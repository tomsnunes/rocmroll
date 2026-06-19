#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Cli - CLI context, help, imports, and registry dispatch.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CliOption {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Value,
        [switch]$Required,
        [string]$Meta = '',
        [string]$Desc = '',
        [string]$Default = ''
    )

    return [ordered]@{
        Name     = $Name
        Value    = [bool]$Value
        Required = [bool]$Required
        Meta     = $Meta
        Desc     = $Desc
        Default  = $Default
    }
}

function New-CliSubCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Synopsis,
        [Parameter(Mandatory)][string]$Usage,
        [object[]]$Options = @(),
        [object[]]$Examples = @(),
        [string]$Handler = ''
    )

    return [ordered]@{
        Name     = $Name
        Synopsis = $Synopsis
        Usage    = $Usage
        Options  = $Options
        Examples = $Examples
        Handler  = $Handler
    }
}

function Get-RocmRollGlobalOptionDefinitions {
    return @(
        New-CliOption -Name 'help' -Desc 'Show help for the current command'
        New-CliOption -Name 'quiet' -Desc 'Suppress non-error output'
        New-CliOption -Name 'verbose' -Desc 'Show verbose output'
        New-CliOption -Name 'debug' -Desc 'Show debug output'
        New-CliOption -Name 'json' -Desc 'Emit structured JSON output'
        New-CliOption -Name 'no-color' -Desc 'Disable colour output'
        New-CliOption -Name 'log-level' -Value -Meta 'LEVEL' -Desc 'Set log level'
        New-CliOption -Name 'log-file' -Value -Meta 'PATH' -Desc 'Write log to file'
    )
}

