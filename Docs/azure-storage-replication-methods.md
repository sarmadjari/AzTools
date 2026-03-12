# Azure Storage Replication Methods

> **Author:** Sarmad Jari
> **Date:** March 12, 2026

---

## Key Terms

### Storage Services

- **Blob Storage** stores unstructured data as objects (documents, images, backups, logs). Data is organized into containers.
- **Azure Files** provides managed file shares accessible via SMB or NFS, similar to a traditional file server.

### Storage Account Types

| Account Type | API Kind | Backed By | Supports |
|:--|:--|:--|:--|
| **Standard GPv2** (General Purpose v2) | `StorageV2` | HDD | Blobs, Files, Queues, Tables. The default and recommended type. |
| **Standard GPv2 with HNS** (ADLS Gen2) | `StorageV2` (HNS enabled) | HDD | Same as GPv2 but with Hierarchical Namespace enabled, adding directory-level operations and POSIX ACLs on blob storage. Used for big data and analytics workloads. Object Replication is **not supported**, use Storage Mover instead. |
| **Premium Block Blob** | `BlockBlobStorage` | SSD | Block blobs only. For workloads needing high transaction rates or low latency. |
| **Premium Block Blob with HNS** (ADLS Gen2) | `BlockBlobStorage` (HNS enabled) | SSD | Same as Premium Block Blob but with Hierarchical Namespace enabled. For high-performance analytics on SSD. Object Replication is **not supported**, use Storage Mover instead. |
| **Premium File Shares** | `FileStorage` | SSD | File shares only. For workloads needing low-latency file access. |
| **Premium Page Blobs** | `StorageV2` (Premium) | SSD | Page blobs only (e.g. unmanaged VM disks). |
| **BlobStorage** | `BlobStorage` | HDD | Blobs only. Legacy type retiring October 2026, upgrade to GPv2. |
| **GPv1** (General Purpose v1) | `Storage` | HDD | Blobs, Files, Queues, Tables. Legacy type retiring October 2026, upgrade to GPv2. |

### Redundancy Levels

| Level | What It Means |
|:--|:--|
| **LRS** (Locally Redundant Storage) | 3 copies in a single data centre. Protects against drive and rack failures. |
| **ZRS** (Zone-Redundant Storage) | 3 copies spread across 3 availability zones in one region. Protects against a full data centre outage. |
| **GRS** (Geo-Redundant Storage) | LRS in the primary region + async copy to the paired region (stored as LRS). Protects against a full region outage. |
| **RA-GRS** (Read-Access GRS) | Same as GRS, plus read access to the copy in the secondary region. |
| **GZRS** (Geo-Zone-Redundant Storage) | ZRS in the primary region + async copy to the paired region (stored as LRS). Highest durability option. |
| **RA-GZRS** (Read-Access GZRS) | Same as GZRS, plus read access to the copy in the secondary region. |

### Other Terms

| Term | Meaning |
|:--|:--|
| **RPO** (Recovery Point Objective) | Maximum acceptable data loss measured in time. An RPO of 15 minutes means you could lose up to 15 minutes of writes after a failure. |
| **SMB** (Server Message Block) | Windows file sharing protocol. Also supported on Linux and macOS. |
| **NFS** (Network File System) | Linux/Unix file sharing protocol. |
| **HNS** (Hierarchical Namespace) | Enables directory-level operations and POSIX permissions on blob storage. Also known as ADLS Gen2 (Azure Data Lake Storage Gen2). |
| **SAS** (Shared Access Signature) | A token appended to a URL that grants time-limited access to a storage resource without exposing account keys. |
| **Change feed** | A log of all create, modify, and delete operations on blobs in a storage account. Required by Object Replication to know what to replicate. |
| **Blob versioning** | Automatically keeps previous versions of a blob when it is overwritten or deleted. Required by Object Replication. |

---

## Replication Methods

### 1. Geo-Redundant Storage (GRS / RA-GRS)

Infrastructure-level replication of the **entire storage account** to an Azure-paired secondary region. Data is replicated asynchronously. RA-GRS adds read access to the secondary region. Failover (planned or unplanned) can be customer-managed or Microsoft-managed.

- **Scope:** Entire account (all services)
- **Direction:** Primary -> Azure-paired secondary (fixed, cannot be changed)
- **RPO:** Typically under 15 minutes, SLA-guaranteed with Geo Priority Replication

### 2. Geo-Zone-Redundant Storage (GZRS / RA-GZRS)

Combines ZRS in the primary region (3 availability zones) with asynchronous geo-replication to the paired secondary region (LRS). RA-GZRS adds secondary read access. Provides the highest durability Azure Storage offers.

