#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.ComfyUI - ComfyUI instance creation, Git mirror, dependency install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Utilities.psm1')

function Invoke-EnsureGitMirror {
    param([string]$Repo)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg       = Get-Config
    $mirrorDir = Join-Path $cfg.GitCacheFolder 'ComfyUI.git'

    if (-not (Get-Command 'git' -ErrorAction SilentlyContinue)) {
        throw "ROCMROLL-GIT-001: git not found in PATH."
    }

    if (-not (Test-Path $mirrorDir)) {
        Write-LogInfo "Creating bare Git mirror: $mirrorDir" -Comp 'RocmRoll.ComfyUI' -Op 'GitMirror'
        $cloneMirrorExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments @('clone', '--mirror', $Repo, $mirrorDir) -Comp 'RocmRoll.ComfyUI' -Op 'GitMirror'
        if ($cloneMirrorExitCode -ne 0) { throw "ROCMROLL-GIT-002: git clone --mirror failed (exit $cloneMirrorExitCode)" }
    } else {
        Write-LogInfo "Fetching updates into Git mirror" -Comp 'RocmRoll.ComfyUI' -Op 'GitFetch'
        $fetchMirrorArgs = Get-SafeGitRepositoryArguments -RepositoryPath $mirrorDir -Arguments @('fetch', '--all', '--tags', '--prune')
        $fetchMirrorExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $fetchMirrorArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitFetch'
        if ($fetchMirrorExitCode -ne 0) { throw "ROCMROLL-GIT-005: git fetch failed (exit $fetchMirrorExitCode)" }
    }
    return $mirrorDir
}