function Get-RocmRollCommandDefinitions {
    $workspaceOpt = New-CliOption -Name 'workspace' -Value -Meta 'NAME' -Desc 'Select a specific workspace'
    $workspaceNameReq = New-CliOption -Name 'name' -Value -Required -Meta 'NAME' -Desc 'Workspace name'
    $workspaceNameOpt = New-CliOption -Name 'name' -Value -Meta 'NAME' -Desc 'Workspace name'
    $nameReq = New-CliOption -Name 'name' -Value -Required -Meta 'NAME' -Desc 'Target instance name'
    $nameOpt = New-CliOption -Name 'name' -Value -Meta 'NAME' -Desc 'Target instance name'
    $instanceReq = New-CliOption -Name 'instance' -Value -Required -Meta 'NAME' -Desc 'Target instance name'
    $instanceOpt = New-CliOption -Name 'instance' -Value -Meta 'NAME' -Desc 'Target instance name'
    $envNameReq = New-CliOption -Name 'name' -Value -Required -Meta 'NAME' -Desc 'Environment name'
    $envNameOpt = New-CliOption -Name 'name' -Value -Meta 'NAME' -Desc 'Environment name'
    $profileNameReq = New-CliOption -Name 'name' -Value -Required -Meta 'NAME' -Desc 'Profile name'
    $componentOpts = @(
        New-CliOption -Name 'environment' -Desc 'Select environment component'
        New-CliOption -Name 'rocm' -Desc 'Select ROCm component'
        New-CliOption -Name 'comfyui' -Desc 'Select ComfyUI component'
        New-CliOption -Name 'patches' -Desc 'Select patches component'
        New-CliOption -Name 'all' -Desc 'Select all components'
    )

    return [ordered]@{
        init = [ordered]@{
            Name = 'init'; Synopsis = 'Initialize the ROCmRoll folder structure'; Usage = 'rocmroll init [help]'
            Handler = 'Invoke-RocmRollInitCommand'; DefaultHandler = 'Invoke-RocmRollInitCommand'; Options = @(); Examples = @('rocmroll init')
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show init help' -Usage 'rocmroll init help' -Handler 'ShowHelp'
            }
        }
        instance = [ordered]@{
            Name = 'instance'; Synopsis = 'Manage ComfyUI instances'; Usage = 'rocmroll instance <help|list|info|install|update|remove|launch|repair>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show instance help' -Usage 'rocmroll instance help' -Handler 'ShowHelp'
                list = New-CliSubCommand -Name 'list' -Synopsis 'List current instances' -Usage 'rocmroll instance list [--workspace NAME|--all] [--channel CHANNEL]' -Options @(
                    $workspaceOpt
                    New-CliOption -Name 'channel' -Value -Meta 'CHANNEL' -Desc 'Select a specific install channel'
                    New-CliOption -Name 'all' -Desc 'Select all instances in all workspaces'
                ) -Examples @('rocmroll instance list', 'rocmroll instance list --all') -Handler 'Invoke-RocmRollInstanceCommand'
                info = New-CliSubCommand -Name 'info' -Synopsis 'Show information about an instance' -Usage 'rocmroll instance info --name NAME [--all|--environment|--rocm|--comfyui|--patches]' -Options (@(
                    $nameReq
                    $workspaceOpt
                ) + $componentOpts) -Examples @('rocmroll instance info --name rocm-stable') -Handler 'Invoke-RocmRollInstanceCommand'
                install = New-CliSubCommand -Name 'install' -Synopsis 'Install an instance' -Usage 'rocmroll instance install --name NAME [options]' -Options @(
                    $nameReq
                    $workspaceOpt
                    New-CliOption -Name 'channel' -Value -Meta 'stable|preview|nightly|rdna1|rdna2' -Default 'stable' -Desc 'Select a specific install channel'
                    New-CliOption -Name 'profile' -Value -Meta 'NAME' -Desc 'Select a specific execution profile'
                    New-CliOption -Name 'gfx' -Value -Meta 'ARCH' -Desc 'Override GPU architecture'
                    New-CliOption -Name 'python' -Value -Meta 'VERSION' -Default '3.12.10' -Desc 'Select a specific Python version'
                    New-CliOption -Name 'force' -Desc 'Force remove and reinstall'
                    New-CliOption -Name 'shared-workflows' -Desc 'Enable shared workflows'
                ) -Examples @('rocmroll instance install --name rocm-stable', 'rocmroll instance install --name rocm-nightly --channel nightly') -Handler 'Invoke-RocmRollInstanceCommand'
                update = New-CliSubCommand -Name 'update' -Synopsis 'Update an instance and its components' -Usage 'rocmroll instance update --name NAME [--all|--environment|--rocm|--comfyui] [--force]' -Options (@(
                    $nameReq
                    $workspaceOpt
                    New-CliOption -Name 'force' -Desc 'Force update'
                ) + @(
                    New-CliOption -Name 'environment' -Desc 'Update environment'
                    New-CliOption -Name 'rocm' -Desc 'Update ROCm'
                    New-CliOption -Name 'comfyui' -Desc 'Update ComfyUI'
                    New-CliOption -Name 'all' -Desc 'Update all components'
                )) -Examples @('rocmroll instance update --name rocm-stable') -Handler 'Invoke-RocmRollInstanceCommand'
                remove = New-CliSubCommand -Name 'remove' -Synopsis 'Remove an instance or components' -Usage 'rocmroll instance remove --name NAME (--all|--environment|--rocm|--comfyui|--patches) [--force]' -Options (@(
                    $nameReq
                    $workspaceOpt
                    New-CliOption -Name 'force' -Desc 'Force instance removal'
                ) + $componentOpts) -Examples @('rocmroll instance remove --name rocm-stable --all --force') -Handler 'Invoke-RocmRollInstanceCommand'
                launch = New-CliSubCommand -Name 'launch' -Synopsis 'Launch an instance' -Usage 'rocmroll instance launch [--name NAME] [--profile NAME] [--url HOST] [--port PORT]' -Options @(
                    $nameOpt
                    $workspaceOpt
                    New-CliOption -Name 'profile' -Value -Meta 'NAME' -Desc 'Select a specific execution profile'
                    New-CliOption -Name 'url' -Value -Meta 'HOST' -Desc 'Set custom ComfyUI hostname'
                    New-CliOption -Name 'port' -Value -Meta 'PORT' -Default '8188' -Desc 'Set custom ComfyUI port'
                ) -Examples @('rocmroll instance launch', 'rocmroll instance launch --name rocm-stable --port 8189') -Handler 'Invoke-RocmRollInstanceCommand'
                repair = New-CliSubCommand -Name 'repair' -Synopsis 'Repair an instance or components' -Usage 'rocmroll instance repair --name NAME [--all|--environment|--rocm|--comfyui|--patches]' -Options (@(
                    $nameReq
                    $workspaceOpt
                ) + $componentOpts) -Examples @('rocmroll instance repair --name rocm-stable') -Handler 'Invoke-RocmRollInstanceCommand'
            }
        }
        workspace = [ordered]@{
            Name = 'workspace'; Synopsis = 'Manage named workspaces'; Usage = 'rocmroll workspace <help|list|show|create|use|edit|remove|init>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show workspace help' -Usage 'rocmroll workspace help' -Handler 'ShowHelp'
                init = New-CliSubCommand -Name 'init' -Synopsis 'Export current paths as a workspace' -Usage 'rocmroll workspace init --name NAME' -Options @($workspaceNameReq) -Handler 'Invoke-RocmRollWorkspaceCommand'
                list = New-CliSubCommand -Name 'list' -Synopsis 'List workspaces' -Usage 'rocmroll workspace list' -Handler 'Invoke-RocmRollWorkspaceCommand'
                create = New-CliSubCommand -Name 'create' -Synopsis 'Create a workspace' -Usage 'rocmroll workspace create --name NAME' -Options @($workspaceNameReq) -Handler 'Invoke-RocmRollWorkspaceCommand'
                show = New-CliSubCommand -Name 'show' -Synopsis 'Show a workspace' -Usage 'rocmroll workspace show --name NAME' -Options @($workspaceNameReq) -Handler 'Invoke-RocmRollWorkspaceCommand'
                use = New-CliSubCommand -Name 'use' -Synopsis 'Switch active workspace' -Usage 'rocmroll workspace use --name NAME' -Options @($workspaceNameOpt) -Handler 'Invoke-RocmRollWorkspaceCommand'
                edit = New-CliSubCommand -Name 'edit' -Synopsis 'Edit a workspace' -Usage 'rocmroll workspace edit --name NAME' -Options @($workspaceNameReq) -Handler 'Invoke-RocmRollWorkspaceCommand'
                remove = New-CliSubCommand -Name 'remove' -Synopsis 'Remove a workspace' -Usage 'rocmroll workspace remove --name NAME' -Options @($workspaceNameReq) -Handler 'Invoke-RocmRollWorkspaceCommand'
            }
        }
        doctor = [ordered]@{
            Name = 'doctor'; Synopsis = 'Analyze the runtime, environment and instance to detect problems'; Usage = 'rocmroll doctor [help] [--instance NAME] [--gpu|--rocm|--comfyui|--cache|--system]'
            Handler = 'Invoke-RocmRollDoctorCommand'; DefaultHandler = 'Invoke-RocmRollDoctorCommand'; Options = @(
                $instanceOpt
                $workspaceOpt
                New-CliOption -Name 'gpu' -Desc 'GPU checks only'
                New-CliOption -Name 'rocm' -Desc 'ROCm checks only'
                New-CliOption -Name 'comfyui' -Desc 'ComfyUI checks only'
                New-CliOption -Name 'cache' -Desc 'Cache checks only'
                New-CliOption -Name 'system' -Desc 'System checks only'
            ); Examples = @('rocmroll doctor', 'rocmroll doctor --gpu')
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show doctor help' -Usage 'rocmroll doctor help' -Handler 'ShowHelp'
            }
        }
        rocm = [ordered]@{
            Name = 'rocm'; Synopsis = 'Manage ROCm'; Usage = 'rocmroll rocm <help|info|validate>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show ROCm help' -Usage 'rocmroll rocm help' -Handler 'ShowHelp'
                info = New-CliSubCommand -Name 'info' -Synopsis 'Show ROCm information' -Usage 'rocmroll rocm info --instance NAME' -Options @($instanceReq; $workspaceOpt) -Handler 'Invoke-RocmRollRocmCommand'
                validate = New-CliSubCommand -Name 'validate' -Synopsis 'Validate ROCm' -Usage 'rocmroll rocm validate --instance NAME' -Options @($instanceReq; $workspaceOpt) -Handler 'Invoke-RocmRollRocmCommand'
            }
        }
        comfyui = [ordered]@{
            Name = 'comfyui'; Synopsis = 'Manage ComfyUI'; Usage = 'rocmroll comfyui <help|info|requirements|nodes|update> [--instance NAME]'
            Handler = 'Invoke-RocmRollComfyUiCommand'; DefaultHandler = 'Invoke-RocmRollComfyUiCommand'; Options = @($instanceOpt; $workspaceOpt)
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show ComfyUI help' -Usage 'rocmroll comfyui help' -Handler 'ShowHelp'
                info = New-CliSubCommand -Name 'info' -Synopsis 'Show ComfyUI information' -Usage 'rocmroll comfyui info --instance NAME' -Options @($instanceReq; $workspaceOpt) -Handler 'Invoke-RocmRollComfyUiCommand'
                requirements = New-CliSubCommand -Name 'requirements' -Synopsis 'Install ComfyUI requirements' -Usage 'rocmroll comfyui requirements --instance NAME' -Options @($instanceReq; $workspaceOpt) -Handler 'Invoke-RocmRollComfyUiCommand'
                nodes = New-CliSubCommand -Name 'nodes' -Synopsis 'Manage ComfyUI nodes' -Usage 'rocmroll comfyui nodes --instance NAME [--list|--install|--update|--add URL]' -Options @(
                    $instanceReq
                    $workspaceOpt
                    New-CliOption -Name 'install' -Desc 'Install default custom nodes'
                    New-CliOption -Name 'list' -Desc 'List installed custom nodes'
                    New-CliOption -Name 'update' -Desc 'Update default custom nodes'
                    New-CliOption -Name 'add' -Value -Meta 'URL' -Desc 'Install a custom node from a Git URL'
                ) -Handler 'Invoke-RocmRollComfyUiCommand'
                update = New-CliSubCommand -Name 'update' -Synopsis 'Update ComfyUI source' -Usage 'rocmroll comfyui update --instance NAME' -Options @(
                    $instanceReq
                    $workspaceOpt
                ) -Handler 'Invoke-RocmRollComfyUiCommand'
            }
        }
        cache = [ordered]@{
            Name = 'cache'; Synopsis = 'Manage caches'; Usage = 'rocmroll cache <help|list|verify|clean|prune>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show cache help' -Usage 'rocmroll cache help' -Handler 'ShowHelp'
                list = New-CliSubCommand -Name 'list' -Synopsis 'List cache summary' -Usage 'rocmroll cache list' -Handler 'Invoke-RocmRollCacheCommand'
                verify = New-CliSubCommand -Name 'verify' -Synopsis 'Verify cache' -Usage 'rocmroll cache verify' -Handler 'Invoke-RocmRollCacheCommand'
                clean = New-CliSubCommand -Name 'clean' -Synopsis 'Clean cache' -Usage 'rocmroll cache clean [--all|--temp]' -Options @(New-CliOption -Name 'all' -Desc 'Clean all cache'; New-CliOption -Name 'temp' -Desc 'Clean temp cache') -Handler 'Invoke-RocmRollCacheCommand'
                prune = New-CliSubCommand -Name 'prune' -Synopsis 'Prune old cache files' -Usage 'rocmroll cache prune [--older-than-days N]' -Options @(New-CliOption -Name 'older-than-days' -Value -Meta 'N' -Default '30' -Desc 'Prune cache entries older than N days') -Handler 'Invoke-RocmRollCacheCommand'
            }
        }
        logs = [ordered]@{
            Name = 'logs'; Synopsis = 'Manage logs'; Usage = 'rocmroll logs <help|show|prune>'
            Options = @($workspaceOpt)
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show logs help' -Usage 'rocmroll logs help' -Handler 'ShowHelp'
                show = New-CliSubCommand -Name 'show' -Synopsis 'Show recent log files' -Usage 'rocmroll logs show [--workspace NAME]' -Options @($workspaceOpt) -Handler 'Invoke-RocmRollLogsCommand'
                prune = New-CliSubCommand -Name 'prune' -Synopsis 'Prune old log files' -Usage 'rocmroll logs prune [--workspace NAME]' -Options @($workspaceOpt) -Handler 'Invoke-RocmRollLogsCommand'
            }
        }
        config = [ordered]@{
            Name = 'config'; Synopsis = 'Manage configuration'; Usage = 'rocmroll config <help|show|init>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show config help' -Usage 'rocmroll config help' -Handler 'ShowHelp'
                show = New-CliSubCommand -Name 'show' -Synopsis 'Show configuration' -Usage 'rocmroll config show' -Handler 'Invoke-RocmRollConfigCommand'
                init = New-CliSubCommand -Name 'init' -Synopsis 'Initialize configuration' -Usage 'rocmroll config init' -Handler 'Invoke-RocmRollConfigCommand'
            }
        }
        profile = [ordered]@{
            Name = 'profile'; Synopsis = 'Manage profiles'; Usage = 'rocmroll profile <help|list|apply|show|create|remove>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show profile help' -Usage 'rocmroll profile help' -Handler 'ShowHelp'
                list = New-CliSubCommand -Name 'list' -Synopsis 'List profiles' -Usage 'rocmroll profile list' -Handler 'Invoke-RocmRollProfileCommand'
                apply = New-CliSubCommand -Name 'apply' -Synopsis 'Apply the instance default profile' -Usage 'rocmroll profile apply --instance NAME' -Options @($instanceReq; $workspaceOpt) -Handler 'Invoke-RocmRollProfileCommand'
                show = New-CliSubCommand -Name 'show' -Synopsis 'Show a profile' -Usage 'rocmroll profile show --name NAME' -Options @($profileNameReq) -Handler 'Invoke-RocmRollProfileCommand'
                create = New-CliSubCommand -Name 'create' -Synopsis 'Create a profile' -Usage 'rocmroll profile create --name NAME' -Options @($profileNameReq) -Handler 'Invoke-RocmRollProfileCommand'
                remove = New-CliSubCommand -Name 'remove' -Synopsis 'Remove a profile' -Usage 'rocmroll profile remove --name NAME' -Options @($profileNameReq) -Handler 'Invoke-RocmRollProfileCommand'
            }
        }
        patch = [ordered]@{
            Name = 'patch'; Synopsis = 'Manage patches'; Usage = 'rocmroll patch <help|list|apply|remove>'
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show patch help' -Usage 'rocmroll patch help' -Handler 'ShowHelp'
                list = New-CliSubCommand -Name 'list' -Synopsis 'List patches' -Usage 'rocmroll patch list [--instance NAME]' -Options @($instanceOpt; $workspaceOpt) -Handler 'Invoke-RocmRollPatchCommand'
                apply = New-CliSubCommand -Name 'apply' -Synopsis 'Apply patches' -Usage 'rocmroll patch apply --instance NAME [--patch-id ID]' -Options @($instanceReq; $workspaceOpt; New-CliOption -Name 'patch-id' -Value -Meta 'ID' -Desc 'Target patch ID'; New-CliOption -Name 'gfx' -Value -Meta 'ARCH' -Desc 'Override GPU architecture') -Handler 'Invoke-RocmRollPatchCommand'
                remove = New-CliSubCommand -Name 'remove' -Synopsis 'Remove a patch' -Usage 'rocmroll patch remove --instance NAME --patch-id ID' -Options @($instanceReq; $workspaceOpt; New-CliOption -Name 'patch-id' -Value -Required -Meta 'ID' -Desc 'Target patch ID'; New-CliOption -Name 'gfx' -Value -Meta 'ARCH' -Desc 'Override GPU architecture') -Handler 'Invoke-RocmRollPatchCommand'
            }
        }
        env = [ordered]@{
            Name = 'env'; Synopsis = 'Manage environments'; Usage = 'rocmroll env <help|list|create|edit|remove> [--name NAME]'
            Handler = 'Invoke-RocmRollEnvCommand'; DefaultHandler = 'Invoke-RocmRollEnvCommand'; Options = @($envNameOpt; $workspaceOpt)
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show environment help' -Usage 'rocmroll env help' -Handler 'ShowHelp'
                list = New-CliSubCommand -Name 'list' -Synopsis 'List environments' -Usage 'rocmroll env list [--name NAME]' -Options @($envNameOpt; $workspaceOpt) -Handler 'Invoke-RocmRollEnvCommand'
                create = New-CliSubCommand -Name 'create' -Synopsis 'Create an environment' -Usage 'rocmroll env create --name NAME' -Options @($envNameReq; $workspaceOpt) -Handler 'Invoke-RocmRollEnvCommand'
                edit = New-CliSubCommand -Name 'edit' -Synopsis 'Validate and rebind an environment' -Usage 'rocmroll env edit --name NAME' -Options @($envNameReq; $workspaceOpt) -Handler 'Invoke-RocmRollEnvCommand'
                remove = New-CliSubCommand -Name 'remove' -Synopsis 'Remove an environment' -Usage 'rocmroll env remove --name NAME' -Options @($envNameReq; $workspaceOpt) -Handler 'Invoke-RocmRollEnvCommand'
            }
        }
        state = [ordered]@{
            Name = 'state'; Synopsis = 'Manage state'; Usage = 'rocmroll state <help|show>'
            Options = @($workspaceOpt)
            SubCommands = [ordered]@{
                help = New-CliSubCommand -Name 'help' -Synopsis 'Show state help' -Usage 'rocmroll state help' -Handler 'ShowHelp'
                show = New-CliSubCommand -Name 'show' -Synopsis 'Show state summary' -Usage 'rocmroll state show [--workspace NAME]' -Options @($workspaceOpt) -Handler 'Invoke-RocmRollStateCommand'
            }
        }
    }
}

