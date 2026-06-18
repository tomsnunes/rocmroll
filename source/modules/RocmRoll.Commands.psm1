#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Commands - CLI command handlers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RocmRollInitCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    Initialize-FolderStructure
    $cfgFile = Initialize-DefaultConfigFile
    if (Test-Path $cfgFile) {
        Write-LogInfo "Config file: $cfgFile" -Comp 'RocmRoll'
    }
    Write-LogSuccess "ROCmRoll initialized at $($Context.RootFolder)" -Comp 'RocmRoll'
}

function Invoke-RocmRollInstallCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    Invoke-FullInstall -InstanceName $Context.InstanceName -Channel $Context.Channel `
        -PythonVersion $Context.PythonVersion -GfxOverride $Context.GfxOverride `
        -ProfileName $Context.ProfileName -Force:$Context.FlagForce `
        -SharedWorkflows:$Context.FlagSharedWorkflows
}

function Invoke-RocmRollUpdateCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    Invoke-FullInstall -InstanceName $Context.InstanceName -Channel $Context.Channel `
        -PythonVersion $Context.PythonVersion -GfxOverride $Context.GfxOverride `
        -ProfileName $Context.ProfileName -Force
}

function Invoke-RocmRollDoctorCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    $doctorArgs = @{
        InstanceName = $Context.InstanceName
        GpuOnly      = $Context.FlagGpuOnly
        CacheOnly    = $Context.FlagCacheOnly
        SystemOnly   = $Context.FlagSystemOnly
        JsonOutput   = $Context.FlagJson
    }
    if ($Context.FlagJson) {
        Invoke-Doctor @doctorArgs
    } else {
        Invoke-Doctor @doctorArgs | Out-Null
    }
}

function Invoke-RocmRollRepairCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    $comp = if ($Context.Component) { $Context.Component } else { 'all' }
    $rollbackPatchValue = if ($Context.RollbackPatch) { $Context.RollbackPatch } else { '' }
    Invoke-RepairComponent -InstanceName $Context.InstanceName -Component $comp `
        -RollbackPatch $rollbackPatchValue -ProfileName $Context.ProfileName `
        -SharedWorkflows:$Context.FlagSharedWorkflows
}

function Invoke-RocmRollRocmCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    $subCmd = $Context.SubCommand
    switch ($subCmd) {
        'info' {
            $instState = Get-InstanceState -Name $Context.InstanceName
            $envName = if ($instState -and $instState.environment) { $instState.environment } else { $Context.InstanceName }
            $envState = Get-EnvironmentState -Name $envName

            Write-Host ''
            Write-Host "  ROCm Environment: $($Context.InstanceName)" -ForegroundColor Cyan
            Write-Host ''
            if ($envState) {
                Write-Host ("  {0,-12} {1}" -f 'Environment', $envName) -ForegroundColor White
                Write-Host ("  {0,-12} {1}" -f 'Status', $envState.status) -ForegroundColor White
                if ($envState.gpu) {
                    $gpu = $envState.gpu
                    $gpuName = if ($gpu.PSObject.Properties['name']) { $gpu.name } else { '' }
                    $gpuGfx = if ($gpu.PSObject.Properties['gfx']) { $gpu.gfx } else { '' }
                    $gpuArch = if ($gpu.PSObject.Properties['architectureName']) { " / $($gpu.architectureName)" } else { '' }
                    $gpuLabel = if ($gpuName) { "$gpuName ($gpuGfx$gpuArch)" } elseif ($gpuGfx) { "$gpuGfx$gpuArch" } else { 'Unknown GPU' }
                    Write-Host ("  {0,-12} {1}" -f 'GPU', $gpuLabel) -ForegroundColor White
                }
                if ($envState.packages) {
                    Write-Host ''
                    Write-Host '  Packages:' -ForegroundColor Yellow
                    foreach ($pkg in $envState.packages.PSObject.Properties) {
                        Write-Host ("    {0,-28} {1}" -f $pkg.Name, $pkg.Value) -ForegroundColor Gray
                    }
                }
            } else {
                Write-Host '  No environment state found. Run rocmroll install first.' -ForegroundColor Yellow
            }
            Write-Host ''
        }
        'validate' {
            $instState = Get-InstanceState -Name $Context.InstanceName
            $envName = if ($instState -and $instState.environment) { $instState.environment } else { $Context.InstanceName }
            $result = Invoke-ValidateRocm -EnvironmentName $envName
            if ($Context.FlagJson) {
                $result | ConvertTo-Json -Depth 5
            } else {
                Write-Host ''
                Write-Host "  ROCm Validation: $($Context.InstanceName)" -ForegroundColor Cyan
                Write-Host ''
                $passed = if ($result.passed) { 'PASS' } else { 'FAIL' }
                $color = if ($result.passed) { 'Green' } else { 'Red' }
                Write-Host "  Result : $passed" -ForegroundColor $color
                $torchVer = if ($result.PSObject.Properties['torchVersion']) { $result.torchVersion } else { $null }
                $hipVer = if ($result.PSObject.Properties['hipVersion']) { $result.hipVersion } else { $null }
                $devCount = if ($result.PSObject.Properties['deviceCount']) { $result.deviceCount } else { $null }
                $devName = $null
                if ($result.PSObject.Properties['checks'] -and $result.checks) {
                    $devChks = @($result.checks | Where-Object { $_.check -eq 'device_name' -and $_.passed })
                    if ($devChks.Count -gt 0 -and $devChks[0].PSObject.Properties['value']) { $devName = $devChks[0].value }
                }
                if ($torchVer) { Write-Host ("  {0,-12} {1}" -f 'torch', $torchVer) -ForegroundColor Gray }
                if ($hipVer) { Write-Host ("  {0,-12} {1}" -f 'HIP', $hipVer) -ForegroundColor Gray }
                if ($null -ne $devCount) { Write-Host ("  {0,-12} {1}" -f 'Devices', $devCount) -ForegroundColor Gray }
                if ($devName) { Write-Host ("  {0,-12} {1}" -f 'Device', $devName) -ForegroundColor Gray }
                if (-not $result.passed -and $result.error) {
                    Write-Host "  error  : $($result.error)" -ForegroundColor Red
                }
                Write-Host ''
            }
        }
        default {
            Write-Host ''
            Write-Host "  Usage: rocmroll rocm <info|validate> --instance NAME" -ForegroundColor Yellow
            Write-Host ''
            Show-RocmRollHelp -Command 'rocm'
        }
    }
}

function Invoke-RocmRollComfyCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollModules -ModulesDir $Context.ModulesDir
    $cfg = Get-Config
    $instState = Get-InstanceState -Name $Context.InstanceName
    $envName = if ($Context.EnvName) {
        $Context.EnvName
    } elseif ($instState -and $instState.environment) {
        $instState.environment
    } else {
        "$($Context.InstanceName)-py$($Context.PythonVersion.Replace('.','').Substring(0,3))"
    }

    switch ($Context.SubCommand) {
        'info' {
            $nodesDir = Join-Path $cfg.InstancesFolder "$($Context.InstanceName)\custom_nodes"
            $nodesList = @()
            if (Test-Path $nodesDir) {
                $nodesList = @(Get-ChildItem $nodesDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            }
            Write-Host ''
            Write-Host "  ComfyUI: $($Context.InstanceName)" -ForegroundColor Cyan
            Write-Host ''
            if ($instState) {
                Write-Host ("  {0,-9} {1}" -f 'Status', $instState.status) -ForegroundColor White
                Write-Host ("  {0,-9} {1}" -f 'Channel', $instState.channel) -ForegroundColor White
                if ($instState.comfyui) {
                    if ($instState.comfyui.ref) { Write-Host ("  {0,-9} {1}" -f 'Ref', $instState.comfyui.ref) -ForegroundColor Gray }
                    if ($instState.comfyui.commit) { Write-Host ("  {0,-9} {1}" -f 'Commit', $instState.comfyui.commit) -ForegroundColor Gray }
                }
            } else {
                Write-Host '  No instance state found. Run rocmroll install first.' -ForegroundColor Yellow
            }
            Write-Host ''
            Write-Host "  Custom nodes ($($nodesList.Count)):" -ForegroundColor Yellow
            if ($nodesList.Count -eq 0) {
                Write-Host '    (none)' -ForegroundColor DarkGray
            } else {
                foreach ($n in $nodesList) { Write-Host "    $n" -ForegroundColor Gray }
            }
            Write-Host ''
        }
        'requirements' { Invoke-InstallComfyDeps -InstanceName $Context.InstanceName -EnvironmentName $envName }
        'nodes' {
            $nodesDir = Join-Path $cfg.InstancesFolder "$($Context.InstanceName)\custom_nodes"
            Write-Host ''
            Write-Host "  Custom nodes: $($Context.InstanceName)" -ForegroundColor Cyan
            Write-Host ''
            if (Test-Path $nodesDir) {
                $dirs = @(Get-ChildItem $nodesDir -Directory -ErrorAction SilentlyContinue)
                if ($dirs.Count -eq 0) {
                    Write-Host '  No custom nodes installed.' -ForegroundColor Gray
                } else {
                    foreach ($d in $dirs) { Write-Host "    $($d.Name)" -ForegroundColor Gray }
                }
            } else {
                Write-Host '  custom_nodes folder not found.' -ForegroundColor Yellow
            }
            Write-Host ''
        }
        'update-nodes' { Invoke-InstallCustomNodes -InstanceName $Context.InstanceName -EnvironmentName $envName -Update }
        'add-node' { Invoke-InstallNodeFromUrl -Url $Context.Url -InstanceName $Context.InstanceName -EnvironmentName $envName }
        'node-requirements' { Invoke-InstallCustomNodes -InstanceName $Context.InstanceName -EnvironmentName $envName -RequirementsOnly }
        default {
            Write-Host ''
            Write-Host "  Usage: rocmroll comfy <info|requirements|nodes|update-nodes|add-node|node-requirements> --instance NAME" -ForegroundColor Yellow
            Write-Host ''
            Show-RocmRollHelp -Command 'comfy'
        }
    }
}

function Invoke-RocmRollLaunchCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Launcher.psm1') -Force -Global
    $instanceName = $Context.InstanceName

    if (-not $instanceName) {
        $cfg = Get-Config
        $instances = @()
        foreach ($f in (Get-ChildItem $cfg.InstanceStateFolder -Filter 'instance-*.json' -ErrorAction SilentlyContinue)) {
            try {
                $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($s.status -eq 'ready') {
                    $instances += [PSCustomObject]@{
                        Name = [string]$s.name
                        Channel = if ($s.channel) { [string]$s.channel } else { '-' }
                    }
                }
            } catch {
                Write-LogDebug "Skipping malformed instance state '$($f.FullName)': $($_.Exception.Message)" -Comp 'RocmRoll.Commands'
            }
        }

        if ($instances.Count -eq 0) {
            Write-Host ''
            Write-Host '  No ready instances found.' -ForegroundColor Red
            Write-Host '  Run: rocmroll install --instance NAME' -ForegroundColor DarkGray
            Write-Host ''
            exit 1
        }

        if ($instances.Count -eq 1) {
            $instanceName = $instances[0].Name
            Write-Host ''
            Write-Host "  Auto-selected instance: $instanceName" -ForegroundColor DarkGray
            Write-Host ''
        } else {
            Write-Host ''
            Write-Host '  ROCmRoll' -ForegroundColor Cyan -NoNewline
            Write-Host ' - Launch ComfyUI'
            Write-Host ''
            Write-Host '  Available instances:' -ForegroundColor White
            Write-Host ''
            for ($i = 0; $i -lt $instances.Count; $i++) {
                $inst = $instances[$i]
                $num = "[$($i + 1)]".PadRight(5)
                $name = $inst.Name.PadRight(28)
                Write-Host "    $num $name channel: $($inst.Channel)"
            }
            Write-Host ''
            $chosen = $null
            while ($null -eq $chosen) {
                $choice = Read-Host "  Select (1-$($instances.Count)) or Q to quit"
                if ($choice -ieq 'q') { Write-Host ''; exit 0 }
                $n = 0
                if ([int]::TryParse($choice.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $instances.Count) {
                    $chosen = $instances[$n - 1].Name
                } else {
                    Write-Host "  Please enter a number between 1 and $($instances.Count)." -ForegroundColor Yellow
                }
            }
            $instanceName = $chosen
            Write-Host ''
        }
    }

    $launchExtra = if ($Context.PortArg) { @('--port', $Context.PortArg) } else { @() }
    $exitCode = Invoke-LaunchInstance -InstanceName $instanceName `
        -ProfileOverride $Context.ProfileName -ExtraArgs $launchExtra
    exit $exitCode
}

