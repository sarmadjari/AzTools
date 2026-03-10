# Setup-StorageMoverBlobJobs.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 2.0 | **Date:** 2026-03-10

Sets up Azure Storage Mover blob-to-blob jobs from a CSV of storage account mappings. Discovers all blob containers on each source, validates compatibility, ensures matching containers exist on the destination, then creates all Storage Mover resources (project, endpoints, RBAC, job definitions). Optionally starts the jobs. The Storage Mover resource and its resource group are created automatically if they do not exist.

Blob-to-blob Storage Mover jobs are **cloud-managed** — no on-premises agent is required.

---

## Disclaimer

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

> **Run with `-DryRun` first to review planned changes before executing live.**
> **Run without `-StartJobs` first to review the setup before starting any data migration jobs.**

---

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated (`az login`)
- **PowerShell 7+** (`pwsh`) — available in Azure Cloud Shell
- **Azure Storage Mover** extension: `az extension add --name storage-mover` (if not already installed)
- Permissions: Contributor on both source and destination subscriptions
- RBAC: Owner role on storage accounts (required for assigning Storage Blob Data Owner to managed identities)
- **Destination storage accounts must already exist** — use `Create-DRBlobStorageAccounts.ps1` to create them first

## Compatible Storage Account Types

The script automatically skips incompatible accounts with a warning:

| Account Type | Compatible | Notes |
|---|---|---|
| StorageV2 (General Purpose v2) | Yes | |
| BlobStorage (legacy blob-only) | Yes | |
| BlockBlobStorage (Premium) | Yes | |
| Storage (classic) | Yes | |
| FileStorage | No | Skipped — no blob service |
| HNS-enabled (ADLS Gen2) | No | Skipped — not supported by Storage Mover |

Both source AND destination must pass the compatibility check.

## CSV Format

Same CSV format as `Create-DRBlobStorageAccounts.ps1`:

```csv
SourceResourceId,DestStorageAccountName,DestResourceGroupName
/subscriptions/xxx/resourceGroups/rg-prod/providers/Microsoft.Storage/storageAccounts/stprod01,stdr001,rg-dr-switzerlandnorth
/subscriptions/xxx/resourceGroups/rg-prod/providers/Microsoft.Storage/storageAccounts/stprod02,stdr002,rg-dr-switzerlandnorth
```

| Column | Description |
|---|---|
| `SourceResourceId` | Full ARM Resource ID of the source storage account |
| `DestStorageAccountName` | Name of the destination storage account (must already exist) |
| `DestResourceGroupName` | Resource group of the destination account |

A sample CSV is provided: `resources-sample.csv`

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-CsvPath` | Yes | Path to the CSV mapping file |
| `-DestRegion` | Yes | Azure region for the Storage Mover and its resource group (e.g., `switzerlandnorth`) |
| `-StorageMoverName` | Yes | Name of the Azure Storage Mover resource (created if it doesn't exist) |
| `-StorageMoverRG` | Yes | Resource group for the Storage Mover (created if it doesn't exist) |
| `-DestSubscriptionId` | No | Destination subscription ID. Defaults to the source subscription |
| `-CopyMode` | No | `Additive` (default) or `Mirror`. Both copy ALL existing objects on first run — Additive never deletes on target, Mirror syncs deletions |
| `-StartJobs` | No | If set, starts jobs after setup (capped at 10 concurrent) |
| `-DryRun` | No | Dry run — shows what would be created without making changes |

## Usage Examples

### Basic setup (Additive mode, don't start jobs)

```powershell
./Setup-StorageMoverBlobJobs.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover"
```

### Dry run (preview changes without creating anything)

```powershell
./Setup-StorageMoverBlobJobs.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover" -DryRun
```

### Mirror mode — start jobs immediately

```powershell
./Setup-StorageMoverBlobJobs.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover" -CopyMode "Mirror" -StartJobs
```

### Cross-subscription — destination accounts in a different subscription

```powershell
./Setup-StorageMoverBlobJobs.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Pre-Validation

Before any Azure operations begin, the script validates **all rows** in the CSV upfront:

| Check | Details |
|---|---|
| ARM Resource ID format | Must match `/subscriptions/.../storageAccounts/...` pattern |
| Destination account name | Must be 3-24 characters, lowercase alphanumeric only |
| Duplicate source-dest pairs | No two rows can have the same source-dest combination |
| Self-reference | Source and destination cannot be the same account |
| Empty fields | SourceResourceId, DestStorageAccountName, DestResourceGroupName must not be empty |

If any validation errors are found, the script reports **all errors at once** and exits before making any Azure API calls.

## What the Script Does

### Before the Main Loop

| Step | Action |
|---|---|
| A | Validate CSV (file exists, headers correct, rows > 0) |
| B | **Pre-validate all rows** — abort if any errors found |
| C | **Ensure Storage Mover exists** — create RG and Storage Mover in `DestRegion` if missing |

### For Each Row in the CSV

