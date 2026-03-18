<#
.SYNOPSIS
    Discovers and rehydrates Archive-tier blobs in an Azure Storage Account.

.DESCRIPTION
    Performs a complete, account-wide discovery and rehydration of all Archive-tier blobs
    in a given Azure Storage Account. Designed for ADLS Gen2 (HNS-enabled) accounts where
    the Azure Portal does not expose the "Change Access Tier" option on individual blobs,
    but works equally well on standard (non-HNS) blob storage accounts.

    The script:
      1. Lists all containers (or a single container if specified)
      2. Paginates through all blobs in batches of 5000
      3. Identifies blobs where Access Tier = Archive
      4. Skips blobs that are already rehydrating (rehydrate-pending-to-hot/cool)
      5. Issues Set Blob Tier commands to rehydrate each Archive blob
      6. Generates three output files: full log, CSV report, and summary

    Rehydrate priority options:
      - Standard (default): Up to 15 hours, lower cost
      - High: Under 1 hour for blobs < 10 GB, higher cost

    DryRun mode: Discovers and reports all Archive blobs without issuing any
    tier change commands. Always run with -DryRun first.

.PARAMETER StorageAccountName
    Required. Name of the Azure Storage Account to scan.

.PARAMETER ResourceGroupName
    Required. Resource group containing the storage account.

.PARAMETER SubscriptionId
    Optional. Subscription ID. If omitted, uses the current Azure CLI subscription context.

.PARAMETER ContainerName
    Optional. Scan only this container. If omitted, scans ALL containers in the account.

.PARAMETER TargetTier
    Optional. Target access tier for rehydration. Valid values: Hot, Cool. Default: Hot.

.PARAMETER RehydratePriority
    Optional. Rehydrate priority. Valid values: Standard, High. Default: Standard.
    Standard = up to 15 hours, lower cost. High = under 1 hour for blobs < 10 GB, higher cost.

.PARAMETER OutputPath
    Optional. Directory for output files (log, CSV, summary).
    Defaults to current directory.

.PARAMETER DryRun
    Switch. Discovers and reports Archive blobs without issuing tier change commands.

.EXAMPLE
    # Dry run — discover Archive blobs without rehydrating
    .\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -DryRun

.EXAMPLE
    # Rehydrate all Archive blobs to Hot tier with Standard priority
    .\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG"

.EXAMPLE
    # Rehydrate to Cool tier with High priority
    .\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -TargetTier "Cool" -RehydratePriority "High"

.EXAMPLE
    # Single container only
    .\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -ContainerName "mycontainer"

.EXAMPLE
    # Cross-subscription with custom output path
    .\Rehydrate-ArchiveBlobs.ps1 -StorageAccountName "mystorageacct" -ResourceGroupName "myRG" -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -OutputPath "C:\reports"

.NOTES
    Author  : Sarmad Jari
    Version : 1.0
    Date    : 2026-03-18
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

    This script is shared strictly as a proof-of-concept (POC) / sample code for
    testing and evaluation purposes only. Use against production environments is
    entirely at your own risk.

    NOT AN OFFICIAL PRODUCT
    This script is an independent, personal work created and shared by an individual
    to assist the community. It is NOT an official product, service, or deliverable
    of any company, employer, or organisation. It is not endorsed, certified, vetted,
    or supported by any company or vendor, including Microsoft. Any use of company
    names, product names, or trademarks is solely for identification purposes and
    does not imply affiliation, sponsorship, or endorsement.

    NO SUPPORT OR MAINTENANCE OBLIGATION
    The author(s) are under no obligation to provide support, maintenance, updates,
    enhancements, or bug fixes. No obligation exists to respond to issues, feature
    requests, or pull requests. If this script requires modifications for your
    environment, you are solely responsible for implementing them.

    CONFIGURATION AND SETTINGS RESPONSIBILITY
    You are solely responsible for verifying that all parameters, settings, and
    configurations used with this script are correct and appropriate for your
    environment. The author(s) make no guarantees that default values, example
    configurations, or suggested settings are suitable for any specific environment.
    Incorrect configuration may result in data loss, service disruption, security
    vulnerabilities, or unintended changes to your Azure resources.

    By using this script, you accept full responsibility for:
      - Determining whether this script is suitable for your intended use case
      - Reviewing and customising the script to meet your specific environment and requirements
      - Verifying that all parameters, settings, and configurations are correct
        and appropriate for your environment before each execution
      - Understanding the cost implications of rehydration (especially High priority)
      - Understanding that rehydration is an asynchronous operation — blobs are not
        immediately available after the script completes
      - Validating that the target tier (Hot/Cool) and rehydrate priority (Standard/High)
        are appropriate for your use case and budget
      - Applying appropriate security hardening, access controls, and compliance policies
      - Ensuring data residency, sovereignty, and regulatory requirements are met
      - Testing and validating in lower environments (development / staging) before running against
        production
      - Following your organisation's approved change management, deployment, and
        operational practices
      - All outcomes resulting from the use of this script, including but not limited
        to data loss, service disruption, security incidents, compliance violations,
        or financial impact

    Always run with -DryRun first to review Archive blobs before rehydrating.
