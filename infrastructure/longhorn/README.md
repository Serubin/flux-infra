# Longhorn Storage Configuration

This directory contains the Longhorn storage configuration for the cluster.

## Components

- **longhorn.hr.yaml**: HelmRelease for Longhorn installation
- **longhorn.ingress.yaml**: IngressRoute for Longhorn UI access
- **longhorn-va-cleanup.cronjob.yaml**: CronJob workaround for VolumeAttachment cleanup on single-node clusters

## Offsite backups

Longhorn is used **only as the CSI provisioner** for local block storage. Offsite backups to object storage are handled by **Velero** (Kopia node agent) — see [infrastructure/velero/README.md](../velero/README.md).

Do not configure a Longhorn backup target in the UI; it is not managed by this repository.

## Storage Settings

Current Longhorn configuration:

- Default replica count: 1
- Reclaim policy: Retain (volumes preserved when PVC deleted)
- Default data path: `/opt/k3s/longhorn`
- Auto-salvage: Enabled
