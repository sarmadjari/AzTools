<#
.SYNOPSIS
    Automates Azure Storage Mover blob-to-blob job setup from a CSV of storage account pairs.
.DESCRIPTION
    Reads a CSV of source and destination storage account ARM Resource IDs, discovers all
    blob containers on each source, validates compatibility with Azure Storage Mover,
    creates matching containers on the destination, then sets up all Storage Mover resources
    (endpoints, project, job definitions, RBAC). Optionally starts the jobs.

    Supports cross-subscription scenarios. Skips and reports incompatible accounts/containers.

.PARAMETER StorageMoverName
    Name of the existing Storage Mover resource.

.PARAMETER StorageMoverRG
    Resource group of the existing Storage Mover resource.

.PARAMETER CsvPath
    Path to CSV with headers: SourceResourceId, DestResourceId
    Each value is a full ARM Resource ID for a storage account.

.PARAMETER CopyMode
    Copy strategy: Additive (default) or Mirror.
    Additive = copy new/updated only. Mirror = full sync with deletes.

.PARAMETER StartJobs
    Switch. If set, starts all created jobs after setup.

.EXAMPLE
    # Setup only (don't start jobs)
    .\Setup-StorageMoverBlobJobs.ps1 -StorageMoverName "sm-georeplication-001" -StorageMoverRG "rg-dr-georeplication-001" -CsvPath ".\resources.csv"

.EXAMPLE
    # Setup and start with Mirror mode
    .\Setup-StorageMoverBlobJobs.ps1 -StorageMoverName "sm-georeplication-001" -StorageMoverRG "rg-dr-georeplication-001" -CsvPath ".\resources.csv" -CopyMode "Mirror" -StartJobs

.NOTES
    Author  : Sarmad Jari
    Version : 1.0
    Date    : 2026-03-09
    License : MIT License (https://opensource.org/licenses/MIT)

    DISCLAIMER
    ----------
    This script is provided "AS IS" without warranty of any kind, express or implied,
    including but not limited to the warranties of merchantability, fitness for a
    particular purpose, and non-infringement. In no event shall the author(s) or
    copyright holder(s) be liable for any claim, damages, data loss, service
    disruption, or other liability, whether in an action of contract, tort, or
    otherwise, arising from, out of, or in connection with this script or the use
    or other dealings in this script.

    This script is shared strictly as a proof-of-concept (POC) for testing and
    evaluation purposes only. Use against production environments is entirely at
    your own risk.

    By using this script, you accept full responsibility for:
      - Reviewing and customising the script to meet your specific environment
      - Validating storage account pairs, container mappings, and Storage Mover
        configuration against your organisational standards
      - Applying appropriate security hardening, access controls, RBAC assignments,
        and network restrictions to all storage accounts and Storage Mover resources
      - Ensuring data residency, sovereignty, and regulatory requirements are met
        for the target region before executing any migration
      - Testing in lower environments (development / staging) before running against
        production storage accounts
      - Verifying copy mode (Additive vs Mirror) and job definitions are fit for
        purpose prior to production use
      - Following your organisation's approved change management, deployment, and
        operational practices

    Run without -StartJobs first to review the setup before starting any data
    migration jobs.
#>

param (
    [Parameter(Mandatory=$true)][string]$StorageMoverName,
    [Parameter(Mandatory=$true)][string]$StorageMoverRG,
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$false)][ValidateSet("Additive","Mirror")][string]$CopyMode = "Additive",
    [switch]$StartJobs
)

$ErrorActionPreference = "Stop"

# ── Shared Functions ─────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ssZ"
    Write-Host "[$Timestamp] [$Level] $Message"
}

function Parse-ArmResourceId {
    param([Parameter(Mandatory=$true)][string]$ResourceId)
    $Trimmed = $ResourceId.Trim()
    if ($Trimmed -notmatch "(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$") {
        throw "Invalid ARM Resource ID format: $Trimmed"
    }
    return @{
        SubscriptionId = $Matches[1]
        ResourceGroup  = $Matches[2]
        AccountName    = $Matches[3]
    }
}

# ── System containers to skip ────────────────────────────────────
$SystemContainers = @('$logs', '$blobchangefeed', '$web', '$root', 'azure-webjobs-hosts', 'azure-webjobs-secrets')
$BlobCompatibleKinds = @("StorageV2", "BlobStorage", "BlockBlobStorage", "Storage")

# ── Constants ────────────────────────────────────────────────────
$MAX_CONCURRENT_JOBS = 10

