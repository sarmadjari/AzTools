<#
.SYNOPSIS
    Sets up a Linux VM with a cron job to sync DR File Shares automatically.

.DESCRIPTION
    Deploys and configures a Linux VM to run Sync-DRFileShares.ps1 on a recurring
    schedule via cron — no Azure Automation Account required.

      1. Validates prerequisites (az CLI, CSV, sync script)
      2. Pre-validates CSV mapping (ARM IDs, account names, duplicates)
      3. Creates or verifies a Linux VM (with networking if new)
      4. Enables System-Assigned Managed Identity on the VM
      5. Installs prerequisites (az CLI, AzCopy, PowerShell 7) on the VM
      6. Assigns RBAC (Storage Account Contributor) at Resource Group scope
      7. Copies Sync-DRFileShares.ps1 and CSV to the VM (/opt/dr-sync/)
      8. Creates a wrapper script and config on the VM
      9. Sets up a cron job for recurring sync
     10. Configures log rotation for sync logs

    The VM authenticates using its System-Assigned Managed Identity. AzCopy runs
    directly on the VM via cron — simpler and more reliable than the Automation
    Account + Hybrid Worker approach.

    The script is idempotent — safe to re-run to update the CSV, change the
    schedule interval, or add RBAC for new resource groups.

.PARAMETER ResourceGroupName
    Resource group for the VM. Created if it does not exist.
    Required when creating a new VM (-VMName). When using -VMResourceId,
    defaults to the VM's resource group if not specified.

.PARAMETER Location
    Azure region (e.g., "switzerlandnorth").
    Required when creating a new VM (-VMName). When using -VMResourceId,
    auto-detected from the VM if not specified.

.PARAMETER CsvPath
    Path to the CSV mapping file with headers:
    SourceResourceId, DestStorageAccountName, DestResourceGroupName

.PARAMETER VMResourceId
    ARM Resource ID of an existing Linux VM to use. The script enables the VM's
    Managed Identity, installs prerequisites, and deploys the sync automation.
    Mutually exclusive with -VMName.

.PARAMETER VMName
    Name for a new Linux VM to create. The script creates networking resources
    (NSG, VNET, NAT Gateway) and the VM with System-Assigned MI.
    Mutually exclusive with -VMResourceId.

.PARAMETER VMSize
    VM size for the new VM (default: Standard_B2s).
    Only used when creating a new VM with -VMName.

.PARAMETER DestSubscriptionId
    Optional. Subscription for destination storage accounts. Defaults to source
    subscription (parsed from CSV).

.PARAMETER ScheduleIntervalHours
    How often to run the sync (default: 12 hours, range: 1-24).

.PARAMETER SyncMode
    Additive (default) or Mirror.
    Additive = sync changes, never delete on destination.
    Mirror   = sync changes + delete files on destination that don't exist on source.

.PARAMETER PreserveSmbPermissions
    Switch. When set, the sync passes --preserve-smb-permissions=true to AzCopy.

.PARAMETER ExcludePattern
    Semicolon-delimited glob pattern passed to AzCopy --exclude-pattern.
    Example: "*.tmp;~$*;thumbs.db"

.PARAMETER ExistingVNetName
    Name of an existing Virtual Network to place the VM into. Use for Hub-Spoke
    topologies or when the VM must join a pre-provisioned network. When set, the
    script skips VNET/Subnet creation and uses the specified network instead.
    Must be combined with -ExistingSubnetName. -ExistingVNetResourceGroup defaults
    to -ResourceGroupName if omitted.

.PARAMETER ExistingSubnetName
    Name of the subnet within -ExistingVNetName. Required when -ExistingVNetName
    is specified. The subnet must already exist.

.PARAMETER ExistingVNetResourceGroup
    Resource group that contains the existing VNet. Defaults to -ResourceGroupName
    when omitted — set this explicitly when the VNet lives in a different RG
    (common in Hub-Spoke deployments).

.PARAMETER SkipNatGateway
    Switch. Skips NAT Gateway and Public IP creation for the new VM.
    Use when the VM subnet already has outbound internet access.

.PARAMETER DryRun
    Switch. Shows what would be created without making changes.

.EXAMPLE
    .\Setup-SyncVM.ps1 `
        -ResourceGroupName "rg-dr-sync" `
        -Location "switzerlandnorth" `
        -CsvPath ".\resources.csv" `
        -VMName "vm-dr-sync"

    Creates a new Linux VM and sets up recurring sync every 12 hours.

.EXAMPLE
    .\Setup-SyncVM.ps1 `
        -CsvPath ".\resources.csv" `
        -VMResourceId "/subscriptions/.../virtualMachines/vm-existing"

    Uses an existing VM. ResourceGroupName and Location are auto-detected
    from the VM Resource ID.

.EXAMPLE
    .\Setup-SyncVM.ps1 `
        -ResourceGroupName "rg-dr-sync" `
        -Location "switzerlandnorth" `
        -CsvPath ".\resources.csv" `
        -VMName "vm-dr-sync" `
        -ScheduleIntervalHours 4 `
        -SyncMode Mirror `
        -DestSubscriptionId "c4b9bb52-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

    Creates a VM with Mirror mode sync every 4 hours, cross-subscription.

.EXAMPLE
    .\Setup-SyncVM.ps1 `
        -ResourceGroupName "rg-dr-sync" `
        -Location "switzerlandnorth" `
        -CsvPath ".\resources.csv" `
        -VMName "vm-dr-sync" `
        -ExistingVNetName "hub-vnet" `
        -ExistingSubnetName "snet-sync" `
        -ExistingVNetResourceGroup "rg-networking" `
        -SkipNatGateway

    Creates a VM in an existing Hub-Spoke VNet (VNet in a different RG).

.EXAMPLE
    .\Setup-SyncVM.ps1 `
        -ResourceGroupName "rg-dr-sync" `
        -Location "switzerlandnorth" `
        -CsvPath ".\resources.csv" `
        -VMName "vm-dr-sync" `
        -DryRun

    Shows what would be created without making any changes.

