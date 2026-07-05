#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Repair - Component-scoped repair operations.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepairRuntimeVersion {
    param(
        [object]$EnvironmentState,
        [hashtable]$Config
    )

    if ($EnvironmentState -and $EnvironmentState.PSObject.Properties['runtimeVersion'] -and $EnvironmentState.runtimeVersion) {
        return [string]$EnvironmentState.runtimeVersion
    }
    if ($Config -and $Config.Contains('RuntimeVersion') -and $Config.RuntimeVersion) {
        return [string]$Config.RuntimeVersion
    }
    return '3.12.10'
}

function Invoke-RepairPythonRuntime {
    param(
        [string]$RuntimeVersion
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Runtime.psm1') -Force
    Invoke-CreatePythonRuntime -Version $RuntimeVersion -Force | Out-Null
}

function Invoke-RepairPythonEnvironment {
    param(
        [string]$EnvironmentName,
        [string]$RuntimeVersion,
        [string]$InstanceName
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force
    Invoke-CreateEnvironment -Name $EnvironmentName -RuntimeVersion $RuntimeVersion -Force | Out-Null
    Set-EnvironmentInstancePath -EnvironmentName $EnvironmentName -InstanceName $InstanceName
}

function Resolve-RepairRocmIndex {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName,
        [hashtable]$PreRepairGpu
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Hardware.psm1') -Force
    $envState = Get-EnvironmentState -Name $EnvironmentName
    $rocmIndex = ''
    if ($envState -and $envState.gpu) {
        $prop = $envState.gpu.PSObject.Properties['rocmIndex']
        if ($prop -and $prop.Value) { $rocmIndex = [string]$prop.Value }
    }
    if (-not $rocmIndex -and $PreRepairGpu.ContainsKey('rocmIndex') -and $PreRepairGpu['rocmIndex']) {
        $rocmIndex = [string]$PreRepairGpu['rocmIndex']
    }
    if (-not $rocmIndex) {
        Write-LogInfo "rocmIndex not in state; running GPU detection" -Comp 'RocmRoll.Repair' -Inst $InstanceName
        $detectedGpu = Invoke-GpuDetect -Quiet
        if ($detectedGpu.detected -and $detectedGpu.rocmIndex) {
            $rocmIndex = [string]$detectedGpu.rocmIndex
        }
    }
    return $rocmIndex
}

function Resolve-RepairMultiArchChip {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName,
        [hashtable]$PreRepairGpu
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Hardware.psm1') -Force
    $envState = Get-EnvironmentState -Name $EnvironmentName
    $chip = ''
    if ($envState -and $envState.gpu) {
        $prop = $envState.gpu.PSObject.Properties['multiArchChip']
        if ($prop -and $prop.Value) { $chip = [string]$prop.Value }
    }
    if (-not $chip -and $PreRepairGpu.ContainsKey('multiArchChip') -and $PreRepairGpu['multiArchChip']) {
        $chip = [string]$PreRepairGpu['multiArchChip']
    }
    if (-not $chip) {
        Write-LogInfo "multiArchChip not in state; running GPU detection" -Comp 'RocmRoll.Repair' -Inst $InstanceName
        $detectedGpu = Invoke-GpuDetect -Quiet
        if ($detectedGpu.detected -and $detectedGpu.multiArchChip) {
            $chip = [string]$detectedGpu.multiArchChip
        }
    }
    return $chip
}

function Invoke-RepairRocmPackages {
    param(
        [string]$InstanceName,
        [object]$InstanceState,
        [string]$RuntimeVersion,
        [hashtable]$PreRepairGpu
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Rocm.psm1') -Force
    $channelProperty = $InstanceState.PSObject.Properties['channel']
    $channel = if ($channelProperty -and $channelProperty.Value) { [string]$channelProperty.Value } else { 'stable' }
    $rocmProfile = Get-RocmProfileForChannel -Channel $channel
    $rocmIndex = Resolve-RepairRocmIndex -InstanceName $InstanceName `
        -EnvironmentName $InstanceState.environment -PreRepairGpu $PreRepairGpu
    $deviceChip = if ($rocmProfile.source -eq 'multiArch') {
        Resolve-RepairMultiArchChip -InstanceName $InstanceName `
            -EnvironmentName $InstanceState.environment -PreRepairGpu $PreRepairGpu
    } else { '' }

    Invoke-InstallRocm -EnvironmentName $InstanceState.environment -RocmIndex $rocmIndex -DeviceChip $deviceChip `
        -RocmProfile $rocmProfile -Channel $channel -PythonVersion $RuntimeVersion -Force | Out-Null
}

function Invoke-RepairComfyUi {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName,
        [object]$InstanceState,
        [switch]$SharedWorkflows
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ComfyUI.psm1') -Force
    $cfg = Get-Config
    $instancePath = if ($InstanceState -and $InstanceState.PSObject.Properties['path'] -and $InstanceState.path) {
        [string]$InstanceState.path
    } else {
        Join-Path $cfg.InstancesFolder $InstanceName
    }
    if (-not (Test-Path -LiteralPath $instancePath)) {
        $channel = if ($InstanceState -and $InstanceState.PSObject.Properties['channel'] -and $InstanceState.channel) {
            [string]$InstanceState.channel
        } else {
            'stable'
        }
        $channel = Resolve-ChannelName -Channel $channel
        $channels = Get-Content (Join-Path $cfg.ManifestsFolder 'channels.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $channelConfig = $channels.$channel
        if (-not $channelConfig) { throw "ROCMROLL-REPAIR-002: Unknown channel '$channel' for instance '$InstanceName'." }
        Invoke-CloneComfyUIInstance -InstanceName $InstanceName -Repo $channelConfig.comfyui.repo `
            -Ref $channelConfig.comfyui.ref | Out-Null
    }
    Invoke-InstallComfyDeps -InstanceName $InstanceName -EnvironmentName $EnvironmentName
    Invoke-GenerateExtraModelPaths -InstanceName $InstanceName
    if ($SharedWorkflows) {
        Invoke-LinkSharedWorkflows -InstanceName $InstanceName
    }
}

function Invoke-RepairCustomNodes {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.CustomNodes.psm1') -Force
    Invoke-InstallCustomNodes -InstanceName $InstanceName -EnvironmentName $EnvironmentName -Update
}

function Invoke-RepairLaunchers {
    param(
        [string]$InstanceName,
        [object]$InstanceState,
        [string]$ProfileName = ''
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Launcher.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force
    $envState = Get-EnvironmentState -Name $InstanceState.environment
    $gfxVersion = ''
    if ($envState -and $envState.gpu) {
        $gfxProperty = $envState.gpu.PSObject.Properties['gfx']
        if ($gfxProperty -and $gfxProperty.Value) {
            $gfxVersion = $gfxProperty.Value
        }
    }
    $channelProperty = $InstanceState.PSObject.Properties['channel']
    $repairChannel = if ($channelProperty -and $channelProperty.Value) { [string]$channelProperty.Value } else { 'stable' }
    Invoke-GenerateLaunchers -InstanceName $InstanceName -EnvironmentName $InstanceState.environment `
        -GfxVersion $gfxVersion -Channel $repairChannel -ProfileName $ProfileName
    Set-EnvironmentInstancePath -EnvironmentName $InstanceState.environment -InstanceName $InstanceName
}

function Invoke-RepairComfyPatches {
    param(
        [string]$InstanceName,
        [hashtable]$GpuState
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ComfyPatch.psm1') -Force
    $gfx = if ($GpuState.ContainsKey('gfx') -and $GpuState['gfx']) { [string]$GpuState['gfx'] } else { '' }
    Invoke-ApplyAllComfyPatches -InstanceName $InstanceName -GfxOverride $gfx
}

function Update-RocmRollInstanceRepairState {
    param(
        [string]$InstanceName,
        [string]$Component,
        [hashtable]$Config
    )

    $stateFile = Join-Path $Config.InstanceStateFolder "instance-$InstanceName.json"
    $currentState = Read-StateFile -Path $stateFile
    if (-not $currentState) { return }
    $stateHash = ConvertTo-StateHashtable -InputObject $currentState
    $remaining = if ($stateHash.ContainsKey('removedComponents')) { @($stateHash['removedComponents']) } else { @() }
    $repaired = switch ($Component) {
        'python-env' { @('environment') }
        'rocm'       { @('environment','rocm') }
        'comfyui'    { @('comfyui') }
        'patches'    { @('patches') }
        'all'        { @('environment','rocm','comfyui','patches') }
        default      { @() }
    }
    $remaining = @($remaining | Where-Object { $_ -notin $repaired } | Sort-Object -Unique)
    if ($remaining.Count -eq 0) {
        $stateHash['status'] = 'ready'
        if ($stateHash.ContainsKey('removedComponents')) { $stateHash.Remove('removedComponents') }
    } else {
        $stateHash['status'] = 'incomplete'
        $stateHash['removedComponents'] = $remaining
    }
    $stateHash['updatedAt'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Write-StateFile -Path $stateFile -State $stateHash
}

function Invoke-RepairComponent {
    param(
        [string]$InstanceName,
        [ValidateSet('python-runtime','python-env','rocm','comfyui','custom-nodes','launchers','patches','all')]
        [string]$Component = 'all',
        [string]$RollbackPatch = '',
        [string]$ProfileName = '',
        [switch]$SharedWorkflows
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg = Get-Config
    $state = Get-InstanceState -Name $InstanceName
    if (-not $state) { throw "ROCMROLL-REPAIR-001: Instance '$InstanceName' not found in state." }

    Write-LogInfo "Repairing instance '$InstanceName' component: $Component" -Comp 'RocmRoll.Repair' -Inst $InstanceName

    $preRepairEnvState = Get-EnvironmentState -Name $state.environment
    $preRepairGpu = ConvertTo-StateHashtable -InputObject $(if ($preRepairEnvState) { $preRepairEnvState.gpu } else { $null })
    $runtimeVersion = Get-RepairRuntimeVersion -EnvironmentState $preRepairEnvState -Config $cfg
    $preRepairEnvPath = if ($preRepairEnvState -and $preRepairEnvState.PSObject.Properties['path']) { [string]$preRepairEnvState.path } else { '' }

    switch ($Component) {
        'python-runtime' { Invoke-RepairPythonRuntime -RuntimeVersion $runtimeVersion }
        'python-env'     { Invoke-RepairPythonEnvironment -EnvironmentName $state.environment -RuntimeVersion $runtimeVersion -InstanceName $InstanceName }
        'rocm'           {
            if (-not $preRepairEnvPath -or -not (Test-Path -LiteralPath $preRepairEnvPath)) {
                Invoke-RepairPythonEnvironment -EnvironmentName $state.environment -RuntimeVersion $runtimeVersion -InstanceName $InstanceName
            }
            Invoke-RepairRocmPackages -InstanceName $InstanceName -InstanceState $state -RuntimeVersion $runtimeVersion -PreRepairGpu $preRepairGpu
        }
        'comfyui'        { Invoke-RepairComfyUi -InstanceName $InstanceName -EnvironmentName $state.environment -InstanceState $state -SharedWorkflows:$SharedWorkflows }
        'custom-nodes'   { Invoke-RepairCustomNodes -InstanceName $InstanceName -EnvironmentName $state.environment }
        'launchers'      { Invoke-RepairLaunchers -InstanceName $InstanceName -InstanceState $state -ProfileName $ProfileName }
        'patches'        { Invoke-RepairComfyPatches -InstanceName $InstanceName -GpuState $preRepairGpu }
        'all' {
            Invoke-RepairPythonEnvironment -EnvironmentName $state.environment -RuntimeVersion $runtimeVersion -InstanceName $InstanceName
            Invoke-RepairRocmPackages -InstanceName $InstanceName -InstanceState $state -RuntimeVersion $runtimeVersion -PreRepairGpu $preRepairGpu
            Invoke-RepairComfyUi -InstanceName $InstanceName -EnvironmentName $state.environment -InstanceState $state -SharedWorkflows:$SharedWorkflows
            Invoke-RepairCustomNodes -InstanceName $InstanceName -EnvironmentName $state.environment
            Invoke-RepairLaunchers -InstanceName $InstanceName -InstanceState $state -ProfileName $ProfileName
            Invoke-RepairComfyPatches -InstanceName $InstanceName -GpuState $preRepairGpu
        }
    }

    if ($RollbackPatch) {
        Invoke-RollbackPatch -InstanceName $InstanceName -PatchId $RollbackPatch
    }

    Update-RocmRollInstanceRepairState -InstanceName $InstanceName -Component $Component -Config $cfg

    Write-LogSuccess "Repair complete for '$InstanceName' component: $Component" -Comp 'RocmRoll.Repair'
}

function Invoke-RollbackPatch {
    param([string]$InstanceName, [string]$PatchId)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $envState = Get-EnvironmentState -Name (Get-InstanceState -Name $InstanceName).environment
    $envFolder = $envState.path
    $backupDir = Join-Path $cfg.PatchStateFolder $PatchId

    if (-not (Test-Path $backupDir)) {
        throw "ROCMROLL-PATCH-001: No backup found for patch '$PatchId' at $backupDir"
    }

    $backups = Get-ChildItem $backupDir -File
    foreach ($b in $backups) {
        $relPath = $b.Name -replace '---', '\'
        $targetFile = Join-Path $envFolder $relPath
        $targetDir = Split-Path $targetFile -Parent
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        Copy-Item $b.FullName $targetFile -Force
        Write-LogInfo "Restored: $relPath" -Comp 'RocmRoll.Repair'
    }
    Write-LogSuccess "Patch '$PatchId' rolled back." -Comp 'RocmRoll.Repair'
}

Export-ModuleMember -Function Invoke-RepairComponent, Invoke-RollbackPatch
