<#
.SYNOPSIS
    Batch Cross-Region DR Sync for Azure Files using AzCopy v10.
.DESCRIPTION
    Reads a CSV of source and destination storage account ARM Resource IDs and
    sequentially syncs all Azure File Shares. Supports cross-subscription scenarios
    by parsing the subscription, resource group, and account name from each Resource ID.
    Uses AzCopy to ensure SMB/NTFS permissions and directory structures are preserved,
    which Azure Data Factory natively strips.

.EXAMPLE
    # Ensure resources.csv has headers: SourceResourceId, DestResourceId
    # Each value is a full ARM Resource ID, e.g.:
    #   /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>
    .\FileShareSync-AzureFilesBatch.ps1 -CsvPath ".\resources.csv"

.NOTES
    License : MIT License (https://opensource.org/licenses/MIT)

    Network Path Considerations:
    - Private endpoints (VNet private IP) are NOT affected by public access / firewall settings.
      VMs, apps, ADF, and anything using a private endpoint will continue working as before.
    - Public endpoints (public IP) ARE affected by firewall rules (Deny + no IPs/VNets).
    - Enabling "Allow trusted Microsoft services" applies only to the public endpoint path,
      which is required for server-side copy operations (e.g., AzCopy, storage-to-storage sync).
    - Changing the trusted services exception does not impact private endpoint connectivity.

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
    [Parameter(Mandatory=$true)][string]$CsvPath
)

$ErrorActionPreference = "Stop"

# Disable AzCopy auto-login to prevent SAS URL parser corruption
$env:AZCOPY_AUTO_LOGIN_TYPE = "NONE"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ssZ"
    Write-Host "[$Timestamp] [$Level] $Message"
}

function Parse-ArmResourceId {
    <#
    .SYNOPSIS
        Parses an ARM Storage Account Resource ID into its components.
    .EXAMPLE
        Parse-ArmResourceId "/subscriptions/abc-123/resourceGroups/my-rg/providers/Microsoft.Storage/storageAccounts/mystorageacct"
        # Returns: @{ SubscriptionId = "abc-123"; ResourceGroup = "my-rg"; AccountName = "mystorageacct" }
    #>
    param([Parameter(Mandatory=$true)][string]$ResourceId)

    $Trimmed = $ResourceId.Trim()
    if ($Trimmed -notmatch "^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$") {
        throw "Invalid ARM Resource ID format: $Trimmed"
    }

    return @{
        SubscriptionId = $Matches[1]
        ResourceGroup  = $Matches[2]
        AccountName    = $Matches[3]
    }
}

