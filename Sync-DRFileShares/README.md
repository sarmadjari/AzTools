# Sync-DRFileShares.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 1.0 | **Date:** 2026-03-10

Syncs Azure File Shares from source to destination storage accounts using `azcopy sync`. Compares source vs destination and transfers only changed files — much faster on subsequent runs than `azcopy copy`. Supports Additive (default, no deletes) and Mirror (syncs deletions) modes.

Data flows directly between Azure storage endpoints (server-side copy) — nothing passes through the client machine.

---

## Disclaimer

> **This script is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with this script or the use or other dealings in this script.**

This script is shared strictly as a **proof-of-concept (POC)** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

By using this script, you accept full responsibility for:

- Reviewing and customising the script to meet your specific environment and requirements
- Validating storage account pairs and file share mappings against your organisational standards
- **Understanding the implications of Mirror mode** (`--delete-destination=true`) which permanently removes files on the destination that do not exist on the source
- Applying appropriate security hardening, access controls, network restrictions, and compliance policies
- Ensuring data residency, sovereignty, and regulatory requirements are met
- Testing in lower environments (development / staging) before running against production
- Following your organisation's approved change management, deployment, and operational practices

> **Always run with `-DryRun` first to review planned changes before executing live.**
> **Use `-SyncMode "Additive"` (default) unless you explicitly need deletion propagation.**

---

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated (`az login`)
- **AzCopy v10+** installed and in PATH
- **PowerShell 7+** (`pwsh`) — available in Azure Cloud Shell
- Permissions: Contributor or Storage Account Contributor on both source and destination subscriptions
- **Storage Account Key Operator Service Role** (or Contributor) on both source and destination for key retrieval and SAS token generation
- Both source and destination accounts must have `allowSharedKeyAccess` enabled (the script detects and reports this clearly if disabled)
- **Both source and destination accounts must already exist** — use `Create-DRFileShareAccounts.ps1` to create them first

## CSV Format

Same CSV format as all other DR scripts:

```csv
SourceResourceId,DestStorageAccountName,DestResourceGroupName
/subscriptions/xxx/resourceGroups/rg-prod/providers/Microsoft.Storage/storageAccounts/stprod01,stdr001,rg-dr-switzerlandnorth
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
| `-DestSubscriptionId` | No | Destination subscription ID. Defaults to the source subscription |
| `-SyncMode` | No | `Additive` (default) or `Mirror`. Additive never deletes. Mirror syncs deletions |
| `-DryRun` | No | Dry run — shows what would be synced without making changes |

## Sync Mode

| Mode | Changed Files | New Files | Deleted Files (on source) | Extra Files (on dest) |
|---|---|---|---|---|
| **Additive** (default) | Synced to dest | Copied to dest | **Kept** on dest | **Kept** on dest |
| **Mirror** | Synced to dest | Copied to dest | **Deleted** from dest | **Deleted** from dest |

> **Warning:** Mirror mode permanently removes files from the destination. Use only when you explicitly need an exact replica.

## Usage Examples

### Basic sync (Additive — no deletes)

```powershell
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"
```

### Dry run (preview changes without syncing anything)

```powershell
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DryRun
```

### Mirror mode (sync with deletions)

```powershell
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -SyncMode "Mirror"
```

### Cross-subscription

```powershell
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Pre-Validation

Before any Azure operations begin, the script validates **all rows** in the CSV upfront:

| Check | Details |
|---|---|
| ARM Resource ID format | Must match `/subscriptions/.../storageAccounts/...` pattern |
| Destination account name | Must be 3-24 characters, lowercase alphanumeric only |
| Duplicate source-dest pairs | No two rows can have the same source-dest combination |
| Self-reference | Source and destination cannot be the same account |
| Empty fields | All three columns must not be empty |

## What the Script Does

For each row in the CSV:

| Step | Action |
|---|---|
| 1 | Parse source ARM Resource ID, determine destination subscription |
| 2 | Validate source account exists, capture firewall settings |
| 3 | Look up destination account — fail if not found, capture firewall settings |
| 4 | List source file shares via **ARM REST API** (bypasses source firewall) |
| 5 | Generate SAS tokens (4h expiry) for both accounts via management plane |
| 6 | Temporarily open source firewall if restrictive (for AzCopy data transfer) |
| 7 | Temporarily open dest firewall if restrictive (for AzCopy data transfer) |
| 8 | `azcopy sync` each share — server-side copy between Azure endpoints |
| 9 | Restore source firewall (`try/finally` — always restored, even on error) |
| 10 | Restore dest firewall (`try/finally` — always restored, even on error) |

### AzCopy sync vs AzCopy copy

| Aspect | `azcopy copy` (DR creation script) | `azcopy sync` (this script) |
|---|---|---|
| Comparison | Copies everything each time | Compares source vs dest, copies only changes |
| Re-run speed | Slow (re-transfers unchanged files) | Fast (skips unchanged files) |
| Deletions | Never | Optional (Mirror mode) |
| Purpose | Initial DR copy | Ongoing sync |

### Properties Preserved

| Property | Preserved |
|---|---|
| SMB permissions (NTFS ACLs) | Yes (`--preserve-smb-permissions=true`) |
| SMB metadata (timestamps, attributes) | Yes (`--preserve-smb-info=true`) |
| File content | Yes |
| Directory structure | Yes (`--recursive=true`) |

### Firewall Handling

Both source and destination firewalls are handled:

1. **Source firewall**: AzCopy needs to read source data (data-plane access required)
2. **Destination firewall**: AzCopy needs to read dest for comparison AND write changes
3. Both are opened before sync and restored in a `try/finally` block — **guaranteed restoration** even if AzCopy fails
4. SAS tokens are generated via management-plane key retrieval (bypasses firewall)

