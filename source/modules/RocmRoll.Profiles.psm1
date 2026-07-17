#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Profiles - Execution profile management.

.DESCRIPTION
    Provides functions to list, load, create, and remove execution profiles.
    Profiles are JSON files stored in the profiles/ directory (configurable via
    rocmroll.ini). Each profile defines environment variables and ComfyUI launch
    arguments that are applied at launcher runtime.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

# ---------------------------------------------------------------------------
# Module-scope option lists (single source of truth for valid values)
# ---------------------------------------------------------------------------

$script:VramModes       = @('auto','gpu-only','highvram','lowvram','novram','cpu')
$script:AttentionModes  = @('default','sage','flash','split','quad','pytorch')
$script:PrecisionModes  = @('default','fp16','fp32','bf16','fp8-e4m3fn','fp8-e5m2')
$script:GlobalPrecModes = @('default','fp16','fp32')
$script:VaePrecModes    = @('default','fp16','fp32','bf16','cpu')
$script:TextEncPrecModes= @('default','fp16','fp32','bf16')
$script:CacheModes      = @('default','classic','lru','none')
$script:PreviewMethods  = @('auto','none','taesd','latent2rgb')
$script:FastOptNames    = @('fp16_accumulation','fp8_matrix_mult','cublas_ops','autotune')

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

function Get-ProfilePath {
    <#
    .SYNOPSIS
        Resolves the full path to a named profile JSON file.

    .DESCRIPTION
        Checks the configured/workspace ProfilesFolder first. If the profile
        isn't there and -PrimaryOnly isn't set, falls back to the repo's
        built-in <RootFolder>\profiles - the same "overlay wins over
        default" precedent used for extra_model_paths.yaml, and needed
        because a workspace can redirect ProfilesFolder somewhere that
        doesn't have ROCmRoll's shipped profiles (stable.json, optimized.json,
        etc.). -PrimaryOnly is used by Remove-Profile so deleting a profile
        can never reach into and delete a shipped built-in.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Config = $null,
        [switch]$PrimaryOnly
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $primaryPath = Join-Path $Config.ProfilesFolder "$Name.json"
    if (Test-Path $primaryPath) { return $primaryPath }

    if ($PrimaryOnly) {
        throw "ROCMROLL-PROFILE-001: Profile '$Name' not found at '$primaryPath'. Run 'rocmroll profile list' to see available profiles."
    }

    $fallbackPath = Join-Path (Join-Path $Config.RootFolder 'profiles') "$Name.json"
    if (Test-Path $fallbackPath) { return $fallbackPath }

    throw "ROCMROLL-PROFILE-001: Profile '$Name' not found at '$primaryPath' or '$fallbackPath'. Run 'rocmroll profile list' to see available profiles."
}

function Get-ProfileObject {
    <#
    .SYNOPSIS
        Loads and returns a profile as a PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $path = Get-ProfilePath -Name $Name -Config $Config
    try {
        $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "ROCMROLL-PROFILE-002: Failed to parse profile '$Name': $_"
    }
    return $obj
}

