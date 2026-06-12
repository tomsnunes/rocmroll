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
    $rocmPackages = @(ConvertTo-RocmStringArray -Value (Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'rocmPackages'))
    if ($torchPackages.Count -eq 0) { $torchPackages = @('torch', 'torchvision', 'torchaudio') }
    if ($rocmPackages.Count -eq 0) { $rocmPackages = @('rocm[libraries,devel]') }

    $profileAllowPreRelease = [bool](Get-RocmObjectValue -InputObject $RocmProfile -PropertyName 'allowPreRelease' -DefaultValue $false)
    $effectiveAllowPreRelease = $profileAllowPreRelease -or [bool]$AllowPreRelease

    $torchArgs = @(
        '-m', 'pip', 'install',
        '--index-url', $indexUrl,
        '--cache-dir', $cfg.PipCacheFolder,
        '--upgrade-strategy', 'only-if-needed'
    )
    $rocmArgs = @(
        '-m', 'pip', 'install',
        '--index-url', $indexUrl,
        '--cache-dir', $cfg.PipCacheFolder
    )
    if ($UseWheelhouse -and $WheelhouseFolder) {
        $torchArgs += @('--find-links', $WheelhouseFolder)
        $rocmArgs += @('--find-links', $WheelhouseFolder)
    }
    if ($effectiveAllowPreRelease) {
        $torchArgs += '--pre'
        $rocmArgs += '--pre'
    }
    $torchArgs += $torchPackages
    $rocmArgs += $rocmPackages

    return [pscustomobject][ordered]@{
        source             = 'index'
        rocmIndex          = $RocmIndex
        indexUrl           = $indexUrl
        allowPreRelease    = $effectiveAllowPreRelease
        sdkArgs            = @()
        torchArgs          = @($torchArgs)
        rocmArgs           = @($rocmArgs)
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
    $Packages['torchvision'] = if ($InstallPlan.torchvisionVersion) { [string]$InstallPlan.torchvisionVersion } else { 'installed' }
    $Packages['torchaudio'] = if ($InstallPlan.torchaudioVersion) { [string]$InstallPlan.torchaudioVersion } else { 'installed' }
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
        $existingValidation = Invoke-ValidateRocm -EnvironmentName $EnvironmentName
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

    if ($installPlan.sdkArgs.Count -gt 0) {
        Write-LogInfo "Installing ROCm SDK packages from AMD direct URLs" -Comp 'RocmRoll.Rocm' -Op 'InstallRocmSdk' -Inst $EnvironmentName
        $sdkExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $installPlan.sdkArgs -Comp 'RocmRoll.Rocm' -Op 'InstallRocmSdk' -Inst $EnvironmentName
        if ($sdkExitCode -ne 0) {
            throw "ROCMROLL-ROCM-010: Failed to install ROCm SDK direct URL packages (exit $sdkExitCode)"
        }
        Write-LogSuccess "ROCm SDK packages installed" -Comp 'RocmRoll.Rocm'
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
    Write-LogSuccess "torch installed" -Comp 'RocmRoll.Rocm'

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
    $validResult = Invoke-ValidateRocm -EnvironmentName $EnvironmentName
    if (-not $validResult.passed) {
        throw "ROCMROLL-ROCM-004: ROCm validation failed. Check logs for details."
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
    param([string]$EnvironmentName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global

    $cfg       = Get-Config
    $pythonExe = Get-EnvironmentPython -Name $EnvironmentName
    $script    = Join-Path $cfg.ScriptsFolder 'verify_rocm.py'

    $output = & $pythonExe $script --json --quiet 2>$null
    try {
        return $output | ConvertFrom-Json
    } catch {
        return @{ passed=$false; error="Invalid JSON from verify_rocm.py: $_" }
    }
}

Export-ModuleMember -Function Invoke-InstallRocm, Invoke-ValidateRocm,
    Resolve-RocmInstallPlan, Get-RocmChannelConfig, Get-RocmProfileForChannel,
    New-RocmIndexProfile
