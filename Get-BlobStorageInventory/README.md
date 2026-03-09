# Get-BlobStorageInventory.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 1.0 | **Date:** 2026-03-09

Scans Azure subscriptions and inventories blob-compatible storage accounts. Determines the recommended replication tool based on Hierarchical Namespace (HNS) status, networking configuration, and AzCopy server-side copy readiness.

---

## ⚠️ Disclaimer

> **This script is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with this script or the use or other dealings in this script.**

This script is shared strictly as a **proof-of-concept (POC)** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

By using this script, you accept full responsibility for:

- Reviewing and customising the script to meet your specific environment and requirements
- Validating that the subscriptions scanned are the correct ones
- Reviewing the output CSV before using it as input for other automation tools
- Ensuring you have appropriate read permissions on the target subscriptions
- Following your organisation's approved change management, deployment, and operational practices

> **This script is read-only — it does not modify any Azure resources. However, always validate its output before using it to drive other automation.**

---

## What the Script Does

| Step | Action |
|---|---|
| 1 | Resolve target subscriptions (all accessible or specified list) |
| 2 | Scan each subscription for storage accounts |
| 3 | Filter to blob-compatible kinds (StorageV2, BlobStorage, BlockBlobStorage, Storage) |
| 4 | Determine HNS status and recommended replication tool |
| 5 | Check networking configuration (public access, firewall, trusted services bypass) |
| 6 | Assess AzCopy server-side copy readiness |
| 7 | Export results to a timestamped CSV |

## Replication Tool Recommendation

| HNS Status | Recommended Tool |
|---|---|
| HNS Disabled (standard blob) | Object Replication |
| HNS Enabled (ADLS Gen2) | Azure Storage Mover |

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SubscriptionIds` | No | Comma-separated subscription IDs to scan. If omitted, scans ALL accessible subscriptions |
| `-OutputPath` | No | Path for output CSV. Defaults to `.\BlobStorageInventory_<timestamp>.csv` |

## Usage Examples

**Scan all accessible subscriptions:**
```powershell
.\Get-BlobStorageInventory.ps1
```

**Scan specific subscriptions:**
```powershell
.\Get-BlobStorageInventory.ps1 -SubscriptionIds "aaa-111,bbb-222"
```

**Single subscription with custom output:**
```powershell
.\Get-BlobStorageInventory.ps1 -SubscriptionIds "aaa-111" -OutputPath "C:\reports\inventory.csv"
```

## Output

Exports a CSV file: `BlobStorageInventory_YYYYMMDD_HHmmss.csv`

| Column | Description |
|---|---|
| `SubscriptionId` | Azure subscription ID |
| `SubscriptionName` | Subscription display name |
| `Region` | Storage account location |
| `StorageAccountName` | Account name |
| `ResourceId` | Full ARM Resource ID |
| `HierarchicalNamespace` | `Enabled` or `Disabled` |
| `ReplicationTool` | Recommended tool (`Object Replication` or `Azure Storage Mover`) |
| `PublicNetworkAccess` | Public access setting |
| `FirewallDefaultAction` | `Allow` or `Deny` |
| `TrustedServicesBypass` | `Yes` or `No` |
| `AzCopyServerSideCopy` | `Yes` or `No` — whether AzCopy server-side copy would work |

## Requirements

- **Azure CLI** — authenticated with appropriate permissions
- **Permissions** — Reader access on target subscriptions
