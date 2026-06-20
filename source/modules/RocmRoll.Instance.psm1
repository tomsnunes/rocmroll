#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Instance - Instance listing and removal operations.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Utilities.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ComfyDesktop.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ComfyPatch.psm1')

function Get-InstalledInstanceList {
    param([hashtable]$Config = $null)

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $byName = [ordered]@{}
    $stateFiles = @(Get-ChildItem $Config.InstanceStateFolder -Filter 'instance-*.json' -File -ErrorAction SilentlyContinue)
    foreach ($file in $stateFiles) {
        $state = Read-StateFile -Path $file.FullName
        if (-not $state) { continue }

        $name = if ($state.PSObject.Properties['name'] -and $state.name) {
            [string]$state.name
        } else {
            $file.BaseName -replace '^instance-', ''
        }
        $path = if ($state.PSObject.Properties['path'] -and $state.path) {
            [string]$state.path
        } else {
            Join-Path $Config.InstancesFolder $name
        }

        $byName[$name] = [PSCustomObject]@{
            Name    = $name
            Path    = $path
            Channel = if ($state.PSObject.Properties['channel'] -and $state.channel) { [string]$state.channel } else { '-' }
            Status  = if ($state.PSObject.Properties['status'] -and $state.status) { [string]$state.status } else { 'unknown' }
            State   = $state
        }
    }

    $instances = @(Get-ChildItem $Config.InstancesFolder -Directory -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($dir in $instances) {
        if ($byName.Contains($dir.Name)) { continue }
        $state = Get-InstanceState -Name $dir.Name
        $byName[$dir.Name] = [PSCustomObject]@{
            Name    = $dir.Name
            Path    = $dir.FullName
            Channel = if ($state) { $state.channel } else { '-' }
            Status  = if ($state) { $state.status } else { 'unknown' }
            State   = $state
        }
    }
    foreach ($key in @($byName.Keys | Sort-Object)) {
        $result += $byName[$key]
    }
    return $result
}

function Remove-RocmRollLaunchers {
    param([string]$InstanceName, [hashtable]$Config)

    foreach ($extension in @('ps1','bat')) {
        $path = Join-Path $Config.LaunchersFolder "$InstanceName.$extension"
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-LogSuccess "Removed launcher: $path" -Comp 'RocmRoll'
        }
    }
}

function Remove-RocmRollPatchArtifacts {
    param([string]$InstanceName, [hashtable]$Config)

    $patchStateFolder = Join-Path $Config.PatchStateFolder 'comfyui'
    $patchStateFile = Join-Path $patchStateFolder "$InstanceName.json"
    $patchBackupFolder = Join-Path $patchStateFolder $InstanceName
    if (Test-Path -LiteralPath $patchStateFile) {
        Remove-Item -LiteralPath $patchStateFile -Force
        Write-LogSuccess "Removed patch state: $patchStateFile" -Comp 'RocmRoll'
    }
    if (Test-Path -LiteralPath $patchBackupFolder) {
        Remove-FolderTree -Path $patchBackupFolder -ParentFolder $patchStateFolder -Description 'patch backup'
        Write-LogSuccess "Removed patch backups: $patchBackupFolder" -Comp 'RocmRoll'
    }
}

function Restore-RocmRollPatches {
    param([string]$InstanceName, [hashtable]$Config)

    $patchState = Get-ComfyPatchState -InstanceName $InstanceName
    $entries = @(Get-ComfyPatchStateEntries -State $patchState)
    if ($entries.Count -gt 0) {
        [array]::Reverse($entries)
        foreach ($entry in $entries) {
            $patchId = Get-ComfyPatchEntryId -Entry $entry
            if ($patchId) {
                Invoke-RemoveComfyPatch -PatchId $patchId -InstanceName $InstanceName
            }
        }
    }
    Remove-RocmRollPatchArtifacts -InstanceName $InstanceName -Config $Config
}

