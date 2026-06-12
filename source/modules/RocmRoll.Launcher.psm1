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
        [int]$Port           = 8188,
        [string]$ProfileName = '',
        [string]$Channel     = ''
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    $cfg            = Get-Config
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
    $envFolder      = Join-Path $cfg.EnvironmentsFolder $EnvironmentName

    $state = Get-InstanceState -Name $InstanceName
    if ($state -and $state.path) {
        $instanceFolder = $state.path
    }

    $envState = Get-EnvironmentState -Name $EnvironmentName
    if ($envState -and $envState.path) {
        $envFolder = $envState.path
    }

    # Resolve default profile from channel manifest when not explicitly provided
    if (-not $ProfileName) {
        $chanFile = Join-Path $cfg.ManifestsFolder 'channels.json'
        if ((Test-Path $chanFile) -and $Channel) {
            try {
                $chanManifest = Get-Content $chanFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $chanObj = $chanManifest.$Channel
                if ($chanObj -and $chanObj.defaultProfile) {
                    $ProfileName = $chanObj.defaultProfile
                }
            } catch { }
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
            -replace '\{Port\}',            $Port `
            -replace '\{ProfilesFolder\}',  $cfg.ProfilesFolder `
            -replace '\{ProfileName\}',     $ProfileName
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
    if (-not $state) { throw "ROCMROLL-LAUNCH-001: Instance '$InstanceName' state not found. Run install first." }
    if ($state.status -ne 'ready') { throw "ROCMROLL-LAUNCH-002: Instance '$InstanceName' is not in ready state (status: $($state.status))." }

    $launchScript = Join-Path $cfg.LaunchersFolder "$InstanceName.ps1"
    if (-not (Test-Path $launchScript)) { throw "ROCMROLL-LAUNCH-003: $InstanceName.ps1 not found in launchers folder. Run 'rocmroll repair --component launchers'." }

    $passArgs = $ExtraArgs

    $launcherContent = Get-Content $launchScript -Raw -ErrorAction SilentlyContinue
    if ($ProfileOverride -and ($launcherContent -notmatch 'ProfileArg')) {
        throw "ROCMROLL-LAUNCH-004: Launcher '$InstanceName.ps1' was generated before profile support was added and cannot accept a --profile override. Regenerate it first:`n`n  rocmroll repair --instance $InstanceName --component launchers`n"
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
