<#
.SYNOPSIS
    Syncs Azure File Shares from source to destination storage accounts using AzCopy.

.DESCRIPTION
    Reads a CSV of source storage account ARM Resource IDs with destination account names
    and resource groups. For each pair, discovers all file shares on the source and runs
    azcopy sync to keep the destination shares in sync.

    Uses azcopy sync (not azcopy copy):
      - Compares source vs destination and transfers only changed files
      - Much faster on subsequent runs than azcopy copy (skips unchanged files)
      - Optionally propagates deletions with Mirror mode

    SyncMode options:
      - Additive (default): Syncs new and changed files. Never deletes files on the
        destination, even if they no longer exist on the source.
      - Mirror: Syncs new and changed files AND deletes files on the destination that
        do not exist on the source. Use with caution — data on the destination that
        has no corresponding source file will be permanently removed.

    Data flows directly between Azure storage endpoints (server-side copy) — nothing
    passes through the client machine.

    Firewall handling: Both source and destination firewalls are temporarily opened
    (if restrictive) for the AzCopy data transfer, then restored via try/finally.

    The script is idempotent — safe to re-run at any frequency.

    IMPORTANT: This script does NOT create storage accounts or file shares. Both must
    already exist. Use Create-DRFileShareAccounts.ps1 for initial DR setup.

.PARAMETER CsvPath
    Path to CSV with headers: SourceResourceId, DestStorageAccountName, DestResourceGroupName

.PARAMETER DestSubscriptionId
    Optional. Subscription for destination accounts. Defaults to source subscription.

.PARAMETER SyncMode
    Additive (default) or Mirror.
    Additive = sync changes, never delete on destination.
    Mirror   = sync changes + delete files on destination that don't exist on source.

.PARAMETER DryRun
    Switch. Dry run — shows what would be synced without making changes.

.EXAMPLE
    # Sync file shares (Additive — no deletes)
    .\Sync-DRFileShares.ps1 -CsvPath ".\resources.csv"

.EXAMPLE
    # Dry run — preview what would be synced
    .\Sync-DRFileShares.ps1 -CsvPath ".\resources.csv" -DryRun

.EXAMPLE
    # Mirror mode — sync with deletions
    .\Sync-DRFileShares.ps1 -CsvPath ".\resources.csv" -SyncMode "Mirror"

.EXAMPLE
    # Cross-subscription
    .\Sync-DRFileShares.ps1 -CsvPath ".\resources.csv" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

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
      - Validating storage account pairs and file share mappings against your
        organisational standards
      - Understanding the implications of Mirror mode (--delete-destination=true)
        which permanently removes files on the destination that do not exist on source
      - Applying appropriate security hardening, access controls, network restrictions,
        and compliance policies to all storage accounts
      - Ensuring data residency, sovereignty, and regulatory requirements are met
      - Testing in lower environments (development / staging) before running against
        production storage accounts
      - Following your organisation's approved change management, deployment, and
        operational practices

    Always run with -DryRun first to review planned changes before executing live.
    Use -SyncMode "Additive" (default) unless you explicitly need deletion propagation.
#>

param (
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$false)][string]$DestSubscriptionId,
    [Parameter(Mandatory=$false)][ValidateSet("Additive","Mirror")][string]$SyncMode = "Additive",
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

    if ($PolicyInfo) { return $PolicyInfo }

    if ($Combined -match '"message"\s*:\s*"([^"]+)"') { return $Matches[1] }
    if ($Combined -match "(?m)^.*ERROR[:\s]+(.+)$") { return $Matches[1].Trim() }

    $Lines = $Combined -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($Lines.Count -gt 0) {
        $LastLine = $Lines[-1].Trim()
        if ($LastLine.Length -gt 500) { $LastLine = $LastLine.Substring(0, 500) + "..." }
        return $LastLine
    }

    return "Unknown error"
}