function Invoke-RocmRollListCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Instance.psm1') -Force -Global
    $cfg = Get-Config
    $instances = @(Get-InstalledInstanceList -Config $cfg)
    if ($instances.Count -eq 0) {
        Write-Host "No instances found." -ForegroundColor Yellow
    } else {
        foreach ($inst in $instances) {
            Write-Host ("  {0,-30} channel={1,-10} status={2}" -f $inst.Name, $inst.Channel, $inst.Status)
        }
    }
}

function Invoke-RocmRollRemoveCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Instance.psm1') -Force -Global
    Remove-RocmRollInstance -InstanceName $Context.InstanceName `
        -EnvironmentName $Context.EnvName -PythonVersion $Context.PythonVersion `
        -Force:$Context.FlagForce -Config (Get-Config)
}

function Invoke-RocmRollCacheCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Cache.psm1') -Force -Global
    $sub = if ($Context.SubCommand) { $Context.SubCommand } else { 'list' }
    switch ($sub) {
        'list' {
            Get-CacheSummary | ForEach-Object {
                $_.GetEnumerator() | ForEach-Object {
                    Write-Host ("  {0,-15} {1} files, {2} MB" -f $_.Key, $_.Value.fileCount, [math]::Round($_.Value.totalBytes / 1MB, 1))
                }
            }
        }
        'verify' {
            $r = Invoke-CacheVerify
            $r | ForEach-Object { Write-Host ("  {0,-50} {1}" -f $_.file, $_.status) }
        }
        'clean' {
            if ($Context.RemainingArgs -contains '--all') {
                Remove-AllCache | Out-Null
            } else {
                if ($Context.RemainingArgs -contains '--temp') { Remove-TempFolder }
                Remove-PartialDownloads | Out-Null
            }
        }
        'prune' {
            $days = if ($null -ne $Context.OlderThanDays) { [int]$Context.OlderThanDays } else { 30 }
            Remove-OldCacheFiles -OlderThanDays $days | Out-Null
        }
        default { Write-Host "Unknown cache subcommand: $sub. Use: list, verify, clean, prune" }
    }
}