## Idempotent / Safe to Re-run

The script is designed for repeated execution:

- **Unchanged files** are skipped by `azcopy sync` (fast re-runs)
- **Firewalls** are always restored, even on error
- **SAS tokens** are cleaned up in every code path
- **No side effects** — the script only syncs data, never creates/deletes accounts or shares

## Running in Production

### Option 1: Azure Container Instances + Logic Apps (Recommended)

The most cost-effective and reliable production approach:

```
Logic Apps (Schedule Trigger: every 1h / 4h / daily)
  |
  v
Azure Container Instance (PowerShell 7 + AzCopy)
  |
  v
Runs Sync-DRFileShares.ps1
  |
  v
Container exits when done (pay only for runtime)
```

**Dockerfile example:**

```dockerfile
FROM mcr.microsoft.com/azure-powershell:latest
RUN curl -L https://aka.ms/downloadazcopy-v10-linux | tar xz --strip-components=1 -C /usr/local/bin
COPY Sync-DRFileShares.ps1 /scripts/
COPY resources.csv /scripts/
WORKDIR /scripts
CMD ["pwsh", "./Sync-DRFileShares.ps1", "-CsvPath", "./resources.csv"]
```

**Why ACI:**

| Benefit | Details |
|---|---|
| No timeout limits | Runs as long as needed (hours for large shares) |
| No VM to manage | Fully managed, no patching, no maintenance |
| Minimal cost | ~$0.013/hour for 1 vCPU. A 15-min sync every 4h costs ~$0.02/month |
| Managed Identity | Secure authentication without storing credentials |
| Built-in logging | Container logs sent to Azure Monitor |
| Restart on failure | Auto-restart policies available |

### Option 2: Azure VM + cron / Task Scheduler

If you already have a VM:

**Linux (cron):**
```bash
# Every 4 hours
0 */4 * * * /usr/bin/pwsh /opt/scripts/Sync-DRFileShares.ps1 -CsvPath "/opt/scripts/resources.csv" >> /var/log/dr-sync.log 2>&1
```

**Windows (Task Scheduler):**
```powershell
# Create scheduled task — every 4 hours
$Action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-File C:\Scripts\Sync-DRFileShares.ps1 -CsvPath C:\Scripts\resources.csv"
$Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 4) -Once -At (Get-Date)
Register-ScheduledTask -TaskName "DR-FileShare-Sync" -Action $Action -Trigger $Trigger -RunLevel Highest
```

### Option 3: Manual / On-Demand

```powershell
# Run directly from Cloud Shell or any terminal
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"
```

### Production Scheduling Options Comparison

| Approach | AzCopy Support | Max Runtime | Cost/Month | Operational Overhead |
|---|---|---|---|---|
| **ACI + Logic Apps** | Full | Unlimited | ~$1–5 | Low (recommended) |
| **Azure VM + cron** | Full | Unlimited | $30–50 (VM) | High (VM management) |
| **Azure Automation (Hybrid Worker)** | Full | Unlimited | $30–50 (VM) | Medium (use `Setup-SyncAutomation.ps1`) |
| **Azure Functions** | Limited | 5 min (Consumption) | Low | Low — but timeout is a blocker |
| **Azure Automation (cloud)** | No azcopy in sandbox | 3 hours | ~$0.002/job | Low — but can't run azcopy |

> **Note:** When using `-HybridWorkerVMResourceId`, `Setup-SyncAutomation.ps1` automatically detects and installs any missing prerequisites (Azure CLI, AzCopy, PowerShell 7) on the VM via `az vm run-command invoke`. For existing Hybrid Worker Groups (`-HybridWorkerGroup`), ensure the VM has these tools pre-installed.

## Running in Azure Cloud Shell

Azure Cloud Shell has a 20-minute idle timeout. For long-running syncs, use `tmux`:

```bash
tmux new -s dr-sync
pwsh ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"
# If disconnected: tmux attach -t dr-sync
```

## Output

The script exports a timestamped results CSV: `DRFileShareSyncResults_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SourceAccount` | Source storage account name |
| `DestAccount` | Destination storage account name |
| `DestResourceGroup` | Destination resource group |
| `DestSubscription` | Destination subscription ID |
| `SharesSynced` | Number of shares successfully synced |
| `SharesFailed` | Number of shares that failed to sync |
| `SyncMode` | `Additive` or `Mirror` |
| `Status` | `Completed`, `PartialFailure`, `Failed`, `Skipped`, or `DryRun` |
| `Notes` | Error or skip reason |

## Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `allowSharedKeyAccess=false` | Source or destination account has shared key access disabled by policy | Enable shared key access on the account, or contact your security team |
| `Failed to retrieve key` | Missing RBAC permissions for key listing | Assign **Storage Account Key Operator Service Role** or **Contributor** on the resource group |
| `AzCopy failed (exit code: N)` | Data-plane sync failure | Check: firewall timing (wait and retry), private endpoints blocking public copy, or share-level permissions |
| `Source account not found` | Source account doesn't exist or wrong subscription | Verify the ARM Resource ID in the CSV |
| `Destination account not found` | Destination account doesn't exist yet | Run `Create-DRFileShareAccounts.ps1` first to create destination accounts |

## Workflow

```
1. Create DR accounts     ->  Create-DRFileShareAccounts.ps1 (initial setup — run once)
2. Dry run sync           ->  ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DryRun
3. First sync             ->  ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"
4. Review results CSV     ->  Check DRFileShareSyncResults_*.csv for errors
5. Schedule recurring     ->  ACI + Logic Apps, cron, or Task Scheduler
6. (Optional) Mirror mode ->  ./Sync-DRFileShares.ps1 ... -SyncMode "Mirror"
```

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
