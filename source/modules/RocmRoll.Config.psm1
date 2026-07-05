#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Config - Canonical path variables and configuration loading.

.DESCRIPTION
    Reads an optional rocmroll.ini from the root folder so users can redirect
    top-level directories (userdata, instances, environments, runtimes, launchers,
    profiles, shared, logs, state, cache) to arbitrary locations.
    All I/O paths - InputFolder, OutputFolder, TempDataFolder, UserDataFolder -
    are derived from SharedFolder. All sub-paths are computed from their (possibly
    overridden) parent - callers never need to change.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Config = $null

function Get-DefaultRootFolder {
    $sourceFolder = Split-Path $PSScriptRoot -Parent
    return Split-Path $sourceFolder -Parent
}

# ---------------------------------------------------------------------------
# INI parser
# ---------------------------------------------------------------------------

function Read-IniFile {
    param([string]$Path)

    $result = @{}
    if (-not (Test-Path $Path)) { return $result }

    $currentSection = ''
    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^[;#]') { continue }
        if ($trimmed -match '^\[(.+)\]$') {
            $currentSection = $Matches[1].ToLower()
            if (-not $result.ContainsKey($currentSection)) {
                $result[$currentSection] = @{}
            }
            continue
        }
        if ($trimmed -match '^([^=]+)=(.*)$' -and $currentSection) {
            $k = $Matches[1].Trim().ToLower()
            $v = $Matches[2].Trim()
            if ($v) { $result[$currentSection][$k] = $v }
        }
    }
    return $result
}

# Resolves a user-supplied path value:
#   - empty string   -> return $Default
#   - absolute path  -> use as-is
#   - relative path  -> join with $RootFolder and normalise
function Resolve-IniPath {
    param([string]$Value, [string]$Default, [string]$RootFolder)
    if (-not $Value) { return $Default }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RootFolder $Value))
}

function Resolve-WorkspacePathOverride {
    param($WorkspacePaths, [string]$Key, [string]$Current, [string]$Root)
    $prop = $WorkspacePaths.PSObject.Properties[$Key]
    if ($prop -and $prop.Value) { return Resolve-IniPath $prop.Value $Current $Root }
    return $Current
}

# ---------------------------------------------------------------------------
# Core config functions
# ---------------------------------------------------------------------------

