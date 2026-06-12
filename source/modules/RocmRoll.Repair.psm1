#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Repair - Component-scoped repair operations.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RepairComponent {
    param(
        [string]$InstanceName,
        [ValidateSet('python-runtime','python-env','rocm','comfyui','custom-nodes','launchers','patches','all')]
        [string]$Component = 'all',
        [string]$RollbackPatch = '',
        [string]$ProfileName = '',
        [switch]$SharedWorkflows
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')   -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')    -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $state = Get-InstanceState -Name $InstanceName
    if (-not $state) { throw "ROCMROLL-REPAIR-001: Instance '$InstanceName' not found in state." }

    Write-LogInfo "Repairing instance '$InstanceName' component: $Component" -Comp 'RocmRoll.Repair' -Inst $InstanceName

    $repairRuntime = { 
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Runtime.psm1') -Force
        Invoke-CreatePythonRuntime -Version $state.environment -Force | Out-Null
    }

    $repairEnv = {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force
        Invoke-CreateEnvironment -Name $state.environment -Force | Out-Null
        # Re-apply instance binding - rebuilding the env resets python312._pth to the base template
        Set-EnvironmentInstancePath -EnvironmentName $state.environment -InstanceName $InstanceName
    }

    $repairRocm = {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Rocm.psm1') -Force
        $envState = Get-EnvironmentState -Name $state.environment
        $channelProperty = $state.PSObject.Properties['channel']
        $channel = if ($channelProperty -and $channelProperty.Value) { [string]$channelProperty.Value } else { 'stable' }
        $rocmProfile = Get-RocmProfileForChannel -Channel $channel
        $runtimeVersion = if ($envState -and $envState.runtimeVersion) { [string]$envState.runtimeVersion } else { '' }
        Invoke-InstallRocm -EnvironmentName $state.environment -RocmIndex $envState.gpu.rocmIndex `
            -RocmProfile $rocmProfile -Channel $channel -PythonVersion $runtimeVersion -Force | Out-Null
    }

    $repairComfyUI = {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ComfyUI.psm1') -Force
        Invoke-InstallComfyDeps -InstanceName $InstanceName -EnvironmentName $state.environment
        Invoke-GenerateExtraModelPaths -InstanceName $InstanceName
        if ($SharedWorkflows) {
            Invoke-LinkSharedWorkflows -InstanceName $InstanceName
        }
    }

    $repairNodes = {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.CustomNodes.psm1') -Force
        Invoke-InstallCustomNodes -InstanceName $InstanceName -EnvironmentName $state.environment -Update
    }

    $repairLaunchers = {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Launcher.psm1')     -Force
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1')  -Force
        $envState = Get-EnvironmentState -Name $state.environment
        $gfxVersion = ''
        if ($envState -and $envState.gpu) {
            $gfxProperty = $envState.gpu.PSObject.Properties['gfx']
            if ($gfxProperty -and $gfxProperty.Value) {
                $gfxVersion = $gfxProperty.Value
            }
        }
        $channelProperty = $state.PSObject.Properties['channel']
        $repairChannel = if ($channelProperty -and $channelProperty.Value) { [string]$channelProperty.Value } else { 'stable' }
        Invoke-GenerateLaunchers -InstanceName $InstanceName -EnvironmentName $state.environment `
            -GfxVersion $gfxVersion -Channel $repairChannel -ProfileName $ProfileName
        Set-EnvironmentInstancePath -EnvironmentName $state.environment -InstanceName $InstanceName
    }

    switch ($Component) {
        'python-runtime' { & $repairRuntime }
        'python-env'     { & $repairEnv }
        'rocm'           { & $repairRocm }
        'comfyui'        { & $repairComfyUI }
        'custom-nodes'   { & $repairNodes }
        'launchers'      { & $repairLaunchers }
        'patches'        { Write-LogInfo "Re-applying patches (not yet automated)" -Comp 'RocmRoll.Repair' }
        'all' {
            & $repairEnv
            & $repairRocm
            & $repairComfyUI
            & $repairNodes
            & $repairLaunchers
        }
    }

    if ($RollbackPatch) {
        Invoke-RollbackPatch -InstanceName $InstanceName -PatchId $RollbackPatch
    }

    Write-LogSuccess "Repair complete for '$InstanceName' component: $Component" -Comp 'RocmRoll.Repair'
}

function Invoke-RollbackPatch {
    param([string]$InstanceName, [string]$PatchId)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg       = Get-Config
    $envState  = Get-EnvironmentState -Name (Get-InstanceState -Name $InstanceName).environment
    $envFolder = $envState.path
    $backupDir = Join-Path $cfg.PatchStateFolder $PatchId

    if (-not (Test-Path $backupDir)) {
        throw "ROCMROLL-PATCH-001: No backup found for patch '$PatchId' at $backupDir"
    }

    $backups = Get-ChildItem $backupDir -File
    foreach ($b in $backups) {
        $relPath    = $b.Name -replace '---', '\'
        $targetFile = Join-Path $envFolder $relPath
        $targetDir  = Split-Path $targetFile -Parent
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        Copy-Item $b.FullName $targetFile -Force
        Write-LogInfo "Restored: $relPath" -Comp 'RocmRoll.Repair'
    }
    Write-LogSuccess "Patch '$PatchId' rolled back." -Comp 'RocmRoll.Repair'
}

Export-ModuleMember -Function Invoke-RepairComponent, Invoke-RollbackPatch
