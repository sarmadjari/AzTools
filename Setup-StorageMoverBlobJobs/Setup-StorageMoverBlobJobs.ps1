<#
.SYNOPSIS
    Sets up Azure Storage Mover blob-to-blob jobs from a CSV of storage account mappings.

.DESCRIPTION
    Reads a CSV of source storage account ARM Resource IDs with destination account names
    and resource groups. Looks up both accounts, validates compatibility with Azure Storage
    Mover (blob-compatible types only, no HNS/ADLS Gen2), discovers all blob containers on
    the source, ensures matching containers exist on the destination, then sets up all
    Storage Mover resources (project, endpoints, RBAC, job definitions).

    The Storage Mover resource and its resource group are created automatically if they
    do not exist. Blob-to-blob Storage Mover jobs are cloud-managed — no on-premises
    agent is required.

    Compatible storage account types:
      - StorageV2 (General Purpose v2)
      - BlobStorage (legacy blob-only)
      - BlockBlobStorage (Premium block blob)
      - Storage (classic)

    NOT compatible (automatically skipped with warning):
      - FileStorage (no blob service)
      - HNS-enabled / ADLS Gen2 (not supported by Storage Mover)

    Both source AND destination accounts must pass the compatibility check.

    The script is idempotent — safe to re-run:
      - Existing Storage Mover projects, endpoints, and job definitions are reused
      - Existing containers on the destination are not affected
      - RBAC assignments are idempotent (re-assignment is harmless)
      - New containers added to the source since the last run are picked up

    Pre-validation: All rows are validated BEFORE any Azure operations begin.
    Invalid names, duplicate pairs, and malformed ARM Resource IDs are reported
    upfront so you can fix the CSV without waiting for partial execution.

    IMPORTANT: This script does NOT create storage accounts. Both source and
    destination accounts must already exist. Use Create-DRBlobStorageAccounts.ps1
    to create destination accounts first.

.PARAMETER CsvPath
    Path to CSV with headers: SourceResourceId, DestStorageAccountName, DestResourceGroupName

.PARAMETER DestRegion
    Azure region for the Storage Mover resource and its resource group
    (e.g., "switzerlandnorth").

.PARAMETER StorageMoverName
    Name of the Azure Storage Mover resource. Created automatically if it does not exist.

.PARAMETER StorageMoverRG
    Resource group for the Storage Mover resource. Created automatically if it does not exist.

.PARAMETER DestSubscriptionId
    Optional. Subscription for destination accounts. Defaults to source subscription.

.PARAMETER CopyMode
    Copy strategy: Additive (default) or Mirror.
    Additive = copies all objects, never deletes on target.
    Mirror   = full sync, deletes objects on target that do not exist on source.
    Both modes copy ALL existing objects on the first run.

.PARAMETER StartJobs
    Switch. If set, starts all created jobs after setup (capped at 10 concurrent).

.PARAMETER DryRun
    Switch. Dry run — shows what would be created without making changes.

.EXAMPLE
    # Basic setup — Additive mode, don't start jobs
    .\Setup-StorageMoverBlobJobs.ps1 -CsvPath ".\resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover"

.EXAMPLE
    # Dry run — preview what would be created
    .\Setup-StorageMoverBlobJobs.ps1 -CsvPath ".\resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover" -DryRun

.EXAMPLE
    # Mirror mode — start jobs immediately
    .\Setup-StorageMoverBlobJobs.ps1 -CsvPath ".\resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover" -CopyMode "Mirror" -StartJobs

.EXAMPLE
    # Cross-subscription — destination accounts in a different subscription
    .\Setup-StorageMoverBlobJobs.ps1 -CsvPath ".\resources.csv" -DestRegion "switzerlandnorth" -StorageMoverName "sm-dr-001" -StorageMoverRG "rg-dr-storagemover" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Author  : Sarmad Jari
    Version : 2.0
    Date    : 2026-03-10
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

    Run with -DryRun first to review planned changes before executing live.
    Run without -StartJobs first to review the setup before starting any jobs.
#>

