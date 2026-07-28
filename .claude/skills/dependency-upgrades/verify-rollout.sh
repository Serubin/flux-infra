#!/usr/bin/env bash
# verify-rollout.sh — generation-aware rollout verification for Flux-managed workloads.
#
# Distilled from the dependency-upgrade monitoring done by the `dependency-upgrades`
# skill. It exists because the obvious checks lie:
#   - comparing the desired pod-template image against .status.readyReplicas reports
#     success mid-rollout (the OLD pod still satisfies readyReplicas) — false positive.
#   - counting a Terminating pod as "still present" reports failure after success —
#     false negative.
# So this uses `kubectl rollout status` (generation-aware), ignores pods with a
# deletionTimestamp, optionally gates on the HelmRelease revision + Ready condition,
# and can assert no live pod still runs the old image.
#
# READ-ONLY: only `kubectl get`/`rollout status`/`describe`. No writes, no secrets
# printed (never dumps HR values or wide YAML).
#
# Usage:
#   verify-rollout.sh -n <namespace> [options] <workload> [<workload> ...]
#
#   <workload>   deploy/<name> | sts/<name> | ds/<name>   (statefulset/daemonset ok)
#
# Options:
#   -n, --namespace <ns>        Namespace (required).
#       --hr <ns/name=version>  Gate on HelmRelease: wait until lastAttemptedRevision
#                               == version AND Ready=True. Fail fast on Ready=False.
#       --old-image <substr>    Fail if any live (non-terminating) pod in <ns> still
#                               runs an image containing <substr>.
#       --timeout <seconds>     Per-workload rollout timeout (default 300).
#   -h, --help
#
# Exit: 0 = every check passed; non-zero = at least one failed (safe for backgrounding
# via Bash run_in_background, then Read the output file).
#
# Examples:
#   verify-rollout.sh -n default deploy/kutt
#   verify-rollout.sh -n default --hr default/loki=7.1.0 sts/loki
#   verify-rollout.sh -n default --old-image 2026.5.4 deploy/authentik-server deploy/authentik-worker

set -uo pipefail

NS=""
HR_SPEC=""
OLD_IMAGE=""
TIMEOUT=300
WORKLOADS=()

die() { echo "error: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NS="${2:-}"; shift 2 ;;
    --hr)           HR_SPEC="${2:-}"; shift 2 ;;
    --old-image)    OLD_IMAGE="${2:-}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)              WORKLOADS+=("$1"); shift ;;
  esac
done

[ -n "$NS" ] || die "namespace is required (-n <ns>)"
[ "${#WORKLOADS[@]}" -gt 0 ] || die "at least one workload is required (deploy/x, sts/y, ds/z)"

FAIL=0
note_fail() { echo "  FAIL: $*"; FAIL=1; }

# ---------------------------------------------------------------------------
# 1. HelmRelease gate (optional): revision reached target AND Ready=True.
# ---------------------------------------------------------------------------
if [ -n "$HR_SPEC" ]; then
  hr_ns_name="${HR_SPEC%%=*}"
  hr_version="${HR_SPEC#*=}"
  hr_ns="${hr_ns_name%%/*}"
  hr_name="${hr_ns_name#*/}"
  [ "$hr_ns" != "$hr_ns_name" ] || die "--hr must be ns/name=version, got: $HR_SPEC"
  echo "[hr] $hr_ns/$hr_name -> $hr_version"
  ok=0
  for _ in $(seq 1 60); do
    rev=$(kubectl get hr "$hr_name" -n "$hr_ns" -o jsonpath='{.status.lastAttemptedRevision}' 2>/dev/null)
    ready=$(kubectl get hr "$hr_name" -n "$hr_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$ready" = "False" ]; then
      msg=$(kubectl get hr "$hr_name" -n "$hr_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
      note_fail "HelmRelease Ready=False at revision '${rev}': ${msg}"
      ok=1; break
    fi
    if [ "$ready" = "True" ] && [ "$rev" = "$hr_version" ]; then
      echo "  ok: revision=$rev Ready=True"; ok=1; break
    fi
    sleep 10
  done
  [ "$ok" = "1" ] || note_fail "HelmRelease did not reach $hr_version/Ready in time (rev=$rev ready=$ready)"
fi

# ---------------------------------------------------------------------------
# 2. Per-workload rollout status (generation-aware).
# ---------------------------------------------------------------------------
for w in "${WORKLOADS[@]}"; do
  echo "[rollout] $w"
  if out=$(kubectl rollout status "$w" -n "$NS" --timeout="${TIMEOUT}s" 2>&1); then
    echo "  ok: $(echo "$out" | tail -1)"
  else
    note_fail "$w did not complete: $(echo "$out" | tail -1)"
    echo "  --- pods ---"
    kubectl get pods -n "$NS" -o wide --no-headers 2>/dev/null | sed 's/^/    /' | head -20
    echo "  --- recent events ---"
    kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -8 | sed 's/^/    /'
  fi
done

# ---------------------------------------------------------------------------
# 3. Live (non-terminating) pods that are not Ready. Terminal job pods ignored.
# ---------------------------------------------------------------------------
echo "[readiness] non-terminating pods not Ready"
notready=$(kubectl get pods -n "$NS" -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = []
for p in d.get("items", []):
    m = p.get("metadata", {})
    s = p.get("status", {})
    if m.get("deletionTimestamp"):            # Terminating -> not "live"
        continue
    if s.get("phase") in ("Succeeded", "Failed"):  # completed job pods
        continue
    ready = next((c["status"] for c in s.get("conditions", []) if c["type"] == "Ready"), "?")
    if ready != "True":
        bad.append("%s phase=%s ready=%s" % (m["name"], s.get("phase"), ready))
print("\n".join(bad))
')
if [ -n "$notready" ]; then
  echo "$notready" | sed 's/^/  /'
  note_fail "$(echo "$notready" | wc -l | tr -d ' ') running pod(s) not Ready"
else
  echo "  ok: all live pods Ready"
fi

# ---------------------------------------------------------------------------
# 4. Old-image assertion (optional): no live pod may still run the old tag.
# ---------------------------------------------------------------------------
if [ -n "$OLD_IMAGE" ]; then
  echo "[old-image] no live pod may run image containing '$OLD_IMAGE'"
  stragglers=$(kubectl get pods -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
old = sys.argv[1]
d = json.load(sys.stdin)
hits = []
for p in d.get('items', []):
    if p.get('metadata', {}).get('deletionTimestamp'):
        continue
    for c in p.get('spec', {}).get('containers', []):
        if old in c.get('image', ''):
            hits.append(f\"{p['metadata']['name']} -> {c['image']}\")
print('\n'.join(hits))
" "$OLD_IMAGE")
  if [ -n "$stragglers" ]; then
    echo "$stragglers" | sed 's/^/  /'
    note_fail "old-image pods still live"
  else
    echo "  ok: none"
  fi
fi

# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: rollout verified in ns/$NS"
else
  echo "FAIL: one or more checks failed in ns/$NS — see above"
fi
exit "$FAIL"