#>

param (
    [Parameter(Mandatory=$true)][string]$StorageAccountName,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$false)][string]$SubscriptionId,
    [Parameter(Mandatory=$false)][string]$ContainerName,
    [Parameter(Mandatory=$false)][ValidateSet("Hot","Cool")][string]$TargetTier = "Hot",
    [Parameter(Mandatory=$false)][ValidateSet("Standard","High")][string]$RehydratePriority = "Standard",
    [Parameter(Mandatory=$false)][string]$OutputPath,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# ── Output file paths ────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "."
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile     = Join-Path $OutputPath "Rehydrate-ArchiveBlobs_Log_$TimestampStr.txt"
$CsvFile     = Join-Path $OutputPath "Rehydrate-ArchiveBlobs_Report_$TimestampStr.csv"
$SummaryFile = Join-Path $OutputPath "Rehydrate-ArchiveBlobs_Summary_$TimestampStr.txt"

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

    # Append to log file
    "$Prefix$Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
}

function Get-AzErrorDetail {
    param([string]$StderrOutput, [string]$StdoutOutput)

    $AllOutput = @($StderrOutput, $StdoutOutput) | Where-Object { $_ } | ForEach-Object { $_.Trim() }
    $Combined = $AllOutput -join "`n"

    if (-not $Combined) {
        return "Unknown error (no output captured)"
    }

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

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Duration {
    param([TimeSpan]$Duration)
    $Parts = @()
    $TotalHours = [math]::Floor($Duration.TotalHours)
    if ($TotalHours -ge 1) {
        $Parts += if ($TotalHours -eq 1) { "1 hour" } else { "$TotalHours hours" }
    }
    if ($Duration.Minutes -ge 1) {
        $Parts += if ($Duration.Minutes -eq 1) { "1 minute" } else { "$($Duration.Minutes) minutes" }
    }
    if ($Parts.Count -eq 0 -or ($TotalHours -eq 0 -and $Duration.Seconds -gt 0)) {
        $Secs = [math]::Floor($Duration.Seconds)
        if ($Secs -gt 0 -or $Parts.Count -eq 0) {
            $Parts += if ($Secs -eq 1) { "1 second" } else { "$Secs seconds" }
        }
    }
    return $Parts -join ", "
}

# ── Counters ─────────────────────────────────────────────────────
$TotalContainersScanned = 0
$TotalBlobsScanned      = 0
$ArchiveBlobsFound      = 0
$TotalArchiveSizeBytes  = 0
$AlreadyRehydrating     = 0
$RehydrateInitiated     = 0
$RehydrateFailed        = 0
$HasFailures            = $false

# ── CSV report rows (List<T> for O(1) append — avoids O(n) array copy on every +=) ──
$CsvRows = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── Main ─────────────────────────────────────────────────────────
try {
    Write-Log "=================================================================="
    Write-Log "Rehydrate-ArchiveBlobs v1.0"
    Write-Log "=================================================================="

    if ($DryRun) {
        Write-Log "DRY RUN MODE — no tier changes will be made" "DRYRUN"
    }

    Write-Log "Storage Account  : $StorageAccountName"
    Write-Log "Resource Group   : $ResourceGroupName"
    Write-Log "Target Tier      : $TargetTier"
    Write-Log "Rehydrate Priority: $RehydratePriority"
    Write-Log "Output Path      : $OutputPath"

    if ($ContainerName) {
        Write-Log "Container Filter : $ContainerName"
    } else {
        Write-Log "Container Filter : ALL containers"
    }

    # ── Set subscription context ──────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        Write-Log "Setting subscription context to: $SubscriptionId"
        $SubResult = Invoke-AzCommand -Arguments @("account", "set", "--subscription", $SubscriptionId)
        if (-not $SubResult.Success) {
            throw "Failed to set subscription context: $($SubResult.ErrorDetail)"
        }
    }

    # ── Validate storage account exists ───────────────────────────
    Write-Log "Validating storage account '$StorageAccountName'..."
    $AcctResult = Invoke-AzCommand -Arguments @(
        "storage", "account", "show",
        "--name", $StorageAccountName,
        "--resource-group", $ResourceGroupName,
        "--query", "{name:name, kind:kind, isHnsEnabled:isHnsEnabled, location:location}",
        "-o", "json"
    )

    if (-not $AcctResult.Success) {
        throw "Storage account '$StorageAccountName' not found or not accessible: $($AcctResult.ErrorDetail)"
    }

    $AccountInfo = $AcctResult.StdOut | ConvertFrom-Json
    $IsHns = if ($AccountInfo.isHnsEnabled -eq $true) { "Yes" } else { "No" }
    Write-Log "Account found: kind=$($AccountInfo.kind), HNS=$IsHns, location=$($AccountInfo.location)"

    if ($AccountInfo.isHnsEnabled -eq $true) {
        Write-Log "HNS-enabled (ADLS Gen2) account detected." "INFO"
    }

    # ── Get account key ───────────────────────────────────────────
    Write-Log "Retrieving storage account key..."
    $KeyResult = Invoke-AzCommand -Arguments @(
        "storage", "account", "keys", "list",
        "--account-name", $StorageAccountName,
        "--resource-group", $ResourceGroupName,
        "--query", "[0].value",
        "-o", "tsv"
    )

    if (-not $KeyResult.Success) {
        throw "Failed to retrieve storage account key: $($KeyResult.ErrorDetail)"
    }

    $AccountKey = $KeyResult.StdOut.Trim()
    if ([string]::IsNullOrWhiteSpace($AccountKey)) {
        throw "Storage account key is empty — check RBAC permissions (requires Microsoft.Storage/storageAccounts/listKeys/action)"
    }

    Write-Log "Storage account key retrieved."

    # ── Resolve containers ────────────────────────────────────────
    $Containers = @()

    if (-not [string]::IsNullOrWhiteSpace($ContainerName)) {
        Write-Log "Using specified container: $ContainerName"
        $Containers = @($ContainerName)
    } else {
        Write-Log "Listing all containers..."

        # az storage container list works on both standard and HNS-enabled accounts
        $ListResult = Invoke-AzCommand -Arguments @(
            "storage", "container", "list",
            "--account-name", $StorageAccountName,
            "--account-key", $AccountKey,
            "--query", "[].name",
            "-o", "tsv"
        )

        if (-not $ListResult.Success) {
            throw "Failed to list containers: $($ListResult.ErrorDetail)"
        }

        $Containers = $ListResult.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    }

    if ($Containers.Count -eq 0) {
        Write-Log "No containers found in storage account." "WARN"
        Write-Log "=================================================================="
        exit 0
    }

    Write-Log "Found $($Containers.Count) container(s) to scan."
    Write-Log "=================================================================="

    # ── Scan each container ───────────────────────────────────────
    $ContainerIndex = 0

    foreach ($Container in $Containers) {
        $ContainerIndex++
        $TotalContainersScanned++
        $ContainerProgress = "$ContainerIndex/$($Containers.Count)"
        $ContainerBlobsScanned = 0
        $ContainerArchiveCount = 0

        Write-Log "Scanning container: '$Container'" "INFO" $ContainerProgress

        # Paginate through blobs in batches of 5000
        $Marker = $null
        $PageNum = 0

        do {
            $PageNum++
            $BatchStart = Get-Date

            # Single API call per page: --show-next-marker returns both blobs and pagination
            # marker in one response. JMESPath extracts only the 4 fields we need per blob.
            # Works on both standard and HNS-enabled accounts.
            $BlobArgs = @(
                "storage", "blob", "list",
                "--container-name", $Container,
                "--account-name", $StorageAccountName,
                "--account-key", $AccountKey,
                "--num-results", "5000",
                "--show-next-marker",
                "-o", "json"
            )

            if ($Marker) {
                $BlobArgs += "--marker"
                $BlobArgs += $Marker
            }

            $BlobResult = Invoke-AzCommand -Arguments $BlobArgs

            if (-not $BlobResult.Success) {
                Write-Log "  Failed to list blobs (page $PageNum): $($BlobResult.ErrorDetail)" "ERROR" $ContainerProgress
                $HasFailures = $true
                break
            }

            # Parse response — with --show-next-marker the output is an array where the
            # last element may be a { nextMarker: "..." } object
            $Marker = $null
            $Blobs = @()

            if ($BlobResult.StdOut -and $BlobResult.StdOut.Trim() -ne "[]") {
                $ParsedItems = $BlobResult.StdOut | ConvertFrom-Json

                if ($ParsedItems.Count -gt 0) {
                    $LastItem = $ParsedItems[-1]

                    # Check if the last element is the nextMarker sentinel
                    if ($LastItem.PSObject.Properties.Name -contains "nextMarker" -and
                        -not ($LastItem.PSObject.Properties.Name -contains "name")) {
                        $Marker = $LastItem.nextMarker
                        # All items except the last are blobs
                        if ($ParsedItems.Count -gt 1) {
                            $Blobs = $ParsedItems[0..($ParsedItems.Count - 2)]
                        }
                    } else {
                        $Blobs = $ParsedItems
                    }
                }
            }

            if ($Blobs.Count -eq 0) {
                if ($PageNum -eq 1) {
                    Write-Log "  Container is empty or has no blobs." "INFO" $ContainerProgress
                }
                break
            }

            $ContainerBlobsScanned += $Blobs.Count
            $TotalBlobsScanned += $Blobs.Count
            $BatchDuration = (Get-Date) - $BatchStart
            $BlobsPerSec = if ($BatchDuration.TotalSeconds -gt 0) { [math]::Round($Blobs.Count / $BatchDuration.TotalSeconds) } else { $Blobs.Count }

            Write-Log "  Batch ${PageNum}: $($Blobs.Count) blobs listed in $([math]::Round($BatchDuration.TotalSeconds, 1))s (~$BlobsPerSec blobs/sec) | Running total: $ContainerBlobsScanned scanned, $ContainerArchiveCount Archive" "INFO" $ContainerProgress

            # Update progress bar (visual-only, does not write to log)
            $ProgressPct = if ($Marker) { -1 } else { 100 }
            $ProgressMsg = "Container '$Container' — $ContainerBlobsScanned blobs scanned, $ContainerArchiveCount Archive found"
            if ($ProgressPct -eq -1) {
                Write-Progress -Activity "Scanning blobs" -Status $ProgressMsg -CurrentOperation "Batch $PageNum ($BlobsPerSec blobs/sec)"
            } else {
                Write-Progress -Activity "Scanning blobs" -Status $ProgressMsg -PercentComplete 100
            }

            foreach ($Blob in $Blobs) {
                $BlobName = $Blob.name
                $Props = $Blob.properties
                $BlobTier = if ($Props.blobTier) { $Props.blobTier } else { "" }
                $RehydrationStatus = if ($Props.rehydrationStatus) { $Props.rehydrationStatus } else { "" }
                $BlobSize = if ($Props.contentLength) { [long]$Props.contentLength } else { 0 }
                $LastModified = if ($Props.lastModified) { $Props.lastModified } else { "" }

                # Only interested in Archive tier blobs
                if ($BlobTier -ne "Archive") {
                    continue
                }

                $ArchiveBlobsFound++
                $ContainerArchiveCount++
                $TotalArchiveSizeBytes += $BlobSize

                $SizeFormatted = Format-FileSize -Bytes $BlobSize

                # Check if already rehydrating
                if (-not [string]::IsNullOrWhiteSpace($RehydrationStatus)) {
                    $AlreadyRehydrating++
                    Write-Log "  SKIP (already rehydrating): $BlobName [$SizeFormatted] — status: $RehydrationStatus" "WARN" $ContainerProgress

                    $CsvRows.Add([PSCustomObject]@{
                        Container          = $Container
                        BlobName           = $BlobName
                        SizeBytes          = $BlobSize
                        SizeFormatted      = $SizeFormatted
                        TierTransition     = "Archive -> $TargetTier"
                        RehydratePriority  = $RehydratePriority
                        Status             = "Skipped-AlreadyRehydrating"
                        RehydrationStatus  = $RehydrationStatus
                        LastModified       = $LastModified
                    })
                    continue
                }

                # DryRun mode — report only
                if ($DryRun) {
                    Write-Log "  WOULD REHYDRATE: $BlobName [$SizeFormatted] — Archive -> $TargetTier ($RehydratePriority priority)" "DRYRUN" $ContainerProgress

                    $CsvRows.Add([PSCustomObject]@{
                        Container          = $Container
                        BlobName           = $BlobName
                        SizeBytes          = $BlobSize
                        SizeFormatted      = $SizeFormatted
                        TierTransition     = "Archive -> $TargetTier"
                        RehydratePriority  = $RehydratePriority
                        Status             = "DryRun-WouldRehydrate"
                        RehydrationStatus  = ""
                        LastModified       = $LastModified
                    })
                    continue
                }

                # ── Issue Set Blob Tier command ───────────────────────
                $SetTierResult = Invoke-AzCommand -Arguments @(
                    "storage", "blob", "set-tier",
                    "--container-name", $Container,
                    "--name", $BlobName,
                    "--account-name", $StorageAccountName,
                    "--account-key", $AccountKey,
                    "--tier", $TargetTier,
                    "--rehydrate-priority", $RehydratePriority
                )

                if ($SetTierResult.Success) {
                    $RehydrateInitiated++
                    Write-Log "  REHYDRATE INITIATED: $BlobName [$SizeFormatted] — Archive -> $TargetTier ($RehydratePriority)" "SUCCESS" $ContainerProgress

                    $CsvRows.Add([PSCustomObject]@{
                        Container          = $Container
                        BlobName           = $BlobName
                        SizeBytes          = $BlobSize
                        SizeFormatted      = $SizeFormatted
                        TierTransition     = "Archive -> $TargetTier"
                        RehydratePriority  = $RehydratePriority
                        Status             = "RehydrateInitiated"
                        RehydrationStatus  = "rehydrate-pending-to-$($TargetTier.ToLower())"
                        LastModified       = $LastModified
                    })
                } else {
                    $RehydrateFailed++
                    $HasFailures = $true
                    Write-Log "  FAILED: $BlobName [$SizeFormatted] — $($SetTierResult.ErrorDetail)" "ERROR" $ContainerProgress

                    $CsvRows.Add([PSCustomObject]@{
                        Container          = $Container
                        BlobName           = $BlobName
                        SizeBytes          = $BlobSize
                        SizeFormatted      = $SizeFormatted
                        TierTransition     = "Archive -> $TargetTier"
                        RehydratePriority  = $RehydratePriority
                        Status             = "Failed"
                        RehydrationStatus  = $SetTierResult.ErrorDetail
                        LastModified       = $LastModified
                    })
                }
            }

            # Marker is already extracted from the response above — no second API call needed

        } while ($Marker)

        Write-Progress -Activity "Scanning blobs" -Completed
        Write-Log "  Container '$Container' complete: $ContainerBlobsScanned blobs scanned, $ContainerArchiveCount Archive blobs found." "INFO" $ContainerProgress
    }

    # ── Export CSV report ─────────────────────────────────────────
    Write-Log "=================================================================="

    if ($CsvRows.Count -gt 0) {
        $CsvRows | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report exported: $CsvFile"
    } else {
        Write-Log "No Archive blobs found — CSV report not generated."
    }

    # ── Write summary file ────────────────────────────────────────
    $Duration = (Get-Date) - $ScriptStartTime
    $DurationStr = Format-Duration -Duration $Duration
    $TotalArchiveSizeFormatted = Format-FileSize -Bytes $TotalArchiveSizeBytes

    $SummaryContent = @"
================================================================
Rehydrate-ArchiveBlobs — Summary
================================================================
Timestamp           : $(Get-Date -Format "yyyy-MM-dd HH:mm:ssZ")
Duration            : $DurationStr
Storage Account     : $StorageAccountName
Resource Group      : $ResourceGroupName
Target Tier         : $TargetTier
Rehydrate Priority  : $RehydratePriority
Mode                : $(if ($DryRun) { "DRY RUN" } else { "LIVE" })
================================================================
Containers Scanned       : $TotalContainersScanned
Total Blobs Scanned      : $TotalBlobsScanned
Archive Blobs Found      : $ArchiveBlobsFound
Total Archive Size       : $TotalArchiveSizeFormatted ($TotalArchiveSizeBytes bytes)
Already Rehydrating      : $AlreadyRehydrating
$(if ($DryRun) { "Would Rehydrate          : $($ArchiveBlobsFound - $AlreadyRehydrating)" } else { "Rehydrate Initiated      : $RehydrateInitiated" })
$(if (-not $DryRun) { "Failed                   : $RehydrateFailed" })
================================================================
Output Files:
  Log     : $LogFile
  CSV     : $(if ($CsvRows.Count -gt 0) { $CsvFile } else { "(none — no Archive blobs found)" })
  Summary : $SummaryFile
================================================================
"@

    $SummaryContent | Out-File -FilePath $SummaryFile -Encoding UTF8
    Write-Log "Summary file exported: $SummaryFile"

    # ── Console summary ───────────────────────────────────────────
    Write-Log "=================================================================="
    Write-Log "SUMMARY"
    Write-Log "  Containers scanned       : $TotalContainersScanned"
    Write-Log "  Total blobs scanned      : $TotalBlobsScanned"
    Write-Log "  Archive blobs found      : $ArchiveBlobsFound"
    Write-Log "  Total Archive size       : $TotalArchiveSizeFormatted"
    Write-Log "  Already rehydrating      : $AlreadyRehydrating"

    if ($DryRun) {
        Write-Log "  Would rehydrate          : $($ArchiveBlobsFound - $AlreadyRehydrating)" "DRYRUN"
    } else {
        Write-Log "  Rehydrate initiated      : $RehydrateInitiated" "SUCCESS"
        Write-Log "  Failed                   : $RehydrateFailed" $(if ($RehydrateFailed -gt 0) { "ERROR" } else { "INFO" })
    }

    Write-Log "  Duration                 : $DurationStr"
    Write-Log "=================================================================="
    Write-Log "Log file   : $LogFile"
    Write-Log "CSV report : $(if ($CsvRows.Count -gt 0) { $CsvFile } else { '(none)' })"
    Write-Log "Summary    : $SummaryFile"
    Write-Log "=================================================================="

    # ── Exit code ─────────────────────────────────────────────────
    if ($HasFailures) {
        Write-Log "Completed with errors." "ERROR"
        exit 1
    } else {
        Write-Log "Completed successfully." "SUCCESS"
        exit 0
    }

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}
