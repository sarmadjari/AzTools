# Create-DRBlobStorageAccounts.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 2.4 | **Date:** 2026-03-09

Creates DR (Disaster Recovery) blob storage accounts from a CSV mapping file. Reads source storage account configurations and replicates them in a target region, including all blob containers. Optionally configures Object Replication with replication monitoring enabled.

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
- Validating storage account naming conventions, SKU selections, and replication policies against your organisational standards
- Applying appropriate security hardening, access controls, network restrictions, and compliance policies to all storage accounts in both source and destination regions
- Ensuring data residency, sovereignty, and regulatory requirements are met for the target region before executing any replication
- Testing and validating in lower environments (development / staging) before running against production storage accounts
- Verifying replication policies, RPO targets, and failover procedures are fit for purpose prior to production use
- Following your organisation's approved change management, deployment, and operational practices
- **All outcomes resulting from the use of this script, including but not limited to data loss, service disruption, security incidents, compliance violations, or financial impact**

> **Always run with the `-DryRun` flag first to review planned changes before executing live.**

---

## Compatible Storage Account Types

The script supports creating DR copies of the following storage account types:

| Storage Account Type | Account Creation | Object Replication |
|---|---|---|
| **StorageV2** (General Purpose v2) | Yes | Yes |
| **BlobStorage** (legacy blob-only) | Yes | No (not supported by Azure) |
| **BlockBlobStorage** (Premium block blob) | Yes | Yes |
| **FileStorage** (Premium file shares) | Yes | No (no blob service) |
| **StorageV2 with HNS** (ADLS Gen2 / Data Lake) | Yes | No (not supported by Azure) |

> **Note:** Object Replication is only supported on **StorageV2** and **BlockBlobStorage** accounts without Hierarchical Namespace (HNS). If `-ConfigureObjectReplication` is used with an incompatible account type (e.g., BlobStorage, FileStorage, HNS-enabled), the script **automatically skips** the replication step for that account with a warning — the storage account and containers are still created successfully.

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated (`az login`)
- **PowerShell 7+** (`pwsh`) — available in Azure Cloud Shell
- Permissions: Contributor or Storage Account Contributor on both source and destination subscriptions
- If using `-ConfigureObjectReplication`: Storage Account Contributor on both source and destination

## CSV Format

Create a CSV file with the following headers:

```csv
SourceResourceId,DestStorageAccountName,DestResourceGroupName
/subscriptions/xxx/resourceGroups/rg-prod/providers/Microsoft.Storage/storageAccounts/starcgisprod01,starcgisdr001,rg-dr-switzerlandnorth
/subscriptions/xxx/resourceGroups/rg-prod/providers/Microsoft.Storage/storageAccounts/starcgisprod02,starcgisdr002,rg-dr-switzerlandnorth
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
| `-SyncContainers` | No | For existing accounts with firewall: temporarily opens firewall, syncs containers, restores firewall |
| `-ConfigureObjectReplication` | No | Enables Object Replication (versioning, change feed, replication policies with monitoring) |
| `-DryRun` | No | Dry run — shows what would be created without making changes |

## Usage Examples

### Create DR accounts in the same subscription

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth"
```

### Create DR accounts in a different subscription

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Dry run (preview changes without creating anything)

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DryRun
```

### Create accounts with Object Replication

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -ConfigureObjectReplication
```

### Add Object Replication later (re-run on existing accounts)

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -ConfigureObjectReplication
```

### Sync containers on existing accounts with firewall restrictions

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -SyncContainers
```

### Combine: sync containers + Object Replication on existing accounts

```powershell
./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -SyncContainers -ConfigureObjectReplication
```

## Pre-Validation

Before any Azure operations begin, the script validates **all rows** in the CSV upfront:

| Check | Details |
|---|---|
| ARM Resource ID format | Must match `/subscriptions/.../storageAccounts/...` pattern |
| Destination account name length | Must be 3-24 characters |
| Destination account name characters | Must be lowercase alphanumeric only (`a-z`, `0-9`) |
| Duplicate destination names | No two rows can target the same destination account name |
| Empty fields | SourceResourceId, DestStorageAccountName, DestResourceGroupName must not be empty |

If any validation errors are found, the script reports **all errors at once** and exits before making any Azure API calls. This lets you fix all issues in the CSV in one pass.

Example output:

```
[2026-03-09 10:00:00Z] [ERROR] ==================================================================
[2026-03-09 10:00:00Z] [ERROR]   PRE-VALIDATION FAILED: 3 error(s) found
[2026-03-09 10:00:00Z] [ERROR] ==================================================================
[2026-03-09 10:00:00Z] [ERROR]   Row 5: [DestStorageAccountName] 'szndbstoragev5unejoynrdss (25 chars)'
[2026-03-09 10:00:00Z] [ERROR]     -> Name must be 3-24 characters (got 25)
[2026-03-09 10:00:00Z] [ERROR]   Row 12: [DestStorageAccountName] 'stdr001'
[2026-03-09 10:00:00Z] [ERROR]     -> Duplicate destination name (first seen in row 3)
[2026-03-09 10:00:00Z] [ERROR]   Row 18: [SourceResourceId] '(empty)'
[2026-03-09 10:00:00Z] [ERROR]     -> SourceResourceId is empty
```

