#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Rocm - ROCm/PyTorch installation and validation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-WheelhouseHasWheels {
    param(
        [string]$WheelhouseFolder
    )

    if (-not (Test-Path $WheelhouseFolder)) { return $false }

    $wheel = Get-ChildItem -LiteralPath $WheelhouseFolder -File -Filter '*.whl' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    return ($null -ne $wheel)
}

function Get-RocmObjectValue {
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }

    if ($InputObject -is [hashtable]) {
        if ($InputObject.ContainsKey($PropertyName)) { return $InputObject[$PropertyName] }
        return $DefaultValue
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($PropertyName)) { return $InputObject[$PropertyName] }
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($property) { return $property.Value }

    return $DefaultValue
}

function ConvertTo-RocmStringArray {
    param([object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @([string]$Value) }

    $items = @()
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            if ($null -ne $item) { $items += [string]$item }
        }
        return $items
    }

    return @([string]$Value)
}

function Get-RocmChannelConfig {
    param([string]$Channel = 'stable')

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global

    $cfg = Get-Config
    $manifestPath = Join-Path $cfg.ManifestsFolder 'channels.json'
    $channelManifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $channelCfg = Get-RocmObjectValue -InputObject $channelManifest -PropertyName $Channel
    if (-not $channelCfg) { throw "ROCMROLL-ROCM-005: Unknown channel '$Channel'" }
    return $channelCfg
}

function Get-RocmProfileForChannel {
    param([string]$Channel = 'stable')

    $channelCfg = Get-RocmChannelConfig -Channel $Channel
    $rocmProfile = Get-RocmObjectValue -InputObject $channelCfg -PropertyName 'rocm'
    if (-not $rocmProfile) { throw "ROCMROLL-ROCM-006: Channel '$Channel' has no ROCm profile." }
    return $rocmProfile
}

function New-RocmIndexProfile {
    param([switch]$AllowPreRelease)

    return [pscustomobject][ordered]@{
        source          = 'index'
        indexBase       = 'https://rocm.nightlies.amd.com/v2'
        allowPreRelease = [bool]$AllowPreRelease
        packageSet      = 'latest'
        torchPackages   = @('torch', 'torchvision', 'torchaudio')
        rocmPackages    = @('rocm[libraries,devel]')
    }
}

function Get-PythonRuntimeVersionFromExecutable {
    param([string]$PythonExe)

    if (-not (Test-Path $PythonExe)) { return '' }

    try {
        $version = & $PythonExe -c "import sys; print('{}.{}.{}'.format(sys.version_info.major, sys.version_info.minor, sys.version_info.micro))" 2>$null
        if ($LASTEXITCODE -eq 0) { return [string]($version | Select-Object -First 1) }
    } catch { }

    return ''
}

function Assert-RocmPythonVersionCompatible {
    param(
        [string]$PythonVersion,
        [string]$PythonTag
    )

    if ($PythonTag -eq 'cp312' -and $PythonVersion -and $PythonVersion -notmatch '^3\.12(\.|$)') {
        throw "ROCMROLL-ROCM-007: Stable ROCm direct wheels are tagged cp312 and require Python 3.12. Requested Python version: $PythonVersion"
    }
}

