# FileShareSync-AzureFilesBatch

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Batch cross-region DR sync for Azure File Shares using AzCopy v10. Reads a CSV of source and destination storage account ARM Resource IDs and syncs all file shares, preserving SMB/NTFS permissions and directory structures.

---

## ⚠️ Disclaimer

> **This script is provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with this script or the use or other dealings in this script.**

This script is shared strictly as a **proof-of-concept (POC)** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

By using this script, you accept full responsibility for:

- Reviewing and customising the script to meet your specific environment and requirements
- Validating storage account names, SAS tokens, and AzCopy parameters against your organisational standards
- Ensuring source and destination accounts are correctly paired in the CSV
- Applying appropriate security hardening, access controls, and network restrictions to all storage accounts
- Ensuring data residency, sovereignty, and regulatory requirements are met for the target region before executing any sync operations
- Testing and validating in lower environments (development / staging) before running against production storage accounts
- Following your organisation's approved change management, deployment, and operational practices

> **Review the script parameters and test in a non-production environment before executing against production systems.**

---

## Scripts

| Script | Description |
|---|---|
| `FileShareSync-AzureFilesBatch.ps1` | Sequential sync — processes one share at a time per account pair |
| `Sync-AzureFilesBatch_parallel.ps1` | Concurrent sync — runs multiple AzCopy jobs in parallel with a managed queue |

## What the Scripts Do

For each row in the CSV:

| Step | Action |
|---|---|
| 1 | Parse source and destination ARM Resource IDs |
| 2 | Generate short-lived SAS tokens for both accounts |
| 3 | List all file shares on the source account |
| 4 | Create matching shares on the destination (if missing) |
| 5 | Sync each share using AzCopy with `--preserve-smb-permissions` and `--preserve-smb-info` |

## Parameters

### FileShareSync-AzureFilesBatch.ps1

| Parameter | Required | Description |
|---|---|---|
| `-CsvPath` | Yes | Path to CSV with headers: `SourceResourceId`, `DestResourceId` |

### Sync-AzureFilesBatch_parallel.ps1

| Parameter | Required | Description |
|---|---|---|
| `-CsvPath` | Yes | Path to CSV with headers: `SourceResourceId`, `DestResourceId` |
| `-MaxConcurrentJobs` | No | Max parallel AzCopy jobs (default: 5) |

## CSV Format

```csv
SourceResourceId,DestResourceId
/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<source-name>,/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<dest-name>
```

## Usage Examples

**Sequential sync:**
```powershell
.\FileShareSync-AzureFilesBatch.ps1 -CsvPath ".\resources.csv"
```

**Parallel sync (5 concurrent jobs):**
```powershell
.\Sync-AzureFilesBatch_parallel.ps1 -CsvPath ".\resources.csv"
```

**Parallel sync (10 concurrent jobs):**
```powershell
.\Sync-AzureFilesBatch_parallel.ps1 -CsvPath ".\resources.csv" -MaxConcurrentJobs 10
```

## Output

The parallel script (`Sync-AzureFilesBatch_parallel.ps1`) generates:

| File | Description |
|---|---|
| `DR-Sync-Concurrent-Report.csv` | Summary of all sync operations (source, destination, share, status) |
| `Retry-Concurrent-AzCopy.ps1` | Auto-generated retry script for failed transfers (only created if failures occurred) |

## Network Considerations

- **Private endpoints** are NOT affected by public access / firewall settings
- **Public endpoints** ARE affected by firewall rules
- **Trusted Microsoft services** exception is required for server-side copy operations
- See `AzCopy-FileShare-Sync-Networking-Guide.md` for detailed networking guidance

## Requirements

- **Azure CLI** — authenticated with appropriate permissions
- **AzCopy v10+** — installed and available in PATH
- **Permissions** — Storage Account Key access on both source and destination accounts

## Prerequisites

- Source and destination storage accounts must already exist
- Cross-subscription scenarios are supported (each ARM Resource ID contains the subscription)