## What the Script Does

For each row in the CSV:

| Step | Action |
|---|---|
| 0 | **Pre-validate all rows** (names, ARM IDs, duplicates) — abort if errors found |
| 1 | Parse source ARM Resource ID, validate destination account name |
| 2 | Read source properties (kind, SKU, HNS, TLS, access tier, networking) |
| 3 | Ensure destination resource group exists (create if missing, using `-DestRegion`) |
| 4 | Create destination storage account (with default open networking) |
| 5 | List source containers via **ARM Management Plane API** (bypasses source firewall), skip system containers (`$logs`, `$blobchangefeed`, etc.) |
| 6 | Create matching containers on destination (while firewall is still open) |
| 7 | If `-ConfigureObjectReplication`: enable versioning, change feed, create replication policies with monitoring enabled (auto-skipped for incompatible account types or if 0 containers) |
| 8 | Apply source networking settings (firewall) **LAST** — after all operations are complete |

**Why ARM API for container listing:** Source storage accounts often have `defaultAction=Deny` firewall. The data plane (`az storage container list`) is blocked by the firewall, but the ARM Management Plane API (`management.azure.com`) bypasses it — no need to modify source firewall settings.

**Why networking is applied last:** If the source has firewall restrictions (defaultAction=Deny), applying them before creating containers would block container creation on the newly created destination account.

### Properties Replicated from Source

| Property | Replicated |
|---|---|
| Kind (StorageV2, BlobStorage, etc.) | Yes |
| SKU (Standard_LRS, Standard_GRS, etc.) | Yes |
| Hierarchical Namespace (HNS/ADLS Gen2) | Yes |
| Minimum TLS version | Yes |
| Access tier (Hot, Cool) | Yes |
| Allow blob public access | Yes |
| Firewall (default action, bypass rules) | Yes |
| Public network access setting | Yes |
| Tags (on storage account) | Yes (copied from source, updated on re-run) |
| Tags (on resource group) | Yes (copied from source RG, updated on re-run) |
| Blob containers (names) | Yes |
| Private endpoints | No (separate step) |
| Data inside containers | No (use AzCopy or Object Replication for data) |

## Progress and Error Reporting

### Console Output

Every log line includes a **progress counter** showing which account is being processed:

```
[2026-03-09 10:05:00Z] [INFO] [3/32] starcgisprod03 -> starcgisdr003
[2026-03-09 10:05:01Z] [INFO] [3/32]   Reading source properties: starcgisprod03...
[2026-03-09 10:05:05Z] [SUCCESS] [3/32]   Storage account 'starcgisdr003' created.
[2026-03-09 10:05:10Z] [SUCCESS] [3/32]   Done: starcgisprod03 -> starcgisdr003 (45s)
```

Each account shows elapsed time on completion. The final summary includes total elapsed time.

### Error Reporting

When an account fails (e.g., Azure Policy violation), the script captures **detailed error messages** from the Azure CLI, including:

- **Azure Policy violations**: Policy name, assignment name, and error message
- **Location restrictions**: Which locations are allowed vs. requested
- **Tag requirements**: Which tags are required by policy
- **Other Azure errors**: Full error detail from the CLI

Failed accounts are reported in:
1. **Console**: Real-time error messages during execution
2. **Summary**: A "FAILED ACCOUNTS DETAIL" section at the end listing all failures with reasons
3. **Results CSV**: The `Notes` column contains the full error detail for each failed account

Example CSV Notes for a policy failure:
```
AZURE POLICY VIOLATION: Policy='Allowed locations' Assignment='Restrict to UAE regions' Message='Resource starcgisdr005 is not allowed in switzerlandnorth'
```

## Idempotent / Safe to Re-run

The script is safe to run multiple times on the same CSV:

- **Existing storage accounts** are skipped (not recreated), but new containers are still synced
- **Existing containers** on the destination are not affected
- **Existing resource groups** are detected and reused
- **`-ConfigureObjectReplication`** can be added on a later run without recreating accounts
- **`-SyncContainers`** temporarily opens the firewall on existing accounts, syncs containers, then restores the original firewall settings. Even if the script fails mid-way, the error handler restores the firewall

## Object Replication

When `-ConfigureObjectReplication` is specified, the script first checks if the account type is compatible. For **compatible accounts only**, it automatically enables the required prerequisites and creates the replication policies. Incompatible accounts are skipped entirely — no changes are made to them:

