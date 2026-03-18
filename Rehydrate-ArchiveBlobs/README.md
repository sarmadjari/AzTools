# Rehydrate-ArchiveBlobs.ps1

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari | **Version:** 1.0 | **Date:** 2026-03-18

Discovers and rehydrates all Archive-tier blobs in an Azure Storage Account. Designed for ADLS Gen2 (HNS-enabled) accounts where the Azure Portal does not expose the "Change Access Tier" option, but works equally well on standard blob storage accounts.

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
- Understanding the cost implications of rehydration (especially High priority)
- Understanding that rehydration is an asynchronous operation — blobs are not immediately available after the script completes
- Validating that the target tier and rehydrate priority are appropriate for your use case and budget
- Applying appropriate security hardening, access controls, and compliance policies
- Ensuring data residency, sovereignty, and regulatory requirements are met
- Testing and validating in lower environments (development / staging) before running against production
- Following your organisation's approved change management, deployment, and operational practices
- **All outcomes resulting from the use of this script, including but not limited to data loss, service disruption, security incidents, compliance violations, or financial impact**

> **Always run with `-DryRun` first to review Archive blobs before rehydrating.**

---

## The Problem

When an Azure Storage Account has **Hierarchical Namespace (HNS) enabled** (ADLS Gen2), the Azure Portal does not expose the "Change Access Tier" option on individual blobs. This is a known portal UI limitation.

If blobs have been moved to the **Archive** access tier (manually, via lifecycle management policies, or by Databricks/ADF pipelines), there is no portal-based way to rehydrate them back to Hot or Cool. The only way to change the tier is programmatically.

This script solves that problem by performing account-wide discovery and rehydration of all Archive-tier blobs.

## What the Script Does

| Step | Action |
|---|---|
| 1 | Validate storage account exists and retrieve account key |
| 2 | List all containers (or use a single container if specified) |
| 3 | Paginate through all blobs in batches of 5,000 per container |
| 4 | Identify blobs where Access Tier = Archive |
| 5 | Skip blobs already rehydrating (status = rehydrate-pending-to-hot/cool) |
| 6 | Issue Set Blob Tier command for each Archive blob (unless DryRun) |
| 7 | Generate full log file, CSV report, and summary file |

## Rehydrate Priority

| Priority | Estimated Time | Cost |
|---|---|---|
| **Standard** (default) | Up to 15 hours | Lower cost |
| **High** | Under 1 hour (blobs < 10 GB) | Higher cost |

> **Note:** Rehydration is an asynchronous operation. After the script completes, blobs transition in the background. Use the Azure Portal or `az storage blob show` to monitor rehydration status.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-StorageAccountName` | Yes | Name of the Azure Storage Account |
| `-ResourceGroupName` | Yes | Resource group containing the storage account |
| `-SubscriptionId` | No | Subscription ID. Defaults to current Azure CLI context |
| `-ContainerName` | No | Scan only this container. If omitted, scans ALL containers |
| `-TargetTier` | No | Target tier: `Hot` (default) or `Cool` |
| `-RehydratePriority` | No | Priority: `Standard` (default, up to 15 hrs) or `High` (under 1 hr) |
| `-OutputPath` | No | Directory for output files. Defaults to current directory |
| `-DryRun` | No | Discover and report Archive blobs without rehydrating |

## Usage Examples

**Dry run — discover Archive blobs without rehydrating:**
```powershell
.\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -DryRun
```

**Rehydrate all Archive blobs to Hot tier (Standard priority):**
```powershell
.\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG"
```

**Rehydrate to Cool tier with High priority:**
```powershell
.\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -TargetTier "Cool" -RehydratePriority "High"
```

**Single container only:**
```powershell
.\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -ContainerName "mycontainer"
```

**Cross-subscription with custom output path:**
```powershell
.\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -OutputPath "C:\reports"
```

## Output Files

The script generates three files (timestamped) in the output directory:

### 1. Full Log — `Rehydrate-ArchiveBlobs_Log_<timestamp>.txt`

Every action with severity levels: `[INFO]`, `[WARN]`, `[ERROR]`, `[SUCCESS]`, `[DRYRUN]`.

### 2. CSV Report — `Rehydrate-ArchiveBlobs_Report_<timestamp>.csv`

One row per Archive blob:

| Column | Description |
|---|---|
| `Container` | Container name |
| `BlobName` | Full blob path |
| `SizeBytes` | Size in bytes |
| `SizeFormatted` | Human-readable size |
| `TierTransition` | e.g., `Archive -> Hot` |
| `RehydratePriority` | `Standard` or `High` |
| `Status` | `RehydrateInitiated`, `Skipped-AlreadyRehydrating`, `Failed`, or `DryRun-WouldRehydrate` |
| `RehydrationStatus` | Current rehydration status or error detail |
| `LastModified` | Blob last modified date |

### 3. Summary — `Rehydrate-ArchiveBlobs_Summary_<timestamp>.txt`

Aggregate counts: total containers scanned, total blobs scanned, archive blobs found, total archive size, already rehydrating, successfully initiated, failed.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All operations succeeded (or DryRun completed) |
| `1` | One or more failures occurred |

## Requirements

- **Azure CLI** (`az`) — authenticated with appropriate permissions
- **PowerShell 7+** (`pwsh`)
- **Permissions** — requires:
  - `Microsoft.Storage/storageAccounts/read` (to validate account)
  - `Microsoft.Storage/storageAccounts/listKeys/action` (to retrieve account key)
  - Storage Blob Data Contributor or equivalent (for tier change operations)
