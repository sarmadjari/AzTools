<#
.SYNOPSIS
    Batch Cross-Region DR Sync for Azure Files using AzCopy v10 (Concurrent / Resource ID Based).
.DESCRIPTION
    Reads a CSV of source and destination Azure Resource IDs and syncs Azure File Shares.
    Transfers are executed concurrently in a managed background queue to maximize DR throughput.
    Requires a robust VM with sufficient CPU/RAM to handle multiple parallel AzCopy scans.

    Uses AzCopy to ensure SMB/NTFS permissions and directory structures are preserved.
    Generates a summary report CSV and an auto-retry script for any failed transfers.

.PARAMETER CsvPath
    Path to CSV with headers: SourceResourceId, DestResourceId
    Each value is a full ARM Resource ID for a storage account.

.PARAMETER MaxConcurrentJobs
    Maximum number of concurrent AzCopy sync jobs. Default: 5.

.EXAMPLE
    # Run with default concurrency (5 parallel jobs)
    .\Sync-AzureFilesBatch_parallel.ps1 -CsvPath ".\resources.csv"

.EXAMPLE
    # Run with higher concurrency
    .\Sync-AzureFilesBatch_parallel.ps1 -CsvPath ".\resources.csv" -MaxConcurrentJobs 10

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
      - Validating storage account names, SAS tokens, and AzCopy parameters
        against your organisational standards
      - Ensuring source and destination accounts are correctly paired in the CSV
      - Applying appropriate security hardening, access controls, and network
        restrictions to all storage accounts
      - Ensuring data residency, sovereignty, and regulatory requirements are met
        for the target region before executing any sync operations
      - Testing in lower environments (development / staging) before running against
        production storage accounts
      - Following your organisation's approved change management, deployment, and
        operational practices

    Review the script parameters and test in a non-production environment before
    executing against production systems.
#>

param (
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$false)][int]$MaxConcurrentJobs = 5
)

$ErrorActionPreference = "Stop"
$env:AZCOPY_AUTO_LOGIN_TYPE = "NONE"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ssZ"
    Write-Host "[$Timestamp] [$Level] $Message"
}

function Assert-Success {
    param([string]$StepName)
    if ($LASTEXITCODE -ne 0) {
        throw "$StepName failed with exit code $LASTEXITCODE. Review console output for details."
    }
}

function Parse-ResourceId {
    param([string]$ResourceId)
    $parts = $ResourceId.Split('/')
    if ($parts.Count -lt 9) { throw "Invalid Resource ID format: $ResourceId" }
    return @{
        SubscriptionId = $parts[2]
        ResourceGroup  = $parts[4]
        AccountName    = $parts[8]
    }
}