.NOTES
    Author  : AzTools
    Version : 1.2
    Date    : 2026-04-01
    Requires: Azure CLI (az), PowerShell 5.1+ (for running this setup script)
#>

param (
    [Parameter(Mandatory=$false)][string]$ResourceGroupName,
    [Parameter(Mandatory=$false)][string]$Location,
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$false)][string]$VMResourceId,
    [Parameter(Mandatory=$false)][string]$VMName,
    [Parameter(Mandatory=$false)][string]$VMSize = "Standard_B2s",
    [Parameter(Mandatory=$false)][string]$ExistingVNetName,
    [Parameter(Mandatory=$false)][string]$ExistingSubnetName,
    [Parameter(Mandatory=$false)][string]$ExistingVNetResourceGroup,
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
        Checks and installs missing prerequisites (az cli, azcopy, pwsh) on a Linux
        VM via az vm run-command invoke. Continues with warnings on failure.
    #>
    param(
        [string]$VMNameParam,
        [string]$VMResourceGroup
    )

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
    curl -sL https://aka.ms/install-powershell.sh | bash 2>/dev/null || echo "FAILED:PowerShell7"
    if command -v pwsh &>/dev/null; then echo "INSTALLED:PowerShell7"; else echo "FAILED:PowerShell7"; fi
else
    echo "OK:PowerShell7"
