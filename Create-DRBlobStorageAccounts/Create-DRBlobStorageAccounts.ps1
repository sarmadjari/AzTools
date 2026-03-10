<#
.SYNOPSIS
    Creates DR blob storage accounts with matching containers from source accounts.

.DESCRIPTION
    Reads a CSV of source storage account ARM Resource IDs with destination account names
    and resource group names. Creates matching storage accounts in a target region,
    replicating source configuration (kind, SKU, HNS, TLS, access tier, networking).
    Creates all blob containers from source on destination. Optionally configures
    Object Replication (versioning, change feed, replication policies with monitoring enabled).

    Compatible storage account types (for account creation):
      - StorageV2 (General Purpose v2) — most common
      - BlobStorage (legacy blob-only)
      - BlockBlobStorage (Premium block blob)
      - FileStorage (Premium file shares)
      - StorageV2 with HNS enabled (ADLS Gen2 / Data Lake)

    Object Replication compatibility (when using -ConfigureObjectReplication):
      - Supported: StorageV2 (General Purpose v2), BlobStorage (legacy), BlockBlobStorage (Premium)
      - NOT supported: Accounts with Hierarchical Namespace (HNS/ADLS Gen2), FileStorage
      - Incompatible account types are automatically SKIPPED (not failed) — the storage
        account and containers are still created, only the replication step is skipped
        with a warning logged.
      - For compatible accounts only, the script automatically enables the required
        prerequisites before creating the replication policy:
          * Blob versioning on BOTH source and destination (required by Azure)
          * Change feed on source (required by Azure)
        Incompatible accounts are skipped entirely — no changes are made to them.
      - The script then configures BOTH accounts in two steps:
        1. Creates the policy on the DESTINATION account first (Azure requirement)
        2. Applies the same policy ID to the SOURCE account
        Both steps are required — if only the destination has the policy,
        replication will NOT start. The source needs the policy so Azure knows
        to watch for changes and replicate blobs to the destination.

    If the destination resource group does not exist, it is created automatically
    in the destination region.

    Networking (firewall) is applied LAST — after containers and Object Replication
    are configured — to avoid blocking container creation on the destination.

    The script is idempotent — safe to re-run:
      - Existing storage accounts are skipped (not recreated), but new containers are synced.
      - Existing containers on the destination are not affected.
      - -ConfigureObjectReplication can be run separately after initial creation.

    Pre-validation: All rows are validated BEFORE any Azure operations begin.
    Invalid names, duplicate names, and malformed ARM Resource IDs are reported
    upfront so you can fix the CSV without waiting for partial execution.

.PARAMETER CsvPath
    Path to CSV with headers: SourceResourceId, DestStorageAccountName, DestResourceGroupName

.PARAMETER DestRegion
    Azure region for destination storage accounts (e.g., "switzerlandnorth").

.PARAMETER DestSubscriptionId
    Optional. Subscription for destination accounts. Defaults to source subscription.

.PARAMETER SyncContainers
    Switch. For already-existing destination accounts that have firewall restrictions,
    temporarily opens the firewall, syncs missing containers from source, then
    re-applies the original networking settings. Use this to add containers to
    accounts that were created in a previous run.

.PARAMETER ConfigureObjectReplication
    Switch. Enables blob versioning on both accounts, change feed on source,
    and creates object replication policies per container with replication
    monitoring enabled (metrics and per-rule status tracking in Azure Monitor).
    Can be run independently after initial account creation.

.PARAMETER DryRun
    Switch. Dry run — shows what would be created without making changes.

.EXAMPLE
    # Create DR accounts in switzerlandnorth, same subscription as source
    ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth"

.EXAMPLE
    # Create in a different subscription
    ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DestSubscriptionId "xxx-yyy"

.EXAMPLE
    # Dry run
    ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DryRun

.EXAMPLE
    # With Object Replication
    ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -ConfigureObjectReplication

.EXAMPLE
    # Re-run later to sync containers on already-created accounts with firewall restrictions
    ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -SyncContainers

.EXAMPLE
    # Combine: sync containers + configure Object Replication on existing accounts
    ./Create-DRBlobStorageAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -SyncContainers -ConfigureObjectReplication

.NOTES
    Author  : Sarmad Jari
    Version : 2.4
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
      - Validating storage account naming, SKU selections, and replication policies
        against your organisational standards
      - Applying appropriate security hardening, access controls, network restrictions,
        and compliance policies to all storage accounts in both source and destination regions
      - Ensuring data residency, sovereignty, and regulatory requirements are met
        for the target region before executing any replication
      - Testing in lower environments (development / staging) before running against
        production storage accounts
      - Verifying replication policies, RPO targets, and failover procedures are fit
        for purpose prior to production use
      - Following your organisation's approved change management, deployment, and
        operational practices

    Always run with the -DryRun flag first to review planned changes before
    executing live.
#>