| Setting | Source | Destination | Why |
|---|---|---|---|
| Blob versioning | **Enabled by script** | **Enabled by script** | Required by Azure before creating replication policies |
| Change feed | **Enabled by script** | Not required | Required by Azure on source to track blob changes |
| Replication policy | Applied (per container pair) | Created first, then mirrored to source | Both accounts must have the policy for replication to start |
| Replication monitoring | **Enabled by script** | **Enabled by script** | Unlocks per-rule replication metrics and status tracking in Azure Monitor |

### Copy Scope: Everything (All Blobs)

Object Replication asynchronously copies **all blobs** (existing + new) from source to destination. The replication rules are configured with `minCreationTime = "1601-01-01T00:00:00Z"` which tells Azure to replicate **everything** — all existing data plus newly created blobs.

> **Important:** In the Azure REST API, omitting the `minCreationTime` filter defaults to **"Only new objects"** (only blobs created after the policy is applied). To get **"Everything"**, the filter must be explicitly set to `1601-01-01T00:00:00Z` (the earliest possible date).

### Configuration Direction: Destination First, Then Source

The script automatically configures **both** accounts in two steps:

1. **Creates the policy on the DESTINATION account** first (using policy ID `default` for new, or existing ID for updates)
2. **Applies the same policy to the SOURCE account** using the policy ID returned from step 1

**Both steps are required.** If only the destination has the policy, replication will **NOT** start. The source account needs the policy so Azure knows to watch for changes and replicate blobs to the destination. The script handles both steps automatically.

> **Note:** This is the opposite of the Azure Portal UI (which starts from the source account and auto-creates on the destination). Under the hood, both approaches result in the policy existing on both accounts.

### Replication Monitoring (Metrics)

Replication monitoring is **enabled by default** on all policies created by the script. This sets `metrics.enabled = true` on the policy, which unlocks:

- **Per-rule replication status** — track whether each container pair is actively replicating
- **Replication lag metrics** — monitor how far behind the destination is from the source
- **Azure Monitor integration** — query replication health via metrics, alerts, and dashboards

> **Note:** Replication monitoring requires ARM API version `2024-01-01` or later. The script uses this API version for all Object Replication policy operations.

### Supported Account Types for Object Replication

- **Supported:** StorageV2 (General Purpose v2), BlockBlobStorage (Premium block blob)
- **NOT supported:** BlobStorage (legacy blob-only), Accounts with Hierarchical Namespace enabled (HNS / ADLS Gen2), FileStorage
- **Auto-skip:** The script automatically detects incompatible account types and skips the Object Replication step with a warning. The storage account and containers are still created — only the replication configuration is skipped.

## Running in Azure Cloud Shell

Azure Cloud Shell has a 20-minute idle timeout. For long-running operations, use `tmux` to keep the session alive:

```bash
# 1. Start a tmux session
tmux new -s dr-setup

# 2. Run the script (pwsh launches PowerShell inline)
pwsh ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -SyncContainers -ConfigureObjectReplication

# 3. If browser disconnects, reconnect to Cloud Shell and reattach:
tmux attach -t dr-setup
```

| tmux Command | What it does |
|---|---|
| `tmux new -s dr-setup` | Create a named session |
| `tmux attach -t dr-setup` | Reattach after disconnect |
| `tmux ls` | List active sessions |
| `Ctrl+B` then `D` | Detach manually (script keeps running) |

## Output

The script exports a timestamped results CSV: `DRBlobStorageResults_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SourceAccount` | Source storage account name |
| `DestAccount` | Destination storage account name |
| `DestResourceGroup` | Destination resource group |
| `DestRegion` | Destination region |
| `DestSubscription` | Destination subscription ID |
| `AccountStatus` | `Created`, `AlreadyExists`, `Skipped`, or `Failed` |
| `ContainersCreated` | Number of containers created on destination |
| `ContainersSkipped` | Number of system containers skipped |
| `NetworkingConfig` | Networking settings applied |
| `ObjectReplication` | `Configured`, `Updated`, `N/A`, `Skipped (incompatible)`, `Skipped (no containers)`, `Failed`, or `DryRun` |
| `Notes` | Detailed error/skip reasons (includes Azure Policy details for failures) |

## Workflow

```
1. Prepare CSV            ->  Map source accounts to destination names and RGs
2. Dry run                ->  ./Create-DRBlobStorageAccounts.ps1 ... -DryRun
3. Create accounts        ->  ./Create-DRBlobStorageAccounts.ps1 ...
4. Review results CSV     ->  Check DRBlobStorageResults_*.csv for errors
5. Fix any failures       ->  Check Notes column for Azure Policy or other issues
6. Re-run (idempotent)    ->  Re-run same command; created accounts are skipped
7. (If needed) Sync later ->  Re-run with -SyncContainers (for accounts with firewall)
8. (Optional) Add OR      ->  Re-run with -ConfigureObjectReplication
9. (Optional) Sync data   ->  Use AzCopy or Object Replication for data transfer
```

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
