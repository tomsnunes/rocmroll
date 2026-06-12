#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Hardware - GPU detection via gpu_detect.py (JSON mode).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GpuDetect {
    param(
        [string]$PythonExe   = '',
        [string]$GfxOverride = '',
        [switch]$Quiet
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg         = Get-Config
    $detectScript= Join-Path $cfg.ScriptsFolder 'gpu_detect.py'

    if (-not (Test-Path $detectScript)) {
        throw "ROCMROLL-GPU-001: gpu_detect.py not found at '$detectScript'"
    }

    # Resolve python: prefer provided exe, then system python
    if (-not $PythonExe) {
        $pythonCommand = Get-Command 'python.exe' -ErrorAction SilentlyContinue
        if ($pythonCommand) {
            $PythonExe = $pythonCommand.Source
        }
        if (-not $PythonExe) {
            throw "ROCMROLL-GPU-002: No Python executable found. Pass -PythonExe or create a runtime first."
        }
    }

    $detectArgs = @($detectScript, '--json')
    if ($Quiet) { $detectArgs += '--quiet' }
    if ($GfxOverride) { $detectArgs += '--gfx'; $detectArgs += $GfxOverride }

    $archManifest = Join-Path $cfg.ManifestsFolder 'rocm-architectures.json'
    if (Test-Path $archManifest) { $detectArgs += '--arch-manifest'; $detectArgs += $archManifest }

    try {
        $result = & $PythonExe $detectArgs 2>$null
        $gpu    = $result | ConvertFrom-Json
    } catch {
        throw "ROCMROLL-GPU-003: gpu_detect.py returned invalid JSON: $_"
    }

    return $gpu
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
