<#
.SYNOPSIS
    Sets up an Azure Automation Account with a Runbook and schedule to sync
    DR File Shares automatically.

.DESCRIPTION
    Deploys and configures all Azure resources needed to run Sync-DRFileShares
    on a recurring schedule via Azure Automation:

      1. Creates (or reuses) an Azure Automation Account
      2. Enables System-Assigned Managed Identity
      3. Optionally registers a VM as a Hybrid Runbook Worker
         (auto-creates a small VM if none provided)
      4. Checks and installs prerequisites (az cli, azcopy, pwsh) on the VM
      5. Assigns RBAC (Storage Account Contributor) at Resource Group scope
      6. Imports Az PowerShell modules into the Automation Account
      7. Uploads and publishes the Runbook (Sync-DRFileShares.ps1)
      8. Stores CSV mapping and config as Automation Variables
      9. Creates a recurring schedule and links it to the Runbook

    The Runbook runs on a Hybrid Runbook Worker because Azure Automation cloud
    sandboxes block external binaries (azcopy). When -HybridWorkerVMResourceId
    is provided, the script automatically checks and installs any missing
    prerequisites (Azure CLI, AzCopy v10+, PowerShell 7) on the VM via
    az vm run-command invoke.

    RBAC is assigned at the Resource Group level (least privilege). The setup
    script parses the CSV to extract all unique source and destination RG scopes
    and assigns "Storage Account Contributor" to both the Automation Account's
    Managed Identity and the Hybrid Worker VM's Managed Identity.

    The script is idempotent — safe to re-run to update CSV content, change
    the schedule interval, or add RBAC for new resource groups.

.PARAMETER AutomationAccountName
    Name of the Azure Automation Account to create or reuse.

.PARAMETER ResourceGroupName
    Resource group to deploy the Automation Account into. Created if it does not exist.

.PARAMETER Location
    Azure region for the Automation Account (e.g., "switzerlandnorth").

.PARAMETER CsvPath
    Path to the CSV mapping file with headers:
    SourceResourceId, DestStorageAccountName, DestResourceGroupName

.PARAMETER HybridWorkerVMResourceId
    ARM Resource ID of an existing VM to use as a Hybrid Runbook Worker. The
    script enables the VM's Managed Identity, checks and installs any missing
    prerequisites (az cli, azcopy, pwsh) on the VM, installs the Hybrid
    Worker extension, and creates a worker group named "hwg-sync-dr-fileshares".
    When omitted, a new VM is created automatically.

.PARAMETER HybridWorkerVMName
    Custom name for the auto-created Hybrid Worker VM. If omitted, a name is
    auto-generated from the Automation Account name (e.g., "ahb-szn-prd-ndbp-filesync-dr-vm").
    Max length: 64 characters (Azure VM resource name limit).
    Only used when -HybridWorkerVMResourceId is not provided.

.PARAMETER VMSize
    VM size for auto-created Hybrid Worker VM (default: Standard_B2s).
    Only used when -HybridWorkerVMResourceId is not provided.

.PARAMETER VMOsType
    OS type for auto-created VM: Linux (default) or Windows.
    Linux is recommended (cheaper, lighter). Only used when auto-creating a VM.

.PARAMETER DestSubscriptionId
    Optional. Subscription for destination storage accounts. Defaults to source
    subscription (parsed from CSV).

.PARAMETER ScheduleIntervalHours
    How often to run the sync (default: 6 hours, range: 1-24).

.PARAMETER SyncMode
    Additive (default) or Mirror.
    Additive = sync changes, never delete on destination.
    Mirror   = sync changes + delete files on destination that don't exist on source.

.PARAMETER PreserveSmbPermissions
    Switch. Stored as the PreserveSmbPermissions Automation Variable. When true, the
    Runbook passes --preserve-smb-permissions=true to AzCopy. Off by default for faster
    subsequent syncs. Recommended for initial sync or when permissions have changed.

.PARAMETER ExcludePattern
    Semicolon-delimited glob pattern stored as the ExcludePattern Automation Variable.
    The Runbook passes this to AzCopy --exclude-pattern to skip matching files during
    sync. Example: "*.tmp;~$*;thumbs.db"

.PARAMETER SkipNatGateway
    Switch. Skips NAT Gateway and Public IP creation for the auto-created VM.
    Use when the VM subnet already has outbound internet access (e.g., existing
    NAT Gateway, Azure Firewall, or UDR). Without outbound access the VM cannot
    reach Azure Storage endpoints or management APIs.

.PARAMETER DryRun
    Switch. Dry run — shows what would be created without making changes.

.EXAMPLE
    # Use an existing VM as Hybrid Worker
    .\Setup-SyncAutomation.ps1 -AutomationAccountName "aa-dr-sync" -ResourceGroupName "rg-automation" -Location "switzerlandnorth" -CsvPath ".\resources.csv" -HybridWorkerVMResourceId "/subscriptions/.../Microsoft.Compute/virtualMachines/vm-worker01"

.EXAMPLE
    # Auto-create a VM with a custom name
    .\Setup-SyncAutomation.ps1 -AutomationAccountName "aa-dr-sync" -ResourceGroupName "rg-automation" -Location "switzerlandnorth" -CsvPath ".\resources.csv" -HybridWorkerVMName "vm-dr-sync-worker" -ScheduleIntervalHours 4

.EXAMPLE
    # Simplest setup — auto-creates a VM with name derived from AutomationAccountName
    .\Setup-SyncAutomation.ps1 -AutomationAccountName "aa-dr-sync" -ResourceGroupName "rg-automation" -Location "switzerlandnorth" -CsvPath ".\resources.csv" -ScheduleIntervalHours 4

.EXAMPLE
    # Dry run — preview what would be created
    .\Setup-SyncAutomation.ps1 -AutomationAccountName "aa-dr-sync" -ResourceGroupName "rg-automation" -Location "switzerlandnorth" -CsvPath ".\resources.csv" -DryRun

.EXAMPLE
    # Cross-subscription, Mirror mode, every 4 hours
    .\Setup-SyncAutomation.ps1 -AutomationAccountName "aa-dr-sync" -ResourceGroupName "rg-automation" -Location "switzerlandnorth" -CsvPath ".\resources.csv" -HybridWorkerVMResourceId "/subscriptions/.../Microsoft.Compute/virtualMachines/vm-worker01" -DestSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SyncMode "Mirror" -ScheduleIntervalHours 4

.NOTES
    Author  : Sarmad Jari
    Version : 1.2
    Date    : 2026-03-19
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
      - Validating storage account pairs and file share mappings against your
        organisational standards
      - Verifying RBAC assignments and Managed Identity permissions
      - Verifying the Hybrid Worker VM prerequisites
        (auto-installed when using -HybridWorkerVMResourceId or auto-created VM)
      - Applying appropriate security hardening, access controls, network restrictions,
        and compliance policies
      - Ensuring data residency, sovereignty, and regulatory requirements are met
      - Testing and validating in lower environments (development / staging) before running against
        production storage accounts
      - Following your organisation's approved change management, deployment, and
        operational practices
      - All outcomes resulting from the use of this script, including but not limited
        to data loss, service disruption, security incidents, compliance violations,
        or financial impact

    Run with -DryRun first to review planned changes before executing live.