try {
    # ── Validate inputs ──────────────────────────────────────────
    if (-Not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }

    # Verify Storage Mover exists
    Write-Log "Verifying Storage Mover '$StorageMoverName' exists..."
    $SmCheck = az storage-mover show --name $StorageMoverName --resource-group $StorageMoverRG -o json 2>$null | ConvertFrom-Json
    if (-not $SmCheck) {
        throw "Storage Mover '$StorageMoverName' not found in resource group '$StorageMoverRG'."
    }
    Write-Log "Storage Mover found: $($SmCheck.location)"

    # Read CSV
    Write-Log "Reading storage account mapping from $CsvPath..."
    $AccountList = Import-Csv $CsvPath
    if ($AccountList.Count -eq 0) {
        throw "CSV file is empty."
    }
    Write-Log "Found $($AccountList.Count) account pair(s) in CSV."

    # ── Results tracking ─────────────────────────────────────────
    $Results = @()
    $JobsStarted = 0
    $TotalJobsCreated = 0

    # ── Process each CSV row ─────────────────────────────────────
    $RowNum = 0
    foreach ($Row in $AccountList) {
        $RowNum++

        try {
            # 1. Parse ARM Resource IDs
            $Source = Parse-ArmResourceId $Row.SourceResourceId
            $Dest = Parse-ArmResourceId $Row.DestResourceId

            if ($Source.AccountName -eq $Dest.AccountName) {
                Write-Log "SKIP: Source and destination are the same account ($($Source.AccountName))." "WARN"
                continue
            }

            Write-Log "=================================================================="
            Write-Log "Row $RowNum : $($Source.AccountName) -> $($Dest.AccountName)"
            Write-Log "=================================================================="

            # 2. Validate source storage account
            Write-Log "Validating source: $($Source.AccountName)..."
            az account set --subscription $Source.SubscriptionId | Out-Null
            $SourceSA = az storage account show --name $Source.AccountName --resource-group $Source.ResourceGroup --query "{kind:kind, isHnsEnabled:isHnsEnabled, id:id}" -o json | ConvertFrom-Json

            if (-not $SourceSA) {
                throw "Source storage account '$($Source.AccountName)' not found."
            }
            if ($BlobCompatibleKinds -notcontains $SourceSA.kind) {
                Write-Log "SKIP: Source '$($Source.AccountName)' kind '$($SourceSA.kind)' not supported for blob migration." "WARN"
                $Results += [PSCustomObject]@{ SourceAccount=$Source.AccountName; DestAccount=$Dest.AccountName; ContainerName="N/A"; Status="Skipped"; EndpointSource=""; EndpointTarget=""; JobName=""; Notes="Source kind '$($SourceSA.kind)' not supported" }
                continue
            }
            if ($SourceSA.isHnsEnabled -eq $true) {
                Write-Log "SKIP: Source '$($Source.AccountName)' has HNS enabled (ADLS Gen2). Use ADLS migration path." "WARN"
                $Results += [PSCustomObject]@{ SourceAccount=$Source.AccountName; DestAccount=$Dest.AccountName; ContainerName="N/A"; Status="Skipped"; EndpointSource=""; EndpointTarget=""; JobName=""; Notes="HNS enabled - use ADLS migration path" }
                continue
            }
            $SourceSAId = $SourceSA.id

            # 3. Validate destination storage account
            Write-Log "Validating destination: $($Dest.AccountName)..."
            az account set --subscription $Dest.SubscriptionId | Out-Null
            $DestSA = az storage account show --name $Dest.AccountName --resource-group $Dest.ResourceGroup --query "{kind:kind, isHnsEnabled:isHnsEnabled, id:id}" -o json | ConvertFrom-Json

            if (-not $DestSA) {
                throw "Destination storage account '$($Dest.AccountName)' not found."
            }
            if ($BlobCompatibleKinds -notcontains $DestSA.kind) {
                Write-Log "SKIP: Destination '$($Dest.AccountName)' kind '$($DestSA.kind)' not supported." "WARN"
                $Results += [PSCustomObject]@{ SourceAccount=$Source.AccountName; DestAccount=$Dest.AccountName; ContainerName="N/A"; Status="Skipped"; EndpointSource=""; EndpointTarget=""; JobName=""; Notes="Dest kind '$($DestSA.kind)' not supported" }
                continue
            }
            if ($DestSA.isHnsEnabled -eq $true) {
                Write-Log "SKIP: Destination '$($Dest.AccountName)' has HNS enabled (ADLS Gen2)." "WARN"
                $Results += [PSCustomObject]@{ SourceAccount=$Source.AccountName; DestAccount=$Dest.AccountName; ContainerName="N/A"; Status="Skipped"; EndpointSource=""; EndpointTarget=""; JobName=""; Notes="Dest HNS enabled - use ADLS migration path" }
                continue
            }
            $DestSAId = $DestSA.id

            # 4. List blob containers on source
            Write-Log "Listing containers on source '$($Source.AccountName)'..."
            az account set --subscription $Source.SubscriptionId | Out-Null
            $ContainersJson = az storage container list --account-name $Source.AccountName --auth-mode login --query "[].name" -o json 2>$null
            if (-not $ContainersJson) {
                Write-Log "Cannot list containers on source (firewall may be blocking). Trying with account key..." "WARN"
                $SourceKey = az storage account keys list -g $Source.ResourceGroup -n $Source.AccountName --query "[0].value" -o tsv
                $ContainersJson = az storage container list --account-name $Source.AccountName --account-key $SourceKey --query "[].name" -o json
            }
            $AllContainers = $ContainersJson | ConvertFrom-Json

            # Filter out system containers
            $UserContainers = $AllContainers | Where-Object {
                $Name = $_
                $IsSystem = $false
                foreach ($Sys in $SystemContainers) {
                    if ($Name -eq $Sys -or $Name.StartsWith('$')) { $IsSystem = $true; break }
                }
                -not $IsSystem
            }

            if (-not $UserContainers -or $UserContainers.Count -eq 0) {
                Write-Log "No user containers found on source '$($Source.AccountName)'." "WARN"
                continue
            }

            $SkippedContainers = $AllContainers.Count - $UserContainers.Count
            if ($SkippedContainers -gt 0) {
                Write-Log "Skipped $SkippedContainers system container(s)."
            }
            Write-Log "Found $($UserContainers.Count) user container(s) to process."

            # 5. Create project for this account pair
            $ProjectName = "proj-$($Source.AccountName)"
            Write-Log "Creating project: $ProjectName..."
            az storage-mover project create --name $ProjectName --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --description "Blob migration: $($Source.AccountName) -> $($Dest.AccountName)" -o none 2>$null

            # 6. Process each container
            foreach ($Container in $UserContainers) {
                $ContainerName = $Container.ToString().Trim()
                Write-Log "--------------------------------------------------"
                Write-Log "  Container: $ContainerName"

                try {
                    # 5a. Create container on destination (if it doesn't exist)
                    Write-Log "  Ensuring container exists on destination..."
                    az account set --subscription $Dest.SubscriptionId | Out-Null
                    az storage container create --name $ContainerName --account-name $Dest.AccountName --auth-mode login -o none 2>$null
                    # If auth-mode login fails (firewall), try with key
                    if ($LASTEXITCODE -ne 0) {
                        $DestKey = az storage account keys list -g $Dest.ResourceGroup -n $Dest.AccountName --query "[0].value" -o tsv 2>$null
                        if ($DestKey) {
                            az storage container create --name $ContainerName --account-name $Dest.AccountName --account-key $DestKey -o none 2>$null
                        }
                    }

                    # 6a. Create source endpoint
                    $SrcEndpointName = "src-$($Source.AccountName)-$ContainerName"
                    # Truncate to 63 chars if needed (ARM naming limit)
                    if ($SrcEndpointName.Length -gt 63) { $SrcEndpointName = $SrcEndpointName.Substring(0, 63) }

                    Write-Log "  Creating source endpoint: $SrcEndpointName"
                    az storage-mover endpoint create-for-storage-container --endpoint-name $SrcEndpointName --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --container-name $ContainerName --storage-account-id $SourceSAId --description "Source: $($Source.AccountName)/$ContainerName" -o none 2>$null

                    # 6b. Create target endpoint
                    $TgtEndpointName = "tgt-$($Dest.AccountName)-$ContainerName"
                    if ($TgtEndpointName.Length -gt 63) { $TgtEndpointName = $TgtEndpointName.Substring(0, 63) }

                    Write-Log "  Creating target endpoint: $TgtEndpointName"
                    az storage-mover endpoint create-for-storage-container --endpoint-name $TgtEndpointName --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --container-name $ContainerName --storage-account-id $DestSAId --description "Target: $($Dest.AccountName)/$ContainerName" -o none 2>$null

                    # 6c. Get managed identity principal IDs
                    $SrcPrincipalId = az storage-mover endpoint show --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --name $SrcEndpointName --query "identity.principalId" -o tsv
                    $TgtPrincipalId = az storage-mover endpoint show --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --name $TgtEndpointName --query "identity.principalId" -o tsv

                    # 6d. Assign RBAC — Storage Blob Data Owner on both containers for both MIs
                    $SourceContainerScope = "$SourceSAId/blobServices/default/containers/$ContainerName"
                    $TargetContainerScope = "$DestSAId/blobServices/default/containers/$ContainerName"

                    Write-Log "  Assigning RBAC..."
                    foreach ($PrincipalId in @($SrcPrincipalId, $TgtPrincipalId)) {
                        if ([string]::IsNullOrWhiteSpace($PrincipalId)) { continue }
                        foreach ($Scope in @($SourceContainerScope, $TargetContainerScope)) {
                            az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Owner" --scope $Scope -o none 2>$null
                        }
                    }

                    # 6e. Create job definition
                    $JobName = "job-$ContainerName"
                    if ($JobName.Length -gt 63) { $JobName = $JobName.Substring(0, 63) }

                    Write-Log "  Creating job definition: $JobName (mode: $CopyMode)"
                    az storage-mover job-definition create --name $JobName --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --project-name $ProjectName --source-name $SrcEndpointName --target-name $TgtEndpointName --copy-mode $CopyMode --description "Copy $ContainerName from $($Source.AccountName) to $($Dest.AccountName)" -o none 2>$null

                    $TotalJobsCreated++

                    # 6f. Optionally start the job
                    $JobStarted = "No"
                    if ($StartJobs) {
                        if ($JobsStarted -lt $MAX_CONCURRENT_JOBS) {
                            Write-Log "  Starting job: $JobName"
                            az storage-mover job-definition start-job --job-definition-name $JobName --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --project-name $ProjectName -o none 2>$null
                            $JobsStarted++
                            $JobStarted = "Yes"
                        } else {
                            Write-Log "  Max concurrent jobs ($MAX_CONCURRENT_JOBS) reached. Job '$JobName' created but NOT started." "WARN"
                            $JobStarted = "No (limit reached)"
                        }
                    }

                    $Results += [PSCustomObject]@{
                        SourceAccount  = $Source.AccountName
                        DestAccount    = $Dest.AccountName
                        ContainerName  = $ContainerName
                        Status         = "Created"
                        EndpointSource = $SrcEndpointName
                        EndpointTarget = $TgtEndpointName
                        JobName        = $JobName
                        JobStarted     = $JobStarted
                        Notes          = ""
                    }

                    Write-Log "  Done: $ContainerName"

                } catch {
                    Write-Log "  ERROR on container '$ContainerName': $($_.Exception.Message)" "ERROR"
                    $Results += [PSCustomObject]@{
                        SourceAccount  = $Source.AccountName
                        DestAccount    = $Dest.AccountName
                        ContainerName  = $ContainerName
                        Status         = "Failed"
                        EndpointSource = ""
                        EndpointTarget = ""
                        JobName        = ""
                        JobStarted     = "No"
                        Notes          = $_.Exception.Message
                    }
                    continue
                }
            }

        } catch {
            Write-Log "ERROR processing row $RowNum : $($_.Exception.Message)" "ERROR"
            continue
        }
    }

    # ── Export summary CSV ────────────────────────────────────────
    $TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
    $SummaryPath = ".\StorageMoverSetup_$TimestampStr.csv"
    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $SummaryPath -NoTypeInformation -Encoding UTF8
        Write-Log "Summary CSV exported to: $SummaryPath"
    }

    # ── Final summary ────────────────────────────────────────────
    $Created = ($Results | Where-Object { $_.Status -eq "Created" }).Count
    $Skipped = ($Results | Where-Object { $_.Status -eq "Skipped" }).Count
    $Failed  = ($Results | Where-Object { $_.Status -eq "Failed" }).Count

    Write-Log "=================================================================="
    Write-Log "SETUP COMPLETE"
    Write-Log "  Jobs created  : $TotalJobsCreated"
    Write-Log "  Jobs started  : $JobsStarted"
    Write-Log "  Skipped       : $Skipped"
    Write-Log "  Failed        : $Failed"
    if ($TotalJobsCreated -gt 0 -and -not $StartJobs) {
        Write-Log "  Note: Use -StartJobs to auto-start, or start manually from the portal."
    }
    if ($TotalJobsCreated -gt 0) {
        Write-Log "  RBAC may take 5-10 minutes to propagate before jobs succeed."
    }
    Write-Log "=================================================================="

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
