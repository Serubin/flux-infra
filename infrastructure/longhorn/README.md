# Longhorn Storage Configuration

This directory contains the Longhorn storage configuration for the cluster.

## Components

- **longhorn.hr.yaml**: HelmRelease for Longhorn installation
- **longhorn.ingress.yaml**: IngressRoute for Longhorn UI access
- **longhorn-backup.recurringjob.yaml**: Tiered backup system for all volumes

## Backup Configuration

### Tiered Backup System for All Volumes

The `longhorn-backup.recurringjob.yaml` resource creates a tiered backup system that backs up **all Longhorn volumes**:

| Tier | Schedule | Retention | Coverage |
|------|----------|-----------|----------|
| **Hourly** | Every hour at :00 | 12 backups | Last 12 hours |
| **Daily** | Daily at 2:00 AM | 7 backups | Last 7 days |
| **Weekly** | Every Sunday at 3:00 AM | 8 backups | Last 8 weeks |

**Total backups per volume:** Up to 21 backups maintained across all tiers

All backups use incremental (delta) backups for efficiency.

### Backup Target Setup

The S3 backup target is configured via GitOps in the `configs/` directory for each environment.

#### Configuration Files

**Production** (`configs/prod/`):
- `longhorn-backup-secret.sops.yaml`: SOPS-encrypted S3 credentials
- `longhorn-backup-target.setting.yaml`: Backup target Settings

**Staging** (`configs/staging/`):
- `longhorn-backup-secret.sops.yaml`: SOPS-encrypted S3 credentials
- `longhorn-backup-target.setting.yaml`: Backup target Settings

#### Setting Up Backblaze B2 Credentials

1. **Create Backblaze B2 Bucket and Application Key**:
   - Log into Backblaze B2
   - Create a bucket (set to "Private" for security)
   - Go to "App Keys" and create a new Application Key with "Write" permissions
   - Note the Key ID (Application Key ID) and Application Key

2. **Edit the SOPS secret file** for your environment:
   ```bash
   # For production
   sops configs/prod/longhorn-backup-secret.sops.yaml
   
   # For staging
   sops configs/staging/longhorn-backup-secret.sops.yaml
   ```

3. **Add your Backblaze B2 credentials**:
   ```yaml
   stringData:
     AWS_ACCESS_KEY_ID: <your-b2-application-key-id>
     AWS_SECRET_ACCESS_KEY: <your-b2-application-key>
     AWS_ENDPOINTS: https://s3.<region>.backblazeb2.com
   ```
   
   **Endpoint regions**: `us-west-000`, `us-west-001`, `us-west-002`, `us-west-003`, `us-west-004`, `eu-central-003`
   
   Find your region in Backblaze B2 bucket settings or use `us-west-004` (default).

4. **Save and encrypt** with SOPS (if not already encrypted):
   ```bash
   sops -e -i configs/prod/longhorn-backup-secret.sops.yaml
   ```

5. **Update the backup target** in the Setting file with your bucket name:
   ```yaml
   # configs/prod/longhorn-backup-target.setting.yaml
   value: s3://your-bucket-name@dummyregion/
   ```
   
   Note: The `dummyregion` is a placeholder - the actual endpoint is specified in `AWS_ENDPOINTS` in the secret.

6. **Commit and push** - Flux will automatically apply the changes

#### Backblaze B2 Bucket Encryption

Backblaze B2 provides **server-side encryption** by default for all data. No additional configuration is required - all backups stored in B2 are automatically encrypted at rest.

### Supported Backup Targets

- **Backblaze B2** (Currently configured)
  - Format: `s3://bucket-name@dummyregion/` (region is placeholder)
  - Requires: `AWS_ACCESS_KEY_ID` (B2 Application Key ID), `AWS_SECRET_ACCESS_KEY` (B2 Application Key), and `AWS_ENDPOINTS` (B2 S3 endpoint)
  - Encryption: Automatic server-side encryption (default)
  - Endpoint format: `https://s3.<region>.backblazeb2.com`

- **AWS S3**
  - Format: `s3://bucket-name@region/`
  - Requires: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
  - Encryption: Enable SSE-S3 or SSE-KMS in bucket settings

- **Other S3-compatible storage** (MinIO, etc.)
  - Format: `s3://bucket-name@region/`
  - Requires: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_ENDPOINTS`

- **NFS**
  - Format: `nfs://server:/path`
  - No credentials required (if NFS allows anonymous access)

- **Azure Blob Storage**
  - Format: `azblob://container-name@account-name/`
  - Requires Azure storage account credentials

### Customizing Backup Schedule

Edit `longhorn-backup.recurringjob.yaml` to change:
- **cron**: CRON expression for backup schedule
- **retain**: Number of backups to keep
- **concurrency**: Number of simultaneous backup jobs
- **groups**: Volume label selectors (empty = all volumes)

### Targeting Specific Volumes

To backup only specific volumes instead of all volumes:

1. Label your Longhorn volumes:
   ```bash
   kubectl label volume <volume-name> backup=enabled -n longhorn-system
   ```

2. Update the RecurringJob to use groups:
   ```yaml
   groups:
     - backup=enabled
   ```

### Monitoring Backups

View backup status via:
- Longhorn UI: Navigate to Backup page
- Kubectl:
  ```bash
  # Check all recurring jobs
  kubectl get recurringjobs -n longhorn-system
  
  # List backups by tier
  kubectl get backups -n longhorn-system -l backup-tier=hourly
  kubectl get backups -n longhorn-system -l backup-tier=daily
  kubectl get backups -n longhorn-system -l backup-tier=weekly
  
  # List all backups
  kubectl get backups -n longhorn-system
  ```

### Restoring from Backup

1. In Longhorn UI, go to Backup page
2. Select the backup to restore
3. Click "Restore" and choose target volume or create new volume

Or via kubectl:
```bash
# List available backups
kubectl get backups -n longhorn-system

# Restore via Longhorn UI (recommended) or API
```

## Storage Settings

Current Longhorn configuration:
- Default replica count: 1
- Reclaim policy: Retain (volumes preserved when PVC deleted)
- Default data path: `/opt/k3s/longhorn`
- Auto-salvage: Enabled

