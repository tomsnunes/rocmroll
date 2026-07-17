#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Launcher - Generate and execute per-instance launchers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

function Invoke-GenerateLaunchers {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName,
        [string]$GfxVersion  = '',
        [string]$RocmIndex   = '',
        [int]$Port           = 8188,
        [string]$ProfileName = '',
        [string]$Channel     = ''
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Profiles.psm1') -Force -Global
    $cfg            = Get-Config
    # Resolve removed-channel aliases immediately after the Config import so the
    # call cannot be affected by any module re-import that runs in between.
    $Channel        = Resolve-ChannelName -Channel $Channel
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
    $envFolder      = Join-Path $cfg.EnvironmentsFolder $EnvironmentName

    # Called mid-pipeline, before state has a 'path' - guard with PSObject.Properties[].
    $state = Get-InstanceState -Name $InstanceName
    if ($state -and $state.PSObject.Properties['path'] -and $state.path) {
        $instanceFolder = $state.path
    }

    $envState = Get-EnvironmentState -Name $EnvironmentName
    if ($envState -and $envState.PSObject.Properties['path'] -and $envState.path) {
        $envFolder = $envState.path
    }

    # Look up the channel manifest once: used both to resolve the default profile
    # and to decide which GPU-state field (family rocmIndex vs. exact multiArchChip)
    # backs the {RocmIndex} launcher token when the caller didn't pass -RocmIndex.
    $chanObj = $null
    $chanFile = Join-Path $cfg.ManifestsFolder 'channels.json'
    if ((Test-Path $chanFile) -and $Channel) {
        try {
            $chanManifest = Get-Content $chanFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $chanObj = $chanManifest.$Channel
        } catch { }
    }

    if (-not $RocmIndex -and $envState -and $envState.PSObject.Properties['gpu'] -and $envState.gpu) {
        $isMultiArch = $chanObj -and $chanObj.rocm -and ([string]$chanObj.rocm.source -eq 'multiArch')
        $gpuFieldName = if ($isMultiArch) { 'multiArchChip' } else { 'rocmIndex' }
        $indexProperty = $envState.gpu.PSObject.Properties[$gpuFieldName]
        if ($indexProperty -and $indexProperty.Value) { $RocmIndex = [string]$indexProperty.Value }
    }

    # Resolve default profile from channel manifest when not explicitly provided
    if (-not $ProfileName) {
        if ($chanObj -and $chanObj.defaultProfile) {
            $ProfileName = $chanObj.defaultProfile
        }
        if (-not $ProfileName) {
            $ProfileName = if ($Channel -eq 'stable') { 'stable' } else { 'optimized' }
        }
    }

    # Resolve root folder from instance/environment paths
    $rootSlash = $cfg.RootFolder
    if ($instanceFolder -and ($instanceFolder -match '\\instances\\[^\\]+$')) {
        $rootSlash = Split-Path (Split-Path $instanceFolder -Parent) -Parent
    } elseif ($envFolder -and ($envFolder -match '\\environments\\[^\\]+$')) {
        $rootSlash = Split-Path (Split-Path $envFolder -Parent) -Parent
    }

    # Read templates and substitute
    $ps1Tpl = Join-Path $cfg.TemplatesFolder 'instance.launch.ps1.tpl'
    $batTpl = Join-Path $cfg.TemplatesFolder 'instance.launch.bat.tpl'
    $now    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    $launchersFolder = $cfg.LaunchersFolder
    if (-not (Test-Path $launchersFolder)) {
        New-Item -ItemType Directory -Path $launchersFolder -Force | Out-Null
    }

    if (Test-Path $ps1Tpl) {
        # Always resolve from RootFolder (not the workspace-redirected root) so the
        # fallback still finds ROCmRoll's own shipped profiles.
        $profilesRootFallback = Join-Path $cfg.RootFolder 'profiles'
        $ps1Content = Get-Content $ps1Tpl -Raw -Encoding UTF8
        $ps1Content = $ps1Content `
            -replace '\{InstanceName\}',    $InstanceName `
            -replace '\{Channel\}',         $Channel `
            -replace '\{CreatedAt\}',       $now `
            -replace '\{RootFolder\}',      $rootSlash `
            -replace '\{SharedFolder\}',    $cfg.SharedFolder `
            -replace '\{InstanceFolder\}',  $instanceFolder `
            -replace '\{EnvironmentFolder\}', $envFolder `
            -replace '\{GfxVersion\}',      $GfxVersion `
            -replace '\{RocmIndex\}',       $RocmIndex `
            -replace '\{Port\}',            $Port `
            -replace '\{ProfilesFolder\}',  $cfg.ProfilesFolder `
            -replace '\{ProfilesRootFallback\}', $profilesRootFallback `
            -replace '\{ProfileName\}',     $ProfileName
        try {
            Get-ProfilePath -Name $ProfileName -Config $cfg | Out-Null
        } catch {
            Write-LogWarn "Profile '$ProfileName' not found in '$($cfg.ProfilesFolder)' or '$profilesRootFallback' - launcher will fail to load it at runtime." -Comp 'RocmRoll.Launcher'
        }
        Write-RocmRollTextFile -Path (Join-Path $launchersFolder "$InstanceName.ps1") -Content $ps1Content
    }

    if (Test-Path $batTpl) {
        $batContent = Get-Content $batTpl -Raw -Encoding UTF8
        $batContent = $batContent `
            -replace '\{InstanceName\}',   $InstanceName `
            -replace '\{RootFolder\}',     $rootSlash `
            -replace '\{EnvironmentFolder\}', $envFolder
        # .bat files must be written without BOM.
        Write-RocmRollTextFile -Path (Join-Path $launchersFolder "$InstanceName.bat") -Content $batContent
    }

    Write-LogSuccess "Launchers generated for instance '$InstanceName' using profile '$ProfileName'" -Comp 'RocmRoll.Launcher'
}

