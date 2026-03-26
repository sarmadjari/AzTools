# Sync-DRFileShares.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 2.5 | **Date:** 2026-03-25

Syncs Azure File Shares from source to destination storage accounts using `azcopy sync`. Compares source vs destination and transfers only changed files — much faster on subsequent runs than `azcopy copy`. Supports Additive (default, no deletes) and Mirror (syncs deletions) modes. Optimized for large file shares: SMB permissions are opt-in (`-PreserveSmbPermissions`), AzCopy uses `--log-level=ERROR` to reduce I/O, and partial syncs (AzCopy exit code 1) are tracked separately from total failures.

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
| `-PreserveSmbPermissions` | No | Opt-in. Preserves NTFS ACLs (`--preserve-smb-permissions=true`). Off by default for faster subsequent syncs — avoids ~2 extra API calls per file. SMB metadata (timestamps, attributes) is always preserved. In Automation mode, falls back to `PreserveSmbPermissions` Automation Variable |
| `-ExcludePattern` | No | Semicolon-delimited glob pattern to skip files (`--exclude-pattern`). Example: `"*.tmp;~$*;thumbs.db"`. In Automation mode, falls back to `ExcludePattern` Automation Variable |
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

# Sync with NTFS ACL preservation (initial sync or after permission changes)
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -PreserveSmbPermissions

# Skip temp and locked files that consistently fail
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -ExcludePattern "*.tmp;~$*;thumbs.db"

# Full sync with permissions and exclusions
./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -PreserveSmbPermissions -ExcludePattern "*.tmp;~$*"
```

### Automated Sync

Two automation approaches are available:

| Approach | Script | Complexity | Best For |
|---|---|---|---|
| **VM + Cron** (recommended) | `Setup-SyncVM.ps1` | Simple | Most deployments — fewer moving parts, easier to troubleshoot |
| **Automation Account + Hybrid Worker** | `Setup-SyncAutomation.ps1` | Complex | When you need Azure Automation features (centralized job history, portal integration, webhooks) |

---

### Option A: VM + Cron (Setup-SyncVM.ps1) — Recommended

Deploys the sync script directly to a Linux VM with a cron job. No Automation Account, no Hybrid Worker, no Runtime Environment — just a VM with Managed Identity.

```powershell
# Create a new VM and set up sync every 12 hours
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -VMName "vm-dr-sync"

# Use an existing VM
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -VMResourceId "/subscriptions/.../virtualMachines/vm-existing"

# Custom interval, Mirror mode, cross-subscription
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -VMName "vm-dr-sync" `
    -ScheduleIntervalHours 4 `
    -SyncMode Mirror `
    -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Hub-Spoke: place VM in an existing VNet/Subnet (VNet in a different RG)
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -VMName "vm-dr-sync" `
    -ExistingVNetName "hub-vnet" `
    -ExistingSubnetName "snet-sync" `
    -ExistingVNetResourceGroup "rg-networking" `
    -SkipNatGateway

# Dry run — preview what would be created
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -VMName "vm-dr-sync" `
    -DryRun
```

This creates and configures:

| Resource | Naming Convention | Details |
|---|---|---|
| VM (auto-created if needed) | `{VMName}` | Linux Ubuntu 22.04 (Standard_B2s by default) |
| OS Disk | `{VMName}-osdisk` | Managed disk for the VM |
| NIC | `{VMName}-nic` | Network interface attached to the VM |
| VNET / Subnet | `{VMName}-vnet` / `default` | Virtual network and subnet (or use existing with `-ExistingVNetName`) |
| NSG | `{VMName}-nsg` | Network security group for the VM |
| NAT Gateway | `{VMName}-natgw` | Outbound internet access (skip with `-SkipNatGateway` or when using existing VNet) |
| Public IP | `{VMName}-natgw-pip` | Standard SKU static IP for the NAT Gateway |
| System-Assigned Managed Identity | — | Secure auth — no credentials stored |
| Prerequisites | — | Azure CLI, AzCopy, PowerShell 7 (auto-installed) |
| RBAC | — | Storage Account Contributor on all source/destination resource groups |
| `/opt/dr-sync/` | — | Sync script, CSV, config, and wrapper script deployed to the VM |
| Cron job | `/etc/cron.d/dr-sync` | Recurring schedule (default: every 12 hours) |
| Log rotation | `/etc/logrotate.d/dr-sync` | 14 days retention, compressed |

**Files on the VM:**

```
/opt/dr-sync/
├── Sync-DRFileShares.ps1    # sync script
├── resources.csv             # CSV mapping
├── run-sync.sh              # wrapper (cron entry point)
└── config.env               # sync parameters

