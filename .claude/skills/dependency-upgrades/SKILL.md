---
name: dependency-upgrades
description: Batch-process container image and Helm chart dependency PRs (Renovate or manual) in this Flux GitOps repo — deduplicate, triage risk with parallel subagents, gate merges on the user, then monitor each rollout to confirmation. Use when the user says "process the Renovate PRs", "update containers and helm charts", "triage the dependency PRs", "bump deps", "go through the open dependency PRs", or "/dependency-upgrades".
---

# Dependency upgrades (containers + Helm charts)

Flux CD GitOps repo, single-node k3s prod cluster (`kubectl` context `default`).
Renovate opens one PR per image/chart bump. This skill turns a pile of those into a
safe, verified upgrade pass:

**dedupe → triage → gate on the user → merge → monitor → verify.**

Two rules that never bend:

- **The user merges. The skill never merges.** Present risk per track; the user clicks
  merge; the skill watches the rollout and confirms (or surfaces failure).
- **Plan-and-approve still applies to any fix PR** the skill opens along the way.

## Secrets hygiene — read first

Flux substitutes credentials into rendered HelmRelease values. Printing them leaks them
into the transcript. **Never** run:

- `kubectl get hr -o yaml`, `kubectl get hr ... -o jsonpath` wider than a single leaf
- `helm get values`, `helm template`
- any command that renders a whole HR/release

Use instead: `flux get ...`, `kubectl describe`, and **single-leaf** jsonpath
(`-o jsonpath='{.status.readyReplicas}'`). See memory `avoid_secret_leak_in_yaml_grep`.
The same applies to `kubectl get secret` — never print secret data.

---

## Phase 1 — Enumerate & deduplicate

