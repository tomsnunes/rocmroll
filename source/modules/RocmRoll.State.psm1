#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.State - Read/write JSON state files for runtimes, environments and instances.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

function ConvertTo-StateHashtable {
    param([object]$InputObject)

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [hashtable]) {
        $copy = @{}
        foreach ($key in $InputObject.Keys) {
            $copy[$key] = $InputObject[$key]
        }
        return $copy
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $InputObject.Keys) {
            $copy[$key] = $InputObject[$key]
        }
        return $copy
    }

    $properties = $InputObject.PSObject.Properties |
        Where-Object { $_.MemberType -in @('NoteProperty', 'Property') }

    $result = @{}
    foreach ($property in $properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}

function Get-StateFilePath {
    param(
        [ValidateSet('runtime','environment','instance','global')]
        [string]$Type,
        [string]$Name = ''
    )
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    switch ($Type) {
        'runtime'     { return Join-Path $cfg.RuntimeStateFolder "runtime-$Name.json" }
        'environment' { return Join-Path $cfg.EnvStateFolder "environment-$Name.json" }
        'instance'    { return Join-Path $cfg.InstanceStateFolder "instance-$Name.json" }
        'global'      { return Join-Path $cfg.StateFolder 'global.json' }
    }
}

function Read-StateFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $json = Get-Content -Path $Path -Raw -Encoding UTF8
        return $json | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to read state file '$Path': $_"
        return $null
    }
}

function Write-StateFile {
    param(
        [string]$Path,
        [hashtable]$State
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$Path.tmp"
    Write-RocmRollTextFile -Path $tmp -Content ($State | ConvertTo-Json -Depth 10)
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-RuntimeState {
    param([string]$Version)
    $cfg = (Get-Module RocmRoll.Config | ForEach-Object { & { Get-Config } })
    if (-not $cfg) { Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force }
    $cfg = Get-Config
    $path = Join-Path $cfg.RuntimeStateFolder "runtime-$Version.json"
    return Read-StateFile -Path $path
}

function Set-RuntimeState {
    param(
        [string]$Version,
        [string]$Path,
        [string]$Status = 'ready',
        [hashtable]$Source = @{}
    )
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $filePath = Join-Path $cfg.RuntimeStateFolder "runtime-$Version.json"
    $state = @{
        type       = 'python-runtime'
        version    = $Version
        path       = $Path
        createdAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        source     = $Source
        status     = $Status
    }
    Write-StateFile -Path $filePath -State $state
}

function Get-EnvironmentState {
    param([string]$Name)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $path = Join-Path $cfg.EnvStateFolder "environment-$Name.json"
    return Read-StateFile -Path $path
}

function Set-EnvironmentState {
    param(
        [string]$Name,
        [string]$Path,
        [string]$RuntimeVersion,
        [string]$Status = 'ready',
        [hashtable]$Gpu = @{},
        [hashtable]$Packages = @{}
    )
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $filePath = Join-Path $cfg.EnvStateFolder "environment-$Name.json"
    $state = @{
        type           = 'python-environment'
        name           = $Name
        runtimeVersion = $RuntimeVersion
        path           = $Path
        gpu            = $Gpu
        packages       = $Packages
        status         = $Status
        updatedAt      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    Write-StateFile -Path $filePath -State $state
}

function Get-InstanceState {
    param([string]$Name)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $path = Join-Path $cfg.InstanceStateFolder "instance-$Name.json"
    return Read-StateFile -Path $path
}

function Set-InstanceState {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Channel,
        [string]$Environment,
        [string]$Status = 'ready',
        [hashtable]$ComfyUI = @{},
        [hashtable]$Paths = @{},
        [string[]]$CustomNodes = @()
    )
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $filePath = Join-Path $cfg.InstanceStateFolder "instance-$Name.json"
    $state = @{
        type        = 'comfyui-instance'
        name        = $Name
        channel     = $Channel
        path        = $Path
        environment = $Environment
        comfyui     = $ComfyUI
        paths       = $Paths
        customNodes = $CustomNodes
        status      = $Status
        updatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    Write-StateFile -Path $filePath -State $state
}

function Set-InstanceComfyDesktopId {
    <#
    Patches only the comfyDesktopId field of an existing instance state file.
    Used after ComfyUI Desktop registration so we don't have to re-supply all
    the other Set-InstanceState parameters.
    #>
    param(
        [string]$Name,
        [string]$ComfyDesktopId
    )
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg      = Get-Config
    $filePath = Join-Path $cfg.InstanceStateFolder "instance-$Name.json"
    $existing = Read-StateFile -Path $filePath
    if (-not $existing) { throw "ROCMROLL-STATE-001: Instance state not found for '$Name'" }
    $ht = ConvertTo-StateHashtable -InputObject $existing
    $ht['comfyDesktopId'] = $ComfyDesktopId
    Write-StateFile -Path $filePath -State $ht
}

function Get-GlobalState {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $path = Join-Path $cfg.StateFolder 'global.json'
    return Read-StateFile -Path $path
}

function Set-GlobalState {
    param([hashtable]$State)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg = Get-Config
    $path = Join-Path $cfg.StateFolder 'global.json'
    Write-StateFile -Path $path -State $State
}

Export-ModuleMember -Function Get-StateFilePath, Read-StateFile, Write-StateFile,
    ConvertTo-StateHashtable,
    Get-RuntimeState, Set-RuntimeState,
    Get-EnvironmentState, Set-EnvironmentState,
    Get-InstanceState, Set-InstanceState, Set-InstanceComfyDesktopId,
    Get-GlobalState, Set-GlobalState