/var/log/dr-sync/
├── sync-YYYYMMDD-HHMMSS.log # per-run logs
├── latest.log →              # symlink to latest
└── cron.log                  # cron stderr
```

**Manual trigger:**

```bash
az vm run-command invoke --name vm-dr-sync --resource-group rg-dr-sync \
    --command-id RunShellScript --scripts "/opt/dr-sync/run-sync.sh"
```

**Check logs:**

```bash
az vm run-command invoke --name vm-dr-sync --resource-group rg-dr-sync \
    --command-id RunShellScript --scripts "cat /var/log/dr-sync/latest.log"
```

#### Setup-SyncVM.ps1 Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-ResourceGroupName` | Yes | — | Resource group for the VM |
| `-Location` | Yes | — | Azure region (e.g., `switzerlandnorth`) |
| `-CsvPath` | Yes | — | Path to the CSV mapping file |
| `-VMResourceId` | No* | — | ARM Resource ID of an existing Linux VM |
| `-VMName` | No* | — | Name for a new VM to create |
| `-VMSize` | No | `Standard_B2s` | VM size for the new VM |
| `-ExistingVNetName` | No | — | Name of an existing VNet to use (for Hub-Spoke). Requires `-ExistingSubnetName` |
| `-ExistingSubnetName` | No | — | Subnet within the existing VNet. Required with `-ExistingVNetName` |
| `-ExistingVNetResourceGroup` | No | `ResourceGroupName` | RG containing the existing VNet (set when VNet is in a different RG) |
| `-DestSubscriptionId` | No | Source subscription | Subscription for destination storage accounts |
| `-ScheduleIntervalHours` | No | `12` | Sync frequency in hours (1-24) |
| `-SyncMode` | No | `Additive` | `Additive` or `Mirror` |
| `-PreserveSmbPermissions` | No | Off | Preserves NTFS ACLs during sync |
| `-ExcludePattern` | No | — | Semicolon-delimited glob pattern to skip files |
| `-SkipNatGateway` | No | Off | Skips NAT Gateway creation |
| `-DryRun` | No | Off | Preview changes without creating anything |

*Must specify exactly one of `-VMResourceId` or `-VMName`.

#### Hub-Spoke / Existing VNet

In enterprise environments with strict networking (Hub-Spoke topology, Azure Firewall, UDR-based routing), use `-ExistingVNetName` to place the VM into a pre-provisioned VNet instead of creating a new one:

```powershell
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -VMName "vm-dr-sync" `
    -ExistingVNetName "spoke-dr-vnet" `
    -ExistingSubnetName "snet-sync" `
    -ExistingVNetResourceGroup "rg-networking" `
    -SkipNatGateway
```

When using an existing VNet:
- The script **verifies** the VNet and subnet exist before proceeding
- **NAT Gateway is skipped** by default (assumes outbound is managed by your network team — e.g., Azure Firewall, UDR, or existing NAT Gateway)
- The VM's NIC references the subnet by full ARM Resource ID, so cross-RG VNets work correctly
- An NSG (`{VMName}-nsg`) is still created and attached to the NIC

#### Updating the CSV (VM + Cron)

Re-run `Setup-SyncVM.ps1` with the updated CSV:

```powershell
./Setup-SyncVM.ps1 `
    -ResourceGroupName "rg-dr-sync" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources-updated.csv" `
    -VMResourceId "/subscriptions/.../virtualMachines/vm-dr-sync"
```

The script is idempotent — it overwrites the CSV and config on the VM, assigns RBAC for any new resource groups, and skips everything else.

---

### Option B: Azure Automation + Hybrid Worker (Setup-SyncAutomation.ps1)

Use `Setup-SyncAutomation.ps1` to deploy via Azure Automation Account with a Hybrid Worker:

```powershell
# Auto-creates a VM as Hybrid Worker
./Setup-SyncAutomation.ps1 `
    -AutomationAccountName "aa-dr-sync" `
    -ResourceGroupName "rg-automation" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -ScheduleIntervalHours 4

# Use an existing VM as Hybrid Worker
./Setup-SyncAutomation.ps1 `
    -AutomationAccountName "aa-dr-sync" `
    -ResourceGroupName "rg-automation" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources.csv" `
    -HybridWorkerVMResourceId "/subscriptions/.../virtualMachines/vm-hybrid-worker" `
    -ScheduleIntervalHours 4
```

This creates and configures:

| Resource | Naming Convention | Details |
|---|---|---|
| Automation Account | `{AutomationAccountName}` | Hosts the Runbook, schedule, and variables |
| VM (auto-created if needed) | `{AutomationAccountName}-vm` or `{HybridWorkerVMName}` | Small Linux VM (Standard_B2s). Size/OS can be overridden with `-VMSize` / `-VMOsType` |
| OS Disk | `{vmname}-osdisk` | Managed disk for the VM |
| NIC | `{vmname}-nic` | Network interface attached to the VM |
| VNET / Subnet | `{vmname}-vnet` / `default` | Virtual network and subnet for the VM |
| NSG | `{vmname}-nsg` | Network security group for the VM |
| NAT Gateway | `{vmname}-natgw` | Provides outbound internet access (skip with `-SkipNatGateway`) |
| Public IP | `{vmname}-natgw-pip` | Standard SKU static IP for the NAT Gateway |
| Runtime Environment | `PowerShell-7.4` | PowerShell 7.4 runtime with Az 12.3.0 modules |
| System-Assigned Managed Identity | — | Secure auth — no credentials stored (on both AA and VM) |
| Hybrid Worker Group | `hwg-sync-dr-fileshares` | Extension-based Hybrid Worker (VM registered automatically) |
| Recurring schedule | `SyncDRFileShares-Every{N}h` | Configurable interval (default: every 12 hours) |
| Automation Variables | — | `SyncCSVContent` (encrypted), `SyncMode`, `DestSubscriptionId`, `PreserveSmbPermissions`, `ExcludePattern` |
| RBAC | — | Storage Account Contributor on all source and destination resource groups |

Prerequisites (Azure CLI, AzCopy, PowerShell 7) are automatically installed on the VM. The script waits for the VM guest agent to become ready before running prerequisite checks.

#### Setup-SyncAutomation.ps1 Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-AutomationAccountName` | Yes | — | Name of the Automation Account to create or reuse |
| `-ResourceGroupName` | Yes | — | Resource group for the Automation Account |
| `-Location` | Yes | — | Azure region (e.g., `switzerlandnorth`) |
| `-CsvPath` | Yes | — | Path to the CSV mapping file |
| `-HybridWorkerVMResourceId` | No | — | ARM Resource ID of an existing VM. When provided, skips VM creation |
| `-HybridWorkerVMName` | No | `{AutomationAccountName}-vm` | Custom name for the auto-created VM. Cannot be used with `-HybridWorkerVMResourceId` |
| `-VMSize` | No | `Standard_B2s` | VM size for auto-created VM |
| `-VMOsType` | No | `Linux` | `Linux` or `Windows` for auto-created VM |
| `-DestSubscriptionId` | No | Source subscription | Subscription for destination storage accounts |
| `-ScheduleIntervalHours` | No | `12` | Sync frequency in hours (1-24) |
| `-SyncMode` | No | `Additive` | `Additive` or `Mirror` |
| `-PreserveSmbPermissions` | No | Off | Preserves NTFS ACLs during sync |
| `-ExcludePattern` | No | — | Semicolon-delimited glob pattern to skip files |
| `-SkipNatGateway` | No | Off | Skips NAT Gateway creation. Use when the subnet already has outbound access (existing NAT Gateway, Azure Firewall, or UDR) |
| `-DryRun` | No | Off | Preview changes without creating anything |

#### Updating the CSV (Automation Account)

**Option 1 — Re-run Setup-SyncAutomation.ps1 (recommended)**

```powershell
./Setup-SyncAutomation.ps1 `
    -AutomationAccountName "aa-dr-sync" `
    -ResourceGroupName "rg-automation" `
    -Location "switzerlandnorth" `
    -CsvPath "./resources-updated.csv" `
    -HybridWorkerVMResourceId "/subscriptions/.../virtualMachines/vm-hybrid-worker"
