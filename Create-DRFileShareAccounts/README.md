# Create-DRFileShareAccounts.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 1.0 | **Date:** 2026-03-10

Creates DR (Disaster Recovery) file share storage accounts from a CSV mapping file. Reads source storage account configurations and replicates them in a target region, including all file shares with quota and access tier. Copies data using AzCopy server-side (S2S) copy, preserving SMB/NTFS permissions and directory structures.

---

## Disclaimer

> **This script is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with this script or the use or other dealings in this script.**

This script is shared strictly as a **proof-of-concept (POC) / sample code** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

**No Support or Maintenance Obligation:** The author(s) are under no obligation to provide support, maintenance, updates, enhancements, or bug fixes. No obligation exists to respond to issues, feature requests, or pull requests. If this script requires modifications for your environment, you are solely responsible for implementing them.

By using this script, you accept full responsibility for:

- **Determining whether this script is suitable for your intended use case**
- Reviewing and customising the script to meet your specific environment and requirements
- Validating storage account naming conventions, SKU selections, and file share quotas against your organisational standards
- Applying appropriate security hardening, access controls, network restrictions, and compliance policies to all storage accounts in both source and destination regions
- Ensuring data residency, sovereignty, and regulatory requirements are met for the target region before executing any data copy
- Testing and validating in lower environments (development / staging) before running against production storage accounts
- Verifying data copy completeness, RPO targets, and failover procedures are fit for purpose prior to production use
- Following your organisation's approved change management, deployment, and operational practices
- **All outcomes resulting from the use of this script, including but not limited to data loss, service disruption, security incidents, compliance violations, or financial impact**

> **Always run with the `-DryRun` flag first to review planned changes before executing live.**

---

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated (`az login`)
- **AzCopy v10+** installed and available in PATH
- **PowerShell 7+** (`pwsh`) — available in Azure Cloud Shell
- Permissions: Contributor or Storage Account Contributor on both source and destination subscriptions
- **Storage Account Key Operator Service Role** (or Contributor) on source accounts for key retrieval and SAS token generation
- Source accounts must have `allowSharedKeyAccess` enabled (the script detects and reports this clearly if disabled)

## CSV Format

Create a CSV file with the following headers:

```csv
SourceResourceId,DestStorageAccountName,DestResourceGroupName
/subscriptions/xxx/resourceGroups/rg-files-prod/providers/Microsoft.Storage/storageAccounts/stfileprod01,stfiledr001,rg-dr-files-switzerlandnorth
/subscriptions/xxx/resourceGroups/rg-files-prod/providers/Microsoft.Storage/storageAccounts/stfileprod02,stfiledr002,rg-dr-files-switzerlandnorth
```