```
gh pr list --limit 100 --json number,title,headRefName,mergeable
```
Then `gh pr diff <n>` per PR to see the **actual version delta** (title isn't enough).

- **Group by service.** When several PRs touch one file, keep only the **highest**
  version; the rest are superseded (e.g. redis 0.30.8 superseded by 0.32.4). Recommend
  closing the superseded PR — **do not close it without the user's ok.**
- **Triage a service's image and chart together.** Authentik ships as chart PR + image
  PR; CloudNativePG as operator chart + `cluster` chart. Their risk and rollout are
  entangled — one report, one merge decision.
- **Watch the tag-pin trap:** a prod overlay that pins an explicit image `tag:` overrides
  the chart's `appVersion`. Merging the *chart* PR alone then ships nothing; the *image*
  PR is the one that delivers the change. Read `apps/prod/<svc>/*.hr.yaml` to check.
- **Baseline before touching anything:** cluster reachable, and green —
  `flux get all -A --status-selector ready=false` empty, no not-ready pods.

Produce a dedup table: track → PR(s) → version delta.

---

## Phase 2 — Triage with parallel subagents

One subagent **per independent track**, all launched in a single message so they run
concurrently. Group entangled PRs (image+chart, operator+consumer) into one subagent.

Standard brief for each (adapt specifics):

> Triage this Renovate upgrade. READ-ONLY: no edits, no merges, no kubectl writes
> (read-only get/describe is fine). Respect secrets hygiene (no `-o yaml` on HRs, no
> `helm get values`).
> 1. Read the local HelmRelease/manifests **and prod overlays**; record exactly which
>    values this repo sets.
> 2. Research the upstream changelog between the two versions (WebFetch/WebSearch the
>    release notes; for charts, diff `values.yaml`/templates at both tags).
> 3. Cross-check: do any changed/removed/renamed values collide with what the repo sets?
>    Any CRD change, schema migration, default flip, or forced major upgrade?
> 4. Report: **RISK (LOW/MED/HIGH + why) · REQUIRED CONFIG CHANGES · ROLLOUT NOTES
>    (what to watch, downtime, rollback) · MERGE ORDER**.
> 5. **State PROVENANCE** — the exact commands/fetches behind each conclusion. If you
>    didn't verify something, say so; do **not** reconstruct from general knowledge.

Feed each subagent the relevant cluster gotchas from memory: `flux_strict_envsubst`,
`cnpg_backup_cronjob_wedge`, `avoid_secret_leak_in_yaml_grep`,
`longhorn_webhook_blocks_flannel`, `flux_hr_retries_exceeded`.

**Reviewer discipline (this is where the value is):**

- **Independently spot-check every load-bearing claim** before putting a prod merge in
  front of the user. Read the file, run the read-only kubectl, confirm the version.
  Multiple confident subagent findings per pass tend to be wrong; the ones that matter
  get caught by checking the cluster, not by re-reasoning.
- A finding written like generic knowledge with **no cited changelog/version** is a
  guess — re-verify it yourself.
- Idle / fast-return notifications from subagents are **noise**, not the report. Wait for
  the actual findings; ping only if a report never arrives, and tell the agent to admit
  gaps rather than fabricate.

---

## Phase 3 — Sequence & merge-gating rules

Order the merges before proposing any. Hard rules learned here:

- **Operator/CRDs before consumers.** CNPG operator chart before the `cluster` chart.
  Let the operator go green (Deployment Ready + all consumers healthy) before the next.
- **Flux itself LAST and ALONE.** It's the engine applying everything else; isolate it so
  failure is unambiguous. Rollback is **out-of-band** — `git revert` won't self-heal a
  crashlooping kustomize-controller:
  ```
  git checkout main -- clusters/prod/flux-system/gotk-components.yaml
  kubectl apply -f clusters/prod/flux-system/gotk-components.yaml
  ```
  Not `flux install --version=<old>` (the local CLI regenerates new-version manifests).
  Before merging a Flux minor, **audit manifests for `${...}` tokens** that aren't
  cluster-secrets vars — 2.9+ strict envsubst turns those into hard failures
  (memory `flux_strict_envsubst`).
- **Admission controllers (Kyverno) ALONE, in a quiet window.** A restart rejects Pod
  CREATE cluster-wide for ~60s (`failurePolicy: Fail`). Must not overlap any other
  rollout, or the other workload's new pod gets rejected.
- **One-way / no-rollback changes** (ClickHouse minor — on-disk format; a Postgres major)
  gated on: a **verified fresh backup** AND any hardware pre-check (e.g. ClickHouse ≥26.6
  needs AVX2: `grep -o avx2 /proc/cpuinfo` on the node). Confirm the backup path actually
  exists and is current — Velero+kopia PodVolumeBackups and/or the pg_dump CronJob — don't
  assume (memory `cnpg_backup_cronjob_wedge`; the cronjob covers only kutt/plausible/
  authentik, nocodb rides kopia).
- **DB-rolling changes** (`instances: 1` ⇒ hard downtime, no failover, ~10–60s per DB,
  sequential): trigger a fresh on-demand pg_dump immediately before
  (`kubectl create job --from=cronjob/cnpg-pg-dump-backup <name> -n default`); gate each
  stage on **all clusters healthy + PG major version unchanged** before proceeding.

Present risk per track. The user merges; monitor each.

---

## Phase 4 — Monitor the rollout (generation-aware)

**This is the core discipline. The obvious checks lie:**

- Comparing the desired pod-template image (`.spec.template...image`) against
  `.status.readyReplicas` reports success **mid-rollout** — the OLD pod still satisfies
  `readyReplicas`. False positive.
- Counting a `Terminating` pod as "still present" reports failure **after** success.
  False negative.

Use `verify-rollout.sh` in this directory, or its equivalents:

```
# Simple:            verify-rollout.sh -n default deploy/kutt
# Gate on HR:        verify-rollout.sh -n default --hr default/loki=7.1.0 sts/loki
# Assert old gone:   verify-rollout.sh -n default --old-image 2026.5.4 \
#                        deploy/authentik-server deploy/authentik-worker
```

It runs in the background well — launch via Bash `run_in_background`, then Read the
output file. Under the hood it does what any trustworthy check must:

1. `kubectl rollout status` (generation-aware) per workload.
2. Optional HR gate: `lastAttemptedRevision == target` **and** Ready=True.
3. Ignore pods with a `deletionTimestamp` and terminal job pods; flag any **running**
   pod not Ready.
4. Optional: assert no live pod still runs the old image tag.

**Then always finish with a FUNCTIONAL check**, not just "Ready": a version query
(`clickhouse-client --query "SELECT version()"`, `redis-server --version`), a health
endpoint (`/api/v2/health`, Loki `/ready` + an ingestion query), or row counts. "Pod
Ready" is necessary, not sufficient.

Expectations that look like problems but aren't:

- **Chart-only bumps still restart pods** when `helm.sh/chart` changes the pod-template
  hash (authentik restarted; the cloudpirates redis chart didn't). Expect it.
- **Alloy restart → a burst of Loki 400 `dropping data`** for entries older than
  retention: `loki.source.kubernetes` keeps no positions file, so it re-tails from the
  start. Self-limiting; no *current* data lost. Recurs on every alloy restart.
- **App restarts once during a dependency (DB/cache) restart**, exiting cleanly, then
  recovers — expected. A *second* restart, or a CrashLoopBackOff, is not (see Phase 5).

**Verify config changes actually landed.** A `postRenderers` / kustomize patch can
silently no-op (wrong target, merge-key mismatch) while the HR still reports Ready. Assert
the field exists on the **live object**, e.g.
`kubectl get deploy kutt -n default -o jsonpath='{.spec.template.spec.containers[0].startupProbe}'`
— don't infer it from pod health.

Per-workload failure signatures worth a dedicated grep:

- DB: `pgDataImageInfo.majorVersion` changed → **stop**, don't reconcile through it.
- ClickHouse: `Cannot attach table`, `DB::Exception`, `Illegal instruction`.
- Flux/Kustomization: `variable not set (strict mode)` envsubst failures.
- Any app after a dependency restart: liveness-probe-kill CrashLoopBackOff.

---

## Phase 5 — Verify & handle latent faults

Upgrades act as **fault injection** — the restart exposes pre-existing bugs that were
invisible while nothing restarted. When an app doesn't recover, separate the two cases:

- **"The upgrade broke it"** — a real regression in the new version. Roll back per the
  track's rollback path; report.
- **"The upgrade exposed a latent fault"** — the new version is fine; a restart merely
  revealed a pre-existing misconfiguration (missing startupProbe → crashloop; a wedged
  backup CronJob; a silently-emptied envsubst value). Fix the fault as its **own PR**.

For a fix PR: branch, **plan + get approval** (per global guidance), commit with **no
co-author trailer**, PR body in this repo's style — `### Description` only (memory
`flux_infra_pr_style`). If the chart hardcodes the thing you need to change (no values
hook), use `spec.postRenderers` with a kustomize patch — then verify per Phase 4 that the
patch actually landed.

Wrap-up each pass:

- Close superseded PRs (with approval).
- Record follow-ups the triage surfaced (value pins, orphaned PVCs, alerting gaps,
  chart migrations).
- If the pass revealed a new durable cluster gotcha, add a memory file and index it in
  `MEMORY.md`.

---

## Reference

- Helper: `verify-rollout.sh` (this directory) — `--help` for usage.
- Living cluster gotchas: the user's memory files, cited by name above. Prefer pointing
  at them over duplicating, so this skill stays in sync as they change.
