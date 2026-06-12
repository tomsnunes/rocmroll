#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Hardware - GPU detection via native PowerShell CIM/PnP/WMIC.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AmdGpuViaCim {
    param([switch]$Quiet)
    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Select-Object Name, AdapterCompatibility
        foreach ($c in $controllers) {
            $name   = [string]$c.Name
            $compat = [string]$c.AdapterCompatibility
            if (($name -match 'amd|radeon') -or ($compat -match 'amd')) {
                return @{ name = $name.Trim(); vendor = if ($compat.Trim()) { $compat.Trim() } else { 'AMD' } }
            }
        }
    } catch {
        if (-not $Quiet) { Write-Host "[gpu_detect] CIM detection error: $_" -ForegroundColor DarkGray }
    }
    return $null
}

function Get-AmdGpuViaPnp {
    param([switch]$Quiet)
    try {
        $devices = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue
        foreach ($d in $devices) {
            $name   = [string]$d.FriendlyName
            $vendor = [string]$d.Manufacturer
            if (($name -match 'amd|radeon') -or ($vendor -match 'amd')) {
                return @{ name = $name.Trim(); vendor = if ($vendor.Trim()) { $vendor.Trim() } else { 'AMD' } }
            }
        }
    } catch {
        if (-not $Quiet) { Write-Host "[gpu_detect] PnP detection error: $_" -ForegroundColor DarkGray }
    }
    return $null
}

function Get-AmdGpuViaWmic {
    param([switch]$Quiet)
    try {
        $output = & wmic path Win32_VideoController get Name,AdapterCompatibility /format:csv 2>$null
        foreach ($line in ($output -split "`n")) {
            $parts = $line.Split(',')
            if ($parts.Count -ge 3) {
                $compat = $parts[1].Trim()
                $name   = $parts[2].Trim()
                if (($name -match 'amd|radeon') -or ($compat -match 'amd')) {
                    return @{ name = $name; vendor = if ($compat) { $compat } else { 'AMD' } }
                }
            }
        }
    } catch {
        if (-not $Quiet) { Write-Host "[gpu_detect] WMIC detection error: $_" -ForegroundColor DarkGray }
    }
    return $null
}

function Resolve-GfxFamily {
    param([string]$DeviceName, $ArchTable)
    if (-not $ArchTable) { return $null }
    $lower  = $DeviceName.ToLower()
    $lookup = foreach ($prop in $ArchTable.PSObject.Properties) {
        foreach ($dev in $prop.Value.devices) {
            [pscustomobject]@{ fragment = $dev.ToLower(); gfx = $prop.Name }
        }
    }
    $match = $lookup |
        Sort-Object { $_.fragment.Length } -Descending |
        Where-Object { $lower.Contains($_.fragment) } |
        Select-Object -First 1
    if ($match) { return $match.gfx }
    return $null
}

function Invoke-GpuDetect {
    param(
        [string]$PythonExe   = '',   # kept for call-site compatibility; not used
        [string]$GfxOverride = '',
        [switch]$Quiet
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config

    $archManifest = Join-Path $cfg.ManifestsFolder 'rocm-architectures.json'
    $archTable    = $null
    if (Test-Path $archManifest) {
        try   { $archTable = Get-Content $archManifest -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $archTable = $null }
    }

    if ($GfxOverride) {
        if (-not $Quiet) { Write-Host "[gpu_detect] Using manual GFX override: $GfxOverride" -ForegroundColor DarkGray }
        $archInfo = if ($archTable) { $archTable.PSObject.Properties[$GfxOverride] } else { $null }
        $ai       = if ($archInfo) { $archInfo.Value } else { $null }
        return [PSCustomObject][ordered]@{
            detected           = $true
            supported          = [bool]$(if ($ai) { $ai.supported } else { $false })
            name               = "Manual override ($GfxOverride)"
            vendor             = 'AMD'
            architecture       = if ($ai) { $ai.architecture } else { 'Unknown' }
            gfx                = $GfxOverride
            rocmIndex          = if ($ai) { $ai.index } else { '' }
            requiresPreRelease = [bool]$(if ($ai) { $ai.requiresPreRelease } else { $false })
            detectionMethod    = 'override'
        }
    }

    $gpu    = $null
    $method = 'none'

    if (-not $Quiet) { Write-Host '[gpu_detect] Trying CIM detection...' -ForegroundColor DarkGray }
    $gpu = Get-AmdGpuViaCim -Quiet:$Quiet
    if ($gpu) { $method = 'cim' }

    if (-not $gpu) {
        if (-not $Quiet) { Write-Host '[gpu_detect] Trying PnP detection...' -ForegroundColor DarkGray }
        $gpu = Get-AmdGpuViaPnp -Quiet:$Quiet
        if ($gpu) { $method = 'pnp' }
    }

    if (-not $gpu) {
        if (-not $Quiet) { Write-Host '[gpu_detect] Trying WMIC detection...' -ForegroundColor DarkGray }
        $gpu = Get-AmdGpuViaWmic -Quiet:$Quiet
        if ($gpu) { $method = 'wmic' }
    }

    if (-not $gpu) {
        return [PSCustomObject][ordered]@{
            detected           = $false
            supported          = $false
            name               = $null
            vendor             = $null
            architecture       = $null
            gfx                = $null
            rocmIndex          = $null
            requiresPreRelease = $false
            detectionMethod    = 'none'
            error              = 'No AMD GPU found'
        }
    }

    $gfx      = Resolve-GfxFamily -DeviceName $gpu.name -ArchTable $archTable
    $archInfo = if ($gfx -and $archTable) { $archTable.PSObject.Properties[$gfx] } else { $null }
    $ai       = if ($archInfo) { $archInfo.Value } else { $null }

    return [PSCustomObject][ordered]@{
        detected           = $true
        supported          = [bool]$(if ($ai) { $ai.supported } else { $false })
        name               = $gpu.name
        vendor             = $gpu.vendor
        architecture       = if ($ai) { $ai.architecture } else { 'Unknown' }
        gfx                = $gfx
        rocmIndex          = if ($ai) { $ai.index } else { $null }
        requiresPreRelease = [bool]$(if ($ai) { $ai.requiresPreRelease } else { $false })
        detectionMethod    = $method
    }
}

function Get-ArchitectureManifest {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force
    $cfg  = Get-Config
    $path = Join-Path $cfg.ManifestsFolder 'rocm-architectures.json'
    if (-not (Test-Path $path)) {
        throw "ROCMROLL-GPU-004: rocm-architectures.json not found at '$path'"
    }
    return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

Export-ModuleMember -Function Invoke-GpuDetect, Get-ArchitectureManifest