try {
    if (-Not (Test-Path $CsvPath)) { throw "CSV file not found at path: $CsvPath" }

    Write-Log "Reading storage account mapping from $CsvPath..."
    $AccountList = Import-Csv $CsvPath

    $TotalAccounts = $AccountList.Count
    $CurrentAccount = 0
    
    $JobTracker = @()
    $ActiveTransfers = @()

    foreach ($Row in $AccountList) {
        $CurrentAccount++
        $SourceResourceId = $Row.SourceResourceId.Trim()
        $DestResourceId = $Row.DestResourceId.Trim()

        if ([string]::IsNullOrWhiteSpace($SourceResourceId) -or [string]::IsNullOrWhiteSpace($DestResourceId)) { continue }

        $SrcAccount = "Unknown"
        $DstAccount = "Unknown"

        try {
            $Src = Parse-ResourceId -ResourceId $SourceResourceId
            $Dst = Parse-ResourceId -ResourceId $DestResourceId
            $SrcAccount = $Src.AccountName
            $DstAccount = $Dst.AccountName

            Write-Log "=================================================================="
            Write-Log "Prep Account $CurrentAccount of $($TotalAccounts): $($Src.AccountName) -> $($Dst.AccountName)"
            Write-Log "=================================================================="

            # 1. Source Context & SAS
            az account set --subscription $($Src.SubscriptionId) | Out-Null
            Assert-Success "az account set (Source)"

            $Expiry = (Get-Date).AddHours(24).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $SourceKey = (az storage account keys list -g $($Src.ResourceGroup) -n $($Src.AccountName) --query "[0].value" -o tsv)
            Assert-Success "Fetch Source Account Key"
            
            $SourceSasRaw = az storage account generate-sas --account-name $($Src.AccountName) --account-key $SourceKey --services f --resource-types sco --permissions rl --expiry $Expiry -o tsv
            Assert-Success "Generate Source SAS"

            # 2. Dest Context & SAS
            az account set --subscription $($Dst.SubscriptionId) | Out-Null
            Assert-Success "az account set (Dest)"

            $DestKey = (az storage account keys list -g $($Dst.ResourceGroup) -n $($Dst.AccountName) --query "[0].value" -o tsv)
            Assert-Success "Fetch Dest Account Key"
            
            $DestSasRaw = az storage account generate-sas --account-name $($Dst.AccountName) --account-key $DestKey --services f --resource-types sco --permissions acdlrwup --expiry $Expiry -o tsv
            Assert-Success "Generate Dest SAS"

            $SourceSas = ($SourceSasRaw -replace "[\r\n\s]", "").TrimStart('?')
            $DestSas = ($DestSasRaw -replace "[\r\n\s]", "").TrimStart('?')

            function Set-AzContextSource { $env:AZURE_STORAGE_SAS_TOKEN = $SourceSas }
            function Set-AzContextDest   { $env:AZURE_STORAGE_SAS_TOKEN = $DestSas }

            # 3. Get Shares
            az account set --subscription $($Src.SubscriptionId) | Out-Null
            Assert-Success "az account set (Source Revert)"

            Set-AzContextSource
            $Shares = az storage share list --account-name $($Src.AccountName) --query "[].name" -o tsv
            Assert-Success "az storage share list"
            
            $ShareArray = @($Shares | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            if ($ShareArray.Count -eq 0) {
                Write-Log "No shares found in $($Src.AccountName). Skipping."
                $JobTracker += [PSCustomObject]@{
                    SourceAccount = $SrcAccount; DestAccount = $DstAccount; ShareName = "N/A"
                    Status = "Skipped"; ErrorMessage = "No shares found"; RetryCommand = ""
                }
                continue 
            }

            # 4. Queue and Sync Shares CONCURRENTLY
            foreach ($Share in $ShareArray) {
                $CleanShare = $Share -replace "[\r\n\s]", ""

                try {
                    Write-Log "--> Prepping Share: $CleanShare"
                    $SourceUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $($Src.AccountName), $CleanShare, $SourceSas
                    $DestUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $($Dst.AccountName), $CleanShare, $DestSas
                    
                    az account set --subscription $($Dst.SubscriptionId) | Out-Null
                    Assert-Success "az account set (Dest Share Create)"
                    
                    Set-AzContextDest
                    az storage share create --name $CleanShare --account-name $($Dst.AccountName) | Out-Null
                    Assert-Success "az storage share create"
                    
                    Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue
                    
                    $azCopyArgs = @(
                        "sync", "`"$SourceUrl`"", "`"$DestUrl`"",
                        "--preserve-smb-permissions=true", "--preserve-smb-info=true",
                        "--recursive=true", "--delete-destination=true"
                    )
                    
                    $AzCopyCmdString = "azcopy $($azCopyArgs -join ' ')"
                    $TempLog = [System.IO.Path]::GetTempFileName()
                    
                    Write-Log "Queueing AzCopy job for $CleanShare..."
                    $Process = Start-Process -FilePath "azcopy" -ArgumentList $azCopyArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $TempLog -RedirectStandardError $TempLog
                    
                    $ActiveTransfers += [PSCustomObject]@{
                        Process = $Process; SourceAccount = $SrcAccount; DestAccount = $DstAccount
                        ShareName = $CleanShare; RetryCmd = $AzCopyCmdString; LogFile = $TempLog
                    }

                    # THROTTLE QUEUE
                    while ($ActiveTransfers.Count -ge $MaxConcurrentJobs) {
                        Start-Sleep -Seconds 5
                        $Completed = $ActiveTransfers | Where-Object { $_.Process.HasExited }
                        
                        foreach ($Job in $Completed) {
                            $ExitCode = $Job.Process.ExitCode
                            $Status = if ($ExitCode -eq 0) { "Success" } else { "Failed" }
                            $ErrorMessage = if ($ExitCode -ne 0) { (Get-Content $Job.LogFile -Tail 3) -join " | " } else { "" }

                            if ($Status -eq "Success") { Write-Log "COMPLETED: $($Job.SourceAccount) -> $($Job.ShareName)" }
                            else { Write-Log "FAILED: $($Job.SourceAccount) -> $($Job.ShareName) (Code: $ExitCode)" "ERROR" }

                            $JobTracker += [PSCustomObject]@{
                                SourceAccount = $Job.SourceAccount; DestAccount = $Job.DestAccount; ShareName = $Job.ShareName
                                Status = $Status; ErrorMessage = $ErrorMessage
                                RetryCommand = if ($Status -eq "Failed") { $Job.RetryCmd } else { "" }
                            }
                            Remove-Item $Job.LogFile -ErrorAction SilentlyContinue
                        }
                        $ActiveTransfers = @($ActiveTransfers | Where-Object { -not $_.Process.HasExited })
                    }

                } catch {
                    Write-Log "ERROR queuing share '$CleanShare': $($_.Exception.Message)" "ERROR"
                    $JobTracker += [PSCustomObject]@{
                        SourceAccount = $SrcAccount; DestAccount = $DstAccount; ShareName = $CleanShare
                        Status = "Failed"; ErrorMessage = $_.Exception.Message; RetryCommand = ""
                    }
                }
            }

        } catch {
            Write-Log "ACCOUNT ERROR processing $($SrcAccount): $($_.Exception.Message)" "ERROR"
            $JobTracker += [PSCustomObject]@{
                SourceAccount = $SrcAccount; DestAccount = $DstAccount; ShareName = "N/A (Account Error)"
                Status = "Failed"; ErrorMessage = $_.Exception.Message; RetryCommand = "N/A"
            }
        } finally {
            if (Test-Path env:AZURE_STORAGE_SAS_TOKEN) { Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue }
            $SourceKey = $null; $DestKey = $null
        }
    }

    # DRAIN REMAINING QUEUE
    if ($ActiveTransfers.Count -gt 0) {
        Write-Log "Draining $($ActiveTransfers.Count) remaining active transfers..."
        while ($ActiveTransfers.Count -gt 0) {
            Start-Sleep -Seconds 5
            $Completed = $ActiveTransfers | Where-Object { $_.Process.HasExited }
            
            foreach ($Job in $Completed) {
                $ExitCode = $Job.Process.ExitCode
                $Status = if ($ExitCode -eq 0) { "Success" } else { "Failed" }
                $ErrorMessage = if ($ExitCode -ne 0) { (Get-Content $Job.LogFile -Tail 3) -join " | " } else { "" }

                if ($Status -eq "Success") { Write-Log "COMPLETED: $($Job.SourceAccount) -> $($Job.ShareName)" }
                else { Write-Log "FAILED: $($Job.SourceAccount) -> $($Job.ShareName) (Code: $ExitCode)" "ERROR" }

                $JobTracker += [PSCustomObject]@{
                    SourceAccount = $Job.SourceAccount; DestAccount = $Job.DestAccount; ShareName = $Job.ShareName
                    Status = $Status; ErrorMessage = $ErrorMessage
                    RetryCommand = if ($Status -eq "Failed") { $Job.RetryCmd } else { "" }
                }
                Remove-Item $Job.LogFile -ErrorAction SilentlyContinue
            }
            $ActiveTransfers = @($ActiveTransfers | Where-Object { -not $_.Process.HasExited })
        }
    }

    Write-Log "=================================================================="
    Write-Log "BATCH DR FILE SYNC SUMMARY"
    Write-Log "=================================================================="
    $JobTracker | Select-Object SourceAccount, DestAccount, ShareName, Status | Format-Table -AutoSize | Out-String | Write-Host
    
    $ReportPath = ".\DR-Sync-Concurrent-Report.csv"
    $JobTracker | Export-Csv -Path $ReportPath -NoTypeInformation
    
    $FailedJobs = $JobTracker | Where-Object { $_.Status -eq "Failed" -and $_.RetryCommand -like "azcopy*" }
    if ($FailedJobs.Count -gt 0) {
        $RetryScriptPath = ".\Retry-Concurrent-AzCopy.ps1"
        $RetryContent = "# Auto-generated retry script`n# WARNING: The SAS Tokens embedded in these URLs expire 24 hours after generation!`n`n"
        foreach ($Job in $FailedJobs) {
            $RetryContent += "# Failed Share: $($Job.SourceAccount) -> $($Job.DestAccount) / $($Job.ShareName)`n"
            $RetryContent += "$($Job.RetryCommand)`n`n"
        }
        Set-Content -Path $RetryScriptPath -Value $RetryContent
        Write-Log "Generated Retry Script at: $RetryScriptPath" "WARN"
    }

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
} finally {
    if (Test-Path env:AZCOPY_AUTO_LOGIN_TYPE) { Remove-Item env:AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue }
}