function Invoke-AzCommand {
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

    $CurrentProps = az storage account show --name $AccountName --resource-group $ResourceGroup --query "{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass}" -o json 2>$null | ConvertFrom-Json

    $OriginalSettings = @{
        PublicAccess  = if ($CurrentProps.publicNetworkAccess) { $CurrentProps.publicNetworkAccess } else { "Enabled" }
        DefaultAction = if ($CurrentProps.defaultAction) { $CurrentProps.defaultAction } else { "Allow" }
        Bypass        = if ($CurrentProps.bypass) { $CurrentProps.bypass } else { "None" }
    }

    if ($OriginalSettings.DefaultAction -eq "Deny" -or $OriginalSettings.PublicAccess -eq "Disabled") {
        Write-Log "    Temporarily opening firewall on '$AccountName' for data operations..."

        if ($OriginalSettings.PublicAccess -eq "Disabled") {
            az storage account update --name $AccountName --resource-group $ResourceGroup --public-network-access Enabled -o none 2>$null
        }
        az storage account update --name $AccountName --resource-group $ResourceGroup --default-action Allow -o none 2>$null

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
    Write-Log "  SyncMode : $SyncMode"
    if ($SyncMode -eq "Mirror") {
        Write-Log "  WARNING  : Mirror mode will DELETE files on dest not in source" "WARN"
    }
    Write-Log "=================================================================="

    # ── Results tracking ─────────────────────────────────────────
    $Results = @()
    $RowNum = 0
    $TotalSharesSynced = 0
    $TotalSharesFailed = 0
    $RowsSkipped = 0
    $RowsFailed = 0

    # ── Process each CSV row ─────────────────────────────────────
    foreach ($Row in $AccountList) {
        $RowNum++
        $RowStartTime = Get-Date
        $Progress = "$RowNum/$TotalRows"

        # Per-row variables — reset for safety
        $OriginalSourceNetworkSettings = $null
        $OriginalDestNetworkSettings = $null
        $SourceKey = $null
        $DestKey = $null
        $SourceSas = $null
        $DestSas = $null
        $SharesSyncedThisRow = 0
        $SharesFailedThisRow = 0

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

            # ── Step 2: Validate source account exists ──
            Write-Log "  Validating source: $($Source.AccountName)..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null
            $SourceCheck = az storage account show --name $Source.AccountName --resource-group $Source.ResourceGroup --query "{name:name, defaultAction:networkRuleSet.defaultAction, publicNetworkAccess:publicNetworkAccess}" -o json 2>$null
            if (-not $SourceCheck) {
                throw "Source account '$($Source.AccountName)' not found in RG '$($Source.ResourceGroup)'."
            }
            $SourceProps = $SourceCheck | ConvertFrom-Json
            $SourceDefaultAction = if ($SourceProps.defaultAction) { $SourceProps.defaultAction } else { "Allow" }
            $SourcePublicAccess  = if ($SourceProps.publicNetworkAccess) { $SourceProps.publicNetworkAccess } else { "Enabled" }

            # ── Step 3: Look up destination account ──
            Write-Log "  Looking up destination: $DestAccountName..." "" $Progress
            az account set --subscription $DestSubId | Out-Null
            $DestCheck = az storage account show --name $DestAccountName --resource-group $DestRGName --query "{name:name, defaultAction:networkRuleSet.defaultAction, publicNetworkAccess:publicNetworkAccess}" -o json 2>$null
            if (-not $DestCheck) {
                throw "Destination account '$DestAccountName' not found in RG '$DestRGName' (sub: $DestSubId). Create it first using Create-DRFileShareAccounts.ps1."
            }
            $DestProps = $DestCheck | ConvertFrom-Json
            $DestDefaultAction = if ($DestProps.defaultAction) { $DestProps.defaultAction } else { "Allow" }
            $DestPublicAccess  = if ($DestProps.publicNetworkAccess) { $DestProps.publicNetworkAccess } else { "Enabled" }

            # ── Step 4: List source shares via ARM REST API (bypasses firewall) ──
            Write-Log "  Listing file shares on source via ARM API..." "" $Progress
            az account set --subscription $Source.SubscriptionId | Out-Null
            $ArmSharesUrl = "https://management.azure.com/subscriptions/$($Source.SubscriptionId)/resourceGroups/$($Source.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Source.AccountName)/fileServices/default/shares?api-version=2023-05-01"
            $ArmSharesJson = az rest --method GET --url $ArmSharesUrl -o json 2>$null

            $SourceShares = @()
            if ($ArmSharesJson) {
                $ArmSharesObj = $ArmSharesJson | ConvertFrom-Json
                if ($ArmSharesObj.value) {
                    $SourceShares = @($ArmSharesObj.value | ForEach-Object { $_.name })
                }
            }

            $ShareCount = $SourceShares.Count
            Write-Log "  Found $ShareCount file share(s) on source." "" $Progress

            if ($ShareCount -eq 0) {
                Write-Log "  No file shares found. Skipping." "WARN" $Progress
                $RowsSkipped++
                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; SharesSynced=0; SharesFailed=0
                    SyncMode=$SyncMode; Status="Skipped"; Notes="No file shares on source"
                }
                continue
            }

            # ── DryRun path ──
            if ($DryRun) {
                Write-Log "  [DRYRUN] Would generate SAS tokens (4h expiry)" "DRYRUN" $Progress
                if ($SourceDefaultAction -eq "Deny" -or $SourcePublicAccess -eq "Disabled") {
                    Write-Log "  [DRYRUN] Would temporarily open source firewall (defaultAction=$SourceDefaultAction, publicAccess=$SourcePublicAccess)" "DRYRUN" $Progress
                }
                if ($DestDefaultAction -eq "Deny" -or $DestPublicAccess -eq "Disabled") {
                    Write-Log "  [DRYRUN] Would temporarily open dest firewall (defaultAction=$DestDefaultAction, publicAccess=$DestPublicAccess)" "DRYRUN" $Progress
                }
                foreach ($ShareName in $SourceShares) {
                    Write-Log "  [DRYRUN] Would azcopy sync share: $ShareName (SyncMode: $SyncMode)" "DRYRUN" $Progress
                }
                if ($SourceDefaultAction -eq "Deny" -or $SourcePublicAccess -eq "Disabled") {
                    Write-Log "  [DRYRUN] Would restore source firewall" "DRYRUN" $Progress
                }
                if ($DestDefaultAction -eq "Deny" -or $DestPublicAccess -eq "Disabled") {
                    Write-Log "  [DRYRUN] Would restore dest firewall" "DRYRUN" $Progress
                }

                $Results += [PSCustomObject]@{
                    SourceAccount=$Source.AccountName; DestAccount=$DestAccountName; DestResourceGroup=$DestRGName
                    DestSubscription=$DestSubId; SharesSynced=$ShareCount; SharesFailed=0
                    SyncMode=$SyncMode; Status="DryRun"; Notes=""
                }
                $RowElapsed = (Get-Date) - $RowStartTime
                Write-Log "  Done: $($Source.AccountName) -> $DestAccountName ($(Format-Duration $RowElapsed))" "SUCCESS" $Progress
                continue
            }

            # ── Step 5: Generate SAS tokens ──
            Write-Log "  Generating SAS tokens (4h expiry)..." "" $Progress
            $Expiry = (Get-Date).AddHours(4).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Source SAS (read + list)
            az account set --subscription $Source.SubscriptionId | Out-Null
            $SourceKey = (az storage account keys list -g $Source.ResourceGroup -n $Source.AccountName --query "[0].value" -o tsv)
            if ([string]::IsNullOrWhiteSpace($SourceKey)) {
                throw "Failed to retrieve key for source account '$($Source.AccountName)'."
            }
            $SourceSasRaw = az storage account generate-sas --account-name $Source.AccountName --account-key $SourceKey --services f --resource-types sco --permissions rl --expiry $Expiry -o tsv
            $SourceSas = (($SourceSasRaw | Out-String) -replace "[\r\n\s]", "").TrimStart('?')

            # Destination SAS (all permissions — azcopy sync needs read+write+delete for comparison and Mirror mode)
            az account set --subscription $DestSubId | Out-Null
            $DestKey = (az storage account keys list -g $DestRGName -n $DestAccountName --query "[0].value" -o tsv)
            if ([string]::IsNullOrWhiteSpace($DestKey)) {
                throw "Failed to retrieve key for destination account '$DestAccountName'."
            }
            $DestSasRaw = az storage account generate-sas --account-name $DestAccountName --account-key $DestKey --services f --resource-types sco --permissions acdlrwup --expiry $Expiry -o tsv
            $DestSas = (($DestSasRaw | Out-String) -replace "[\r\n\s]", "").TrimStart('?')

            # ── Step 6: Open source firewall if restrictive ──
            if ($SourceDefaultAction -eq "Deny" -or $SourcePublicAccess -eq "Disabled") {
                az account set --subscription $Source.SubscriptionId | Out-Null
                $OriginalSourceNetworkSettings = Open-StorageFirewall -AccountName $Source.AccountName -ResourceGroup $Source.ResourceGroup
            }

            # ── Step 7: Open dest firewall if restrictive ──
            if ($DestDefaultAction -eq "Deny" -or $DestPublicAccess -eq "Disabled") {
                az account set --subscription $DestSubId | Out-Null
                $OriginalDestNetworkSettings = Open-StorageFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName
            }

            # Clear env var to prevent SAS cross-contamination
            Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue

            # ── Step 8: AzCopy sync each share ──
            try {
                foreach ($ShareName in $SourceShares) {
                    $SourceUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $Source.AccountName, $ShareName, $SourceSas
                    $DestUrl   = "https://{0}.file.core.windows.net/{1}?{2}" -f $DestAccountName, $ShareName, $DestSas

                    Write-Log "    Syncing share: $ShareName (SyncMode: $SyncMode)..." "" $Progress

                    $azCopyArgs = @(
                        "sync",
                        $SourceUrl,
                        $DestUrl,
                        "--preserve-smb-permissions=true",
                        "--preserve-smb-info=true",
                        "--recursive=true"
                    )

                    # Mirror mode: propagate deletions
                    if ($SyncMode -eq "Mirror") {
                        $azCopyArgs += "--delete-destination=true"
                    }

                    & azcopy $azCopyArgs

                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "    Share synced: $ShareName" "SUCCESS" $Progress
                        $SharesSyncedThisRow++
                        $TotalSharesSynced++
                    } else {
                        Write-Log "    AzCopy failed for share '$ShareName' (exit code: $LASTEXITCODE)" "WARN" $Progress
                        $SharesFailedThisRow++
                        $TotalSharesFailed++
                    }
                }
            } finally {
                # ── Step 9: Restore source firewall (always, even on error) ──
                if ($OriginalSourceNetworkSettings) {
                    try {
                        az account set --subscription $Source.SubscriptionId | Out-Null
                        Restore-StorageFirewall -AccountName $Source.AccountName -ResourceGroup $Source.ResourceGroup -OriginalSettings $OriginalSourceNetworkSettings
                        $OriginalSourceNetworkSettings = $null
                    } catch {
                        Write-Log "  WARNING: Failed to restore source firewall on '$($Source.AccountName)'. Check manually." "WARN" $Progress
                    }
                }

                # ── Step 10: Restore dest firewall (always, even on error) ──
                if ($OriginalDestNetworkSettings) {
                    try {
                        az account set --subscription $DestSubId | Out-Null
                        Restore-StorageFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName -OriginalSettings $OriginalDestNetworkSettings
                        $OriginalDestNetworkSettings = $null
                    } catch {
                        Write-Log "  WARNING: Failed to restore dest firewall on '$DestAccountName'. Check manually." "WARN" $Progress
                    }
                }

                # Cleanup sensitive material
                $SourceKey = $null
                $DestKey = $null
                $SourceSas = $null
                $DestSas = $null
                Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue
            }

            # ── Step 11: Record results ──
            $RowStatus = if ($SharesFailedThisRow -eq 0) { "Completed" }
                         elseif ($SharesSyncedThisRow -gt 0) { "PartialFailure" }
                         else { "Failed" }

            if ($RowStatus -eq "Failed") { $RowsFailed++ }

            $Results += [PSCustomObject]@{
                SourceAccount    = $Source.AccountName
                DestAccount      = $DestAccountName
                DestResourceGroup = $DestRGName
                DestSubscription = $DestSubId
                SharesSynced     = $SharesSyncedThisRow
                SharesFailed     = $SharesFailedThisRow
                SyncMode         = $SyncMode
                Status           = $RowStatus
                Notes            = ""
            }

            $RowElapsed = (Get-Date) - $RowStartTime
            Write-Log "  Done: $($Source.AccountName) -> $DestAccountName ($(Format-Duration $RowElapsed))" "SUCCESS" $Progress

        } catch {
            $ErrorMessage = $_.Exception.Message
            Write-Log "ERROR: $ErrorMessage" "ERROR" $Progress
            $RowsFailed++

            # Safety: restore firewalls even on error
            if ($OriginalSourceNetworkSettings) {
                try {
                    az account set --subscription $Source.SubscriptionId | Out-Null
                    Restore-StorageFirewall -AccountName $Source.AccountName -ResourceGroup $Source.ResourceGroup -OriginalSettings $OriginalSourceNetworkSettings
                } catch {
                    Write-Log "  WARNING: Failed to restore source firewall on '$($Source.AccountName)'. Check manually." "WARN" $Progress
                }
            }
            if ($OriginalDestNetworkSettings) {
                try {
                    az account set --subscription $DestSubId | Out-Null
                    Restore-StorageFirewall -AccountName $DestAccountName -ResourceGroup $DestRGName -OriginalSettings $OriginalDestNetworkSettings
                } catch {
                    Write-Log "  WARNING: Failed to restore dest firewall on '$DestAccountName'. Check manually." "WARN" $Progress
                }
            }

            $Results += [PSCustomObject]@{
                SourceAccount = if ($Source) { $Source.AccountName } else { "N/A" }
                DestAccount = if ($DestAccountName) { $DestAccountName } else { "N/A" }
                DestResourceGroup = if ($DestRGName) { $DestRGName } else { "N/A" }
                DestSubscription = if ($DestSubId) { $DestSubId } else { "N/A" }
                SharesSynced = 0
                SharesFailed = 0
                SyncMode = $SyncMode
                Status = "Failed"
                Notes = $ErrorMessage
            }
            continue
        }
    }

    # ── Export results CSV ────────────────────────────────────────
    $TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultsPath = ".\DRFileShareSyncResults_$TimestampStr.csv"

    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $ResultsPath -NoTypeInformation -Encoding UTF8
        Write-Log "Results CSV exported to: $ResultsPath"
    }

    # ── Summary ──────────────────────────────────────────────────
    $TotalElapsed = (Get-Date) - $ScriptStartTime
    $TotalDuration = Format-Duration $TotalElapsed

    Write-Log "=================================================================="
    Write-Log "  SUMMARY                                          ($TotalDuration)"
    Write-Log "=================================================================="
    Write-Log "  Total rows processed         : $RowNum of $TotalRows"
    Write-Log "  SyncMode                     : $SyncMode"
    Write-Log "  Total shares synced          : $TotalSharesSynced"
    Write-Log "  Total shares failed          : $TotalSharesFailed"
    Write-Log "  Rows skipped                 : $RowsSkipped"
    Write-Log "  Rows failed                  : $RowsFailed"
    Write-Log "  Total elapsed time           : $TotalDuration"
    if ($Results.Count -gt 0) {
        Write-Log "  Results CSV                  : $ResultsPath"
    }
    Write-Log "=================================================================="

    # Failed rows detail
    $FailedResults = @($Results | Where-Object { $_.Status -eq "Failed" -or $_.Status -eq "PartialFailure" })
    if ($FailedResults.Count -gt 0) {
        Write-Log ""
        Write-Log "  FAILED DETAIL:" "ERROR"
        Write-Log "  ----------------------------------------------------------" "ERROR"
        foreach ($F in $FailedResults) {
            Write-Log "  $($F.SourceAccount) -> $($F.DestAccount): $($F.Status)" "ERROR"
            if ($F.Notes) {
                Write-Log "    Reason: $($F.Notes)" "ERROR"
            }
            if ($F.SharesFailed -gt 0) {
                Write-Log "    Shares synced: $($F.SharesSynced), failed: $($F.SharesFailed)" "ERROR"
            }
        }
        Write-Log "  ----------------------------------------------------------" "ERROR"
    }

    Write-Log "=================================================================="

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
