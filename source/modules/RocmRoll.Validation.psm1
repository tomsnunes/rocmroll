#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Validation - Instance health checks and component validation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ValidateInstance {
    param([string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')       -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg            = Get-Config
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
    $state          = Get-InstanceState -Name $InstanceName
    $checks         = [System.Collections.Generic.List[hashtable]]::new()

    $Add = {
        param([string]$Name, [bool]$Passed, [string]$Detail='')
        $checks.Add(@{ check=$Name; passed=$Passed; detail=$Detail })
        if ($Passed) {
            Write-LogSuccess "  [OK] $Name" -Comp 'RocmRoll.Validation'
        } else {
            Write-LogError   "  [FAIL] ${Name}: $Detail" -Comp 'RocmRoll.Validation'
        }
    }

    # Instance folder
    & $Add 'instance_folder_exists' (Test-Path $instanceFolder) $instanceFolder

    # main.py
    & $Add 'comfyui_main_exists' (Test-Path (Join-Path $instanceFolder 'main.py')) ''

    # extra_model_paths.yaml
    & $Add 'extra_model_paths_exists' (Test-Path (Join-Path $instanceFolder 'extra_model_paths.yaml')) ''

    # Environment
    if ($state -and $state.environment) {
        $envOk = Test-EnvironmentIntegrity -Name $state.environment
        & $Add 'environment_python_ok' $envOk $state.environment
    } else {
        & $Add 'environment_state_exists' $false 'No environment in instance state'
    }

    # Launchers
    & $Add 'launch_ps1_exists' (Test-Path (Join-Path $cfg.LaunchersFolder "$InstanceName.ps1")) ''
    & $Add 'launch_bat_exists' (Test-Path (Join-Path $cfg.LaunchersFolder "$InstanceName.bat")) ''

    # Shared models folder
    & $Add 'shared_models_folder_exists' (Test-Path $cfg.SharedModelsFolder) $cfg.SharedModelsFolder

    # Shared I/O folders
    foreach ($dir in @($cfg.InputFolder, $cfg.OutputFolder)) {
        & $Add "shared_folder_$(Split-Path $dir -Leaf)_exists" (Test-Path $dir) $dir
    }

    # Shared temp folder
    & $Add 'shared_folder_temp_exists' (Test-Path $cfg.TempDataFolder) $cfg.TempDataFolder

    $allPassed = -not ($checks | Where-Object { -not $_.passed })
    return @{ passed=$allPassed; instance=$InstanceName; checks=($checks | ForEach-Object { $_ }) }
}

Export-ModuleMember -Function Invoke-ValidateInstance