function Invoke-RocmRollLogsCommand {
    param([Parameter(Mandatory)][object]$Context)
    $cfg = Get-Config
    $logs = Get-ChildItem $cfg.LogsFolder -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20
    $logs | ForEach-Object { Write-Host "  $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $($_.FullName)" }
}

function Invoke-RocmRollConfigCommand {
    param([Parameter(Mandatory)][object]$Context)
    $sub = if ($Context.SubCommand) { $Context.SubCommand } else { 'show' }
    switch ($sub) {
        'show' {
            $cfg = Get-Config
            $iniPath = $cfg.ConfigFilePath
            $active = Test-Path $iniPath
            Write-Host ''
            Write-Host '  ROCmRoll Configuration' -ForegroundColor Cyan
            Write-Host ''
            if ($active) {
                Write-Host "  Config file : $iniPath" -ForegroundColor Green
            } else {
                Write-Host "  Config file : $iniPath  (not found - using defaults)" -ForegroundColor Yellow
            }
            Write-Host ''
            Write-Host '  Paths:' -ForegroundColor Yellow
            Write-Host ''
            $entries = [ordered]@{
                'Root' = 'RootFolder'; 'Shared' = 'SharedFolder'; 'Input' = 'InputFolder'
                'Output' = 'OutputFolder'; 'Temp' = 'TempDataFolder'; 'User Data' = 'UserDataFolder'
                'Instances' = 'InstancesFolder'; 'Environments' = 'EnvironmentsFolder'; 'Runtimes' = 'RuntimesFolder'
                'Launchers' = 'LaunchersFolder'; 'Profiles' = 'ProfilesFolder'; 'Logs' = 'LogsFolder'
                'State' = 'StateFolder'; 'Cache' = 'CacheFolder'
            }
            foreach ($e in $entries.GetEnumerator()) {
                Write-Host ('    {0,-14} {1}' -f "$($e.Key):", $cfg[$e.Value]) -ForegroundColor Gray
            }
            Write-Host ''
            Write-Host '  Workspace:' -ForegroundColor Yellow
            Write-Host ''
            $wsName = if ($cfg.Contains('ActiveWorkspace') -and $cfg['ActiveWorkspace']) { $cfg['ActiveWorkspace'] } else { '(none)' }
            Write-Host ('    {0,-14} {1}' -f 'Active:', $wsName) -ForegroundColor Gray
            $wsDir = if ($cfg.Contains('WorkspacesFolder')) { $cfg['WorkspacesFolder'] } else { '' }
            if ($wsDir) { Write-Host ('    {0,-14} {1}' -f 'Folder:', $wsDir) -ForegroundColor Gray }
            Write-Host ''
            if (-not $active) {
                Write-Host "  Tip: run 'rocmroll config init' to create rocmroll.ini." -ForegroundColor DarkGray
            } else {
                Write-Host "  Edit $iniPath to customise paths." -ForegroundColor DarkGray
            }
            Write-Host "  Tip: run 'rocmroll workspace create' to set up named workspaces." -ForegroundColor DarkGray
            Write-Host ''
        }
        'init' {
            $cfg = Get-Config
            $iniPath = $cfg.ConfigFilePath
            $existed = Test-Path $iniPath
            Initialize-DefaultConfigFile | Out-Null
            Write-Host ''
            if ($existed) {
                Write-Host "  Config file already exists: $iniPath" -ForegroundColor Yellow
            } else {
                Write-Host "  Config file created: $iniPath" -ForegroundColor Green
            }
            Write-Host ''
        }
        default {
            Write-Host ''
            Write-Host "  Unknown config sub-command: '$sub'. Use: show, init" -ForegroundColor Yellow
            Write-Host ''
        }
    }
}

