#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Doctor - System and instance health diagnostic command.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DoctorPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [object]$DefaultValue
    )

    if ($null -eq $InputObject) { return $DefaultValue }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -eq '') {
        return $DefaultValue
    }

    return $property.Value
}

function Get-CachedDoctorGpu {
    param([string]$InstanceName = '')

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global

    $cfg = Get-Config
    $candidateGpuStates = @()

    if ($InstanceName) {
        $instanceState = Get-InstanceState -Name $InstanceName
        if ($instanceState -and $instanceState.environment) {
            $envState = Get-EnvironmentState -Name $instanceState.environment
            if ($envState -and $envState.gpu) {
                $candidateGpuStates += $envState.gpu
            }
        }
    }

    if (Test-Path $cfg.EnvStateFolder) {
        $stateFiles = Get-ChildItem -LiteralPath $cfg.EnvStateFolder -Filter 'environment-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

        foreach ($stateFile in $stateFiles) {
            $envState = Read-StateFile -Path $stateFile.FullName
            if ($envState -and $envState.gpu) {
                $candidateGpuStates += $envState.gpu
            }
        }
    }

    foreach ($candidateGpu in $candidateGpuStates) {
        $gpu = ConvertTo-StateHashtable -InputObject $candidateGpu
        if ($gpu.ContainsKey('gfx') -and $gpu['gfx'] -and
            $gpu.ContainsKey('rocmIndex') -and $gpu['rocmIndex']) {
            $gpuName = if ($gpu.ContainsKey('name') -and $gpu['name']) { $gpu['name'] } else { 'Cached AMD GPU' }
            $architecture = if ($gpu.ContainsKey('architectureName') -and $gpu['architectureName']) {
                $gpu['architectureName']
            } elseif ($gpu.ContainsKey('architecture') -and $gpu['architecture']) {
                $gpu['architecture']
            } else {
                'cached'
            }

            return [pscustomobject]@{
                detected        = $true
                supported       = $true
                name            = $gpuName
                architecture    = $architecture
                gfx             = $gpu['gfx']
                rocmIndex       = $gpu['rocmIndex']
                detectionMethod = 'state'
            }
        }
    }

    return $null
}