fi
'@

    $TempScript = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $TempScript -Value $Script -Encoding UTF8

    try {
        Write-Log "    Running prerequisite check on VM (this may take a few minutes)..."
        $RunResult = Invoke-AzCommand -Arguments @(
            "vm", "run-command", "invoke",
            "--name", $VMNameParam,
            "--resource-group", $VMResourceGroup,
            "--command-id", "RunShellScript",
            "--scripts", "@$TempScript",
            "-o", "json"
        ) -IgnoreExitCode

        if ($RunResult.ExitCode -ne 0) {
            Write-Log "    WARNING: Could not run prerequisite check on VM. Install az cli, azcopy, and pwsh manually." "WARN"
            Write-Log "    Error: $($RunResult.ErrorDetail)" "WARN"
            return
        }

        $RunOutput = $RunResult.StdOut | ConvertFrom-Json
        $StdOutMessages = if ($RunOutput.value) {
            ($RunOutput.value | Where-Object { $_.code -eq "ComponentStatus/StdOut/succeeded" }).message
        } else { "" }

        if (-not $StdOutMessages) {
            # Try alternate format (direct .message on first value entry)
            $StdOutMessages = if ($RunOutput.value -and $RunOutput.value[0].message) {
                $RunOutput.value[0].message
            } else { "" }
        }

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

# ── New Helper Functions ─────────────────────────────────────────

function Invoke-VMRunCommand {
    <#
    .SYNOPSIS
        Runs a shell script on the VM via az vm run-command invoke and returns
        parsed stdout/stderr.
    #>
    param(
        [string]$VMNameParam,
        [string]$VMResourceGroup,
        [string]$Script
    )

    $TempScript = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $TempScript -Value $Script -Encoding UTF8

    try {
        $RunResult = Invoke-AzCommand -Arguments @(
            "vm", "run-command", "invoke",
            "--name", $VMNameParam,
            "--resource-group", $VMResourceGroup,
            "--command-id", "RunShellScript",
            "--scripts", "@$TempScript",
            "-o", "json"
        ) -IgnoreExitCode

        $StdOut = ""
        $StdErr = ""

        if ($RunResult.ExitCode -eq 0 -and $RunResult.StdOut) {
            $Parsed = $RunResult.StdOut | ConvertFrom-Json
            if ($Parsed.value) {
                foreach ($Entry in $Parsed.value) {
                    if ($Entry.code -match "StdOut") { $StdOut = $Entry.message }
                    if ($Entry.code -match "StdErr") { $StdErr = $Entry.message }
                }
                # Fallback: some formats use message directly
                if (-not $StdOut -and $Parsed.value[0].message) {
                    $FullMsg = $Parsed.value[0].message
                    if ($FullMsg -match "(?s)\[stdout\]\n(.*?)\n\[stderr\]\n(.*)") {
                        $StdOut = $Matches[1]
                        $StdErr = $Matches[2]
                    } else {
                        $StdOut = $FullMsg
                    }
                }
            }
        }

        return @{
            Success = ($RunResult.ExitCode -eq 0)
            StdOut  = $StdOut
            StdErr  = $StdErr
            ErrorDetail = $RunResult.ErrorDetail
        }
    } finally {
        Remove-Item $TempScript -ErrorAction SilentlyContinue
    }
}

function Copy-FileToVM {
    <#
    .SYNOPSIS
        Transfers a local file to the VM via base64 encoding + az vm run-command invoke.
    #>
    param(
        [string]$VMNameParam,
        [string]$VMResourceGroup,
        [string]$LocalPath,
        [string]$RemotePath
    )

    $Bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $B64 = [Convert]::ToBase64String($Bytes)
    $LocalSize = $Bytes.Length

    # Split into chunks if needed (keep under 150KB per command to leave headroom)
    $ChunkSize = 150000
    $Chunks = @()
    for ($i = 0; $i -lt $B64.Length; $i += $ChunkSize) {
        $End = [Math]::Min($i + $ChunkSize, $B64.Length)
        $Chunks += $B64.Substring($i, $End - $i)
    }

    # Derive remote directory (Linux path)
    $RemoteDir = $RemotePath.Substring(0, $RemotePath.LastIndexOf('/'))

    for ($c = 0; $c -lt $Chunks.Count; $c++) {
        $Redirect = if ($c -eq 0) { ">" } else { ">>" }
        $ChunkScript = @"
mkdir -p $RemoteDir
echo '$($Chunks[$c])' | base64 -d $Redirect $RemotePath
"@
        $Result = Invoke-VMRunCommand -VMNameParam $VMNameParam -VMResourceGroup $VMResourceGroup -Script $ChunkScript
        if (-not $Result.Success) {
            throw "Failed to copy file chunk $($c+1)/$($Chunks.Count) to ${RemotePath}: $($Result.ErrorDetail)"
        }
    }

    # Verify file size
    $VerifyResult = Invoke-VMRunCommand -VMNameParam $VMNameParam -VMResourceGroup $VMResourceGroup -Script "wc -c < $RemotePath"
    if ($VerifyResult.Success) {
        $RemoteSize = [int]($VerifyResult.StdOut.Trim())
        if ($RemoteSize -ne $LocalSize) {
            Write-Log "    WARNING: Size mismatch for $RemotePath (local: $LocalSize, remote: $RemoteSize)" "WARN"
        }
    }
}

# ── Main Script ──────────────────────────────────────────────────

try {
    # ── Step 1: Validate prerequisites ────────────────────────────
    Write-Log "Validating prerequisites..."

    $AzCliPath = Get-Command az -ErrorAction SilentlyContinue
    if (-not $AzCliPath) {
        throw "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
    }

    $LoginCheck = Invoke-AzCommand -Arguments @("account", "show", "-o", "json") -IgnoreExitCode
    if ($LoginCheck.ExitCode -ne 0) {
        throw "Not logged in to Azure CLI. Run 'az login' first."
    }
    $CurrentAccount = $LoginCheck.StdOut | ConvertFrom-Json
    Write-Log "  Logged in as: $($CurrentAccount.user.name) (subscription: $($CurrentAccount.name))"

    if ($VMResourceId -and $VMName) {
        throw "Cannot specify both -VMResourceId and -VMName. Use -VMResourceId for an existing VM, or -VMName to create a new one."
    }
    if (-not $VMResourceId -and -not $VMName) {
        throw "Must specify either -VMResourceId (existing VM) or -VMName (create new VM)."
    }

    # When using existing VM, parse Resource ID early and derive defaults
    if ($VMResourceId) {
        if ($VMResourceId -notmatch "(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)$") {
            throw "Invalid VM ARM Resource ID format: $VMResourceId. Expected: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{name}"
        }
        $VMSubId = $Matches[1]
        $VMRGResolved = $Matches[2]
        $VMNameResolved = $Matches[3]

        if (-not $ResourceGroupName) {
            $ResourceGroupName = $VMRGResolved
            Write-Log "  -ResourceGroupName not provided, derived from VM Resource ID: '$ResourceGroupName'"
        }

        if (-not $Location) {
            $VMLocQuery = Invoke-AzCommand -Arguments @(
                "vm", "show", "--name", $VMNameResolved, "--resource-group", $VMRGResolved,
                "--query", "location", "-o", "tsv"
            ) -IgnoreExitCode
            if ($VMLocQuery.ExitCode -eq 0 -and $VMLocQuery.StdOut.Trim()) {
                $Location = $VMLocQuery.StdOut.Trim()
                Write-Log "  -Location not provided, detected from VM: '$Location'"
            } else {
                Write-Log "  WARNING: Could not detect VM location. Specify -Location explicitly for accurate reporting." "WARN"
                $Location = "(unknown)"
            }
        }
    }

    # ResourceGroupName and Location are required when creating a new VM
    if ($VMName) {
        if (-not $ResourceGroupName) {
            throw "-ResourceGroupName is required when creating a new VM with -VMName."
        }
        if (-not $Location) {
            throw "-Location is required when creating a new VM with -VMName."
        }
    }

    # Validate VNet parameters
    if ($ExistingVNetName -and -not $ExistingSubnetName) {
        throw "-ExistingSubnetName is required when -ExistingVNetName is specified."
    }
    if ($ExistingSubnetName -and -not $ExistingVNetName) {
        throw "-ExistingVNetName is required when -ExistingSubnetName is specified."
    }
    if ($ExistingVNetName -and $VMResourceId) {
        throw "-ExistingVNetName cannot be used with -VMResourceId (existing VMs already have networking)."
    }
    if (-not $ExistingVNetResourceGroup -and $ExistingVNetName) {
        $ExistingVNetResourceGroup = $ResourceGroupName
        Write-Log "  -ExistingVNetResourceGroup not specified, defaulting to '$ResourceGroupName'"
    }

    if (-Not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }
    $CsvFullPath = (Resolve-Path $CsvPath).Path
    Write-Log "  CSV mapping: $CsvFullPath"

    $RunbookPath = Join-Path $PSScriptRoot "Sync-DRFileShares.ps1"
    if (-not (Test-Path $RunbookPath)) {
        throw "Sync script not found: $RunbookPath. Ensure Sync-DRFileShares.ps1 is in the same directory as this script."
    }

    # ── Step 2: Pre-validate CSV ──────────────────────────────────
    $AccountList = Import-Csv $CsvFullPath
    if ($AccountList.Count -eq 0) {
        throw "CSV file is empty."
    }

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

        $SrcId = if ($Row.SourceResourceId) { $Row.SourceResourceId.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($SrcId)) {
            $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="SourceResourceId"; Value="(empty)"; Error="SourceResourceId is empty" }
        } else {
            if ($SrcId -notmatch "(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$") {
                $DisplayVal = if ($SrcId.Length -gt 60) { $SrcId.Substring(0, 60) + "..." } else { $SrcId }
                $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="SourceResourceId"; Value=$DisplayVal; Error="Invalid ARM Resource ID format" }
            } else {
                $SrcParsed = Parse-ArmResourceId $SrcId
                $SrcRGScope = "/subscriptions/$($SrcParsed.SubscriptionId)/resourceGroups/$($SrcParsed.ResourceGroup)"
                $UniqueRGScopes[$SrcRGScope] = "source"

                $DestSubIdForScope = if ([string]::IsNullOrWhiteSpace($DestSubscriptionId)) { $SrcParsed.SubscriptionId } else { $DestSubscriptionId }
                $DestRGForScope = if ($Row.DestResourceGroupName) { $Row.DestResourceGroupName.Trim() } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($DestRGForScope)) {
                    $DestRGScope = "/subscriptions/$DestSubIdForScope/resourceGroups/$DestRGForScope"
                    $UniqueRGScopes[$DestRGScope] = "destination"
                }
            }
        }

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

        $DestRG = if ($Row.DestResourceGroupName) { $Row.DestResourceGroupName.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($DestRG)) {
            $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="DestResourceGroupName"; Value="(empty)"; Error="DestResourceGroupName is empty" }
        }

        if (-not [string]::IsNullOrWhiteSpace($SrcId) -and -not [string]::IsNullOrWhiteSpace($DestName)) {
            $PairKey = "$SrcId|$DestName".ToLower()
            if ($SeenPairs.ContainsKey($PairKey)) {
                $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="SourceResourceId+DestStorageAccountName"; Value="'$DestName'"; Error="Duplicate source-dest pair (first seen in row $($SeenPairs[$PairKey]))" }
            } else {
                $SeenPairs[$PairKey] = $CsvRowNum
            }

            if ($SrcId -match "storageAccounts/([^/]+)$") {
                $SrcAccountName = $Matches[1].ToLower()
                if ($SrcAccountName -eq $DestName) {
                    $ValidationErrors += [PSCustomObject]@{ Row=$CsvRowNum; Field="DestStorageAccountName"; Value="'$DestName'"; Error="Source and destination are the same account" }
                }
            }
        }
    }

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
    $CronExpression = if ($ScheduleIntervalHours -eq 24) { "0 0 * * *" } else { "0 */$ScheduleIntervalHours * * *" }

    if ($DryRun) {
        Write-Log "==================================================================" "DRYRUN"
        Write-Log "  DRY RUN MODE -- no changes will be made" "DRYRUN"
        Write-Log "==================================================================" "DRYRUN"
    }

    Write-Log "=================================================================="
    Write-Log "  VM                   : $(if ($VMName) { "$VMName (new)" } else { $VMResourceId })"
    Write-Log "  Resource Group       : $ResourceGroupName"
    Write-Log "  Location             : $Location"
    if ($ExistingVNetName) {
        Write-Log "  VNet (existing)      : $ExistingVNetName (RG: $ExistingVNetResourceGroup)"
        Write-Log "  Subnet               : $ExistingSubnetName"
    }
    Write-Log "  SyncMode             : $SyncMode"
    Write-Log "  Cron Schedule        : Every $ScheduleIntervalHours hour(s) ($CronExpression)"
    if ($SyncMode -eq "Mirror") {
        Write-Log "  WARNING              : Mirror mode will DELETE files on dest not in source" "WARN"
    }
    Write-Log "=================================================================="

    # ── Step 3: Create or verify VM ───────────────────────────────
    $VMPrincipalId = $null
    $VMCreatedByScript = $false

    if ($VMResourceId) {
        # ── Path A: Use existing VM ──
        # VMSubId, VMRGResolved, VMNameResolved already parsed in Step 1
        Write-Log "Setting up sync on existing VM '$VMNameResolved' (RG: $VMRGResolved)..."

        if (-not $DryRun) {
            # Verify VM exists and is Linux
            $VMCheck = Invoke-AzCommand -Arguments @(
                "vm", "show",
                "--name", $VMNameResolved,
                "--resource-group", $VMRGResolved,
                "--query", "storageProfile.osDisk.osType",
                "-o", "tsv"
            ) -IgnoreExitCode
            if ($VMCheck.ExitCode -ne 0) {
                throw "VM '$VMNameResolved' not found in resource group '$VMRGResolved'."
            }
            $DetectedOs = $VMCheck.StdOut.Trim()
            if ($DetectedOs -ne "Linux") {
                throw "VM '$VMNameResolved' is $DetectedOs. This script only supports Linux VMs."
            }
            Write-Log "  VM '$VMNameResolved' exists (Linux)." "SUCCESS"
        } else {
            Write-Log "  [DRYRUN] Would verify VM '$VMNameResolved' in '$VMRGResolved'" "DRYRUN"
        }
    } else {
        # ── Path B: Create new VM ──
        if ($VMName.Length -gt 64) {
            throw "VM name '$VMName' exceeds the maximum Azure VM resource name length of 64 characters."
        }
        $VMNameResolved = $VMName
        $VMRGResolved = $ResourceGroupName

        Write-Log "Creating VM '$VMNameResolved' (Linux, $VMSize)..."

        # Determine networking mode
        $UseExistingVNet = [bool]$ExistingVNetName

        if ($DryRun) {
            Write-Log "  [DRYRUN] Would create resource group '$ResourceGroupName' in '$Location' (if needed)" "DRYRUN"
            Write-Log "  [DRYRUN] Would create NSG '$VMNameResolved-nsg'" "DRYRUN"
            if ($UseExistingVNet) {
                Write-Log "  [DRYRUN] Would use existing VNET '$ExistingVNetName' (RG: $ExistingVNetResourceGroup), subnet '$ExistingSubnetName'" "DRYRUN"
            } else {
                Write-Log "  [DRYRUN] Would create VNET '$VMNameResolved-vnet'" "DRYRUN"
            }
            if (-not $SkipNatGateway -and -not $UseExistingVNet) {
                Write-Log "  [DRYRUN] Would create NAT Gateway '$VMNameResolved-natgw'" "DRYRUN"
            } elseif ($SkipNatGateway) {
                Write-Log "  [DRYRUN] NAT Gateway: Skipped (-SkipNatGateway)" "DRYRUN"
            } else {
                Write-Log "  [DRYRUN] NAT Gateway: Skipped (using existing VNet)" "DRYRUN"
            }
            Write-Log "  [DRYRUN] Would create NIC '$VMNameResolved-nic'" "DRYRUN"
            Write-Log "  [DRYRUN] Would create VM '$VMNameResolved' ($VMSize, Ubuntu 22.04)" "DRYRUN"
        } else {
            # Ensure resource group exists
            $RGCheck = Invoke-AzCommand -Arguments @("group", "show", "--name", $ResourceGroupName, "-o", "json") -IgnoreExitCode
            if ($RGCheck.ExitCode -ne 0) {
                Write-Log "  Creating resource group '$ResourceGroupName' in '$Location'..."
                $RGCreate = Invoke-AzCommand -Arguments @("group", "create", "--name", $ResourceGroupName, "--location", $Location, "-o", "none")
                if ($RGCreate.ExitCode -ne 0) {
                    throw "Failed to create resource group: $($RGCreate.ErrorDetail)"
                }
                Write-Log "  Resource group created." "SUCCESS"
            } else {
                Write-Log "  Resource group '$ResourceGroupName' already exists."
            }

            # Check if VM already exists (idempotent)
            $VMCheck = Invoke-AzCommand -Arguments @(
                "vm", "show",
                "--name", $VMNameResolved,
                "--resource-group", $ResourceGroupName,
                "-o", "json"
            ) -IgnoreExitCode

            if ($VMCheck.ExitCode -eq 0) {
                Write-Log "  VM '$VMNameResolved' already exists. Reusing." "SUCCESS"
            } else {
                $OsDiskName   = "$VMNameResolved-osdisk"
                $NicName      = "$VMNameResolved-nic"
                $NSGName      = "$VMNameResolved-nsg"
                $NatGwName    = "$VMNameResolved-natgw"
                $NatGwPipName = "$VMNameResolved-natgw-pip"

                # Determine VNet/Subnet names and resource group
                if ($UseExistingVNet) {
                    $VNetName     = $ExistingVNetName
                    $SubnetName   = $ExistingSubnetName
                    $VNetRG       = $ExistingVNetResourceGroup
                } else {
                    $VNetName     = "$VMNameResolved-vnet"
                    $SubnetName   = "default"
                    $VNetRG       = $ResourceGroupName
                }

                Write-Log "  Creating networking resources..."

                # NSG
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

                # VNET — create only if not using existing
                if ($UseExistingVNet) {
                    Write-Log "    Using existing VNET '$VNetName' (RG: $VNetRG), subnet '$SubnetName'"

                    # Verify the VNet and subnet exist
                    $SubnetCheck = Invoke-AzCommand -Arguments @(
                        "network", "vnet", "subnet", "show",
                        "--name", $SubnetName,
                        "--resource-group", $VNetRG,
                        "--vnet-name", $VNetName,
                        "-o", "json"
                    ) -IgnoreExitCode
                    if ($SubnetCheck.ExitCode -ne 0) {
                        throw "Subnet '$SubnetName' not found in VNet '$VNetName' (RG: $VNetRG). Verify the VNet and subnet names."
                    }
                    Write-Log "    VNet and subnet verified." "SUCCESS"
                } else {
                    Write-Log "    Creating VNET '$VNetName' with subnet '$SubnetName'..."
                    $VNetCreate = Invoke-AzCommand -Arguments @(
                        "network", "vnet", "create",
                        "--name", $VNetName,
                        "--resource-group", $VNetRG,
                        "--location", $Location,
                        "--subnet-name", $SubnetName,
                        "-o", "none"
                    ) -IgnoreExitCode
                    if ($VNetCreate.ExitCode -ne 0) {
                        Write-Log "    VNET may already exist, continuing..." "WARN"
                    }
                }

                # NAT Gateway — skip when using existing VNet (assumes network team manages outbound)
                if (-not $SkipNatGateway -and -not $UseExistingVNet) {
                    Write-Log "    Creating Public IP '$NatGwPipName' for NAT Gateway..."
                    Invoke-AzCommand -Arguments @(
                        "network", "public-ip", "create",
                        "--name", $NatGwPipName,
                        "--resource-group", $ResourceGroupName,
                        "--location", $Location,
                        "--sku", "Standard",
                        "--allocation-method", "Static",
                        "-o", "none"
                    ) -IgnoreExitCode | Out-Null

                    Write-Log "    Creating NAT Gateway '$NatGwName'..."
                    Invoke-AzCommand -Arguments @(
                        "network", "nat", "gateway", "create",
                        "--name", $NatGwName,
                        "--resource-group", $ResourceGroupName,
                        "--location", $Location,
                        "--public-ip-addresses", $NatGwPipName,
                        "--idle-timeout", "4",
                        "-o", "none"
                    ) -IgnoreExitCode | Out-Null

                    Write-Log "    Associating NAT Gateway with subnet '$SubnetName'..."
                    $NatAssoc = Invoke-AzCommand -Arguments @(
                        "network", "vnet", "subnet", "update",
                        "--name", $SubnetName,
                        "--resource-group", $VNetRG,
                        "--vnet-name", $VNetName,
                        "--nat-gateway", $NatGwName,
                        "-o", "none"
                    ) -IgnoreExitCode
                    if ($NatAssoc.ExitCode -ne 0) {
                        Write-Log "    WARNING: Failed to associate NAT Gateway with subnet. VM may lack outbound internet." "WARN"
                    }
                } elseif ($UseExistingVNet) {
                    Write-Log "    NAT Gateway: Skipped (using existing VNet — outbound access assumed to be managed externally)."
                } else {
                    Write-Log "    Skipping NAT Gateway (-SkipNatGateway). Ensure the VM has outbound internet access." "WARN"
                }

                # NIC — reference VNet from correct RG (may differ from VM RG in Hub-Spoke)
                Write-Log "    Creating NIC '$NicName'..."
                $NicSubnetId = "/subscriptions/$($CurrentAccount.id)/resourceGroups/$VNetRG/providers/Microsoft.Network/virtualNetworks/$VNetName/subnets/$SubnetName"
                $NicArgs = @(
                    "network", "nic", "create",
                    "--name", $NicName,
                    "--resource-group", $ResourceGroupName,
                    "--location", $Location,
                    "--subnet", $NicSubnetId,
                    "--network-security-group", $NSGName,
                    "-o", "none"
                )
                Invoke-AzCommand -Arguments $NicArgs -IgnoreExitCode | Out-Null

                # VM
                Write-Log "  Creating VM '$VMNameResolved' (Ubuntu 22.04, $VMSize)..."
                $VMCreateResult = Invoke-AzCommand -Arguments @(
                    "vm", "create",
                    "--name", $VMNameResolved,
                    "--resource-group", $ResourceGroupName,
                    "--location", $Location,
                    "--image", "Ubuntu2204",
                    "--size", $VMSize,
                    "--assign-identity",
                    "--admin-username", "azadmin",
                    "--public-ip-address", "",
                    "--os-disk-name", $OsDiskName,
                    "--nics", $NicName,
                    "--generate-ssh-keys",
                    "--authentication-type", "ssh",
                    "-o", "json"
                )
                if ($VMCreateResult.ExitCode -ne 0) {
                    throw "Failed to create VM '$VMNameResolved': $($VMCreateResult.ErrorDetail)"
                }
                Write-Log "  VM '$VMNameResolved' created." "SUCCESS"
                $VMCreatedByScript = $true

                # Wait for guest agent
                Write-Log "  Waiting for VM guest agent to become ready..."
                $AgentReady = $false
                $AgentWaitMax = 120
                $AgentWaitElapsed = 0
                while ($AgentWaitElapsed -lt $AgentWaitMax) {
                    Start-Sleep -Seconds 15
                    $AgentWaitElapsed += 15
                    $AgentCheck = Invoke-AzCommand -Arguments @(
                        "vm", "get-instance-view",
                        "--name", $VMNameResolved,
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
        }
    }

    # ── Step 4: Enable Managed Identity ───────────────────────────
    Write-Log "Enabling System-Assigned Managed Identity on VM..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would enable Managed Identity on VM '$VMNameResolved'" "DRYRUN"
    } else {
        $VMUpdate = Invoke-AzCommand -Arguments @(
            "vm", "identity", "assign",
            "--name", $VMNameResolved,
            "--resource-group", $VMRGResolved,
            "-o", "json"
        )
        if ($VMUpdate.ExitCode -ne 0) {
            throw "Failed to enable Managed Identity on VM: $($VMUpdate.ErrorDetail)"
        }
        $VMIdentity = $VMUpdate.StdOut | ConvertFrom-Json
        $VMPrincipalId = $VMIdentity.systemAssignedIdentity
        Write-Log "  Managed Identity enabled. Principal ID: $VMPrincipalId" "SUCCESS"
    }

    # ── Step 5: Install prerequisites ─────────────────────────────
    Write-Log "Checking and installing prerequisites on VM '$VMNameResolved'..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would check and install az cli, azcopy, pwsh on VM" "DRYRUN"
    } else {
        Install-VMPrerequisites -VMNameParam $VMNameResolved -VMResourceGroup $VMRGResolved
    }

    # ── Step 6: Assign RBAC ───────────────────────────────────────
    Write-Log "Assigning RBAC 'Storage Account Contributor' to $($UniqueRGScopes.Count) resource group scope(s)..."

    $RoleName = "Storage Account Contributor"
    $RBACAssigned = 0
    $RBACSkipped = 0

    if (-not $DryRun -and $VMPrincipalId) {
        # Fetch all existing role assignments for the VM MI in one call
        Write-Log "  Checking existing RBAC for VM MI..."
        $ExistingRoles = Invoke-AzCommand -Arguments @(
            "role", "assignment", "list",
            "--assignee", $VMPrincipalId,
            "--role", $RoleName,
            "--query", "[].scope",
            "-o", "json"
        ) -IgnoreExitCode

        $ExistingScopes = @{}
        if ($ExistingRoles.StdOut) {
            $ScopeList = $ExistingRoles.StdOut | ConvertFrom-Json
            foreach ($S in $ScopeList) {
                $ExistingScopes[$S.ToLower()] = $true
            }
        }
        Write-Log "  Found $($ExistingScopes.Count) existing '$RoleName' assignment(s) for VM MI."
    }

    foreach ($Scope in $UniqueRGScopes.Keys) {
        $ScopeType = $UniqueRGScopes[$Scope]
        if ($DryRun) {
            Write-Log "  [DRYRUN] Would assign '$RoleName' to VM MI at $ScopeType scope: $Scope" "DRYRUN"
        } elseif ($VMPrincipalId) {
            if ($ExistingScopes.ContainsKey($Scope.ToLower())) {
                $RBACSkipped++
            } else {
                Write-Log "  Assigning '$RoleName' at $ScopeType scope: $Scope..."
                Invoke-AzCommand -Arguments @(
                    "role", "assignment", "create",
                    "--assignee-object-id", $VMPrincipalId,
                    "--assignee-principal-type", "ServicePrincipal",
                    "--role", $RoleName,
                    "--scope", $Scope,
                    "-o", "none"
                ) -IgnoreExitCode | Out-Null
                $RBACAssigned++
            }
        }
    }

    if (-not $DryRun) {
        Write-Log "  RBAC: $RBACAssigned new assignment(s), $RBACSkipped already existed (skipped)." "SUCCESS"
    }

    # ── Step 7: Copy files to VM ──────────────────────────────────
    Write-Log "Copying files to VM..."

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would copy Sync-DRFileShares.ps1 to /opt/dr-sync/" "DRYRUN"
        Write-Log "  [DRYRUN] Would copy CSV to /opt/dr-sync/resources.csv" "DRYRUN"
    } else {
        Write-Log "  Copying Sync-DRFileShares.ps1 to VM..."
        Copy-FileToVM -VMNameParam $VMNameResolved -VMResourceGroup $VMRGResolved `
            -LocalPath $RunbookPath -RemotePath "/opt/dr-sync/Sync-DRFileShares.ps1"
        Write-Log "  Sync script copied." "SUCCESS"

        Write-Log "  Copying CSV mapping file to VM..."
        Copy-FileToVM -VMNameParam $VMNameResolved -VMResourceGroup $VMRGResolved `
            -LocalPath $CsvFullPath -RemotePath "/opt/dr-sync/resources.csv"
        Write-Log "  CSV copied." "SUCCESS"
    }

    # ── Step 8: Create config and wrapper script ──────────────────
    Write-Log "Creating config and wrapper script on VM..."

    # Build config values
    $ConfigSyncMode = $SyncMode
    $ConfigPreserveSmb = if ($PreserveSmbPermissions) { "true" } else { "false" }
    $ConfigExclude = if ($ExcludePattern) { $ExcludePattern } else { "" }
    $ConfigDestSub = if ($DestSubscriptionId) { $DestSubscriptionId } else { "" }

    $ConfigAndWrapperScript = @"
