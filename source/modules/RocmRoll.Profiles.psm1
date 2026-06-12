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

# ---------------------------------------------------------------------------
# JSON formatter (PS5.1 ConvertTo-Json produces double-spaces and alignment
# indentation - this function always emits clean 2-space indented JSON)
# ---------------------------------------------------------------------------

function Get-ProfileFieldValue {
    param([object]$Obj, [string]$Key)
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Key] }
    $prop = $Obj.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ProfileFieldKeys {
    param([object]$Obj)
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys) }
    return @($Obj.PSObject.Properties.Name)
}

function Invoke-JsonEscapeString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    ($Value -replace '\\', '\\') -replace '"', '\"' -replace "`r`n", '\n' -replace "`n", '\n' -replace "`t", '\t'
}

function Format-ProfileJson {
    <#
    .SYNOPSIS
        Serializes a profile object/hashtable to clean 2-space-indented JSON.
        Bypasses PowerShell 5.1 ConvertTo-Json formatting quirks.
    #>
    param([Parameter(Mandatory)][object]$ProfileData)

    $ln = [System.Collections.Generic.List[string]]::new()

    $ln.Add('{')

    # Scalar fields
    $ln.Add("  `"name`": `"$(Invoke-JsonEscapeString (Get-ProfileFieldValue $ProfileData 'name'))`",")
    $ln.Add("  `"description`": `"$(Invoke-JsonEscapeString (Get-ProfileFieldValue $ProfileData 'description'))`",")
    $ln.Add("  `"version`": `"$(Invoke-JsonEscapeString (Get-ProfileFieldValue $ProfileData 'version'))`",")

    # defaultForChannels
    $chans = @(Get-ProfileFieldValue $ProfileData 'defaultForChannels')
    if ($chans.Count -eq 0) {
        $ln.Add("  `"defaultForChannels`": [],")
    } else {
        $ln.Add("  `"defaultForChannels`": [")
        for ($i = 0; $i -lt $chans.Count; $i++) {
            $comma = if ($i -lt $chans.Count - 1) { ',' } else { '' }
            $ln.Add("    `"$(Invoke-JsonEscapeString $chans[$i])`"$comma")
        }
        $ln.Add("  ],")
    }

    # env
    $envObj  = Get-ProfileFieldValue $ProfileData 'env'
    $envKeys = @(Get-ProfileFieldKeys $envObj)
    if ($envKeys.Count -eq 0) {
        $ln.Add("  `"env`": {},")
    } else {
        $ln.Add("  `"env`": {")
        for ($i = 0; $i -lt $envKeys.Count; $i++) {
            $k     = $envKeys[$i]
            $v     = Get-ProfileFieldValue $envObj $k
            $comma = if ($i -lt $envKeys.Count - 1) { ',' } else { '' }
            $ln.Add("    `"$(Invoke-JsonEscapeString $k)`": `"$(Invoke-JsonEscapeString $v)`"$comma")
        }
        $ln.Add("  },")
    }

    # launchArgs
    $laArr = @(Get-ProfileFieldValue $ProfileData 'launchArgs')
    if ($laArr.Count -eq 0) {
        $ln.Add("  `"launchArgs`": [],")
    } else {
        $ln.Add("  `"launchArgs`": [")
        for ($i = 0; $i -lt $laArr.Count; $i++) {
            $comma = if ($i -lt $laArr.Count - 1) { ',' } else { '' }
            $ln.Add("    `"$(Invoke-JsonEscapeString $laArr[$i])`"$comma")
        }
        $ln.Add("  ],")
    }

    # legacyGpuOverrides
    $legObj     = Get-ProfileFieldValue $ProfileData 'legacyGpuOverrides'
    $legEnvObj  = if ($legObj) { Get-ProfileFieldValue $legObj 'env' } else { $null }
    $legEnvKeys = @(Get-ProfileFieldKeys $legEnvObj)
    $legLaArr   = @(if ($legObj) { Get-ProfileFieldValue $legObj 'launchArgs' })

    $ln.Add("  `"legacyGpuOverrides`": {")

    if ($legEnvKeys.Count -eq 0) {
        $ln.Add("    `"env`": {},")
    } else {
        $ln.Add("    `"env`": {")
        for ($i = 0; $i -lt $legEnvKeys.Count; $i++) {
            $k     = $legEnvKeys[$i]
            $v     = Get-ProfileFieldValue $legEnvObj $k
            $comma = if ($i -lt $legEnvKeys.Count - 1) { ',' } else { '' }
            $ln.Add("      `"$(Invoke-JsonEscapeString $k)`": `"$(Invoke-JsonEscapeString $v)`"$comma")
        }
        $ln.Add("    },")
    }

    if ($legLaArr.Count -eq 0) {
        $ln.Add("    `"launchArgs`": []")
    } else {
        $ln.Add("    `"launchArgs`": [")
        for ($i = 0; $i -lt $legLaArr.Count; $i++) {
            $comma = if ($i -lt $legLaArr.Count - 1) { ',' } else { '' }
            $ln.Add("      `"$(Invoke-JsonEscapeString $legLaArr[$i])`"$comma")
        }
        $ln.Add("    ]")
    }

    $ln.Add("  }")
    $ln.Add('}')

    return $ln -join "`n"
}

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

function Get-ProfilePath {
    <#
    .SYNOPSIS
        Resolves the full path to a named profile JSON file.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $path = Join-Path $Config.ProfilesFolder "$Name.json"
    if (-not (Test-Path $path)) {
        throw "ROCMROLL-PROFILE-001: Profile '$Name' not found at '$path'. Run 'rocmroll profile list' to see available profiles."
    }
    return $path
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
        Returns all profiles found in the ProfilesFolder as PSCustomObjects.
    #>
    param(
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $folder = $Config.ProfilesFolder
    if (-not (Test-Path $folder)) { return @() }

    $profiles = @()
    foreach ($file in (Get-ChildItem -Path $folder -Filter '*.json' | Sort-Object Name)) {
        try {
            $obj = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $profiles += $obj
        } catch {
            Write-LogWarn "Skipping malformed profile file: $($file.Name)" -Comp 'RocmRoll.Profiles'
        }
    }
    return $profiles
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
    $availableProfiles = Get-ProfileList -Config $Config
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
    if ($qVram -notin @('auto','gpu-only','highvram','lowvram','novram','cpu')) { $qVram = 'auto' }

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
    if ($qAttn -notin @('default','sage','flash','split','quad','pytorch')) { $qAttn = 'default' }

    # ---------------------------------------------------------------------------
    # Precision
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Precision --' -ForegroundColor Yellow

    $qGlobalPrec = (Read-Host '  Global precision [default/fp16/fp32] (default: default)').Trim().ToLower()
    if ($qGlobalPrec -notin @('default','fp16','fp32')) { $qGlobalPrec = 'default' }

    $qUnetPrec = (Read-Host '  UNET precision [default/fp16/fp32/bf16/fp8-e4m3fn/fp8-e5m2] (default: default)').Trim().ToLower()
    if ($qUnetPrec -notin @('default','fp16','fp32','bf16','fp8-e4m3fn','fp8-e5m2')) { $qUnetPrec = 'default' }

    $qVaePrec = (Read-Host '  VAE precision [default/fp16/fp32/bf16/cpu] (default: default)').Trim().ToLower()
    if ($qVaePrec -notin @('default','fp16','fp32','bf16','cpu')) { $qVaePrec = 'default' }

    $qTextEncPrec = (Read-Host '  Text encoder precision [default/fp16/fp32/bf16] (default: default)').Trim().ToLower()
    if ($qTextEncPrec -notin @('default','fp16','fp32','bf16')) { $qTextEncPrec = 'default' }

    # ---------------------------------------------------------------------------
    # Cache
    # ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- Cache --' -ForegroundColor Yellow

    $qCache = (Read-Host '  Cache strategy [default/classic/lru/none] (default: default)').Trim().ToLower()
    if ($qCache -notin @('default','classic','lru','none')) { $qCache = 'default' }
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
    $previewMethod = if ($qPreview -match '^(auto|none|taesd|latent2rgb)$') { $qPreview } else { 'auto' }

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

    $validFastOpts = @('fp16_accumulation','fp8_matrix_mult','cublas_ops','autotune')
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

    # Build final object
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

    # Ensure profiles folder exists
    if (-not (Test-Path $Config.ProfilesFolder)) {
        New-Item -ItemType Directory -Path $Config.ProfilesFolder -Force | Out-Null
    }

    $json     = Format-ProfileJson -ProfileData $profileObj
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($destPath, $json, $encoding)

    Write-Host ''
    Write-Host "  Profile '$Name' saved to: $destPath" -ForegroundColor Green
    Write-LogSuccess "Profile '$Name' created at '$destPath'" -Comp 'RocmRoll.Profiles'
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

    $path = Get-ProfilePath -Name $Name -Config $Config

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
    Format-ProfileJson, `
    Get-ProfilePath, Get-ProfileObject, Get-ProfileList, `
    Show-ProfileDetail, New-ProfileInteractive, Remove-Profile, `
    Resolve-ChannelDefaultProfile
