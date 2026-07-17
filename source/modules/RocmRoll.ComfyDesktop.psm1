#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.ComfyDesktop - Register and unregister ROCmRoll instances in ComfyUI Desktop.

.DESCRIPTION
    ComfyUI Desktop stores its installations in:
        %APPDATA%\Comfy Desktop\installations.json
    This module detects whether Desktop is present, builds the entry from instance/environment
    state, and mutates that file atomically.  Every function is a no-op when Desktop is absent.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

function Get-ComfyDesktopInstallationsPath {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    return Join-Path $appData 'Comfy Desktop\installations.json'
}

function Test-ComfyDesktopAvailable {
    return Test-Path (Get-ComfyDesktopInstallationsPath)
}

# ---------------------------------------------------------------------------
# JSON I/O (atomic write, no BOM)
# ---------------------------------------------------------------------------

function Get-ComfyDesktopInstallations {
    $path = Get-ComfyDesktopInstallationsPath
    if (-not (Test-Path $path)) { return @() }
    try
    {
        $raw = Get-Content $path -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } catch {
        Write-Warning "ComfyDesktop: Could not parse installations.json: $_"
        return @()
    }
}

function Write-ComfyDesktopInstallations {
    param([object[]]$Installations)

    $path = Get-ComfyDesktopInstallationsPath
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # ConvertTo-Json with a typed array ensures the output is always a JSON array,
    # even when only one element is present (PS5.1 quirk).
    $json = ConvertTo-Json -InputObject ([object[]]$Installations) -Depth 20
    $tmp  = "$path.tmp"
    Write-RocmRollTextFile -Path $tmp -Content $json
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ---------------------------------------------------------------------------
# GFX version conversion helper
# ---------------------------------------------------------------------------

function ConvertTo-HsaGfxVersion {
    <#
    Converts a 4-digit GFX family ID to the HSA_OVERRIDE_GFX_VERSION format.
    Examples:
        gfx1201  ->  12.0.1
        gfx1151  ->  11.5.1
        gfx1100  ->  11.0.0
    Returns $null for wildcard families (e.g. gfx120X) where no specific version
    can be derived.
    #>
    param([string]$GfxFamily)
    if ($GfxFamily -match '^gfx(\d{2})(\d)(\d)$') {
        return "$($Matches[1]).$($Matches[2]).$($Matches[3])"
    }
    return $null
}

# ---------------------------------------------------------------------------
# Entry builder
# ---------------------------------------------------------------------------

function New-ComfyDesktopEntry {
    <#
    Builds the installations.json entry object for a ROCmRoll instance.
    When ExistingId is provided the same id is reused (update path).
    When ProfileObject is provided its launchArgs and env are used instead of the hardcoded defaults.
    #>
    param(
        [string]$InstanceName,
        [object]$InstanceState,
        [object]$EnvironmentState,
        [string]$GfxFamily    = '',
        [string]$ExistingId   = '',
        [object]$ProfileObject = $null
    )

    $cfg = Get-Config

    # --- id / timestamp ---
    $id        = if ($ExistingId) { $ExistingId } else { "inst-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" }
    $createdAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # --- paths ---
    $instanceFolder = if ($InstanceState -and $InstanceState.PSObject.Properties['path'] -and $InstanceState.path) { $InstanceState.path } else { Join-Path $cfg.InstancesFolder $InstanceName }
    $envName        = if ($InstanceState -and $InstanceState.PSObject.Properties['environment'] -and $InstanceState.environment) { $InstanceState.environment } else { '' }
    $envFolder      = if ($EnvironmentState -and $EnvironmentState.PSObject.Properties['path'] -and $EnvironmentState.path) { $EnvironmentState.path } `
                      elseif ($envName) { Join-Path $cfg.EnvironmentsFolder $envName } `
                      else { '' }

    # --- ComfyUI git metadata ---
    $commit  = ''
    $repo    = 'https://github.com/Comfy-Org/ComfyUI.git'
    $branch  = 'master'
    if ($InstanceState -and $InstanceState.PSObject.Properties['comfyui'] -and $InstanceState.comfyui) {
        $cu = $InstanceState.comfyui
        if ($cu.PSObject.Properties['commit'] -and $cu.commit) { $commit = [string]$cu.commit }
        if ($cu.PSObject.Properties['repo']   -and $cu.repo)   { $repo   = [string]$cu.repo   }
        if ($cu.PSObject.Properties['ref']    -and $cu.ref)    { $branch = [string]$cu.ref     }
    }
    $shortCommit = if ($commit.Length -ge 8) { $commit.Substring(0, 8) } else { $commit }

    $isLegacy = $GfxFamily -imatch '^gfx(?:101X|103X)$'

    # --- launchArgs string ---
    $launchArgs = if ($ProfileObject) {
        $parts = @(
            "--input-directory $($cfg.InputFolder)",
            "--output-directory $($cfg.OutputFolder)"
        ) + @($ProfileObject.launchArgs)
        if ($isLegacy -and $ProfileObject.PSObject.Properties['legacyGpuOverrides'] -and $ProfileObject.legacyGpuOverrides -and $ProfileObject.legacyGpuOverrides.PSObject.Properties['launchArgs'] -and $ProfileObject.legacyGpuOverrides.launchArgs) {
            $parts = $parts + @($ProfileObject.legacyGpuOverrides.launchArgs)
        }
        $parts -join ' '
    } else {
        (
            "--input-directory $($cfg.InputFolder)",
            "--output-directory $($cfg.OutputFolder)",
            "--disable-api-nodes",
            "--disable-smart-memory",
            "--disable-pinned-memory",
            "--preview-method auto",
            "--use-sage-attention",
            "--enable-manager-legacy-ui",
            "--enable-dynamic-vram"
        ) -join ' '
    }

    # --- envVars ---
    $sitePackages  = if ($envFolder) { Join-Path $envFolder 'Lib\site-packages' } else { '' }
    $rocmSdkDevel  = if ($sitePackages) { Join-Path $sitePackages '_rocm_sdk_devel' } else { '' }
    $tunableOpDir  = Join-Path $cfg.CacheFolder 'tunableop'

    $envVars = [ordered]@{
        PYTHONHOME                    = $envFolder
        PYTHONPATH                    = $instanceFolder
        PIP_CACHE_DIR                 = $cfg.PipCacheFolder
        PIP_DISABLE_PIP_VERSION_CHECK = '1'
        PIP_NO_INPUT                  = '1'
        PIP_REQUIRE_VIRTUALENV        = 'FALSE'
        TRITON_CACHE_DIR              = $cfg.TritonCacheFolder
        PYTORCH_TUNABLEOP_CACHE_DIR   = $tunableOpDir
        HIP_VISIBLE_DEVICES           = '0'
    }

    # ROCM_HOME / HIP_PATH / ROCM_PATH - point at the rocm_sdk_devel root (contains
    # include/hip/hip_version.h and .info/version, which aiter's get_hip_version()
    # needs) if present, else the env Scripts dir. Must match instance.launch.ps1.tpl,
    # which points these at the devel root rather than its bin subfolder - pointing
    # at bin here previously made aiter's version-file lookup search bin\bin\... and
    # bin\include\..., neither of which exist, breaking ComfyUI Desktop launches
    # (direct ROCmRoll launches were unaffected since they set the root correctly).
    $rocmDevelRoot = if ($rocmSdkDevel) { $rocmSdkDevel } else { Join-Path $envFolder 'Scripts' }
    $envVars['ROCM_HOME'] = $rocmDevelRoot
    $envVars['HIP_PATH']  = $rocmDevelRoot
    $envVars['ROCM_PATH'] = $rocmDevelRoot

    # HSA_OVERRIDE_GFX_VERSION - only for specific (non-wildcard) GFX IDs
    $hsaVersion = ConvertTo-HsaGfxVersion -GfxFamily $GfxFamily
    if ($hsaVersion) {
        $envVars['HSA_OVERRIDE_GFX_VERSION'] = $hsaVersion
    }

    # MIOpen / ROCBlas paths (only when devel folder is present)
    if ($rocmSdkDevel -and (Test-Path $rocmSdkDevel)) {
        $envVars['MIOPEN_SYSTEM_DB_PATH']   = Join-Path $rocmSdkDevel 'bin'
        $envVars['ROCBLAS_TENSILE_DB_PATH'] = Join-Path $rocmSdkDevel 'bin\rocblas'
        $envVars['ROCBLAS_TENSILE_LIBPATH'] = Join-Path $rocmSdkDevel 'bin\rocblas\library'
    }

    if ($ProfileObject) {
        # Merge profile env on top of infrastructure vars; profile is authoritative for its own keys
        if ($ProfileObject.PSObject.Properties['env'] -and $ProfileObject.env) {
            foreach ($kv in $ProfileObject.env.PSObject.Properties) { $envVars[$kv.Name] = $kv.Value }
        }
        # Apply legacy GPU env overrides from the profile
        if ($isLegacy -and $ProfileObject.PSObject.Properties['legacyGpuOverrides'] -and $ProfileObject.legacyGpuOverrides -and $ProfileObject.legacyGpuOverrides.PSObject.Properties['env'] -and $ProfileObject.legacyGpuOverrides.env) {
            foreach ($kv in $ProfileObject.legacyGpuOverrides.env.PSObject.Properties) { $envVars[$kv.Name] = $kv.Value }
        }
    } else {
        # Hardcoded defaults when no profile is provided
        if ($isLegacy) {
            $envVars['TORCH_BACKENDS_CUDA_FLASH_SDP_ENABLED']    = '0'
            $envVars['TORCH_BACKENDS_CUDA_MEM_EFF_SDP_ENABLED']  = '0'
            $envVars['TORCH_BACKENDS_CUDA_MATH_SDP_ENABLED']     = '1'
        } else {
            $envVars['TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL']  = '1'
        }
        $envVars['COMFYUI_ENABLE_MIOPEN']             = '0'
        $envVars['FLASH_ATTENTION_TRITON_AMD_ENABLE']  = 'TRUE'
        $envVars['FLASH_ATTENTION_TRITON_AMD_AUTOTUNE']= 'TRUE'
        $envVars['MIOPEN_FIND_ENFORCE']                = '1'
        $envVars['MIOPEN_FIND_MODE']                   = '2'
        $envVars['MIOPEN_DEBUG_DISABLE_FIND_DB']       = '0'
        $envVars['MIOPEN_SEARCH_CUTOFF']               = '1'
        $envVars['MIOPEN_ENABLE_LOGGING']              = '0'
        $envVars['MIOPEN_LOG_LEVEL']                   = '0'
        $envVars['MIOPEN_ENABLE_LOGGING_CMD']          = '0'
        $envVars['TRITON_PRINT_AUTOTUNING']            = '0'
        $envVars['TRITON_CACHE_AUTOTUNING']            = '0'
    }

    return [pscustomobject][ordered]@{
        id               = $id
        createdAt        = $createdAt
        name             = $InstanceName
        installPath      = $instanceFolder
        sourceId         = 'git'
        sourceLabel      = 'Git Clone'
        version          = $shortCommit
        repo             = $repo
        branch           = $branch
        commit           = $commit
        launchMode       = 'window'
        browserPartition = 'shared'
        venvPath         = $envFolder
        status           = 'installed'
        seen             = $false
        launchArgs       = $launchArgs
        envVars          = $envVars
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Register-ComfyDesktopInstance {
    <#
    Adds or updates the ComfyUI Desktop entry for a ROCmRoll instance.
    Returns the entry id on success, or $null when Desktop is not available.

    Pass ExistingId to update an existing entry in place instead of appending.
    Pass ProfileObject to have the entry reflect a specific profile's launchArgs and env.
    #>
    param(
        [string]$InstanceName,
        [object]$InstanceState,
        [object]$EnvironmentState,
        [string]$GfxFamily     = '',
        [string]$ExistingId    = '',
        [object]$ProfileObject = $null
    )

    if (-not (Test-ComfyDesktopAvailable)) {
        Write-LogInfo "ComfyUI Desktop not detected - skipping registration" -Comp 'RocmRoll.ComfyDesktop'
        return $null
    }

    $desktopEntry = $null
    try
    {
        $desktopEntry = New-ComfyDesktopEntry -InstanceName $InstanceName `
                            -InstanceState $InstanceState -EnvironmentState $EnvironmentState `
                            -GfxFamily $GfxFamily -ExistingId $ExistingId -ProfileObject $ProfileObject

        if ($null -eq $desktopEntry)
        {
            Write-LogWarn "ComfyUI Desktop registration skipped for '$InstanceName': entry builder returned no entry" -Comp 'RocmRoll.ComfyDesktop'
            return $null
        }

        $desktopEntryId = ''
        if ($desktopEntry -is [System.Collections.IDictionary])
        {
            $desktopEntryId = [string]$desktopEntry['id']
        }
        else
        {
            if ($desktopEntry.PSObject.Properties['id'])
            {
                $desktopEntryId = [string]$desktopEntry.id
            }
        }

        if (-not $desktopEntryId)
        {
            Write-LogWarn "ComfyUI Desktop registration skipped for '$InstanceName': generated entry has no id" -Comp 'RocmRoll.ComfyDesktop'
            return $null
        }

        $installations = @(Get-ComfyDesktopInstallations)

        if ($ExistingId)
        {
            $found   = $false
            $updated = @()
            foreach ($inst in $installations)
            {
                if ($inst.PSObject.Properties['id'] -and $inst.id -eq $ExistingId)
                {
                    $updated += $desktopEntry
                    $found = $true
                }
                else
                {
                    $updated += $inst
                }
            }
            if (-not $found) { $updated = @($desktopEntry) + $updated }   # entry was removed externally - re-add
            $installations = $updated
        }
        else
        {
            $installations = @($desktopEntry) + $installations
        }

        Write-ComfyDesktopInstallations -Installations $installations
        Write-LogSuccess "Registered '$InstanceName' in ComfyUI Desktop (id=$desktopEntryId)" -Comp 'RocmRoll.ComfyDesktop'
        return $desktopEntryId
    }
    catch
    {
        Write-LogWarn "ComfyUI Desktop registration skipped for '$InstanceName': $($_.Exception.Message)" -Comp 'RocmRoll.ComfyDesktop'
        return $null
    }
}

function Unregister-ComfyDesktopInstance {
    <#
    Removes the ComfyUI Desktop entry for a ROCmRoll instance by its stored id.
    Silent no-op when Desktop is absent or the entry is already gone.
    #>
    param(
        [string]$InstanceName,
        [string]$ComfyDesktopId
    )

    if (-not (Test-ComfyDesktopAvailable)) { return }
    if (-not $ComfyDesktopId)             { return }

    $installations = @(Get-ComfyDesktopInstallations)
    $filtered      = @($installations | Where-Object { $_.id -ne $ComfyDesktopId })

    if ($filtered.Count -eq $installations.Count) {
        Write-LogInfo "ComfyUI Desktop: no entry found for '$InstanceName' (id=$ComfyDesktopId)" -Comp 'RocmRoll.ComfyDesktop'
        return
    }

    Write-ComfyDesktopInstallations -Installations $filtered
    Write-LogSuccess "Removed '$InstanceName' from ComfyUI Desktop (id=$ComfyDesktopId)" -Comp 'RocmRoll.ComfyDesktop'
}

Export-ModuleMember -Function `
    Get-ComfyDesktopInstallationsPath, Test-ComfyDesktopAvailable, `
    Get-ComfyDesktopInstallations, Write-ComfyDesktopInstallations, `
    ConvertTo-HsaGfxVersion, New-ComfyDesktopEntry, `
    Register-ComfyDesktopInstance, Unregister-ComfyDesktopInstance
