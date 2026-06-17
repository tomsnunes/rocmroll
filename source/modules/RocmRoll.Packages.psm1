#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Packages - Package-profile installation and patch application.

.DESCRIPTION
    Reads package-profiles.json from the manifests folder and patch definitions
    from source\patches\sageattention\. Installs packages defined in a named
    profile and applies any patches referenced by those packages. Called from
    Invoke-FullInstall (Core) to handle the ROCm performance stack: triton,
    sageattention (+patches), bitsandbytes, flash-attn, amd-aiter.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Get-PackageProfileManifest {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg  = Get-Config
    $path = Join-Path $cfg.ManifestsFolder 'package-profiles.json'
    if (-not (Test-Path $path)) { throw "ROCMROLL-PKG-001: package-profiles.json not found at '$path'" }
    return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-PatchesManifest {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $dir = Join-Path $cfg.SourceFolder 'patches\sageattention'
    $patches = @()
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem $dir -Filter '*.json' | Sort-Object Name)) {
            $patches += (Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    }
    return [PSCustomObject]@{ patches = $patches }
}

# ---------------------------------------------------------------------------
# Public: Apply a named patch to an environment
# ---------------------------------------------------------------------------

function Invoke-ApplyPatch {
    param(
        [Parameter(Mandatory)][string]$PatchId,
        [Parameter(Mandatory)][string]$EnvironmentFolder
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Download.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1') -Force -Global

    $cfg = Get-Config
    $patchesManifest = Get-PatchesManifest
    $patch = $patchesManifest.patches | Where-Object { $_.id -eq $PatchId } | Select-Object -First 1

    if (-not $patch) {
        Write-LogWarn "Patch '$PatchId' not found in patches.json - skipping" -Comp 'RocmRoll.Packages'
        return
    }

    Write-LogInfo "Applying patch '$PatchId': $($patch.description)" -Comp 'RocmRoll.Packages' -Op 'ApplyPatch'

    $patchDownloadFolder = Join-Path (Join-Path $cfg.DownloadsFolder 'patches') $PatchId
    $backupDir = Join-Path $cfg.PatchStateFolder $PatchId
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    foreach ($file in $patch.files) {
        $targetRelativePath = [string]$file.target
        $targetRelativePath = $targetRelativePath.Replace('/', '\')
        $targetPath = Join-Path $EnvironmentFolder $targetRelativePath
        $targetDir  = Split-Path $targetPath -Parent

        if (-not (Test-Path $targetDir)) {
            throw "ROCMROLL-PATCH-002: Target directory not found for patch '$PatchId': $targetDir"
        }

        Write-LogInfo "  Patching: $($file.target)" -Comp 'RocmRoll.Packages'
        try {
            $downloadedFile = Invoke-CachedDownload -Url $file.source -DestFolder $patchDownloadFolder
            if (-not (Test-Path $downloadedFile)) {
                throw "Downloaded patch file not found: $downloadedFile"
            }

            $downloadedLength = (Get-Item -LiteralPath $downloadedFile).Length
            if ($downloadedLength -le 0) {
                throw "Downloaded patch file is empty: $($file.source)"
            }

            $backupName = $targetRelativePath -replace '[\\/]', '---'
            $backupPath = Join-Path $backupDir $backupName
            if ((Test-Path $targetPath) -and -not (Test-Path $backupPath)) {
                Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
            }

            Copy-Item -LiteralPath $downloadedFile -Destination $targetPath -Force
            Write-LogSuccess "  Patched: $($file.target)" -Comp 'RocmRoll.Packages'
        } catch {
            throw "ROCMROLL-PATCH-003: Failed to patch '$($file.target)': $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Public: Install all packages in a named profile
# ---------------------------------------------------------------------------

function Invoke-InstallPackageProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [string]$GfxVersion = ''
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1') -Force -Global

    $cfg = Get-Config
    $pythonExe = Get-EnvironmentPython -Name $EnvironmentName
    $envFolder = Join-Path $cfg.EnvironmentsFolder $EnvironmentName
    $manifest = Get-PackageProfileManifest
    $pkgProfile = $manifest.$ProfileName

    if (-not $pkgProfile) {
        throw "ROCMROLL-PKG-003: Package profile '$ProfileName' not found in package-profiles.json"
    }

    if (-not $pkgProfile.packages -or $pkgProfile.packages.Count -eq 0) {
        Write-LogInfo "Profile '$ProfileName' has no packages; nothing to install." -Comp 'RocmRoll.Packages'
        return
    }

    $env:PYTHONHOME = ''
    $env:PYTHONPATH = ''
    $env:PIP_CACHE_DIR = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_INPUT = '1'
    $env:PIP_REQUIRE_VIRTUALENV = 'false'

    $failedPackages = @{}
    $installedPackages = @{}

    foreach ($pkg in $pkgProfile.packages) {
        if ($pkg.PSObject.Properties['skipArchitectures'] -and $pkg.skipArchitectures -and $GfxVersion) {
            $shouldSkip = $false
            foreach ($skipArch in $pkg.skipArchitectures) {
                if ($GfxVersion -ieq $skipArch) {
                    $shouldSkip = $true
                    break
                }
            }

            if ($shouldSkip) {
                Write-LogInfo "Skipping '$($pkg.name)' because architecture '$GfxVersion' is unsupported." -Comp 'RocmRoll.Packages'
                continue
            }
        }

        if ($pkg.PSObject.Properties['dependsOn'] -and $pkg.dependsOn) {
            $missingDependency = $false
            foreach ($dependency in $pkg.dependsOn) {
                if ($failedPackages.ContainsKey($dependency) -or -not $installedPackages.ContainsKey($dependency)) {
                    Write-LogWarn "Skipping '$($pkg.name)' because dependency '$dependency' was not installed successfully." -Comp 'RocmRoll.Packages'
                    $missingDependency = $true
                    break
                }
            }

            if ($missingDependency) {
                continue
            }
        }

        Write-LogInfo "Installing package: $($pkg.name)" -Comp 'RocmRoll.Packages' -Op 'InstallPackage'

        $installTarget = switch ($pkg.source) {
            'pypi' {
                if ($pkg.PSObject.Properties['version'] -and $pkg.version) {
                    "$($pkg.name)==$($pkg.version)"
                } else {
                    $pkg.name
                }
            }
            'url' {
                $pkg.url
            }
            default {
                throw "ROCMROLL-PKG-004: Unknown package source '$($pkg.source)' for '$($pkg.name)'"
            }
        }

        $pipArgs = @('-m', 'pip', 'install', '--cache-dir', $cfg.PipCacheFolder, $installTarget)
        $exitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $pipArgs `
            -Comp 'RocmRoll.Packages' -Op 'InstallPackage' -Inst $EnvironmentName

        if ($exitCode -ne 0) {
            $failedPackages[$pkg.name] = $true
            if ($pkg.PSObject.Properties['required'] -and $pkg.required) {
                throw "ROCMROLL-PKG-005: Required package '$($pkg.name)' failed to install (exit $exitCode)"
            }

            Write-LogWarn "Optional package '$($pkg.name)' failed to install (exit $exitCode); skipping." -Comp 'RocmRoll.Packages'
            continue
        }

        $installedPackages[$pkg.name] = $true
        Write-LogSuccess "Installed: $($pkg.name)" -Comp 'RocmRoll.Packages'

        if ($pkg.PSObject.Properties['patches'] -and $pkg.patches) {
            foreach ($patchId in $pkg.patches) {
                Invoke-ApplyPatch -PatchId $patchId -EnvironmentFolder $envFolder
            }
        }
    }
}

Export-ModuleMember -Function Invoke-InstallPackageProfile, Invoke-ApplyPatch