function Find-CliOptionDefinition {
    param([object[]]$Options, [string]$Name)
    foreach ($opt in $Options) {
        if ($opt.Name -eq $Name) { return $opt }
    }
    return $null
}

function Get-CliCombinedOptions {
    param([object]$Definition, [object]$SubDefinition = $null)
    $options = @(Get-RocmRollGlobalOptionDefinitions)
    if ($Definition -and $Definition.Contains('Options')) { $options += @($Definition.Options) }
    if ($SubDefinition -and $SubDefinition.Contains('Options')) { $options += @($SubDefinition.Options) }
    return $options
}

function New-CliParsedOptions {
    return [PSCustomObject][ordered]@{
        Values = @{}
        Flags  = @{}
        Present = @()
    }
}

function Add-CliPresentOption {
    param([object]$ParsedOptions, [string]$Name)
    if ($ParsedOptions.Present -notcontains $Name) {
        $ParsedOptions.Present += $Name
    }
}

function Parse-CliOptions {
    param(
        [string[]]$ArgList,
        [object[]]$Options
    )

    $parsed = New-CliParsedOptions
    $positionals = @()
    $errors = @()
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $arg = $ArgList[$i]
        if ($arg -like '--*') {
            $name = $arg.Substring(2)
            $opt = Find-CliOptionDefinition -Options $Options -Name $name
            if (-not $opt) {
                $errors += "Unknown option: --$name"
                continue
            }
            Add-CliPresentOption -ParsedOptions $parsed -Name $name
            if ($opt.Value) {
                if ($i -ge ($ArgList.Count - 1) -or $ArgList[$i + 1] -like '--*') {
                    $errors += "Option --$name requires a value"
                    continue
                }
                $parsed.Values[$name] = $ArgList[$i + 1]
                $i++
            } else {
                $parsed.Flags[$name] = $true
            }
        } elseif ($arg -like '-*') {
            $errors += "Unknown option: $arg"
        } else {
            $positionals += $arg
        }
    }

    if ($parsed.Present -notcontains 'help') {
        foreach ($opt in $Options) {
            if ($opt.Required -and $parsed.Present -notcontains $opt.Name) {
                $meta = if ($opt.Meta) { " $($opt.Meta)" } else { '' }
                $errors += "Missing required option: --$($opt.Name)$meta"
            }
        }
    }

    return [PSCustomObject][ordered]@{
        Options = $parsed
        Positionals = $positionals
        Errors = $errors
    }
}