| Column | Description |
|---|---|
| `SourceResourceId` | Full ARM Resource ID of the source storage account |
| `DestStorageAccountName` | Name for the destination storage account (3-24 chars, lowercase alphanumeric) |
| `DestResourceGroupName` | Resource group for the destination account (created automatically if it doesn't exist) |

A sample CSV is provided: `resources-sample.csv`

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-CsvPath` | Yes | Path to the CSV mapping file |
| `-DestRegion` | Yes | Azure region for destination accounts (e.g., `switzerlandnorth`) |
| `-DestSubscriptionId` | No | Destination subscription ID. Defaults to the source subscription |
| `-DryRun` | No | Dry run — shows what would be created without making changes |

## Usage Examples

### Create DR accounts in the same subscription

```powershell
./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth"
```

### Create DR accounts in a different subscription

```powershell
./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Dry run (preview changes without creating anything)

```powershell
./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DryRun
```

## Pre-Validation

Before any Azure operations begin, the script validates **all rows** in the CSV upfront:

| Check | Details |
|---|---|
| ARM Resource ID format | Must match `/subscriptions/.../storageAccounts/...` pattern |
| Destination account name length | Must be 3-24 characters |
| Destination account name characters | Must be lowercase alphanumeric only (`a-z`, `0-9`) |
| Source == Destination name collision | Source and destination cannot have the same name (globally unique) |
| Duplicate destination names | No two rows can target the same destination account name |
| Empty fields | SourceResourceId, DestStorageAccountName, DestResourceGroupName must not be empty |

If any validation errors are found, the script reports **all errors at once** and exits before making any Azure API calls.

## What the Script Does

For each row in the CSV:

| Step | Action |
|---|---|
| 0 | **Pre-validate all rows** (names, ARM IDs, duplicates) — abort if errors found |
| 1 | Parse source ARM Resource ID, validate destination account name |
| 2 | Read source properties (kind, SKU, HNS, TLS, access tier, networking) |
| 3 | Ensure destination resource group exists (create if missing, using `-DestRegion`) |
| 4 | Create destination storage account (with default open networking) |
| 5 | List source file shares via **ARM API** (bypasses source firewall) |
| 6 | Create matching file shares on destination via **ARM** (`az storage share-rm create`) — replicates quota and access tier |
| 7 | Generate SAS tokens, temporarily open source firewall if needed, **AzCopy S2S copy** each share |
| 8 | Restore source firewall (if it was opened) |
| 9 | Apply source networking settings (firewall) to destination **LAST** — after all operations are complete |

**Why ARM API for share listing:** Source storage accounts often have `defaultAction=Deny` firewall. The data plane is blocked by the firewall, but the ARM Management Plane API (`management.azure.com`) bypasses it — no need to modify source firewall settings for share listing.

**Why `az storage share-rm create`:** The `-rm` variant uses the ARM management plane, which bypasses the destination account's firewall. No need to wait for firewall propagation.

**Why networking is applied last:** If the source has firewall restrictions (defaultAction=Deny), applying them before creating shares and copying data would block operations on the newly created destination account.

### Properties Replicated from Source

| Property | Replicated |
|---|---|
| Kind (StorageV2, FileStorage, etc.) | Yes |
| SKU (Standard_LRS, Premium_LRS, etc.) | Yes |
| Hierarchical Namespace (HNS/ADLS Gen2) | Yes |
| Minimum TLS version | Yes |
| Access tier (Hot, Cool) | Yes (StorageV2 only; skipped for Premium SKUs, FileStorage, BlockBlobStorage, and classic Storage v1) |
| Allow blob public access | Yes |
| Firewall (default action, bypass rules) | Yes |
| Public network access setting | Yes |
| Tags (on storage account) | Yes (copied from source, updated on re-run) |
| Tags (on resource group) | Yes (copied from source RG, updated on re-run) |
| File shares (names, quota, access tier) | Yes |
| Private endpoints | No (separate step) |
| Data inside file shares | Yes (via AzCopy S2S copy) |

## AzCopy Server-Side Copy (S2S)

The script uses AzCopy's **server-side copy** mode (`azcopy copy` with `--s2s-preserve-properties`). Data flows directly between Azure storage endpoints without passing through the client machine.

### Copy Behavior

| Setting | Value |
|---|---|
| Copy mode | `azcopy copy` (server-side / S2S) |
| SMB permissions | Preserved (`--preserve-smb-permissions=true`) |
| SMB info (timestamps, attributes) | Preserved (`--preserve-smb-info=true`) |
| S2S properties | Preserved (`--s2s-preserve-properties=true`) |
| S2S access tier | Preserved (`--s2s-preserve-access-tier=true`) |
| Delete propagation | **No** — additive only. Files deleted from source remain on destination |
| Recursive | Yes (`--recursive`) |
| SAS token expiry | 4 hours (short-lived, regenerated per account pair) |

### Source Firewall Handling

AzCopy S2S copy requires data-plane access to both source and destination. If the source account has `defaultAction=Deny`, the script:

1. Saves the original source firewall settings
2. Temporarily opens the source firewall
3. Runs AzCopy S2S copy for all shares
4. **Restores the original source firewall** — even if AzCopy fails mid-way (wrapped in `try/finally`)

The destination account is created with open networking and locked down **LAST** (after all operations complete).

## Idempotent / Safe to Re-run

The script is safe to run multiple times on the same CSV:

- **Existing storage accounts** are skipped (not recreated), but new shares are still synced
- **Existing file shares** on the destination are not affected (additive copy)
- **Existing resource groups** are detected and reused
- **Existing accounts with firewall** are auto-detected — the script temporarily opens the firewall, syncs shares and copies data, then restores the original firewall settings. Even if the script fails mid-way, the error handler restores the firewall

## Running in Azure Cloud Shell

Azure Cloud Shell has a 20-minute idle timeout. For long-running operations, use `tmux` to keep the session alive:

```bash
# 1. Start a tmux session
tmux new -s dr-fileshare

# 2. Run the script (pwsh launches PowerShell inline)
pwsh ./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth"

# 3. If browser disconnects, reconnect to Cloud Shell and reattach:
tmux attach -t dr-fileshare
```

| tmux Command | What it does |
|---|---|
| `tmux new -s dr-fileshare` | Create a named session |
| `tmux attach -t dr-fileshare` | Reattach after disconnect |
| `tmux ls` | List active sessions |
| `Ctrl+B` then `D` | Detach manually (script keeps running) |

## Output

The script exports a timestamped results CSV: `DRFileShareResults_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SourceAccount` | Source storage account name |
| `DestAccount` | Destination storage account name |
| `DestResourceGroup` | Destination resource group |
| `DestRegion` | Destination region |
| `DestSubscription` | Destination subscription ID |
| `AccountStatus` | `Created`, `AlreadyExists`, `CreatedNoCopy`, `ExistsNoCopy`, `Skipped`, or `Failed` |
| `SharesCreated` | Number of file shares created on destination |
| `SharesCopied` | Number of file shares successfully copied via AzCopy S2S |
| `NetworkingConfig` | Networking settings applied |
| `Notes` | Detailed error/skip reasons (includes Azure Policy details for failures) |

## Smart Error Handling

The script handles common issues automatically instead of failing:

| Issue | How it's handled |
|---|---|
| **Access tier not supported** | Auto-retries without `--access-tier` when the source account type doesn't support it (Premium, FileStorage, BlockBlobStorage, Storage v1). Account is created successfully. |
| **Storage account name globally taken** | Checks name availability (`az storage account check-name`) before creating. Fails fast with a clear message instead of hitting the Azure API error. |
| **Failed to retrieve source key** | Skips data copy gracefully — account and shares are still created. Status shows `CreatedNoCopy` or `ExistsNoCopy`. Fix RBAC and re-run to copy data. |
| **`allowSharedKeyAccess=false` on source** | Same as above — skips data copy, creates account and shares. Enable shared key access and re-run. |

## Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `Name globally unavailable` | Destination name already exists in another subscription | Use a different destination name in the CSV |
| `allowSharedKeyAccess=false` | Source account has shared key access disabled by policy | Enable shared key access on the source account, or contact your security team. Re-run the script to copy data. |
| `Failed to retrieve key for source account` | Missing RBAC permissions for key listing | Assign **Storage Account Key Operator Service Role** or **Contributor** on the source resource group. Re-run the script to copy data. |
| `AzCopy failed (exit code: N)` | Data-plane copy failure | Check: firewall timing (wait and retry), private endpoints blocking public copy, or share-level permissions |
| `AZURE POLICY VIOLATION` | Azure Policy blocking account creation | Check the policy name and assignment in the error message; work with your governance team |

## Workflow

```
1. Prepare CSV            ->  Map source accounts to destination names and RGs
2. Dry run                ->  ./Create-DRFileShareAccounts.ps1 ... -DryRun
3. Create accounts + copy ->  ./Create-DRFileShareAccounts.ps1 ...
4. Review results CSV     ->  Check DRFileShareResults_*.csv for errors
5. Fix any failures       ->  Check Notes column for Azure Policy or other issues
6. Re-run (idempotent)    ->  Re-run same command; created accounts are skipped
7. (If needed) Sync later ->  Re-run same command; firewall handled automatically
```

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
