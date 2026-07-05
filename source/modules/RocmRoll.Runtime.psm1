#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Runtime - Python runtime creation from embeddable + full ZIP distributions.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

function script:Test-RemoteFileExists {
    param([string]$Url)
    try {
        $req         = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method  = 'HEAD'
        $req.Timeout = 15000
        $resp        = $req.GetResponse()
        $resp.Close()
        return $true
    } catch { return $false }
}

function Invoke-CreatePythonRuntime {
    param(
        [string]$Version = '3.12.10',
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Download.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg           = Get-Config
    $runtimeFolder = Join-Path $cfg.RuntimesFolder "python-$Version"
    $pythonExe     = Join-Path $runtimeFolder 'python.exe'

    # --- Idempotency check ---
    if (-not $Force -and (Test-Path $pythonExe)) {
        $state = Get-RuntimeState -Version $Version
        if ($state -and $state.status -eq 'ready') {
            Write-LogInfo "Runtime $Version already exists and is ready. Skipping." -Comp 'RocmRoll.Runtime' -Op 'CreatePythonRuntime'
            return $runtimeFolder
        }
    }

    # --- Resolve manifest ---
    $manifestPath = Join-Path $cfg.ManifestsFolder 'python-runtimes.json'
    $manifest     = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $verEntry     = $manifest.versions | Where-Object { $_.version -eq $Version } | Select-Object -First 1
    if (-not $verEntry) {
        Write-LogWarn "Python $Version not in manifest - attempting auto-resolve from python.org FTP" -Comp 'RocmRoll.Runtime' -Op 'CreatePythonRuntime'
        $parts      = $Version.Split('.')
        $majorMinor = "$($parts[0])$($parts[1])"
        $autoEmbed  = "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip"
        $autoFull   = "https://www.python.org/ftp/python/$Version/python-$Version-amd64.zip"
        foreach ($probeUrl in @($autoEmbed, $autoFull)) {
            if (-not (Test-RemoteFileExists -Url $probeUrl)) {
                throw "ROCMROLL-RUNTIME-005: Python $Version not found on python.org FTP ($probeUrl). Verify the version number or add it to python-runtimes.json."
            }
        }
        $verEntry = [PSCustomObject]@{
            embedUrl    = $autoEmbed
            fullUrl     = $autoFull
            pthTemplate = "python$majorMinor._pth.tpl"
        }
    }

    $embedUrl = $verEntry.embedUrl
    $fullUrl  = $verEntry.fullUrl

    Write-LogInfo "Resolving Python runtime $Version" -Comp 'RocmRoll.Runtime' -Op 'CreatePythonRuntime' -Data @{ version=$Version; runtimeFolder=$runtimeFolder }

    # --- Download archives ---
    $embedZip = Invoke-CachedDownload -Url $embedUrl  -DestFolder $cfg.PythonDownloadsFolder
    $fullZip  = Invoke-CachedDownload -Url $fullUrl   -DestFolder $cfg.PythonDownloadsFolder

    # --- Extract embeddable into runtime folder ---
    if (-not (Test-Path $runtimeFolder)) {
        New-Item -ItemType Directory -Path $runtimeFolder -Force | Out-Null
    }
    Write-LogInfo "Extracting embeddable Python to $runtimeFolder" -Comp 'RocmRoll.Runtime' -Op 'ExtractEmbed'
    Expand-Archive -Path $embedZip -DestinationPath $runtimeFolder -Force

    # --- Extract full ZIP to temp ---
    $tempFullDir = Join-Path $cfg.TempFolder 'python-full'
    if (Test-Path $tempFullDir) { Remove-Item $tempFullDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempFullDir -Force | Out-Null
    Write-LogInfo "Extracting full Python to temp" -Comp 'RocmRoll.Runtime' -Op 'ExtractFull'
    Expand-Archive -Path $fullZip -DestinationPath $tempFullDir -Force

    # --- Copy enrichment files (include, libs, Lib) from temp into runtime ---
    foreach ($subdir in @('include', 'libs', 'Lib')) {
        $src = Join-Path $tempFullDir $subdir
        $dst = Join-Path $runtimeFolder $subdir
        if (Test-Path $src) {
            Write-LogInfo "Copying $subdir into runtime" -Comp 'RocmRoll.Runtime' -Op 'EnrichRuntime'
            Copy-Item -Path $src -Destination $dst -Recurse -Force
        } else {
            Write-LogWarn "$subdir not found in full Python archive" -Comp 'RocmRoll.Runtime'
        }
    }

    # --- Generate pythonXYZ._pth ---
    Set-PythonPthFile -DestFolder $runtimeFolder -Version $Version
    Write-LogInfo "Generated pth file for Python $Version" -Comp 'RocmRoll.Runtime' -Op 'GeneratePth'

    # --- Bootstrap pip ---
    Write-LogInfo "Bootstrapping pip" -Comp 'RocmRoll.Runtime' -Op 'BootstrapPip'
    $getPipUrl  = 'https://bootstrap.pypa.io/get-pip.py'
    $getPipFile = Invoke-CachedDownload -Url $getPipUrl -DestFolder $cfg.ToolsDownloadsFolder
    $getPipExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments @($getPipFile, '--no-warn-script-location') -Comp 'RocmRoll.Runtime' -Op 'BootstrapPip'
    if ($getPipExitCode -ne 0) { throw "ROCMROLL-RUNTIME-002: get-pip.py failed (exit $getPipExitCode)" }

    # --- Upgrade pip, setuptools, wheel ---
    Write-LogInfo "Upgrading pip / setuptools / wheel" -Comp 'RocmRoll.Runtime' -Op 'UpgradePip'
    $env:PIP_CACHE_DIR              = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_INPUT               = '1'
    $env:PIP_REQUIRE_VIRTUALENV     = 'false'
    $pipUpgradeArgs = @('-m', 'pip', 'install', '--upgrade', '--cache-dir', $cfg.PipCacheFolder, 'pip', 'setuptools', 'wheel')
    $pipUpgradeExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $pipUpgradeArgs -Comp 'RocmRoll.Runtime' -Op 'UpgradePip'
    if ($pipUpgradeExitCode -ne 0) { throw "ROCMROLL-RUNTIME-003: pip upgrade failed (exit $pipUpgradeExitCode)" }

    # --- Validate ---
    Write-LogInfo "Validating runtime" -Comp 'RocmRoll.Runtime' -Op 'ValidateRuntime'
    $validation = & $pythonExe -c "import sys; import site; print(sys.version); print(site.getsitepackages())" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ROCMROLL-RUNTIME-004: Runtime validation failed: $validation" }
    Write-LogSuccess "Runtime validation passed: $($validation[0])" -Comp 'RocmRoll.Runtime'

    # --- Write state ---
    Set-RuntimeState -Version $Version -Path $runtimeFolder -Status 'ready' -Source @{
        embeddedArchive = (Split-Path $embedZip -Leaf)
        fullArchive     = (Split-Path $fullZip  -Leaf)
    }

    # --- Clean temp ---
    Remove-Item $tempFullDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-LogSuccess "Python runtime $Version ready at $runtimeFolder" -Comp 'RocmRoll.Runtime'
    return $runtimeFolder
}

function Set-PythonPthFile {
    param(
        [string]$DestFolder,
        [string]$Version = '3.12.10',
        [string[]]$ExtraPaths = @()
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global

    $cfg        = Get-Config
    $parts      = $Version.Split('.')
    $majorMinor = "$($parts[0])$($parts[1])"
    $pthName    = "python$majorMinor._pth"
    $pthTpl     = Join-Path $cfg.TemplatesFolder "$pthName.tpl"
    $pthDest    = Join-Path $DestFolder $pthName

    $baseLines = if (Test-Path $pthTpl) {
        @(Get-Content $pthTpl -Encoding UTF8)
    } else {
        @("python$majorMinor.zip", '.', '..', 'Lib', 'Lib\site-packages', 'import site')
    }

    $lines = if ($ExtraPaths.Count -gt 0) { $ExtraPaths + $baseLines } else { $baseLines }
    Write-RocmRollTextLines -Path $pthDest -Lines $lines
}

function Test-RuntimeIntegrity {
    param([string]$Version = '3.12.10')
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg    = Get-Config
    $folder = Join-Path $cfg.RuntimesFolder "python-$Version"
    $exe    = Join-Path $folder 'python.exe'
    if (-not (Test-Path $exe)) { return $false }
    & $exe -c "import sys; print(sys.version)" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Export-ModuleMember -Function Invoke-CreatePythonRuntime, Set-PythonPthFile, Test-RuntimeIntegrity
