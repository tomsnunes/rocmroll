#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.CustomNodes - Custom node clone, update and requirements installation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Utilities.psm1')

function Get-CustomNodesManifest {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg  = Get-Config
    $path = Join-Path $cfg.ManifestsFolder 'custom-nodes.json'
    if (-not (Test-Path $path)) { throw "ROCMROLL-NODES-001: custom-nodes.json not found at '$path'" }
    return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-InstallCustomNodes {
    param(
        [string]$InstanceName,
        [string]$EnvironmentName,
        [switch]$Update,
        [switch]$RequirementsOnly
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg            = Get-Config
    $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
    $nodesFolder    = Join-Path $instanceFolder 'custom_nodes'
    $pythonExe      = Get-EnvironmentPython -Name $EnvironmentName

    if (-not (Test-Path $nodesFolder)) {
        New-Item -ItemType Directory -Path $nodesFolder -Force | Out-Null
    }

    $manifest = Get-CustomNodesManifest
    $nodes    = $manifest.default

    $env:PYTHONHOME                    = ''
    $env:PYTHONPATH                    = ''
    $env:PIP_CACHE_DIR                 = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_INPUT                  = '1'
    $env:PIP_REQUIRE_VIRTUALENV        = 'false'

    foreach ($node in $nodes) {
        $nodeDir = Join-Path $nodesFolder $node.name
        Write-LogInfo "Processing custom node: $($node.name)" -Comp 'RocmRoll.CustomNodes' -Inst $InstanceName

        if (-not $RequirementsOnly) {
            if (-not (Test-Path $nodeDir)) {
                Write-LogInfo "Cloning $($node.name) from $($node.repo)" -Comp 'RocmRoll.CustomNodes'
                $cloneExitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments @('clone', '--depth', '1', '--branch', $node.ref, $node.repo, $nodeDir) -Comp 'RocmRoll.CustomNodes' -Op 'CloneCustomNode' -Inst $InstanceName
                if ($cloneExitCode -ne 0) {
                    Write-LogWarn "Failed to clone custom node '$($node.name)'" -Comp 'RocmRoll.CustomNodes'
                    continue
                }
            } elseif ($Update) {
                Write-LogInfo "Updating $($node.name)" -Comp 'RocmRoll.CustomNodes'
                Invoke-LoggedNativeCommand -FilePath 'git' -Arguments (Get-SafeGitRepositoryArguments -RepositoryPath $nodeDir -Arguments @('fetch', 'origin')) -Comp 'RocmRoll.CustomNodes' -Op 'FetchCustomNode' -Inst $InstanceName | Out-Null
                Invoke-LoggedNativeCommand -FilePath 'git' -Arguments (Get-SafeGitRepositoryArguments -RepositoryPath $nodeDir -Arguments @('checkout', $node.ref)) -Comp 'RocmRoll.CustomNodes' -Op 'CheckoutCustomNode' -Inst $InstanceName | Out-Null
                Invoke-LoggedNativeCommand -FilePath 'git' -Arguments (Get-SafeGitRepositoryArguments -RepositoryPath $nodeDir -Arguments @('pull')) -Comp 'RocmRoll.CustomNodes' -Op 'PullCustomNode' -Inst $InstanceName | Out-Null
            } else {
                Write-LogDebug "Custom node '$($node.name)' exists. Use 'rocmroll comfyui nodes --instance INSTANCE --update' to refresh." -Comp 'RocmRoll.CustomNodes'
            }
        }

        $shouldInstallReqs = $RequirementsOnly -or $node.installRequirements
        if ($shouldInstallReqs -and (Test-Path $nodeDir)) {
            $req = Join-Path $nodeDir 'requirements.txt'
            if (Test-Path $req) {
                Write-LogInfo "Installing requirements for $($node.name)" -Comp 'RocmRoll.CustomNodes'
                $pipArgs = @('-m', 'pip', 'install', '--cache-dir', $cfg.PipCacheFolder, '-r', $req)
                $pipExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $pipArgs -Comp 'RocmRoll.CustomNodes' -Op 'InstallNodeRequirements' -Inst $InstanceName
                if ($pipExitCode -ne 0) {
                    Write-LogWarn "requirements.txt install for '$($node.name)' returned exit $pipExitCode" -Comp 'RocmRoll.CustomNodes'
                }
            }
        }

        if (-not $RequirementsOnly) {
            $commit = (& git -c "safe.directory=$nodeDir" -C $nodeDir rev-parse HEAD 2>$null).Trim()
            Write-LogSuccess "Custom node '$($node.name)' ready (commit: $commit)" -Comp 'RocmRoll.CustomNodes'
        }
    }
}

function Invoke-InstallNodeFromUrl {
    param(
        [string]$Url,
        [string]$InstanceName,
        [string]$EnvironmentName
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

    $cfg         = Get-Config
    $nodesFolder = Join-Path $cfg.InstancesFolder "$InstanceName\custom_nodes"
    $pythonExe   = Get-EnvironmentPython -Name $EnvironmentName

    $rawName  = $Url.TrimEnd('/').Split('/')[-1]
    $nodeName = [System.IO.Path]::GetFileNameWithoutExtension($rawName)
    if ([string]::IsNullOrWhiteSpace($nodeName)) {
        throw "ROCMROLL-NODES-010: Cannot derive node name from URL '$Url'"
    }
    if ($nodeName -notmatch '^[a-zA-Z0-9_\-\.]+$') {
        throw "ROCMROLL-NODES-011: Derived node name '$nodeName' contains unsafe characters"
    }

    $nodeDir = Join-Path $nodesFolder $nodeName
    if (Test-Path $nodeDir) {
        Write-LogWarn "Custom node '$nodeName' already exists. Use 'rocmroll comfyui nodes --instance $InstanceName --update' to update." -Comp 'RocmRoll.CustomNodes' -Inst $InstanceName
        return
    }

    if (-not (Test-Path $nodesFolder)) {
        New-Item -ItemType Directory -Path $nodesFolder -Force | Out-Null
    }

    $env:PYTHONHOME                    = ''
    $env:PYTHONPATH                    = ''
    $env:PIP_CACHE_DIR                 = $cfg.PipCacheFolder
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_INPUT                  = '1'
    $env:PIP_REQUIRE_VIRTUALENV        = 'false'

    Write-LogInfo "Cloning '$nodeName' from $Url" -Comp 'RocmRoll.CustomNodes' -Inst $InstanceName
    $cloneExitCode = Invoke-LoggedNativeCommand -FilePath 'git' `
        -Arguments @('clone', '--depth', '1', $Url, $nodeDir) `
        -Comp 'RocmRoll.CustomNodes' -Op 'CloneNodeFromUrl' -Inst $InstanceName
    if ($cloneExitCode -ne 0) {
        throw "ROCMROLL-NODES-012: Failed to clone '$Url' (git exit $cloneExitCode)"
    }

    $req = Join-Path $nodeDir 'requirements.txt'
    if (Test-Path $req) {
        Write-LogInfo "Installing requirements for '$nodeName'" -Comp 'RocmRoll.CustomNodes'
        $pipArgs     = @('-m', 'pip', 'install', '--cache-dir', $cfg.PipCacheFolder, '-r', $req)
        $pipExitCode = Invoke-LoggedNativeCommand -FilePath $pythonExe -Arguments $pipArgs `
            -Comp 'RocmRoll.CustomNodes' -Op 'InstallNodeRequirements' -Inst $InstanceName
        if ($pipExitCode -ne 0) {
            Write-LogWarn "requirements.txt install for '$nodeName' returned exit $pipExitCode" -Comp 'RocmRoll.CustomNodes'
        }
    }

    $commit = (& git -c "safe.directory=$nodeDir" -C $nodeDir rev-parse HEAD 2>$null).Trim()
    Write-LogSuccess "Custom node '$nodeName' installed (commit: $commit)" -Comp 'RocmRoll.CustomNodes' -Inst $InstanceName
}

Export-ModuleMember -Function Get-CustomNodesManifest, Invoke-InstallCustomNodes, Invoke-InstallNodeFromUrl
