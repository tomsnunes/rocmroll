#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Environment - Python environment creation from a runtime copy.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CreateEnvironment {
    param(
        [string]$Name,
        [string]$RuntimeVersion = '3.12.10',
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')  -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')   -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg       = Get-Config
    $envFolder = Join-Path $cfg.EnvironmentsFolder $Name
    $pythonExe = Join-Path $envFolder 'python.exe'

    $runtimeFolder = Join-Path $cfg.RuntimesFolder "python-$RuntimeVersion"
    if (-not (Test-Path (Join-Path $runtimeFolder 'python.exe'))) {
        throw "ROCMROLL-ENV-001: Runtime python-$RuntimeVersion not found. Run 'rocmroll create-runtime' first."
    }

    if (-not $Force -and (Test-Path $pythonExe)) {
        $val = & $pythonExe -c "import sys; print(sys.version)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $state = Get-EnvironmentState -Name $Name
            $statusProperty = if ($state) { $state.PSObject.Properties['status'] } else { $null }
            $status = if ($statusProperty -and $statusProperty.Value) { $statusProperty.Value } else { 'unknown' }
            Write-LogInfo "Environment '$Name' already has a working Python (state: $status). Preserving existing packages." -Comp 'RocmRoll.Environment' -Op 'CreateEnvironment'
            if (-not $state) {
                Set-EnvironmentState -Name $Name -Path $envFolder -RuntimeVersion $RuntimeVersion -Status 'ready'
            }
            return $envFolder
        }

        Write-LogWarn "Environment '$Name' exists but Python validation failed; rebuilding it." -Comp 'RocmRoll.Environment' -Op 'CreateEnvironment'
    }

    Write-LogInfo "Creating environment '$Name' from runtime $RuntimeVersion" -Comp 'RocmRoll.Environment' -Op 'CreateEnvironment'

    if (Test-Path $envFolder) {
        Remove-Item $envFolder -Recurse -Force
    }
    Copy-Item -Path $runtimeFolder -Destination $envFolder -Recurse -Force

    # Apply process-local env vars for pip operations
    $env:PYTHONHOME                     = ''
    $env:PYTHONPATH                     = ''
    $env:PIP_CACHE_DIR                  = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK  = '1'
    $env:PIP_NO_INPUT                   = '1'
    $env:PIP_REQUIRE_VIRTUALENV         = 'false'

    # Validate
    $val = & $pythonExe -c "import sys; print(sys.version)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ROCMROLL-ENV-002: Environment validation failed: $val" }
    Write-LogSuccess "Environment '$Name' ready at $envFolder" -Comp 'RocmRoll.Environment'

    Set-EnvironmentState -Name $Name -Path $envFolder -RuntimeVersion $RuntimeVersion -Status 'ready'
    return $envFolder
}

function Get-EnvironmentPython {
    param([string]$Name)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    return Join-Path $cfg.EnvironmentsFolder "$Name\python.exe"
}

function Test-EnvironmentIntegrity {
    param([string]$Name)
    $python = Get-EnvironmentPython -Name $Name
    if (-not (Test-Path $python)) { return $false }
    & $python -c "import sys; print(sys.version)" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-EnvironmentInstancePath {
    param(
        [string]$EnvironmentName,
        [string]$InstanceName
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')  -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Runtime.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')   -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg          = Get-Config
    $instanceState = Get-InstanceState -Name $InstanceName
    $instanceFolder = if ($instanceState -and $instanceState.path) { $instanceState.path } else { Join-Path $cfg.InstancesFolder $InstanceName }
    $envState     = Get-EnvironmentState -Name $EnvironmentName
    $envFolder    = if ($envState -and $envState.path) { $envState.path } else { Join-Path $cfg.EnvironmentsFolder $EnvironmentName }

    if (-not (Test-Path $envFolder))      { throw "ROCMROLL-ENV-003: Environment folder not found: $envFolder" }
    if (-not (Test-Path $instanceFolder)) { throw "ROCMROLL-ENV-004: Instance folder not found: $instanceFolder" }

    $fromUri = [System.Uri]([System.IO.Path]::GetFullPath($envFolder) + '\')
    $toUri   = [System.Uri]([System.IO.Path]::GetFullPath($instanceFolder) + '\')
    $relPath = [Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).TrimEnd('/')

    Set-PythonPthFile -DestFolder $envFolder -ExtraPaths @($relPath)
    Write-LogInfo "python312._pth updated: prepended '$relPath'" -Comp 'RocmRoll.Environment' -Op 'SetInstancePath'
}

Export-ModuleMember -Function Invoke-CreateEnvironment, Get-EnvironmentPython, Test-EnvironmentIntegrity, Set-EnvironmentInstancePath