#!/bin/bash
set -e

# Create config.env
cat > /opt/dr-sync/config.env << 'CONFIGEOF'
SYNC_MODE="$ConfigSyncMode"
PRESERVE_SMB_PERMISSIONS="$ConfigPreserveSmb"
EXCLUDE_PATTERN="$ConfigExclude"
DEST_SUBSCRIPTION_ID="$ConfigDestSub"
CSV_PATH="/opt/dr-sync/resources.csv"
SCRIPT_PATH="/opt/dr-sync/Sync-DRFileShares.ps1"
LOG_DIR="/var/log/dr-sync"
CONFIGEOF

# Create wrapper script
cat > /opt/dr-sync/run-sync.sh << 'WRAPPEREOF'
#!/bin/bash
# DR File Share Sync Wrapper
# Managed by Setup-SyncVM.ps1 -- do not edit manually.

set -uo pipefail

# Load config
source /opt/dr-sync/config.env

# Setup logging
mkdir -p "`$LOG_DIR"
TIMESTAMP=`$(date +%Y%m%d-%H%M%S)
LOGFILE="`$LOG_DIR/sync-`$TIMESTAMP.log"

exec > >(tee -a "`$LOGFILE") 2>&1

echo "=== DR File Share Sync started at `$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# Authenticate with Managed Identity
echo "Logging in with Managed Identity..."
if ! az login --identity --output none 2>&1; then
    echo "ERROR: az login --identity failed"
    exit 1