#>

param (
    [Parameter(Mandatory=$true)][string]$AutomationAccountName,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$Location,
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$false)][string]$HybridWorkerVMResourceId,
    [Parameter(Mandatory=$false)][string]$HybridWorkerVMName,
    [Parameter(Mandatory=$false)][string]$VMSize = "Standard_B2s",
    [Parameter(Mandatory=$false)][ValidateSet("Linux","Windows")][string]$VMOsType = "Linux",
    [Parameter(Mandatory=$false)][string]$DestSubscriptionId,
    [Parameter(Mandatory=$false)][ValidateRange(1,24)][int]$ScheduleIntervalHours = 12,
    [Parameter(Mandatory=$false)][ValidateSet("Additive","Mirror")][string]$SyncMode = "Additive",
    [switch]$PreserveSmbPermissions,
    [string]$ExcludePattern,
    [switch]$SkipNatGateway,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# Prevent 'az automation' from hanging on invisible extension installation prompts
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "yes_without_prompt"

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

function Install-VMPrerequisites {
    <#
    .SYNOPSIS
        Checks and installs missing prerequisites (az cli, azcopy, pwsh) on a VM
        via az vm run-command invoke. Continues with warnings on failure.
    #>
    param(
        [string]$HybridWorkerVMName,
        [string]$VMResourceGroup,
        [string]$VMOsType  # "Windows" or "Linux"
    )

    $CommandId = if ($VMOsType -eq "Linux") { "RunShellScript" } else { "RunPowerShellScript" }

    if ($VMOsType -eq "Linux") {
        $Script = @'
#!/bin/bash
set -e

# Check Azure CLI
if ! command -v az &>/dev/null; then
    echo "INSTALLING:AzureCLI"
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash 2>/dev/null || echo "FAILED:AzureCLI"
else
    echo "OK:AzureCLI"
fi

# Check AzCopy
if ! command -v azcopy &>/dev/null; then
    echo "INSTALLING:AzCopy"
    cd /tmp
    curl -sL https://aka.ms/downloadazcopy-v10-linux -o azcopy.tar.gz
    tar xzf azcopy.tar.gz --strip-components=1 --wildcards '*/azcopy'
    mv azcopy /usr/local/bin/azcopy && chmod +x /usr/local/bin/azcopy
    rm -f azcopy.tar.gz
    if command -v azcopy &>/dev/null; then echo "INSTALLED:AzCopy"; else echo "FAILED:AzCopy"; fi
else
    echo "OK:AzCopy"
fi

# Check PowerShell 7
if ! command -v pwsh &>/dev/null; then
    echo "INSTALLING:PowerShell7"
    # Use official install script (auto-detects distro)
    curl -sL https://aka.ms/install-powershell.sh | bash 2>/dev/null || echo "FAILED:PowerShell7"
    if command -v pwsh &>/dev/null; then echo "INSTALLED:PowerShell7"; else echo "FAILED:PowerShell7"; fi
else
    echo "OK:PowerShell7"
fi
'@
    } else {
        $Script = @'
$ErrorActionPreference = "Continue"

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Output "INSTALLING:AzureCLI"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile "$env:TEMP\AzureCLI.msi"
        Start-Process msiexec.exe -Wait -ArgumentList "/I `"$env:TEMP\AzureCLI.msi`" /quiet"
        Remove-Item "$env:TEMP\AzureCLI.msi" -Force -ErrorAction SilentlyContinue
        Write-Output "INSTALLED:AzureCLI"
    } catch { Write-Output "FAILED:AzureCLI" }
} else { Write-Output "OK:AzureCLI" }

# Check AzCopy
if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) {
    Write-Output "INSTALLING:AzCopy"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/downloadazcopy-v10-windows -OutFile "$env:TEMP\azcopy.zip"
        Expand-Archive "$env:TEMP\azcopy.zip" -DestinationPath "$env:TEMP\azcopy_extract" -Force
        $exe = Get-ChildItem "$env:TEMP\azcopy_extract" -Recurse -Filter azcopy.exe | Select-Object -First 1
        Copy-Item $exe.FullName "$env:SystemRoot\System32\azcopy.exe" -Force
        Remove-Item "$env:TEMP\azcopy.zip","$env:TEMP\azcopy_extract" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "INSTALLED:AzCopy"
    } catch { Write-Output "FAILED:AzCopy" }
} else { Write-Output "OK:AzCopy" }

# Check PowerShell 7
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Output "INSTALLING:PowerShell7"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/install-powershell.ps1 -OutFile "$env:TEMP\install-pwsh.ps1"
        & "$env:TEMP\install-pwsh.ps1" -UseMSI -Quiet
        Remove-Item "$env:TEMP\install-pwsh.ps1" -Force -ErrorAction SilentlyContinue
        Write-Output "INSTALLED:PowerShell7"
    } catch { Write-Output "FAILED:PowerShell7" }
} else { Write-Output "OK:PowerShell7" }
'@
    }

    # Write script to temp file for az vm run-command
    $TempScript = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $TempScript -Value $Script -Encoding UTF8

    try {
        Write-Log "    Running prerequisite check on VM (this may take a few minutes)..."
        $RunResult = Invoke-AzCommand -Arguments @(
            "vm", "run-command", "invoke",
            "--name", $HybridWorkerVMName,
            "--resource-group", $VMResourceGroup,
            "--command-id", $CommandId,
            "--scripts", "@$TempScript",
            "-o", "json"
        ) -IgnoreExitCode

        if ($RunResult.ExitCode -ne 0) {
            Write-Log "    WARNING: Could not run prerequisite check on VM. Install az cli, azcopy, and pwsh manually." "WARN"
            Write-Log "    Error: $($RunResult.ErrorDetail)" "WARN"
            return
        }

        # Parse run-command output
        $RunOutput = $RunResult.StdOut | ConvertFrom-Json
        $StdOutMessages = if ($RunOutput.value) {
            ($RunOutput.value | Where-Object { $_.code -eq "ComponentStatus/StdOut/succeeded" }).message
        } else { "" }

        if (-not $StdOutMessages) {
            Write-Log "    WARNING: No output from prerequisite check. Verify tools are installed on the VM manually." "WARN"
            return
        }

        $Lines = $StdOutMessages -split "`n" | Where-Object { $_.Trim() -ne "" }
        $Installed = @()
        $AlreadyPresent = @()
        $Failed = @()

        foreach ($Line in $Lines) {
            $Line = $Line.Trim()
            if ($Line -match "^OK:(.+)$")        { $AlreadyPresent += $Matches[1] }
            if ($Line -match "^INSTALLED:(.+)$")  { $Installed += $Matches[1] }
            if ($Line -match "^FAILED:(.+)$")     { $Failed += $Matches[1] }
        }

        if ($AlreadyPresent.Count -gt 0) {
            Write-Log "    Already installed: $($AlreadyPresent -join ', ')" "SUCCESS"
        }
        if ($Installed.Count -gt 0) {
            Write-Log "    Newly installed:   $($Installed -join ', ')" "SUCCESS"
        }
        if ($Failed.Count -gt 0) {
            Write-Log "    WARNING: Failed to install: $($Failed -join ', '). Install these manually on the VM." "WARN"
        }
    } catch {
        Write-Log "    WARNING: Prerequisite check failed: $($_.Exception.Message). Install az cli, azcopy, and pwsh on the VM manually." "WARN"
    } finally {
        Remove-Item $TempScript -ErrorAction SilentlyContinue
    }
}