- **Scope:** Entire account (all services)
- **Direction:** Primary (ZRS across 3 availability zones) -> Azure-paired secondary (LRS)
- **RPO:** Typically under 15 minutes, SLA-guaranteed with Geo Priority Replication

### 3. Object Replication

Asynchronous, policy-based replication of **block blobs** between a source and destination storage account. Allows granular control: you select which containers and optional prefix filters to replicate. Only new blobs created after the policy are replicated, existing blobs are not.

- **Scope:** Per-container, per-prefix (block blobs only)
- **Direction:** One-way per policy, up to 2 policies per account
- **Destination:** Any compatible storage account in any region (not limited to paired regions)

### 4. Azure Storage Mover

Fully managed migration service for moving data from on-premises (SMB/NFS), AWS S3 (generally available), or Azure-to-Azure (Preview) into Azure Blob Storage or Azure Files. Designed for one-time or recurring migrations, not continuous replication.

- **Scope:** Per-job (source endpoint -> target endpoint)
- **Direction:** On-premises/AWS/Azure -> Azure Blob containers or Azure File shares
- **Agent:** Required for on-premises sources, agentless for cloud-to-cloud (AWS S3, Azure-to-Azure)
- **HNS / ADLS Gen2:** Supported for Azure-to-Azure blob migration (Preview as of March 2026)
- **Cost:** Service is free, standard storage, transaction, and egress charges apply

### 5. AzCopy

Command-line utility for high-performance data transfer to and from Azure Storage. Supports blob-to-blob server-side async copy, incremental sync, and cross-cloud transfers (AWS S3, Google Cloud Storage). Works with all account types and all redundancy configurations.

- **Scope:** Per-container, per-blob, per-file share
- **Direction:** Bidirectional (local <-> Azure, Azure <-> Azure, AWS S3 -> Azure)
- **Authentication:** Microsoft Entra ID (OAuth), SAS (Shared Access Signature) tokens, storage account keys

### 6. Azure Data Factory / Synapse Pipelines

Managed data integration service (ETL/ELT) with a Copy Activity supporting 90+ connectors. Provides scheduled triggers, event-based triggers, and data transformation during copy. Supports all Azure storage account types as source or destination.

- **Scope:** Per-pipeline, per-activity
- **Direction:** Any supported connector -> Any supported connector
- **Scheduling:** Built-in triggers (schedule, tumbling window, event-based)

### 7. Azure File Sync

Extends Azure Files to on-premises Windows Servers. Syncs SMB file shares with cloud tiering, where infrequently accessed files are tiered to Azure while hot files remain cached locally. Multi-server sync groups allow branch office distribution.

- **Scope:** Per-sync-group (Azure file share <-> Windows Server endpoints)
- **Protocol:** SMB only (not NFS)
- **Target:** SMB file shares within Standard GPv2 storage accounts

### 8. Azure Backup (Azure Files)

Snapshot-based and vaulted backup for Azure file shares. Provides point-in-time restore and long-term retention (up to 10 years with vaulted backup). Not a replication mechanism but included as it is a key data protection method.

- **Scope:** Per-file-share
- **Target:** HDD file shares (vaulted backup GA), SSD file shares (snapshot backup)

---

## Matrix 1: Storage Account Types vs Replication Mechanisms

| Replication Mechanism | Standard GPv2 | GPv2 with HNS | Premium Block Blob | Premium Block Blob with HNS | Premium File Shares | Premium Page Blobs | BlobStorage ¹ | GPv1 ¹ |
|:--|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **GRS / RA-GRS** | ✅ Supported | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ✅ Supported | ✅ Supported |
| **GZRS / RA-GZRS** | ✅ Supported | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |
| **Object Replication** | ✅ Recommended | ❌ Not Supported | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |
| **Storage Mover (target)** | ✅ Supported | ✅ Recommended ⁶ | ✅ Supported ² | ✅ Supported ² ⁶ | ✅ Supported ³ | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |
| **AzCopy** | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported |
| **Data Factory** | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported |
| **Azure File Sync** | ✅ Supported ⁴ | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |
| **Azure Backup (Files)** | ✅ Supported ⁴ | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ✅ Supported ⁵ | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |

