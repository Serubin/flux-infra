# Velero (Kopia node agent)

Velero backs up workload data with **filesystem backups** (Kopia uploader) to **Backblaze B2** using the AWS S3-compatible API. This replaces Longhorn’s native S3 backup path and uses a separate prefix in the same bucket (`velero-backups/`).

## Layout

| Path | Purpose |
|------|---------|
| [namespace.yaml](namespace.yaml) | `velero` namespace |
| [velero.hr.yaml](velero.hr.yaml) | HelmRelease (controller + node agent + AWS plugin + BSL) |
| [schedules.yaml](schedules.yaml) | Hourly / daily / weekly `Schedule` CRs |

## Cluster secrets (Flux `postBuild`)

Edit prod cluster secrets with SOPS and set:

- `VELERO_B2_BUCKET` — bucket name (same bucket as former Longhorn target is fine)
- `VELERO_B2_ENDPOINT` — e.g. `https://s3.us-west-004.backblazeb2.com`

Remove obsolete keys when ready:

- `LONGHORN_BACKUP_TARGET` (no longer used)

## B2 credentials secret

`configs/prod/velero-b2-credentials.sops.yaml` defines Secret `velero-b2-credentials` in namespace `velero`, key `cloud`, INI format:

```ini
[default]
aws_access_key_id = <B2 application key ID>
aws_secret_access_key = <B2 application key>
```

Create or update with `sops configs/prod/velero-b2-credentials.sops.yaml`, then `sops -e -i` before commit.

## Schedules

| Name | Cron | TTL |
|------|------|-----|
| `hourly-backup` | `0 * * * *` | 12h |
| `daily-backup` | `0 2 * * *` | 7d (`168h`) |
| `weekly-backup` | `0 3 * * 0` | 10 weeks (`1680h`) |

All use `defaultVolumesToFsBackup: true`. Local-path and explicitly excluded volumes are opted out via `backup.velero.io/backup-volumes-excludes` on pods (and a Kyverno mutate policy for Authelia CNPG pods).

## Verification

```bash
kubectl get pods -n velero
velero backup-location get
velero backup create test-backup --wait
velero backup describe test-backup
```

## Restore

Follow [Velero restore documentation](https://velero.io/docs/latest/restore-reference/). FS backups restore pod volume data via the node agent workflow for the target workload.
