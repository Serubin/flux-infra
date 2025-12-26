# Backup Infrastructure

This directory contains backup configurations for CloudNativePG PostgreSQL databases.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       CNPG PostgreSQL Backups                               │
│                       (pg_dump to Longhorn)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  • authelia-postgresql-cnpg                                                 │
│  • kutt-postgresql-cnpg                                                     │
│  • plausible-postgresql-cnpg                                                │
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
│  │                         Image: postgres:16-alpine                    │  │
│  └───────────────────────────────────┬──────────────────────────────────┘  │
│                                      │                                      │
│            ┌─────────────────────────┼─────────────────────────┐            │
│            │                         │                         │            │
│            ▼                         ▼                         ▼            │
│  ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐    │
│  │ authelia-pg-cnpg │     │  kutt-pg-cnpg    │     │plausible-pg-cnpg │    │
│  │   Port 5432      │     │   Port 5432      │     │   Port 5432      │    │
│  └──────────────────┘     └──────────────────┘     └──────────────────┘    │
│                                      │                                      │
│                                      ▼                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    PVC: cnpg-backups-pvc (Encrypted)                 │  │
│  │                    StorageClass: longhorn-encrypted                  │  │
│  │                    Size: 15Gi                                        │  │
│  │                                                                      │  │
│  │    /backups/                                                         │  │
│  │    ├── authelia/                                                     │  │
│  │    │   ├── authelia-20241226-140000.dump                             │  │
│  │    │   └── ...                                                       │  │
│  │    ├── kutt/                                                         │  │
│  │    │   └── ...                                                       │  │
│  │    └── plausible/                                                    │  │
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
Total across all databases: 45 dump files
```

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
│       - authelia-postgresql-cnpg                                            │
│       - kutt-postgresql-cnpg                                                │
│       - plausible-postgresql-cnpg                                           │
│    ❌ All other traffic denied                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### PVC Access Control (Kyverno)

A Kyverno ClusterPolicy prevents unauthorized pods from mounting the backup PVC:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              ClusterPolicy: restrict-cnpg-backup-pvc-access                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  Action: Enforce (block violating pods)                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  Rule: If a pod tries to mount "cnpg-backups-pvc":                          │
│                                                                             │
│    ✅ ALLOW: Pods with label app=cnpg-backup (the backup CronJob)           │
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

```bash
# 1. Get the backup file name
kubectl exec -it <inspector-pod> -- ls -la /backups/authelia/

# 2. Restore to the CNPG cluster
kubectl exec -it authelia-postgresql-cnpg-1 -n default -- \
  pg_restore -U authelia -d authelia -c /path/to/backup.dump
```

Or create a new cluster from backup:

```bash
# 1. Copy dump out of cluster
kubectl cp <pod>:/backups/authelia/authelia-20241226-140000.dump ./authelia.dump

# 2. Create new CNPG cluster, then restore
kubectl exec -i new-cluster-1 -- pg_restore -U authelia -d authelia -c < ./authelia.dump
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `cnpg-backup.cronjob.yaml` | PostgreSQL backup job (every 2 hours) |
| `cnpg-backup.pvc.yaml` | Storage for dumps |
| `cnpg-backup.networkpolicy.yaml` | Network isolation for backup pods |
| `cnpg-backup-pvc.policy.yaml` | Kyverno policy restricting PVC access |

---

## Longhorn Backup

To backup the PVC to external storage using Longhorn:

```bash
# Create a backup via Longhorn UI or API
# The backup will be unencrypted and portable
```

For offsite backups, configure Longhorn's backup target (S3/NFS) with encryption
at the destination level.
