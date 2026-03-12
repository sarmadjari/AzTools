<#
.SYNOPSIS
    Inventory blob storage accounts and determine replication tool compatibility.
.DESCRIPTION
    Scans one, multiple, or all Azure subscriptions and lists storage accounts
    that support blob storage. Determines the recommended replication tool based
    on Hierarchical Namespace (HNS) status:
      - HNS Enabled  (ADLS Gen2)    → Azure Storage Mover
      - HNS Disabled  (standard blob) → Object Replication

    Outputs a CSV file that can be used as input for other automation tools.

.PARAMETER SubscriptionIds
    Optional. Comma-separated list of subscription IDs to scan.
    If omitted, scans ALL accessible subscriptions.

.PARAMETER OutputPath
    Optional. Path for the output CSV file.
    Defaults to .\BlobStorageInventory_<timestamp>.csv

.EXAMPLE
    # Scan all accessible subscriptions
    .\Get-BlobStorageInventory.ps1

.EXAMPLE
    # Scan specific subscriptions
    .\Get-BlobStorageInventory.ps1 -SubscriptionIds "aaa-111,bbb-222"

.EXAMPLE
    # Single subscription with custom output path
    .\Get-BlobStorageInventory.ps1 -SubscriptionIds "aaa-111" -OutputPath "C:\reports\inventory.csv"

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
      - Validating that the subscriptions scanned are the correct ones
      - Reviewing the output CSV before using it as input for other automation tools
      - Ensuring you have appropriate read permissions on the target subscriptions
      - Applying appropriate security hardening, access controls, and compliance policies
      - Ensuring data residency, sovereignty, and regulatory requirements are met
      - Testing and validating in lower environments (development / staging) before running against
        production
      - Following your organisation's approved change management, deployment, and
        operational practices
      - All outcomes resulting from the use of this script, including but not limited
        to data loss, service disruption, security incidents, compliance violations,
        or financial impact

    This script is read-only — it does not modify any Azure resources. However,
    always validate its output before using it to drive other automation.
#>

