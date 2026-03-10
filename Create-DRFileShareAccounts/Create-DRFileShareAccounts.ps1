<#
.SYNOPSIS
    Creates DR file share storage accounts and copies file shares from source accounts.

.DESCRIPTION
    Reads a CSV of source storage account ARM Resource IDs with destination account names
    and resource group names. Creates matching storage accounts in a target region,
    replicating source configuration (kind, SKU, TLS, access tier, networking).
    Lists all file shares from source and creates matching shares on destination
    (replicating quota and access tier). Then copies data using AzCopy server-side
    (S2S) copy, preserving SMB/NTFS permissions and directory structures.

    The script replicates whatever kind and SKU the source account has (StorageV2,
    FileStorage, etc.). If the source account has 0 file shares, the account and
    resource group are still created — only the share creation and data copy steps
    are skipped.

    If the destination resource group does not exist, it is created automatically
    in the destination region.

    Networking (firewall) is applied LAST — after shares are created and data is
    copied — to avoid blocking operations on the destination. For source accounts
    with firewall restrictions, the script temporarily opens the source firewall
    for AzCopy, then restores the original settings.

    The script is idempotent — safe to re-run:
      - Existing storage accounts are skipped (not recreated), but new shares are synced.
      - Existing shares on the destination are not affected.
      - For existing accounts with firewall restrictions, the firewall is automatically
        opened temporarily, data is synced, and the original settings are restored.

    Pre-validation: All rows are validated BEFORE any Azure operations begin.
    Invalid names, duplicate names, and malformed ARM Resource IDs are reported
    upfront so you can fix the CSV without waiting for partial execution.

.PARAMETER CsvPath
    Path to CSV with headers: SourceResourceId, DestStorageAccountName, DestResourceGroupName

.PARAMETER DestRegion
    Azure region for destination storage accounts (e.g., "switzerlandnorth").

.PARAMETER DestSubscriptionId
    Optional. Subscription for destination accounts. Defaults to source subscription.

.PARAMETER DryRun
    Switch. Dry run — shows what would be created without making changes.

.EXAMPLE
    # Create DR accounts with file share copy
    ./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth"

.EXAMPLE
    # Dry run (preview changes without creating anything)
    ./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DryRun

.EXAMPLE
    # Create DR accounts in a different subscription
    ./Create-DRFileShareAccounts.ps1 -CsvPath "./resources.csv" -DestRegion "switzerlandnorth" -DestSubscriptionId "xxx-yyy"

.NOTES
    Author  : Sarmad Jari
    Version : 1.0
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
      - Validating storage account naming, SKU selections, and file share quotas
        against your organisational standards
      - Applying appropriate security hardening, access controls, network restrictions,
        and compliance policies to all storage accounts in both source and destination regions
      - Ensuring data residency, sovereignty, and regulatory requirements are met
        for the target region before executing any data copy
      - Testing in lower environments (development / staging) before running against
        production storage accounts
      - Verifying data copy completeness, RPO targets, and failover procedures are fit
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
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# Disable AzCopy auto-login to prevent SAS URL parser corruption
$env:AZCOPY_AUTO_LOGIN_TYPE = "NONE"

# ── Shared Functions ─────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Progress
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
        $Errors += "Name must contain only lowercase letters and numbers"
    }
    if ($Errors.Count -gt 0) { return ($Errors -join "; ") }
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