try {
    if (-Not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }

    Write-Log "Reading storage account mapping from $CsvPath..."
    $AccountList = Import-Csv $CsvPath

    $TotalAccounts = $AccountList.Count
    $CurrentAccount = 0

    foreach ($Row in $AccountList) {
        $CurrentAccount++

        # Parse source and destination from full ARM Resource IDs
        $Source = Parse-ArmResourceId $Row.SourceResourceId
        $Dest   = Parse-ArmResourceId $Row.DestResourceId

        $SourceAccountName    = $Source.AccountName
        $SourceResourceGroup  = $Source.ResourceGroup
        $SourceSubscriptionId = $Source.SubscriptionId

        $DestAccountName      = $Dest.AccountName
        $DestResourceGroup    = $Dest.ResourceGroup
        $DestSubscriptionId   = $Dest.SubscriptionId

        if ([string]::IsNullOrWhiteSpace($SourceAccountName) -or [string]::IsNullOrWhiteSpace($DestAccountName)) {
            Write-Log "Skipping invalid row in CSV." "WARN"
            continue
        }

        Write-Log "=================================================================="
        Write-Log "Processing Account $CurrentAccount of $($TotalAccounts): $SourceAccountName -> $DestAccountName"
        Write-Log "  Source Sub: $SourceSubscriptionId  |  Dest Sub: $DestSubscriptionId"
        Write-Log "=================================================================="

        try {
            # 1. Generate fresh SAS tokens for this specific account pair
            Write-Log "Retrieving short-lived SAS tokens for current account pair..."
            $Expiry = (Get-Date).AddHours(4).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Switch to source subscription and get key
            Write-Log "Switching to source subscription ($SourceSubscriptionId)..."
            az account set --subscription $SourceSubscriptionId | Out-Null
            $SourceKey = (az storage account keys list -g $SourceResourceGroup -n $SourceAccountName --query "[0].value" -o tsv)
            if ([string]::IsNullOrWhiteSpace($SourceKey)) {
                throw "Failed to retrieve key for source account '$SourceAccountName' in subscription '$SourceSubscriptionId'."
            }

            # Switch to destination subscription and get key
            Write-Log "Switching to destination subscription ($DestSubscriptionId)..."
            az account set --subscription $DestSubscriptionId | Out-Null
            $DestKey = (az storage account keys list -g $DestResourceGroup -n $DestAccountName --query "[0].value" -o tsv)
            if ([string]::IsNullOrWhiteSpace($DestKey)) {
                throw "Failed to retrieve key for destination account '$DestAccountName' in subscription '$DestSubscriptionId'."
            }

            $SourceSasRaw = az storage account generate-sas --account-name $SourceAccountName --account-key $SourceKey --services f --resource-types sco --permissions rl --expiry $Expiry -o tsv
            $DestSasRaw = az storage account generate-sas --account-name $DestAccountName --account-key $DestKey --services f --resource-types sco --permissions acdlrwup --expiry $Expiry -o tsv

            # Strictly strip all formatting/newlines and leading question marks
            $SourceSas = (($SourceSasRaw | Out-String) -replace "[\r\n\s]", "").TrimStart('?')
            $DestSas = (($DestSasRaw | Out-String) -replace "[\r\n\s]", "").TrimStart('?')

            # Helper functions to switch SAS context safely
            function Set-AzContextSource { $env:AZURE_STORAGE_SAS_TOKEN = $SourceSas }
            function Set-AzContextDest   { $env:AZURE_STORAGE_SAS_TOKEN = $DestSas }

            # 2. Retrieve shares and sync — switch back to source subscription for share listing
            az account set --subscription $SourceSubscriptionId | Out-Null
            Set-AzContextSource
            $Shares = az storage share list --account-name $SourceAccountName --query "[].name" -o tsv

            foreach ($Share in $Shares) {
                $CleanShare = $Share -replace "[\r\n\s]", ""
                if ([string]::IsNullOrWhiteSpace($CleanShare)) { continue }

                Write-Log "--> Syncing Share: $CleanShare"
                $SourceUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $SourceAccountName, $CleanShare, $SourceSas
                $DestUrl = "https://{0}.file.core.windows.net/{1}?{2}" -f $DestAccountName, $CleanShare, $DestSas

                # Ensure destination share exists — switch to dest subscription
                az account set --subscription $DestSubscriptionId | Out-Null
                Set-AzContextDest
                az storage share create --name $CleanShare --account-name $DestAccountName | Out-Null

                # Clear the env var so AzCopy doesn't inject the Dest SAS into the Source account
                Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue

                # Use array splatting to prevent PowerShell from misinterpreting URLs
                $azCopyArgs = @(
                    "sync",
                    $SourceUrl,
                    $DestUrl,
                    "--preserve-smb-permissions=true",
                    "--preserve-smb-info=true",
                    "--recursive=true",
                    "--delete-destination=true"
                )
                & azcopy $azCopyArgs
            }

            Write-Log "Account $SourceAccountName completed successfully."

        } catch {
            Write-Log "ERROR processing $SourceAccountName : $($_.Exception.Message)" "ERROR"
            # We don't exit the whole script, we continue to the next storage account
            continue
        } finally {
            # Aggressive cleanup to prevent SAS token cross-contamination between loop iterations
            if (Test-Path env:AZURE_STORAGE_SAS_TOKEN) {
                Remove-Item env:AZURE_STORAGE_SAS_TOKEN -ErrorAction SilentlyContinue
            }
            $SourceKey = $null
            $DestKey = $null
        }
    }

    Write-Log "Batch DR File Sync Completed."

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
} finally {
    if (Test-Path env:AZCOPY_AUTO_LOGIN_TYPE) {
        Remove-Item env:AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue
    }
}