param (
    [Parameter(Mandatory=$false)][string]$SubscriptionIds,
    [Parameter(Mandatory=$false)][string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ssZ"
    Write-Host "[$Timestamp] [$Level] $Message"
}

try {
    # ── Set default output path ──────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $TimestampStr = Get-Date -Format "yyyyMMdd_HHmmss"
        $OutputPath = ".\BlobStorageInventory_$TimestampStr.csv"
    }

    # ── Resolve subscriptions ────────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($SubscriptionIds)) {
        Write-Log "No subscriptions specified — scanning ALL accessible subscriptions..."
        $Subscriptions = az account list --query "[?state=='Enabled'].{Id:id, Name:name}" -o json | ConvertFrom-Json
    } else {
        Write-Log "Scanning specified subscriptions..."
        $IdList = $SubscriptionIds -split "," | ForEach-Object { $_.Trim() }
        $Subscriptions = @()
        foreach ($Id in $IdList) {
            $Sub = az account show --subscription $Id --query "{Id:id, Name:name}" -o json 2>$null | ConvertFrom-Json
            if ($Sub) {
                $Subscriptions += $Sub
            } else {
                Write-Log "Subscription '$Id' not found or not accessible." "WARN"
            }
        }
    }

    if ($Subscriptions.Count -eq 0) {
        throw "No accessible subscriptions found."
    }

    Write-Log "Found $($Subscriptions.Count) subscription(s) to scan."

    # ── Scan storage accounts ────────────────────────────────────
    $Results = @()
    $TotalAccounts = 0
    $HnsEnabledCount = 0
    $HnsDisabledCount = 0

    foreach ($Sub in $Subscriptions) {
        Write-Log "=================================================================="
        Write-Log "Scanning subscription: $($Sub.Name) ($($Sub.Id))"
        Write-Log "=================================================================="

        try {
            az account set --subscription $Sub.Id | Out-Null

            # Get all storage accounts with relevant properties in one call
            $AccountsJson = az storage account list --query "[].{name:name, location:location, kind:kind, id:id, isHnsEnabled:isHnsEnabled, publicNetworkAccess:publicNetworkAccess, networkRuleSet:networkRuleSet}" -o json
            $Accounts = $AccountsJson | ConvertFrom-Json

            if (-not $Accounts -or $Accounts.Count -eq 0) {
                Write-Log "  No storage accounts found in this subscription."
                continue
            }

            # Filter to blob-compatible kinds
            $BlobCompatibleKinds = @("StorageV2", "BlobStorage", "BlockBlobStorage", "Storage")
            $BlobAccounts = $Accounts | Where-Object { $BlobCompatibleKinds -contains $_.kind }

            Write-Log "  Found $($Accounts.Count) storage account(s), $($BlobAccounts.Count) blob-compatible."

            foreach ($Acct in $BlobAccounts) {
                $TotalAccounts++

                $HnsStatus = if ($Acct.isHnsEnabled -eq $true) { "Enabled" } else { "Disabled" }
                $ReplicationTool = if ($Acct.isHnsEnabled -eq $true) { "Azure Storage Mover" } else { "Object Replication" }

                if ($HnsStatus -eq "Enabled") { $HnsEnabledCount++ } else { $HnsDisabledCount++ }

                # Determine public network access and firewall settings
                $PublicAccess = if ($Acct.publicNetworkAccess) { $Acct.publicNetworkAccess } else { "Enabled" }
                $DefaultAction = if ($Acct.networkRuleSet -and $Acct.networkRuleSet.defaultAction) { $Acct.networkRuleSet.defaultAction } else { "Allow" }
                $Bypass = if ($Acct.networkRuleSet -and $Acct.networkRuleSet.bypass) { $Acct.networkRuleSet.bypass } else { "None" }
                $TrustedServices = if ($Bypass -match "AzureServices") { "Yes" } else { "No" }

                # AzCopy server-side copy requires: public access enabled (selected networks) + trusted services bypass
                $AzCopyReady = if ($PublicAccess -ne "Disabled" -and $DefaultAction -eq "Deny" -and $TrustedServices -eq "Yes") {
                    "Yes"
                } elseif ($PublicAccess -ne "Disabled" -and $DefaultAction -eq "Allow") {
                    "Yes"
                } else {
                    "No"
                }

                Write-Log "  $($Acct.name) | $($Acct.location) | HNS: $HnsStatus | PublicAccess: $PublicAccess | TrustedServices: $TrustedServices | AzCopyReady: $AzCopyReady"

                $Results += [PSCustomObject]@{
                    SubscriptionId        = $Sub.Id
                    SubscriptionName      = $Sub.Name
                    Region                = $Acct.location
                    StorageAccountName    = $Acct.name
                    ResourceId            = $Acct.id
                    HierarchicalNamespace = $HnsStatus
                    ReplicationTool       = $ReplicationTool
                    PublicNetworkAccess   = $PublicAccess
                    FirewallDefaultAction = $DefaultAction
                    TrustedServicesBypass = $TrustedServices
                    AzCopyServerSideCopy  = $AzCopyReady
                }
            }

        } catch {
            Write-Log "ERROR scanning subscription $($Sub.Name): $($_.Exception.Message)" "ERROR"
            continue
        }
    }

    # ── Export CSV ────────────────────────────────────────────────
    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "=================================================================="
        Write-Log "CSV exported to: $OutputPath"
    } else {
        Write-Log "No blob-compatible storage accounts found across all subscriptions." "WARN"
    }

    # ── Summary ──────────────────────────────────────────────────
    Write-Log "=================================================================="
    Write-Log "SUMMARY"
    Write-Log "  Total subscriptions scanned : $($Subscriptions.Count)"
    Write-Log "  Total blob storage accounts : $TotalAccounts"
    Write-Log "  HNS Enabled  (Storage Mover)      : $HnsEnabledCount"
    Write-Log "  HNS Disabled (Object Replication)  : $HnsDisabledCount"
    Write-Log "=================================================================="

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