function Initialize-Config {
    param(
        [string]$RootFolder    = '',
        [string]$WorkspaceName = '',
        [switch]$IgnoreActiveWorkspace
    )

    if (-not $RootFolder) {
        $rootOverride = Get-Variable -Name 'RocmRollConfigRootFolder' -Scope Global -ErrorAction SilentlyContinue
        $RootFolder = if ($rootOverride -and $rootOverride.Value) { [string]$rootOverride.Value } else { Get-DefaultRootFolder }
    }
    if (-not $WorkspaceName -and -not $IgnoreActiveWorkspace) {
        $workspaceOverride = Get-Variable -Name 'RocmRollConfigWorkspaceOverride' -Scope Global -ErrorAction SilentlyContinue
        if ($workspaceOverride -and $workspaceOverride.Value) {
            $WorkspaceName = [string]$workspaceOverride.Value
        }
    }

    # Load optional INI overrides
    $iniPath = Join-Path $RootFolder 'rocmroll.ini'
    $ini     = Read-IniFile -Path $iniPath
    $p       = if ($ini.ContainsKey('paths')) { $ini['paths'] } else { @{} }

    # Resolve user-configurable top-level paths
    # shared is resolved first - all I/O paths derive from it
    $sharedFolder       = Resolve-IniPath $p['shared']       (Join-Path $RootFolder 'shared')        $RootFolder
    $userdataFolder     = Resolve-IniPath $p['userdata']     (Join-Path $sharedFolder 'user')        $RootFolder
    $instancesFolder    = Resolve-IniPath $p['instances']    (Join-Path $RootFolder 'instances')     $RootFolder
    $environmentsFolder = Resolve-IniPath $p['environments'] (Join-Path $RootFolder 'environments')  $RootFolder
    $runtimesFolder     = Resolve-IniPath $p['runtimes']     (Join-Path $RootFolder 'runtimes')      $RootFolder
    $launchersFolder    = Resolve-IniPath $p['launchers']    (Join-Path $RootFolder 'launchers')     $RootFolder
    $profilesFolder     = Resolve-IniPath $p['profiles']     (Join-Path $RootFolder 'profiles')      $RootFolder
    $logsFolder         = Resolve-IniPath $p['logs']         (Join-Path $RootFolder 'logs')          $RootFolder
    $stateFolder        = Resolve-IniPath $p['state']        (Join-Path $RootFolder '.state')        $RootFolder
    $cacheFolder        = Resolve-IniPath $p['cache']        (Join-Path $RootFolder '.cache')        $RootFolder

    # Apply active workspace path overrides (highest precedence, layered on top of [paths]).
    # $WorkspaceName parameter takes priority over the [active] section in rocmroll.ini -
    # this enables transient per-command overrides without modifying the persistent config.
    $workspacesFolder    = Join-Path $RootFolder 'workspaces'
    $activeWorkspaceName = ''
    if ($WorkspaceName) {
        $activeWorkspaceName = $WorkspaceName
    } elseif (-not $IgnoreActiveWorkspace -and $ini.ContainsKey('active') -and $ini['active'].ContainsKey('workspace')) {
        $activeWorkspaceName = $ini['active']['workspace']
    }
    if ($activeWorkspaceName) {
        $wsFilePath = Join-Path $workspacesFolder "$activeWorkspaceName.json"
        if (Test-Path $wsFilePath) {
            try {
                $wsData = Get-Content $wsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($wsData.paths) {
                    $wp = $wsData.paths
                    # shared first: userdata default derives from it
                    $wsProp = $wp.PSObject.Properties['shared']
                    if ($wsProp -and $wsProp.Value) {
                        $sharedFolder = Resolve-IniPath $wsProp.Value $sharedFolder $RootFolder
                        $wsUdProp = $wp.PSObject.Properties['userdata']
                        if (-not ($wsUdProp -and $wsUdProp.Value)) {
                            $userdataFolder = Resolve-IniPath $p['userdata'] (Join-Path $sharedFolder 'user') $RootFolder
                        }
                    }
                    $userdataFolder     = Resolve-WorkspacePathOverride $wp 'userdata'     $userdataFolder     $RootFolder
                    $instancesFolder    = Resolve-WorkspacePathOverride $wp 'instances'    $instancesFolder    $RootFolder
                    $environmentsFolder = Resolve-WorkspacePathOverride $wp 'environments' $environmentsFolder $RootFolder
                    $runtimesFolder     = Resolve-WorkspacePathOverride $wp 'runtimes'     $runtimesFolder     $RootFolder
                    $launchersFolder    = Resolve-WorkspacePathOverride $wp 'launchers'    $launchersFolder    $RootFolder
                    $profilesFolder     = Resolve-WorkspacePathOverride $wp 'profiles'     $profilesFolder     $RootFolder
                    $logsFolder         = Resolve-WorkspacePathOverride $wp 'logs'         $logsFolder         $RootFolder
                    $stateFolder        = Resolve-WorkspacePathOverride $wp 'state'        $stateFolder        $RootFolder
                    $cacheFolder        = Resolve-WorkspacePathOverride $wp 'cache'        $cacheFolder        $RootFolder
                }
            } catch {
                Write-Warning "Failed to load workspace override '$wsFilePath': $($_.Exception.Message)"
            }
        }
    }

    $script:Config = [ordered]@{
        RootFolder         = $RootFolder
        ConfigFilePath     = $iniPath

        TempFolder         = Join-Path $RootFolder '.temp'

        CacheFolder           = $cacheFolder
        DownloadsFolder       = Join-Path $cacheFolder 'downloads'
        PipCacheFolder        = Join-Path $cacheFolder 'pip'
        TritonCacheFolder     = Join-Path $cacheFolder 'triton'
        WheelhouseFolder      = Join-Path $cacheFolder 'wheelhouse'
        GitCacheFolder        = Join-Path $cacheFolder 'git'
        PythonDownloadsFolder = Join-Path $cacheFolder 'downloads\python'
        ComfyDownloadsFolder  = Join-Path $cacheFolder 'downloads\comfyui'
        RocmDownloadsFolder   = Join-Path $cacheFolder 'downloads\rocm'
        ToolsDownloadsFolder  = Join-Path $cacheFolder 'downloads\tools'
        ChecksumsFolder       = Join-Path $cacheFolder 'checksums'

        TempDataFolder     = Join-Path $sharedFolder 'temp'
        UserDataFolder     = $userdataFolder

        RuntimeVersion     = '3.12.10'
        RuntimesFolder     = $runtimesFolder
        EnvironmentsFolder = $environmentsFolder
        InstancesFolder    = $instancesFolder
        LaunchersFolder    = $launchersFolder
        ProfilesFolder     = $profilesFolder

        SourceFolder          = Join-Path $RootFolder 'source'
        ModulesFolder      = Join-Path $RootFolder 'source\modules'
        ScriptsFolder      = Join-Path $RootFolder 'source\scripts'
        ManifestsFolder    = Join-Path $RootFolder 'source\manifests'
        TemplatesFolder    = Join-Path $RootFolder 'source\templates'

        SharedFolder            = $sharedFolder
        SharedModelsFolder      = Join-Path $sharedFolder 'models'
        SharedWorkflowsFolder   = Join-Path $sharedFolder 'workflows'
        InputFolder             = Join-Path $sharedFolder 'input'
        OutputFolder            = Join-Path $sharedFolder 'output'

        StateFolder        = $stateFolder
        LocksFolder        = Join-Path $stateFolder 'locks'
        RuntimeStateFolder = Join-Path $stateFolder 'runtimes'
        EnvStateFolder     = Join-Path $stateFolder 'environments'
        InstanceStateFolder= Join-Path $stateFolder 'instances'
        PatchStateFolder      = Join-Path $stateFolder 'patches'
        ComfyPatchesFolder    = Join-Path $RootFolder 'source\patches\comfyui'
        ComfyPatchStateFolder = Join-Path $stateFolder 'patches\comfyui'

        LogsFolder         = $logsFolder
        LogsInstallFolder  = Join-Path $logsFolder 'install'
        LogsLaunchFolder   = Join-Path $logsFolder 'launch'
        LogsUpdateFolder   = Join-Path $logsFolder 'update'
        LogsDoctorFolder   = Join-Path $logsFolder 'doctor'
        LogsCrashFolder    = Join-Path $logsFolder 'crash'

        BinFolder          = Join-Path $RootFolder 'bin'

        WorkspacesFolder   = $workspacesFolder
        ActiveWorkspace    = $activeWorkspaceName

        RocmIndexBase      = 'https://rocm.nightlies.amd.com/v2'
    }

    return $script:Config
}