function Invoke-Doctor {
    param(
        [string]$InstanceName = '',
        [switch]$GpuOnly,
        [switch]$CacheOnly,
        [switch]$SystemOnly,
        [switch]$JsonOutput
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1')      -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Hardware.psm1')    -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1')       -Force -Global

    $cfg     = Get-Config
    $results = [ordered]@{ passed=$true; checks=@() }

    $Add = {
        param([string]$Name,[bool]$Passed,[string]$Detail='',[string]$Suggestion='')
        $c = [ordered]@{ check=$Name; passed=$Passed; detail=$Detail; suggestion=$Suggestion }
        $results.checks += $c
        if (-not $Passed) { $results.passed = $false }
        if ($JsonOutput) { return }
        if ($Passed) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
        else         { Write-Host "  [FAIL] ${Name}: $Detail" -ForegroundColor Red
                       if ($Suggestion) { Write-Host "         Suggestion: $Suggestion" -ForegroundColor Yellow } }
    }

    # --- System checks ---
    if (-not $GpuOnly -and -not $CacheOnly) {
        if (-not $JsonOutput) { Write-Host "`n[System]" -ForegroundColor White }

        # OS
        $osVer = [System.Environment]::OSVersion.VersionString
        & $Add 'os_windows' ($osVer -like '*Windows*') $osVer

        # PowerShell version
        & $Add 'powershell_version' ($PSVersionTable.PSVersion.Major -ge 5) "v$($PSVersionTable.PSVersion)"

        # git
        $gitVer = (& git --version 2>$null)
        $gitDetail = if ($gitVer) { $gitVer } else { 'not found' }
        & $Add 'git_available' ($LASTEXITCODE -eq 0) $gitDetail 'Install Git from https://git-scm.com'

        # Long path
        $longPathSetting = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue
        $longPath = if ($longPathSetting) { $longPathSetting.LongPathsEnabled } else { $null }
        $longPathDetail = if ($null -ne $longPath) { "LongPathsEnabled=$longPath" } else { 'LongPathsEnabled not found' }
        & $Add 'long_paths_enabled' ($longPath -eq 1) $longPathDetail 'Enable via Group Policy or: reg add HKLM\...\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1'

        # Path safety (no non-ASCII)
        $badPath = $cfg.RootFolder -match '[^\x00-\x7F]'
        & $Add 'path_ascii_only' (-not $badPath) $cfg.RootFolder 'Avoid non-ASCII characters in the root path'

        # curl.exe
        $curlVer = (& curl.exe --version 2>$null | Select-Object -First 1)
        $curlDetail = if ($curlVer) { $curlVer } else { 'not found' }
        & $Add 'curl_available' ($LASTEXITCODE -eq 0) $curlDetail
    }

    # --- GPU checks ---
    if (-not $SystemOnly -and -not $CacheOnly) {
        if (-not $JsonOutput) { Write-Host "`n[GPU]" -ForegroundColor White }
        try {
            $gpu = Invoke-GpuDetect -Quiet
            if ((-not $gpu.detected) -or (-not $gpu.gfx) -or (-not $gpu.rocmIndex)) {
                $cachedGpu = Get-CachedDoctorGpu -InstanceName $InstanceName
                if ($cachedGpu) {
                    $gpu = $cachedGpu
                }
            }
            $gpuName = Get-DoctorPropertyValue -InputObject $gpu -PropertyName 'name' -DefaultValue 'No AMD GPU detected'
            $gpuArchitecture = Get-DoctorPropertyValue -InputObject $gpu -PropertyName 'architecture' -DefaultValue 'unknown'
            $gpuGfx = Get-DoctorPropertyValue -InputObject $gpu -PropertyName 'gfx' -DefaultValue 'unmapped'
            $gpuRocmIndex = Get-DoctorPropertyValue -InputObject $gpu -PropertyName 'rocmIndex' -DefaultValue 'none'

            & $Add 'gpu_detected'    ($gpu.detected)  $gpuName          'Ensure AMD driver is installed'
            & $Add 'gpu_supported'   ($gpu.supported) $gpuArchitecture  'Check rocm-architectures.json for supported families'
            & $Add 'gpu_gfx_mapped'  ($gpuGfx -ne 'unmapped') $gpuGfx   'Add GPU to rocm-architectures.json or use --gfx override'
            & $Add 'gpu_rocm_index'  ($gpuRocmIndex -ne 'none') $gpuRocmIndex
        } catch {
            & $Add 'gpu_detection' $false "Exception: $_"
        }
    }

    # --- Instance checks ---
    if ($InstanceName -and -not $GpuOnly -and -not $CacheOnly -and -not $SystemOnly) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Validation.psm1') -Force
        if (-not $JsonOutput) { Write-Host "`n[Instance: $InstanceName]" -ForegroundColor White }
        $valResult = Invoke-ValidateInstance -InstanceName $InstanceName
        foreach ($c in $valResult.checks) {
            $results.checks += $c
            if (-not $c.passed) { $results.passed = $false }
            if (-not $JsonOutput) {
                if ($c.passed) { Write-Host "  [OK]   $($c.check)" -ForegroundColor Green }
                else           { Write-Host "  [FAIL] $($c.check): $($c.detail)" -ForegroundColor Red }
            }
        }
    }

    # --- Cache checks ---
    if (-not $SystemOnly -and -not $GpuOnly) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Cache.psm1') -Force
        if (-not $JsonOutput) { Write-Host "`n[Cache]" -ForegroundColor White }
        $summary = Get-CacheSummary
        foreach ($k in $summary.Keys) {
            $v = $summary[$k]
            $detail = "files: $($v.fileCount), size: $([math]::Round($v.totalBytes/1MB,1)) MB"
            & $Add "cache_$k" $true $detail
        }
    }

    if ($JsonOutput) {
        return ($results | ConvertTo-Json -Depth 6)
    } else {
        Write-Host ''
        if ($results.passed) { Write-Host 'All checks passed.' -ForegroundColor Green }
        else                 { Write-Host 'Some checks failed. See above.' -ForegroundColor Red }
        return $results
    }
}

Export-ModuleMember -Function Invoke-Doctor
