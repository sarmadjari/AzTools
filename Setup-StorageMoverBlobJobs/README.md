# Setup-StorageMoverBlobJobs.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 1.0 | **Date:** 2026-03-09

Automates Azure Storage Mover blob-to-blob job setup from a CSV of storage account pairs. Discovers all blob containers on each source, validates compatibility, creates matching containers on the destination, and sets up all Storage Mover resources (endpoints, project, job definitions, RBAC). Optionally starts the jobs.

---

## ⚠️ Disclaimer

> **This script is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with this script or the use or other dealings in this script.**

This script is shared strictly as a **proof-of-concept (POC)** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

By using this script, you accept full responsibility for:

- Reviewing and customising the script to meet your specific environment and requirements
- Validating storage account pairs, container mappings, and Storage Mover configuration against your organisational standards
- Applying appropriate security hardening, access controls, RBAC assignments, and network restrictions to all storage accounts and Storage Mover resources
- Ensuring data residency, sovereignty, and regulatory requirements are met for the target region before executing any migration
- Testing and validating in lower environments (development / staging) before running against production storage accounts
- Verifying copy mode (Additive vs Mirror) and job definitions are fit for purpose prior to production use
- Following your organisation's approved change management, deployment, and operational practices

> **Run without `-StartJobs` first to review the setup before starting any data migration jobs.**

---

## What the Script Does

For each row in the CSV:

| Step | Action |
|---|---|
| 1 | Parse source and destination ARM Resource IDs |
| 2 | Validate source storage account (kind, HNS compatibility) |
| 3 | Validate destination storage account (kind, HNS compatibility) |
| 4 | List blob containers on source, filter out system containers |
| 5 | Create matching containers on destination (if missing) |
| 6 | Create Storage Mover project for the account pair |
| 7 | For each container: create source endpoint, target endpoint |
| 8 | Assign RBAC (Storage Blob Data Owner) on both containers for both managed identities |
| 9 | Create job definition (Additive or Mirror copy mode) |
| 10 | Optionally start the job (if `-StartJobs` is specified) |

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-StorageMoverName` | Yes | Name of the existing Storage Mover resource |
| `-StorageMoverRG` | Yes | Resource group of the existing Storage Mover resource |
| `-CsvPath` | Yes | Path to CSV with headers: `SourceResourceId`, `DestResourceId` |
| `-CopyMode` | No | `Additive` (default) or `Mirror`. Additive = copy new/updated only. Mirror = full sync with deletes |
| `-StartJobs` | No | If set, starts all created jobs after setup |

## Compatibility

The script automatically skips incompatible accounts:

| Account Type | Supported |
|---|---|
| StorageV2 (General Purpose v2) | Yes |
| BlobStorage (legacy blob-only) | Yes |
| BlockBlobStorage (Premium) | Yes |
| Storage (classic) | Yes |
| HNS-enabled (ADLS Gen2) | No — skipped with warning |
| FileStorage | No — skipped with warning |

## CSV Format

```csv
SourceResourceId,DestResourceId
/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<source-name>,/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<dest-name>
```

## Usage Examples

**Setup only (don't start jobs):**
```powershell
.\Setup-StorageMoverBlobJobs.ps1 -StorageMoverName "sm-georeplication-001" -StorageMoverRG "rg-dr-georeplication-001" -CsvPath ".\resources.csv"
```

**Setup and start with Mirror mode:**
```powershell
.\Setup-StorageMoverBlobJobs.ps1 -StorageMoverName "sm-georeplication-001" -StorageMoverRG "rg-dr-georeplication-001" -CsvPath ".\resources.csv" -CopyMode "Mirror" -StartJobs
```

## Output

Exports a summary CSV: `StorageMoverSetup_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SourceAccount` | Source storage account name |
| `DestAccount` | Destination storage account name |
| `ContainerName` | Container name |
| `Status` | `Created`, `Skipped`, or `Failed` |
| `EndpointSource` | Source endpoint name in Storage Mover |
| `EndpointTarget` | Target endpoint name in Storage Mover |
| `JobName` | Job definition name |
| `JobStarted` | `Yes`, `No`, or `No (limit reached)` |
| `Notes` | Error or skip reason |

## Important Notes

- **RBAC propagation** may take 5–10 minutes before jobs succeed
- **Max concurrent jobs** is capped at 10 to avoid overwhelming the Storage Mover agent
- **System containers** (`$logs`, `$blobchangefeed`, `$web`, `$root`, etc.) are automatically skipped
- Cross-subscription scenarios are supported

## Requirements

- **Azure CLI** — authenticated with appropriate permissions
- **Azure Storage Mover** — must already be deployed with an agent registered
- **Permissions** — Contributor on storage accounts, Storage Blob Data Owner for RBAC assignments