function Get-Config {
    if ($null -eq $script:Config) {
        Initialize-Config | Out-Null
    }
    return $script:Config
}

function Get-ConfigValue {
    param([string]$Key)
    $cfg = Get-Config
    if (-not $cfg.Contains($Key)) {
        throw "Config key '$Key' not found."
    }
    return $cfg[$Key]
}

function Get-RuntimeFolder {
    param([string]$Version = '')
    $cfg = Get-Config
    $ver = if ($Version) { $Version } else { $cfg.RuntimeVersion }
    return Join-Path $cfg.RuntimesFolder "python-$ver"
}

function Get-RocmIndexUrl {
    param([string]$RocmIndex)
    $cfg = Get-Config
    return "$($cfg.RocmIndexBase)/$RocmIndex/"
}

function Resolve-ChannelName {
    <#
    .SYNOPSIS
        Maps removed channel names persisted in old instance state to their
        current replacements. RDNA 1/2 GPUs install from the multi-arch
        preview channel since the dedicated rdna1/rdna2 channels were removed.
    #>
    param([string]$Channel)

    if (-not $Channel) { return $Channel }

    switch ($Channel.ToLowerInvariant()) {
        'rdna1' { return 'preview' }
        'rdna2' { return 'preview' }
        default { return $Channel }
    }
}

# ---------------------------------------------------------------------------
# Folder structure initialisation
# ---------------------------------------------------------------------------