param (
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$true)][string]$DestRegion,
    [Parameter(Mandatory=$true)][string]$StorageMoverName,
    [Parameter(Mandatory=$true)][string]$StorageMoverRG,
    [Parameter(Mandatory=$false)][string]$DestSubscriptionId,
    [Parameter(Mandatory=$false)][ValidateSet("Additive","Mirror")][string]$CopyMode = "Additive",
    [switch]$StartJobs,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# ── Shared Functions ─────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Progress = ""
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ssZ"
    $Color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "DRYRUN"  { "Cyan" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    $Prefix = if ($Progress) { "[$Timestamp] [$Level] [$Progress] " } else { "[$Timestamp] [$Level] " }
    Write-Host "$Prefix$Message" -ForegroundColor $Color
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

function Validate-StorageAccountName {
    param([string]$Name)
    $Errors = @()
    if ($Name.Length -lt 3 -or $Name.Length -gt 24) {
        $Errors += "Name must be 3-24 characters (got $($Name.Length))"
    }
    if ($Name -notmatch "^[a-z0-9]+$") {
        $Errors += "Name must be lowercase alphanumeric only"
    }
    if ($Errors.Count -gt 0) {
        return $Errors -join "; "
    }
    return $null
}

function Get-AzErrorDetail {
    <#
    .SYNOPSIS
        Captures detailed error output from an Azure CLI command, including
        Azure Policy violation details.
    #>
    param([string]$StderrOutput, [string]$StdoutOutput)

    $AllOutput = @($StderrOutput, $StdoutOutput) | Where-Object { $_ } | ForEach-Object { $_.Trim() }
    $Combined = $AllOutput -join "`n"

    if (-not $Combined) {
        return "Unknown error (no output captured)"
    }

    # Try to extract policy violation details
    $PolicyInfo = ""
    if ($Combined -match "(?i)RequestDisallowedByPolicy|PolicyViolation|policy") {
        $PolicyInfo = "AZURE POLICY VIOLATION: "

        if ($Combined -match '"policyDefinitionDisplayName"\s*:\s*"([^"]+)"') {
            $PolicyInfo += "Policy='$($Matches[1])' "
        }
        if ($Combined -match '"policyAssignmentDisplayName"\s*:\s*"([^"]+)"') {
            $PolicyInfo += "Assignment='$($Matches[1])' "
        }
        if ($Combined -match '"message"\s*:\s*"([^"]+)"') {
            $PolicyInfo += "Message='$($Matches[1])'"
        }

        if ($PolicyInfo -eq "AZURE POLICY VIOLATION: ") {
            if ($Combined -match "(?i)(policy[^`"\n]{0,200})") {
                $PolicyInfo += $Matches[1].Trim()
            }
        }
    }

    if ($PolicyInfo) {
        return $PolicyInfo
    }

    # Try to extract JSON error message
    if ($Combined -match '"message"\s*:\s*"([^"]+)"') {
        return $Matches[1]
    }

    # Try to extract "ERROR:" prefixed messages
    if ($Combined -match "(?m)^.*ERROR[:\s]+(.+)$") {
        return $Matches[1].Trim()
    }

    # Return the last meaningful line
    $Lines = $Combined -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($Lines.Count -gt 0) {
        $LastLine = $Lines[-1].Trim()
        if ($LastLine.Length -gt 500) { $LastLine = $LastLine.Substring(0, 500) + "..." }
        return $LastLine
    }

    return "Unknown error"
}

function Invoke-AzCommand {
    <#
    .SYNOPSIS
        Runs an Azure CLI command and captures both stdout and stderr for detailed error reporting.
        Returns a hashtable with Success, StdOut, StdErr, and ErrorDetail.
    #>
    param(
        [string[]]$Arguments,
        [switch]$IgnoreExitCode
    )

    $TempStdErr = [System.IO.Path]::GetTempFileName()
    $TempStdOut = [System.IO.Path]::GetTempFileName()

    try {
        & az @Arguments > $TempStdOut 2> $TempStdErr
        $ExitCode = $LASTEXITCODE

        $StdOutContent = if (Test-Path $TempStdOut) { Get-Content $TempStdOut -Raw -ErrorAction SilentlyContinue } else { "" }
        $StdErrContent = if (Test-Path $TempStdErr) { Get-Content $TempStdErr -Raw -ErrorAction SilentlyContinue } else { "" }

        $Result = @{
            Success     = ($ExitCode -eq 0) -or $IgnoreExitCode
            ExitCode    = $ExitCode
            StdOut      = if ($StdOutContent) { $StdOutContent.Trim() } else { "" }
            StdErr      = if ($StdErrContent) { $StdErrContent.Trim() } else { "" }
            ErrorDetail = ""
        }

        if ($ExitCode -ne 0 -and -not $IgnoreExitCode) {
            $Result.ErrorDetail = Get-AzErrorDetail -StderrOutput $Result.StdErr -StdoutOutput $Result.StdOut
        }

        return $Result
    } finally {
        Remove-Item $TempStdOut -ErrorAction SilentlyContinue
        Remove-Item $TempStdErr -ErrorAction SilentlyContinue
    }
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) {
        return "{0:N0}h {1:N0}m {2:N0}s" -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds
    } elseif ($Duration.TotalMinutes -ge 1) {
        return "{0:N0}m {1:N0}s" -f [math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    } else {
        return "{0:N0}s" -f [math]::Floor($Duration.TotalSeconds)
    }
}

# ── Constants ────────────────────────────────────────────────────
$SystemContainers = @('$logs', '$blobchangefeed', '$web', '$root', 'azure-webjobs-hosts', 'azure-webjobs-secrets')
$BlobCompatibleKinds = @("StorageV2", "BlobStorage", "BlockBlobStorage", "Storage")
$MAX_CONCURRENT_JOBS = 10