function Register-HybridWorker {
    <#
    .SYNOPSIS
        Enables MI on a VM, installs prerequisites, and registers it as a Hybrid Worker.
        Returns a hashtable with VMPrincipalId and VMResourceId.
    #>
    param(
        [string]$HybridWorkerVMName,
        [string]$VMResourceGroup,
        [string]$VMSubscriptionId,
        [string]$WorkerGroupName,
        [string]$AutomationAccountName,
        [string]$AAResourceGroup,
        [object]$AACheckResult  # Result of the AA show command (for automationHybridServiceUrl)
    )

    $Result = @{ VMPrincipalId = $null; VMResourceId = $null }

    # Enable VM's System-Assigned Managed Identity
    Write-Log "  Enabling Managed Identity on VM '$HybridWorkerVMName'..."
    az account set --subscription $VMSubscriptionId | Out-Null
    $VMUpdate = Invoke-AzCommand -Arguments @(
        "vm", "identity", "assign",
        "--name", $HybridWorkerVMName,
        "--resource-group", $VMResourceGroup,
        "-o", "json"
    )
    if ($VMUpdate.ExitCode -ne 0) {
        throw "Failed to enable MI on VM: $($VMUpdate.ErrorDetail)"
    }
    $VMIdentity = $VMUpdate.StdOut | ConvertFrom-Json
    $Result.VMPrincipalId = $VMIdentity.systemAssignedIdentity
    Write-Log "  VM Managed Identity enabled. Principal ID: $($Result.VMPrincipalId)" "SUCCESS"

    # Detect VM OS type
    $VMInfo = Invoke-AzCommand -Arguments @(
        "vm", "show",
        "--name", $HybridWorkerVMName,
        "--resource-group", $VMResourceGroup,
        "--query", "storageProfile.osDisk.osType",
        "-o", "tsv"
    )
    $DetectedOsType = if ($VMInfo.StdOut) { $VMInfo.StdOut.Trim() } else { "Windows" }

    # Build VM Resource ID
    $Result.VMResourceId = "/subscriptions/$VMSubscriptionId/resourceGroups/$VMResourceGroup/providers/Microsoft.Compute/virtualMachines/$HybridWorkerVMName"

    # Install prerequisites on VM
    Write-Log "  Checking and installing prerequisites on VM '$HybridWorkerVMName' ($DetectedOsType)..."
    Install-VMPrerequisites -HybridWorkerVMName $HybridWorkerVMName -VMResourceGroup $VMResourceGroup -VMOsType $DetectedOsType

    # Create Hybrid Worker Group
    Write-Log "  Creating Hybrid Worker Group '$WorkerGroupName'..."
    $HWGCreate = Invoke-AzCommand -Arguments @(
        "automation", "hrwg", "create",
        "--automation-account-name", $AutomationAccountName,
        "--resource-group", $AAResourceGroup,
        "--name", $WorkerGroupName,
        "-o", "none"
    ) -IgnoreExitCode

    # Register VM as Hybrid Worker
    Write-Log "  Registering VM '$HybridWorkerVMName' as Hybrid Worker..."
    $HWCreate = Invoke-AzCommand -Arguments @(
        "automation", "hrwg", "hrw", "create",
        "--automation-account-name", $AutomationAccountName,
        "--resource-group", $AAResourceGroup,
        "--hybrid-runbook-worker-group-name", $WorkerGroupName,
        "--name", $HybridWorkerVMName,
        "--vm-resource-id", $Result.VMResourceId,
        "-o", "none"
    ) -IgnoreExitCode
    Write-Log "  Hybrid Worker registered." "SUCCESS"

    return $Result
}

