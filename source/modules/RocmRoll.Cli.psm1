#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Cli - CLI context, help, imports, and command dispatch.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CliFlag {
    param([string[]]$ArgList, [string]$Name)
    return ($ArgList -contains "--$Name") -or ($ArgList -contains "-$Name")
}

function Get-CliFlagValue {
    param([string[]]$ArgList, [string]$Name)
    for ($i = 0; $i -lt $ArgList.Count - 1; $i++) {
        if ($ArgList[$i] -in @("--$Name", "-$Name")) { return $ArgList[$i + 1] }
    }
    return $null
}

function Get-CliSubCommand {
    param([string[]]$ArgList, [string]$Default = '')
    if ($ArgList.Count -gt 0 -and $ArgList[0] -notlike '-*') { return $ArgList[0].ToLower() }
    return $Default
}

function New-CliContext {
    param(
        [string]$Command = 'help',
        [string[]]$RemainingArgs = @(),
        [string]$ScriptRoot = ''
    )

    if (-not $ScriptRoot) { $ScriptRoot = Split-Path $PSScriptRoot -Parent }

    $rootFolder = Split-Path $ScriptRoot -Parent
    $modulesDir = Join-Path $ScriptRoot 'modules'

    $flagDebug = Get-CliFlag -ArgList $RemainingArgs -Name 'debug'
    $flagVerbose = Get-CliFlag -ArgList $RemainingArgs -Name 'verbose'
    $logLevel = Get-CliFlagValue -ArgList $RemainingArgs -Name 'log-level'
    if (-not $logLevel) {
        $logLevel = if ($flagDebug -or $flagVerbose) { 'DEBUG' } else { 'INFO' }
    }

    $channel = Get-CliFlagValue -ArgList $RemainingArgs -Name 'channel'
    if (-not $channel) { $channel = 'stable' }

    $pythonVersion = Get-CliFlagValue -ArgList $RemainingArgs -Name 'python'
    if (-not $pythonVersion) { $pythonVersion = '3.12.10' }

    return [PSCustomObject][ordered]@{
        Command             = if ($Command) { $Command.ToLower() } else { 'help' }
        RemainingArgs       = $RemainingArgs
        SubCommand          = Get-CliSubCommand -ArgList $RemainingArgs
        ScriptRoot          = $ScriptRoot
        RootFolder          = $rootFolder
        ModulesDir          = $modulesDir

        WorkspaceName       = Get-CliFlagValue -ArgList $RemainingArgs -Name 'workspace'
        InstanceName        = Get-CliFlagValue -ArgList $RemainingArgs -Name 'instance'
        Channel             = $channel
        PythonVersion       = $pythonVersion
        GfxOverride         = Get-CliFlagValue -ArgList $RemainingArgs -Name 'gfx'
        Component           = Get-CliFlagValue -ArgList $RemainingArgs -Name 'component'
        RollbackPatch       = Get-CliFlagValue -ArgList $RemainingArgs -Name 'rollback-patch'
        LogLevel            = $logLevel
        LogFile             = Get-CliFlagValue -ArgList $RemainingArgs -Name 'log-file'
        EnvName             = Get-CliFlagValue -ArgList $RemainingArgs -Name 'env'
        OlderThanDays       = Get-CliFlagValue -ArgList $RemainingArgs -Name 'older-than-days'
        PortArg             = Get-CliFlagValue -ArgList $RemainingArgs -Name 'port'
        ProfileName         = Get-CliFlagValue -ArgList $RemainingArgs -Name 'profile'
        PatchId             = Get-CliFlagValue -ArgList $RemainingArgs -Name 'patch-id'
        Url                 = Get-CliFlagValue -ArgList $RemainingArgs -Name 'url'

        FlagForce           = Get-CliFlag -ArgList $RemainingArgs -Name 'force'
        FlagQuiet           = Get-CliFlag -ArgList $RemainingArgs -Name 'quiet'
        FlagVerbose         = $flagVerbose
        FlagDebug           = $flagDebug
        FlagJson            = Get-CliFlag -ArgList $RemainingArgs -Name 'json'
        FlagNoColor         = Get-CliFlag -ArgList $RemainingArgs -Name 'no-color'
        FlagGpuOnly         = Get-CliFlag -ArgList $RemainingArgs -Name 'gpu'
        FlagCacheOnly       = Get-CliFlag -ArgList $RemainingArgs -Name 'cache'
        FlagSystemOnly      = Get-CliFlag -ArgList $RemainingArgs -Name 'system'
        FlagHelp            = Get-CliFlag -ArgList $RemainingArgs -Name 'help'
        FlagSharedWorkflows = Get-CliFlag -ArgList $RemainingArgs -Name 'shared-workflows'
    }
}

