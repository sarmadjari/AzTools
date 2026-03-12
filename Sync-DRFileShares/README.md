# Sync-DRFileShares.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 2.0 | **Date:** 2026-03-11

Syncs Azure File Shares from source to destination storage accounts using `azcopy sync`. Compares source vs destination and transfers only changed files — much faster on subsequent runs than `azcopy copy`. Supports Additive (default, no deletes) and Mirror (syncs deletions) modes.

Data flows directly between Azure storage endpoints (server-side copy) — nothing passes through the client machine.

**Dual-mode script** — works both interactively and as an Azure Automation Runbook:

| Mode | Authentication | CSV Source | Output | DryRun |
|---|---|---|---|---|
| **Manual** | Existing `az login` | `-CsvPath` parameter | Colored console + results CSV | Yes |
| **Automation** | Managed Identity | Automation Variable (`SyncCSVContent`) | Plain-text job logs | Yes |

The script auto-detects which mode it's running in — no configuration needed.

---

## Disclaimer

> **This script is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with this script or the use or other dealings in this script.**

This script is shared strictly as a **proof-of-concept (POC) / sample code** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

**Not an Official Product:** This script is an independent, personal work created and shared by an individual to assist the community. It is **NOT** an official product, service, or deliverable of any company, employer, or organisation. It is not endorsed, certified, vetted, or supported by any company or vendor, including Microsoft. Any use of company names, product names, or trademarks is solely for identification purposes and does not imply affiliation, sponsorship, or endorsement.

**No Support or Maintenance Obligation:** The author(s) are under no obligation to provide support, maintenance, updates, enhancements, or bug fixes. No obligation exists to respond to issues, feature requests, or pull requests. If this script requires modifications for your environment, you are solely responsible for implementing them.

**Configuration and Settings Responsibility:** You are solely responsible for verifying that all parameters, settings, and configurations used with this script are correct and appropriate for your environment. The author(s) make no guarantees that default values, example configurations, or suggested settings are suitable for any specific environment. Incorrect configuration may result in data loss, service disruption, security vulnerabilities, or unintended changes to your Azure resources.

By using this script, you accept full responsibility for:

- **Determining whether this script is suitable for your intended use case**
- Reviewing and customising the script to meet your specific environment and requirements
- **Verifying that all parameters, settings, and configurations are correct and appropriate for your environment before each execution**
- Validating storage account pairs and file share mappings against your organisational standards
- **Understanding the implications of Mirror mode** (`--delete-destination=true`) which permanently removes files on the destination that do not exist on the source
- Applying appropriate security hardening, access controls, network restrictions, and compliance policies to all storage accounts
- Ensuring data residency, sovereignty, and regulatory requirements are met
- Testing and validating in lower environments (development / staging) before running against production storage accounts
- Following your organisation's approved change management, deployment, and operational practices
- **All outcomes resulting from the use of this script, including but not limited to data loss, service disruption, security incidents, compliance violations, or financial impact**

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
- **Both source and destination storage accounts must already exist** — use `Create-DRFileShareAccounts.ps1` to create them first. Missing file shares on the destination are auto-created by the sync script.

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

All parameters are optional. In Automation mode, values fall back to Automation Variables.

| Parameter | Required | Description |
|---|---|---|
| `-CsvPath` | Manual: Yes | Path to the CSV mapping file. In Automation mode, falls back to `SyncCSVContent` Automation Variable |
| `-DestSubscriptionId` | No | Destination subscription ID. Defaults to the source subscription. In Automation mode, falls back to `DestSubscriptionId` Automation Variable |
| `-SyncMode` | No | `Additive` (default) or `Mirror`. In Automation mode, falls back to `SyncMode` Automation Variable |
| `-DryRun` | No | Dry run — shows what would be synced without making changes |

## Sync Mode

| Mode | Changed Files | New Files | Deleted Files (on source) | Extra Files (on dest) |
|---|---|---|---|---|
| **Additive** (default) | Synced to dest | Copied to dest | **Kept** on dest | **Kept** on dest |
| **Mirror** | Synced to dest | Copied to dest | **Deleted** from dest | **Deleted** from dest |

> **Warning:** Mirror mode permanently removes files from the destination. Use only when you explicitly need an exact replica.

## Usage Examples

### Manual Mode

```powershell
# Basic sync (Additive — no deletes)
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"

# Dry run (preview changes without syncing anything)
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DryRun

# Mirror mode (sync with deletions)
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -SyncMode "Mirror"

# Cross-subscription
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Automated Sync (Azure Automation + Hybrid Worker)

Use `Setup-SyncAutomation.ps1` to deploy everything in one command:

```powershell
# Simplest — auto-creates a VM as Hybrid Worker
./Setup-SyncAutomation.ps1 `
    -AutomationAccountName "aa-dr-sync" `
    -ResourceGroupName "rg-automation" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -ScheduleIntervalHours 4
```

If you already have a VM, pass its Resource ID instead:

```powershell
./Setup-SyncAutomation.ps1 `
    -AutomationAccountName "aa-dr-sync" `
    -ResourceGroupName "rg-automation" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -HybridWorkerVMResourceId "/subscriptions/.../virtualMachines/vm-hybrid-worker" `
    -ScheduleIntervalHours 4
```

This creates and configures:

| Resource | Details |
|---|---|
| Automation Account | Hosts the Runbook, schedule, and variables |
| VM (auto-created if needed) | Small Linux VM (Standard_B2s) — override with `-VMSize` / `-VMOsType` |
| System-Assigned Managed Identity | Secure auth — no credentials stored |
| Hybrid Runbook Worker | VM-based execution (azcopy requires a real host, not a cloud sandbox) |
| Recurring schedule | Configurable interval (default: every 6 hours) |
| Automation Variables | `SyncCSVContent` (encrypted), `SyncMode`, `DestSubscriptionId` |
| RBAC | Storage Account Contributor on all source and destination resource groups |

Prerequisites (Azure CLI, AzCopy, PowerShell 7) are automatically installed on the VM. For existing Hybrid Worker Groups (`-HybridWorkerGroup`), ensure the VM has these tools pre-installed.

To change the sync frequency, re-run `Setup-SyncAutomation.ps1` with a different `-ScheduleIntervalHours` value.

### Updating the CSV After Deployment

When you add or remove storage accounts from the CSV after the Automation Account and Hybrid Worker are already deployed, you need to update the `SyncCSVContent` Automation Variable with the new CSV content. There are two ways:

**Option 1 — Re-run Setup-SyncAutomation.ps1 (recommended)**

```powershell
./Setup-SyncAutomation.ps1 `
    -AutomationAccountName "aa-dr-sync" `
    -ResourceGroupName "rg-automation" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources-updated.csv" `
    -HybridWorkerGroup "my-worker-group"
```

The script is idempotent — it skips everything that already exists (Automation Account, VM, schedule, RBAC) and only overwrites the `SyncCSVContent` variable with the new CSV content. If the updated CSV references **new resource groups**, the script also assigns the required RBAC (`Storage Account Contributor`) on those new scopes automatically.

**Option 2 — Update only the variable (quick, no RBAC)**

If you are only removing accounts, or the new accounts are in resource groups that already have RBAC, you can update just the variable directly:

**Azure Portal → Automation Account → Variables → `SyncCSVContent` → Edit → paste the new CSV content → Save**

> **Note:** If the new CSV references resource groups that were not in the original CSV, the Managed Identity will not have permissions on them and the sync will fail for those accounts. In that case, use Option 1.

The change takes effect immediately — the next scheduled Runbook execution reads `SyncCSVContent` fresh every time it runs. No restart or redeployment is needed.

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
| 2 | Validate source account exists, check `allowSharedKeyAccess`, capture firewall settings |
| 3 | Look up destination account — fail if not found, check `allowSharedKeyAccess`, capture firewall settings |
| 4 | List source file shares via **ARM REST API** (bypasses source firewall) |
| 4b | List destination file shares — **auto-create** any source shares missing on the destination (via `az storage share-rm create`, matching quota and access tier) |
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
- **New shares auto-created** — if a share exists on source but not on destination, it is created automatically with matching quota and access tier before syncing

## Output

### Manual Mode

The script exports a timestamped results CSV: `DRFileShareSyncResults_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SourceAccount` | Source storage account name |
| `DestAccount` | Destination storage account name |
| `DestResourceGroup` | Destination resource group |
| `DestSubscription` | Destination subscription ID |
| `SharesCreated` | Number of missing shares auto-created on destination |
| `SharesSynced` | Number of shares successfully synced |
| `SharesFailed` | Number of shares that failed to sync |
| `SyncMode` | `Additive` or `Mirror` |
| `Status` | `Completed`, `PartialFailure`, `Failed`, `Skipped`, or `DryRun` |
| `Notes` | Error or skip reason |

### Automation Mode

Output goes to the Azure Automation job log (plain text). No results CSV is exported — check job status in the Azure Portal.

## Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `allowSharedKeyAccess=false` | Source or destination account has shared key access disabled by policy | Enable shared key access on the account, or contact your security team |
| `Failed to retrieve key` | Missing RBAC permissions for key listing | Assign **Storage Account Key Operator Service Role** or **Contributor** on the resource group |
| `AzCopy failed (exit code: N)` | Data-plane sync failure | Check: firewall timing (wait and retry), private endpoints blocking public copy, or share-level permissions |
| `Source account not found` | Source account doesn't exist or wrong subscription | Verify the ARM Resource ID in the CSV |
| `Destination account not found` | Destination account doesn't exist yet | Run `Create-DRFileShareAccounts.ps1` first to create destination accounts |
| `No CSV source specified` | Neither `-CsvPath` provided nor running in Automation | Provide `-CsvPath` for manual runs, or deploy via `Setup-SyncAutomation.ps1` for automation |
| `SyncCSVContent is empty` | Automation Variable not configured | Re-run `Setup-SyncAutomation.ps1` to populate the variable |
| `Failed to authenticate via Managed Identity` | MI not enabled or missing RBAC | Ensure the Automation Account has a System-Assigned MI with Storage Account Contributor role |

## Workflow

```
1. Create DR accounts     ->  Create-DRFileShareAccounts.ps1 (initial setup — run once)
2. Dry run sync           ->  ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DryRun
3. First sync             ->  ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"
4. Review results CSV     ->  Check DRFileShareSyncResults_*.csv for errors
5. Automate               ->  ./Setup-SyncAutomation.ps1 (deploys Automation + Hybrid Worker + schedule)
6. (Optional) Mirror mode ->  Re-run Setup-SyncAutomation.ps1 with -SyncMode "Mirror"
```

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