```

The script is idempotent — it skips everything that already exists and only overwrites the `SyncCSVContent` variable with the new CSV content. RBAC assignments are checked in bulk and only new assignments are created.

**Option 2 — Update only the variable (quick, no RBAC)**

**Azure Portal → Automation Account → Variables → `SyncCSVContent` → Edit → paste the new CSV content → Save**

> **Note:** If the new CSV references resource groups that were not in the original CSV, the Managed Identity will not have permissions on them. Use Option 1 instead.

#### Outbound Internet Access (NAT Gateway)

The auto-created VM requires outbound internet access to reach:

- `*.file.core.windows.net` — Azure Storage data plane (AzCopy sync)
- `management.azure.com` — ARM API (SAS token generation, firewall toggling)
- Package repositories — for prerequisite installation (Azure CLI, AzCopy, PowerShell 7)

By default, the script creates a **NAT Gateway** with a Standard SKU static Public IP and associates it with the VM's subnet. This is required because Azure's default outbound access (SNAT) is deprecated for VMs created after November 2025.

Use `-SkipNatGateway` if your environment already provides outbound connectivity (e.g., existing NAT Gateway, Azure Firewall with UDR, or ExpressRoute with forced tunneling).

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
| SMB permissions (NTFS ACLs) | Opt-in (`-PreserveSmbPermissions`). Off by default for performance — avoids ~2 extra API calls per file when permissions haven't changed. Recommended for initial sync or after permission changes |
| SMB metadata (timestamps, attributes) | Always (`--preserve-smb-info=true`) |
| File content | Yes |
| Directory structure | Yes (`--recursive=true`) |

### AzCopy Performance Tuning

The script applies several optimizations for large file shares (1M+ files):

| Optimization | Details |
|---|---|
| `--log-level=ERROR` | Reduces AzCopy internal log I/O. Microsoft-recommended for large jobs where INFO-level logging creates significant disk overhead |
| `--preserve-smb-permissions` opt-in | Off by default. Each file requires ~2 extra API calls (one on source, one on dest) to compare NTFS ACLs. On subsequent syncs where permissions haven't changed, this overhead is wasted. Use `-PreserveSmbPermissions` for initial sync or after permission changes |
| `--exclude-pattern` | Skip files matching a semicolon-delimited glob pattern. Use `-ExcludePattern` to exclude locked, in-use, or temporary files that consistently fail and cause retries |
| Three-way exit code handling | AzCopy exit code 0 = full success, exit code 1 = partial sync (some files transferred, some failed), exit code 2+ = total failure. Partial syncs are tracked as `PartialSync` instead of being treated as failures |

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
- **RBAC assignments** (`Setup-SyncAutomation.ps1`) — existing assignments are detected in bulk (one API call per principal) and skipped. Only new scopes trigger assignment creation

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
| `SharesSynced` | Number of shares fully synced (AzCopy exit code 0) |
| `SharesPartial` | Number of shares partially synced (AzCopy exit code 1 — some files transferred, some failed) |
| `SharesFailed` | Number of shares that failed to sync (AzCopy exit code 2+) |
| `SyncMode` | `Additive` or `Mirror` |
| `Status` | `Completed`, `PartialSync`, `Failed`, `Skipped`, or `DryRun` |
| `Notes` | Error or skip reason |

### Automation Mode

Output goes to the Azure Automation job log (plain text). No results CSV is exported — check job status in the Azure Portal.

## Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `allowSharedKeyAccess=false` | Source or destination account has shared key access disabled by policy | Enable shared key access on the account, or contact your security team |
| `Failed to retrieve key` | Missing RBAC permissions for key listing | Assign **Storage Account Key Operator Service Role** or **Contributor** on the resource group |
| `Share partially synced` (exit code 1) | Some files transferred, some failed (locked files, permission issues, transient errors) | Review AzCopy logs. Use `-ExcludePattern` to skip known-problematic files. Re-run — partial syncs are safe to retry |
| `AzCopy failed (exit code: N)` (exit code 2+) | Total data-plane sync failure | Check: firewall timing (wait and retry), private endpoints blocking public copy, or share-level permissions |
| `Source account not found` | Source account doesn't exist or wrong subscription | Verify the ARM Resource ID in the CSV |
| `Destination account not found` | Destination account doesn't exist yet | Run `Create-DRFileShareAccounts.ps1` first to create destination accounts |
| `No CSV source specified` | Neither `-CsvPath` provided nor running in Automation | Provide `-CsvPath` for manual runs, or deploy via `Setup-SyncAutomation.ps1` for automation |
| `SyncCSVContent is empty` | Automation Variable not configured | Re-run `Setup-SyncAutomation.ps1` to populate the variable |
| `Failed to authenticate via Managed Identity` | MI not enabled or missing RBAC | Ensure the Automation Account has a System-Assigned MI with Storage Account Contributor role |
| `AZURE POLICY VIOLATION: Require a tag on resource groups` | Azure Policy requires tags (e.g., cost centre) on resource groups | Create the resource group manually with the required tags before running `Setup-SyncAutomation.ps1`. The script will reuse the existing RG |
| `Runtime Environment provisioning did not complete within 600s` | Azure is slow to provision Az modules into the Runtime Environment | This is a warning, not a failure. The provisioning continues in the background. Check the Automation Account in the portal — the Runtime Environment will show as "Succeeded" after a few more minutes |
| `No output from prerequisite check` | VM guest agent not ready when prerequisites were checked | The VM was just created and the OS was still initialising. Verify tools manually: SSH into the VM and run `az --version`, `azcopy --version`, `pwsh --version` |

## Workflow

```
1. Create DR accounts     ->  Create-DRFileShareAccounts.ps1 (initial setup — run once)
2. Dry run sync           ->  ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv" -DryRun
3. First sync             ->  ./Sync-DRFileShares.ps1 -CsvPath "./resources.csv"
4. Review results CSV     ->  Check DRFileShareSyncResults_*.csv for errors
5. Automate (Option A)    ->  ./Setup-SyncVM.ps1 (VM + cron — recommended)
   Automate (Option B)    ->  ./Setup-SyncAutomation.ps1 (Automation Account + Hybrid Worker)
6. (Optional) Mirror mode ->  Re-run setup script with -SyncMode "Mirror"
```

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