function Test-CliFlag {
    param([object]$ParsedOptions, [string]$Name)
    return $ParsedOptions.Flags.ContainsKey($Name)
}

function Get-CliValue {
    param([object]$ParsedOptions, [string]$Name, [string]$Default = '')
    if ($ParsedOptions.Values.ContainsKey($Name)) { return [string]$ParsedOptions.Values[$Name] }
    return $Default
}

function Get-CliComponentScopes {
    param([object]$ParsedOptions, [string[]]$Names)
    $scopes = @()
    foreach ($name in $Names) {
        if (Test-CliFlag -ParsedOptions $ParsedOptions -Name $name) { $scopes += $name }
    }
    return $scopes
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
    $defs = Get-RocmRollCommandDefinitions
    $rootCommand = if ($Command) { $Command.ToLowerInvariant() } else { 'help' }
    $parseErrors = @()
    $definition = $null
    $subDefinition = $null
    $subCommand = ''
    $handler = ''
    $helpTarget = ''
    $helpRequested = $false
    $parsedOptions = New-CliParsedOptions

    if ($rootCommand -eq 'help') {
        $helpTarget = ($RemainingArgs | Where-Object { $_ -notlike '--*' }) -join ' '
        $parsed = Parse-CliOptions -ArgList @($RemainingArgs | Where-Object { $_ -like '--*' }) -Options @(Get-RocmRollGlobalOptionDefinitions)
        $parsedOptions = $parsed.Options
        $parseErrors += $parsed.Errors
        $handler = 'Invoke-RocmRollHelpCommand'
    } elseif (-not $defs.Contains($rootCommand)) {
        $parseErrors += "Unknown command: '$rootCommand'"
    } else {
        $definition = $defs[$rootCommand]
        $argsToParse = @($RemainingArgs)
        if ($definition.Contains('SubCommands')) {
            if ($argsToParse.Count -gt 0 -and $argsToParse[0] -notlike '-*') {
                $subCommand = $argsToParse[0].ToLowerInvariant()
                $argsToParse = @($argsToParse | Select-Object -Skip 1)
                if ($subCommand -eq 'help') {
                    $helpRequested = $true
                } elseif ($definition.SubCommands.Contains($subCommand)) {
                    $subDefinition = $definition.SubCommands[$subCommand]
                    $handler = $subDefinition.Handler
                } else {
                    $parseErrors += "Unknown $rootCommand subcommand: '$subCommand'"
                }
            } else {
                if ($definition.Contains('DefaultHandler') -and $definition.DefaultHandler) {
                    $handler = $definition.DefaultHandler
                } else {
                    $helpRequested = $true
                }
            }

            if ($helpRequested) {
                $subDefinition = if ($subCommand -and $definition.SubCommands.Contains($subCommand)) { $definition.SubCommands[$subCommand] } else { $null }
                $handler = 'ShowHelp'
            }
        } else {
            $handler = $definition.Handler
        }

        $options = Get-CliCombinedOptions -Definition $definition -SubDefinition $subDefinition
        $parsed = Parse-CliOptions -ArgList $argsToParse -Options $options
        $parsedOptions = $parsed.Options
        $parseErrors += $parsed.Errors
        if ($parsed.Positionals.Count -gt 0) {
            $parseErrors += "Unexpected positional argument: $($parsed.Positionals[0])"
        }
        if (Test-CliFlag -ParsedOptions $parsedOptions -Name 'help') {
            $helpRequested = $true
            $handler = 'ShowHelp'
        }
    }

    if ($rootCommand -eq 'instance' -and $subCommand -eq 'list' -and
        (Test-CliFlag -ParsedOptions $parsedOptions -Name 'all') -and
        (Get-CliValue -ParsedOptions $parsedOptions -Name 'workspace')) {
        $parseErrors += 'Options --all and --workspace cannot be used together for instance list'
    }

    if ($rootCommand -eq 'instance' -and $subCommand -eq 'remove' -and -not (Test-CliFlag -ParsedOptions $parsedOptions -Name 'help')) {
        $removeScopes = @(Get-CliComponentScopes -ParsedOptions $parsedOptions -Names @('environment','rocm','comfyui','patches','all'))
        if ($removeScopes.Count -eq 0) {
            $parseErrors += 'instance remove requires --all or at least one component flag'
        }
    }

    $flagDebug = Test-CliFlag -ParsedOptions $parsedOptions -Name 'debug'
    $flagVerbose = Test-CliFlag -ParsedOptions $parsedOptions -Name 'verbose'
    $logLevel = Get-CliValue -ParsedOptions $parsedOptions -Name 'log-level'
    if (-not $logLevel) { $logLevel = if ($flagDebug -or $flagVerbose) { 'DEBUG' } else { 'INFO' } }

    $nameValue = Get-CliValue -ParsedOptions $parsedOptions -Name 'name'
    $instanceValue = Get-CliValue -ParsedOptions $parsedOptions -Name 'instance'
    $instanceName = if ($instanceValue) { $instanceValue } else { $nameValue }
    $profileOption = Get-CliValue -ParsedOptions $parsedOptions -Name 'profile'
    $profileName = if ($profileOption) {
        $profileOption
    } elseif ($rootCommand -eq 'profile') {
        $nameValue
    } else {
        ''
    }
    $channel = Get-CliValue -ParsedOptions $parsedOptions -Name 'channel'
    if (-not $channel -and $rootCommand -eq 'instance' -and $subCommand -eq 'install') {
        $channel = 'stable'
    }
    $pythonVersion = Get-CliValue -ParsedOptions $parsedOptions -Name 'python' -Default '3.12.10'
    $componentScopes = @(Get-CliComponentScopes -ParsedOptions $parsedOptions -Names @('environment','rocm','comfyui','patches','all'))
    if ($rootCommand -eq 'instance' -and $subCommand -in @('info','update','repair') -and $componentScopes.Count -eq 0) {
        $componentScopes = @('all')
    }

    return [PSCustomObject][ordered]@{
        Command             = $rootCommand
        SubCommand          = $subCommand
        CommandPath         = (@($rootCommand, $subCommand) | Where-Object { $_ }) -join ' '
        Handler             = $handler
        HelpRequested       = $helpRequested
        HelpTarget          = $helpTarget
        Definition          = $definition
        SubDefinition       = $subDefinition
        ParseErrors         = $parseErrors
        ParsedOptions       = $parsedOptions
        RemainingArgs       = $RemainingArgs
        ScriptRoot          = $ScriptRoot
        RootFolder          = $rootFolder
        ModulesDir          = $modulesDir

        WorkspaceName       = Get-CliValue -ParsedOptions $parsedOptions -Name 'workspace'
        NameArg             = $nameValue
        InstanceArg         = $instanceValue
        WorkspaceTargetName = $nameValue
        InstanceName        = $instanceName
        Channel             = $channel
        PythonVersion       = $pythonVersion
        GfxOverride         = Get-CliValue -ParsedOptions $parsedOptions -Name 'gfx'
        Component           = if ($componentScopes.Count -eq 1) { $componentScopes[0] } else { '' }
        ComponentScopes     = $componentScopes
        RollbackPatch       = ''
        LogLevel            = $logLevel
        LogFile             = Get-CliValue -ParsedOptions $parsedOptions -Name 'log-file'
        EnvName             = $nameValue
        OlderThanDays       = Get-CliValue -ParsedOptions $parsedOptions -Name 'older-than-days'
        PortArg             = Get-CliValue -ParsedOptions $parsedOptions -Name 'port'
        ProfileName         = $profileName
        PatchId             = Get-CliValue -ParsedOptions $parsedOptions -Name 'patch-id'
        Url                 = Get-CliValue -ParsedOptions $parsedOptions -Name 'url'
        AddUrl              = Get-CliValue -ParsedOptions $parsedOptions -Name 'add'

        FlagForce           = Test-CliFlag -ParsedOptions $parsedOptions -Name 'force'
        FlagQuiet           = Test-CliFlag -ParsedOptions $parsedOptions -Name 'quiet'
        FlagVerbose         = $flagVerbose
        FlagDebug           = $flagDebug
        FlagJson            = Test-CliFlag -ParsedOptions $parsedOptions -Name 'json'
        FlagNoColor         = Test-CliFlag -ParsedOptions $parsedOptions -Name 'no-color'
        FlagGpuOnly         = Test-CliFlag -ParsedOptions $parsedOptions -Name 'gpu'
        FlagCacheOnly       = Test-CliFlag -ParsedOptions $parsedOptions -Name 'cache'
        FlagSystemOnly      = Test-CliFlag -ParsedOptions $parsedOptions -Name 'system'
        FlagHelp            = Test-CliFlag -ParsedOptions $parsedOptions -Name 'help'
        FlagAll             = Test-CliFlag -ParsedOptions $parsedOptions -Name 'all'
        FlagEnvironment     = Test-CliFlag -ParsedOptions $parsedOptions -Name 'environment'
        FlagRocm            = Test-CliFlag -ParsedOptions $parsedOptions -Name 'rocm'
        FlagComfyUi         = Test-CliFlag -ParsedOptions $parsedOptions -Name 'comfyui'
        FlagPatches         = Test-CliFlag -ParsedOptions $parsedOptions -Name 'patches'
        FlagInstall         = Test-CliFlag -ParsedOptions $parsedOptions -Name 'install'
        FlagList            = Test-CliFlag -ParsedOptions $parsedOptions -Name 'list'
        FlagUpdate          = Test-CliFlag -ParsedOptions $parsedOptions -Name 'update'
        FlagNodes           = Test-CliFlag -ParsedOptions $parsedOptions -Name 'nodes'
        FlagSharedWorkflows = Test-CliFlag -ParsedOptions $parsedOptions -Name 'shared-workflows'
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

function Show-CliDefinitionHelp {
    param(
        [Parameter(Mandatory)][object]$Definition,
        [object]$SubDefinition = $null
    )

    $title = if ($SubDefinition) {
        "ROCMROLL $($Definition.Name.ToUpper()) $($SubDefinition.Name.ToUpper())"
    } else {
        "ROCMROLL $($Definition.Name.ToUpper())"
    }
    $helpDef = if ($SubDefinition) { $SubDefinition } else { $Definition }

    Write-Host ''
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $($helpDef.Synopsis)" -ForegroundColor White
    Write-Host ''
    Write-Host '  USAGE' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    $($helpDef.Usage)"
    Write-Host ''

    if ((-not $SubDefinition) -and $Definition.Contains('SubCommands')) {
        Write-Host '  COMMANDS' -ForegroundColor Yellow
        Write-Host ''
        foreach ($cmd in $Definition.SubCommands.GetEnumerator()) {
            Write-Host ("    {0,-18} {1}" -f $cmd.Key, $cmd.Value.Synopsis) -ForegroundColor Gray
        }
        Write-Host ''
    }

    $optionsToShow = @()
    if ($SubDefinition -and $SubDefinition.Contains('Options')) {
        $optionsToShow = @($SubDefinition.Options)
    } elseif ((-not $SubDefinition) -and $Definition.Contains('Options')) {
        $optionsToShow = @($Definition.Options)
    }

    if ($optionsToShow.Count -gt 0) {
        Write-Host '  OPTIONS' -ForegroundColor Yellow
        Write-Host ''
        foreach ($opt in $optionsToShow) {
            $flag = "--$($opt.Name)"
            if ($opt.Meta) { $flag = "$flag $($opt.Meta)" }
            $tag = if ($opt.Required) { ' (required)' } elseif ($opt.Default) { " (default: $($opt.Default))" } else { '' }
            Write-Host ("    {0,-34} {1}{2}" -f $flag, $opt.Desc, $tag) -ForegroundColor Gray
        }
        Write-Host ''
    }

    if ($helpDef.Contains('Examples') -and $helpDef.Examples.Count -gt 0) {
        Write-Host '  EXAMPLES' -ForegroundColor Yellow
        Write-Host ''
        foreach ($ex in $helpDef.Examples) { Write-Host "    $ex" -ForegroundColor DarkGray }
        Write-Host ''
    }
}

function Show-RocmRollHelp {
    param([string]$Command = '')

    $defs = Get-RocmRollCommandDefinitions
    $parts = @()
    if ($Command) { $parts = @($Command -split '\s+' | Where-Object { $_ }) }

    if ($parts.Count -gt 0 -and $parts[0] -eq 'options') {
        Write-Host ''
        Write-Host '  GLOBAL OPTIONS' -ForegroundColor Cyan
        Write-Host ''
        foreach ($opt in Get-RocmRollGlobalOptionDefinitions) {
            $flag = "--$($opt.Name)"
            if ($opt.Meta) { $flag = "$flag $($opt.Meta)" }
            Write-Host ("    {0,-26}  {1}" -f $flag, $opt.Desc) -ForegroundColor Gray
        }
        Write-Host ''
        return
    }

    if ($parts.Count -gt 0 -and $defs.Contains($parts[0])) {
        $def = $defs[$parts[0]]
        if ($parts.Count -gt 1 -and $def.Contains('SubCommands') -and $def.SubCommands.Contains($parts[1])) {
            Show-CliDefinitionHelp -Definition $def -SubDefinition $def.SubCommands[$parts[1]]
        } else {
            Show-CliDefinitionHelp -Definition $def
        }
        return
    }

    Show-RocmRollAsciiArt
    Write-Host '  Usage:  rocmroll <command> [subcommand] [options]' -ForegroundColor White
    Write-Host ''
    Write-Host '  Commands:' -ForegroundColor Yellow
    Write-Host ''
    foreach ($cmd in $defs.GetEnumerator()) {
        Write-Host ("    {0,-18} {1}" -f $cmd.Key, $cmd.Value.Synopsis)
    }
    Write-Host ''
    Write-Host '  Tip: rocmroll help <command>  or  rocmroll <command> --help' -ForegroundColor DarkGray
    Write-Host '       rocmroll help options    to list global flags' -ForegroundColor DarkGray
    Write-Host ''
}

function Initialize-RocmRollCli {
    param([Parameter(Mandatory)][object]$Context)

    $global:RocmRollConfigRootFolder = $Context.RootFolder
    $global:RocmRollConfigWorkspaceOverride = if ($Context.WorkspaceName -and $Context.Command -ne 'workspace') {
        $Context.WorkspaceName
    } else {
        ''
    }

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

function Test-RocmRollProfileName {
    param(
        [string]$ProfileName,
        [string]$ModulesDir
    )

    if (-not $ProfileName) { return }

    Import-Module (Join-Path $ModulesDir 'RocmRoll.Profiles.psm1') -Global
    $cfg = Get-Config
    $profilePath = Join-Path $cfg.ProfilesFolder "$ProfileName.json"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Write-Host ''
        Write-Host "  ERROR  Unknown profile: '$ProfileName'" -ForegroundColor Red
        Write-Host "  Run 'rocmroll profile list' to see available profiles." -ForegroundColor DarkGray
        Write-Host ''
        exit 1
    }
}

function Invoke-CliParseErrors {
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.ParseErrors.Count -eq 0) { return }
    Write-Host ''
    foreach ($err in $Context.ParseErrors) {
        Write-Host "  ERROR  $err" -ForegroundColor Red
    }
    Write-Host ''
    if ($Context.Command -and $Context.Command -ne 'help') {
        Show-RocmRollHelp -Command $Context.CommandPath
    } else {
        Show-RocmRollHelp
    }
    exit 1
}

function Invoke-RocmRollCommand {
    param([Parameter(Mandatory)][object]$Context)

    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Commands.psm1') -Force -Global

    Invoke-CliParseErrors -Context $Context

    if ($Context.Handler -eq 'ShowHelp') {
        $target = if ($Context.SubCommand -eq 'help') { $Context.Command } else { $Context.CommandPath }
        Show-RocmRollHelp -Command $target
        exit 0
    }

    if ($Context.ProfileName -and $Context.Command -eq 'instance' -and $Context.SubCommand -in @('install','launch')) {
        Test-RocmRollProfileName -ProfileName $Context.ProfileName -ModulesDir $Context.ModulesDir
    }

    switch ($Context.Handler) {
        'Invoke-RocmRollInitCommand'      { Invoke-RocmRollInitCommand -Context $Context }
        'Invoke-RocmRollInstanceCommand'  { Invoke-RocmRollInstanceCommand -Context $Context }
        'Invoke-RocmRollDoctorCommand'    { Invoke-RocmRollDoctorCommand -Context $Context }
        'Invoke-RocmRollRocmCommand'      { Invoke-RocmRollRocmCommand -Context $Context }
        'Invoke-RocmRollComfyUiCommand'   { Invoke-RocmRollComfyUiCommand -Context $Context }
        'Invoke-RocmRollCacheCommand'     { Invoke-RocmRollCacheCommand -Context $Context }
        'Invoke-RocmRollEnvCommand'       { Invoke-RocmRollEnvCommand -Context $Context }
        'Invoke-RocmRollStateCommand'     { Invoke-RocmRollStateCommand -Context $Context }
        'Invoke-RocmRollLogsCommand'      { Invoke-RocmRollLogsCommand -Context $Context }
        'Invoke-RocmRollConfigCommand'    { Invoke-RocmRollConfigCommand -Context $Context }
        'Invoke-RocmRollProfileCommand'   { Invoke-RocmRollProfileCommand -Context $Context }
        'Invoke-RocmRollPatchCommand'     { Invoke-RocmRollPatchCommand -Context $Context }
        'Invoke-RocmRollWorkspaceCommand' { Invoke-RocmRollWorkspaceCommand -Context $Context }
        'Invoke-RocmRollHelpCommand'      { Invoke-RocmRollHelpCommand -Context $Context }
        default {
            Show-RocmRollHelp -Command $Context.CommandPath
            exit 0
        }
    }
}

Export-ModuleMember -Function New-CliContext, Initialize-RocmRollCli,
    Invoke-RocmRollCommand, Show-RocmRollHelp