fi

# Build pwsh arguments
PWSH_ARGS="-CsvPath `$CSV_PATH -SyncMode `$SYNC_MODE"

if [ "`$DEST_SUBSCRIPTION_ID" != "" ]; then
    PWSH_ARGS="`$PWSH_ARGS -DestSubscriptionId `$DEST_SUBSCRIPTION_ID"
fi

if [ "`$PRESERVE_SMB_PERMISSIONS" = "true" ]; then
    PWSH_ARGS="`$PWSH_ARGS -PreserveSmbPermissions"
fi

if [ "`$EXCLUDE_PATTERN" != "" ]; then
    PWSH_ARGS="`$PWSH_ARGS -ExcludePattern '`$EXCLUDE_PATTERN'"
fi

# Run the sync
echo "Running: pwsh `$SCRIPT_PATH `$PWSH_ARGS"
eval pwsh "`$SCRIPT_PATH" `$PWSH_ARGS
EXIT_CODE=`$?

echo "=== DR File Share Sync finished at `$(date -u +%Y-%m-%dT%H:%M:%SZ) with exit code `$EXIT_CODE ==="

# Update latest symlink
ln -sf "`$LOGFILE" "`$LOG_DIR/latest.log"

exit `$EXIT_CODE
WRAPPEREOF

chmod +x /opt/dr-sync/run-sync.sh

# Create log directory
mkdir -p /var/log/dr-sync

echo "CONFIG_AND_WRAPPER_CREATED"
"@

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would create /opt/dr-sync/config.env" "DRYRUN"
        Write-Log "  [DRYRUN] Would create /opt/dr-sync/run-sync.sh" "DRYRUN"
    } else {
        $WrapperResult = Invoke-VMRunCommand -VMNameParam $VMNameResolved -VMResourceGroup $VMRGResolved -Script $ConfigAndWrapperScript
        if ($WrapperResult.Success -and $WrapperResult.StdOut -match "CONFIG_AND_WRAPPER_CREATED") {
            Write-Log "  Config and wrapper script created." "SUCCESS"
        } else {
            Write-Log "  WARNING: Wrapper script creation may have failed. Check the VM manually." "WARN"
            if ($WrapperResult.StdErr) {
                Write-Log "    StdErr: $($WrapperResult.StdErr)" "WARN"
            }
        }
    }

    # ── Step 9: Setup cron job ────────────────────────────────────
    Write-Log "Setting up cron job (every $ScheduleIntervalHours hour(s))..."

    $CronScript = @"
#!/bin/bash
set -e

# Create cron job
cat > /etc/cron.d/dr-sync << 'CRONEOF'
# DR File Share Sync -- managed by Setup-SyncVM.ps1
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

$CronExpression root /opt/dr-sync/run-sync.sh >> /var/log/dr-sync/cron.log 2>&1
CRONEOF

chmod 644 /etc/cron.d/dr-sync

# Verify cron service
if systemctl is-active cron >/dev/null 2>&1; then
    echo "CRON_ACTIVE"
elif systemctl is-active crond >/dev/null 2>&1; then
    echo "CRON_ACTIVE"
else
    echo "CRON_INACTIVE"
fi
"@

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would create /etc/cron.d/dr-sync ($CronExpression)" "DRYRUN"
    } else {
        $CronResult = Invoke-VMRunCommand -VMNameParam $VMNameResolved -VMResourceGroup $VMRGResolved -Script $CronScript
        if ($CronResult.Success) {
            if ($CronResult.StdOut -match "CRON_ACTIVE") {
                Write-Log "  Cron job created and cron service is active." "SUCCESS"
            } else {
                Write-Log "  Cron job created but cron service may not be running." "WARN"
                Write-Log "  Run 'systemctl start cron' on the VM if needed." "WARN"
            }
        } else {
            Write-Log "  WARNING: Cron job creation may have failed: $($CronResult.ErrorDetail)" "WARN"
        }
    }

    # ── Step 10: Setup log rotation ───────────────────────────────
    Write-Log "Setting up log rotation..."

    $LogrotateScript = @'
#!/bin/bash
cat > /etc/logrotate.d/dr-sync << 'LREOF'
/var/log/dr-sync/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
LREOF
echo "LOGROTATE_CREATED"
'@

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would create /etc/logrotate.d/dr-sync (14 days retention)" "DRYRUN"
    } else {
        $LRResult = Invoke-VMRunCommand -VMNameParam $VMNameResolved -VMResourceGroup $VMRGResolved -Script $LogrotateScript
        if ($LRResult.Success -and $LRResult.StdOut -match "LOGROTATE_CREATED") {
            Write-Log "  Log rotation configured (14 days, compressed)." "SUCCESS"
        } else {
            Write-Log "  WARNING: Log rotation setup may have failed." "WARN"
        }
    }

    # ── Step 11: Summary ──────────────────────────────────────────
    $TotalElapsed = (Get-Date) - $ScriptStartTime
    $TotalDuration = Format-Duration $TotalElapsed

    Write-Log "=================================================================="
    Write-Log "  SUMMARY                                          ($TotalDuration)"
    Write-Log "=================================================================="
    Write-Log "  VM                       : $VMNameResolved$(if ($VMCreatedByScript) { ' (newly created)' })"
    Write-Log "  VM Resource Group        : $VMRGResolved"
    Write-Log "  VM Size                  : $VMSize"
    Write-Log "  VM MI Principal ID       : $(if ($VMPrincipalId) { $VMPrincipalId } else { '(dry-run)' })"
    Write-Log "  Location                 : $Location"
    if ($ExistingVNetName) {
        Write-Log "  VNet (existing)          : $ExistingVNetName (RG: $ExistingVNetResourceGroup)"
        Write-Log "  Subnet                   : $ExistingSubnetName"
    }
    Write-Log "  RBAC scopes              : $($UniqueRGScopes.Count) resource group(s)"
    Write-Log "  SyncMode                 : $SyncMode"
    Write-Log "  Cron Schedule            : Every ${ScheduleIntervalHours}h ($CronExpression)"
    Write-Log "  CSV rows                 : $TotalRows"
    Write-Log "  Files deployed to        : /opt/dr-sync/"
    Write-Log "  Logs at                  : /var/log/dr-sync/"
    Write-Log "  Total elapsed time       : $TotalDuration"
    Write-Log "=================================================================="

    if (-not $DryRun) {
        Write-Log ""
        Write-Log "  NOTE: RBAC role assignments may take 5-10 minutes to propagate." "WARN"
        Write-Log "  The first cron run may fail with permission errors. Check" "WARN"
        Write-Log "  /var/log/dr-sync/latest.log on the VM after the first run." "WARN"
        Write-Log ""
        Write-Log "  To trigger a manual sync now:" "SUCCESS"
        Write-Log "    az vm run-command invoke --name $VMNameResolved --resource-group $VMRGResolved \" "SUCCESS"
        Write-Log "      --command-id RunShellScript --scripts '/opt/dr-sync/run-sync.sh'" "SUCCESS"
    }

    Write-Log "=================================================================="

} catch {
    Write-Log "FATAL SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
