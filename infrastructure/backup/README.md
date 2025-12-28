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
│       - authelia-postgresql-cnpg-cluster                                    │
│       - kutt-postgresql-cnpg-cluster                                        │
│       - plausible-postgresql-cnpg-cluster                                   │
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

The CNPG backup PVC (and all other Longhorn volumes) are automatically backed up to Longhorn's backup target using a tiered retention system with incremental (delta) backups.

### Tiered Backup Retention Policy

All Longhorn volumes are backed up using the tiered system defined in `infrastructure/longhorn/longhorn-backup.recurringjob.yaml`:

| Tier | Schedule | Retention | Coverage |
|------|----------|-----------|----------|
| **Hourly** | Every hour at :00 | 12 backups | Last 12 hours |
| **Daily** | Daily at 2:00 AM | 7 backups | Last 7 days |
| **Weekly** | Every Sunday at 3:00 AM | 8 backups | Last 8 weeks |

**Total backups per volume:** Up to 21 backups maintained across all tiers

### Configuration

- All jobs target **all Longhorn volumes** (no volume labeling required)
- Each backup is labeled with its tier (`backup-tier: hourly|daily|weekly`)
- Longhorn automatically uses incremental/delta backups for efficiency

### Setup Steps

1. **Configure Backup Target** (required):
   - Via Longhorn UI: Settings > Backup Target
   - Or via kubectl (see `infrastructure/longhorn/README.md`)

### How Incremental Backups Work

Longhorn automatically creates incremental backups by:
- Taking snapshots of the volume before backing up
- Only backing up changed blocks since the last snapshot
- This makes frequent backups very efficient, even with hourly runs

### Monitoring Backups

```bash
# Check all recurring job statuses
kubectl get recurringjobs -n longhorn-system | grep longhorn-backup

# Find the CNPG backup volume name
kubectl get volumes -n longhorn-system | grep cnpg-backups

# List backups for a specific volume by tier
kubectl get backups -n longhorn-system -l backup-tier=hourly
kubectl get backups -n longhorn-system -l backup-tier=daily
kubectl get backups -n longhorn-system -l backup-tier=weekly

# View backup details in Longhorn UI
# Navigate to Backup page and filter by volume or backup-tier
```

### Restoring from Longhorn Backup

1. In Longhorn UI, go to Backup page
2. Filter by volume name or `backup-tier`
3. Select the desired backup timestamp
4. Click "Restore" to restore the entire PVC

### Backup Schedule Summary

```
Hourly:   Every hour at :00     → Keeps 12 most recent (12 hours coverage)
Daily:    Daily at 02:00        → Keeps 7 most recent (7 days coverage)
Weekly:   Sundays at 03:00     → Keeps 8 most recent (8 weeks coverage)
```

For offsite backups, configure Longhorn's backup target (S3/NFS) with encryption
at the destination level.