function Set-RocmRollInstanceIncomplete {
    param([string]$InstanceName, [object]$State, [string[]]$Components, [hashtable]$Config)

    if (-not $State) { return }
    $stateHash = ConvertTo-StateHashtable -InputObject $State
    $previousComponents = if ($stateHash.ContainsKey('removedComponents')) { @($stateHash['removedComponents']) } else { @() }
    $stateHash['status'] = 'incomplete'
    $stateHash['removedComponents'] = @($previousComponents + $Components | Sort-Object -Unique)
    $stateHash['updatedAt'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    if ($stateHash.ContainsKey('comfyDesktopId')) { $stateHash.Remove('comfyDesktopId') }
    $stateFile = Join-Path $Config.InstanceStateFolder "instance-$InstanceName.json"
    Write-StateFile -Path $stateFile -State $stateHash
}

function Remove-RocmRollInstance {
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [string]$EnvironmentName = '',
        [string]$PythonVersion = '3.12.10',
        [switch]$Force,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $state = Get-InstanceState -Name $InstanceName
    $folder = if ($state -and $state.PSObject.Properties['path'] -and $state.path) {
        [string]$state.path
    } else {
        Join-Path $Config.InstancesFolder $InstanceName
    }
    $envName = if ($EnvironmentName) {
        $EnvironmentName
    } elseif ($state -and $state.environment) {
        $state.environment
    } else {
        "$InstanceName-py$($PythonVersion.Split('.')[0])$($PythonVersion.Split('.')[1])"
    }

    $envState = Get-EnvironmentState -Name $envName
    $envFolder = if ($envState -and $envState.PSObject.Properties['path'] -and $envState.path) {
        [string]$envState.path
    } else {
        Join-Path $Config.EnvironmentsFolder $envName
    }
    $stateFile = Join-Path $Config.InstanceStateFolder "instance-$InstanceName.json"
    $envStateFile = Join-Path $Config.EnvStateFolder "environment-$envName.json"

    if (-not (Test-Path $folder) -and -not (Test-Path $envFolder) -and
        -not (Test-Path $stateFile) -and -not (Test-Path $envStateFile) -and
        -not (Test-Path (Join-Path $Config.LaunchersFolder "$InstanceName.ps1")) -and
        -not (Test-Path (Join-Path $Config.PatchStateFolder "comfyui\$InstanceName.json"))) {
        Write-LogWarn "Install '$InstanceName' not found." -Comp 'RocmRoll'
        return
    }

    if (-not $Force) {
        $confirm = Read-Host "Remove instance '$InstanceName' and environment '$envName'? (y/N)"
        if ($confirm -ne 'y') { Write-Host 'Cancelled.'; return }
    }

    $desktopId = if ($state -and $state.PSObject.Properties['comfyDesktopId']) {
        [string]$state.comfyDesktopId
    } else {
        ''
    }
    Unregister-ComfyDesktopInstance -InstanceName $InstanceName -ComfyDesktopId $desktopId

    if (Test-Path $folder) {
        Remove-FolderTree -Path $folder -ParentFolder $Config.InstancesFolder -Description 'instance'
        Write-LogSuccess "Removed instance folder: $folder" -Comp 'RocmRoll'
    }

    if (Test-Path $envFolder) {
        Remove-FolderTree -Path $envFolder -ParentFolder $Config.EnvironmentsFolder -Description 'environment'
        Write-LogSuccess "Removed environment folder: $envFolder" -Comp 'RocmRoll'
    }

    Remove-RocmRollLaunchers -InstanceName $InstanceName -Config $Config
    Remove-RocmRollPatchArtifacts -InstanceName $InstanceName -Config $Config
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
    if (Test-Path -LiteralPath $envStateFile) { Remove-Item -LiteralPath $envStateFile -Force }

    Write-LogSuccess "Install '$InstanceName' removed." -Comp 'RocmRoll'
}

function Remove-RocmRollInstanceComponents {
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [Parameter(Mandatory)][string[]]$Components,
        [string]$PythonVersion = '3.12.10',
        [switch]$Force,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $state = Get-InstanceState -Name $InstanceName
    $envName = if ($state -and $state.environment) {
        $state.environment
    } else {
        "$InstanceName-py$($PythonVersion.Split('.')[0])$($PythonVersion.Split('.')[1])"
    }

    $componentList = @($Components | Sort-Object -Unique)
    $rocmImpliesEnvironment = $componentList -contains 'rocm' -and $componentList -notcontains 'environment'
    if ($rocmImpliesEnvironment) {
        $componentList += 'environment'
    }
    if (-not $Force) {
        $confirm = Read-Host "Remove component(s) '$($componentList -join ', ')' from instance '$InstanceName'? (y/N)"
        if ($confirm -ne 'y') { Write-Host 'Cancelled.'; return }
    }

    if ($componentList -contains 'patches') {
        if ($componentList -contains 'comfyui') {
            Remove-RocmRollPatchArtifacts -InstanceName $InstanceName -Config $Config
        } else {
            Restore-RocmRollPatches -InstanceName $InstanceName -Config $Config
        }
    }

    if ($componentList -contains 'comfyui' -or $componentList -contains 'environment' -or $componentList -contains 'rocm') {
        $desktopId = if ($state -and $state.PSObject.Properties['comfyDesktopId']) { [string]$state.comfyDesktopId } else { '' }
        Unregister-ComfyDesktopInstance -InstanceName $InstanceName -ComfyDesktopId $desktopId
    }

    if ($componentList -contains 'comfyui') {
        $folder = if ($state -and $state.path) { $state.path } else { Join-Path $Config.InstancesFolder $InstanceName }
        if (Test-Path $folder) {
            Remove-FolderTree -Path $folder -ParentFolder $Config.InstancesFolder -Description 'instance'
            Write-LogSuccess "Removed ComfyUI folder: $folder" -Comp 'RocmRoll'
        }

        Remove-RocmRollLaunchers -InstanceName $InstanceName -Config $Config
    }

    if ($componentList -contains 'environment' -or $componentList -contains 'rocm') {
        if ($rocmImpliesEnvironment) {
            Write-LogWarn "ROCm packages are installed inside the Python environment; removing ROCm removes the environment '$envName'." -Comp 'RocmRoll'
        }

        $envState = Get-EnvironmentState -Name $envName
        $envFolder = if ($envState -and $envState.PSObject.Properties['path'] -and $envState.path) {
            [string]$envState.path
        } else {
            Join-Path $Config.EnvironmentsFolder $envName
        }
        $envStateFile = Join-Path $Config.EnvStateFolder "environment-$envName.json"
        if (Test-Path $envFolder) {
            Remove-FolderTree -Path $envFolder -ParentFolder $Config.EnvironmentsFolder -Description 'environment'
            Write-LogSuccess "Removed environment folder: $envFolder" -Comp 'RocmRoll'
        }
        if (Test-Path $envStateFile) {
            Remove-Item -LiteralPath $envStateFile -Force
            Write-LogSuccess "Removed environment state: $envStateFile" -Comp 'RocmRoll'
        }
    }

    if (@($componentList | Where-Object { $_ -in @('comfyui','environment','rocm') }).Count -gt 0) {
        Set-RocmRollInstanceIncomplete -InstanceName $InstanceName -State $state -Components $componentList -Config $Config
    }

    Write-LogSuccess "Component removal complete for '$InstanceName': $($componentList -join ', ')" -Comp 'RocmRoll'
}

Export-ModuleMember -Function Get-InstalledInstanceList, Remove-RocmRollInstance,
    Remove-RocmRollInstanceComponents
