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

function Get-InstalledInstanceList {
    param([hashtable]$Config = $null)

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $instances = @(Get-ChildItem $Config.InstancesFolder -Directory -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($dir in $instances) {
        $state = Get-InstanceState -Name $dir.Name
        $result += [PSCustomObject]@{
            Name    = $dir.Name
            Path    = $dir.FullName
            Channel = if ($state) { $state.channel } else { '-' }
            Status  = if ($state) { $state.status } else { 'unknown' }
            State   = $state
        }
    }
    return $result
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

    $folder = Join-Path $Config.InstancesFolder $InstanceName
    $state = Get-InstanceState -Name $InstanceName
    $envName = if ($EnvironmentName) {
        $EnvironmentName
    } elseif ($state -and $state.environment) {
        $state.environment
    } else {
        "$InstanceName-py$($PythonVersion.Split('.')[0])$($PythonVersion.Split('.')[1])"
    }

    $envFolder = Join-Path $Config.EnvironmentsFolder $envName
    $stateFile = Join-Path $Config.InstanceStateFolder "instance-$InstanceName.json"
    $envStateFile = Join-Path $Config.EnvStateFolder "environment-$envName.json"

    if (-not (Test-Path $folder) -and -not (Test-Path $envFolder) -and
        -not (Test-Path $stateFile) -and -not (Test-Path $envStateFile)) {
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

    if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
    if (Test-Path $envStateFile) { Remove-Item $envStateFile -Force }

    $launcherPs1 = Join-Path $Config.LaunchersFolder "$InstanceName.ps1"
    $launcherBat = Join-Path $Config.LaunchersFolder "$InstanceName.bat"
    if (Test-Path $launcherPs1) {
        Remove-Item $launcherPs1 -Force
        Write-LogSuccess "Removed launcher: $launcherPs1" -Comp 'RocmRoll'
    }
    if (Test-Path $launcherBat) {
        Remove-Item $launcherBat -Force
        Write-LogSuccess "Removed launcher: $launcherBat" -Comp 'RocmRoll'
    }

    Write-LogSuccess "Install '$InstanceName' removed." -Comp 'RocmRoll'
}

Export-ModuleMember -Function Get-InstalledInstanceList, Remove-RocmRollInstance