function Invoke-CloneComfyUIInstance {
    param(
        [string]$InstanceName,
        [string]$Ref    = 'master',
        [string]$Repo   = 'https://github.com/Comfy-Org/ComfyUI.git',
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg            = Get-Config
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName

    if ($Force -and (Test-Path $instanceFolder)) {
        Remove-Item $instanceFolder -Recurse -Force
    }

    if (Test-Path $instanceFolder) {
        Write-LogInfo "Instance folder already exists: $instanceFolder" -Comp 'RocmRoll.ComfyUI' -Op 'CloneInstance'
    } else {
        $mirrorDir = Invoke-EnsureGitMirror -Repo $Repo
        Write-LogInfo "Cloning from mirror to $instanceFolder" -Comp 'RocmRoll.ComfyUI' -Op 'CloneInstance'
        $cloneExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments @('clone', $mirrorDir, $instanceFolder) -Comp 'RocmRoll.ComfyUI' -Op 'CloneInstance'
        if ($cloneExitCode -ne 0) { throw "ROCMROLL-GIT-003: git clone failed (exit $cloneExitCode)" }
    }

    # Set remote to real upstream
    $remoteArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('remote', 'set-url', 'origin', $Repo)
    $remoteExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $remoteArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitRemote' -Inst $InstanceName
    if ($remoteExitCode -ne 0) {
        Write-LogWarn "Unable to update ComfyUI origin remote (exit $remoteExitCode)." -Comp 'RocmRoll.ComfyUI'
    }

    # Checkout requested ref
    $checkoutArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('checkout', $Ref)
    $checkoutExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $checkoutArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitCheckout'
    if ($checkoutExitCode -ne 0) { throw "ROCMROLL-GIT-004: git checkout '$Ref' failed (exit $checkoutExitCode)" }

    $commit = (& git -c "safe.directory=$instanceFolder" -c core.excludesfile= -C $instanceFolder rev-parse HEAD 2>$null).Trim()
    Write-LogSuccess "ComfyUI instance cloned at $instanceFolder (commit: $commit)" -Comp 'RocmRoll.ComfyUI'
    return @{ path=$instanceFolder; commit=$commit }
}

function Invoke-InstallComfyDeps {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global

    $cfg            = Get-Config
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
    $requirementsFile = Join-Path $instanceFolder 'requirements.txt'
    $pythonExe      = Get-EnvironmentPython -Name $EnvironmentName

    if (-not (Test-Path $requirementsFile)) {
        Write-LogWarn "requirements.txt not found in $instanceFolder" -Comp 'RocmRoll.ComfyUI'
        return
    }

    $env:PYTHONHOME                    = ''
    $env:PYTHONPATH                    = ''
    $env:PIP_CACHE_DIR                 = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_INPUT                  = '1'
    $env:PIP_REQUIRE_VIRTUALENV        = 'false'

    Write-LogInfo "Installing ComfyUI requirements.txt" -Comp 'RocmRoll.ComfyUI' -Op 'InstallDeps' -Inst $InstanceName
    $pipArgs = @('-m', 'pip', 'install', '--cache-dir', $cfg.PipCacheFolder, '--upgrade-strategy', 'only-if-needed', '-r', $requirementsFile)
    $pipExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $pipArgs -Comp 'RocmRoll.ComfyUI' -Op 'InstallDeps' -Inst $InstanceName
    if ($pipExitCode -ne 0) { throw "ROCMROLL-COMFY-001: pip install requirements.txt failed (exit $pipExitCode)" }
    Write-LogSuccess "ComfyUI dependencies installed" -Comp 'RocmRoll.ComfyUI'

    $managerRequirementsFile = Join-Path $instanceFolder 'manager_requirements.txt'
    if (Test-Path $managerRequirementsFile) {
        Write-LogInfo "Installing ComfyUI manager_requirements.txt" -Comp 'RocmRoll.ComfyUI' -Op 'InstallDeps' -Inst $InstanceName
        $managerPipArgs = @('-m', 'pip', 'install', '--cache-dir', $cfg.PipCacheFolder, '--upgrade-strategy', 'only-if-needed', '-r', $managerRequirementsFile)
        $managerPipExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $managerPipArgs -Comp 'RocmRoll.ComfyUI' -Op 'InstallDeps' -Inst $InstanceName
        if ($managerPipExitCode -ne 0) { throw "ROCMROLL-COMFY-003: pip install manager_requirements.txt failed (exit $managerPipExitCode)" }
        Write-LogSuccess "ComfyUI manager dependencies installed" -Comp 'RocmRoll.ComfyUI'
    }

    $customReqFile = Join-Path (Join-Path (Join-Path $cfg.RootFolder 'custom') $InstanceName) 'requirements.txt'
    if (Test-Path $customReqFile) {
        Write-LogInfo "Installing custom requirements from custom\$InstanceName\requirements.txt" -Comp 'RocmRoll.ComfyUI' -Op 'InstallDeps' -Inst $InstanceName
        $customPipArgs = @('-m', 'pip', 'install', '--cache-dir', $cfg.PipCacheFolder, '--upgrade-strategy', 'only-if-needed', '-r', $customReqFile)
        $customPipExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $customPipArgs -Comp 'RocmRoll.ComfyUI' -Op 'InstallDeps' -Inst $InstanceName
        if ($customPipExitCode -ne 0) { throw "ROCMROLL-COMFY-005: pip install custom requirements.txt failed (exit $customPipExitCode)" }
        Write-LogSuccess "Custom requirements installed" -Comp 'RocmRoll.ComfyUI'
    }
}

function Invoke-UpdateComfyUIInstance {
    param(
        [string]$InstanceName,
        [string]$Ref  = 'master',
        [string]$Repo = 'https://github.com/Comfy-Org/ComfyUI.git'
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global

    $cfg = Get-Config
    $state = Get-InstanceState -Name $InstanceName
    $instanceFolder = if ($state -and $state.PSObject.Properties['path'] -and $state.path) {
        [string]$state.path
    } else {
        Join-Path $cfg.InstancesFolder $InstanceName
    }

    if (-not (Test-Path $instanceFolder)) {
        throw "ROCMROLL-COMFY-004: ComfyUI instance folder not found: $instanceFolder"
    }
    if (-not (Test-Path (Join-Path $instanceFolder '.git'))) {
        throw "ROCMROLL-COMFY-005: ComfyUI folder is not a Git checkout: $instanceFolder"
    }

    $dirty = (& git -c "safe.directory=$instanceFolder" -c core.excludesfile= -C $instanceFolder status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "ROCMROLL-GIT-006: git status failed for '$instanceFolder'"
    }
    if (@($dirty).Count -gt 0) {
        throw "ROCMROLL-COMFY-006: ComfyUI checkout has local changes. Commit, stash, or remove them before updating: $instanceFolder"
    }

    Invoke-EnsureGitMirror -Repo $Repo | Out-Null

    $remoteArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('remote', 'set-url', 'origin', $Repo)
    $remoteExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $remoteArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitRemote' -Inst $InstanceName
    if ($remoteExitCode -ne 0) {
        Write-LogWarn "Unable to update ComfyUI origin remote (exit $remoteExitCode)." -Comp 'RocmRoll.ComfyUI'
    }

    $fetchArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('fetch', 'origin', '--tags', '--prune')
    $fetchExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $fetchArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitFetch' -Inst $InstanceName
    if ($fetchExitCode -ne 0) { throw "ROCMROLL-GIT-007: git fetch failed (exit $fetchExitCode)" }

    $remoteRef = (& git -c "safe.directory=$instanceFolder" -c core.excludesfile= -C $instanceFolder rev-parse --verify --quiet "origin/$Ref" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $remoteRef) {
        $checkoutArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('checkout', $Ref)
        $checkoutExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $checkoutArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitCheckout' -Inst $InstanceName
        if ($checkoutExitCode -ne 0) { throw "ROCMROLL-GIT-008: git checkout '$Ref' failed (exit $checkoutExitCode)" }

        $pullArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('pull', '--ff-only', 'origin', $Ref)
        $pullExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $pullArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitPull' -Inst $InstanceName
        if ($pullExitCode -ne 0) { throw "ROCMROLL-GIT-009: git pull --ff-only failed (exit $pullExitCode)" }
    } else {
        $checkoutArgs = Get-SafeGitRepositoryArguments -RepositoryPath $instanceFolder -Arguments @('checkout', $Ref)
        $checkoutExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $checkoutArgs -Comp 'RocmRoll.ComfyUI' -Op 'GitCheckout' -Inst $InstanceName
        if ($checkoutExitCode -ne 0) { throw "ROCMROLL-GIT-010: git checkout '$Ref' failed (exit $checkoutExitCode)" }
    }

    $commit = (& git -c "safe.directory=$instanceFolder" -c core.excludesfile= -C $instanceFolder rev-parse HEAD 2>$null).Trim()
    Write-LogSuccess "ComfyUI source updated for '$InstanceName' (commit: $commit)" -Comp 'RocmRoll.ComfyUI'
    return @{ path=$instanceFolder; commit=$commit; ref=$Ref; repo=$Repo }
}

function Invoke-GenerateExtraModelPaths {
    param([string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg            = Get-Config
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
    $tplPath        = Join-Path $cfg.TemplatesFolder 'extra_model_paths.yaml.tpl'
    $destPath       = Join-Path $instanceFolder 'extra_model_paths.yaml'

    $sharedSlash = $cfg.SharedFolder -replace '\\', '/'
    if (Test-Path $tplPath) {
        $content = Get-Content $tplPath -Raw -Encoding UTF8
        $content = $content -replace '\{SharedFolder\}', $sharedSlash
    } else {
        $content = @"
rocmroll:
  base_path: $sharedSlash
  checkpoints: models/checkpoints/
  clip: models/clip/
  clip_vision: models/clip_vision/
  configs: models/configs/
  controlnet: models/controlnet/
  diffusion_models: models/diffusion_models/
  embeddings: models/embeddings/
  loras: models/loras/
  upscale_models: models/upscale_models/
  vae: models/vae/
  text_encoders: models/text_encoders/
"@
    }
    Write-RocmRollTextFile -Path $destPath -Content $content
    Write-LogSuccess "Generated extra_model_paths.yaml at $destPath" -Comp 'RocmRoll.ComfyUI'
    return $destPath
}

function Invoke-LinkSharedWorkflows {
    param([string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg            = Get-Config
    $userDefaultDir = Join-Path $cfg.InstancesFolder "$InstanceName\user\default"
    $linkPath       = Join-Path $userDefaultDir 'workflows'
    $targetPath     = $cfg.SharedWorkflowsFolder

    if (-not (Test-Path $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }

    if (-not (Test-Path $userDefaultDir)) {
        New-Item -ItemType Directory -Path $userDefaultDir -Force | Out-Null
    }

    $existing = Get-Item -LiteralPath $linkPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -eq 'SymbolicLink') {
        Write-LogInfo "Shared workflows symlink already exists: $linkPath" -Comp 'RocmRoll.ComfyUI' -Op 'LinkWorkflows' -Inst $InstanceName
        return $linkPath
    }

    if (Test-Path $linkPath) {
        Write-LogWarn "workflows folder already exists at $linkPath and is not a symlink - skipping." -Comp 'RocmRoll.ComfyUI' -Op 'LinkWorkflows' -Inst $InstanceName
        return $null
    }

    Write-LogWarn "Creating a symbolic link requires administrator privileges or Developer Mode enabled in Windows Settings." -Comp 'RocmRoll.ComfyUI' -Op 'LinkWorkflows' -Inst $InstanceName

    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isElevated) {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath | Out-Null
    } else {
        Write-LogWarn "Current session is not elevated. A UAC prompt will appear to elevate for the symlink step only." -Comp 'RocmRoll.ComfyUI' -Op 'LinkWorkflows' -Inst $InstanceName
        $psCmd   = "New-Item -ItemType SymbolicLink -Path '$($linkPath -replace "'","''")' -Target '$($targetPath -replace "'","''")' | Out-Null"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psCmd))
        $proc    = Start-Process powershell.exe `
                       -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
                       -Verb RunAs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "ROCMROLL-COMFY-002: Shared workflows symlink creation failed (elevated process exited $($proc.ExitCode)). Accept the UAC prompt or enable Developer Mode and retry."
        }
    }

    Write-LogSuccess "Shared workflows symlink: $linkPath -> $targetPath" -Comp 'RocmRoll.ComfyUI' -Op 'LinkWorkflows' -Inst $InstanceName
    return $linkPath
}

Export-ModuleMember -Function Invoke-EnsureGitMirror, Invoke-CloneComfyUIInstance,
    Invoke-UpdateComfyUIInstance,
    Invoke-InstallComfyDeps, Invoke-GenerateExtraModelPaths, Invoke-LinkSharedWorkflows