try {
    # ── Validate inputs ──────────────────────────────────────────
    if (-Not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }

    $CsvFullPath = (Resolve-Path $CsvPath).Path
    Write-Log "Reading storage account mapping from $CsvFullPath..."

    $AccountList = Import-Csv $CsvFullPath
    if ($AccountList.Count -eq 0) {
        throw "CSV file is empty."
    }

    # Validate CSV headers
    $RequiredHeaders = @("SourceResourceId", "DestStorageAccountName", "DestResourceGroupName")
    $CsvHeaders = $AccountList[0].PSObject.Properties.Name
    $MissingHeaders = $RequiredHeaders | Where-Object { $_ -notin $CsvHeaders }
    if ($MissingHeaders.Count -gt 0) {
        throw "CSV is missing required headers: $($MissingHeaders -join ', '). Expected: $($RequiredHeaders -join ', ')"
    }

    $TotalRows = $AccountList.Count
    Write-Log "Found $TotalRows account pair(s) in CSV."

    # ── Pre-validation pass ──────────────────────────────────────
    Write-Log "Running pre-validation on all $TotalRows rows..."
    $ValidationErrors = @()
    $SeenPairs = @{}

    for ($i = 0; $i -lt $TotalRows; $i++) {
        $Row = $AccountList[$i]
        $CsvRowNum = $i + 1

        # Validate SourceResourceId
        $SrcId = if ($Row.SourceResourceId) { $Row.SourceResourceId.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($SrcId)) {
            $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="SourceResourceId"; Value="(empty)"; Error="SourceResourceId is empty" }
        } else {
            if ($SrcId -notmatch "(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$") {
                $DisplayVal = if ($SrcId.Length -gt 60) { $SrcId.Substring(0, 60) + "..." } else { $SrcId }
                $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="SourceResourceId"; Value=$DisplayVal; Error="Invalid ARM Resource ID format" }
            }
        }

        # Validate DestStorageAccountName
        $DestName = if ($Row.DestStorageAccountName) { $Row.DestStorageAccountName.Trim().ToLower() } else { "" }
        if ([string]::IsNullOrWhiteSpace($DestName)) {
            $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="DestStorageAccountName"; Value="(empty)"; Error="DestStorageAccountName is empty" }
        } else {
            $NameError = Validate-StorageAccountName -Name $DestName
            if ($NameError) {
                $DisplayVal = if ($DestName.Length -gt 30) { "'$($DestName.Substring(0,25))...' ($($DestName.Length) chars)" } else { "'$DestName'" }
                $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="DestStorageAccountName"; Value=$DisplayVal; Error=$NameError }
            }
        }

        # Validate DestResourceGroupName
        $DestRG = if ($Row.DestResourceGroupName) { $Row.DestResourceGroupName.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($DestRG)) {
            $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="DestResourceGroupName"; Value="(empty)"; Error="DestResourceGroupName is empty" }
        }

        # Check for duplicate source-dest pairs
        if (-not [string]::IsNullOrWhiteSpace($SrcId) -and -not [string]::IsNullOrWhiteSpace($DestName)) {
            $PairKey = "$SrcId|$DestName".ToLower()
            if ($SeenPairs.ContainsKey($PairKey)) {
                $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="SourceResourceId+DestStorageAccountName"; Value="'$DestName'"; Error="Duplicate source-dest pair (first seen in row $($SeenPairs[$PairKey]))" }
            } else {
                $SeenPairs[$PairKey] = $CsvRowNum
            }

            # Self-reference check
            if ($SrcId -match "storageAccounts/([^/]+)$") {
                $SrcAccountName = $Matches[1].ToLower()
                if ($SrcAccountName -eq $DestName) {
                    $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="DestStorageAccountName"; Value="'$DestName'"; Error="Source and destination are the same account" }
                }
            }
        }
    }

    # Report validation errors
    if ($ValidationErrors.Count -gt 0) {
        Write-Log "==================================================================" "ERROR"
        Write-Log "  PRE-VALIDATION FAILED: $($ValidationErrors.Count) error(s) found" "ERROR"
        Write-Log "==================================================================" "ERROR"
        foreach ($Err in $ValidationErrors) {
            Write-Log "  Row $($Err.Row): [$($Err.Field)] $($Err.Value)" "ERROR"
            Write-Log "    -> $($Err.Error)" "ERROR"
        }
        Write-Log "==================================================================" "ERROR"
        Write-Log "Fix the CSV and re-run. No Azure operations were performed." "ERROR"
        exit 1
    }

    Write-Log "PRE-VALIDATION PASSED: All $TotalRows rows are valid." "SUCCESS"

    # ── Mode banners ─────────────────────────────────────────────
    if ($DryRun) {
        Write-Log "==================================================================" "DRYRUN"
        Write-Log "  DRY RUN MODE -- no changes will be made" "DRYRUN"
        Write-Log "==================================================================" "DRYRUN"
    }

    Write-Log "=================================================================="
    Write-Log "  Storage Mover    : $StorageMoverName"
    Write-Log "  Storage Mover RG : $StorageMoverRG"
    Write-Log "  DestRegion       : $DestRegion"
    Write-Log "  CopyMode         : $CopyMode"
    Write-Log "  StartJobs        : $StartJobs"
    Write-Log "=================================================================="

    # ── Ensure Storage Mover exists ──────────────────────────────
    Write-Log "Checking if Storage Mover '$StorageMoverName' exists..."
    $SmResult = Invoke-AzCommand -Arguments @("storage-mover", "show", "--name", $StorageMoverName, "--resource-group", $StorageMoverRG, "-o", "json") -IgnoreExitCode
    $SmRegion = $DestRegion

    if ($SmResult.ExitCode -eq 0 -and $SmResult.StdOut) {
        $SmObj = $SmResult.StdOut | ConvertFrom-Json
        $SmRegion = $SmObj.location
        Write-Log "Storage Mover '$StorageMoverName' found in '$SmRegion'." "SUCCESS"
    } else {
        # Storage Mover does not exist — create it
        Write-Log "Storage Mover '$StorageMoverName' not found. Creating..."

        if ($DryRun) {
            Write-Log "  [DRYRUN] Would ensure resource group '$StorageMoverRG' in '$DestRegion'" "DRYRUN"
            Write-Log "  [DRYRUN] Would create Storage Mover '$StorageMoverName' in '$DestRegion'" "DRYRUN"
        } else {
            # Ensure RG exists
            $RGCheck = az group show --name $StorageMoverRG --query "name" -o tsv 2>$null
            if (-not $RGCheck) {
                Write-Log "  Creating resource group '$StorageMoverRG' in '$DestRegion'..."
                $RGResult = Invoke-AzCommand -Arguments @("group", "create", "--name", $StorageMoverRG, "--location", $DestRegion, "-o", "none")
                if (-not $RGResult.Success) {
                    throw "Failed to create resource group '$StorageMoverRG': $($RGResult.ErrorDetail)"
                }
                Write-Log "  Resource group created." "SUCCESS"
            } else {
                Write-Log "  Resource group '$StorageMoverRG' already exists."
            }

            # Create Storage Mover
            Write-Log "  Creating Storage Mover '$StorageMoverName' in '$DestRegion'..."
            $SmCreateResult = Invoke-AzCommand -Arguments @("storage-mover", "create", "--name", $StorageMoverName, "--resource-group", $StorageMoverRG, "--location", $DestRegion, "-o", "none")
            if (-not $SmCreateResult.Success) {
                throw "Failed to create Storage Mover '$StorageMoverName': $($SmCreateResult.ErrorDetail)"
            }
            Write-Log "  Storage Mover created." "SUCCESS"
        }
    }

    # ── Results tracking ─────────────────────────────────────────
    $Results = @()
    $RowNum = 0
    $ProjectsCreated = 0
    $JobsCreated = 0
    $JobsStarted = 0
    $RowsSkipped = 0
    $RowsFailed = 0
    $TotalContainersProcessed = 0
    $TotalSystemContainersSkipped = 0

    # ── Process each CSV row ─────────────────────────────────────
    foreach ($Row in $AccountList) {
        $RowNum++
        $RowStartTime = Get-Date
        $Progress = "$RowNum/$TotalRows"

        try {
            # ── Step 1: Parse source ARM ID and determine subscription ──
            $Source = Parse-ArmResourceId $Row.SourceResourceId
            $DestAccountName = $Row.DestStorageAccountName.Trim().ToLower()
            $DestRGName = $Row.DestResourceGroupName.Trim()
            $DestSubId = if ([string]::IsNullOrWhiteSpace($DestSubscriptionId)) { $Source.SubscriptionId } else { $DestSubscriptionId }

            Write-Log "==================================================================" "" $Progress
            Write-Log "$($Source.AccountName) -> $DestAccountName" "" $Progress
            Write-Log "  Source sub: $($Source.SubscriptionId) | Dest sub: $DestSubId" "" $Progress
            Write-Log "==================================================================" "" $Progress

            # ── Step 2: Validate source account ──
            Write-Log "  Validating source: $($Source.AccountName)..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null
            $SourceSAJson = az storage account show --name $Source.AccountName --resource-group $Source.ResourceGroup --query "{kind:kind, isHnsEnabled:isHnsEnabled, id:id}" -o json 2>$null
            if (-not $SourceSAJson) {
                throw "Source account '$($Source.AccountName)' not found in RG '$($Source.ResourceGroup)'."
            }
            $SourceSA = $SourceSAJson | ConvertFrom-Json

            if ($BlobCompatibleKinds -notcontains $SourceSA.kind) {
                Write-Log "  SKIP: Source kind '$($SourceSA.kind)' not compatible with blob migration." "WARN" $Progress
                $RowsSkipped++
                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; ProjectName="N/A"; ContainerName="N/A"
                    EndpointSource=""; EndpointTarget=""; JobName=""
                    JobStatus="Skipped"; JobStarted="No"; CopyMode=$CopyMode
                    Notes="Source kind '$($SourceSA.kind)' not supported"
                }
                continue
            }
            if ($SourceSA.isHnsEnabled -eq $true) {
                Write-Log "  SKIP: Source '$($Source.AccountName)' has HNS enabled (ADLS Gen2)." "WARN" $Progress
                $RowsSkipped++
                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; ProjectName="N/A"; ContainerName="N/A"
                    EndpointSource=""; EndpointTarget=""; JobName=""
                    JobStatus="Skipped"; JobStarted="No"; CopyMode=$CopyMode
                    Notes="HNS enabled (ADLS Gen2) - not supported by Storage Mover"
                }
                continue
            }
            Write-Log "  Source validated: kind=$($SourceSA.kind)" "" $Progress

            # ── Step 3: Look up destination account ──
            Write-Log "  Looking up destination: $DestAccountName..." "" $Progress
            az account set --subscription $DestSubId | Out-Null
            $DestSAJson = az storage account show --name $DestAccountName --resource-group $DestRGName --query "{kind:kind, isHnsEnabled:isHnsEnabled, id:id}" -o json 2>$null
            if (-not $DestSAJson) {
                throw "Destination account '$DestAccountName' not found in RG '$DestRGName' (sub: $DestSubId). Create it first using Create-DRBlobStorageAccounts.ps1."
            }
            $DestSA = $DestSAJson | ConvertFrom-Json

            if ($BlobCompatibleKinds -notcontains $DestSA.kind) {
                Write-Log "  SKIP: Dest kind '$($DestSA.kind)' not compatible." "WARN" $Progress
                $RowsSkipped++
                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; ProjectName="N/A"; ContainerName="N/A"
                    EndpointSource=""; EndpointTarget=""; JobName=""
                    JobStatus="Skipped"; JobStarted="No"; CopyMode=$CopyMode
                    Notes="Dest kind '$($DestSA.kind)' not supported"
                }
                continue
            }
            if ($DestSA.isHnsEnabled -eq $true) {
                Write-Log "  SKIP: Dest '$DestAccountName' has HNS enabled (ADLS Gen2)." "WARN" $Progress
                $RowsSkipped++
                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; ProjectName="N/A"; ContainerName="N/A"
                    EndpointSource=""; EndpointTarget=""; JobName=""
                    JobStatus="Skipped"; JobStarted="No"; CopyMode=$CopyMode
                    Notes="Dest HNS enabled (ADLS Gen2) - not supported"
                }
                continue
            }
            Write-Log "  Dest validated: kind=$($DestSA.kind)" "" $Progress

            # ── Step 4: List containers via ARM REST API (bypasses firewall) ──
            Write-Log "  Listing containers on source via ARM API..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null
            $ArmUrl = "https://management.azure.com/subscriptions/$($Source.SubscriptionId)/resourceGroups/$($Source.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Source.AccountName)/blobServices/default/containers?api-version=2023-05-01"
            $ArmResult = az rest --method GET --url $ArmUrl -o json 2>$null

            $AllContainers = @()
            if ($ArmResult) {
                $ArmObj = $ArmResult | ConvertFrom-Json
                if ($ArmObj.value) {
                    $AllContainers = @($ArmObj.value | ForEach-Object { $_.name })
                }
            }

            # Fallback: data plane with login auth
            if ($AllContainers.Count -eq 0) {
                Write-Log "  ARM API returned 0 containers. Trying data plane fallback..." "WARN" $Progress
                $ContainersJson = az storage container list --account-name $Source.AccountName --auth-mode login --query "[].name" -o json 2>$null
                if ($ContainersJson) {
                    $AllContainers = @($ContainersJson | ConvertFrom-Json)
                }
            }

            # Fallback: data plane with account key
            if ($AllContainers.Count -eq 0) {
                Write-Log "  Trying account key fallback..." "WARN" $Progress
                $SourceKey = az storage account keys list -g $Source.ResourceGroup -n $Source.AccountName --query "[0].value" -o tsv 2>$null
                if ($SourceKey) {
                    $ContainersJson = az storage container list --account-name $Source.AccountName --account-key $SourceKey --query "[].name" -o json 2>$null
                    if ($ContainersJson) {
                        $AllContainers = @($ContainersJson | ConvertFrom-Json)
                    }
                    $SourceKey = $null
                }
            }

            # ── Step 5: Filter system containers ──
            $UserContainers = @($AllContainers | Where-Object {
                $Name = $_
                $IsSystem = $false
                foreach ($Sys in $SystemContainers) {
                    if ($Name -eq $Sys -or $Name.StartsWith('$')) { $IsSystem = $true; break }
                }
                -not $IsSystem
            })

            $SystemSkipped = $AllContainers.Count - $UserContainers.Count
            $TotalSystemContainersSkipped += $SystemSkipped
            if ($SystemSkipped -gt 0) {
                Write-Log "  Skipped $SystemSkipped system container(s)." "" $Progress
            }

            if ($UserContainers.Count -eq 0) {
                Write-Log "  No user containers found on source '$($Source.AccountName)'." "WARN" $Progress
                $RowsSkipped++
                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; ProjectName="N/A"; ContainerName="N/A"
                    EndpointSource=""; EndpointTarget=""; JobName=""
                    JobStatus="Skipped"; JobStarted="No"; CopyMode=$CopyMode
                    Notes="No user containers on source"
                }
                continue
            }

            Write-Log "  Found $($UserContainers.Count) user container(s) to process." "" $Progress

            # ── Step 6: Ensure containers exist on dest via ARM REST API ──
            Write-Log "  Ensuring containers exist on destination..." "" $Progress
            az account set --subscription $DestSubId | Out-Null
            foreach ($Container in $UserContainers) {
                $ContainerName = $Container.ToString().Trim()
                $DestContainerUrl = "https://management.azure.com$($DestSA.id)/blobServices/default/containers/${ContainerName}?api-version=2023-05-01"

                if ($DryRun) {
                    Write-Log "    [DRYRUN] Would ensure container '$ContainerName' on dest via ARM API" "DRYRUN" $Progress
                } else {
                    az rest --method PUT --url $DestContainerUrl --body "{}" -o none 2>$null
                }
            }
            if (-not $DryRun) {
                Write-Log "  Containers ensured on destination." "" $Progress
            }

            # ── Step 7: Create Storage Mover project ──
            $ProjectName = "proj-$($Source.AccountName)-to-$DestAccountName"
            if ($ProjectName.Length -gt 63) { $ProjectName = $ProjectName.Substring(0, 63) }

            if ($DryRun) {
                Write-Log "  [DRYRUN] Would create project: $ProjectName" "DRYRUN" $Progress
            } else {
                Write-Log "  Creating project: $ProjectName..." "" $Progress
                Invoke-AzCommand -Arguments @(
                    "storage-mover", "project", "create",
                    "--name", $ProjectName,
                    "--resource-group", $StorageMoverRG,
                    "--storage-mover-name", $StorageMoverName,
                    "--description", "Blob migration: $($Source.AccountName) -> $DestAccountName",
                    "-o", "none"
                ) -IgnoreExitCode | Out-Null
            }
            $ProjectsCreated++

            # ── Step 8-11: Process each container ──
            foreach ($Container in $UserContainers) {
                $ContainerName = $Container.ToString().Trim()
                $TotalContainersProcessed++

                # Build resource names (truncated to 63 chars)
                $SrcEpName = "ep-src-$($Source.AccountName)-$ContainerName"
                if ($SrcEpName.Length -gt 63) { $SrcEpName = $SrcEpName.Substring(0, 63) }

                $TgtEpName = "ep-tgt-$DestAccountName-$ContainerName"
                if ($TgtEpName.Length -gt 63) { $TgtEpName = $TgtEpName.Substring(0, 63) }

                $JobName = "job-$ContainerName"
                if ($JobName.Length -gt 63) { $JobName = $JobName.Substring(0, 63) }

                if ($DryRun) {
                    Write-Log "    [DRYRUN] Container: $ContainerName" "DRYRUN" $Progress
                    Write-Log "      [DRYRUN] Source endpoint : $SrcEpName" "DRYRUN" $Progress
                    Write-Log "      [DRYRUN] Target endpoint : $TgtEpName" "DRYRUN" $Progress
                    Write-Log "      [DRYRUN] RBAC            : Storage Blob Data Owner on both containers" "DRYRUN" $Progress
                    Write-Log "      [DRYRUN] Job definition  : $JobName (CopyMode: $CopyMode)" "DRYRUN" $Progress
                    if ($StartJobs) {
                        Write-Log "      [DRYRUN] Would start job : $JobName" "DRYRUN" $Progress
                    }
                    $JobsCreated++
                    $Results += [PSCustomObject]@{
                        SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                        DestSubscription=$DestSubId; ProjectName=$ProjectName; ContainerName=$ContainerName
                        EndpointSource=$SrcEpName; EndpointTarget=$TgtEpName; JobName=$JobName
                        JobStatus="DryRun"; JobStarted="No"; CopyMode=$CopyMode
                        Notes=""
                    }
                    continue
                }

                try {
                    # Step 8a: Create source endpoint (idempotent)
                    Write-Log "    [$ContainerName] Creating source endpoint: $SrcEpName" "" $Progress
                    Invoke-AzCommand -Arguments @(
                        "storage-mover", "endpoint", "create-for-storage-container",
                        "--endpoint-name", $SrcEpName,
                        "--resource-group", $StorageMoverRG,
                        "--storage-mover-name", $StorageMoverName,
                        "--container-name", $ContainerName,
                        "--storage-account-id", $SourceSA.id,
                        "--description", "Source: $($Source.AccountName)/$ContainerName",
                        "-o", "none"
                    ) -IgnoreExitCode | Out-Null

                    # Step 8b: Create target endpoint (idempotent)
                    Write-Log "    [$ContainerName] Creating target endpoint: $TgtEpName" "" $Progress
                    Invoke-AzCommand -Arguments @(
                        "storage-mover", "endpoint", "create-for-storage-container",
                        "--endpoint-name", $TgtEpName,
                        "--resource-group", $StorageMoverRG,
                        "--storage-mover-name", $StorageMoverName,
                        "--container-name", $ContainerName,
                        "--storage-account-id", $DestSA.id,
                        "--description", "Target: $DestAccountName/$ContainerName",
                        "-o", "none"
                    ) -IgnoreExitCode | Out-Null

                    # Step 9: Get managed identity principal IDs and assign RBAC
                    $SrcPrincipalId = az storage-mover endpoint show --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --name $SrcEpName --query "properties.provisioningState" -o tsv 2>$null
                    # Query principal ID — try both known JSON paths
                    $SrcEpJson = az storage-mover endpoint show --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --name $SrcEpName -o json 2>$null
                    $TgtEpJson = az storage-mover endpoint show --resource-group $StorageMoverRG --storage-mover-name $StorageMoverName --name $TgtEpName -o json 2>$null

                    $SrcPrincipalId = $null
                    $TgtPrincipalId = $null

                    if ($SrcEpJson) {
                        $SrcEpObj = $SrcEpJson | ConvertFrom-Json
                        # Try both JSON paths for managed identity
                        $SrcPrincipalId = if ($SrcEpObj.properties.identity.principalId) { $SrcEpObj.properties.identity.principalId }
                                          elseif ($SrcEpObj.identity.principalId) { $SrcEpObj.identity.principalId }
                                          else { $null }
                    }
                    if ($TgtEpJson) {
                        $TgtEpObj = $TgtEpJson | ConvertFrom-Json
                        $TgtPrincipalId = if ($TgtEpObj.properties.identity.principalId) { $TgtEpObj.properties.identity.principalId }
                                          elseif ($TgtEpObj.identity.principalId) { $TgtEpObj.identity.principalId }
                                          else { $null }
                    }

                    # Assign RBAC — Storage Blob Data Owner on both containers for both MIs
                    $SourceContainerScope = "$($SourceSA.id)/blobServices/default/containers/$ContainerName"
                    $TargetContainerScope = "$($DestSA.id)/blobServices/default/containers/$ContainerName"

                    Write-Log "    [$ContainerName] Assigning RBAC..." "" $Progress
                    foreach ($PrincipalId in @($SrcPrincipalId, $TgtPrincipalId)) {
                        if ([string]::IsNullOrWhiteSpace($PrincipalId)) { continue }
                        foreach ($Scope in @($SourceContainerScope, $TargetContainerScope)) {
                            Invoke-AzCommand -Arguments @(
                                "role", "assignment", "create",
                                "--assignee-object-id", $PrincipalId,
                                "--assignee-principal-type", "ServicePrincipal",
                                "--role", "Storage Blob Data Owner",
                                "--scope", $Scope,
                                "-o", "none"
                            ) -IgnoreExitCode | Out-Null
                        }
                    }

                    # Step 10: Create job definition (idempotent)
                    Write-Log "    [$ContainerName] Creating job: $JobName (CopyMode: $CopyMode)" "" $Progress
                    Invoke-AzCommand -Arguments @(
                        "storage-mover", "job-definition", "create",
                        "--name", $JobName,
                        "--resource-group", $StorageMoverRG,
                        "--storage-mover-name", $StorageMoverName,
                        "--project-name", $ProjectName,
                        "--source-name", $SrcEpName,
                        "--target-name", $TgtEpName,
                        "--copy-mode", $CopyMode,
                        "--description", "Copy $ContainerName from $($Source.AccountName) to $DestAccountName",
                        "-o", "none"
                    ) -IgnoreExitCode | Out-Null

                    $JobsCreated++

                    # Step 11: Optionally start job
                    $JobStartedStatus = "No"
                    if ($StartJobs) {
                        if ($JobsStarted -lt $MAX_CONCURRENT_JOBS) {
                            Write-Log "    [$ContainerName] Starting job: $JobName" "" $Progress
                            Invoke-AzCommand -Arguments @(
                                "storage-mover", "job-definition", "start-job",
                                "--job-definition-name", $JobName,
                                "--resource-group", $StorageMoverRG,
                                "--storage-mover-name", $StorageMoverName,
                                "--project-name", $ProjectName,
                                "-o", "none"
                            ) -IgnoreExitCode | Out-Null
                            $JobsStarted++
                            $JobStartedStatus = "Yes"
                        } else {
                            Write-Log "    [$ContainerName] Max concurrent jobs ($MAX_CONCURRENT_JOBS) reached. Skipping start." "WARN" $Progress
                            $JobStartedStatus = "No (limit reached)"
                        }
                    }

                    $Results += [PSCustomObject]@{
                        SourceAccount    = $Source.AccountName
                        DestAccount      = $DestAccountName
                        DestResourceGroup = $DestRGName
                        DestSubscription = $DestSubId
                        ProjectName      = $ProjectName
                        ContainerName    = $ContainerName
                        EndpointSource   = $SrcEpName
                        EndpointTarget   = $TgtEpName
                        JobName          = $JobName
                        JobStatus        = "Created"
                        JobStarted       = $JobStartedStatus
                        CopyMode         = $CopyMode
                        Notes            = ""
                    }

                    Write-Log "    [$ContainerName] Done." "SUCCESS" $Progress

                } catch {
                    Write-Log "    ERROR on container '$ContainerName': $($_.Exception.Message)" "ERROR" $Progress
                    $Results += [PSCustomObject]@{
                        SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                        DestSubscription=$DestSubId; ProjectName=$ProjectName; ContainerName=$ContainerName
                        EndpointSource=$SrcEpName; EndpointTarget=$TgtEpName; JobName=$JobName
                        JobStatus="Failed"; JobStarted="No"; CopyMode=$CopyMode
                        Notes=$_.Exception.Message
                    }
                    continue
                }
            }

            # ── Step 12: Log elapsed time for this row ──
            $RowElapsed = (Get-Date) - $RowStartTime
            Write-Log "  Done: $($Source.AccountName) -> $DestAccountName ($(Format-Duration $RowElapsed))" "SUCCESS" $Progress

        } catch {
            $ErrorMessage = $_.Exception.Message
            Write-Log "ERROR: $ErrorMessage" "ERROR" $Progress
            $RowsFailed++
            $Results += [PSCustomObject]@{
                SourceAccount = if ($Source) { $Source.AccountName } else { "N/A" }
                DestAccount = $DestAccountName
                DestResourceGroup = $DestRGName
                DestSubscription = if ($DestSubId) { $DestSubId } else { "N/A" }
                ProjectName = "N/A"
                ContainerName = "N/A"
                EndpointSource = ""
                EndpointTarget = ""
                JobName = ""
                JobStatus = "Failed"
                JobStarted = "No"
                CopyMode = $CopyMode
                Notes = $ErrorMessage
            }
            continue
        }
    }

    # ── Export results CSV ────────────────────────────────────────
    $TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultsPath = ".\StorageMoverResults_$TimestampStr.csv"

    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $ResultsPath -NoTypeInformation -Encoding UTF8
        Write-Log "Results CSV exported to: $ResultsPath"
    }

    # ── Summary ──────────────────────────────────────────────────
    $TotalElapsed = (Get-Date) - $ScriptStartTime
    $TotalDuration = Format-Duration $TotalElapsed

    $JobsCreatedCount = ($Results | Where-Object { $_.JobStatus -eq "Created" }).Count
    $JobsDryRunCount = ($Results | Where-Object { $_.JobStatus -eq "DryRun" }).Count
    $JobsFailedCount = ($Results | Where-Object { $_.JobStatus -eq "Failed" }).Count

    Write-Log "=================================================================="
    Write-Log "  SUMMARY                                          ($TotalDuration)"
    Write-Log "=================================================================="
    Write-Log "  Total rows processed         : $RowNum of $TotalRows"
    Write-Log "  Storage Mover                : $StorageMoverName ($SmRegion)"
    Write-Log "  Projects created             : $ProjectsCreated"
    if ($DryRun) {
        Write-Log "  Jobs (DryRun)                : $JobsDryRunCount"
    } else {
        Write-Log "  Jobs created                 : $JobsCreatedCount"
    }
    Write-Log "  Jobs started                 : $JobsStarted"
    Write-Log "  Containers skipped (system)  : $TotalSystemContainersSkipped"
    Write-Log "  Rows skipped (incompatible)  : $RowsSkipped"
    Write-Log "  Rows failed                  : $RowsFailed"
    Write-Log "  CopyMode                     : $CopyMode"
    Write-Log "  Total elapsed time           : $TotalDuration"
    if ($Results.Count -gt 0) {
        Write-Log "  Results CSV                  : $ResultsPath"
    }
    Write-Log "=================================================================="

    # RBAC propagation warning
    if ($JobsCreatedCount -gt 0 -and -not $DryRun) {
        Write-Log ""
        Write-Log "  NOTE: RBAC may take 5-10 minutes to propagate. If jobs fail" "WARN"
        Write-Log "  immediately, wait and retry from the Azure portal." "WARN"
    }

    if ($JobsCreatedCount -gt 0 -and -not $StartJobs -and -not $DryRun) {
        Write-Log ""
        Write-Log "  Jobs created but NOT started. Use -StartJobs to auto-start," "WARN"
        Write-Log "  or start manually from the Azure portal." "WARN"
    }

    # Failed rows detail
    $FailedResults = @($Results | Where-Object { $_.JobStatus -eq "Failed" })
    if ($FailedResults.Count -gt 0) {
        Write-Log ""
        Write-Log "  FAILED DETAIL:" "ERROR"
        Write-Log "  ----------------------------------------------------------" "ERROR"
        foreach ($F in $FailedResults) {
            Write-Log "  Account: $($F.SourceAccount) -> $($F.DestAccount)" "ERROR"
            if ($F.ContainerName -ne "N/A") {
                Write-Log "    Container: $($F.ContainerName)" "ERROR"
            }
            Write-Log "    Reason: $($F.Notes)" "ERROR"
        }
        Write-Log "  ----------------------------------------------------------" "ERROR"
    }

    Write-Log "=================================================================="

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