function Invoke-RocmRollProfileCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Profiles.psm1') -Force -Global
    $cfg = Get-Config
    $subCmd = if ($Context.SubCommand) { $Context.SubCommand } else { 'list' }
    switch ($subCmd) {
        'list' {
            $all = Get-ProfileList -Config $cfg
            if ($all.Count -eq 0) {
                Write-Host ''
                Write-Host "  No profiles found in: $($cfg.ProfilesFolder)" -ForegroundColor Yellow
                Write-Host ''
            } else {
                Write-Host ''
                Write-Host '  ROCmRoll Execution Profiles' -ForegroundColor Cyan
                $all | Show-ProfileDetail
                Write-Host ''
            }
        }
        'show' {
            $obj = Get-ProfileObject -Name $Context.ProfileName -Config $cfg
            Write-Host ''
            Write-Host '  ROCmRoll Profile Detail' -ForegroundColor Cyan
            $obj | Show-ProfileDetail
            Write-Host ''
        }
        'create' { New-ProfileInteractive -Name $Context.ProfileName -Config $cfg }
        'remove' { Remove-Profile -Name $Context.ProfileName -Force:$Context.FlagForce -Config $cfg }
        default {
            Write-Host ''
            Write-Host "  Unknown profile sub-command: '$subCmd'. Use: list, show, create, remove" -ForegroundColor Yellow
            Show-RocmRollHelp -Command 'profile'
            Write-Host ''
        }
    }
}

