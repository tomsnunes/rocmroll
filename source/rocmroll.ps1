#Requires -Version 5.1
<#
.SYNOPSIS
    rocmroll.ps1 - Main CLI entrypoint for ComfyUI ROCmRoll.

.DESCRIPTION
    Dispatches subcommands to PowerShell modules.
    All business logic lives in source\modules\*.psm1.

.EXAMPLE
    .\rocmroll.ps1 install --instance rocm-stable --channel stable
    .\rocmroll.ps1 launch --instance rocm-stable
    .\rocmroll.ps1 doctor --instance rocm-stable
    .\rocmroll.ps1 cache list
#>

param(
    [Parameter(Position=0)]
    [string]$Command = 'help',

    [Parameter(Position=1, ValueFromRemainingArguments)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure UTF-8 output so non-ASCII chars reach the console correctly
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$ScriptRoot  = $PSScriptRoot
$RootFolder  = Split-Path $ScriptRoot -Parent
$ModulesDir  = Join-Path $ScriptRoot 'modules'

function Import-AllModules {
    $order = @(
        'RocmRoll.Logging',
        'RocmRoll.Config',
        'RocmRoll.State',
        'RocmRoll.Locking',
        'RocmRoll.Download',
        'RocmRoll.Cache',
        'RocmRoll.Hardware',
        'RocmRoll.Runtime',
        'RocmRoll.Environment',
        'RocmRoll.Rocm',
        'RocmRoll.ComfyUI',
        'RocmRoll.CustomNodes',
        'RocmRoll.Packages',
        'RocmRoll.Launcher',
        'RocmRoll.Profiles',
        'RocmRoll.Validation',
        'RocmRoll.Repair',
        'RocmRoll.Doctor',
        'RocmRoll.UI',
        'RocmRoll.ComfyDesktop',
        'RocmRoll.Core'
    )
    foreach ($m in $order) {
        $path = Join-Path $ModulesDir "$m.psm1"
        if (Test-Path $path) {
            Import-Module $path -Force -Global
        } else {
            Write-Warning "Module not found: $path"
        }
    }
}

# ---------------------------------------------------------------------------
# Parse common flags from remaining args
# ---------------------------------------------------------------------------
function Get-Flag {
    param([string[]]$ArgList, [string]$Name)
    return ($ArgList -contains "--$Name") -or ($ArgList -contains "-$Name")
}

function Get-FlagValue {
    param([string[]]$ArgList, [string]$Name)
    for ($i = 0; $i -lt $ArgList.Count - 1; $i++) {
        if ($ArgList[$i] -in @("--$Name", "-$Name")) { return $ArgList[$i+1] }
    }
    return $null
}

function Test-PathInsideFolder {
    param(
        [string]$Path,
        [string]$ParentFolder
    )

    if (-not $Path -or -not $ParentFolder) { return $false }

    $resolvedParent = [System.IO.Path]::GetFullPath($ParentFolder).TrimEnd('\')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $resolvedPath.StartsWith("$resolvedParent\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-QuietNativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Remove-FolderTree {
    param(
        [string]$Path,
        [string]$ParentFolder,
        [string]$Description
    )

    if (-not (Test-Path $Path)) { return }

    if (-not (Test-PathInsideFolder -Path $Path -ParentFolder $ParentFolder)) {
        throw "ROCMROLL-REMOVE-001: Refusing to remove $Description path outside expected folder: $Path"
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        Write-LogWarn "Normal removal failed for $Description. Retrying after ACL reset." -Comp 'RocmRoll'
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Invoke-QuietNativeCommand -FilePath 'icacls.exe' -Arguments @($Path, '/grant', "${currentUser}:(OI)(CI)F", '/T', '/C') | Out-Null

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        Invoke-QuietNativeCommand -FilePath 'takeown.exe' -Arguments @('/F', $Path, '/R', '/D', 'Y') | Out-Null
        Invoke-QuietNativeCommand -FilePath 'icacls.exe' -Arguments @($Path, '/grant', "${currentUser}:(OI)(CI)F", '/T', '/C') | Out-Null
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        throw "ROCMROLL-REMOVE-003: Failed to remove $Description path '$Path'. Run the remove command from an elevated PowerShell session and try again. Last error: $($_.Exception.Message)"
    }
}

$InstanceName   = Get-FlagValue -ArgList $RemainingArgs -Name 'instance'
$Channel        = Get-FlagValue -ArgList $RemainingArgs -Name 'channel'
$PythonVersion  = Get-FlagValue -ArgList $RemainingArgs -Name 'python'
$GfxOverride    = Get-FlagValue -ArgList $RemainingArgs -Name 'gfx'
$Component      = Get-FlagValue -ArgList $RemainingArgs -Name 'component'
$RollbackPatch  = Get-FlagValue -ArgList $RemainingArgs -Name 'rollback-patch'
$LogLevel       = Get-FlagValue -ArgList $RemainingArgs -Name 'log-level'
$LogFile        = Get-FlagValue -ArgList $RemainingArgs -Name 'log-file'
$EnvName        = Get-FlagValue -ArgList $RemainingArgs -Name 'env'
$OlderThanDays  = Get-FlagValue -ArgList $RemainingArgs -Name 'older-than-days'
$PortArg        = Get-FlagValue -ArgList $RemainingArgs -Name 'port'
$ProfileName    = Get-FlagValue -ArgList $RemainingArgs -Name 'profile'

$FlagForce      = Get-Flag -ArgList $RemainingArgs -Name 'force'
$FlagQuiet      = Get-Flag -ArgList $RemainingArgs -Name 'quiet'
$FlagVerbose    = Get-Flag -ArgList $RemainingArgs -Name 'verbose'
$FlagDebug      = Get-Flag -ArgList $RemainingArgs -Name 'debug'
$FlagJson       = Get-Flag -ArgList $RemainingArgs -Name 'json'
$FlagNoColor    = Get-Flag -ArgList $RemainingArgs -Name 'no-color'
$FlagGpuOnly    = Get-Flag -ArgList $RemainingArgs -Name 'gpu'
$FlagCacheOnly  = Get-Flag -ArgList $RemainingArgs -Name 'cache'
$FlagSystemOnly = Get-Flag -ArgList $RemainingArgs -Name 'system'
$FlagHelp            = Get-Flag -ArgList $RemainingArgs -Name 'help'
$FlagSharedWorkflows = Get-Flag -ArgList $RemainingArgs -Name 'shared-workflows'
$Url                 = Get-FlagValue -ArgList $RemainingArgs -Name 'url'

# Defaults
if (-not $Channel)       { $Channel       = 'stable' }
if (-not $PythonVersion) { $PythonVersion = '3.12.10' }
if (-not $LogLevel)      { $LogLevel      = if ($FlagDebug) { 'DEBUG' } elseif ($FlagVerbose) { 'DEBUG' } else { 'INFO' } }

# Init config first (minimal before module import)
Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1') -Force -Global
Initialize-Config -RootFolder $RootFolder | Out-Null

Import-Module (Join-Path $ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
$logInitArgs = @{ Level=$LogLevel; NoColor=$FlagNoColor; Quiet=$FlagQuiet; JsonOnly=$FlagJson }
if ($LogFile) { $logInitArgs['LogFile'] = $LogFile }
Initialize-Logging @logInitArgs

# ---------------------------------------------------------------------------
# CLI help system
# ---------------------------------------------------------------------------

function Show-AsciiArt {
    $art = @'

 /$$$$$$$   /$$$$$$   /$$$$$$                /$$$$$$$            /$$ /$$
| $$__  $$ /$$__  $$ /$$__  $$              | $$__  $$          | $$| $$
| $$  \ $$| $$  \ $$| $$  \__/ /$$$$$$/$$$$ | $$  \ $$  /$$$$$$ | $$| $$
| $$$$$$$/| $$  | $$| $$      | $$_  $$_  $$| $$$$$$$/ /$$__  $$| $$| $$
| $$__  $$| $$  | $$| $$      | $$ \ $$ \ $$| $$__  $$| $$  \ $$| $$| $$
| $$  \ $$| $$  | $$| $$    $$| $$ | $$ | $$| $$  \ $$| $$  | $$| $$| $$
| $$  | $$|  $$$$$$/|  $$$$$$/| $$ | $$ | $$| $$  | $$|  $$$$$$/| $$| $$
|__/  |__/ \______/  \______/ |__/ |__/ |__/|__/  |__/ \______/ |__/|__/
                                                                        
'@
    Write-Host $art -ForegroundColor Red
    Write-Host '            Optimized ComfyUI for AMD GPUs using ROCm on Windows' -ForegroundColor DarkRed
    Write-Host ''
}

$script:CommandDefs = [ordered]@{
    'install' = @{
        Synopsis = 'Install Python runtime, ROCm/PyTorch, ComfyUI, and custom nodes'
        Usage    = 'rocmroll install --instance NAME [options]'
        Params   = @(
            [ordered]@{ Flag = '--instance  NAME';           Required = $true;  Default = '';        Desc = 'Instance name to create' }
            [ordered]@{ Flag = '--channel   stable|nightly'; Required = $false; Default = 'stable';  Desc = 'Update channel' }
            [ordered]@{ Flag = '--python    VERSION';        Required = $false; Default = '3.12.10'; Desc = 'Python version' }
            [ordered]@{ Flag = '--gfx       ARCH';           Required = $false; Default = '';        Desc = 'Override GPU architecture (e.g. gfx1201, gfx120X)' }
            [ordered]@{ Flag = '--profile   NAME';           Required = $false; Default = '';        Desc = 'Execution profile to bake into the launcher' }
            [ordered]@{ Flag = '--force';                    Required = $false; Default = '';        Desc = 'Force reinstall even if already ready' }
            [ordered]@{ Flag = '--shared-workflows';         Required = $false; Default = '';        Desc = 'Symlink instance workflows to shared/workflows' }
        )
        Examples = @(
            'rocmroll install --instance rocm-stable'
            'rocmroll install --instance rocm-nightly --channel nightly'
            'rocmroll install --instance my-rig --gfx gfx1201 --force'
            'rocmroll install --instance rocm-stable --shared-workflows'
        )
    }
    'launch' = @{
        Synopsis = 'Launch a ComfyUI instance (interactive selector when --instance is omitted)'
        Usage    = 'rocmroll launch [--instance NAME] [--port PORT]'
        Params   = @(
            [ordered]@{ Flag = '--instance  NAME'; Required = $false; Default = '';     Desc = 'Instance name (omit to select interactively)' }
            [ordered]@{ Flag = '--port      PORT';   Required = $false; Default = '8188'; Desc = 'Listen port' }
            [ordered]@{ Flag = '--profile   NAME';  Required = $false; Default = '';     Desc = 'Override execution profile at runtime' }
        )
        Examples = @(
            'rocmroll launch'
            'rocmroll launch --instance rocm-stable'
            'rocmroll launch --instance rocm-stable --port 8189'
        )
    }
    'update' = @{
        Synopsis = 'Update an existing instance to the latest state'
        Usage    = 'rocmroll update --instance NAME [options]'
        Params   = @(
            [ordered]@{ Flag = '--instance  NAME';           Required = $true;  Default = '';       Desc = 'Instance to update' }
            [ordered]@{ Flag = '--channel   stable|nightly'; Required = $false; Default = 'stable'; Desc = 'Switch update channel' }
            [ordered]@{ Flag = '--gfx       ARCH';           Required = $false; Default = '';       Desc = 'Override GPU architecture' }
        )
        Examples = @(
            'rocmroll update --instance rocm-stable'
            'rocmroll update --instance rocm-stable --channel nightly'
        )
    }
    'doctor' = @{
        Synopsis = 'Run diagnostics and health checks'
        Usage    = 'rocmroll doctor [--instance NAME] [options]'
        Params   = @(
            [ordered]@{ Flag = '--instance  NAME'; Required = $false; Default = ''; Desc = 'Scope checks to a specific instance' }
            [ordered]@{ Flag = '--gpu';             Required = $false; Default = ''; Desc = 'GPU detection and ROCm checks only' }
            [ordered]@{ Flag = '--cache';           Required = $false; Default = ''; Desc = 'Cache integrity checks only' }
            [ordered]@{ Flag = '--system';          Required = $false; Default = ''; Desc = 'System-level checks only' }
            [ordered]@{ Flag = '--json';            Required = $false; Default = ''; Desc = 'Output results as structured JSON' }
        )
        Examples = @(
            'rocmroll doctor'
            'rocmroll doctor --instance rocm-stable'
            'rocmroll doctor --gpu'
            'rocmroll doctor --instance rocm-stable --json'
        )
    }
    'repair' = @{
        Synopsis = 'Repair a specific component of an instance'
        Usage    = 'rocmroll repair --instance NAME [--component SCOPE]'
        Params   = @(
            [ordered]@{ Flag = '--instance   NAME';  Required = $true;  Default = '';    Desc = 'Instance to repair' }
            [ordered]@{ Flag = '--component  SCOPE'; Required = $false; Default = 'all'; Desc = 'python-runtime | python-env | rocm | comfyui | custom-nodes | launchers | patches | all' }
            [ordered]@{ Flag = '--profile    NAME';  Required = $false; Default = '';    Desc = 'Profile to apply when repairing launchers' }
            [ordered]@{ Flag = '--shared-workflows'; Required = $false; Default = '';    Desc = 'Re-create shared workflows symlink during comfyui/all repair' }
        )
        Examples = @(
            'rocmroll repair --instance rocm-stable'
            'rocmroll repair --instance rocm-stable --component rocm'
            'rocmroll repair --instance rocm-stable --component launchers'
            'rocmroll repair --instance rocm-stable --component python-env'
            'rocmroll repair --instance rocm-stable --component comfyui --shared-workflows'
        )
    }
    'list' = @{
        Synopsis = 'List all installed ComfyUI instances'
        Usage    = 'rocmroll list'
        Params   = @()
        Examples = @('rocmroll list')
    }
    'remove' = @{
        Synopsis = 'Remove an instance and its Python environment'
        Usage    = 'rocmroll remove --instance NAME [--force]'
        Params   = @(
            [ordered]@{ Flag = '--instance  NAME'; Required = $true;  Default = ''; Desc = 'Instance to remove' }
            [ordered]@{ Flag = '--force';          Required = $false; Default = ''; Desc = 'Skip the confirmation prompt' }
        )
        Examples = @(
            'rocmroll remove --instance rocm-stable'
            'rocmroll remove --instance rocm-stable --force'
        )
    }
    'cache' = @{
        Synopsis = 'Inspect or clean the download and wheel cache'
        Usage    = 'rocmroll cache <list|verify|clean|prune> [options]'
        Params   = @(
            [ordered]@{ Flag = 'list';                       Required = $false; Default = ''; Desc = 'Show cache sizes and file counts' }
            [ordered]@{ Flag = 'verify';                     Required = $false; Default = ''; Desc = 'Verify cached file integrity' }
            [ordered]@{ Flag = 'clean --temp';               Required = $false; Default = ''; Desc = 'Remove temp extraction folder' }
            [ordered]@{ Flag = 'clean --all';                Required = $false; Default = ''; Desc = 'Clear all caches (downloads, wheelhouse, git, triton, temp)' }
            [ordered]@{ Flag = 'prune --older-than-days N';  Required = $false; Default = ''; Desc = 'Remove download cache entries older than N days (0 = all)' }
        )
        Examples = @(
            'rocmroll cache list'
            'rocmroll cache verify'
            'rocmroll cache clean --temp'
            'rocmroll cache clean --all'
            'rocmroll cache prune --older-than-days 30'
        )
    }
    'init' = @{
        Synopsis = 'Initialize the ROCmRoll folder structure'
        Usage    = 'rocmroll init'
        Params   = @()
        Examples = @('rocmroll init')
    }
    'rocm' = @{
        Synopsis = 'Show ROCm and PyTorch information for an instance'
        Usage    = 'rocmroll rocm <info|validate> --instance NAME'
        Params   = @(
            [ordered]@{ Flag = 'info      --instance NAME'; Required = $false; Default = ''; Desc = 'Show installed ROCm/PyTorch packages and GPU information' }
            [ordered]@{ Flag = 'validate  --instance NAME'; Required = $false; Default = ''; Desc = 'Run the ROCm/PyTorch validation script' }
            [ordered]@{ Flag = '--instance NAME';           Required = $true;  Default = ''; Desc = 'Target instance' }
        )
        Examples = @(
            'rocmroll rocm info     --instance rocm-stable'
            'rocmroll rocm validate --instance rocm-stable'
        )
    }
    'comfy' = @{
        Synopsis = 'Show ComfyUI information and manage ComfyUI components for an instance'
        Usage    = 'rocmroll comfy <info|requirements|nodes|update-nodes|add-node|node-requirements> --instance NAME [options]'
        Params   = @(
            [ordered]@{ Flag = 'info              --instance NAME';  Required = $false; Default = ''; Desc = 'Show ComfyUI version, commit, status, and custom node list' }
            [ordered]@{ Flag = 'requirements      --instance NAME';  Required = $false; Default = ''; Desc = 'Reinstall ComfyUI requirements.txt' }
            [ordered]@{ Flag = 'nodes             --instance NAME';  Required = $false; Default = ''; Desc = 'List installed custom nodes' }
            [ordered]@{ Flag = 'update-nodes      --instance NAME';  Required = $false; Default = ''; Desc = 'Pull latest commits for all custom nodes' }
            [ordered]@{ Flag = 'add-node --url URL --instance NAME'; Required = $false; Default = ''; Desc = 'Install a custom node from a git repository URL' }
            [ordered]@{ Flag = 'node-requirements --instance NAME';  Required = $false; Default = ''; Desc = 'Reinstall requirements.txt for all custom nodes' }
            [ordered]@{ Flag = '--instance NAME';                    Required = $true;  Default = ''; Desc = 'Target instance' }
            [ordered]@{ Flag = '--url      URL';                     Required = $false; Default = ''; Desc = 'Git repository URL (add-node only)' }
        )
        Examples = @(
            'rocmroll comfy info              --instance rocm-stable'
            'rocmroll comfy requirements      --instance rocm-stable'
            'rocmroll comfy nodes             --instance rocm-stable'
            'rocmroll comfy update-nodes      --instance rocm-stable'
            'rocmroll comfy add-node          --url https://github.com/author/my-node --instance rocm-stable'
            'rocmroll comfy node-requirements --instance rocm-stable'
        )
    }
    'logs' = @{
        Synopsis = 'Show recent log files'
        Usage    = 'rocmroll logs [--instance NAME]'
        Params   = @(
            [ordered]@{ Flag = '--instance  NAME'; Required = $false; Default = ''; Desc = 'Filter by instance' }
        )
        Examples = @('rocmroll logs', 'rocmroll logs --instance rocm-stable')
    }
    'profile' = @{
        Synopsis = 'Manage execution profiles'
        Usage    = 'rocmroll profile <list|show|create|remove> [options]'
        Params   = @(
            [ordered]@{ Flag = 'list';                    Required = $false; Default = ''; Desc = 'List all available profiles' }
            [ordered]@{ Flag = 'show   --profile NAME';   Required = $false; Default = ''; Desc = 'Print full detail for a profile' }
            [ordered]@{ Flag = 'create --profile NAME';   Required = $false; Default = ''; Desc = 'Launch interactive wizard to create a profile' }
            [ordered]@{ Flag = 'remove --profile NAME';   Required = $false; Default = ''; Desc = 'Delete a profile (--force skips confirmation)' }
        )
        Examples = @(
            'rocmroll profile list'
            'rocmroll profile show --profile optimized'
            'rocmroll profile create --profile my-profile'
            'rocmroll profile remove --profile my-profile'
            'rocmroll install --instance rocm-stable --profile stable-dynamic-vram'
            'rocmroll launch  --instance rocm-stable --profile performance-autotune'
            'rocmroll repair  --instance rocm-stable --component launchers --profile optimized'
        )
    }
    'config' = @{
        Synopsis = 'Show or initialise the ROCmRoll configuration file (rocmroll.ini)'
        Usage    = 'rocmroll config <show|init>'
        Params   = @(
            [ordered]@{ Flag = 'show'; Required = $false; Default = ''; Desc = 'Print resolved paths and config file location (default)' }
            [ordered]@{ Flag = 'init'; Required = $false; Default = ''; Desc = 'Create rocmroll.ini with defaults if it does not exist' }
        )
        Examples = @(
            'rocmroll config show'
            'rocmroll config init'
        )
    }
}

function Show-CommandHelp {
    param([string]$Command)
    $def = $script:CommandDefs[$Command]
    if (-not $def) {
        Write-Host "  No help entry for '$Command'. Run 'rocmroll help' for a command list." -ForegroundColor Yellow
        return
    }
    $upper = $Command.ToUpper()
    Write-Host ""
    Write-Host "  ROCMROLL $upper" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $($def.Synopsis)" -ForegroundColor White
    Write-Host ""
    Write-Host "  USAGE" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    $($def.Usage)"
    Write-Host ""
    if ($def.Params.Count -gt 0) {
        Write-Host "  PARAMETERS" -ForegroundColor Yellow
        Write-Host ""
        foreach ($p in $def.Params) {
            $tag  = if ($p.Required) { ' (required)' } elseif ($p.Default) { " (default: $($p.Default))" } else { '' }
            $col  = $p.Flag.PadRight(36)
            $color = if ($p.Required) { 'White' } else { 'Gray' }
            Write-Host "    $col $($p.Desc)$tag" -ForegroundColor $color
        }
        Write-Host ""
    }
    if ($def.Examples.Count -gt 0) {
        Write-Host "  EXAMPLES" -ForegroundColor Yellow
        Write-Host ""
        foreach ($ex in $def.Examples) {
            Write-Host "    $ex" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

function Assert-Param {
    param(
        [string]$Value,
        [string]$Flag,
        [string]$Command
    )
    if (-not $Value) {
        Write-Host ""
        Write-Host "  ERROR  $Flag is required for 'rocmroll $Command'" -ForegroundColor Red
        Show-CommandHelp -Command $Command
        exit 1
    }
}

# Route --help to per-command help before dispatch
if ($FlagHelp -and $Command -ne 'help') {
    Show-CommandHelp -Command $Command
    exit 0
}

# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

switch ($Command.ToLower()) {

    'init' {
        Import-AllModules
        Initialize-FolderStructure
        $cfgFile = Initialize-DefaultConfigFile
        if (Test-Path $cfgFile) {
            Write-LogInfo "Config file: $cfgFile" -Comp 'RocmRoll'
        }
        Write-LogSuccess "ROCmRoll initialized at $RootFolder" -Comp 'RocmRoll'
    }

    'install' {
        $subCmd = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0].ToLower() } else { $null }
        if ($subCmd) {
            Write-Host ''
            Write-Host "  ERROR  Unknown install sub-command: '$subCmd'" -ForegroundColor Red
            Write-Host ''
            Write-Host "  Use 'rocmroll comfy ...' for ComfyUI operations." -ForegroundColor DarkGray
            Write-Host "  Use 'rocmroll rocm  ...' for ROCm information." -ForegroundColor DarkGray
            Write-Host "  Run 'rocmroll install --help' for full install options." -ForegroundColor DarkGray
            Write-Host ''
            exit 1
        }
        Assert-Param -Value $InstanceName -Flag '--instance' -Command 'install'
        Import-AllModules
        Invoke-FullInstall -InstanceName $InstanceName -Channel $Channel `
            -PythonVersion $PythonVersion -GfxOverride $GfxOverride `
            -ProfileName $ProfileName -Force:$FlagForce `
            -SharedWorkflows:$FlagSharedWorkflows
    }

    'rocm' {
        Assert-Param -Value $InstanceName -Flag '--instance' -Command 'rocm'
        $subCmd = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0].ToLower() } else { '' }
        Import-AllModules

        switch ($subCmd) {
            'info' {
                $instState = Get-InstanceState -Name $InstanceName
                $envName   = if ($instState -and $instState.environment) { $instState.environment } else { $InstanceName }
                $envState  = Get-EnvironmentState -Name $envName

                Write-Host ''
                Write-Host "  ROCm Environment: $InstanceName" -ForegroundColor Cyan
                Write-Host ''
                if ($envState) {
                    Write-Host ("  {0,-12} {1}" -f 'Environment', $envName) -ForegroundColor White
                    Write-Host ("  {0,-12} {1}" -f 'Status', $envState.status) -ForegroundColor White
                    if ($envState.gpu) {
                        $gpu      = $envState.gpu
                        $gpuName  = if ($gpu.PSObject.Properties['name'])             { $gpu.name }                        else { '' }
                        $gpuGfx   = if ($gpu.PSObject.Properties['gfx'])              { $gpu.gfx }                         else { '' }
                        $gpuArch  = if ($gpu.PSObject.Properties['architectureName']) { " / $($gpu.architectureName)" }    else { '' }
                        $gpuLabel = if ($gpuName) { "$gpuName ($gpuGfx$gpuArch)" } elseif ($gpuGfx) { "$gpuGfx$gpuArch" } else { 'Unknown GPU' }
                        Write-Host ("  {0,-12} {1}" -f 'GPU', $gpuLabel) -ForegroundColor White
                    }
                    if ($envState.packages) {
                        Write-Host ''
                        Write-Host '  Packages:' -ForegroundColor Yellow
                        foreach ($pkg in $envState.packages.PSObject.Properties) {
                            Write-Host ("    {0,-28} {1}" -f $pkg.Name, $pkg.Value) -ForegroundColor Gray
                        }
                    }
                } else {
                    Write-Host '  No environment state found. Run rocmroll install first.' -ForegroundColor Yellow
                }
                Write-Host ''
            }
            'validate' {
                $instState = Get-InstanceState -Name $InstanceName
                $envName   = if ($instState -and $instState.environment) { $instState.environment } else { $InstanceName }
                $result    = Invoke-ValidateRocm -EnvironmentName $envName
                if ($FlagJson) {
                    $result | ConvertTo-Json -Depth 5
                } else {
                    Write-Host ''
                    Write-Host "  ROCm Validation: $InstanceName" -ForegroundColor Cyan
                    Write-Host ''
                    $passed = if ($result.passed) { 'PASS' } else { 'FAIL' }
                    $color  = if ($result.passed) { 'Green' } else { 'Red' }
                    Write-Host "  Result : $passed" -ForegroundColor $color
                    $torchVer = if ($result.PSObject.Properties['torchVersion']) { $result.torchVersion } else { $null }
                    $hipVer   = if ($result.PSObject.Properties['hipVersion'])   { $result.hipVersion   } else { $null }
                    $devCount = if ($result.PSObject.Properties['deviceCount'])  { $result.deviceCount  } else { $null }
                    $devName  = $null
                    if ($result.PSObject.Properties['checks'] -and $result.checks) {
                        $devChks = @($result.checks | Where-Object { $_.check -eq 'device_name' -and $_.passed })
                        if ($devChks.Count -gt 0 -and $devChks[0].PSObject.Properties['value']) { $devName = $devChks[0].value }
                    }
                    if ($torchVer)          { Write-Host ("  {0,-12} {1}" -f 'torch',   $torchVer) -ForegroundColor Gray }
                    if ($hipVer)            { Write-Host ("  {0,-12} {1}" -f 'HIP',     $hipVer)   -ForegroundColor Gray }
                    if ($null -ne $devCount){ Write-Host ("  {0,-12} {1}" -f 'Devices', $devCount) -ForegroundColor Gray }
                    if ($devName)           { Write-Host ("  {0,-12} {1}" -f 'Device',  $devName)  -ForegroundColor Gray }
                    if (-not $result.passed -and $result.error) {
                        Write-Host "  error  : $($result.error)" -ForegroundColor Red
                    }
                    Write-Host ''
                }
            }
            default {
                Write-Host ''
                Write-Host "  Usage: rocmroll rocm <info|validate> --instance NAME" -ForegroundColor Yellow
                Write-Host ''
                Show-CommandHelp -Command 'rocm'
            }
        }
    }

    'comfy' {
        Assert-Param -Value $InstanceName -Flag '--instance' -Command 'comfy'
        $subCmd = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0].ToLower() } else { '' }
        Import-AllModules
        $cfg = Get-Config

        $instState = Get-InstanceState -Name $InstanceName
        $envName   = if ($EnvName) { $EnvName }
                     elseif ($instState -and $instState.environment) { $instState.environment }
                     else { "$InstanceName-py$($PythonVersion.Replace('.','').Substring(0,3))" }

        switch ($subCmd) {
            'info' {
                $nodesDir  = Join-Path $cfg.InstancesFolder "$InstanceName\custom_nodes"
                $nodesList = @()
                if (Test-Path $nodesDir) {
                    $nodesList = @(Get-ChildItem $nodesDir -Directory -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Name)
                }

                Write-Host ''
                Write-Host "  ComfyUI: $InstanceName" -ForegroundColor Cyan
                Write-Host ''
                if ($instState) {
                    Write-Host ("  {0,-9} {1}" -f 'Status',  $instState.status)  -ForegroundColor White
                    Write-Host ("  {0,-9} {1}" -f 'Channel', $instState.channel) -ForegroundColor White
                    if ($instState.comfyui) {
                        if ($instState.comfyui.ref)    { Write-Host ("  {0,-9} {1}" -f 'Ref',    $instState.comfyui.ref)    -ForegroundColor Gray }
                        if ($instState.comfyui.commit) { Write-Host ("  {0,-9} {1}" -f 'Commit', $instState.comfyui.commit) -ForegroundColor Gray }
                    }
                } else {
                    Write-Host '  No instance state found. Run rocmroll install first.' -ForegroundColor Yellow
                }
                Write-Host ''
                Write-Host "  Custom nodes ($($nodesList.Count)):" -ForegroundColor Yellow
                if ($nodesList.Count -eq 0) {
                    Write-Host '    (none)' -ForegroundColor DarkGray
                } else {
                    foreach ($n in $nodesList) { Write-Host "    $n" -ForegroundColor Gray }
                }
                Write-Host ''
            }
            'requirements' {
                Invoke-InstallComfyDeps -InstanceName $InstanceName -EnvironmentName $envName
            }
            'nodes' {
                $nodesDir = Join-Path $cfg.InstancesFolder "$InstanceName\custom_nodes"
                Write-Host ''
                Write-Host "  Custom nodes: $InstanceName" -ForegroundColor Cyan
                Write-Host ''
                if (Test-Path $nodesDir) {
                    $dirs = @(Get-ChildItem $nodesDir -Directory -ErrorAction SilentlyContinue)
                    if ($dirs.Count -eq 0) {
                        Write-Host '  No custom nodes installed.' -ForegroundColor Gray
                    } else {
                        foreach ($d in $dirs) { Write-Host "    $($d.Name)" -ForegroundColor Gray }
                    }
                } else {
                    Write-Host '  custom_nodes folder not found.' -ForegroundColor Yellow
                }
                Write-Host ''
            }
            'update-nodes' {
                Invoke-InstallCustomNodes -InstanceName $InstanceName -EnvironmentName $envName -Update
            }
            'add-node' {
                Assert-Param -Value $Url -Flag '--url' -Command 'comfy'
                Invoke-InstallNodeFromUrl -Url $Url -InstanceName $InstanceName -EnvironmentName $envName
            }
            'node-requirements' {
                Invoke-InstallCustomNodes -InstanceName $InstanceName -EnvironmentName $envName -RequirementsOnly
            }
            default {
                Write-Host ''
                Write-Host "  Usage: rocmroll comfy <info|requirements|nodes|update-nodes|add-node|node-requirements> --instance NAME" -ForegroundColor Yellow
                Write-Host ''
                Show-CommandHelp -Command 'comfy'
            }
        }
    }

    'launch' {
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1')   -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.State.psm1')    -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Launcher.psm1') -Force -Global

        if (-not $InstanceName) {
            $cfg         = Get-Config
            $instances   = @()
            foreach ($f in (Get-ChildItem $cfg.InstanceStateFolder -Filter 'instance-*.json' -ErrorAction SilentlyContinue)) {
                try {
                    $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($s.status -eq 'ready') {
                        $instances += [PSCustomObject]@{
                            Name    = [string]$s.name
                            Channel = if ($s.channel) { [string]$s.channel } else { '-' }
                        }
                    }
                } catch { }
            }

            if ($instances.Count -eq 0) {
                Write-Host ''
                Write-Host '  No ready instances found.' -ForegroundColor Red
                Write-Host '  Run: rocmroll install --instance NAME' -ForegroundColor DarkGray
                Write-Host ''
                exit 1
            }

            if ($instances.Count -eq 1) {
                $InstanceName = $instances[0].Name
                Write-Host ''
                Write-Host "  Auto-selected instance: $InstanceName" -ForegroundColor DarkGray
                Write-Host ''
            } else {
                Write-Host ''
                Write-Host '  ROCmRoll' -ForegroundColor Cyan -NoNewline
                Write-Host ' - Launch ComfyUI'
                Write-Host ''
                Write-Host '  Available instances:' -ForegroundColor White
                Write-Host ''
                for ($i = 0; $i -lt $instances.Count; $i++) {
                    $inst = $instances[$i]
                    $num  = "[$($i + 1)]".PadRight(5)
                    $name = $inst.Name.PadRight(28)
                    Write-Host "    $num $name channel: $($inst.Channel)"
                }
                Write-Host ''
                $chosen = $null
                while ($null -eq $chosen) {
                    $choice = Read-Host "  Select (1-$($instances.Count)) or Q to quit"
                    if ($choice -ieq 'q') { Write-Host ''; exit 0 }
                    $n = 0
                    if ([int]::TryParse($choice.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $instances.Count) {
                        $chosen = $instances[$n - 1].Name
                    } else {
                        Write-Host "  Please enter a number between 1 and $($instances.Count)." -ForegroundColor Yellow
                    }
                }
                $InstanceName = $chosen
                Write-Host ''
            }
        }

        $launchExtra = if ($PortArg) { @('--port', $PortArg) } else { @() }
        $exitCode = Invoke-LaunchInstance -InstanceName $InstanceName `
            -ProfileOverride $ProfileName -ExtraArgs $launchExtra
        exit $exitCode
    }

    'update' {
        Assert-Param -Value $InstanceName -Flag '--instance' -Command 'update'
        Import-AllModules
        Invoke-FullInstall -InstanceName $InstanceName -Channel $Channel `
            -PythonVersion $PythonVersion -GfxOverride $GfxOverride `
            -ProfileName $ProfileName -Force
    }

    'doctor' {
        Import-AllModules
        $doctorArgs = @{
            InstanceName = $InstanceName
            GpuOnly      = $FlagGpuOnly
            CacheOnly    = $FlagCacheOnly
            SystemOnly   = $FlagSystemOnly
            JsonOutput   = $FlagJson
        }
        if ($FlagJson) {
            Invoke-Doctor @doctorArgs
        } else {
            Invoke-Doctor @doctorArgs | Out-Null
        }
    }

    'repair' {
        Assert-Param -Value $InstanceName -Flag '--instance' -Command 'repair'
        Import-AllModules
        $comp = if ($Component) { $Component } else { 'all' }
        $rollbackPatchValue = if ($RollbackPatch) { $RollbackPatch } else { '' }
        Invoke-RepairComponent -InstanceName $InstanceName -Component $comp `
            -RollbackPatch $rollbackPatchValue -ProfileName $ProfileName `
            -SharedWorkflows:$FlagSharedWorkflows
    }

    'list' {
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1') -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.State.psm1')  -Force -Global
        $cfg = Get-Config
        $instances = @(Get-ChildItem $cfg.InstancesFolder -Directory -ErrorAction SilentlyContinue)
        if ($instances.Count -eq 0) {
            Write-Host "No instances found." -ForegroundColor Yellow
        } else {
            foreach ($dir in $instances) {
                $state = Get-InstanceState -Name $dir.Name
                $status = if ($state) { $state.status } else { 'unknown' }
                $channel = if ($state) { $state.channel } else { '-' }
                Write-Host ("  {0,-30} channel={1,-10} status={2}" -f $dir.Name, $channel, $status)
            }
        }
    }

    'remove' {
        Assert-Param -Value $InstanceName -Flag '--instance' -Command 'remove'
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1')       -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Logging.psm1')      -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.State.psm1')        -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.ComfyDesktop.psm1') -Force -Global
        $cfg    = Get-Config
        $folder = Join-Path $cfg.InstancesFolder $InstanceName
        $state = Get-InstanceState -Name $InstanceName
        $envName = if ($EnvName) { $EnvName } elseif ($state -and $state.environment) { $state.environment } else { "$InstanceName-py$($PythonVersion.Split('.')[0])$($PythonVersion.Split('.')[1])" }
        $envFolder = Join-Path $cfg.EnvironmentsFolder $envName
        $stateFile = Join-Path $cfg.InstanceStateFolder "instance-$InstanceName.json"
        $envStateFile = Join-Path $cfg.EnvStateFolder "environment-$envName.json"

        if (-not (Test-Path $folder) -and -not (Test-Path $envFolder) -and -not (Test-Path $stateFile) -and -not (Test-Path $envStateFile)) {
            Write-LogWarn "Install '$InstanceName' not found." -Comp 'RocmRoll'
            return
        }

        if (-not $FlagForce) {
            $confirm = Read-Host "Remove instance '$InstanceName' and environment '$envName'? (y/N)"
            if ($confirm -ne 'y') { Write-Host 'Cancelled.'; return }
        }

        # Remove from ComfyUI Desktop before deleting files
        $desktopId = if ($state -and $state.PSObject.Properties['comfyDesktopId']) { [string]$state.comfyDesktopId } else { '' }
        Unregister-ComfyDesktopInstance -InstanceName $InstanceName -ComfyDesktopId $desktopId

        if (Test-Path $folder) {
            Remove-FolderTree -Path $folder -ParentFolder $cfg.InstancesFolder -Description 'instance'
            Write-LogSuccess "Removed instance folder: $folder" -Comp 'RocmRoll'
        }

        if (Test-Path $envFolder) {
            Remove-FolderTree -Path $envFolder -ParentFolder $cfg.EnvironmentsFolder -Description 'environment'
            Write-LogSuccess "Removed environment folder: $envFolder" -Comp 'RocmRoll'
        }

        if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
        if (Test-Path $envStateFile) { Remove-Item $envStateFile -Force }

        $launcherPs1 = Join-Path $cfg.LaunchersFolder "$InstanceName.ps1"
        $launcherBat = Join-Path $cfg.LaunchersFolder "$InstanceName.bat"
        if (Test-Path $launcherPs1) { Remove-Item $launcherPs1 -Force; Write-LogSuccess "Removed launcher: $launcherPs1" -Comp 'RocmRoll' }
        if (Test-Path $launcherBat) { Remove-Item $launcherBat -Force; Write-LogSuccess "Removed launcher: $launcherBat" -Comp 'RocmRoll' }

        Write-LogSuccess "Install '$InstanceName' removed." -Comp 'RocmRoll'
    }

    'cache' {
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1')  -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Cache.psm1')   -Force -Global
        $sub = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0] } else { 'list' }
        switch ($sub) {
            'list'   { Get-CacheSummary | ForEach-Object { $_.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-15} {1} files, {2} MB" -f $_.Key, $_.Value.fileCount, [math]::Round($_.Value.totalBytes/1MB,1)) } } }
            'verify' { $r = Invoke-CacheVerify; $r | ForEach-Object { Write-Host ("  {0,-50} {1}" -f $_.file, $_.status) } }
            'clean'  {
                if (Get-Flag -ArgList $RemainingArgs -Name 'all') {
                    Remove-AllCache | Out-Null
                } else {
                    if (Get-Flag -ArgList $RemainingArgs -Name 'temp') { Remove-TempFolder }
                    Remove-PartialDownloads | Out-Null
                }
            }
            'prune'  {
                $days = if ($null -ne $OlderThanDays) { [int]$OlderThanDays } else { 30 }
                Remove-OldCacheFiles -OlderThanDays $days | Out-Null
            }
            default  { Write-Host "Unknown cache subcommand: $sub. Use: list, verify, clean, prune" }
        }
    }

    'logs' {
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1') -Force -Global
        $cfg  = Get-Config
        $logs = Get-ChildItem $cfg.LogsFolder -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 20
        $logs | ForEach-Object { Write-Host "  $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $($_.FullName)" }
    }

    'config' {
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1') -Force -Global
        $sub = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0] } else { 'show' }
        switch ($sub) {
            'show' {
                $cfg     = Get-Config
                $iniPath = $cfg.ConfigFilePath
                $active  = Test-Path $iniPath

                Write-Host ''
                Write-Host '  ROCmRoll Configuration' -ForegroundColor Cyan
                Write-Host ''
                if ($active) {
                    Write-Host "  Config file : $iniPath" -ForegroundColor Green
                } else {
                    Write-Host "  Config file : $iniPath  (not found - using defaults)" -ForegroundColor Yellow
                }
                Write-Host ''
                Write-Host '  Paths:' -ForegroundColor Yellow
                Write-Host ''

                $entries = [ordered]@{
                    'Root'         = 'RootFolder'
                    'Shared'       = 'SharedFolder'
                    'Input'        = 'InputFolder'
                    'Output'       = 'OutputFolder'
                    'Temp'         = 'TempDataFolder'
                    'User Data'    = 'UserDataFolder'
                    'Instances'    = 'InstancesFolder'
                    'Environments' = 'EnvironmentsFolder'
                    'Runtimes'     = 'RuntimesFolder'
                    'Launchers'    = 'LaunchersFolder'
                    'Profiles'     = 'ProfilesFolder'
                    'Logs'         = 'LogsFolder'
                    'State'        = 'StateFolder'
                    'Cache'        = 'CacheFolder'
                }
                foreach ($e in $entries.GetEnumerator()) {
                    Write-Host ('    {0,-14} {1}' -f "$($e.Key):", $cfg[$e.Value]) -ForegroundColor Gray
                }
                Write-Host ''
                if (-not $active) {
                    Write-Host "  Tip: run 'rocmroll config init' to create rocmroll.ini." -ForegroundColor DarkGray
                } else {
                    Write-Host "  Edit $iniPath to customise paths." -ForegroundColor DarkGray
                }
                Write-Host ''
            }
            'init' {
                $cfg     = Get-Config
                $iniPath = $cfg.ConfigFilePath
                $existed = Test-Path $iniPath
                Initialize-DefaultConfigFile | Out-Null
                if ($existed) {
                    Write-Host ''
                    Write-Host "  Config file already exists: $iniPath" -ForegroundColor Yellow
                } else {
                    Write-Host ''
                    Write-Host "  Config file created: $iniPath" -ForegroundColor Green
                }
                Write-Host ''
            }
            default {
                Write-Host ''
                Write-Host "  Unknown config sub-command: '$sub'. Use: show, init" -ForegroundColor Yellow
                Write-Host ''
            }
        }
    }

    'profile' {
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Config.psm1')    -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Logging.psm1')   -Force -Global
        Import-Module (Join-Path $ModulesDir 'RocmRoll.Profiles.psm1')  -Force -Global
        $cfg    = Get-Config
        $subCmd = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0] } else { 'list' }
        switch ($subCmd) {
            'list' {
                $all = Get-ProfileList -Config $cfg
                if ($all.Count -eq 0) {
                    Write-Host ''
                    Write-Host "  No profiles found in: $($cfg.ProfilesFolder)" -ForegroundColor Yellow
                    Write-Host ''
                } else {
                    Write-Host ''
                    Write-Host '  ROCmRoll Execution Profiles' -ForegroundColor Cyan
                    $all | Show-ProfileDetail
                    Write-Host ''
                }
            }
            'show' {
                if (-not $ProfileName) {
                    Write-Host ''
                    Write-Host "  ERROR  --profile NAME is required for 'rocmroll profile show'" -ForegroundColor Red
                    Write-Host ''
                    exit 1
                }
                $obj = Get-ProfileObject -Name $ProfileName -Config $cfg
                Write-Host ''
                Write-Host '  ROCmRoll Profile Detail' -ForegroundColor Cyan
                $obj | Show-ProfileDetail
                Write-Host ''
            }
            'create' {
                New-ProfileInteractive -Name $ProfileName -Config $cfg
            }
            'remove' {
                if (-not $ProfileName) {
                    Write-Host ''
                    Write-Host "  ERROR  --profile NAME is required for 'rocmroll profile remove'" -ForegroundColor Red
                    Write-Host ''
                    exit 1
                }
                Remove-Profile -Name $ProfileName -Force:$FlagForce -Config $cfg
            }
            default {
                Write-Host ''
                Write-Host "  Unknown profile sub-command: '$subCmd'. Use: list, show, create, remove" -ForegroundColor Yellow
                Show-CommandHelp -Command 'profile'
                Write-Host ''
            }
        }
    }

    'help' {
        # rocmroll help <command>  ->  per-command detail
        $helpTarget = if ($RemainingArgs.Count -gt 0 -and $RemainingArgs[0] -notlike '-*') { $RemainingArgs[0] } else { '' }

        if ($helpTarget -eq 'options') {
            Write-Host ''
            Write-Host '  GLOBAL OPTIONS' -ForegroundColor Cyan
            Write-Host ''
            $globalOpts = [ordered]@{
                '--instance   NAME'       = 'Target instance name'
                '--channel    VALUE'      = 'Update channel: stable | nightly           (default: stable)'
                '--python     VERSION'    = 'Python version                             (default: 3.12.10)'
                '--port       PORT'       = 'ComfyUI listen port                        (default: 8188)'
                '--gfx        ARCH'       = 'Override GPU architecture  e.g. gfx120X, gfx1201'
                '--component  SCOPE'      = 'Repair scope: python-runtime | python-env | rocm | comfyui | custom-nodes | launchers | patches | all'
                '--env        NAME'       = 'Specify environment name explicitly'
                '--url        URL'        = 'Git repository URL (comfy add-node)'
                '--older-than-days N'     = 'Prune cache entries older than N days'
                '--profile    NAME'       = 'Execution profile name (overrides channel default)'
                '--force'                 = 'Force overwrite / bypass stale locks'
                '--quiet'                 = 'Suppress non-error output'
                '--verbose / --debug'     = 'Show pip download/install output (default: only summary)'
                '--json'                  = 'Emit structured JSON output'
                '--no-color'              = 'Disable colour output'
                '--log-file   PATH'       = 'Write log to file'
                '--help'                  = 'Show help for the current command'
            }
            foreach ($o in $globalOpts.GetEnumerator()) {
                Write-Host ('    {0,-26}  {1}' -f $o.Key, $o.Value) -ForegroundColor Gray
            }
            Write-Host ''
            exit 0
        }

        if ($helpTarget -and $script:CommandDefs.Contains($helpTarget)) {
            Show-CommandHelp -Command $helpTarget
            exit 0
        }

        Show-AsciiArt
        Write-Host "  Usage:  rocmroll <command> [--help] [options]" -ForegroundColor White
        Write-Host ""
        Write-Host "  Common commands:" -ForegroundColor Yellow
        Write-Host ""
        $common = @('install','launch','update','doctor','repair','list','remove','cache')
        foreach ($cmd in $common) {
            $d = $script:CommandDefs[$cmd]
            if ($d) { Write-Host ("    {0,-18} {1}" -f $cmd, $d.Synopsis) }
        }
        Write-Host ""
        Write-Host "  Advanced commands:" -ForegroundColor Yellow
        Write-Host ""
        $advanced = @('init','rocm','comfy','logs','config','profile')
        foreach ($cmd in $advanced) {
            $d = $script:CommandDefs[$cmd]
            if ($d) { Write-Host ("    {0,-18} {1}" -f $cmd, $d.Synopsis) }
        }
        Write-Host ''
        Write-Host '  Tip: rocmroll help <command>  or  rocmroll <command> --help' -ForegroundColor DarkGray
        Write-Host '       rocmroll help options    to list all global flags' -ForegroundColor DarkGray
        Write-Host ''
    }

    default {
        Write-Host ""
        Write-Host "  ERROR  Unknown command: '$Command'" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Run 'rocmroll help' for a command list." -ForegroundColor DarkGray
        Write-Host "  Run 'rocmroll help <command>' for detailed usage." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
}
