#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Core - High-level install orchestration (full install pipeline).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Packages.psm1') -Force -Global

function Get-CachedGpuForInstall {
    param([string]$EnvironmentName)

    $envState = Get-EnvironmentState -Name $EnvironmentName
    $gpu = ConvertTo-StateHashtable -InputObject $(if ($envState) { $envState.gpu } else { $null })
    if ($gpu.ContainsKey('gfx') -and $gpu['gfx'] -and $gpu.ContainsKey('rocmIndex') -and $gpu['rocmIndex']) {
        return $gpu
    }

    $cfg = Get-Config
    if (-not (Test-Path $cfg.EnvStateFolder)) {
        return @{}
    }

    $stateFiles = Get-ChildItem -LiteralPath $cfg.EnvStateFolder -Filter 'environment-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    foreach ($stateFile in $stateFiles) {
        $state = Read-StateFile -Path $stateFile.FullName
        $gpu = ConvertTo-StateHashtable -InputObject $(if ($state) { $state.gpu } else { $null })
        if ($gpu.ContainsKey('gfx') -and $gpu['gfx'] -and $gpu.ContainsKey('rocmIndex') -and $gpu['rocmIndex']) {
            return $gpu
        }
    }

    return @{}
}

function Invoke-FullInstall {
    param(
        [string]$InstanceName,
        [string]$Channel          = 'stable',
        [string]$PythonVersion    = '3.12.10',
        [string]$GfxOverride      = '',
        [string]$ProfileName      = '',
        [switch]$Force,
        [switch]$SharedWorkflows
    )

    # Load all modules
    $modDir = $PSScriptRoot
    Import-Module (Join-Path $modDir 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Logging.psm1')     -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.UI.psm1')          -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Locking.psm1')     -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Download.psm1')    -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Runtime.psm1')     -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Environment.psm1') -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Hardware.psm1')    -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Rocm.psm1')        -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.ComfyUI.psm1')     -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.CustomNodes.psm1') -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Packages.psm1')    -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Launcher.psm1')     -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.State.psm1')        -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.Validation.psm1')   -Force -Global
    Import-Module (Join-Path $modDir 'RocmRoll.ComfyDesktop.psm1') -Force -Global

    $cfg = Get-Config
    $now = (Get-Date).ToString('yyyy-MM-dd')

    # Logging setup
    $logPrefix = Join-Path $cfg.LogsInstallFolder "${now}_${InstanceName}_install"
    Initialize-Logging -Level 'INFO' -LogFile "$logPrefix.log" -JsonlFile "$logPrefix.jsonl"
    Initialize-UI -TotalSteps 10

    # Channel manifest
    $channelManifest = Get-Content (Join-Path $cfg.ManifestsFolder 'channels.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $channelCfg      = $channelManifest.$Channel
    if (-not $channelCfg) { throw "Unknown channel '$Channel'" }

    $envName = "$InstanceName-py$($PythonVersion.Split('.')[0])$($PythonVersion.Split('.')[1])"

    # Capture any existing ComfyUI Desktop registration ID before overwriting state
    $priorState        = Get-InstanceState -Name $InstanceName
    $existingDesktopId = if ($priorState -and $priorState.PSObject.Properties['comfyDesktopId']) { [string]$priorState.comfyDesktopId } else { '' }

    Invoke-WithLock -LockName "instance-$InstanceName" -Force:$Force -ScriptBlock {

        # Step 1 - Platform check
        Write-Step "Checking platform"
        Initialize-FolderStructure
        Write-StepOk "Folder structure ready"

        # Step 2 - Cache
        Write-Step "Preparing cache"
        Write-StepOk "Cache directories ready"

        # Step 3 - Python runtime
        Write-Step "Resolving Python runtime $PythonVersion"
        Invoke-CreatePythonRuntime -Version $PythonVersion -Force:$Force | Out-Null
        Write-StepOk "Runtime ready: $(Join-Path $cfg.RuntimesFolder "python-$PythonVersion")"

        # Step 4 - Python environment
        Write-Step "Creating Python environment"
        Invoke-CreateEnvironment -Name $envName -RuntimeVersion $PythonVersion -Force:$Force | Out-Null
        Write-StepOk "Environment ready: $envName"

        # Step 5 - GPU detection
        Write-Step "Detecting AMD GPU"
        $gpu = Invoke-GpuDetect -PythonExe (Get-EnvironmentPython -Name $envName) -GfxOverride $GfxOverride -Quiet
        if ((-not $gpu.detected) -or (-not $gpu.gfx) -or (-not $gpu.rocmIndex)) {
            $cachedGpu = Get-CachedGpuForInstall -EnvironmentName $envName

            if ($cachedGpu.ContainsKey('gfx') -and $cachedGpu['gfx'] -and
                $cachedGpu.ContainsKey('rocmIndex') -and $cachedGpu['rocmIndex']) {
                $cachedName = if ($cachedGpu.ContainsKey('name') -and $cachedGpu['name']) { $cachedGpu['name'] } else { "Cached AMD GPU" }
                $cachedArchitecture = if ($cachedGpu.ContainsKey('architectureName') -and $cachedGpu['architectureName']) { $cachedGpu['architectureName'] } else { "Unknown" }
                $cachedRequiresPreRelease = $false
                if ($cachedGpu.ContainsKey('requiresPreRelease')) {
                    $cachedRequiresPreRelease = [bool]$cachedGpu['requiresPreRelease']
                }

                Write-StepWarn "Live GPU detection unavailable; using cached GPU: $cachedName / $($cachedGpu['gfx']) / $cachedArchitecture"
                $gpu = [pscustomobject]@{
                    detected           = $true
                    supported          = $true
                    name               = $cachedName
                    vendor             = 'AMD'
                    architecture       = $cachedArchitecture
                    gfx                = $cachedGpu['gfx']
                    rocmIndex          = $cachedGpu['rocmIndex']
                    requiresPreRelease = $cachedRequiresPreRelease
                    detectionMethod    = 'state'
                }
            } else {
                throw "ROCMROLL-GPU-005: No AMD GPU detected. Use --gfx to override."
            }
        }
        Write-StepOk "GPU: $($gpu.name) / $($gpu.gfx) / $($gpu.architecture)"
        Write-StepInfo "ROCm index: $($gpu.rocmIndex)"

        # Update environment state with GPU info
        $envState = Get-EnvironmentState -Name $envName
        Set-EnvironmentState -Name $envName -Path $envState.path -RuntimeVersion $PythonVersion `
            -Status 'installing' -Gpu @{
                name              = $gpu.name
                gfx               = $gpu.gfx
                rocmIndex         = $gpu.rocmIndex
                architectureName  = $gpu.architecture
                requiresPreRelease= $gpu.requiresPreRelease
            }

        # Step 6 - ROCm/PyTorch
        Write-Step "Installing ROCm/PyTorch"
        if ($channelCfg.rocm.source -eq 'index') {
            Write-StepInfo "Index: $($gpu.rocmIndex)"
        } else {
            Write-StepInfo "Source: AMD ROCm $($channelCfg.rocm.version) direct URLs"
        }
        Invoke-InstallRocm -EnvironmentName $envName -RocmIndex $gpu.rocmIndex `
            -RocmProfile $channelCfg.rocm -Channel $Channel -PythonVersion $PythonVersion
        Write-StepOk "torch installed and validated"

        # Step 7 - ComfyUI
        Write-Step "Downloading ComfyUI"
        $cloneResult = Invoke-CloneComfyUIInstance -InstanceName $InstanceName `
            -Repo $channelCfg.comfyui.repo -Ref $channelCfg.comfyui.ref -Force:$Force
        Invoke-InstallComfyDeps -InstanceName $InstanceName -EnvironmentName $envName
        Invoke-GenerateExtraModelPaths -InstanceName $InstanceName
        if ($SharedWorkflows) {
            Invoke-LinkSharedWorkflows -InstanceName $InstanceName
        }
        Write-StepOk "ComfyUI ready (commit: $($cloneResult.commit))"

        # Step 8 - Custom nodes
        Write-Step "Installing custom nodes"
        Invoke-InstallCustomNodes -InstanceName $InstanceName -EnvironmentName $envName
        Write-StepOk "Custom nodes installed"

        # Step 9 - ROCm performance packages (triton, sageattention+patches, bitsandbytes, flash-attn)
        Write-Step "Installing ROCm performance packages"
        Import-Module (Join-Path $modDir 'RocmRoll.Packages.psm1') -Force -Global
        Invoke-InstallPackageProfile -ProfileName 'rocm-performance' -EnvironmentName $envName -GfxVersion $gpu.gfx
        Write-StepOk "Performance packages installed"

        # Generate launchers
        Invoke-GenerateLaunchers -InstanceName $InstanceName -EnvironmentName $envName `
            -GfxVersion $gpu.gfx -Port 8188 -Channel $Channel -ProfileName $ProfileName

        # Bind the instance path into the environment's python312._pth so ComfyUI Desktop imports work
        Set-EnvironmentInstancePath -EnvironmentName $envName -InstanceName $InstanceName

        # Write instance state
        $instanceFolder = Join-Path $cfg.InstancesFolder $InstanceName
        Set-InstanceState -Name $InstanceName -Path $instanceFolder -Channel $Channel `
            -Environment $envName -Status 'ready' `
            -ComfyUI @{ repo=$channelCfg.comfyui.repo; ref=$channelCfg.comfyui.ref; commit=$cloneResult.commit } `
            -Paths @{
                input  = $cfg.InputFolder
                output = $cfg.OutputFolder
                temp   = $cfg.TempDataFolder
                models = $cfg.SharedModelsFolder
            }

        # Register (or update) in ComfyUI Desktop
        $instanceState = Get-InstanceState -Name $InstanceName
        $envState      = Get-EnvironmentState -Name $envName
        $desktopId     = Register-ComfyDesktopInstance -InstanceName $InstanceName `
                            -InstanceState $instanceState -EnvironmentState $envState `
                            -GfxFamily $gpu.gfx -ExistingId $existingDesktopId
        if ($desktopId) {
            Set-InstanceComfyDesktopId -Name $InstanceName -ComfyDesktopId $desktopId
        }

        # Step 9 - Validation
        Write-Step "Running validation"
        $val = Invoke-ValidateInstance -InstanceName $InstanceName
        if ($val.passed) {
            Write-StepOk "All checks passed"
        } else {
            $failed = $val.checks | Where-Object { -not $_.passed } | ForEach-Object { $_.check }
            Write-StepWarn "Some checks failed: $($failed -join ', ')"
        }

        Write-Banner -InstanceName $InstanceName -Channel $Channel -PythonVersion $PythonVersion `
            -GpuName $gpu.name -GfxFamily $gpu.gfx -Architecture $gpu.architecture
        Write-Summary
    }
}

Export-ModuleMember -Function Invoke-FullInstall