> ¹ BlobStorage and GPv1 are legacy account types retiring **October 13, 2026**. Upgrade to GPv2.  
> ² Storage Mover targets blob containers only for block blob accounts.  
> ³ Storage Mover targets Azure File shares only for Premium File Shares accounts.  
> ⁴ Azure File Sync and Azure Backup (Files) apply to SMB file shares within Standard GPv2 accounts only, not to blobs or other services in the same account.  
> ⁵ Azure Backup supports snapshot-based backup for SSD premium file shares, vaulted backup is GA for HDD file shares.
> ⁶ Azure-to-Azure blob migration for HNS-enabled accounts is in Preview as of March 2026.

---

## Matrix 2: Redundancy Options vs Storage Account Types

| Redundancy | Standard GPv2 | Premium Block Blob | Premium File Shares | Premium Page Blobs | BlobStorage ¹ | GPv1 ¹ |
|:--|:--:|:--:|:--:|:--:|:--:|:--:|
| **LRS** | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported | ✅ Supported |
| **ZRS** | ✅ Supported | ✅ Supported ² | ✅ Supported ² | ✅ Supported ² | ❌ Not Supported | ❌ Not Supported ³ |
| **GRS** | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ✅ Supported | ✅ Supported |
| **RA-GRS** | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ✅ Supported | ✅ Supported |
| **GZRS** | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |
| **RA-GZRS** | ✅ Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported | ❌ Not Supported |

> ¹ BlobStorage and GPv1 are legacy account types retiring **October 13, 2026**.  
> ² ZRS for premium accounts is available in certain regions only. Check [Azure Storage redundancy](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy) for regional availability.  
> ³ GPv1 had a legacy ZRS configuration (Standard_ZRS) that is also retiring October 2026. It is **not** the same as modern ZRS and does not provide synchronous 3-AZ replication.

### Additional Redundancy Notes

- **Archive access tier** is only supported on accounts configured for **LRS, GRS, or RA-GRS**. It is **not** supported on ZRS, GZRS, or RA-GZRS accounts.
- **Azure Files (RA-GRS / RA-GZRS):** Azure Files does not support read access to the secondary region. If the storage account is configured for RA-GRS or RA-GZRS, the file shares are configured and billed as GRS or GZRS respectively.

---

## Object Replication Pre-Requisite Configurations

| Configuration | Required | Notes |
|:--|:--:|:--|
| **Account type** | ✅ Required | Must be **Standard GPv2** or **Premium Block Blob**, both source and destination |
| **Blob versioning** | ✅ Required | Must be enabled on **both** source and destination accounts |
| **Change feed** | ✅ Required | Must be enabled on the **source** account |
| **HNS disabled** | ✅ Required | Object Replication is **not supported** on accounts with Hierarchical Namespace enabled (ADLS Gen2). See Key Terms above. |
| **Microsoft-managed keys** | ✅ Supported | Default encryption, fully compatible |
| **Customer-managed keys (CMK)** | ✅ Supported | CMK via Azure Key Vault is compatible |
| **Customer-provided keys (CPK)** | ❌ Not Supported | Blobs encrypted with CPK cannot be replicated |
| **Cross-subscription (same tenant)** | ✅ Supported | Source and destination can be in different subscriptions within the same Entra ID tenant |
| **Cross-tenant replication** | ⚠️ Disabled by default | Disabled for new accounts since **December 15, 2023**. Must explicitly set `AllowCrossTenantReplication = true` and provide full ARM resource IDs |
| **Customer-managed failover** | ❌ Not Supported | Cannot be used on accounts that are part of an Object Replication policy (source or destination) |
| **Priority Replication** | ✅ Supported (GA) | 99% of objects replicated within 15 minutes (SLA) when source and destination are on the same continent. Max 1 priority policy per source account |
| **Max policies per account** | - | **2** object replication policies per storage account |
| **Existing blobs** | - | **Not replicated**, only new blobs created after the policy is configured |

---

## References

| Topic | Link |
|:--|:--|
| Storage Account Overview | https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview |
| Data Redundancy | https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy |
| Object Replication Overview | https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-overview |
| Configure Object Replication | https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-configure |
| OR Priority Replication | https://learn.microsoft.com/en-us/azure/storage/blobs/object-replication-priority-replication |
| Storage Mover Overview | https://learn.microsoft.com/en-us/azure/storage-mover/service-overview |
| Storage Mover Cloud-to-Cloud | https://learn.microsoft.com/en-us/azure/storage-mover/cloud-to-cloud-migration |
| Azure File Sync Planning | https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-planning |
| Access Tiers | https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview |
| Change Redundancy Configuration | https://learn.microsoft.com/en-us/azure/storage/common/redundancy-migration |
| GPv1 Retirement | https://learn.microsoft.com/en-us/azure/storage/common/general-purpose-version-1-account-migration-overview |
| Disaster Recovery & Failover | https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance |
