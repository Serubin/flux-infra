# Backup Infrastructure

This directory contains backup configurations for CloudNativePG PostgreSQL databases.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       CNPG PostgreSQL Backups                               │
│                       (pg_dump to Longhorn)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  • kutt-postgresql-cnpg                                                     │
│  • plausible-postgresql-cnpg                                                │
│  • authentik-postgresql-cnpg                                                │
│  • nocodb-postgresql-cnpg                                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            default namespace                                │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                         CronJob: cnpg-pg-dump-backup                 │  │
│  │                         Schedule: Every 2 hours                      │  │
│  │                         Image: postgres:18-alpine                    │  │
│  └───────────────────────────────────┬──────────────────────────────────┘  │
│                                      │                                      │
│              ┌───────────────────────┼───────────────────────┐              │
│              ▼                       ▼                       ▼              │
│   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│   │  kutt-pg-cnpg    │    │plausible-pg-cnpg │    │authentik-pg-cnpg │      │
│   │   Port 5432      │    │   Port 5432      │    │   Port 5432      │      │
│   └──────────────────┘    └──────────────────┘    └──────────────────┘      │
│                                      │                                      │
│                                      ▼                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    PVC: cnpg-backups-pvc (Encrypted)                 │  │
│  │                    StorageClass: longhorn-encrypted                  │  │
│  │                    Size: 15Gi                                        │  │
│  │                                                                      │  │
│  │    /backups/                                                         │  │
│  │    ├── kutt/                                                         │  │
│  │    │   ├── kutt-20241226-140000.dump                                 │  │
│  │    │   └── ...                                                       │  │
│  │    ├── plausible/                                                    │  │
│  │    │   └── ...                                                       │  │
│  │    ├── authentik/                                                    │  │
│  │    │   └── ...                                                       │  │
│  │    └── nocodb/                                                       │  │
│  │        └── ...                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Backup Schedule & Retention

| Schedule | Every 2 hours (`0 */2 * * *`) |
|----------|-------------------------------|

**Tiered Retention Policy:**

| Tier | Count | Age Range | Purpose |
|------|-------|-----------|---------|
| Hourly | 6 backups | 0-12 hours | Recent granularity |
| 12-Hourly | 4 backups | 12-48 hours | Short-term recovery |
| Daily | 5 backups | 48+ hours | Long-term recovery |

```
Time ──────────────────────────────────────────────────────────────────────▶

Now                    12h ago              48h ago                    7d ago
 │                        │                    │                          │
 ├────────────────────────┼────────────────────┼──────────────────────────┤
 │   6 hourly backups     │  4 twelve-hourly   │       5 daily            │
 │   (every 2 hours)      │     backups        │       backups            │
 └────────────────────────┴────────────────────┴──────────────────────────┘

Maximum backups per database: 15
Total across all databases: 60 dump files
```

> **PVC headroom:** the 15Gi PVC was sized for two databases. Authentik dumps
> are typically small (tens of MB), but verify free space after the first full
> retention cycle (`kubectl exec`/`df` against `cnpg-backups-pvc`) and bump
> `cnpg-backup.pvc.yaml` if utilisation exceeds ~70%.

## Storage

The backup PVC uses standard Longhorn storage (unencrypted):

```
┌─────────────────────────────────────────────────────────────┐
│  PVC: cnpg-backups-pvc                                      │
│  storageClassName: longhorn                                 │
└─────────────────────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────┐
│  Longhorn Volume                                            │
│  - Unencrypted at rest (allows portable Longhorn backups)   │
│  - Access restricted by Kyverno policy                      │
└─────────────────────────────────────────────────────────────┘
```

**Why unencrypted?** This allows Longhorn's native backup feature to create
portable backups that don't require an encryption key to restore.

---

## Security

### Network Isolation

The backup job is isolated via NetworkPolicy:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            NetworkPolicy Rules                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Pod Selector: app=cnpg-backup                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  INGRESS: ❌ Denied (no inbound traffic)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  EGRESS:                                                                    │
│    ✅ DNS (UDP/TCP 53)                                                      │
│    ✅ PostgreSQL clusters on port 5432:                                     │
│       - kutt-postgresql-cnpg-cluster                                        │
│       - plausible-postgresql-cnpg-cluster                                   │
│       - authentik-postgresql-cnpg-cluster                                   │
│       - nocodb-postgresql-cnpg-cluster                                      │
│    ❌ All other traffic denied                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### PVC Access Control (Kyverno)

A Kyverno ValidatingPolicy prevents unauthorized pods from mounting the backup PVC:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              ValidatingPolicy: restrict-cnpg-backup-pvc-access              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Action: Deny (block violating pods)                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Rule: If a pod tries to mount "cnpg-backups-pvc":                          │
│                                                                             │
│    ✅ ALLOW: Pods with label app=cnpg-backup (CronJob and holder)           │
│    ❌ DENY:  All other pods                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Operations

### Trigger Manual Backup

```bash
kubectl create job --from=cronjob/cnpg-pg-dump-backup cnpg-backup-manual -n default
```

### View Backup Logs

```bash
kubectl logs -f job/cnpg-backup-manual -n default
```

### List Current Backups

```bash
# Create a temporary pod to inspect backups
kubectl run backup-inspector --rm -it --restart=Never \
  --image=alpine \
  --overrides='{"spec":{"containers":[{"name":"alpine","image":"alpine","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"backups","mountPath":"/backups"}]}],"volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"cnpg-backups-pvc"}}]}}' \
  -n default

# Inside the pod:
find /backups -name "*.dump" -exec ls -lh {} \;
```

### Restore a Database

The scheduled dumps come from the Postgres 18 client. `pg_restore` must be at least as
new as the `pg_dump` that wrote the archive, so run the restore from an 18 client (for
example a `postgres:18-alpine` pod), not from an older server's own binary. Files named
`pre-pg18-<app>-*.dump` are one-off rollback dumps from the 16 client, taken by hand
before each cluster's move to 18; the retention glob skips them, so delete them by hand.

```bash
# 1. Get the backup file name
kubectl exec -it <inspector-pod> -- ls -la /backups/kutt/

# 2a. Server on Postgres 18: restore the archive directly, as the owner
pg_restore -h kutt-postgresql-cnpg-cluster-rw -U kutt -d kutt -c --if-exists \
  --exit-on-error --single-transaction /backups/kutt/kutt-<timestamp>.dump

# 2b. Server still on Postgres 16: an 18 dump sets transaction_timeout, which 16
#     rejects, so restore through SQL with that line removed
pg_restore -c --if-exists -f - /backups/kutt/kutt-<timestamp>.dump \
  | sed '/^SET transaction_timeout/d' \
  | psql -h kutt-postgresql-cnpg-cluster-rw -U kutt -d kutt -v ON_ERROR_STOP=1 --single-transaction
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `cnpg-backup.cronjob.yaml` | PostgreSQL backup job (every 2 hours) |
| `cnpg-backup.pvc.yaml` | Storage for dumps |
| `cnpg-backup.networkpolicy.yaml` | Network isolation for backup pods |
| `cnpg-backup-pvc.vpol.yaml` | Kyverno policy restricting PVC access |
| `cnpg-backup-holder.deployment.yaml` | Keeps the dump PVC mounted so Velero backs it up |

---

## Offsite backup (Velero)

The `cnpg-backups-pvc` Longhorn volume (pg_dump output) is included in **Velero** filesystem backups to B2, along with other in-scope Longhorn-backed workloads. Schedules and credentials are defined under [infrastructure/velero/](../velero/README.md).

Velero's filesystem backup only reads volumes of running pods, so the short-lived dump Job can't carry the PVC itself. `cnpg-backup-holder` is a `pause` pod that mounts the PVC read-only to keep it in every backup, and the Job pod template excludes the volume with `backup.velero.io/backup-volumes-excludes` so a backup that catches a Job mid-run doesn't fail on it. The holder carries `app: cnpg-backup`, so the Kyverno policy admits it and the `cnpg-backup-isolation` NetworkPolicy blocks all ingress to it.

```bash
velero schedule get -n velero
velero backup get -n velero
```

Restore workflows use the Velero CLI and node agent; see the Velero README linked above.