try {
    # ── Step 1: Validate prerequisites ────────────────────────────
    Write-Log "Validating prerequisites..."

    # Check az cli
    $AzCliPath = Get-Command az -ErrorAction SilentlyContinue
    if (-not $AzCliPath) {
        throw "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
    }

    # Check az login
    $LoginCheck = Invoke-AzCommand -Arguments @("account", "show", "-o", "json") -IgnoreExitCode
    if ($LoginCheck.ExitCode -ne 0) {
        throw "Not logged in to Azure CLI. Run 'az login' first."
    }
    $CurrentAccount = $LoginCheck.StdOut | ConvertFrom-Json
    Write-Log "  Logged in as: $($CurrentAccount.user.name) (subscription: $($CurrentAccount.name))"

    # Validate HybridWorkerVMName is only used when not providing a VM Resource ID
    if ($HybridWorkerVMName -and $HybridWorkerVMResourceId) {
        throw "Cannot specify both -HybridWorkerVMName and -HybridWorkerVMResourceId. Use -HybridWorkerVMResourceId for an existing VM, or -HybridWorkerVMName to create a new one."
    }

    # Check CSV file
    if (-Not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }

    $CsvFullPath = (Resolve-Path $CsvPath).Path
    Write-Log "Reading storage account mapping from $CsvFullPath..."

    # Check Runbook file
    $RunbookPath = Join-Path $PSScriptRoot "Sync-DRFileShares.ps1"
    if (-not (Test-Path $RunbookPath)) {
        throw "Runbook file not found: $RunbookPath. Ensure Sync-DRFileShares.ps1 is in the same directory as this script."
    }

    # ── Step 2: Pre-validate CSV ──────────────────────────────────
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

    Write-Log "Running pre-validation on all $TotalRows rows..."
    $ValidationErrors = @()
    $SeenPairs = @{}
    $UniqueRGScopes = @{}

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
            } else {
                # Extract source RG scope for RBAC
                $SrcParsed = Parse-ArmResourceId $SrcId
                $SrcRGScope = "/subscriptions/$($SrcParsed.SubscriptionId)/resourceGroups/$($SrcParsed.ResourceGroup)"
                $UniqueRGScopes[$SrcRGScope] = "source"

                # Extract dest RG scope for RBAC
                $DestSubIdForScope = if ([string]::IsNullOrWhiteSpace($DestSubscriptionId)) { $SrcParsed.SubscriptionId } else { $DestSubscriptionId }
                $DestRGForScope = if ($Row.DestResourceGroupName) { $Row.DestResourceGroupName.Trim() } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($DestRGForScope)) {
                    $DestRGScope = "/subscriptions/$DestSubIdForScope/resourceGroups/$DestRGForScope"
                    $UniqueRGScopes[$DestRGScope] = "destination"
                }
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
    Write-Log "  RBAC scopes identified: $($UniqueRGScopes.Count) resource group(s)"

    # ── Mode banners ──────────────────────────────────────────────
    if ($DryRun) {
        Write-Log "==================================================================" "DRYRUN"
        Write-Log "  DRY RUN MODE -- no changes will be made" "DRYRUN"
        Write-Log "==================================================================" "DRYRUN"
    }

    Write-Log "=================================================================="
    Write-Log "  Automation Account   : $AutomationAccountName"
    Write-Log "  Resource Group       : $ResourceGroupName"
    Write-Log "  Location             : $Location"
    Write-Log "  SyncMode             : $SyncMode"
    Write-Log "  Schedule             : Every $ScheduleIntervalHours hour(s)"
    if ($SyncMode -eq "Mirror") {
        Write-Log "  WARNING              : Mirror mode will DELETE files on dest not in source" "WARN"
    }
    Write-Log "=================================================================="

    # ── Step 3: Create or verify Automation Account ────────────────
    Write-Log "Checking Automation Account '$AutomationAccountName'..."

    # Ensure resource group exists
    $RGCheck = Invoke-AzCommand -Arguments @("group", "show", "--name", $ResourceGroupName, "-o", "json") -IgnoreExitCode
    if ($RGCheck.ExitCode -ne 0) {
        if ($DryRun) {
            Write-Log "  [DRYRUN] Would create resource group '$ResourceGroupName' in '$Location'" "DRYRUN"
        } else {
            Write-Log "  Creating resource group '$ResourceGroupName' in '$Location'..."
            $RGCreate = Invoke-AzCommand -Arguments @("group", "create", "--name", $ResourceGroupName, "--location", $Location, "-o", "none")
            if ($RGCreate.ExitCode -ne 0) {
                throw "Failed to create resource group: $($RGCreate.ErrorDetail)"
            }
            Write-Log "  Resource group created." "SUCCESS"
        }
    } else {
        Write-Log "  Resource group '$ResourceGroupName' already exists."
    }

    # Create or verify Automation Account
    $AACheck = Invoke-AzCommand -Arguments @("automation", "account", "show", "--name", $AutomationAccountName, "--resource-group", $ResourceGroupName, "-o", "json") -IgnoreExitCode
    if ($AACheck.ExitCode -ne 0) {
        if ($DryRun) {
            Write-Log "  [DRYRUN] Would create Automation Account '$AutomationAccountName' in '$Location'" "DRYRUN"
        } else {
            Write-Log "  Creating Automation Account '$AutomationAccountName'..."
            $AACreate = Invoke-AzCommand -Arguments @(
                "automation", "account", "create",
                "--name", $AutomationAccountName,
                "--resource-group", $ResourceGroupName,
                "--location", $Location,
                "-o", "none"
            )
            if ($AACreate.ExitCode -ne 0) {
                throw "Failed to create Automation Account: $($AACreate.ErrorDetail)"
            }
            Write-Log "  Automation Account created." "SUCCESS"
        }
    } else {
        Write-Log "  Automation Account '$AutomationAccountName' already exists."
    }

    # ── Step 4: Enable System-Assigned Managed Identity ───────────
    Write-Log "Enabling System-Assigned Managed Identity..."

    $MIPrincipalId = $null
    if ($DryRun) {
        Write-Log "  [DRYRUN] Would enable System-Assigned Managed Identity" "DRYRUN"
    } else {
        $MIResult = Invoke-AzCommand -Arguments @(
            "resource", "update",
            "--name", $AutomationAccountName,
            "--resource-group", $ResourceGroupName,
            "--resource-type", "Microsoft.Automation/automationAccounts",
            "--set", "identity.type=SystemAssigned",
            "-o", "json"
        )
        if ($MIResult.ExitCode -ne 0) {
            throw "Failed to enable Managed Identity: $($MIResult.ErrorDetail)"
        }
        $MIJson = $MIResult.StdOut | ConvertFrom-Json
        $MIPrincipalId = $MIJson.identity.principalId
        Write-Log "  Managed Identity enabled. Principal ID: $MIPrincipalId" "SUCCESS"
    }

    # ── Step 5: Hybrid Worker setup ───────────────────────────────
    $EffectiveWorkerGroup = "hwg-sync-dr-fileshares"
    $VMPrincipalId = $null
    $VMCreatedByScript = $false

    if ($HybridWorkerVMResourceId) {
        # ── Path 1: Use an existing VM as Hybrid Worker ──
        Write-Log "Setting up Hybrid Runbook Worker from existing VM..."

        # Parse VM resource ID
        if ($HybridWorkerVMResourceId -notmatch "(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)$") {
            throw "Invalid VM ARM Resource ID format: $HybridWorkerVMResourceId. Expected: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{name}"
        }
        $VMSubId = $Matches[1]
        $VMRGName = $Matches[2]
        $HybridWorkerVMName = $Matches[3]

        if ($DryRun) {
            Write-Log "  [DRYRUN] Would enable System-Assigned MI on VM '$HybridWorkerVMName'" "DRYRUN"
            Write-Log "  [DRYRUN] Would check and install prerequisites (az cli, azcopy, pwsh) on VM '$HybridWorkerVMName'" "DRYRUN"
            Write-Log "  [DRYRUN] Would create Hybrid Worker Group '$EffectiveWorkerGroup'" "DRYRUN"
            Write-Log "  [DRYRUN] Would register VM as Hybrid Worker" "DRYRUN"
        } else {
            $HWResult = Register-HybridWorker `
                -HybridWorkerVMName $HybridWorkerVMName `
                -VMResourceGroup $VMRGName `
                -VMSubscriptionId $VMSubId `
                -WorkerGroupName $EffectiveWorkerGroup `
                -AutomationAccountName $AutomationAccountName `
                -AAResourceGroup $ResourceGroupName `
                -AACheckResult $AACheck
            $VMPrincipalId = $HWResult.VMPrincipalId
        }

    } else {
        # ── Path 2: Create a new VM as Hybrid Worker ──
        if ([string]::IsNullOrWhiteSpace($HybridWorkerVMName)) {
            # Auto-generate VM name from AutomationAccountName by appending "-vm"
            $HybridWorkerVMName = "$($AutomationAccountName.ToLower())-vm"
            if ($HybridWorkerVMName.Length -gt 64) {
                $HybridWorkerVMName = $HybridWorkerVMName.Substring(0, 64)
            }
        } elseif ($HybridWorkerVMName.Length -gt 64) {
            throw "VM name '$HybridWorkerVMName' exceeds the maximum Azure VM resource name length of 64 characters."
        }

        $AASubId = $CurrentAccount.id

        Write-Log "Creating Hybrid Worker VM '$HybridWorkerVMName' ($VMOsType, $VMSize)..."

        if ($DryRun) {
            $DryRunOsDiskName  = "$HybridWorkerVMName-osdisk"
            $DryRunNicName     = "$HybridWorkerVMName-nic"
            $DryRunVNetName    = "$HybridWorkerVMName-vnet"
            $DryRunNSGName     = "$HybridWorkerVMName-nsg"
            Write-Log "  [DRYRUN] Would create VM '$HybridWorkerVMName' (size: $VMSize, os: $VMOsType) in '$ResourceGroupName'" "DRYRUN"
            Write-Log "  [DRYRUN]   OS Disk    : $DryRunOsDiskName" "DRYRUN"
            Write-Log "  [DRYRUN]   NIC        : $DryRunNicName" "DRYRUN"
            Write-Log "  [DRYRUN]   VNET       : $DryRunVNetName" "DRYRUN"
            Write-Log "  [DRYRUN]   NSG        : $DryRunNSGName" "DRYRUN"
            if (-not $SkipNatGateway) {
                $DryRunNatGwName = "$HybridWorkerVMName-natgw"
                $DryRunNatGwPip  = "$HybridWorkerVMName-natgw-pip"
                Write-Log "  [DRYRUN]   NAT Gateway: $DryRunNatGwName (Public IP: $DryRunNatGwPip)" "DRYRUN"
            } else {
                Write-Log "  [DRYRUN]   NAT Gateway: Skipped (-SkipNatGateway)" "DRYRUN"
            }
            Write-Log "  [DRYRUN] Would enable System-Assigned MI on VM '$HybridWorkerVMName'" "DRYRUN"
            Write-Log "  [DRYRUN] Would check and install prerequisites (az cli, azcopy, pwsh) on VM" "DRYRUN"
            Write-Log "  [DRYRUN] Would create Hybrid Worker Group '$EffectiveWorkerGroup'" "DRYRUN"
            Write-Log "  [DRYRUN] Would register VM as Hybrid Worker" "DRYRUN"
        } else {
            # Check if VM already exists (idempotent re-runs)
            $VMCheck = Invoke-AzCommand -Arguments @(
                "vm", "show",
                "--name", $HybridWorkerVMName,
                "--resource-group", $ResourceGroupName,
                "-o", "json"
            ) -IgnoreExitCode

            if ($VMCheck.ExitCode -eq 0) {
                Write-Log "  VM '$HybridWorkerVMName' already exists. Reusing." "SUCCESS"
            } else {
                # Create the VM with clean resource names
                $Image = if ($VMOsType -eq "Linux") { "Ubuntu2204" } else { "Win2022Datacenter" }

                # Derive clean names for all VM-related resources
                $OsDiskName  = "$HybridWorkerVMName-osdisk"
                $NicName     = "$HybridWorkerVMName-nic"
                $VNetName    = "$HybridWorkerVMName-vnet"
                $NSGName     = "$HybridWorkerVMName-nsg"
                $NatGwName   = "$HybridWorkerVMName-natgw"
                $NatGwPipName = "$HybridWorkerVMName-natgw-pip"
                $SubnetName  = "default"

                Write-Log "  Creating networking resources for VM '$HybridWorkerVMName'..."

                # Create NSG
                Write-Log "    Creating NSG '$NSGName'..."
                $NSGCreate = Invoke-AzCommand -Arguments @(
                    "network", "nsg", "create",
                    "--name", $NSGName,
                    "--resource-group", $ResourceGroupName,
                    "--location", $Location,
                    "-o", "none"
                ) -IgnoreExitCode
                if ($NSGCreate.ExitCode -ne 0) {
                    Write-Log "    NSG may already exist, continuing..." "WARN"
                }

                # Create VNET with subnet
                Write-Log "    Creating VNET '$VNetName' with subnet '$SubnetName'..."
                $VNetCreate = Invoke-AzCommand -Arguments @(
                    "network", "vnet", "create",
                    "--name", $VNetName,
                    "--resource-group", $ResourceGroupName,
                    "--location", $Location,
                    "--subnet-name", $SubnetName,
                    "-o", "none"
                ) -IgnoreExitCode
                if ($VNetCreate.ExitCode -ne 0) {
                    Write-Log "    VNET may already exist, continuing..." "WARN"
                }

                # Create NAT Gateway for outbound internet access (unless skipped)
                if (-not $SkipNatGateway) {
                    Write-Log "    Creating Public IP '$NatGwPipName' for NAT Gateway..."
                    $NatPipCreate = Invoke-AzCommand -Arguments @(
                        "network", "public-ip", "create",
                        "--name", $NatGwPipName,
                        "--resource-group", $ResourceGroupName,
                        "--location", $Location,
                        "--sku", "Standard",
                        "--allocation-method", "Static",
                        "-o", "none"
                    ) -IgnoreExitCode
                    if ($NatPipCreate.ExitCode -ne 0) {
                        Write-Log "    Public IP may already exist, continuing..." "WARN"
                    }

                    Write-Log "    Creating NAT Gateway '$NatGwName'..."
                    $NatGwCreate = Invoke-AzCommand -Arguments @(
                        "network", "nat", "gateway", "create",
                        "--name", $NatGwName,
                        "--resource-group", $ResourceGroupName,
                        "--location", $Location,
                        "--public-ip-addresses", $NatGwPipName,
                        "--idle-timeout", "4",
                        "-o", "none"
                    ) -IgnoreExitCode
                    if ($NatGwCreate.ExitCode -ne 0) {
                        Write-Log "    NAT Gateway may already exist, continuing..." "WARN"
                    }

                    # Associate NAT Gateway with subnet
                    Write-Log "    Associating NAT Gateway with subnet '$SubnetName'..."
                    $NatAssoc = Invoke-AzCommand -Arguments @(
                        "network", "vnet", "subnet", "update",
                        "--name", $SubnetName,
                        "--resource-group", $ResourceGroupName,
                        "--vnet-name", $VNetName,
                        "--nat-gateway", $NatGwName,
                        "-o", "none"
                    ) -IgnoreExitCode
                    if ($NatAssoc.ExitCode -ne 0) {
                        Write-Log "    WARNING: Failed to associate NAT Gateway with subnet. VM may lack outbound internet access." "WARN"
                    }
                } else {
                    Write-Log "    Skipping NAT Gateway creation (-SkipNatGateway). Ensure the VM has outbound internet access." "WARN"
                }

                # Create NIC attached to subnet and NSG
                Write-Log "    Creating NIC '$NicName'..."
                $NicCreate = Invoke-AzCommand -Arguments @(
                    "network", "nic", "create",
                    "--name", $NicName,
                    "--resource-group", $ResourceGroupName,
                    "--location", $Location,
                    "--vnet-name", $VNetName,
                    "--subnet", $SubnetName,
                    "--network-security-group", $NSGName,
                    "-o", "none"
                ) -IgnoreExitCode
                if ($NicCreate.ExitCode -ne 0) {
                    Write-Log "    NIC may already exist, continuing..." "WARN"
                }

                $azVmArgs = @(
                    "vm", "create",
                    "--name", $HybridWorkerVMName,
                    "--resource-group", $ResourceGroupName,
                    "--location", $Location,
                    "--image", $Image,
                    "--size", $VMSize,
                    "--assign-identity",
                    "--admin-username", "azadmin",
                    "--public-ip-address", "",
                    "--os-disk-name", $OsDiskName,
                    "--nics", $NicName,
                    "-o", "json"
                )

                # Linux: SSH keys (no password needed). Windows: generate random password.
                if ($VMOsType -eq "Linux") {
                    $azVmArgs += "--generate-ssh-keys"
                    $azVmArgs += "--authentication-type"
                    $azVmArgs += "ssh"
                } else {
                    # Generate a random 24-char password for Windows admin
                    $VMPassword = -join ((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,64) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
                    $azVmArgs += "--admin-password"
                    $azVmArgs += $VMPassword
                }

                Write-Log "  Creating VM '$HybridWorkerVMName' ($VMOsType, $VMSize) in '$ResourceGroupName'..."
                $VMCreateResult = Invoke-AzCommand -Arguments $azVmArgs
                if ($VMCreateResult.ExitCode -ne 0) {
                    throw "Failed to create VM '$HybridWorkerVMName': $($VMCreateResult.ErrorDetail)"
                }
                Write-Log "  VM '$HybridWorkerVMName' created." "SUCCESS"
                $VMCreatedByScript = $true

                if ($VMOsType -eq "Windows") {
                    Write-Log "  Admin credentials: username=azadmin (password shown once, store securely)" "WARN"
                    Write-Log "  Admin password: $VMPassword" "WARN"
                }

                # Wait for the VM guest agent to become ready before running commands
                Write-Log "  Waiting for VM guest agent to become ready..."
                $AgentReady = $false
                $AgentWaitMax = 120
                $AgentWaitElapsed = 0
                while ($AgentWaitElapsed -lt $AgentWaitMax) {
                    Start-Sleep -Seconds 15
                    $AgentWaitElapsed += 15
                    $AgentCheck = Invoke-AzCommand -Arguments @(
                        "vm", "get-instance-view",
                        "--name", $HybridWorkerVMName,
                        "--resource-group", $ResourceGroupName,
                        "--query", "instanceView.vmAgent.statuses[0].displayStatus",
                        "-o", "tsv"
                    ) -IgnoreExitCode
                    if ($AgentCheck.StdOut -and $AgentCheck.StdOut.Trim() -eq "Ready") {
                        $AgentReady = $true
                        break
                    }
                    Write-Log "    Agent not ready yet (${AgentWaitElapsed}s elapsed)..."
                }
                if ($AgentReady) {
                    Write-Log "  VM guest agent is ready." "SUCCESS"
                } else {
                    Write-Log "  WARNING: VM guest agent did not report ready within ${AgentWaitMax}s. Proceeding anyway..." "WARN"
                }
            }

            # Register as Hybrid Worker (MI, prerequisites, HWG, worker)
            $HWResult = Register-HybridWorker `
                -HybridWorkerVMName $HybridWorkerVMName `
                -VMResourceGroup $ResourceGroupName `
                -VMSubscriptionId $AASubId `
                -WorkerGroupName $EffectiveWorkerGroup `
                -AutomationAccountName $AutomationAccountName `
                -AAResourceGroup $ResourceGroupName `
                -AACheckResult $AACheck
            $VMPrincipalId = $HWResult.VMPrincipalId
        }
    }

    # ── Step 6: Assign RBAC ───────────────────────────────────────
    Write-Log "Assigning RBAC 'Storage Account Contributor' to $($UniqueRGScopes.Count) resource group scope(s)..."

    $RoleName = "Storage Account Contributor"
    $PrincipalsToAssign = @()

    if ($MIPrincipalId) {
        $PrincipalsToAssign += @{ Id = $MIPrincipalId; Label = "Automation Account MI" }
    }
    if ($VMPrincipalId) {
        $PrincipalsToAssign += @{ Id = $VMPrincipalId; Label = "VM MI" }
    }

    $RBACAssigned = 0
    $RBACSkipped = 0

    foreach ($Scope in $UniqueRGScopes.Keys) {
        $ScopeType = $UniqueRGScopes[$Scope]
        foreach ($Principal in $PrincipalsToAssign) {
            if ($DryRun) {
                Write-Log "  [DRYRUN] Would assign '$RoleName' to $($Principal.Label) ($($Principal.Id)) at $ScopeType scope: $Scope" "DRYRUN"
            } else {
                # Check if assignment already exists before creating
                $ExistingCheck = Invoke-AzCommand -Arguments @(
                    "role", "assignment", "list",
                    "--assignee", $Principal.Id,
                    "--role", $RoleName,
                    "--scope", $Scope,
                    "--query", "length(@)",
                    "-o", "tsv"
                ) -IgnoreExitCode

                if ($ExistingCheck.StdOut -and [int]$ExistingCheck.StdOut.Trim() -gt 0) {
                    $RBACSkipped++
                } else {
                    Write-Log "  Assigning '$RoleName' to $($Principal.Label) at $ScopeType scope: $Scope..."
                    $RBACResult = Invoke-AzCommand -Arguments @(
                        "role", "assignment", "create",
                        "--assignee-object-id", $Principal.Id,
                        "--assignee-principal-type", "ServicePrincipal",
                        "--role", $RoleName,
                        "--scope", $Scope,
                        "-o", "none"
                    ) -IgnoreExitCode
                    $RBACAssigned++
                }
            }
        }
    }

    if (-not $DryRun) {
        Write-Log "  RBAC: $RBACAssigned new assignment(s), $RBACSkipped already existed (skipped)." "SUCCESS"
    }

    # ── Step 7: Create Runtime Environment (PowerShell 7.4) ──────
    $RuntimeEnvName = "PowerShell-7.4"
    $AASubId = $CurrentAccount.id
    $ApiVersion = "2024-10-23"

    Write-Log "Creating Runtime Environment '$RuntimeEnvName' with Az modules..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would create Runtime Environment '$RuntimeEnvName' (PowerShell 7.4, Az 12.3.0)" "DRYRUN"
        Write-Log "  [DRYRUN] Would add package Az.Storage to Runtime Environment" "DRYRUN"
    } else {
        # Create Runtime Environment (includes Az 12.3.0 by default)
        $RTEApiUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runtimeEnvironments/$RuntimeEnvName`?api-version=$ApiVersion"
        $RTEBody = @{
            location   = $Location
            properties = @{
                runtime = @{
                    language = "PowerShell"
                    version  = "7.4"
                }
                defaultPackages = @{
                    Az = "12.3.0"
                }
                description = "PowerShell 7.4 runtime for DR File Share sync (managed by Setup-SyncAutomation.ps1)"
            }
        } | ConvertTo-Json -Depth 5

        $RTEResult = Invoke-AzCommand -Arguments @(
            "rest", "--method", "PUT",
            "--url", $RTEApiUrl,
            "--body", $RTEBody,
            "--headers", "Content-Type=application/json",
            "-o", "none"
        ) -IgnoreExitCode

        if ($RTEResult.ExitCode -eq 0) {
            Write-Log "  Runtime Environment '$RuntimeEnvName' created." "SUCCESS"
        } else {
            Write-Log "  WARNING: Runtime Environment creation may have failed: $($RTEResult.ErrorDetail)" "WARN"
            Write-Log "  The runtime environment may already exist. Continuing..." "WARN"
        }

        # Add Az.Storage package explicitly (Az default package may not include all sub-modules)
        $PkgApiUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runtimeEnvironments/$RuntimeEnvName/packages/Az.Storage`?api-version=$ApiVersion"
        $PkgBody = @{
            properties = @{
                contentLink = @{
                    uri = "https://www.powershellgallery.com/api/v2/package/Az.Storage"
                }
            }
        } | ConvertTo-Json -Depth 5

        $PkgResult = Invoke-AzCommand -Arguments @(
            "rest", "--method", "PUT",
            "--url", $PkgApiUrl,
            "--body", $PkgBody,
            "--headers", "Content-Type=application/json",
            "-o", "none"
        ) -IgnoreExitCode

        if ($PkgResult.ExitCode -eq 0) {
            Write-Log "  Package Az.Storage added to Runtime Environment." "SUCCESS"
        } else {
            Write-Log "  WARNING: Az.Storage package may have failed: $($PkgResult.ErrorDetail)" "WARN"
            Write-Log "  The package may already be available. Continuing..." "WARN"
        }

        # Wait for Runtime Environment to provision
        Write-Log "  Waiting for Runtime Environment to provision (may take 2-5 minutes)..."
        $MaxWaitSeconds = 600
        $ElapsedSeconds = 0
        $RTEReady = $false

        while ($ElapsedSeconds -lt $MaxWaitSeconds) {
            Start-Sleep -Seconds 15
            $ElapsedSeconds += 15

            $RTECheck = Invoke-AzCommand -Arguments @(
                "rest", "--method", "GET",
                "--url", $RTEApiUrl,
                "-o", "json"
            ) -IgnoreExitCode

            if ($RTECheck.ExitCode -eq 0 -and $RTECheck.StdOut) {
                $RTEState = ($RTECheck.StdOut | ConvertFrom-Json).properties.provisioningState
                if ($RTEState -eq "Succeeded") {
                    Write-Log "  Runtime Environment ready." "SUCCESS"
                    $RTEReady = $true
                    break
                } elseif ($RTEState -eq "Failed") {
                    Write-Log "  WARNING: Runtime Environment provisioning failed." "WARN"
                    break
                }
                Write-Log "  Runtime Environment provisioning state: $RTEState (${ElapsedSeconds}s elapsed)..."
            }
        }

        if (-not $RTEReady) {
            Write-Log "  WARNING: Runtime Environment provisioning did not complete within ${MaxWaitSeconds}s." "WARN"
            Write-Log "  Check the Automation Account in the portal." "WARN"
        }
    }

    # ── Step 8: Import and publish Runbook ─────────────────────────
    $RunbookName = "Sync-DRFileShares"
    Write-Log "Importing Runbook '$RunbookName' from $RunbookPath..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would import runbook from: $RunbookPath" "DRYRUN"
        Write-Log "  [DRYRUN] Would publish runbook: $RunbookName (Runtime Environment: $RuntimeEnvName)" "DRYRUN"
    } else {
        # Import the runbook using ARM REST API with Runtime Environment (PowerShell 7.4)
        $RunbookContent = Get-Content $RunbookPath -Raw

        # Create/update runbook definition linked to Runtime Environment
        $RunbookApiUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/$RunbookName`?api-version=$ApiVersion"
        $RunbookBody = @{
            location = $Location
            properties = @{
                runbookType        = "PowerShell7"
                runtimeEnvironment = $RuntimeEnvName
                description        = "Syncs Azure File Shares from source to destination using AzCopy (Managed Identity auth)."
            }
        } | ConvertTo-Json -Depth 5

        $RBCreate = Invoke-AzCommand -Arguments @(
            "rest", "--method", "PUT",
            "--url", $RunbookApiUrl,
            "--body", $RunbookBody,
            "--headers", "Content-Type=application/json",
            "-o", "none"
        )
        if ($RBCreate.ExitCode -ne 0) {
            throw "Failed to create runbook: $($RBCreate.ErrorDetail)"
        }

        # Upload runbook content (draft)
        $DraftUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/$RunbookName/draft/content?api-version=$ApiVersion"

        # Write content to a temp file for upload
        $TempRunbookFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $TempRunbookFile -Value $RunbookContent -Encoding UTF8

            $DraftUpload = Invoke-AzCommand -Arguments @(
                "rest", "--method", "PUT",
                "--url", $DraftUrl,
                "--body", "@$TempRunbookFile",
                "--headers", "Content-Type=text/powershell",
                "-o", "none"
            )
            if ($DraftUpload.ExitCode -ne 0) {
                throw "Failed to upload runbook content: $($DraftUpload.ErrorDetail)"
            }
        } finally {
            Remove-Item $TempRunbookFile -ErrorAction SilentlyContinue
        }

        # Publish the runbook
        $PublishUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/$RunbookName/publish?api-version=$ApiVersion"
        $Publish = Invoke-AzCommand -Arguments @(
            "rest", "--method", "POST",
            "--url", $PublishUrl,
            "--headers", "Content-Type=application/json",
            "-o", "none"
        )
        if ($Publish.ExitCode -ne 0) {
            throw "Failed to publish runbook: $($Publish.ErrorDetail)"
        }

        Write-Log "  Runbook '$RunbookName' imported and published (Runtime: $RuntimeEnvName)." "SUCCESS"
    }

    # ── Step 9: Store CSV and config as Automation Variables ───────
    Write-Log "Storing configuration in Automation Variables..."

    $CsvContent = Get-Content $CsvFullPath -Raw

    $Variables = @(
        @{ Name = "SyncCSVContent";          Value = $CsvContent;                                                                      Encrypted = $true  },
        @{ Name = "SyncMode";                Value = $SyncMode;                                                                         Encrypted = $false },
        @{ Name = "DestSubscriptionId";      Value = $(if ($DestSubscriptionId) { $DestSubscriptionId } else { "" });                   Encrypted = $false },
        @{ Name = "PreserveSmbPermissions";  Value = $(if ($PreserveSmbPermissions) { "true" } else { "false" });                        Encrypted = $false },
        @{ Name = "ExcludePattern";          Value = $(if ($ExcludePattern) { $ExcludePattern } else { "" });                            Encrypted = $false }
    )

    foreach ($Var in $Variables) {
        if ($DryRun) {
            $DisplayVal = if ($Var.Encrypted) { "(encrypted, $($Var.Value.Length) chars)" } else { "'$($Var.Value)'" }
            Write-Log "  [DRYRUN] Would set variable '$($Var.Name)' = $DisplayVal" "DRYRUN"
        } else {
            # Use ARM REST API to create/update variables
            $AASubId = $CurrentAccount.id
            $VarApiUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/variables/$($Var.Name)?api-version=$ApiVersion"

            $VarBody = @{
                properties = @{
                    value       = "`"$($Var.Value -replace '\\', '\\\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r')`""
                    isEncrypted = $Var.Encrypted
                    description = "Managed by Setup-SyncAutomation.ps1"
                }
            } | ConvertTo-Json -Depth 5

            $VarResult = Invoke-AzCommand -Arguments @(
                "rest", "--method", "PUT",
                "--url", $VarApiUrl,
                "--body", $VarBody,
                "--headers", "Content-Type=application/json",
                "-o", "none"
            ) -IgnoreExitCode

            if ($VarResult.ExitCode -eq 0) {
                Write-Log "  Variable '$($Var.Name)' set." "SUCCESS"
            } else {
                Write-Log "  WARNING: Failed to set variable '$($Var.Name)': $($VarResult.ErrorDetail)" "WARN"
            }
        }
    }

    # ── Step 10: Create recurring Schedule ─────────────────────────
    $ScheduleName = "SyncDRFileShares-Every${ScheduleIntervalHours}h"
    $StartTime = (Get-Date).ToUniversalTime().AddHours(1).ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Log "Creating schedule '$ScheduleName' (every $ScheduleIntervalHours hours, starting ~1 hour from now)..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would create schedule: $ScheduleName (every $ScheduleIntervalHours hours)" "DRYRUN"
    } else {
        $AASubId = $CurrentAccount.id

        # Delete existing schedule if present (idempotent update)
        $DelScheduleUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/schedules/$ScheduleName`?api-version=$ApiVersion"
        Invoke-AzCommand -Arguments @(
            "rest", "--method", "DELETE",
            "--url", $DelScheduleUrl,
            "-o", "none"
        ) -IgnoreExitCode | Out-Null

        # Create schedule
        $ExpiryTime = (Get-Date).ToUniversalTime().AddYears(5).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $ScheduleApiUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/schedules/$ScheduleName`?api-version=$ApiVersion"
        $ScheduleBody = @{
            properties = @{
                startTime   = $StartTime
                expiryTime  = $ExpiryTime
                interval    = $ScheduleIntervalHours
                frequency   = "Hour"
                timeZone    = "UTC"
                description = "Sync DR File Shares every $ScheduleIntervalHours hours"
            }
        } | ConvertTo-Json -Depth 5

        $ScheduleResult = Invoke-AzCommand -Arguments @(
            "rest", "--method", "PUT",
            "--url", $ScheduleApiUrl,
            "--body", $ScheduleBody,
            "--headers", "Content-Type=application/json",
            "-o", "none"
        )
        if ($ScheduleResult.ExitCode -ne 0) {
            throw "Failed to create schedule: $($ScheduleResult.ErrorDetail)"
        }
        Write-Log "  Schedule created." "SUCCESS"
    }

    # ── Step 11: Link Runbook to Schedule ──────────────────────────
    Write-Log "Linking Runbook '$RunbookName' to schedule '$ScheduleName'..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would link runbook to schedule (target: Hybrid Worker: $EffectiveWorkerGroup)" "DRYRUN"
    } else {
        $AASubId = $CurrentAccount.id
        $JobScheduleId = [guid]::NewGuid().ToString()
        $JobScheduleUrl = "https://management.azure.com/subscriptions/$AASubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobSchedules/$JobScheduleId`?api-version=$ApiVersion"

        $JobScheduleBody = @{
            properties = @{
                schedule = @{ name = $ScheduleName }
                runbook  = @{ name = $RunbookName }
            }
        }

        if ($EffectiveWorkerGroup) {
            $JobScheduleBody.properties["runOn"] = $EffectiveWorkerGroup
        }

        $JobScheduleJson = $JobScheduleBody | ConvertTo-Json -Depth 5

        $LinkResult = Invoke-AzCommand -Arguments @(
            "rest", "--method", "PUT",
            "--url", $JobScheduleUrl,
            "--body", $JobScheduleJson,
            "--headers", "Content-Type=application/json",
            "-o", "none"
        )
        if ($LinkResult.ExitCode -ne 0) {
            throw "Failed to link runbook to schedule: $($LinkResult.ErrorDetail)"
        }
        Write-Log "  Runbook linked to schedule." "SUCCESS"
    }

    # ── Summary ───────────────────────────────────────────────────
    $TotalElapsed = (Get-Date) - $ScriptStartTime
    $TotalDuration = Format-Duration $TotalElapsed

    Write-Log "=================================================================="
    Write-Log "  SUMMARY                                          ($TotalDuration)"
    Write-Log "=================================================================="
    Write-Log "  Automation Account       : $AutomationAccountName"
    Write-Log "  Resource Group           : $ResourceGroupName"
    Write-Log "  Location                 : $Location"
    Write-Log "  MI Principal ID          : $(if ($MIPrincipalId) { $MIPrincipalId } else { '(dry-run)' })"
    if ($VMPrincipalId) {
        Write-Log "  VM MI Principal ID       : $VMPrincipalId"
    }
    if ($VMCreatedByScript) {
        Write-Log "  VM created               : $HybridWorkerVMName ($VMSize, $VMOsType)"
    }
    Write-Log "  RBAC scopes              : $($UniqueRGScopes.Count) resource group(s)"
    Write-Log "  Runtime Environment      : $RuntimeEnvName"
    Write-Log "  Runbook                  : $RunbookName"
    Write-Log "  Schedule                 : $ScheduleName (every ${ScheduleIntervalHours}h)"
    Write-Log "  SyncMode                 : $SyncMode"
    Write-Log "  Run target               : Hybrid Worker: $EffectiveWorkerGroup"
    Write-Log "  CSV rows                 : $TotalRows"
    Write-Log "  Total elapsed time       : $TotalDuration"
    Write-Log "=================================================================="

    # RBAC propagation warning
    if (-not $DryRun) {
        Write-Log ""
        Write-Log "  NOTE: RBAC role assignments may take 5-10 minutes to propagate." "WARN"
        Write-Log "  If the first scheduled run fails with permission errors, wait" "WARN"
        Write-Log "  and retry from the Azure portal." "WARN"
    }

    Write-Log "=================================================================="

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