function Open-StorageFirewall {
    <#
    .SYNOPSIS
        Temporarily opens a storage account firewall for data operations.
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
        Write-Log "    Temporarily opening firewall on '$AccountName' for data operations..."

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

function Restore-StorageFirewall {
    <#
    .SYNOPSIS
        Restores a storage account firewall to its original settings.
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
        $CsvRowNum = $i + 1  # 1-based for display

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

    # ── Results tracking ─────────────────────────────────────────
    $Results = @()
    $RowNum = 0
    $AccountsCreated = 0
    $AccountsExisted = 0
    $AccountsSkipped = 0
    $AccountsFailed = 0
    $TotalSharesCreated = 0
    $TotalSharesCopied = 0

    # ── Track resource groups already ensured ─────────────────────
    $EnsuredResourceGroups = @{}

    # ══════════════════════════════════════════════════════════════
    # ── MAIN PROCESSING LOOP ─────────────────────────────────────
    # ══════════════════════════════════════════════════════════════
    foreach ($Row in $AccountList) {
        $RowNum++
        $RowStartTime = Get-Date
        $Progress = "$RowNum/$TotalRows"

        # Reset per-row variables
        $Source = $null
        $DestAccountName = $null
        $DestRGName = $null
        $DestSubId = $null
        $OriginalDestNetworkSettings = $null
        $OriginalSourceNetworkSettings = $null

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
                    SharesCreated      = 0
                    SharesCopied       = 0
                    NetworkingConfig   = ""
                    Notes              = $NameError
                }
                $AccountsSkipped++
                continue
            }

            # 3. Read source properties
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

            # 6. Check if destination storage account already exists (includes network props for firewall auto-detect)
            $DestCheckJson = az storage account show --name $DestAccountName --resource-group $DestRGName --query "{name:name, defaultAction:networkRuleSet.defaultAction, publicNetworkAccess:publicNetworkAccess}" -o json 2>$null
            $AccountCreatedThisRun = $false

            if ($DestCheckJson) {
                $DestCheckProps = $DestCheckJson | ConvertFrom-Json
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

                # Auto-detect: if dest has restrictive firewall, temporarily open it for data operations
                $DestDefaultAction = if ($DestCheckProps.defaultAction) { $DestCheckProps.defaultAction } else { "Allow" }
                $DestPublicAccess  = if ($DestCheckProps.publicNetworkAccess) { $DestCheckProps.publicNetworkAccess } else { "Enabled" }

                if ($DestDefaultAction -eq "Deny" -or $DestPublicAccess -eq "Disabled") {
                    if (-not $DryRun) {
                        Write-Log "  Existing account has restrictive firewall (defaultAction=$DestDefaultAction, publicAccess=$DestPublicAccess). Temporarily opening..." "" $Progress
                        $OriginalDestNetworkSettings = Open-StorageFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName
                    } else {
                        Write-Log "  [DRYRUN] Would temporarily open dest firewall (defaultAction=$DestDefaultAction, publicAccess=$DestPublicAccess)" "DRYRUN" $Progress
                    }
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
                    "--allow-blob-public-access", $SourceAllowBlobPublicAccess.ToString().ToLower(),
                    "-o", "none"
                )

                # Access tier only for non-FileStorage accounts (FileStorage does not support --access-tier)
                if ($SourceKind -ne "FileStorage") {
                    $CreateArgs += @("--access-tier", $SourceAccessTier)
                }

                if ($SourceHns) {
                    $CreateArgs += @("--hns", "true")
                }

                if ($SourceAccountTags.Count -gt 0) {
                    $CreateArgs += @("--tags") + $SourceAccountTags
                }

                if ($DryRun) {
                    Write-Log "  [DRYRUN] Would create storage account '$DestAccountName'" "DRYRUN" $Progress
                    Write-Log "    kind=$SourceKind sku=$SourceSku hns=$SourceHns tls=$SourceTls tier=$SourceAccessTier" "DRYRUN" $Progress
                    $AccountCreatedThisRun = $true
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

            # 7. List source file shares via ARM API (bypasses source firewall)
            Write-Log "  Listing file shares on source '$($Source.AccountName)' (via ARM)..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null

            $ArmSharesUrl = "https://management.azure.com/subscriptions/$($Source.SubscriptionId)/resourceGroups/$($Source.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Source.AccountName)/fileServices/default/shares?api-version=2023-05-01"
            $ArmSharesJson = az rest --method GET --url $ArmSharesUrl -o json 2>$null

            $SourceShares = @()
            if ($ArmSharesJson) {
                $ArmSharesObj = $ArmSharesJson | ConvertFrom-Json
                $SourceShares = @($ArmSharesObj.value | ForEach-Object {
                    @{
                        Name       = $_.name
                        Quota      = $_.properties.shareQuota
                        AccessTier = $_.properties.accessTier
                    }
                })
            }

            $ShareCount = $SourceShares.Count
            Write-Log "  Found $ShareCount file share(s) on source." "" $Progress

            # 8. Create matching shares on destination via ARM (az storage share-rm create)
            $SharesCreatedThisRow = 0
            if ($ShareCount -gt 0) {
                az account set --subscription $DestSubId | Out-Null

                foreach ($Share in $SourceShares) {
                    $ShareName = $Share.Name
                    $ShareQuota = $Share.Quota

                    if ($DryRun) {
                        Write-Log "    [DRYRUN] Would create share: $ShareName (quota=${ShareQuota}GB)" "DRYRUN" $Progress
                        $SharesCreatedThisRow++
                    } else {
                        $ShareCreateArgs = @(
                            "storage", "share-rm", "create",
                            "--storage-account", $DestAccountName,
                            "--resource-group", $DestRGName,
                            "--name", $ShareName,
                            "--quota", $ShareQuota.ToString(),
                            "-o", "none"
                        )

                        # Access tier only for non-FileStorage (FileStorage shares are always Premium)
                        if ($SourceKind -ne "FileStorage" -and $Share.AccessTier) {
                            $ShareCreateArgs += @("--access-tier", $Share.AccessTier)
                        }

                        Invoke-AzCommand -Arguments $ShareCreateArgs -IgnoreExitCode | Out-Null
                        Write-Log "    Share created/verified: $ShareName (quota=${ShareQuota}GB)" "" $Progress
                        $SharesCreatedThisRow++
                        $TotalSharesCreated++
                    }
                }
            }

            # 9. AzCopy server-side (S2S) copy — data transfer
            $SharesCopiedThisRow = 0

            if (-not $DryRun -and $ShareCount -gt 0) {
                Write-Log "  Generating SAS tokens for AzCopy S2S copy..." "" $Progress

                $Expiry = (Get-Date).AddHours(4).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

                # Source SAS (read + list)
                az account set --subscription $Source.SubscriptionId | Out-Null
                $SourceKey = (az storage account keys list -g $Source.ResourceGroup -n $Source.AccountName --query "[0].value" -o tsv)
                if ([string]::IsNullOrWhiteSpace($SourceKey)) {
                    throw "Failed to retrieve key for source account '$($Source.AccountName)'."
                }
                $SourceSasRaw = az storage account generate-sas --account-name $Source.AccountName --account-key $SourceKey --services f --resource-types sco --permissions rl --expiry $Expiry -o tsv
                $SourceSas = (($SourceSasRaw | Out-String) -replace "[\r\n\s]", "").TrimStart('?')

                # Destination SAS (all permissions)
                az account set --subscription $DestSubId | Out-Null
                $DestKey = (az storage account keys list -g $DestRGName -n $DestAccountName --query "[0].value" -o tsv)
                if ([string]::IsNullOrWhiteSpace($DestKey)) {
                    throw "Failed to retrieve key for destination account '$DestAccountName'."
                }
                $DestSasRaw = az storage account generate-sas --account-name $DestAccountName --account-key $DestKey --services f --resource-types sco --permissions acdlrwup --expiry $Expiry -o tsv
                $DestSas = (($DestSasRaw | Out-String) -replace "[\r\n\s]", "").TrimStart('?')

                # Temporarily open source firewall if needed for AzCopy S2S copy
                if ($SourceDefaultAction -eq "Deny" -or $SourcePublicAccess -eq "Disabled") {
                    az account set --subscription $Source.SubscriptionId | Out-Null
                    $OriginalSourceNetworkSettings = Open-StorageFirewall -AccountName $Source.AccountName -ResourceGroup $Source.ResourceGroup
                }

                # Clear env var to prevent SAS cross-contamination
                Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue

                # AzCopy S2S copy each share
                try {
                    foreach ($Share in $SourceShares) {
                        $ShareName = $Share.Name
                        $SourceUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $Source.AccountName, $ShareName, $SourceSas
                        $DestUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $DestAccountName, $ShareName, $DestSas

                        Write-Log "    Copying share (S2S): $ShareName..." "" $Progress

                        # Server-side copy — data flows directly between Azure storage endpoints
                        $azCopyArgs = @(
                            "copy",
                            $SourceUrl,
                            $DestUrl,
                            "--s2s-preserve-properties=true",
                            "--s2s-preserve-access-tier=true",
                            "--preserve-smb-permissions=true",
                            "--preserve-smb-info=true",
                            "--recursive"
                        )
                        & azcopy $azCopyArgs

                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "    Share copied: $ShareName" "SUCCESS" $Progress
                            $SharesCopiedThisRow++
                            $TotalSharesCopied++
                        } else {
                            Write-Log "    AzCopy failed for share '$ShareName' (exit code: $LASTEXITCODE)" "WARN" $Progress
                        }
                    }
                } finally {
                    # Restore source firewall even on error
                    if ($OriginalSourceNetworkSettings) {
                        try {
                            az account set --subscription $Source.SubscriptionId | Out-Null
                            Restore-StorageFirewall -AccountName $Source.AccountName -ResourceGroup $Source.ResourceGroup -OriginalSettings $OriginalSourceNetworkSettings
                            $OriginalSourceNetworkSettings = $null
                        } catch {
                            Write-Log "  WARNING: Failed to restore source firewall on '$($Source.AccountName)'. Check manually." "WARN" $Progress
                        }
                    }

                    # Cleanup sensitive material
                    $SourceKey = $null
                    $DestKey = $null
                    $SourceSas = $null
                    $DestSas = $null
                    Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue
                }

            } elseif ($DryRun -and $ShareCount -gt 0) {
                Write-Log "  [DRYRUN] Would generate SAS tokens and copy $ShareCount share(s) via AzCopy (server-side)" "DRYRUN" $Progress
                if ($SourceDefaultAction -eq "Deny" -or $SourcePublicAccess -eq "Disabled") {
                    Write-Log "  [DRYRUN] Would temporarily open source firewall for AzCopy S2S copy" "DRYRUN" $Progress
                }
            }

            # 10. Apply networking LAST — after shares and data copy are done
            if (-not $DryRun) {
                if ($OriginalDestNetworkSettings) {
                    # Existing account: restore the original firewall settings
                    az account set --subscription $DestSubId | Out-Null
                    Restore-StorageFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName -OriginalSettings $OriginalDestNetworkSettings
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
                if ($AccountCreatedThisRun -or $OriginalDestNetworkSettings) {
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
                SharesCreated      = $SharesCreatedThisRow
                SharesCopied       = $SharesCopiedThisRow
                NetworkingConfig   = $NetworkingConfig
                Notes              = ""
            }

            Write-Log "  Done: $($Source.AccountName) -> $DestAccountName ($RowDuration)" "SUCCESS" $Progress

        } catch {
            $ErrorMessage = $_.Exception.Message
            Write-Log "ERROR: $ErrorMessage" "ERROR" $Progress
            $AccountsFailed++

            # Safety: if we opened the source firewall, try to restore it even on error
            if ($OriginalSourceNetworkSettings -and -not $DryRun) {
                try {
                    az account set --subscription $Source.SubscriptionId | Out-Null
                    Restore-StorageFirewall -AccountName $Source.AccountName -ResourceGroup $Source.ResourceGroup -OriginalSettings $OriginalSourceNetworkSettings
                } catch {
                    Write-Log "  WARNING: Failed to restore source firewall on '$($Source.AccountName)'. Please check manually." "WARN" $Progress
                }
            }

            # Safety: if we opened the dest firewall, try to restore it even on error
            if ($OriginalDestNetworkSettings -and -not $DryRun) {
                try {
                    az account set --subscription $DestSubId | Out-Null
                    Restore-StorageFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName -OriginalSettings $OriginalDestNetworkSettings
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
                SharesCreated      = 0
                SharesCopied       = 0
                NetworkingConfig   = ""
                Notes              = $ErrorMessage
            }
            continue
        }
    }

    # ── Export results CSV ─────────────────────────────────────────
    $TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultsPath = ".\DRFileShareResults_$TimestampStr.csv"
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
    Write-Log "  Total shares created      : $TotalSharesCreated"
    Write-Log "  Total shares copied (S2S) : $TotalSharesCopied"
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
} finally {
    # Clean up environment variables
    if (Test-Path env:AZCOPY_AUTO_LOGIN_TYPE) {
        Remove-Item env:AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue
    }
    if (Test-Path env:AZURE_STORAGE_SAS_TOKEN) {
        Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue
    }
}