param (
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$true)][string]$DestRegion,
    [Parameter(Mandatory=$false)][string]$DestSubscriptionId,
    [switch]$SyncContainers,
    [switch]$ConfigureObjectReplication,
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

        # Try to extract the policy name/display name
        if ($Combined -match '"policyDefinitionDisplayName"\s*:\s*"([^"]+)"') {
            $PolicyInfo += "Policy='$($Matches[1])' "
        }
        if ($Combined -match '"policyAssignmentDisplayName"\s*:\s*"([^"]+)"') {
            $PolicyInfo += "Assignment='$($Matches[1])' "
        }
        # Capture the message
        if ($Combined -match '"message"\s*:\s*"([^"]+)"') {
            $PolicyInfo += "Message='$($Matches[1])'"
        }

        if ($PolicyInfo -eq "AZURE POLICY VIOLATION: ") {
            # Fallback: capture any useful policy text
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

    # Return the last meaningful line (often the error summary)
    $Lines = $Combined -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($Lines.Count -gt 0) {
        # Return last non-empty line, truncated
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

function ConvertTo-TagArgs {
    <#
    .SYNOPSIS
        Converts a tags PSObject/hashtable to an array of "key=value" strings
        for use with Azure CLI --tags parameter.
    #>
    param($Tags)
    if (-not $Tags) { return @() }
    $TagArgs = @()
    foreach ($Prop in $Tags.PSObject.Properties) {
        if ($null -ne $Prop.Value) {
            $TagArgs += "$($Prop.Name)=$($Prop.Value)"
        }
    }
    return $TagArgs
}

function Open-DestFirewall {
    <#
    .SYNOPSIS
        Temporarily opens the destination account firewall for container operations.
        Returns the original settings so they can be restored later.
    #>
    param(
        [string]$AccountName,
        [string]$ResourceGroup
    )

    # Capture current networking state
    $CurrentProps = az storage account show --name $AccountName --resource-group $ResourceGroup --query "{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass}" -o json 2>$null | ConvertFrom-Json

    $OriginalSettings = @{
        PublicAccess  = if ($CurrentProps.publicNetworkAccess) { $CurrentProps.publicNetworkAccess } else { "Enabled" }
        DefaultAction = if ($CurrentProps.defaultAction) { $CurrentProps.defaultAction } else { "Allow" }
        Bypass        = if ($CurrentProps.bypass) { $CurrentProps.bypass } else { "None" }
    }

    # Only open if currently restricted
    if ($OriginalSettings.DefaultAction -eq "Deny" -or $OriginalSettings.PublicAccess -eq "Disabled") {
        Write-Log "    Temporarily opening firewall on '$AccountName' for container operations..."

        # Enable public access if disabled
        if ($OriginalSettings.PublicAccess -eq "Disabled") {
            az storage account update --name $AccountName --resource-group $ResourceGroup --public-network-access Enabled -o none 2>$null
        }
        # Set default action to Allow
        az storage account update --name $AccountName --resource-group $ResourceGroup --default-action Allow -o none 2>$null

        # Brief pause for propagation
        Start-Sleep -Seconds 5
        Write-Log "    Firewall temporarily opened."
    }

    return $OriginalSettings
}

function Restore-DestFirewall {
    <#
    .SYNOPSIS
        Restores the destination account firewall to its original settings.
    #>
    param(
        [string]$AccountName,
        [string]$ResourceGroup,
        [hashtable]$OriginalSettings
    )

    $BypassValue = if ($OriginalSettings.Bypass -and $OriginalSettings.Bypass -ne "None") { $OriginalSettings.Bypass } else { "None" }

    Write-Log "    Restoring firewall on '$AccountName': defaultAction=$($OriginalSettings.DefaultAction) bypass=$BypassValue"
    az storage account update --name $AccountName --resource-group $ResourceGroup --default-action $OriginalSettings.DefaultAction --bypass $BypassValue -o none 2>$null

    if ($OriginalSettings.PublicAccess -eq "Disabled") {
        az storage account update --name $AccountName --resource-group $ResourceGroup --public-network-access Disabled -o none 2>$null
    }

    Write-Log "    Firewall restored."
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

# ── System containers to skip ────────────────────────────────────
$SystemContainers = @('$logs', '$blobchangefeed', '$web', '$root', 'azure-webjobs-hosts', 'azure-webjobs-secrets')

try {
    # ── Validate inputs ──────────────────────────────────────────
    if (-Not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }

    Write-Log "Reading CSV from $CsvPath..."
    $AccountList = Import-Csv $CsvPath

    if ($AccountList.Count -eq 0) {
        throw "CSV file is empty."
    }

    # Validate CSV headers
    $RequiredHeaders = @("SourceResourceId", "DestStorageAccountName", "DestResourceGroupName")
    $CsvHeaders = $AccountList[0].PSObject.Properties.Name
    foreach ($Header in $RequiredHeaders) {
        if ($CsvHeaders -notcontains $Header) {
            throw "CSV missing required header: '$Header'. Expected: $($RequiredHeaders -join ', ')"
        }
    }

    $TotalRows = $AccountList.Count
    Write-Log "Found $TotalRows row(s) in CSV."

    # ══════════════════════════════════════════════════════════════
    # ── PRE-VALIDATION PASS ──────────────────────────────────────
    # Validate ALL rows before starting any Azure operations.
    # ══════════════════════════════════════════════════════════════
    Write-Log "=================================================================="
    Write-Log "PRE-VALIDATION: Checking all $TotalRows row(s) before starting..."
    Write-Log "=================================================================="

    $ValidationErrors = @()
    $SeenDestNames = @{}
    $ValidRowCount = 0

    for ($i = 0; $i -lt $TotalRows; $i++) {
        $Row = $AccountList[$i]
        $CsvRowNum = $i + 1  # 1-based for display (matches CSV line number if 1 header line)

        # --- Validate ARM Resource ID ---
        $ArmId = $Row.SourceResourceId.Trim()
        if ([string]::IsNullOrWhiteSpace($ArmId)) {
            $ValidationErrors += [PSCustomObject]@{ Row = $CsvRowNum; Field = "SourceResourceId"; Value = "(empty)"; Error = "SourceResourceId is empty" }
            continue
        }

        try {
            $Parsed = Parse-ArmResourceId $ArmId
        } catch {
            $ValidationErrors += [PSCustomObject]@{ Row = $CsvRowNum; Field = "SourceResourceId"; Value = $ArmId; Error = $_.Exception.Message }
            continue
        }

        # --- Validate destination account name ---
        $DestName = $Row.DestStorageAccountName.Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($DestName)) {
            $ValidationErrors += [PSCustomObject]@{ Row = $CsvRowNum; Field = "DestStorageAccountName"; Value = "(empty)"; Error = "Destination account name is empty" }
            continue
        }

        $NameError = Validate-StorageAccountName $DestName
        if ($NameError) {
            $ValidationErrors += [PSCustomObject]@{ Row = $CsvRowNum; Field = "DestStorageAccountName"; Value = "$DestName ($($DestName.Length) chars)"; Error = $NameError }
            continue
        }

        # --- Check for duplicate destination names ---
        if ($SeenDestNames.ContainsKey($DestName)) {
            $FirstRow = $SeenDestNames[$DestName]
            $ValidationErrors += [PSCustomObject]@{ Row = $CsvRowNum; Field = "DestStorageAccountName"; Value = $DestName; Error = "Duplicate destination name (first seen in row $FirstRow)" }
            continue
        }
        $SeenDestNames[$DestName] = $CsvRowNum

        # --- Validate destination resource group name ---
        $DestRG = $Row.DestResourceGroupName.Trim()
        if ([string]::IsNullOrWhiteSpace($DestRG)) {
            $ValidationErrors += [PSCustomObject]@{ Row = $CsvRowNum; Field = "DestResourceGroupName"; Value = "(empty)"; Error = "Destination resource group name is empty" }
            continue
        }

        $ValidRowCount++
    }

    # --- Report validation results ---
    if ($ValidationErrors.Count -gt 0) {
        Write-Log "=================================================================="  "ERROR"
        Write-Log "  PRE-VALIDATION FAILED: $($ValidationErrors.Count) error(s) found"  "ERROR"
        Write-Log "=================================================================="  "ERROR"
        Write-Log "" "ERROR"

        foreach ($Err in $ValidationErrors) {
            Write-Log "  Row $($Err.Row): [$($Err.Field)] '$($Err.Value)'" "ERROR"
            Write-Log "    -> $($Err.Error)" "ERROR"
        }

        Write-Log "" "ERROR"
        Write-Log "Fix the above errors in '$CsvPath' and re-run the script." "ERROR"
        Write-Log "No Azure operations were performed." "ERROR"
        exit 1
    }

    Write-Log "PRE-VALIDATION PASSED: All $TotalRows row(s) are valid." "SUCCESS"
    Write-Log ""

    # ══════════════════════════════════════════════════════════════
    # ── MODE BANNERS ─────────────────────────────────────────────
    # ══════════════════════════════════════════════════════════════

    if ($DryRun) {
        Write-Log "============================================" "DRYRUN"
        Write-Log "  DRY RUN MODE -- no changes will be made"   "DRYRUN"
        Write-Log "============================================" "DRYRUN"
    }

    if ($SyncContainers) {
        Write-Log "============================================"
        Write-Log "  SYNC CONTAINERS MODE -- will temporarily"
        Write-Log "  open firewall on existing accounts to"
        Write-Log "  create missing containers, then restore."
        Write-Log "============================================"
    }

    # ── Results tracking ─────────────────────────────────────────
    $Results = @()
    $RowNum = 0
    $AccountsCreated = 0
    $AccountsExisted = 0
    $AccountsSkipped = 0
    $AccountsFailed = 0
    $TotalContainersCreated = 0

    # ── Track resource groups already ensured ─────────────────────
    $EnsuredResourceGroups = @{}

    # ══════════════════════════════════════════════════════════════
    # ── MAIN PROCESSING LOOP ─────────────────────────────────────
    # ══════════════════════════════════════════════════════════════
    foreach ($Row in $AccountList) {
        $RowNum++
        $RowStartTime = Get-Date
        $Progress = "$RowNum/$TotalRows"

        try {
            # 1. Parse source ARM Resource ID
            $Source = Parse-ArmResourceId $Row.SourceResourceId
            $DestAccountName = $Row.DestStorageAccountName.Trim().ToLower()
            $DestRGName = $Row.DestResourceGroupName.Trim()

            # Determine destination subscription
            $DestSubId = if ([string]::IsNullOrWhiteSpace($DestSubscriptionId)) { $Source.SubscriptionId } else { $DestSubscriptionId }

            Write-Log "==================================================================" "" $Progress
            Write-Log "$($Source.AccountName) -> $DestAccountName" "" $Progress
            Write-Log "  Source sub: $($Source.SubscriptionId) | Dest sub: $DestSubId" "" $Progress
            Write-Log "  Dest RG: $DestRGName | Dest region: $DestRegion" "" $Progress
            Write-Log "==================================================================" "" $Progress

            # 2. Validate destination account name (already pre-validated, but kept for safety)
            $NameError = Validate-StorageAccountName $DestAccountName
            if ($NameError) {
                Write-Log "SKIP: Invalid destination name '$DestAccountName': $NameError" "WARN" $Progress
                $Results += [PSCustomObject]@{
                    SourceAccount      = $Source.AccountName
                    DestAccount        = $DestAccountName
                    DestResourceGroup  = $DestRGName
                    DestRegion         = $DestRegion
                    DestSubscription   = $DestSubId
                    AccountStatus      = "Skipped"
                    ContainersCreated  = 0
                    ContainersSkipped  = 0
                    NetworkingConfig   = ""
                    ObjectReplication  = ""
                    Notes              = $NameError
                }
                $AccountsSkipped++
                continue
            }

            # 3. Validate source exists and read properties
            Write-Log "  Reading source properties: $($Source.AccountName)..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null
            $SourcePropsJson = az storage account show --name $Source.AccountName --resource-group $Source.ResourceGroup -o json 2>$null
            if (-not $SourcePropsJson) {
                throw "Source storage account '$($Source.AccountName)' not found in RG '$($Source.ResourceGroup)' (sub: $($Source.SubscriptionId))."
            }
            $SourceProps = $SourcePropsJson | ConvertFrom-Json

            $SourceKind       = $SourceProps.kind
            $SourceSku        = $SourceProps.sku.name
            $SourceHns        = if ($SourceProps.isHnsEnabled -eq $true) { $true } else { $false }
            $SourceTls        = if ($SourceProps.minimumTlsVersion) { $SourceProps.minimumTlsVersion } else { "TLS1_2" }
            $SourceAccessTier = if ($SourceProps.accessTier) { $SourceProps.accessTier } else { "Hot" }
            $SourceAllowBlobPublicAccess = if ($null -ne $SourceProps.allowBlobPublicAccess) { $SourceProps.allowBlobPublicAccess } else { $false }

            # Source networking settings (to replicate on destination)
            $SourcePublicAccess  = if ($SourceProps.publicNetworkAccess) { $SourceProps.publicNetworkAccess } else { "Enabled" }
            $SourceDefaultAction = if ($SourceProps.networkRuleSet -and $SourceProps.networkRuleSet.defaultAction) { $SourceProps.networkRuleSet.defaultAction } else { "Allow" }
            $SourceBypass        = if ($SourceProps.networkRuleSet -and $SourceProps.networkRuleSet.bypass) { $SourceProps.networkRuleSet.bypass } else { "None" }

            # Source tags (to apply to destination storage account)
            $SourceAccountTags = ConvertTo-TagArgs $SourceProps.tags
            $SourceAccountTagCount = $SourceAccountTags.Count

            # Source resource group tags (to apply to destination resource group)
            $SourceRGJson = az group show --name $Source.ResourceGroup --query "tags" -o json 2>$null
            $SourceRGTags = @()
            if ($SourceRGJson -and $SourceRGJson -ne "null") {
                $SourceRGTagsObj = $SourceRGJson | ConvertFrom-Json
                $SourceRGTags = ConvertTo-TagArgs $SourceRGTagsObj
            }

            Write-Log "  Source: kind=$SourceKind sku=$SourceSku hns=$SourceHns tls=$SourceTls tier=$SourceAccessTier" "" $Progress
            Write-Log "  Source networking: publicAccess=$SourcePublicAccess defaultAction=$SourceDefaultAction bypass=$SourceBypass" "" $Progress
            Write-Log "  Source tags: $SourceAccountTagCount on account, $($SourceRGTags.Count) on resource group" "" $Progress

            $NetworkingConfig = "publicAccess=$SourcePublicAccess defaultAction=$SourceDefaultAction bypass=$SourceBypass"

            # 4. Switch to destination subscription
            az account set --subscription $DestSubId | Out-Null

            # 5. Ensure destination resource group exists (with tags from source RG)
            $RGKey = "$DestSubId/$DestRGName"
            if (-not $EnsuredResourceGroups.ContainsKey($RGKey)) {
                $RGCheck = az group show --name $DestRGName --query "name" -o tsv 2>$null
                if (-not $RGCheck) {
                    if ($DryRun) {
                        Write-Log "  [DRYRUN] Would create resource group '$DestRGName' in '$DestRegion' with $($SourceRGTags.Count) tag(s)" "DRYRUN" $Progress
                    } else {
                        Write-Log "  Resource group '$DestRGName' does not exist. Creating in '$DestRegion'..." "" $Progress
                        $RGCreateArgs = @("group", "create", "--name", $DestRGName, "--location", $DestRegion, "-o", "none")
                        if ($SourceRGTags.Count -gt 0) {
                            $RGCreateArgs += @("--tags") + $SourceRGTags
                        }
                        $RGResult = Invoke-AzCommand -Arguments $RGCreateArgs
                        if (-not $RGResult.Success) {
                            throw "Failed to create resource group '$DestRGName': $($RGResult.ErrorDetail)"
                        }
                        Write-Log "  Resource group '$DestRGName' created with $($SourceRGTags.Count) tag(s)." "SUCCESS" $Progress
                    }
                } else {
                    Write-Log "  Resource group '$DestRGName' already exists." "" $Progress
                    # Update tags on existing resource group (merge source RG tags)
                    if ($SourceRGTags.Count -gt 0 -and -not $DryRun) {
                        $RGUpdateArgs = @("group", "update", "--name", $DestRGName, "--tags") + $SourceRGTags + @("-o", "none")
                        az @RGUpdateArgs 2>$null
                        Write-Log "  Updated resource group tags ($($SourceRGTags.Count) tag(s) from source RG)." "" $Progress
                    } elseif ($SourceRGTags.Count -gt 0 -and $DryRun) {
                        Write-Log "  [DRYRUN] Would update resource group tags ($($SourceRGTags.Count) tag(s))" "DRYRUN" $Progress
                    }
                }
                $EnsuredResourceGroups[$RGKey] = $true
            }

            # 6. Check if destination storage account already exists
            $DestExists = az storage account show --name $DestAccountName --resource-group $DestRGName --query "name" -o tsv 2>$null
            $AccountCreatedThisRun = $false
            $OriginalNetworkSettings = $null

            if ($DestExists) {
                Write-Log "  Destination account '$DestAccountName' already exists. Skipping creation." "" $Progress
                $AccountStatus = "AlreadyExists"
                $AccountsExisted++

                # Update tags on existing storage account from source
                if ($SourceAccountTags.Count -gt 0 -and -not $DryRun) {
                    $TagUpdateArgs = @("storage", "account", "update", "--name", $DestAccountName, "--resource-group", $DestRGName, "--tags") + $SourceAccountTags + @("-o", "none")
                    az @TagUpdateArgs 2>$null
                    Write-Log "  Updated storage account tags ($SourceAccountTagCount tag(s) from source)." "" $Progress
                } elseif ($SourceAccountTags.Count -gt 0 -and $DryRun) {
                    Write-Log "  [DRYRUN] Would update storage account tags ($SourceAccountTagCount tag(s))" "DRYRUN" $Progress
                }

                # If -SyncContainers, temporarily open the firewall for container operations
                if ($SyncContainers -and -not $DryRun) {
                    $OriginalNetworkSettings = Open-DestFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName
                } elseif ($SyncContainers -and $DryRun) {
                    Write-Log "  [DRYRUN] Would temporarily open firewall for container sync" "DRYRUN" $Progress
                }
            } else {
                # Build create command arguments — account is created with default open networking
                $CreateArgs = @(
                    "storage", "account", "create",
                    "--name", $DestAccountName,
                    "--resource-group", $DestRGName,
                    "--location", $DestRegion,
                    "--kind", $SourceKind,
                    "--sku", $SourceSku,
                    "--min-tls-version", $SourceTls,
                    "--access-tier", $SourceAccessTier,
                    "--allow-blob-public-access", $SourceAllowBlobPublicAccess.ToString().ToLower(),
                    "-o", "none"
                )

                if ($SourceHns) {
                    $CreateArgs += @("--hns", "true")
                }

                if ($SourceAccountTags.Count -gt 0) {
                    $CreateArgs += @("--tags") + $SourceAccountTags
                }

                if ($DryRun) {
                    Write-Log "  [DRYRUN] Would create storage account '$DestAccountName'" "DRYRUN" $Progress
                    Write-Log "    kind=$SourceKind sku=$SourceSku hns=$SourceHns tls=$SourceTls tier=$SourceAccessTier" "DRYRUN" $Progress
                    $AccountStatus = "DryRun"
                } else {
                    Write-Log "  Creating storage account '$DestAccountName'..." "" $Progress
                    $CreateResult = Invoke-AzCommand -Arguments $CreateArgs
                    if (-not $CreateResult.Success) {
                        $ErrorMsg = $CreateResult.ErrorDetail
                        Write-Log "  FAILED to create '$DestAccountName': $ErrorMsg" "ERROR" $Progress
                        throw "Failed to create storage account '$DestAccountName': $ErrorMsg"
                    }
                    Write-Log "  Storage account '$DestAccountName' created." "SUCCESS" $Progress
                    $AccountCreatedThisRun = $true
                    $AccountsCreated++
                    $AccountStatus = "Created"
                }
            }

            # 7. List source containers via Management Plane API
            #    Uses ARM API instead of data plane — bypasses storage firewall (defaultAction=Deny)
            Write-Log "  Listing containers on source '$($Source.AccountName)' (via ARM)..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null

            $ArmContainersUrl = "https://management.azure.com/subscriptions/$($Source.SubscriptionId)/resourceGroups/$($Source.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Source.AccountName)/blobServices/default/containers?api-version=2023-05-01"
            $ArmContainersJson = az rest --method GET --url $ArmContainersUrl -o json 2>$null

            $AllContainers = @()
            if ($ArmContainersJson) {
                $ArmContainersObj = $ArmContainersJson | ConvertFrom-Json
                $AllContainers = @($ArmContainersObj.value | ForEach-Object { $_.name })
            }

            if ($AllContainers.Count -eq 0) {
                Write-Log "  ARM API returned 0 containers. Trying data plane fallback..." "WARN" $Progress
                $ContainersJson = az storage container list --account-name $Source.AccountName --auth-mode login --query "[].name" -o json 2>$null
                if (-not $ContainersJson -or $ContainersJson -eq "[]") {
                    $SourceKey = az storage account keys list -g $Source.ResourceGroup -n $Source.AccountName --query "[0].value" -o tsv 2>$null
                    if ($SourceKey) {
                        $ContainersJson = az storage container list --account-name $Source.AccountName --account-key $SourceKey --query "[].name" -o json 2>$null
                    }
                }
                if ($ContainersJson -and $ContainersJson -ne "[]") {
                    $AllContainers = @($ContainersJson | ConvertFrom-Json)
                }
            }

            # Filter out system containers
            $UserContainers = $AllContainers | Where-Object {
                $Name = $_
                $IsSystem = $false
                foreach ($Sys in $SystemContainers) {
                    if ($Name -eq $Sys -or $Name.StartsWith('$')) { $IsSystem = $true; break }
                }
                -not $IsSystem
            }

            $ContainerSkipped = $AllContainers.Count - ($UserContainers | Measure-Object).Count
            $ContainerCount = ($UserContainers | Measure-Object).Count
            Write-Log "  Found $ContainerCount user container(s), skipped $ContainerSkipped system container(s)." "" $Progress

            # 8. Create containers on destination (firewall is still open at this point)
            $ContainersCreatedThisRow = 0
            if ($ContainerCount -gt 0) {
                az account set --subscription $DestSubId | Out-Null

                foreach ($Container in $UserContainers) {
                    $ContainerName = $Container.ToString().Trim()

                    if ($DryRun) {
                        Write-Log "    [DRYRUN] Would create container: $ContainerName" "DRYRUN" $Progress
                        $ContainersCreatedThisRow++
                    } else {
                        az storage container create --name $ContainerName --account-name $DestAccountName --auth-mode login -o none 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            # Fallback to account key
                            $DestKey = az storage account keys list -g $DestRGName -n $DestAccountName --query "[0].value" -o tsv 2>$null
                            if ($DestKey) {
                                az storage container create --name $ContainerName --account-name $DestAccountName --account-key $DestKey -o none 2>$null
                            }
                        }
                        $ContainersCreatedThisRow++
                        $TotalContainersCreated++
                        Write-Log "    Container created: $ContainerName" "" $Progress
                    }
                }
            }

            # 9. Configure Object Replication (if requested) — before locking down networking
            # Object Replication is only supported on StorageV2, BlobStorage, and BlockBlobStorage without HNS.
            # Incompatible account types (FileStorage, HNS-enabled) are automatically skipped.
            $ObjReplStatus = "N/A"
            if ($ConfigureObjectReplication -and ($SourceKind -notin @("StorageV2", "BlobStorage", "BlockBlobStorage") -or $SourceHns -eq $true)) {
                $SkipReason = if ($SourceHns -eq $true) { "HNS (ADLS Gen2) is enabled" } else { "account type '$SourceKind'" }
                Write-Log "  Skipping Object Replication — not compatible: $SkipReason. Only StorageV2, BlobStorage, and BlockBlobStorage without HNS are supported." "WARN" $Progress
                $ObjReplStatus = "Skipped (incompatible: $SourceKind, HNS=$SourceHns)"
            } elseif ($ConfigureObjectReplication -and $ContainerCount -eq 0) {
                Write-Log "  Skipping Object Replication — no user containers to replicate." "WARN" $Progress
                $ObjReplStatus = "Skipped (no containers)"
            } elseif ($ConfigureObjectReplication -and -not $DryRun) {
                Write-Log "  Configuring Object Replication..." "" $Progress

                # --- Prerequisites: Azure requires versioning + change feed BEFORE creating replication policies ---
                # These are only enabled on compatible accounts (this block is skipped for incompatible types).
                # No unnecessary changes are made to accounts that cannot use Object Replication.
                # Replication monitoring (metrics.enabled = true) is set on the policy to unlock
                # per-rule replication metrics and status tracking in Azure Monitor.

                # Enable blob versioning on SOURCE (required for Object Replication)
                az account set --subscription $Source.SubscriptionId | Out-Null
                az storage account blob-service-properties update --account-name $Source.AccountName --resource-group $Source.ResourceGroup --enable-versioning true -o none 2>$null
                Write-Log "    Versioning enabled on source: $($Source.AccountName)" "" $Progress

                # Enable change feed on SOURCE (required for Object Replication)
                az storage account blob-service-properties update --account-name $Source.AccountName --resource-group $Source.ResourceGroup --enable-change-feed true -o none 2>$null
                Write-Log "    Change feed enabled on source: $($Source.AccountName)" "" $Progress

                # Enable blob versioning on DESTINATION (required for Object Replication)
                az account set --subscription $DestSubId | Out-Null
                az storage account blob-service-properties update --account-name $DestAccountName --resource-group $DestRGName --enable-versioning true -o none 2>$null
                Write-Log "    Versioning enabled on destination: $DestAccountName" "" $Progress

                # Build replication rules — one rule per container
                # minCreationTime = "1601-01-01T00:00:00Z" = replicate ALL blobs (existing + new)
                # Omitting filters or minCreationTime defaults to "Only new objects" — NOT what we want.
                $Rules = @()
                foreach ($Container in $UserContainers) {
                    $ContainerName = $Container.ToString().Trim()
                    $Rules += @{
                        sourceContainer      = $ContainerName
                        destinationContainer = $ContainerName
                        filters              = @{
                            minCreationTime = "1601-01-01T00:00:00Z"
                        }
                    }
                }

                $DestAccountArmId = "/subscriptions/$DestSubId/resourceGroups/$DestRGName/providers/Microsoft.Storage/storageAccounts/$DestAccountName"

                # Check if a replication policy already exists between this source-destination pair
                az account set --subscription $DestSubId | Out-Null
                $ExistingPoliciesJson = az rest --method GET --url "https://management.azure.com${DestAccountArmId}/objectReplicationPolicies?api-version=2024-01-01" -o json 2>$null
                $ExistingPolicyId = $null

                if ($ExistingPoliciesJson) {
                    $ExistingPolicies = ($ExistingPoliciesJson | ConvertFrom-Json).value
                    foreach ($Pol in $ExistingPolicies) {
                        $PolSource = $Pol.properties.sourceAccount
                        # Match by full ARM ID or by account name
                        if ($PolSource -eq $SourceProps.id -or $PolSource -eq $Source.AccountName) {
                            $ExistingPolicyId = $Pol.properties.policyId
                            Write-Log "    Found existing replication policy (ID: $ExistingPolicyId). Will update." "" $Progress
                            break
                        }
                    }
                }

                # Determine the policy endpoint — use existing ID to update, or 'default' to create new
                $DestPolicyEndpoint = if ($ExistingPolicyId) {
                    "https://management.azure.com${DestAccountArmId}/objectReplicationPolicies/${ExistingPolicyId}?api-version=2024-01-01"
                } else {
                    "https://management.azure.com${DestAccountArmId}/objectReplicationPolicies/default?api-version=2024-01-01"
                }

                # Build the policy payload — metrics.enabled unlocks replication monitoring
                # (per-rule status and lag metrics in Azure Monitor). Requires api-version 2024-01-01+.
                $PolicyPayload = @{
                    properties = @{
                        sourceAccount      = $SourceProps.id
                        destinationAccount = $DestAccountArmId
                        rules              = $Rules
                        metrics            = @{ enabled = $true }
                    }
                } | ConvertTo-Json -Depth 10

                $TempFile = [System.IO.Path]::GetTempFileName()
                $PolicyPayload | Out-File -FilePath $TempFile -Encoding UTF8

                # Create or update the policy on the destination account
                $PolicyResult = az rest --method PUT --url $DestPolicyEndpoint --body "@$TempFile" -o json 2>$null

                if ($PolicyResult) {
                    $PolicyObj = $PolicyResult | ConvertFrom-Json
                    $PolicyId = $PolicyObj.properties.policyId
                    $ActionVerb = if ($ExistingPolicyId) { "updated" } else { "created" }
                    Write-Log "    Object Replication policy $ActionVerb on destination (ID: $PolicyId)." "" $Progress

                    # Apply the same policy ID to the source account
                    $SourcePolicyPayload = @{
                        properties = @{
                            sourceAccount      = $SourceProps.id
                            destinationAccount = $DestAccountArmId
                            rules              = $Rules
                            metrics            = @{ enabled = $true }
                        }
                    } | ConvertTo-Json -Depth 10

                    $SourcePolicyPayload | Out-File -FilePath $TempFile -Encoding UTF8 -Force

                    az account set --subscription $Source.SubscriptionId | Out-Null
                    az rest --method PUT --url "https://management.azure.com$($SourceProps.id)/objectReplicationPolicies/$PolicyId`?api-version=2024-01-01" --body "@$TempFile" -o none 2>$null
                    Write-Log "    Object Replication policy applied to source." "SUCCESS" $Progress
                    $ObjReplStatus = if ($ExistingPolicyId) { "Updated" } else { "Configured" }
                } else {
                    Write-Log "    Failed to create/update Object Replication policy." "WARN" $Progress
                    $ObjReplStatus = "Failed"
                }

                Remove-Item $TempFile -ErrorAction SilentlyContinue

            } elseif ($ConfigureObjectReplication -and $DryRun) {
                Write-Log "  [DRYRUN] Would configure Object Replication (versioning + change feed + policy + monitoring)" "DRYRUN" $Progress
                $ObjReplStatus = "DryRun"
            }

            # 10. Apply networking LAST — after containers and Object Replication are done
            if (-not $DryRun) {
                if ($OriginalNetworkSettings) {
                    # -SyncContainers mode: restore the original firewall settings
                    az account set --subscription $DestSubId | Out-Null
                    Restore-DestFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName -OriginalSettings $OriginalNetworkSettings
                } elseif ($AccountCreatedThisRun) {
                    # New account: apply source networking settings
                    az account set --subscription $DestSubId | Out-Null
                    $BypassValue = if ($SourceBypass -and $SourceBypass -ne "None") { $SourceBypass } else { "None" }
                    $DefaultActionValue = if ($SourceDefaultAction) { $SourceDefaultAction } else { "Allow" }

                    Write-Log "  Applying networking: defaultAction=$DefaultActionValue bypass=$BypassValue" "" $Progress
                    az storage account update --name $DestAccountName --resource-group $DestRGName --default-action $DefaultActionValue --bypass $BypassValue -o none 2>$null

                    if ($SourcePublicAccess -eq "Disabled") {
                        az storage account update --name $DestAccountName --resource-group $DestRGName --public-network-access Disabled -o none 2>$null
                    }

                    Write-Log "  Networking settings applied." "" $Progress
                }
            } else {
                if ($AccountCreatedThisRun -or $OriginalNetworkSettings) {
                    Write-Log "  [DRYRUN] Would apply networking: $NetworkingConfig" "DRYRUN" $Progress
                }
            }

            # Calculate row elapsed time
            $RowElapsed = (Get-Date) - $RowStartTime
            $RowDuration = Format-Duration $RowElapsed

            # Record results
            $Results += [PSCustomObject]@{
                SourceAccount      = $Source.AccountName
                DestAccount        = $DestAccountName
                DestResourceGroup  = $DestRGName
                DestRegion         = $DestRegion
                DestSubscription   = $DestSubId
                AccountStatus      = $AccountStatus
                ContainersCreated  = $ContainersCreatedThisRow
                ContainersSkipped  = $ContainerSkipped
                NetworkingConfig   = $NetworkingConfig
                ObjectReplication  = $ObjReplStatus
                Notes              = ""
            }

            Write-Log "  Done: $($Source.AccountName) -> $DestAccountName ($RowDuration)" "SUCCESS" $Progress

        } catch {
            $ErrorMessage = $_.Exception.Message
            Write-Log "ERROR: $ErrorMessage" "ERROR" $Progress
            $AccountsFailed++

            # Safety: if we opened the firewall, try to restore it even on error
            if ($OriginalNetworkSettings -and -not $DryRun) {
                try {
                    az account set --subscription $DestSubId | Out-Null
                    Restore-DestFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName -OriginalSettings $OriginalNetworkSettings
                } catch {
                    Write-Log "  WARNING: Failed to restore firewall on '$DestAccountName'. Please check manually." "WARN" $Progress
                }
            }

            $Results += [PSCustomObject]@{
                SourceAccount      = if ($Source) { $Source.AccountName } else { "N/A" }
                DestAccount        = if ($DestAccountName) { $DestAccountName } else { "N/A" }
                DestResourceGroup  = if ($DestRGName) { $DestRGName } else { "N/A" }
                DestRegion         = $DestRegion
                DestSubscription   = if ($DestSubId) { $DestSubId } else { "N/A" }
                AccountStatus      = "Failed"
                ContainersCreated  = 0
                ContainersSkipped  = 0
                NetworkingConfig   = ""
                ObjectReplication  = ""
                Notes              = $ErrorMessage
            }
            continue
        }
    }

    # ── Export results CSV ─────────────────────────────────────────
    $TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultsPath = ".\DRBlobStorageResults_$TimestampStr.csv"
    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $ResultsPath -NoTypeInformation -Encoding UTF8
        Write-Log "Results CSV exported to: $ResultsPath"
    }

    # ── Total elapsed time ─────────────────────────────────────────
    $TotalElapsed = (Get-Date) - $ScriptStartTime
    $TotalDuration = Format-Duration $TotalElapsed

    # ── Summary ────────────────────────────────────────────────────
    Write-Log ""
    Write-Log "==================================================================" "SUCCESS"
    Write-Log "  SUMMARY                                          ($TotalDuration)" "SUCCESS"
    Write-Log "==================================================================" "SUCCESS"
    Write-Log "  Total rows processed      : $RowNum of $TotalRows"
    Write-Log "  Accounts created          : $AccountsCreated" "SUCCESS"
    Write-Log "  Accounts already existed  : $AccountsExisted"
    Write-Log "  Accounts skipped (invalid): $AccountsSkipped" $(if ($AccountsSkipped -gt 0) { "WARN" } else { "INFO" })
    Write-Log "  Accounts failed           : $AccountsFailed"  $(if ($AccountsFailed -gt 0) { "ERROR" } else { "INFO" })
    Write-Log "  Total containers created  : $TotalContainersCreated"
    if ($ConfigureObjectReplication) {
        $ObjReplConfigured = ($Results | Where-Object { $_.ObjectReplication -eq "Configured" }).Count
        Write-Log "  Object Replication configured : $ObjReplConfigured"
    }
    Write-Log "  Total elapsed time        : $TotalDuration"
    Write-Log "  Results CSV               : $ResultsPath"
    Write-Log "==================================================================" "SUCCESS"

    # ── Show details for failed accounts ──────────────────────────
    $FailedResults = $Results | Where-Object { $_.AccountStatus -eq "Failed" }
    if ($FailedResults.Count -gt 0) {
        Write-Log ""
        Write-Log "==================================================================" "ERROR"
        Write-Log "  FAILED ACCOUNTS DETAIL ($($FailedResults.Count) failure(s))" "ERROR"
        Write-Log "==================================================================" "ERROR"
        foreach ($Failed in $FailedResults) {
            Write-Log "  Account : $($Failed.DestAccount)" "ERROR"
            Write-Log "  RG      : $($Failed.DestResourceGroup)" "ERROR"
            Write-Log "  Sub     : $($Failed.DestSubscription)" "ERROR"
            Write-Log "  Reason  : $($Failed.Notes)" "ERROR"
            Write-Log "  --" "ERROR"
        }
        Write-Log "==================================================================" "ERROR"
    }

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