| Step | Action |
|---|---|
| 1 | Parse source ARM Resource ID, determine destination subscription |
| 2 | Validate source account (kind, HNS compatibility) — skip if incompatible |
| 3 | Look up destination account by name + RG — fail if not found, skip if incompatible |
| 4 | List source containers via **ARM REST API** (bypasses source firewall) |
| 5 | Filter out system containers (`$logs`, `$blobchangefeed`, `$web`, `$root`, etc.) |
| 6 | Ensure matching containers exist on dest via **ARM REST API PUT** (bypasses dest firewall) |
| 7 | Create Storage Mover project for the account pair |
| 8 | For each container: create source endpoint + target endpoint |
| 9 | Assign RBAC (Storage Blob Data Owner) to endpoint managed identities |
| 10 | Create job definition (Additive or Mirror copy mode) |
| 11 | Optionally start the job (if `-StartJobs`, capped at 10 concurrent) |

**Why ARM API for container listing and creation:** Storage accounts often have `defaultAction=Deny` firewall. The ARM Management Plane API (`management.azure.com`) bypasses it — no need to modify firewall settings on either account.

## Storage Mover Resource Hierarchy

```
Storage Mover (top-level Azure resource)
└── Project (one per source-dest account pair)
    └── Job Definition (one per container)
        ├── Source Endpoint (points to source container)
        └── Target Endpoint (points to dest container)
```

| Resource | Naming Convention | Scope |
|---|---|---|
| Project | `proj-{SourceName}-to-{DestName}` | Per account pair |
| Source Endpoint | `ep-src-{AccountName}-{ContainerName}` | Global to Storage Mover |
| Target Endpoint | `ep-tgt-{AccountName}-{ContainerName}` | Global to Storage Mover |
| Job Definition | `job-{ContainerName}` | Per project |

All names are truncated to 63 characters (ARM naming limit).

## Copy Mode

| Mode | First Run | Subsequent Runs |
|---|---|---|
| **Additive** (default) | Copies ALL objects from source to dest | Copies new/updated objects. **Never deletes** anything on target |
| **Mirror** | Copies ALL objects from source to dest | Full sync — copies new/updated AND **deletes** objects on target that don't exist on source |

## Idempotent / Safe to Re-run

The script is safe to run multiple times on the same CSV:

- **Existing Storage Mover resources** (projects, endpoints, jobs) are reused — not duplicated
- **Existing containers** on the destination are not affected
- **RBAC assignments** are idempotent (re-assignment is harmless)
- **New containers** added to the source since the last run are picked up automatically
- **Storage Mover and its RG** are detected and reused if they already exist

## Running in Azure Cloud Shell

Azure Cloud Shell has a 20-minute idle timeout. For long-running operations, use `tmux` to keep the session alive:

```bash
# 1. Start a tmux session
tmux new -s sm-setup

# 2. Run the script (pwsh launches PowerShell inline)
pwsh ./Setup-StorageMoverBlobJobs.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover"

# 3. If browser disconnects, reconnect to Cloud Shell and reattach:
tmux attach -t sm-setup
```

| tmux Command | What it does |
|---|---|
| `tmux new -s sm-setup` | Create a named session |
| `tmux attach -t sm-setup` | Reattach after disconnect |
| `tmux ls` | List active sessions |
| `Ctrl+B` then `D` | Detach manually (script keeps running) |

## Output

The script exports a timestamped results CSV: `StorageMoverResults_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SourceAccount` | Source storage account name |
| `DestAccount` | Destination storage account name |
| `DestResourceGroup` | Destination resource group |
| `DestSubscription` | Destination subscription ID |
| `ProjectName` | Storage Mover project name |
| `ContainerName` | Blob container name |
| `EndpointSource` | Source endpoint name in Storage Mover |
| `EndpointTarget` | Target endpoint name in Storage Mover |
| `JobName` | Job definition name |
| `JobStatus` | `Created`, `Skipped`, `Failed`, or `DryRun` |
| `JobStarted` | `Yes`, `No`, or `No (limit reached)` |
| `CopyMode` | `Additive` or `Mirror` |
| `Notes` | Error or skip reason |

## Workflow

```
1. Create DR accounts     ->  Create-DRBlobStorageAccounts.ps1 ... (run first)
2. Prepare CSV            ->  Same CSV used for account creation
3. Dry run                ->  ./Setup-StorageMoverBlobJobs.ps1 ... -DryRun
4. Setup Storage Mover    ->  ./Setup-StorageMoverBlobJobs.ps1 ...
5. Review results CSV     ->  Check StorageMoverResults_*.csv for errors
6. Start jobs             ->  Re-run with -StartJobs, or start from Azure portal
7. Re-run (idempotent)    ->  Re-run same command; existing resources are reused
8. Monitor                ->  Check job status in Azure portal or CLI
```

## Important Notes

- **RBAC propagation** may take 5–10 minutes before jobs succeed. If jobs fail immediately after setup, wait and retry
- **Max concurrent jobs** is capped at 10 to avoid overwhelming the Storage Mover service
- **System containers** (`$logs`, `$blobchangefeed`, `$web`, `$root`, etc.) are automatically skipped
- **No agent required** — blob-to-blob Storage Mover jobs are handled entirely by the Azure service
- Cross-subscription scenarios are supported

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