function Get-RocmRollCommandDefinitions {
    return [ordered]@{
        install = @{
            Synopsis = 'Install Python runtime, ROCm/PyTorch, ComfyUI, and custom nodes'
            Usage = 'rocmroll install --instance NAME [options]'
            Params = @(
                [ordered]@{ Flag = '--instance  NAME'; Required = $true; Default = ''; Desc = 'Instance name to create' }
                [ordered]@{ Flag = '--channel   stable|nightly|preview|rdna1|rdna2'; Required = $false; Default = 'stable'; Desc = 'Update channel' }
                [ordered]@{ Flag = '--python    VERSION'; Required = $false; Default = '3.12.10'; Desc = 'Python version' }
                [ordered]@{ Flag = '--gfx       ARCH'; Required = $false; Default = ''; Desc = 'Override GPU architecture' }
                [ordered]@{ Flag = '--profile   NAME'; Required = $false; Default = ''; Desc = 'Execution profile to bake into the launcher' }
                [ordered]@{ Flag = '--force'; Required = $false; Default = ''; Desc = 'Force reinstall even if already ready' }
                [ordered]@{ Flag = '--shared-workflows'; Required = $false; Default = ''; Desc = 'Symlink instance workflows to shared/workflows' }
            )
            Examples = @('rocmroll install --instance rocm-stable', 'rocmroll install --instance rocm-nightly --channel nightly')
        }
        launch = @{
            Synopsis = 'Launch a ComfyUI instance (interactive selector when --instance is omitted)'
            Usage = 'rocmroll launch [--instance NAME] [--port PORT]'
            Params = @(
                [ordered]@{ Flag = '--instance  NAME'; Required = $false; Default = ''; Desc = 'Instance name' }
                [ordered]@{ Flag = '--port      PORT'; Required = $false; Default = '8188'; Desc = 'Listen port' }
                [ordered]@{ Flag = '--profile   NAME'; Required = $false; Default = ''; Desc = 'Override execution profile at runtime' }
            )
            Examples = @('rocmroll launch', 'rocmroll launch --instance rocm-stable')
        }
        update = @{
            Synopsis = 'Update an existing instance to the latest state'
            Usage = 'rocmroll update --instance NAME [options]'
            Params = @(
                [ordered]@{ Flag = '--instance  NAME'; Required = $true; Default = ''; Desc = 'Instance to update' }
                [ordered]@{ Flag = '--channel   stable|nightly|preview|rdna1|rdna2'; Required = $false; Default = 'stable'; Desc = 'Switch update channel' }
                [ordered]@{ Flag = '--gfx       ARCH'; Required = $false; Default = ''; Desc = 'Override GPU architecture' }
            )
            Examples = @('rocmroll update --instance rocm-stable')
        }
        doctor = @{
            Synopsis = 'Run diagnostics and health checks'
            Usage = 'rocmroll doctor [--instance NAME] [options]'
            Params = @(
                [ordered]@{ Flag = '--instance  NAME'; Required = $false; Default = ''; Desc = 'Scope checks to a specific instance' }
                [ordered]@{ Flag = '--gpu'; Required = $false; Default = ''; Desc = 'GPU detection and ROCm checks only' }
                [ordered]@{ Flag = '--cache'; Required = $false; Default = ''; Desc = 'Cache integrity checks only' }
                [ordered]@{ Flag = '--system'; Required = $false; Default = ''; Desc = 'System-level checks only' }
                [ordered]@{ Flag = '--json'; Required = $false; Default = ''; Desc = 'Output results as structured JSON' }
            )
            Examples = @('rocmroll doctor', 'rocmroll doctor --gpu')
        }
        repair = @{
            Synopsis = 'Repair a specific component of an instance'
            Usage = 'rocmroll repair --instance NAME [--component SCOPE]'
            Params = @(
                [ordered]@{ Flag = '--instance   NAME'; Required = $true; Default = ''; Desc = 'Instance to repair' }
                [ordered]@{ Flag = '--component  SCOPE'; Required = $false; Default = 'all'; Desc = 'python-runtime | python-env | rocm | comfyui | custom-nodes | launchers | patches | all' }
                [ordered]@{ Flag = '--profile    NAME'; Required = $false; Default = ''; Desc = 'Profile to apply when repairing launchers' }
                [ordered]@{ Flag = '--shared-workflows'; Required = $false; Default = ''; Desc = 'Re-create shared workflows symlink during comfyui/all repair' }
            )
            Examples = @('rocmroll repair --instance rocm-stable')
        }
        list = @{ Synopsis = 'List all installed ComfyUI instances'; Usage = 'rocmroll list [--workspace NAME]'; Params = @(); Examples = @('rocmroll list') }
        remove = @{
            Synopsis = 'Remove an instance and its Python environment'
            Usage = 'rocmroll remove --instance NAME [--force]'
            Params = @(
                [ordered]@{ Flag = '--instance  NAME'; Required = $true; Default = ''; Desc = 'Instance to remove' }
                [ordered]@{ Flag = '--force'; Required = $false; Default = ''; Desc = 'Skip the confirmation prompt' }
            )
            Examples = @('rocmroll remove --instance rocm-stable --force')
        }
        cache = @{ Synopsis = 'Inspect or clean the download and wheel cache'; Usage = 'rocmroll cache <list|verify|clean|prune> [options]'; Params = @(); Examples = @('rocmroll cache list') }
        init = @{ Synopsis = 'Initialize the ROCmRoll folder structure'; Usage = 'rocmroll init'; Params = @(); Examples = @('rocmroll init') }
        rocm = @{
            Synopsis = 'Show ROCm and PyTorch information for an instance'
            Usage = 'rocmroll rocm <info|validate> --instance NAME'
            Params = @(
                [ordered]@{ Flag = 'info      --instance NAME'; Required = $false; Default = ''; Desc = 'Show installed ROCm/PyTorch packages and GPU information' }
                [ordered]@{ Flag = 'validate  --instance NAME'; Required = $false; Default = ''; Desc = 'Run the ROCm/PyTorch validation script' }
                [ordered]@{ Flag = '--instance NAME'; Required = $true; Default = ''; Desc = 'Target instance' }
            )
            Examples = @('rocmroll rocm validate --instance rocm-stable')
        }
        comfy = @{
            Synopsis = 'Show ComfyUI information and manage ComfyUI components for an instance'
            Usage = 'rocmroll comfy <info|requirements|nodes|update-nodes|add-node|node-requirements> --instance NAME [options]'
            Params = @(
                [ordered]@{ Flag = 'info              --instance NAME'; Required = $false; Default = ''; Desc = 'Show ComfyUI version, commit, status, and custom node list' }
                [ordered]@{ Flag = 'requirements      --instance NAME'; Required = $false; Default = ''; Desc = 'Reinstall ComfyUI requirements.txt' }
                [ordered]@{ Flag = 'nodes             --instance NAME'; Required = $false; Default = ''; Desc = 'List installed custom nodes' }
                [ordered]@{ Flag = 'update-nodes      --instance NAME'; Required = $false; Default = ''; Desc = 'Pull latest commits for all custom nodes' }
                [ordered]@{ Flag = 'add-node --url URL --instance NAME'; Required = $false; Default = ''; Desc = 'Install a custom node from a git repository URL' }
                [ordered]@{ Flag = 'node-requirements --instance NAME'; Required = $false; Default = ''; Desc = 'Reinstall requirements.txt for all custom nodes' }
            )
            Examples = @('rocmroll comfy info --instance rocm-stable')
        }
        logs = @{ Synopsis = 'Show recent log files'; Usage = 'rocmroll logs [--instance NAME]'; Params = @(); Examples = @('rocmroll logs') }
        config = @{
            Synopsis = 'Show or initialise the ROCmRoll configuration file (rocmroll.ini)'
            Usage = 'rocmroll config <show|init>'
            Params = @(
                [ordered]@{ Flag = 'show'; Required = $false; Default = ''; Desc = 'Print resolved paths and config file location' }
                [ordered]@{ Flag = 'init'; Required = $false; Default = ''; Desc = 'Create rocmroll.ini with defaults if it does not exist' }
            )
            Examples = @('rocmroll config show')
        }
        profile = @{
            Synopsis = 'Manage execution profiles'
            Usage = 'rocmroll profile <list|show|create|remove> [options]'
            Params = @(
                [ordered]@{ Flag = 'list'; Required = $false; Default = ''; Desc = 'List all available profiles' }
                [ordered]@{ Flag = 'show   --profile NAME'; Required = $false; Default = ''; Desc = 'Print full detail for a profile' }
                [ordered]@{ Flag = 'create --profile NAME'; Required = $false; Default = ''; Desc = 'Launch interactive wizard to create a profile' }
                [ordered]@{ Flag = 'remove --profile NAME'; Required = $false; Default = ''; Desc = 'Delete a profile' }
            )
            Examples = @('rocmroll profile list')
        }
        patch = @{
            Synopsis = 'Manage ComfyUI instance patches (apply, list, remove)'
            Usage = 'rocmroll patch <list|apply|remove> [--instance NAME] [--patch-id ID]'
            Params = @(
                [ordered]@{ Flag = 'list'; Required = $false; Default = ''; Desc = 'List available patches or applied status' }
                [ordered]@{ Flag = 'apply  --instance NAME'; Required = $false; Default = ''; Desc = 'Apply all applicable patches or one specific patch' }
                [ordered]@{ Flag = 'remove --instance NAME'; Required = $false; Default = ''; Desc = 'Remove a specific patch and restore original file' }
                [ordered]@{ Flag = '--patch-id ID'; Required = $false; Default = ''; Desc = 'Target a specific patch by ID' }
            )
            Examples = @('rocmroll patch list')
        }
        workspace = @{
            Synopsis = 'Manage named workspaces (separate path-sets for different disks or purposes)'
            Usage = 'rocmroll workspace <list|show|create|use|edit|remove|init> [options]'
            Params = @(
                [ordered]@{ Flag = 'list'; Required = $false; Default = ''; Desc = 'List all workspaces' }
                [ordered]@{ Flag = 'show   --workspace NAME'; Required = $false; Default = ''; Desc = 'Print paths stored in a workspace' }
                [ordered]@{ Flag = 'create --workspace NAME'; Required = $false; Default = ''; Desc = 'Interactive wizard to create a new workspace' }
                [ordered]@{ Flag = 'use    --workspace NAME'; Required = $false; Default = ''; Desc = 'Switch the active workspace' }
                [ordered]@{ Flag = 'edit   --workspace NAME'; Required = $false; Default = ''; Desc = 'Re-run the wizard on an existing workspace' }
                [ordered]@{ Flag = 'remove --workspace NAME'; Required = $false; Default = ''; Desc = 'Delete a workspace' }
                [ordered]@{ Flag = 'init   --workspace NAME'; Required = $false; Default = ''; Desc = 'Save current resolved paths as a new workspace' }
            )
            Examples = @('rocmroll workspace list')
        }
    }
}

