# AzTools

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Author:** Sarmad Jari

A collection of PowerShell scripts for Azure Storage disaster recovery, inventory, account creation, data replication, and ongoing sync.

---

## Disclaimer

> **These scripts are provided "AS IS" without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author(s) or copyright holder(s) be liable for any claim, damages, data loss, service disruption, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with these scripts or the use or other dealings in these scripts.**

These scripts are shared strictly as **proof-of-concept (POC) / sample code** for testing and evaluation purposes only. Use against production environments is **entirely at your own risk**.

**Not an Official Product:** These scripts are an independent, personal work created and shared by an individual to assist the community. They are **NOT** an official product, service, or deliverable of any company, employer, or organisation. They are not endorsed, certified, vetted, or supported by any company or vendor, including Microsoft. Any use of company names, product names, or trademarks is solely for identification purposes and does not imply affiliation, sponsorship, or endorsement.

**No Support or Maintenance Obligation:** The author(s) are under no obligation to provide support, maintenance, updates, enhancements, or bug fixes. No obligation exists to respond to issues, feature requests, or pull requests. If these scripts require modifications for your environment, you are solely responsible for implementing them.

**Configuration and Settings Responsibility:** You are solely responsible for verifying that all parameters, settings, and configurations used with these scripts are correct and appropriate for your environment. The author(s) make no guarantees that default values, example configurations, or suggested settings are suitable for any specific environment. Incorrect configuration may result in data loss, service disruption, security vulnerabilities, or unintended changes to your Azure resources.

By using these scripts, you accept full responsibility for:

- **Determining whether these scripts are suitable for your intended use case**
- Reviewing and customising the scripts to meet your specific environment and requirements
- **Verifying that all parameters, settings, and configurations are correct and appropriate for your environment before each execution**
- Applying appropriate security hardening, access controls, network restrictions, and compliance policies
- Ensuring data residency, sovereignty, and regulatory requirements are met
- Testing and validating in lower environments (development / staging) before running against production
- Following your organisation's approved change management, deployment, and operational practices
- **All outcomes resulting from the use of these scripts, including but not limited to data loss, service disruption, security incidents, compliance violations, or financial impact**

> **Always run with `-DryRun` first to review planned changes before executing live.**

---

## Scripts

### [Get-BlobStorageInventory](./Get-BlobStorageInventory)

Scans Azure subscriptions and inventories blob-compatible storage accounts. Determines the recommended replication tool based on Hierarchical Namespace (HNS) status, networking configuration, and AzCopy server-side copy readiness. Read-only — does not modify any Azure resources.

### [Create-DRFileShareAccounts](./Create-DRFileShareAccounts)

Creates destination storage accounts for Azure File Share disaster recovery from a CSV mapping. Replicates account configuration (SKU, kind, tags, access tier), creates matching file shares with matching quotas, and optionally copies data via AzCopy server-side copy.

### [Create-DRBlobStorageAccounts](./Create-DRBlobStorageAccounts)

Creates destination storage accounts for Azure Blob Storage disaster recovery from a CSV mapping. Replicates account configuration, syncs blob containers, and optionally configures Object Replication policies for ongoing replication.

### [Setup-StorageMoverBlobJobs](./Setup-StorageMoverBlobJobs)

Sets up Azure Storage Mover blob-to-blob jobs from a CSV of storage account mappings. Discovers all blob containers on each source, validates compatibility, ensures matching containers exist on the destination, then creates all Storage Mover resources (project, endpoints, RBAC, job definitions). Cloud-managed — no on-premises agent required.

### [Sync-DRFileShares](./Sync-DRFileShares)

Contains two scripts:

- **Sync-DRFileShares.ps1** — Syncs Azure File Shares from source to destination using `azcopy sync`. Compares source vs destination and transfers only changed files. Supports Additive (default, no deletes) and Mirror (syncs deletions) modes. Dual-mode — works both interactively and as an Azure Automation Runbook.

- **Setup-SyncAutomation.ps1** — Deploys an Azure Automation Account, Hybrid Worker VM, recurring schedule, and all supporting resources to run `Sync-DRFileShares.ps1` on a configurable interval. One-command setup — auto-creates a VM if none is provided.

## Typical Workflow

```
1. Inventory           →  Get-BlobStorageInventory.ps1 (scan & assess)
2. Create DR accounts  →  Create-DRFileShareAccounts.ps1 / Create-DRBlobStorageAccounts.ps1
3. Blob replication    →  Setup-StorageMoverBlobJobs.ps1 (Storage Mover) or Object Replication
4. File share sync     →  Sync-DRFileShares.ps1 (manual or automated via Setup-SyncAutomation.ps1)
```

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated (`az login`)
- **PowerShell 7+** (`pwsh`)
- **AzCopy v10+** (for file share scripts)
- Appropriate RBAC permissions on source and destination subscriptions

Each script's README contains detailed prerequisites and usage instructions.

## License

This project is licensed under the [MIT License](./LICENSE).