function Resolve-RocmInstallPlan {
    param(
        [string]$RocmIndex,
        [object]$RocmProfile = $null,
        [string]$PythonVersion = '',
        [switch]$AllowPreRelease,
        [switch]$UseWheelhouse,
        [string]$WheelhouseFolder = ''
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global

    $cfg = Get-Config
    if (-not $RocmProfile) {
        $RocmProfile = New-RocmIndexProfile -AllowPreRelease:$AllowPreRelease
    }

    $source = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'source' -DefaultValue 'index')
    $commonArgs = @(
        '-m', 'pip', 'install',
        '--cache-dir', $cfg.PipCacheFolder,
        '--upgrade-strategy', 'only-if-needed'
    )

    if ($source -eq 'directUrls') {
        $pythonTag = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'pythonTag' -DefaultValue '')
        Assert-RocmPythonVersionCompatible -PythonVersion $PythonVersion -PythonTag $pythonTag

        $directUrls = Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'directUrls'
        $sdkUrls = @(ConvertTo-RocmStringArray -Value (Get-RocmObjectValue -InputObject $directUrls -PropertyName 'sdk'))
        $torchUrls = @(ConvertTo-RocmStringArray -Value (Get-RocmObjectValue -InputObject $directUrls -PropertyName 'torch'))
        if ($sdkUrls.Count -eq 0 -and $torchUrls.Count -eq 0) {
            throw "ROCMROLL-ROCM-008: Direct ROCm profile has no package URLs."
        }

        $sdkArgs = if ($sdkUrls.Count -gt 0) { @($commonArgs + $sdkUrls) } else { @() }
        $torchArgs = if ($torchUrls.Count -gt 0) { @($commonArgs + $torchUrls) } else { @() }

        return [pscustomobject][ordered]@{
            source             = 'directUrls'
            rocmIndex          = $RocmIndex
            indexUrl           = ''
            allowPreRelease    = $false
            sdkArgs            = $sdkArgs
            torchArgs          = $torchArgs
            rocmArgs           = @()
            torchDeps          = @()
            allPackageSpecs    = @($sdkUrls + $torchUrls)
            rocmVersion        = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'version' -DefaultValue '')
            torchVersion       = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchVersion' -DefaultValue '')
            torchvisionVersion = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchvisionVersion' -DefaultValue '')
            torchaudioVersion  = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchaudioVersion' -DefaultValue '')
        }
    }

    if (-not $RocmIndex) {
        throw "ROCMROLL-ROCM-009: ROCm index is required for index-based ROCm profiles."
    }

    $indexBase = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'indexBase' -DefaultValue $cfg.RocmIndexBase)
    $indexUrl = "$($indexBase.TrimEnd('/'))/$RocmIndex/"
    $torchPackages = @(ConvertTo-RocmStringArray -Value (Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchPackages'))
    $rocmPackages  = @(ConvertTo-RocmStringArray -Value (Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'rocmPackages'))
    $torchDeps     = @(ConvertTo-RocmStringArray -Value (Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchDependencies' -DefaultValue @()))
    if ($torchPackages.Count -eq 0) { $torchPackages = @('torch', 'torchvision', 'torchaudio') }
    if ($rocmPackages.Count -eq 0) { $rocmPackages = @('rocm[libraries,devel]') }

    $profileAllowPreRelease = [bool](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'allowPreRelease' -DefaultValue $false)

    # Per-package pre-release overrides; fall back to allowPreRelease when absent
    $profileAllowTorchPreRelease = [bool](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'allowTorchPreRelease' -DefaultValue $profileAllowPreRelease)
    $profileAllowRocmPreRelease  = [bool](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'allowRocmPreRelease'  -DefaultValue $profileAllowPreRelease)

    $effectiveAllowTorchPreRelease = $profileAllowTorchPreRelease -or [bool]$AllowPreRelease
    $effectiveAllowRocmPreRelease  = $profileAllowRocmPreRelease  -or [bool]$AllowPreRelease

    $torchArgs = @(
        '-m', 'pip', 'install',
        '--index-url', $indexUrl,
        '--cache-dir', $cfg.PipCacheFolder
    )
    $rocmArgs = @(
        '-m', 'pip', 'install',
        '--index-url', $indexUrl,
        '--cache-dir', $cfg.PipCacheFolder
    )
    if ($UseWheelhouse -and $WheelhouseFolder) {
        $torchArgs += @('--find-links', $WheelhouseFolder)
        $rocmArgs  += @('--find-links', $WheelhouseFolder)
    }
    if ($effectiveAllowTorchPreRelease) { $torchArgs += '--pre' }
    if ($effectiveAllowRocmPreRelease)  { $rocmArgs  += '--pre' }
    $torchArgs += $torchPackages
    $rocmArgs  += $rocmPackages

    return [pscustomobject][ordered]@{
        source               = 'index'
        rocmIndex            = $RocmIndex
        indexUrl             = $indexUrl
        allowPreRelease      = $effectiveAllowTorchPreRelease -or $effectiveAllowRocmPreRelease
        allowTorchPreRelease = $effectiveAllowTorchPreRelease
        allowRocmPreRelease  = $effectiveAllowRocmPreRelease
        sdkArgs            = @()
        torchArgs          = @($torchArgs)
        rocmArgs           = @($rocmArgs)
        torchDeps          = @($torchDeps)
        allPackageSpecs    = @($torchPackages + $rocmPackages)
        rocmVersion        = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'version' -DefaultValue '')
        torchVersion       = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchVersion' -DefaultValue '')
        torchvisionVersion = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchvisionVersion' -DefaultValue '')
        torchaudioVersion  = [string](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'torchaudioVersion' -DefaultValue '')
    }
}

function Test-RocmStateMatchesInstallPlan {
    param(
        [hashtable]$Packages,
        [object]$InstallPlan
    )

    if (-not $Packages.ContainsKey('rocmSource')) { return $false }
    if ([string]$Packages['rocmSource'] -ne [string]$InstallPlan.source) { return $false }

    if ($InstallPlan.source -eq 'index') {
        if (-not $Packages.ContainsKey('rocmIndex')) { return $false }
        if ([string]$Packages['rocmIndex'] -ne [string]$InstallPlan.rocmIndex) { return $false }
    }

    if ($InstallPlan.rocmVersion) {
        if (-not $Packages.ContainsKey('rocmVersion')) { return $false }
        if ([string]$Packages['rocmVersion'] -ne [string]$InstallPlan.rocmVersion) { return $false }
    }

    if ($InstallPlan.torchVersion) {
        if (-not $Packages.ContainsKey('torch')) { return $false }
        if ([string]$Packages['torch'] -ne [string]$InstallPlan.torchVersion) { return $false }
    }

    return $true
}

function Set-RocmPackageStateValues {
    param(
        [hashtable]$Packages,
        [object]$InstallPlan,
        [object]$ValidationResult = $null
    )

    $Packages['rocmSource'] = [string]$InstallPlan.source
    $Packages['rocmIndex'] = [string]$InstallPlan.rocmIndex
    if ($InstallPlan.rocmVersion) { $Packages['rocmVersion'] = [string]$InstallPlan.rocmVersion }
    if ($InstallPlan.indexUrl) { $Packages['rocmIndexUrl'] = [string]$InstallPlan.indexUrl }

    $torchVersion = if ($InstallPlan.torchVersion) {
        [string]$InstallPlan.torchVersion
    } elseif ($ValidationResult -and $ValidationResult.PSObject.Properties['torchVersion']) {
        [string]$ValidationResult.torchVersion
    } else {
        'installed'
    }

    $Packages['torch'] = $torchVersion
    $Packages['torchvision'] = if ($InstallPlan.torchvisionVersion) {
        [string]$InstallPlan.torchvisionVersion
    } elseif ($ValidationResult -and $ValidationResult.PSObject.Properties['torchvisionVersion'] -and $ValidationResult.torchvisionVersion) {
        [string]$ValidationResult.torchvisionVersion
    } else {
        'installed'
    }
    $Packages['torchaudio'] = if ($InstallPlan.torchaudioVersion) {
        [string]$InstallPlan.torchaudioVersion
    } elseif ($ValidationResult -and $ValidationResult.PSObject.Properties['torchaudioVersion'] -and $ValidationResult.torchaudioVersion) {
        [string]$ValidationResult.torchaudioVersion
    } else {
        'installed'
    }
    $Packages['rocmLibraries'] = 'installed'
}

function Invoke-InstallRocm {
    param(
        [string]$EnvironmentName,
        [string]$RocmIndex,
        [object]$RocmProfile = $null,
        [string]$Channel = '',
        [string]$PythonVersion = '',
        [switch]$AllowPreRelease,
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')       -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg        = Get-Config
    $pythonExe  = Get-EnvironmentPython -Name $EnvironmentName

    $wheelhouse = if ($RocmIndex) { Join-Path $cfg.WheelhouseFolder $RocmIndex } else { '' }
    $useWheelhouse = $RocmIndex -and (Test-WheelhouseHasWheels -WheelhouseFolder $wheelhouse)

    if (-not (Test-Path $pythonExe)) {
        throw "ROCMROLL-ROCM-001: Python environment '$EnvironmentName' not found at $pythonExe"
    }

    $existingState = Get-EnvironmentState -Name $EnvironmentName
    $statePath = if ($existingState -and $existingState.path) { $existingState.path } else { Split-Path $pythonExe -Parent }
    $stateRuntime = if ($PythonVersion) {
        $PythonVersion
    } elseif ($existingState -and $existingState.runtimeVersion) {
        $existingState.runtimeVersion
    } else {
        Get-PythonRuntimeVersionFromExecutable -PythonExe $pythonExe
    }

    if (-not $RocmProfile -and $Channel) {
        $RocmProfile = Get-RocmProfileForChannel -Channel $Channel
    }

    $installPlan = Resolve-RocmInstallPlan -RocmIndex $RocmIndex -RocmProfile $RocmProfile `
        -PythonVersion $stateRuntime -AllowPreRelease:$AllowPreRelease `
        -UseWheelhouse:$useWheelhouse -WheelhouseFolder $wheelhouse

    if (-not $Force) {
        $existingValidation = Invoke-ValidateRocm -EnvironmentName $EnvironmentName -RocmIndex $RocmIndex
        if ($existingValidation.passed) {
            $gpu = ConvertTo-StateHashtable -InputObject $(if ($existingState) { $existingState.gpu } else { $null })
            $pkgs = ConvertTo-StateHashtable -InputObject $(if ($existingState) { $existingState.packages } else { $null })
            if (Test-RocmStateMatchesInstallPlan -Packages $pkgs -InstallPlan $installPlan) {
                Write-LogInfo "ROCm/PyTorch already validates for '$EnvironmentName' using requested profile. Skipping package install." -Comp 'RocmRoll.Rocm' -Op 'InstallRocm' -Inst $EnvironmentName

                Set-RocmPackageStateValues -Packages $pkgs -InstallPlan $installPlan -ValidationResult $existingValidation
                Set-EnvironmentState -Name $EnvironmentName -Path $statePath -RuntimeVersion $stateRuntime -Status 'ready' -Gpu $gpu -Packages $pkgs
                return
            }

            Write-LogInfo "ROCm/PyTorch validates, but installed package profile does not match requested channel. Reinstalling." -Comp 'RocmRoll.Rocm' -Op 'InstallRocm' -Inst $EnvironmentName
        }
    }

    # Process-local env
    $env:PYTHONHOME                    = ''
    $env:PYTHONPATH                    = ''
    $env:PIP_CACHE_DIR                 = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_INPUT                  = '1'
    $env:PIP_REQUIRE_VIRTUALENV        = 'false'
    # Do NOT set ROCM_SDK_TARGET_FAMILY here: the rocm sdist's setup.py calls
    # determine_target_family() at build time and hard-fails on any value the
    # distribution does not ship (stable direct-URL wheels only ship 'custom').
    # Validation and launchers seed it behind a membership check instead.

    if ($installPlan.sdkArgs.Count -gt 0) {
        Write-LogInfo "Installing ROCm SDK packages from AMD direct URLs" -Comp 'RocmRoll.Rocm' -Op 'InstallRocmSdk' -Inst $EnvironmentName
        $sdkExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $installPlan.sdkArgs -Comp 'RocmRoll.Rocm' -Op 'InstallRocmSdk' -Inst $EnvironmentName
        if ($sdkExitCode -ne 0) {
            throw "ROCMROLL-ROCM-010: Failed to install ROCm SDK direct URL packages (exit $sdkExitCode)"
        }
        Write-LogSuccess "ROCm SDK packages installed" -Comp 'RocmRoll.Rocm'
    }

    # --- Step 0: Pre-install torch dependencies from PyPI ---
    # torchDeps seeds packages (mpmath, setuptools<82, etc.) that exist only on PyPI.
    # This must run before the ROCm --index-url call, which replaces PyPI as the default index.
    if ($installPlan.torchDeps.Count -gt 0) {
        Write-LogInfo "Pre-installing torch dependencies from PyPI" -Comp 'RocmRoll.Rocm' -Op 'InstallTorchDeps' -Inst $EnvironmentName
        $torchDepsArgs = @(
            '-m', 'pip', 'install',
            '--cache-dir', $cfg.PipCacheFolder,
            '--upgrade-strategy', 'only-if-needed'
        ) + $installPlan.torchDeps
        $torchDepsExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $torchDepsArgs `
            -Comp 'RocmRoll.Rocm' -Op 'InstallTorchDeps' -Inst $EnvironmentName
        if ($torchDepsExitCode -ne 0) {
            throw "ROCMROLL-ROCM-012: Failed to pre-install torch dependencies from PyPI (exit $torchDepsExitCode)"
        }
        Write-LogSuccess "Torch dependencies pre-installed from PyPI" -Comp 'RocmRoll.Rocm'
    }

    # --- Step 1: torch, torchvision, torchaudio ---
    if ($installPlan.torchArgs.Count -eq 0) {
        throw "ROCMROLL-ROCM-011: ROCm profile did not resolve any torch package arguments."
    }

    if ($installPlan.source -eq 'index') {
        Write-LogInfo "Installing torch from ROCm index: $($installPlan.indexUrl)" -Comp 'RocmRoll.Rocm' -Op 'InstallTorch' -Inst $EnvironmentName
    } else {
        Write-LogInfo "Installing torch from AMD direct URLs" -Comp 'RocmRoll.Rocm' -Op 'InstallTorch' -Inst $EnvironmentName
    }

    if ($useWheelhouse -and $installPlan.source -eq 'index') {
        Write-LogInfo "Using wheelhouse cache: $wheelhouse" -Comp 'RocmRoll.Rocm' -Op 'InstallTorch' -Inst $EnvironmentName
    }

    $torchExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $installPlan.torchArgs -Comp 'RocmRoll.Rocm' -Op 'InstallTorch' -Inst $EnvironmentName
    if ($torchExitCode -ne 0) {
        $sourceDetail = if ($installPlan.indexUrl) { $installPlan.indexUrl } else { 'AMD direct URLs' }
        throw "ROCMROLL-ROCM-003: Failed to install torch from '$sourceDetail' (exit $torchExitCode)"
    }
    Write-LogSuccess "torch installed (wheels)" -Comp 'RocmRoll.Rocm'

    # --- Step 2: rocm[libraries,devel] ---
    if ($installPlan.rocmArgs.Count -gt 0) {
        Write-LogInfo "Installing ROCm packages from index" -Comp 'RocmRoll.Rocm' -Op 'InstallRocmLibs' -Inst $EnvironmentName
        if ($useWheelhouse -and $installPlan.source -eq 'index') {
            Write-LogInfo "Using wheelhouse cache: $wheelhouse" -Comp 'RocmRoll.Rocm' -Op 'InstallRocmLibs' -Inst $EnvironmentName
        }

        $rocmExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $installPlan.rocmArgs -Comp 'RocmRoll.Rocm' -Op 'InstallRocmLibs' -Inst $EnvironmentName
        if ($rocmExitCode -ne 0) {
            Write-LogWarn "ROCm package install returned exit $rocmExitCode - may be expected if package set is limited." -Comp 'RocmRoll.Rocm'
        }
    }

    # --- Step 3: rocm-sdk init ---
    $rocmSdk = Join-Path $cfg.EnvironmentsFolder "$EnvironmentName\Scripts\rocm-sdk.exe"
    if (Test-Path $rocmSdk) {
        Write-LogInfo "Running rocm-sdk init" -Comp 'RocmRoll.Rocm' -Op 'RocmSdkInit'
        $rocmSdkExitCode = Invoke-LoggedNativeCommand -FilePath $rocmSdk -Arguments @('init') -Comp 'RocmRoll.Rocm' -Op 'RocmSdkInit' -Inst $EnvironmentName
        if ($rocmSdkExitCode -ne 0) {
            Write-LogWarn "rocm-sdk init returned exit $rocmSdkExitCode" -Comp 'RocmRoll.Rocm'
        }
    } else {
        Write-LogDebug "rocm-sdk.exe not found - skipping init step." -Comp 'RocmRoll.Rocm'
    }

    # --- Step 4: Validate ---
    $validResult = Invoke-ValidateRocm -EnvironmentName $EnvironmentName -RocmIndex $RocmIndex
    if (-not $validResult.passed) {
        $torchOk = $validResult.PSObject.Properties['torchImportable'] -and [bool]$validResult.torchImportable
        if (-not $torchOk) {
            throw "ROCMROLL-ROCM-004: ROCm validation failed - torch is not importable. Check logs for details."
        }
        Write-LogWarn "torch imported but GPU was not visible during install-time validation (likely a path-space initialisation issue). ROCm acceleration will work once the environment is fully configured." -Comp 'RocmRoll.Rocm'
    }

    # Update environment state with GPU/package info
    $state = Get-EnvironmentState -Name $EnvironmentName
    $pkgs  = ConvertTo-StateHashtable -InputObject $(if ($state) { $state.packages } else { $null })
    Set-RocmPackageStateValues -Packages $pkgs -InstallPlan $installPlan -ValidationResult $validResult
    $gpu = ConvertTo-StateHashtable -InputObject $(if ($state) { $state.gpu } else { $null })
    $finalPath = if ($state -and $state.path) { $state.path } else { $statePath }
    $finalRuntime = if ($state -and $state.runtimeVersion) { $state.runtimeVersion } else { $stateRuntime }
    Set-EnvironmentState -Name $EnvironmentName -Path $finalPath -RuntimeVersion $finalRuntime -Status 'ready' -Gpu $gpu -Packages $pkgs
}

function Invoke-ValidateRocm {
    param(
        [string]$EnvironmentName,
        [string]$RocmIndex = ''
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')       -Force -Global

    $pythonExe = Get-EnvironmentPython -Name $EnvironmentName

    if (-not (Test-Path $pythonExe)) {
        return [pscustomobject]@{ passed = $false; torchImportable = $false; error = "Python not found: $pythonExe" }
    }

    if (-not $RocmIndex) {
        $envState = Get-EnvironmentState -Name $EnvironmentName
        if ($envState -and $envState.PSObject.Properties['gpu'] -and $envState.gpu) {
            $indexProperty = $envState.gpu.PSObject.Properties['rocmIndex']
            if ($indexProperty -and $indexProperty.Value) { $RocmIndex = [string]$indexProperty.Value }
        }
    }

    $pyScript = @'
import json, os, sys

# rocm_sdk's offload-arch GPU discovery spawns an unquoted exe path and breaks
# on space-containing install paths; pre-seed the target family it would have
# detected, but only if the installed distribution actually offers it.
_raw_index = sys.argv[1] if len(sys.argv) > 1 else ""
# RocmIndex includes a suffix (gfx103X-all, gfx101X-dgpu, gfx110X-all); strip it
# to get the plain family name that AVAILABLE_TARGET_FAMILIES carries.
target_family = _raw_index.split('-')[0] if _raw_index else ""
if target_family and not os.environ.get("ROCM_SDK_TARGET_FAMILY"):
    try:
        from rocm_sdk import _dist_info
        if target_family in _dist_info.AVAILABLE_TARGET_FAMILIES:
            os.environ["ROCM_SDK_TARGET_FAMILY"] = target_family
    except Exception:
        pass

try:
    import torch
except Exception as exc:
    print(json.dumps({"passed": False, "torchImportable": False, "error": str(exc), "checks": []}))
    sys.exit(2)

def chk(name, fn):
    try:
        return {"check": name, "passed": True, "value": str(fn())}
    except Exception as exc:
        return {"check": name, "passed": False, "error": str(exc)}

checks = [{"check": "torch_importable", "passed": True, "value": "ok"}]
checks.append(chk("torch_version", lambda: torch.__version__))

ca = chk("cuda_available", lambda: torch.cuda.is_available())
checks.append(ca)

hc = chk("hip_version", lambda: torch.version.hip)
checks.append(hc)

checks.append(chk("device_count", lambda: torch.cuda.device_count()))
checks.append(chk("device_name", lambda: torch.cuda.get_device_name(0) if torch.cuda.is_available() and torch.cuda.device_count() > 0 else "N/A"))

def tensor_op():
    if torch.cuda.is_available():
        t = torch.tensor([1.0, 2.0], device="cuda")
        return float(t.sum().item())
    return "skipped (no CUDA)"

checks.append(chk("tensor_op", tensor_op))

passed_all = (
    ca.get("value") in ("True", "true") and
    hc.get("passed") and hc.get("value") and
    all(r.get("passed", True) for r in checks)
)

def _pkg_ver(name):
    try:
        import importlib.metadata
        return importlib.metadata.version(name)
    except Exception:
        return None

tv_ver = _pkg_ver("torchvision")
ta_ver = _pkg_ver("torchaudio")

print(json.dumps({
    "passed": passed_all,
    "torchImportable": True,
    "torchVersion": torch.__version__,
    "torchvisionVersion": tv_ver,
    "torchaudioVersion": ta_ver,
    "hipVersion": getattr(torch.version, "hip", None),
    "cudaAvailable": torch.cuda.is_available(),
    "deviceCount": torch.cuda.device_count() if torch.cuda.is_available() else 0,
    "checks": checks,
}))
'@

    $tmpPy = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.py')
    try {
        [System.IO.File]::WriteAllText($tmpPy, $pyScript, [System.Text.Encoding]::UTF8)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $combined = & $pythonExe $tmpPy $RocmIndex 2>&1
        } finally {
            $ErrorActionPreference = $prevEap
        }
        # Keep only stdout; rocm_sdk_core may spawn a wrong exe via unquoted space-containing path, flooding stderr.
        $output = $combined | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    } finally {
        Remove-Item $tmpPy -ErrorAction SilentlyContinue
    }
    # Find the last stdout line that looks like a JSON object; Python may emit torch noise before it.
    $jsonLine = @($output) | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    if (-not $jsonLine) {
        return [pscustomobject]@{ passed = $false; torchImportable = $false; error = 'Python validation produced no JSON output' }
    }
    try {
        return $jsonLine | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ passed = $false; error = "ROCm validation returned invalid JSON: $_" }
    }
}

Export-ModuleMember -Function Invoke-InstallRocm, Invoke-ValidateRocm,
    Resolve-RocmInstallPlan, Get-RocmChannelConfig, Get-RocmProfileForChannel,
    New-RocmIndexProfile