function Show-RocmRollAsciiArt {
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

function Show-RocmRollHelp {
    param([string]$Command = '')

    $defs = Get-RocmRollCommandDefinitions
    if ($Command -eq 'options') {
        Write-Host ''
        Write-Host '  GLOBAL OPTIONS' -ForegroundColor Cyan
        Write-Host ''
        $globalOpts = [ordered]@{
            '--instance   NAME'       = 'Target instance name'
            '--workspace  NAME'       = 'Transient workspace override'
            '--channel    VALUE'      = 'Update channel: stable | nightly | preview | rdna1 | rdna2'
            '--python     VERSION'    = 'Python version (default: 3.12.10)'
            '--port       PORT'       = 'ComfyUI listen port (default: 8188)'
            '--gfx        ARCH'       = 'Override GPU architecture'
            '--component  SCOPE'      = 'Repair scope'
            '--env        NAME'       = 'Specify environment name explicitly'
            '--url        URL'        = 'Git repository URL'
            '--older-than-days N'     = 'Prune cache entries older than N days'
            '--profile    NAME'       = 'Execution profile name'
            '--force'                 = 'Force overwrite / bypass stale locks'
            '--quiet'                 = 'Suppress non-error output'
            '--verbose / --debug'     = 'Show debug output'
            '--json'                  = 'Emit structured JSON output'
            '--no-color'              = 'Disable colour output'
            '--log-file   PATH'       = 'Write log to file'
            '--help'                  = 'Show help for the current command'
        }
        foreach ($o in $globalOpts.GetEnumerator()) {
            Write-Host ('    {0,-26}  {1}' -f $o.Key, $o.Value) -ForegroundColor Gray
        }
        Write-Host ''
        return
    }

    if ($Command -and $defs.Contains($Command)) {
        $def = $defs[$Command]
        Write-Host ''
        Write-Host "  ROCMROLL $($Command.ToUpper())" -ForegroundColor Cyan
        Write-Host ''
        Write-Host "  $($def.Synopsis)" -ForegroundColor White
        Write-Host ''
        Write-Host '  USAGE' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "    $($def.Usage)"
        Write-Host ''
        if ($def.Params.Count -gt 0) {
            Write-Host '  PARAMETERS' -ForegroundColor Yellow
            Write-Host ''
            foreach ($p in $def.Params) {
                $tag = if ($p.Required) { ' (required)' } elseif ($p.Default) { " (default: $($p.Default))" } else { '' }
                $col = $p.Flag.PadRight(36)
                $color = if ($p.Required) { 'White' } else { 'Gray' }
                Write-Host "    $col $($p.Desc)$tag" -ForegroundColor $color
            }
            Write-Host ''
        }
        if ($def.Examples.Count -gt 0) {
            Write-Host '  EXAMPLES' -ForegroundColor Yellow
            Write-Host ''
            foreach ($ex in $def.Examples) { Write-Host "    $ex" -ForegroundColor DarkGray }
            Write-Host ''
        }
        return
    }

    Show-RocmRollAsciiArt
    Write-Host '  Usage:  rocmroll <command> [--help] [options]' -ForegroundColor White
    Write-Host ''
    Write-Host '  Common commands:' -ForegroundColor Yellow
    Write-Host ''
    foreach ($cmd in @('install','launch','update','doctor','repair','list','remove','cache')) {
        Write-Host ("    {0,-18} {1}" -f $cmd, $defs[$cmd].Synopsis)
    }
    Write-Host ''
    Write-Host '  Advanced commands:' -ForegroundColor Yellow
    Write-Host ''
    foreach ($cmd in @('init','rocm','comfy','logs','config','profile','workspace','patch')) {
        Write-Host ("    {0,-18} {1}" -f $cmd, $defs[$cmd].Synopsis)
    }
    Write-Host ''
    Write-Host '  Tip: rocmroll help <command>  or  rocmroll <command> --help' -ForegroundColor DarkGray
    Write-Host '       rocmroll help options    to list all global flags' -ForegroundColor DarkGray
    Write-Host ''
}

function Assert-CliRequiredOption {
    param(
        [string]$Value,
        [string]$Flag,
        [string]$Command
    )

    if (-not $Value) {
        Write-Host ''
        Write-Host "  ERROR  $Flag is required for 'rocmroll $Command'" -ForegroundColor Red
        Show-RocmRollHelp -Command (($Command -split ' ')[0])
        exit 1
    }
}

function Import-RocmRollModules {
    param([string]$ModulesDir)

    $order = @(
        'RocmRoll.Logging',
        'RocmRoll.Utilities',
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
        'RocmRoll.ComfyPatch',
        'RocmRoll.Launcher',
        'RocmRoll.Profiles',
        'RocmRoll.Validation',
        'RocmRoll.Repair',
        'RocmRoll.Doctor',
        'RocmRoll.UI',
        'RocmRoll.ComfyDesktop',
        'RocmRoll.Instance',
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

function Initialize-RocmRollCli {
    param([Parameter(Mandatory)][object]$Context)

    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Config.psm1') -Force -Global
    $initCfgArgs = @{ RootFolder = $Context.RootFolder }
    if ($Context.WorkspaceName -and $Context.Command -ne 'workspace') {
        $initCfgArgs['WorkspaceName'] = $Context.WorkspaceName
    }
    Initialize-Config @initCfgArgs | Out-Null

    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
    $logInitArgs = @{
        Level    = $Context.LogLevel
        NoColor  = $Context.FlagNoColor
        Quiet    = $Context.FlagQuiet
        JsonOnly = $Context.FlagJson
    }
    if ($Context.LogFile) { $logInitArgs['LogFile'] = $Context.LogFile }
    Initialize-Logging @logInitArgs
}

function Invoke-RocmRollCommand {
    param([Parameter(Mandatory)][object]$Context)

    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Commands.psm1') -Force -Global

    if ($Context.FlagHelp -and $Context.Command -ne 'help') {
        Show-RocmRollHelp -Command $Context.Command
        exit 0
    }

    switch ($Context.Command) {
        'init'      { Invoke-RocmRollInitCommand -Context $Context }
        'install'   {
            if ($Context.SubCommand) {
                Write-Host ''
                Write-Host "  ERROR  Unknown install sub-command: '$($Context.SubCommand)'" -ForegroundColor Red
                Write-Host ''
                Write-Host "  Use 'rocmroll comfy ...' for ComfyUI operations." -ForegroundColor DarkGray
                Write-Host "  Use 'rocmroll rocm  ...' for ROCm information." -ForegroundColor DarkGray
                Write-Host "  Run 'rocmroll install --help' for full install options." -ForegroundColor DarkGray
                Write-Host ''
                exit 1
            }
            Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'install'
            Invoke-RocmRollInstallCommand -Context $Context
        }
        'rocm'      {
            Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'rocm'
            Invoke-RocmRollRocmCommand -Context $Context
        }
        'comfy'     {
            Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'comfy'
            if ($Context.SubCommand -eq 'add-node') {
                Assert-CliRequiredOption -Value $Context.Url -Flag '--url' -Command 'comfy'
            }
            Invoke-RocmRollComfyCommand -Context $Context
        }
        'launch'    { Invoke-RocmRollLaunchCommand -Context $Context }
        'update'    {
            Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'update'
            Invoke-RocmRollUpdateCommand -Context $Context
        }
        'doctor'    { Invoke-RocmRollDoctorCommand -Context $Context }
        'repair'    {
            Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'repair'
            Invoke-RocmRollRepairCommand -Context $Context
        }
        'list'      { Invoke-RocmRollListCommand -Context $Context }
        'remove'    {
            Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'remove'
            Invoke-RocmRollRemoveCommand -Context $Context
        }
        'cache'     { Invoke-RocmRollCacheCommand -Context $Context }
        'logs'      { Invoke-RocmRollLogsCommand -Context $Context }
        'config'    { Invoke-RocmRollConfigCommand -Context $Context }
        'profile'   {
            if ($Context.SubCommand -in @('show','remove')) {
                Assert-CliRequiredOption -Value $Context.ProfileName -Flag '--profile' -Command "profile $($Context.SubCommand)"
            }
            Invoke-RocmRollProfileCommand -Context $Context
        }
        'patch'     {
            if ($Context.SubCommand -eq 'apply') {
                Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'patch apply'
            } elseif ($Context.SubCommand -eq 'remove') {
                Assert-CliRequiredOption -Value $Context.InstanceName -Flag '--instance' -Command 'patch remove'
                Assert-CliRequiredOption -Value $Context.PatchId -Flag '--patch-id' -Command 'patch remove'
            }
            Invoke-RocmRollPatchCommand -Context $Context
        }
        'workspace' {
            if ($Context.SubCommand -in @('show','edit','remove','init')) {
                Assert-CliRequiredOption -Value $Context.WorkspaceName -Flag '--workspace' -Command "workspace $($Context.SubCommand)"
            }
            Invoke-RocmRollWorkspaceCommand -Context $Context
        }
        'help'      { Invoke-RocmRollHelpCommand -Context $Context }
        default {
            Write-Host ''
            Write-Host "  ERROR  Unknown command: '$($Context.Command)'" -ForegroundColor Red
            Write-Host ''
            Write-Host "  Run 'rocmroll help' for a command list." -ForegroundColor DarkGray
            Write-Host "  Run 'rocmroll help <command>' for detailed usage." -ForegroundColor DarkGray
            Write-Host ''
            exit 1
        }
    }
}

Export-ModuleMember -Function New-CliContext, Initialize-RocmRollCli,
    Invoke-RocmRollCommand, Assert-CliRequiredOption, Show-RocmRollHelp,
    Import-RocmRollModules