function Initialize-FolderStructure {
    $cfg = Get-Config
    $folders = @(
        $cfg.TempFolder
        $cfg.CacheFolder
        $cfg.DownloadsFolder
        $cfg.PipCacheFolder
        $cfg.TritonCacheFolder
        $cfg.WheelhouseFolder
        $cfg.GitCacheFolder
        $cfg.PythonDownloadsFolder
        $cfg.ComfyDownloadsFolder
        $cfg.RocmDownloadsFolder
        $cfg.ToolsDownloadsFolder
        $cfg.ChecksumsFolder
        $cfg.RuntimesFolder
        $cfg.EnvironmentsFolder
        $cfg.InstancesFolder
        $cfg.LaunchersFolder
        $cfg.ProfilesFolder
        $cfg.SharedFolder
        $cfg.InputFolder
        $cfg.OutputFolder
        $cfg.TempDataFolder
        $cfg.UserDataFolder
        $cfg.SharedModelsFolder
        $cfg.SharedWorkflowsFolder
        (Join-Path $cfg.SharedModelsFolder 'checkpoints')
        (Join-Path $cfg.SharedModelsFolder 'clip')
        (Join-Path $cfg.SharedModelsFolder 'clip_vision')
        (Join-Path $cfg.SharedModelsFolder 'configs')
        (Join-Path $cfg.SharedModelsFolder 'controlnet')
        (Join-Path $cfg.SharedModelsFolder 'diffusion_models')
        (Join-Path $cfg.SharedModelsFolder 'embeddings')
        (Join-Path $cfg.SharedModelsFolder 'loras')
        (Join-Path $cfg.SharedModelsFolder 'upscale_models')
        (Join-Path $cfg.SharedModelsFolder 'vae')
        (Join-Path $cfg.SharedModelsFolder 'text_encoders')
        $cfg.StateFolder
        $cfg.LocksFolder
        $cfg.RuntimeStateFolder
        $cfg.EnvStateFolder
        $cfg.InstanceStateFolder
        $cfg.PatchStateFolder
        $cfg.ComfyPatchStateFolder
        $cfg.LogsFolder
        $cfg.LogsInstallFolder
        $cfg.LogsLaunchFolder
        $cfg.LogsUpdateFolder
        $cfg.LogsDoctorFolder
        $cfg.LogsCrashFolder
        $cfg.WorkspacesFolder
    )
    foreach ($f in $folders) {
        if (-not (Test-Path $f)) {
            New-Item -ItemType Directory -Path $f -Force | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Default config file creation
# ---------------------------------------------------------------------------

function Initialize-DefaultConfigFile {
    <#
    Creates rocmroll.ini with all path settings commented out (defaults active).
    Does nothing if the file already exists. Returns the path to the file.
    #>
    param([string]$RootFolder = '')

    if (-not $RootFolder) {
        $cfg = Get-Config
        $RootFolder = $cfg.RootFolder
    }

    $iniPath = Join-Path $RootFolder 'rocmroll.ini'
    if (Test-Path $iniPath) { return $iniPath }

    $lines = @(
        '; ROCmRoll Configuration'
        '; Paths can be absolute (C:\MyData) or relative to this file''s directory.'
        '; Remove the leading semicolon from any line to override that value.'
        ''
        '[paths]'
        ''
        '; Top-level directories'
        '; shared       = shared'
        '; userdata     = shared\user'
        '; instances    = instances'
        '; environments = environments'
        '; runtimes     = runtimes'
        '; launchers    = launchers'
        '; profiles     = profiles'
        '; logs         = logs'
        '; state        = .state'
        '; cache        = .cache'
        ''
        '; All shared asset sub-paths (input\, output\, temp\, user\, models\, workflows\)'
        '; are derived from the shared key above.'
        ''
        '; Workspace management'
        '; Use ''rocmroll workspace create'' and ''rocmroll workspace use'' to manage workspaces.'
        '; The [active] section below is written automatically by ''rocmroll workspace use''.'
        '; [active]'
        '; workspace = my-workspace'
    )

    $content  = $lines -join [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($iniPath, $content, $encoding)
    return $iniPath
}

Export-ModuleMember -Function Initialize-Config, Get-Config, Get-ConfigValue,
    Get-RuntimeFolder, Get-RocmIndexUrl, Resolve-ChannelName,
    Initialize-FolderStructure, Initialize-DefaultConfigFile,
    Read-IniFile