function Find-RocmRollInstanceWorkspaces {
    <#
    .SYNOPSIS
        Scans every other configured workspace for an installed instance named
        Name, so a launch failure can point at the right --workspace instead of
        just saying "not found". Reads state files directly rather than
        switching the active config.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Config
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Workspace.psm1') -Force -Global
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($ws in @(Get-WorkspaceList -Config $Config | Where-Object { -not $_.IsActive })) {
        $stateFolder = if ($ws.Object.paths -and $ws.Object.paths.PSObject.Properties['state'] -and $ws.Object.paths.state) {
            [string]$ws.Object.paths.state
        } else {
            Join-Path $Config.RootFolder '.state'
        }
        $candidatePath = Join-Path (Join-Path $stateFolder 'instances') "instance-$Name.json"
        if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
        try {
            $candidateState = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        if ($candidateState.PSObject.Properties['status'] -and $candidateState.status) {
            $found.Add($ws.Name) | Out-Null
        }
    }
    return $found.ToArray()
}

function Invoke-LaunchInstance {
    param(
        [string]$InstanceName,
        [string]$ProfileOverride = '',
        [string[]]$ExtraArgs = @()
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')  -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg   = Get-Config
    $state = Get-InstanceState -Name $InstanceName
    # A non-null $state doesn't guarantee a real install: a 'plan'-only run can
    # leave a partial state record with no status.
    $hasStatus = $state -and $state.PSObject.Properties['status'] -and $state.status
    if (-not $hasStatus) {
        $activeWs = if ($cfg.ActiveWorkspace) { $cfg.ActiveWorkspace } else { '(default, no workspace)' }
        $foundIn  = @(Find-RocmRollInstanceWorkspaces -Name $InstanceName -Config $cfg)
        $hint     = if ($foundIn.Count -gt 0) {
            "Found in workspace '$($foundIn[0])'. Retry with: rocmroll instance launch --name $InstanceName --workspace $($foundIn[0])"
        } else {
            "Run 'rocmroll instance install --name $InstanceName' or check 'rocmroll workspace list' for the correct workspace."
        }
        throw "ROCMROLL-LAUNCH-001: Instance '$InstanceName' not found or not fully installed in the current workspace ('$activeWs'). $hint"
    }
    if ($state.status -ne 'ready') { throw "ROCMROLL-LAUNCH-002: Instance '$InstanceName' is not in ready state (status: $($state.status))." }

    $launchScript = Join-Path $cfg.LaunchersFolder "$InstanceName.ps1"
    if (-not (Test-Path $launchScript)) { throw "ROCMROLL-LAUNCH-003: $InstanceName.ps1 not found in launchers folder. Run 'rocmroll instance repair --name $InstanceName'." }

    $passArgs = $ExtraArgs

    $launcherContent = Get-Content $launchScript -Raw -ErrorAction SilentlyContinue
    if ($ProfileOverride -and ($launcherContent -notmatch 'ProfileArg')) {
        throw "ROCMROLL-LAUNCH-004: Launcher '$InstanceName.ps1' was generated before profile support was added and cannot accept a --profile override. Regenerate it first:`n`n  rocmroll instance repair --name $InstanceName`n"
    }

    Write-LogInfo "Launching instance '$InstanceName'" -Comp 'RocmRoll.Launcher' -Inst $InstanceName
    if ($ProfileOverride) {
        & $launchScript -ProfileArg $ProfileOverride @passArgs
    } else {
        & $launchScript @passArgs
    }
    return $LASTEXITCODE
}

Export-ModuleMember -Function Invoke-GenerateLaunchers, Invoke-LaunchInstance