function Invoke-RocmRollPatchCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Encoding.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.ComfyPatch.psm1') -Force -Global
    $subCmd = if ($Context.SubCommand) { $Context.SubCommand } else { 'list' }
    switch ($subCmd) {
        'list' { Show-ComfyPatchList -InstanceName $Context.InstanceName }
        'apply' {
            if ($Context.PatchId) {
                Invoke-ApplyComfyPatch -PatchId $Context.PatchId -InstanceName $Context.InstanceName -GfxOverride $Context.GfxOverride
            } else {
                Invoke-ApplyAllComfyPatches -InstanceName $Context.InstanceName -GfxOverride $Context.GfxOverride
            }
        }
        'remove' { Invoke-RemoveComfyPatch -PatchId $Context.PatchId -InstanceName $Context.InstanceName }
        default {
            Write-Host ''
            Write-Host "  Unknown patch sub-command: '$subCmd'. Use: list, apply, remove" -ForegroundColor Yellow
            Show-RocmRollHelp -Command 'patch'
            Write-Host ''
        }
    }
}

function Invoke-RocmRollWorkspaceCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Logging.psm1') -Force -Global
    Import-Module (Join-Path $Context.ModulesDir 'RocmRoll.Workspace.psm1') -Force -Global
    $cfg = Get-Config
    $subCmd = if ($Context.SubCommand) { $Context.SubCommand } else { 'list' }
    $workspaceName = $Context.WorkspaceName
    switch ($subCmd) {
        'list' {
            $all = Get-WorkspaceList -Config $cfg
            $activeWs = $cfg['ActiveWorkspace']
            Write-Host ''
            Write-Host '  ROCmRoll Workspaces' -ForegroundColor Cyan
            Write-Host ''
            if (-not $activeWs) {
                Write-Host ("    {0,-20}{1}" -f '(default) [active]', ' - paths from rocmroll.ini / built-in defaults') -ForegroundColor Green
            }
            if ($all.Count -eq 0) {
                if ($activeWs) { Write-Host "  No workspace files found in: $($cfg['WorkspacesFolder'])" -ForegroundColor Yellow }
                Write-Host "  Run 'rocmroll workspace create --workspace NAME' to create one." -ForegroundColor DarkGray
            } else {
                foreach ($ws in $all) {
                    $tag = if ($ws.IsActive) { ' [active]' } else { '' }
                    $col = if ($ws.IsActive) { 'Green' } else { 'Gray' }
                    $desc = if ($ws.Description) { " - $($ws.Description)" } else { '' }
                    Write-Host ("    {0,-20}{1}" -f "$($ws.Name)$tag", $desc) -ForegroundColor $col
                }
            }
            Write-Host ''
        }
        'show' {
            $obj = Get-WorkspaceObject -Name $workspaceName -Config $cfg
            Write-Host ''
            Write-Host '  ROCmRoll Workspace Detail' -ForegroundColor Cyan
            $obj | Show-WorkspaceDetail -Config $cfg
            Write-Host ''
        }
        'create' { New-WorkspaceInteractive -Name $workspaceName -Config $cfg }
        'use' {
            if (-not $workspaceName) {
                $all = Get-WorkspaceList -Config $cfg
                if ($all.Count -eq 0) {
                    Write-Host ''
                    Write-Host '  No workspaces found. Run: rocmroll workspace create --workspace NAME' -ForegroundColor Yellow
                    Write-Host ''
                    exit 1
                }
                if ($all.Count -eq 1) {
                    $workspaceName = $all[0].Name
                    Write-Host ''
                    Write-Host "  Auto-selected workspace: $workspaceName" -ForegroundColor DarkGray
                    Write-Host ''
                } else {
                    Write-Host ''
                    Write-Host '  ROCmRoll - Switch Workspace' -ForegroundColor Cyan
                    Write-Host ''
                    for ($i = 0; $i -lt $all.Count; $i++) {
                        $ws = $all[$i]
                        $num = "[$($i + 1)]".PadRight(5)
                        $tag = if ($ws.IsActive) { ' [active]' } else { '' }
                        Write-Host "    $num $($ws.Name)$tag"
                    }
                    Write-Host ''
                    $chosen = $null
                    while ($null -eq $chosen) {
                        $choice = Read-Host "  Select (1-$($all.Count)) or Q to quit"
                        if ($choice -ieq 'q') { Write-Host ''; exit 0 }
                        $n = 0
                        if ([int]::TryParse($choice.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $all.Count) {
                            $chosen = $all[$n - 1].Name
                        } else {
                            Write-Host "  Please enter a number between 1 and $($all.Count)." -ForegroundColor Yellow
                        }
                    }
                    $workspaceName = $chosen
                    Write-Host ''
                }
            }
            Set-ActiveWorkspace -Name $workspaceName -Config $cfg
            Write-Host ''
            Write-Host "  Active workspace: $workspaceName" -ForegroundColor Green
            Write-Host "  Run 'rocmroll config show' to verify resolved paths." -ForegroundColor DarkGray
            Write-Host ''
        }
        'edit' { New-WorkspaceInteractive -Name $workspaceName -EditMode -Config $cfg }
        'remove' { Remove-Workspace -Name $workspaceName -Force:$Context.FlagForce -Config $cfg }
        'init' { Export-CurrentAsWorkspace -Name $workspaceName -Config $cfg }
        default {
            Write-Host ''
            Write-Host "  Unknown workspace sub-command: '$subCmd'. Use: list, show, create, use, edit, remove, init" -ForegroundColor Yellow
            Show-RocmRollHelp -Command 'workspace'
            Write-Host ''
        }
    }
}

function Invoke-RocmRollHelpCommand {
    param([Parameter(Mandatory)][object]$Context)
    $helpTarget = if ($Context.SubCommand) { $Context.SubCommand } else { '' }
    Show-RocmRollHelp -Command $helpTarget
}

Export-ModuleMember -Function Invoke-RocmRollInitCommand, Invoke-RocmRollInstallCommand,
    Invoke-RocmRollUpdateCommand, Invoke-RocmRollDoctorCommand, Invoke-RocmRollRepairCommand,
    Invoke-RocmRollRocmCommand, Invoke-RocmRollComfyCommand, Invoke-RocmRollLaunchCommand,
    Invoke-RocmRollListCommand, Invoke-RocmRollRemoveCommand, Invoke-RocmRollCacheCommand,
    Invoke-RocmRollLogsCommand, Invoke-RocmRollConfigCommand, Invoke-RocmRollProfileCommand,
    Invoke-RocmRollPatchCommand, Invoke-RocmRollWorkspaceCommand, Invoke-RocmRollHelpCommand