function Get-ProfileList {
    <#
    .SYNOPSIS
        Returns all profiles found in the ProfilesFolder as PSCustomObjects,
        falling back to the repo's built-in <RootFolder>\profiles for any
        name not present in the primary folder (see Get-ProfilePath).
    #>
    param(
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $primaryFolder  = $Config.ProfilesFolder
    $fallbackFolder = Join-Path $Config.RootFolder 'profiles'
    $seen = [ordered]@{}

    if (Test-Path $primaryFolder) {
        foreach ($file in (Get-ChildItem -Path $primaryFolder -Filter '*.json')) {
            try {
                $seen[$file.BaseName.ToLowerInvariant()] = (Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
            } catch {
                Write-LogWarn "Skipping malformed profile file: $($file.Name)" -Comp 'RocmRoll.Profiles'
            }
        }
    }

    $sameFolder = ([System.IO.Path]::GetFullPath($fallbackFolder).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($primaryFolder).TrimEnd('\'))
    if (-not $sameFolder -and (Test-Path $fallbackFolder)) {
        foreach ($file in (Get-ChildItem -Path $fallbackFolder -Filter '*.json')) {
            $key = $file.BaseName.ToLowerInvariant()
            if ($seen.Contains($key)) { continue }
            try {
                $seen[$key] = (Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
            } catch {
                Write-LogWarn "Skipping malformed profile file: $($file.Name)" -Comp 'RocmRoll.Profiles'
            }
        }
    }

    return @($seen.Keys | Sort-Object | ForEach-Object { $seen[$_] })
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

function Show-ProfileDetail {
    <#
    .SYNOPSIS
        Formats and prints one or more profile objects to the console.
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)][PSCustomObject]$ProfileData
    )

    process {
        $name = if ($ProfileData.name) { $ProfileData.name } else { '(unnamed)' }
        $desc = if ($ProfileData.description) { $ProfileData.description } else { '' }
        $channels = if ($ProfileData.defaultForChannels -and $ProfileData.defaultForChannels.Count -gt 0) {
            $ProfileData.defaultForChannels -join ', '
        } else { '(none)' }

        Write-Host ''
        Write-Host "  Profile     : $name" -ForegroundColor Cyan
        if ($desc) { Write-Host "  Description : $desc" }
        Write-Host "  Default for : $channels"

        if ($ProfileData.env) {
            Write-Host '  Env vars    :' -ForegroundColor DarkGray
            foreach ($kv in $ProfileData.env.PSObject.Properties) {
                Write-Host "    $($kv.Name) = $($kv.Value)" -ForegroundColor DarkGray
            }
        }

        if ($ProfileData.launchArgs -and $ProfileData.launchArgs.Count -gt 0) {
            Write-Host "  Launch args : $($ProfileData.launchArgs -join ' ')" -ForegroundColor DarkGray
        }

        if ($ProfileData.legacyGpuOverrides) {
            Write-Host '  Legacy GPU overrides:' -ForegroundColor DarkGray
            if ($ProfileData.legacyGpuOverrides.env) {
                foreach ($kv in $ProfileData.legacyGpuOverrides.env.PSObject.Properties) {
                    Write-Host "    (env) $($kv.Name) = $($kv.Value)" -ForegroundColor DarkGray
                }
            }
            if ($ProfileData.legacyGpuOverrides.launchArgs) {
                Write-Host "    (args) $($ProfileData.legacyGpuOverrides.launchArgs -join ' ')" -ForegroundColor DarkGray
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Create / Wizard
# ---------------------------------------------------------------------------

function New-ProfileInteractive {
    <#
    .SYNOPSIS
        Interactive wizard to create a new execution profile.
    #>
    param(
        [string]$Name = '',
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    Write-Host ''
    Write-Host '  ROCmRoll Profile Wizard' -ForegroundColor Cyan
    Write-Host '  -----------------------'

    # Profile name
    if (-not $Name) {
        $Name = (Read-Host '  Profile name (alphanumeric, hyphens)').Trim()
    }
    if (-not $Name -or $Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\-]*$') {
        throw 'ROCMROLL-PROFILE-003: Profile name must start with a letter or digit and contain only letters, digits, and hyphens.'
    }

    $destPath = Join-Path $Config.ProfilesFolder "$Name.json"
    if (Test-Path $destPath) {
        $overwrite = (Read-Host "  Profile '$Name' already exists. Overwrite? [y/N]").Trim()
        if ($overwrite -notmatch '^[yY]') { Write-Host '  Cancelled.'; return }
    }

    # Description
    $description = (Read-Host '  Description (press Enter to skip)').Trim()

    # Base profile
    $availableProfiles = @(Get-ProfileList -Config $Config)
    $baseChoice = ''
    if ($availableProfiles.Count -gt 0) {
        Write-Host ''
        Write-Host '  Available base profiles:'
        foreach ($p in $availableProfiles) { Write-Host "    - $($p.name)" }
        $baseChoice = (Read-Host '  Base this profile on an existing one? (enter name or press Enter to start blank)').Trim()
    }

    $envVars    = [ordered]@{}
    $launchArgs = @()
    $legacyEnv  = [ordered]@{}
    $legacyArgs = @()

    if ($baseChoice) {
        try {
            $base       = Get-ProfileObject -Name $baseChoice -Config $Config
            foreach ($kv in $base.env.PSObject.Properties) { $envVars[$kv.Name] = $kv.Value }
            $launchArgs = @($base.launchArgs)
            if ($base.legacyGpuOverrides) {
                foreach ($kv in $base.legacyGpuOverrides.env.PSObject.Properties) { $legacyEnv[$kv.Name] = $kv.Value }
                $legacyArgs = @($base.legacyGpuOverrides.launchArgs)
            }
            Write-Host "  Based on: $baseChoice"
        } catch {
            Write-Host "  Warning: could not load base profile '$baseChoice', starting blank." -ForegroundColor Yellow
        }
    }

    # ---------------------------------------------------------------------------
    # VRAM & Memory
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- VRAM & Memory --' -ForegroundColor Yellow

    $qVram = (Read-Host '  VRAM mode [auto/gpu-only/highvram/lowvram/novram/cpu] (default: auto)').Trim().ToLower()
    if ($qVram -notin $script:VramModes) { $qVram = 'auto' }

    $qDynVram = (Read-Host '  Enable dynamic VRAM (--enable-dynamic-vram)? [Y/n]').Trim()
    $wantDynamicVram = $qDynVram -notmatch '^[nN]'

    $qNoSmartMem = (Read-Host '  Disable smart memory (--disable-smart-memory)? [Y/n]').Trim()
    $wantNoSmartMem = $qNoSmartMem -notmatch '^[nN]'

    $qNoPinnedMem = (Read-Host '  Disable pinned memory (--disable-pinned-memory)? [Y/n]').Trim()
    $wantNoPinnedMem = $qNoPinnedMem -notmatch '^[nN]'

    $qFastDisk = (Read-Host '  Fast disk (prefer disk-backed dynamic loading)? [y/N]').Trim()
    $wantFastDisk = $qFastDisk -match '^[yY]'

    $qReserveVram = (Read-Host '  Reserve VRAM for OS in GB (blank = auto)').Trim()
    $reserveVramGb = if ($qReserveVram -match '^\d+(\.\d+)?$') { $qReserveVram } else { '' }

    # ---------------------------------------------------------------------------
    # Attention
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Attention --' -ForegroundColor Yellow

    $qAttn = (Read-Host '  Attention mechanism [default/sage/flash/split/quad/pytorch] (default: default)').Trim().ToLower()
    if ($qAttn -notin $script:AttentionModes) { $qAttn = 'default' }

    # ---------------------------------------------------------------------------
    # Precision
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Precision --' -ForegroundColor Yellow

    $qGlobalPrec = (Read-Host '  Global precision [default/fp16/fp32] (default: default)').Trim().ToLower()
    if ($qGlobalPrec -notin $script:GlobalPrecModes) { $qGlobalPrec = 'default' }

    $qUnetPrec = (Read-Host '  UNET precision [default/fp16/fp32/bf16/fp8-e4m3fn/fp8-e5m2] (default: default)').Trim().ToLower()
    if ($qUnetPrec -notin $script:PrecisionModes) { $qUnetPrec = 'default' }

    $qVaePrec = (Read-Host '  VAE precision [default/fp16/fp32/bf16/cpu] (default: default)').Trim().ToLower()
    if ($qVaePrec -notin $script:VaePrecModes) { $qVaePrec = 'default' }

    $qTextEncPrec = (Read-Host '  Text encoder precision [default/fp16/fp32/bf16] (default: default)').Trim().ToLower()
    if ($qTextEncPrec -notin $script:TextEncPrecModes) { $qTextEncPrec = 'default' }

    # ---------------------------------------------------------------------------
    # Cache
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Cache --' -ForegroundColor Yellow

    $qCache = (Read-Host '  Cache strategy [default/classic/lru/none] (default: default)').Trim().ToLower()
    if ($qCache -notin $script:CacheModes) { $qCache = 'default' }
    $cacheLruCount = ''
    if ($qCache -eq 'lru') {
        $qLruN = (Read-Host '  LRU cache size (number of node results to cache, e.g. 10)').Trim()
        $cacheLruCount = if ($qLruN -match '^\d+$') { $qLruN } else { '10' }
    }

    # ---------------------------------------------------------------------------
    # Preview
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Preview --' -ForegroundColor Yellow

    $qPreview = (Read-Host '  Preview method [auto/none/taesd/latent2rgb] (default: auto)').Trim().ToLower()
    $previewMethod = if ($qPreview -in $script:PreviewMethods) { $qPreview } else { 'auto' }

    $qPreviewSize = (Read-Host '  Preview size in pixels (blank = default 512)').Trim()
    $previewSize = if ($qPreviewSize -match '^\d+$' -and $qPreviewSize -ne '512') { $qPreviewSize } else { '' }

    # ---------------------------------------------------------------------------
    # ROCm / AMD
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- ROCm / AMD --' -ForegroundColor Yellow

    $qFlashAttn = (Read-Host '  Enable Flash-Attention Triton AMD backend? [Y/n]').Trim()
    $wantFlashAttn = $qFlashAttn -notmatch '^[nN]'

    $qMiopen = (Read-Host '  Enable MIOpen (COMFYUI_ENABLE_MIOPEN=1)? [y/N]').Trim()
    $wantMiopen = $qMiopen -match '^[yY]'

    $qTritonBackend = (Read-Host '  Enable ComfyUI Triton backend (--enable-triton-backend)? [y/N]').Trim()
    $wantTritonBackend = $qTritonBackend -match '^[yY]'

    # ---------------------------------------------------------------------------
    # Fast optimizations
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Fast Optimizations --' -ForegroundColor Yellow

    $validFastOpts = $script:FastOptNames
    $qFast = (Read-Host '  Fast options - comma-separated from: fp16_accumulation, fp8_matrix_mult, autotune (blank = none)').Trim()
    $fastOpts = @()
    if ($qFast) {
        $fastOpts = @($qFast -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -in $validFastOpts })
    }

    # ---------------------------------------------------------------------------
    # Other
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Other --' -ForegroundColor Yellow

    $qDisableCustomNodes = (Read-Host '  Disable all custom nodes (--disable-all-custom-nodes)? [y/N]').Trim()
    $wantDisableCustomNodes = $qDisableCustomNodes -match '^[yY]'

    $qDisableMmap = (Read-Host '  Disable mmap for safetensors (--disable-mmap)? [y/N]').Trim()
    $wantDisableMmap = $qDisableMmap -match '^[yY]'

    # ---------------------------------------------------------------------------
    # Assemble env vars
    # ---------------------------------------------------------------------------
    $envVars['PYTHONUNBUFFERED']    = '1'
    $envVars['PYTHONIOENCODING']    = 'utf-8'
    $envVars['PYTHONUTF8']         = '1'

    if ($wantFlashAttn) {
        $envVars['FLASH_ATTENTION_TRITON_AMD_ENABLE']   = 'TRUE'
        $envVars['FLASH_ATTENTION_TRITON_AMD_AUTOTUNE'] = 'TRUE'
    } else {
        $envVars.Remove('FLASH_ATTENTION_TRITON_AMD_ENABLE')
        $envVars.Remove('FLASH_ATTENTION_TRITON_AMD_AUTOTUNE')
    }

    $envVars['COMFYUI_ENABLE_MIOPEN'] = if ($wantMiopen) { '1' } else { '0' }

    # ---------------------------------------------------------------------------
    # Assemble launch args (rebuild from scratch to avoid duplicates)
    # ---------------------------------------------------------------------------
    $newLaunchArgs = [System.Collections.Generic.List[string]]::new()
    $newLaunchArgs.Add('--disable-api-nodes')

    # VRAM mode (mutually exclusive)
    switch ($qVram) {
        'gpu-only' { $newLaunchArgs.Add('--gpu-only') }
        'highvram' { $newLaunchArgs.Add('--highvram') }
        'lowvram'  { $newLaunchArgs.Add('--lowvram') }
        'novram'   { $newLaunchArgs.Add('--novram') }
        'cpu'      { $newLaunchArgs.Add('--cpu') }
        # auto: no flag
    }

    if ($reserveVramGb) {
        $newLaunchArgs.Add('--reserve-vram')
        $newLaunchArgs.Add($reserveVramGb)
    }

    if ($wantNoSmartMem)   { $newLaunchArgs.Add('--disable-smart-memory') }
    if ($wantNoPinnedMem)  { $newLaunchArgs.Add('--disable-pinned-memory') }
    if ($wantFastDisk)     { $newLaunchArgs.Add('--fast-disk') }
    if ($wantDynamicVram)  { $newLaunchArgs.Add('--enable-dynamic-vram') }

    # Attention (mutually exclusive)
    switch ($qAttn) {
        'sage'    { $newLaunchArgs.Add('--use-sage-attention') }
        'flash'   { $newLaunchArgs.Add('--use-flash-attention') }
        'split'   { $newLaunchArgs.Add('--use-split-cross-attention') }
        'quad'    { $newLaunchArgs.Add('--use-quad-cross-attention') }
        'pytorch' { $newLaunchArgs.Add('--use-pytorch-cross-attention') }
        # default: no flag
    }

    # Global precision (mutually exclusive)
    switch ($qGlobalPrec) {
        'fp16' { $newLaunchArgs.Add('--force-fp16') }
        'fp32' { $newLaunchArgs.Add('--force-fp32') }
    }

    # UNET precision
    switch ($qUnetPrec) {
        'fp16'       { $newLaunchArgs.Add('--fp16-unet') }
        'fp32'       { $newLaunchArgs.Add('--fp32-unet') }
        'bf16'       { $newLaunchArgs.Add('--bf16-unet') }
        'fp8-e4m3fn' { $newLaunchArgs.Add('--fp8_e4m3fn-unet') }
        'fp8-e5m2'   { $newLaunchArgs.Add('--fp8_e5m2-unet') }
    }

    # VAE precision
    switch ($qVaePrec) {
        'fp16' { $newLaunchArgs.Add('--fp16-vae') }
        'fp32' { $newLaunchArgs.Add('--fp32-vae') }
        'bf16' { $newLaunchArgs.Add('--bf16-vae') }
        'cpu'  { $newLaunchArgs.Add('--cpu-vae') }
    }

    # Text encoder precision
    switch ($qTextEncPrec) {
        'fp16' { $newLaunchArgs.Add('--fp16-text-enc') }
        'fp32' { $newLaunchArgs.Add('--fp32-text-enc') }
        'bf16' { $newLaunchArgs.Add('--bf16-text-enc') }
    }

    # Cache strategy (mutually exclusive)
    switch ($qCache) {
        'classic' { $newLaunchArgs.Add('--cache-classic') }
        'lru'     { $newLaunchArgs.Add('--cache-lru'); $newLaunchArgs.Add($cacheLruCount) }
        'none'    { $newLaunchArgs.Add('--cache-none') }
    }

    # Preview
    $newLaunchArgs.Add('--preview-method')
    $newLaunchArgs.Add($previewMethod)
    if ($previewSize) {
        $newLaunchArgs.Add('--preview-size')
        $newLaunchArgs.Add($previewSize)
    }

    $newLaunchArgs.Add('--enable-manager-legacy-ui')

    if ($wantTritonBackend)      { $newLaunchArgs.Add('--enable-triton-backend') }
    if ($wantDisableCustomNodes) { $newLaunchArgs.Add('--disable-all-custom-nodes') }
    if ($wantDisableMmap)        { $newLaunchArgs.Add('--disable-mmap') }

    # Fast options
    if ($fastOpts.Count -gt 0) {
        $newLaunchArgs.Add('--fast')
        $newLaunchArgs.Add(($fastOpts -join ','))
    }

    $launchArgs = $newLaunchArgs.ToArray()

    $profileObj = [ordered]@{
        name               = $Name
        description        = $description
        version            = '1.0'
        defaultForChannels = @()
        env                = $envVars
        launchArgs         = $launchArgs
        legacyGpuOverrides = [ordered]@{
            env        = $legacyEnv
            launchArgs = $legacyArgs
        }
    }

    Save-ProfileObject -ProfileObj $profileObj -DestPath $destPath -Name $Name -Config $Config
}

function Save-ProfileObject {
    param(
        [Parameter(Mandatory)][object]$ProfileObj,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Config
    )

    if (-not (Test-Path $Config.ProfilesFolder)) {
        New-Item -ItemType Directory -Path $Config.ProfilesFolder -Force | Out-Null
    }

    $json = Format-RocmRollJson -Data $ProfileObj
    [System.IO.File]::WriteAllText($DestPath, $json, (New-RocmRollUtf8NoBomEncoding))

    Write-Host ''
    Write-Host "  Profile '$Name' saved to: $DestPath" -ForegroundColor Green
    Write-LogSuccess "Profile '$Name' created at '$DestPath'" -Comp 'RocmRoll.Profiles'
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------

function Remove-Profile {
    <#
    .SYNOPSIS
        Deletes a named profile after confirmation.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    # -PrimaryOnly: removal must never reach into <RootFolder>\profiles and
    # delete a shipped built-in profile via the fallback.
    $path = Get-ProfilePath -Name $Name -Config $Config -PrimaryOnly

    if (-not $Force) {
        $confirm = (Read-Host "  Remove profile '$Name'? [y/N]").Trim()
        if ($confirm -notmatch '^[yY]') { Write-Host '  Cancelled.'; return }
    }

    Remove-Item $path -Force
    Write-Host "  Profile '$Name' removed." -ForegroundColor Yellow
    Write-LogInfo "Profile '$Name' removed" -Comp 'RocmRoll.Profiles'
}

# ---------------------------------------------------------------------------
# Resolve default profile for a channel
# ---------------------------------------------------------------------------

function Resolve-ChannelDefaultProfile {
    <#
    .SYNOPSIS
        Returns the default profile name for a given channel from channels.json.
        Falls back to 'optimized' if the field is missing.
    #>
    param(
        [string]$Channel,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $manifestPath = Join-Path $Config.ManifestsFolder 'channels.json'
    if (-not (Test-Path $manifestPath)) { return 'optimized' }

    try {
        $channels = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $chan = $channels.$Channel
        if ($chan -and $chan.defaultProfile) { return $chan.defaultProfile }
    } catch { }

    return 'optimized'
}

Export-ModuleMember -Function `
    Get-ProfilePath, Get-ProfileObject, Get-ProfileList, `
    Show-ProfileDetail, New-ProfileInteractive, Remove-Profile, `
    Resolve-ChannelDefaultProfile
