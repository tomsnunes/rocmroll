#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Commands - CLI command handlers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LoadedCommandModules = @{}

function Import-RocmRollCommandModules {
    param(
        [Parameter(Mandatory)][string]$ModulesDir,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($script:LoadedCommandModules.ContainsKey($name)) { continue }
        $path = Join-Path $ModulesDir "$name.psm1"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "ROCMROLL-CLI-001: Required module not found: $path"
        }
        Import-Module $path -Global -ErrorAction Stop
        $script:LoadedCommandModules[$name] = $true
    }
}

function Invoke-RocmRollInitCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Config','RocmRoll.Logging')
    Initialize-FolderStructure
    $cfgFile = Initialize-DefaultConfigFile
    if (Test-Path $cfgFile) {
        Write-LogInfo "Config file: $cfgFile" -Comp 'RocmRoll'
    }
    Write-LogSuccess "ROCmRoll initialized at $($Context.RootFolder)" -Comp 'RocmRoll'
}

function Get-RocmRollInstanceComponentScopes {
    param([Parameter(Mandatory)][object]$Context)
    $scopes = @($Context.ComponentScopes)
    if ($scopes -contains 'all') { return @('environment','rocm','comfyui','patches') }
    return $scopes
}

function Get-RocmRollUpdateDefaults {
    param([string]$InstanceName)

    $state = Get-InstanceState -Name $InstanceName
    $channel = 'stable'
    $pythonVersion = '3.12.10'
    if ($state) {
        if ($state.PSObject.Properties['channel'] -and $state.channel) { $channel = [string]$state.channel }
        if ($state.PSObject.Properties['environment'] -and $state.environment) {
            $envState = Get-EnvironmentState -Name $state.environment
            if ($envState -and $envState.PSObject.Properties['runtimeVersion'] -and $envState.runtimeVersion) {
                $pythonVersion = [string]$envState.runtimeVersion
            }
        }
    }

    return [PSCustomObject]@{
        Channel = $channel
        PythonVersion = $pythonVersion
    }
}

function Invoke-RocmRollInstanceCommand {
    param([Parameter(Mandatory)][object]$Context)

    switch ($Context.SubCommand) {
        'list'    { Invoke-RocmRollInstanceListCommand -Context $Context }
        'info'    { Invoke-RocmRollInstanceInfoCommand -Context $Context }
        'install' { Invoke-RocmRollInstanceInstallCommand -Context $Context }
        'update'  { Invoke-RocmRollInstanceUpdateCommand -Context $Context }
        'remove'  { Invoke-RocmRollInstanceRemoveCommand -Context $Context }
        'launch'  { Invoke-RocmRollInstanceLaunchCommand -Context $Context }
        'repair'  { Invoke-RocmRollInstanceRepairCommand -Context $Context }
        default   { Show-RocmRollHelp -Command 'instance' }
    }
}

function Resolve-RocmRollInstanceDefinitionPath {
    <#
    .SYNOPSIS
        Resolves the ComfyUIInstance YAML definition path for plan/apply/destroy:
        --file if given, else the default overlays\<name>\<name>.yaml for --name.
        Exits with a clear error if neither resolves to an existing file.
    #>
    param([Parameter(Mandatory)][object]$Context)

    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.InstanceDefinition')

    $path = if ($Context.DefinitionFile) {
        $Context.DefinitionFile
    } elseif ($Context.InstanceName) {
        Get-InstanceDefinitionPath -InstanceName $Context.InstanceName
    } else {
        ''
    }

    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ''
        if ($path) {
            Write-Host "  ERROR  Instance definition file not found: $path" -ForegroundColor Red
        } else {
            Write-Host '  ERROR  Provide --file PATH or --name NAME (overlays\NAME\NAME.yaml).' -ForegroundColor Red
        }
        Write-Host ''
        exit 1
    }

    return $path
}

function Invoke-RocmRollPlanCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.InstanceDefinition', 'RocmRoll.InstancePlan'
    )

    $definitionPath = Resolve-RocmRollInstanceDefinitionPath -Context $Context
    $definition = Read-InstanceDefinition -FilePath $definitionPath
    foreach ($warning in $definition.Warnings) {
        Write-LogWarn $warning -Comp 'RocmRoll.InstanceDefinition' -Inst $definition.Name
    }

    $plan = Get-InstancePlan -Definition $definition

    if ($Context.FlagJson) {
        ConvertTo-InstancePlanJson -Plan $plan
    } else {
        Format-InstancePlanText -Plan $plan
    }

    if ($Context.OutputPath) {
        Save-InstancePlan -Plan $plan -Path $Context.OutputPath | Out-Null
        Write-Host "  Plan written to: $($Context.OutputPath)" -ForegroundColor Green
        Write-Host ''
    }
}

function Invoke-RocmRollApplyCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.InstanceDefinition', 'RocmRoll.InstancePlan'
    )

    $definitionPath = Resolve-RocmRollInstanceDefinitionPath -Context $Context
    $definition = Read-InstanceDefinition -FilePath $definitionPath
    foreach ($warning in $definition.Warnings) {
        Write-LogWarn $warning -Comp 'RocmRoll.InstanceDefinition' -Inst $definition.Name
    }

    if ($Context.PlanFile) {
        if (-not (Test-Path -LiteralPath $Context.PlanFile -PathType Leaf)) {
            Write-Host ''
            Write-Host "  ERROR  Plan file not found: $($Context.PlanFile)" -ForegroundColor Red
            Write-Host ''
            exit 1
        }
        $savedPlanJson = Get-Content -LiteralPath $Context.PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$savedPlanJson.instance -ne $definition.Name) {
            Write-Host ''
            Write-Host "  ERROR  Plan file '$($Context.PlanFile)' was generated for instance '$($savedPlanJson.instance)', not '$($definition.Name)'." -ForegroundColor Red
            Write-Host ''
            exit 1
        }
        $plan = [pscustomobject]@{
            ApiVersion = [string]$savedPlanJson.apiVersion
            Kind       = [string]$savedPlanJson.kind
            Instance   = [string]$savedPlanJson.instance
            CreatedAt  = [string]$savedPlanJson.createdAt
            Actions    = @($savedPlanJson.actions | ForEach-Object {
                [pscustomobject]@{ Id = [string]$_.id; Type = [string]$_.type; Target = [string]$_.target; Reason = [string]$_.reason; Destructive = [bool]$_.destructive }
            })
        }
        if (Test-InstancePlanStale -Definition $definition -SavedPlan $plan) {
            Write-LogWarn "Saved plan '$($Context.PlanFile)' no longer matches current state/definition; the actions below may be stale." -Comp 'RocmRoll.InstancePlan' -Inst $definition.Name
        }
    } else {
        $plan = Get-InstancePlan -Definition $definition
    }

    $result = Invoke-InstanceApply -Definition $definition -Plan $plan `
        -AutoApprove:$Context.FlagAutoApprove -AllowDestructive:$Context.FlagAllowDestructive -DryRun:$Context.FlagDryRun

    if ($result.Blocked.Count -gt 0) { exit 3 }
}

function Invoke-RocmRollDestroyCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.InstanceDefinition', 'RocmRoll.InstancePlan'
    )

    $definitionPath = Resolve-RocmRollInstanceDefinitionPath -Context $Context
    $definition = Read-InstanceDefinition -FilePath $definitionPath
    foreach ($warning in $definition.Warnings) {
        Write-LogWarn $warning -Comp 'RocmRoll.InstanceDefinition' -Inst $definition.Name
    }

    $plan = Get-InstanceDestroyPlan -InstanceName $definition.Name

    if ($Context.FlagJson) {
        ConvertTo-InstancePlanJson -Plan $plan
    } else {
        Format-InstancePlanText -Plan $plan
    }

    if ($Context.FlagDryRun) { return }

    $result = Invoke-InstanceDestroy -Definition $definition -Plan $plan -AutoApprove:$Context.FlagAutoApprove
    if ($result.Cancelled) { exit 1 }
}

function Invoke-RocmRollImportCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.InstanceDefinition', 'RocmRoll.InstancePlan'
    )

    $targetPath = if ($Context.OutputPath) { $Context.OutputPath } else { Get-InstanceDefinitionPath -InstanceName $Context.InstanceName }
    if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and -not $Context.FlagForce) {
        Write-Host ''
        Write-Host "  ERROR  Definition file already exists: $targetPath" -ForegroundColor Red
        Write-Host '  Use --force to overwrite, or --output PATH to write elsewhere.' -ForegroundColor DarkGray
        Write-Host ''
        exit 1
    }

    try {
        $writtenPath = Export-InstanceDefinition -InstanceName $Context.InstanceName -OutPath $targetPath -Force:$Context.FlagForce
    } catch {
        Write-Host ''
        Write-Host "  ERROR  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        exit 1
    }

    Write-Host ''
    Write-Host "  Imported '$($Context.InstanceName)' -> $writtenPath" -ForegroundColor Green

    $definition = Read-InstanceDefinition -FilePath $writtenPath
    foreach ($warning in $definition.Warnings) {
        Write-LogWarn $warning -Comp 'RocmRoll.InstanceDefinition' -Inst $definition.Name
    }

    Write-Host ''
    Write-Host '  Verifying the import with a plan (expect mostly NOOP/PRESERVE):' -ForegroundColor Cyan
    $plan = Get-InstancePlan -Definition $definition
    Format-InstancePlanText -Plan $plan
    Write-Host "  Edit $writtenPath to adjust spec.profile, spec.updatePolicy, or overlay sources before running 'rocmroll apply'." -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-RocmRollInstanceInstallCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Core')
    Invoke-FullInstall -InstanceName $Context.InstanceName -Channel $Context.Channel `
        -PythonVersion $Context.PythonVersion -GfxOverride $Context.GfxOverride `
        -ProfileName $Context.ProfileName -Force:$Context.FlagForce `
        -SharedWorkflows:$Context.FlagSharedWorkflows
}

function Invoke-RocmRollInstanceUpdateCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.State','RocmRoll.Repair','RocmRoll.Core')

    $scopes = @(Get-RocmRollInstanceComponentScopes -Context $Context)
    $updateAll = ($Context.ComponentScopes -contains 'all') -or ($scopes.Count -eq 0) -or
        (@($scopes | Where-Object { $_ -in @('environment','rocm','comfyui') }).Count -eq 3)

    if ($updateAll) {
        $defaults = Get-RocmRollUpdateDefaults -InstanceName $Context.InstanceName
        Invoke-FullInstall -InstanceName $Context.InstanceName -Channel $defaults.Channel `
            -PythonVersion $defaults.PythonVersion -Force:$Context.FlagForce -IsUpdate
        return
    }

    foreach ($scope in $scopes) {
        switch ($scope) {
            'environment' { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'python-env' }
            'rocm'        { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'rocm' }
            'comfyui'     { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'comfyui' }
        }
    }
}

function Invoke-RocmRollInstanceRepairCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Repair')
    $scopes = @(Get-RocmRollInstanceComponentScopes -Context $Context)
    foreach ($scope in $scopes) {
        switch ($scope) {
            'environment' { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'python-env' -Force:$Context.FlagForce }
            'rocm'        { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'rocm' -Force:$Context.FlagForce }
            'comfyui'     { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'comfyui' -Force:$Context.FlagForce }
            'patches'     { Invoke-RepairComponent -InstanceName $Context.InstanceName -Component 'patches' -Force:$Context.FlagForce }
        }
    }
}

function Invoke-RocmRollDoctorCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.State','RocmRoll.Validation','RocmRoll.Doctor')

    if (($Context.FlagRocm -or $Context.FlagComfyUi) -and -not $Context.InstanceName) {
        Write-Host ''
        Write-Host '  ERROR  --rocm and --comfyui doctor scopes require --instance NAME.' -ForegroundColor Red
        Write-Host ''
        exit 1
    }

    if ($Context.FlagRocm) {
        $state = Get-InstanceState -Name $Context.InstanceName
        Write-Host ''
        Write-Host "  ROCm Doctor: $($Context.InstanceName)" -ForegroundColor Cyan
        if (-not $state) {
            Write-Host '  Instance state not found.' -ForegroundColor Red
            Write-Host ''
            exit 1
        }
        Show-RocmRollInstanceRocmInfo -InstanceState $state
        Write-Host ''
        return
    }

    if ($Context.FlagComfyUi) {
        Write-Host ''
        Write-Host "  ComfyUI Doctor: $($Context.InstanceName)" -ForegroundColor Cyan
        $result = Invoke-ValidateInstance -InstanceName $Context.InstanceName
        if ($Context.FlagJson) {
            $result | ConvertTo-Json -Depth 5
        } else {
            Write-Host ''
            foreach ($check in $result.checks) {
                $status = if ($check.passed) { '[OK]  ' } else { '[FAIL]' }
                $color = if ($check.passed) { 'Green' } else { 'Red' }
                Write-Host ("  {0} {1} {2}" -f $status, $check.check, $check.detail) -ForegroundColor $color
            }
            Write-Host ''
        }
        return
    }

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

function Show-RocmRollInstanceEnvironmentInfo {
    param([object]$InstanceState)

    if (-not $InstanceState -or -not $InstanceState.environment) {
        Write-Host ''
        Write-Host '  Environment: not found' -ForegroundColor Yellow
        return
    }

    $envState = Get-EnvironmentState -Name $InstanceState.environment
    Write-Host ''
    Write-Host '  Environment' -ForegroundColor Yellow
    if ($envState) {
        Write-Host ("    {0,-12} {1}" -f 'Name', $InstanceState.environment) -ForegroundColor Gray
        Write-Host ("    {0,-12} {1}" -f 'Status', $envState.status) -ForegroundColor Gray
        if ($envState.PSObject.Properties['runtimeVersion']) {
            Write-Host ("    {0,-12} {1}" -f 'Python', $envState.runtimeVersion) -ForegroundColor Gray
        }
        if ($envState.PSObject.Properties['path']) {
            Write-Host ("    {0,-12} {1}" -f 'Path', $envState.path) -ForegroundColor Gray
        }
    } else {
        Write-Host "    State not found for '$($InstanceState.environment)'" -ForegroundColor Yellow
    }
}

function Show-RocmRollInstanceRocmInfo {
    param([object]$InstanceState)

    $envState = if ($InstanceState -and $InstanceState.environment) { Get-EnvironmentState -Name $InstanceState.environment } else { $null }
    Write-Host ''
    Write-Host '  ROCm' -ForegroundColor Yellow
    if (-not $envState) {
        Write-Host '    Environment state not found.' -ForegroundColor Yellow
        return
    }

    if ($envState.PSObject.Properties['gpu'] -and $envState.gpu) {
        $gpu = $envState.gpu
        $gpuName = if ($gpu.PSObject.Properties['name']) { $gpu.name } else { 'Unknown GPU' }
        $gfx = if ($gpu.PSObject.Properties['gfx']) { $gpu.gfx } else { 'unknown' }
        $arch = if ($gpu.PSObject.Properties['architectureName']) { $gpu.architectureName } else { '' }
        Write-Host ("    {0,-12} {1}" -f 'GPU', "$gpuName ($gfx $arch)") -ForegroundColor Gray
    }

    if ($envState.PSObject.Properties['packages'] -and $envState.packages) {
        foreach ($pkg in $envState.packages.PSObject.Properties) {
            Write-Host ("    {0,-28} {1}" -f $pkg.Name, $pkg.Value) -ForegroundColor Gray
        }
    }
}

function Show-RocmRollInstanceComfyUiInfo {
    param([object]$InstanceState, [hashtable]$Config)

    Write-Host ''
    Write-Host '  ComfyUI' -ForegroundColor Yellow
    if (-not $InstanceState) {
        Write-Host '    Instance state not found.' -ForegroundColor Yellow
        return
    }

    Write-Host ("    {0,-12} {1}" -f 'Status', $InstanceState.status) -ForegroundColor Gray
    Write-Host ("    {0,-12} {1}" -f 'Channel', $InstanceState.channel) -ForegroundColor Gray
    if ($InstanceState.PSObject.Properties['comfyui'] -and $InstanceState.comfyui) {
        if ($InstanceState.comfyui.PSObject.Properties['ref']) {
            Write-Host ("    {0,-12} {1}" -f 'Ref', $InstanceState.comfyui.ref) -ForegroundColor Gray
        }
        if ($InstanceState.comfyui.PSObject.Properties['commit']) {
            Write-Host ("    {0,-12} {1}" -f 'Commit', $InstanceState.comfyui.commit) -ForegroundColor Gray
        }
    }

    $nodesDir = Join-Path $Config.InstancesFolder "$($InstanceState.name)\custom_nodes"
    $nodes = @()
    if (Test-Path $nodesDir) {
        $nodes = @(Get-ChildItem $nodesDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }
    Write-Host ("    {0,-12} {1}" -f 'Nodes', $nodes.Count) -ForegroundColor Gray
}

function Invoke-RocmRollInstanceInfoCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.State','RocmRoll.ComfyPatch')
    $cfg = Get-Config
    $state = Get-InstanceState -Name $Context.InstanceName

    Write-Host ''
    Write-Host "  ROCmRoll Instance: $($Context.InstanceName)" -ForegroundColor Cyan
    if ($state) {
        Write-Host ("  {0,-12} {1}" -f 'Status', $state.status) -ForegroundColor White
        Write-Host ("  {0,-12} {1}" -f 'Channel', $state.channel) -ForegroundColor White
        if ($state.PSObject.Properties['path']) {
            Write-Host ("  {0,-12} {1}" -f 'Path', $state.path) -ForegroundColor Gray
        }
    } else {
        Write-Host '  No instance state found.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    $scopes = @(Get-RocmRollInstanceComponentScopes -Context $Context)
    if ($scopes -contains 'environment') { Show-RocmRollInstanceEnvironmentInfo -InstanceState $state }
    if ($scopes -contains 'rocm') { Show-RocmRollInstanceRocmInfo -InstanceState $state }
    if ($scopes -contains 'comfyui') { Show-RocmRollInstanceComfyUiInfo -InstanceState $state -Config $cfg }
    if ($scopes -contains 'patches') {
        Write-Host ''
        Show-ComfyPatchList -InstanceName $Context.InstanceName
    }
    Write-Host ''
}

function Show-RocmRollInstanceList {
    param(
        [object[]]$Instances,
        [string]$Label = '',
        [string]$Channel = ''
    )

    if ($Label) {
        Write-Host ''
        Write-Host "  $Label" -ForegroundColor Cyan
    }

    $filtered = @($Instances)
    if ($Channel) {
        $filtered = @($filtered | Where-Object { $_.Channel -eq $Channel })
    }

    if ($filtered.Count -eq 0) {
        Write-Host '  No instances found.' -ForegroundColor Yellow
        return
    }

    foreach ($inst in $filtered) {
        Write-Host ("  {0,-30} channel={1,-10} status={2}" -f $inst.Name, $inst.Channel, $inst.Status)
    }
}

function Invoke-RocmRollInstanceListCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Instance','RocmRoll.Workspace','RocmRoll.Config')
    $initializeConfig = Get-Command -Name Initialize-Config -Module RocmRoll.Config -ErrorAction Stop
    $getConfig = Get-Command -Name Get-Config -Module RocmRoll.Config -ErrorAction Stop

    if ($Context.FlagAll) {
        & $initializeConfig -RootFolder $Context.RootFolder -IgnoreActiveWorkspace | Out-Null
        $baseCfg = & $getConfig
        Show-RocmRollInstanceList -Instances @(Get-InstalledInstanceList -Config $baseCfg) -Label 'Default workspace' -Channel $Context.Channel

        $workspaces = @(Get-WorkspaceList -Config $baseCfg)
        foreach ($ws in $workspaces) {
            & $initializeConfig -RootFolder $Context.RootFolder -WorkspaceName $ws.Name | Out-Null
            $cfg = & $getConfig
            Show-RocmRollInstanceList -Instances @(Get-InstalledInstanceList -Config $cfg) -Label "Workspace: $($ws.Name)" -Channel $Context.Channel
        }

        & $initializeConfig -RootFolder $Context.RootFolder | Out-Null
        return
    }

    $cfg = Get-Config
    Show-RocmRollInstanceList -Instances @(Get-InstalledInstanceList -Config $cfg) -Channel $Context.Channel
}

function Invoke-RocmRollInstanceRemoveCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Instance')

    if ($Context.ComponentScopes -contains 'all') {
        Remove-RocmRollInstance -InstanceName $Context.InstanceName `
            -PythonVersion $Context.PythonVersion -Force:$Context.FlagForce -Config (Get-Config)
        return
    }

    Remove-RocmRollInstanceComponents -InstanceName $Context.InstanceName `
        -Components @(Get-RocmRollInstanceComponentScopes -Context $Context) `
        -PythonVersion $Context.PythonVersion -Force:$Context.FlagForce -Config (Get-Config)
}

function Invoke-RocmRollInstanceLaunchCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.State','RocmRoll.Launcher','RocmRoll.Logging')
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
            Write-Host '  Run: rocmroll instance install --name NAME' -ForegroundColor DarkGray
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

    $launchExtra = @()
    if ($Context.Url) { $launchExtra += @('--listen', $Context.Url) }
    if ($Context.PortArg) { $launchExtra += @('--port', $Context.PortArg) }
    $exitCode = Invoke-LaunchInstance -InstanceName $instanceName `
        -ProfileOverride $Context.ProfileName -ExtraArgs $launchExtra
    exit $exitCode
}

function Invoke-RocmRollRocmCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.State','RocmRoll.Rocm')
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
                Write-Host '  No environment state found. Run rocmroll instance install first.' -ForegroundColor Yellow
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
                if (-not $result.passed -and $result.error) {
                    Write-Host "  error  : $($result.error)" -ForegroundColor Red
                }
                Write-Host ''
            }
        }
        default { Show-RocmRollHelp -Command 'rocm' }
    }
}

function Get-RocmRollGitDirtyFiles {
    param([Parameter(Mandatory)][string]$RepositoryPath)
    $dirty = @(& git -c "safe.directory=$RepositoryPath" -c core.excludesfile= -C $RepositoryPath status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "ROCMROLL-GIT-011: git status failed for '$RepositoryPath'"
    }
    return @($dirty | ForEach-Object {
        $line = [string]$_
        if ($line.Length -ge 4) { $line.Substring(3) -replace '\\', '/' }
    } | Where-Object { $_ })
}

function Get-RocmRollComfyPatchTargetFiles {
    $files = @()
    foreach ($patch in @(Get-ComfyPatchList)) {
        $patchFiles = if ($patch -and $patch.PSObject.Properties['files']) { @($patch.files) } else { @() }
        foreach ($fileSpec in $patchFiles) {
            if ($fileSpec -and $fileSpec.PSObject.Properties['path'] -and $fileSpec.path) {
                $files += ([string]$fileSpec.path -replace '\\', '/')
            }
        }
    }
    return @($files | Sort-Object -Unique)
}

function Restore-RocmRollGitFiles {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Paths
    )

    if ($Paths.Count -eq 0) { return }
    $gitArguments = (Get-SafeGitRepositoryArguments -RepositoryPath $RepositoryPath -Arguments @('checkout', '--')) + $Paths
    $exitCode = Invoke-LoggedNativeCommand -FilePath 'git' -Arguments $gitArguments -Comp 'RocmRoll.Commands' -Op 'GitRestore'
    if ($exitCode -ne 0) {
        throw "ROCMROLL-GIT-012: git checkout failed while restoring managed patch files (exit $exitCode)"
    }
}

function Invoke-RocmRollComfyUiCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.State','RocmRoll.ComfyUI','RocmRoll.ModelPaths','RocmRoll.CustomNodes',
        'RocmRoll.ComfyPatch','RocmRoll.Utilities','RocmRoll.Logging'
    )
    $cfg = Get-Config
    $instState = Get-InstanceState -Name $Context.InstanceName
    $envName = if ($instState -and $instState.environment) {
        $instState.environment
    } else {
        "$($Context.InstanceName)-py$($Context.PythonVersion.Replace('.','').Substring(0,3))"
    }

    $subCommand = if ($Context.SubCommand) {
        $Context.SubCommand
    } elseif ($Context.InstanceName) {
        'info'
    } else {
        ''
    }

    switch ($subCommand) {
        'info' {
            Show-RocmRollInstanceComfyUiInfo -InstanceState $instState -Config $cfg
            Write-Host ''
        }
        'requirements' { Invoke-InstallComfyDeps -InstanceName $Context.InstanceName -EnvironmentName $envName }
        'nodes' {
            $actions = @()
            if ($Context.FlagInstall) { $actions += 'install' }
            if ($Context.FlagList) { $actions += 'list' }
            if ($Context.FlagUpdate) { $actions += 'update' }
            if ($Context.AddUrl) { $actions += 'add' }
            if ($actions.Count -gt 1) {
                Write-Host ''
                Write-Host '  ERROR  Choose only one of --list, --install, --update, or --add URL.' -ForegroundColor Red
                Write-Host ''
                exit 1
            }

            $action = if ($actions.Count -eq 0) { 'list' } else { $actions[0] }
            switch ($action) {
                'install' { Invoke-InstallCustomNodes -InstanceName $Context.InstanceName -EnvironmentName $envName }
                'update'  { Invoke-InstallCustomNodes -InstanceName $Context.InstanceName -EnvironmentName $envName -Update }
                'add'     { Invoke-InstallNodeFromUrl -Url $Context.AddUrl -InstanceName $Context.InstanceName -EnvironmentName $envName }
                default {
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
            }
        }
        'update' {
            if (-not $instState) {
                Write-Host ''
                Write-Host "  ERROR  Instance '$($Context.InstanceName)' state not found." -ForegroundColor Red
                Write-Host ''
                exit 1
            }

            $channel = if ($instState.PSObject.Properties['channel'] -and $instState.channel) { [string]$instState.channel } else { 'stable' }
            $channelFile = Join-Path $cfg.ManifestsFolder 'channels.json'
            $channelManifest = Get-Content $channelFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $channelCfg = $channelManifest.$channel
            if (-not $channelCfg) { throw "Unknown channel '$channel'" }
            $comfyCfg = $channelCfg.comfyui
            $repo = if ($comfyCfg -and $comfyCfg.PSObject.Properties['repo'] -and $comfyCfg.repo) { [string]$comfyCfg.repo } else { 'https://github.com/Comfy-Org/ComfyUI.git' }
            $ref = if ($comfyCfg -and $comfyCfg.PSObject.Properties['ref'] -and $comfyCfg.ref) { [string]$comfyCfg.ref } else { 'master' }

            $patchState = Get-ComfyPatchState -InstanceName $Context.InstanceName
            $appliedPatches = @(Get-ComfyPatchStateEntries -State $patchState)
            if ($appliedPatches.Count -gt 0) {
                Write-Host ''
                Write-Host "  Removing managed ComfyUI patches before source update..." -ForegroundColor Yellow
                [array]::Reverse($appliedPatches)
                foreach ($patch in $appliedPatches) {
                    $patchId = Get-ComfyPatchEntryId -Entry $patch
                    if ($patchId) {
                        Invoke-RemoveComfyPatch -PatchId $patchId -InstanceName $Context.InstanceName
                    }
                }
            }

            $instanceFolder = if ($instState.PSObject.Properties['path'] -and $instState.path) {
                [string]$instState.path
            } else {
                Join-Path $cfg.InstancesFolder $Context.InstanceName
            }
            $dirtyFiles = @(Get-RocmRollGitDirtyFiles -RepositoryPath $instanceFolder)
            if ($dirtyFiles.Count -gt 0) {
                $managedPatchFiles = @(Get-RocmRollComfyPatchTargetFiles)
                $unmanagedDirty = @($dirtyFiles | Where-Object { $managedPatchFiles -notcontains $_ })
                if ($unmanagedDirty.Count -gt 0) {
                    Write-Host ''
                    Write-Host '  ERROR  ComfyUI checkout has local changes outside managed patch files:' -ForegroundColor Red
                    foreach ($file in $unmanagedDirty) { Write-Host "    $file" -ForegroundColor Gray }
                    Write-Host ''
                    Write-Host '  Commit, stash, or remove those changes before updating.' -ForegroundColor DarkGray
                    Write-Host ''
                    exit 1
                }

                Write-Host ''
                Write-Host '  ComfyUI checkout has leftover managed patch changes:' -ForegroundColor Yellow
                foreach ($file in $dirtyFiles) { Write-Host "    $file" -ForegroundColor Gray }
                $restore = Read-Host '  Restore these files from Git and continue? [y/N]'
                if ($restore -notmatch '^[yY]') {
                    Write-Host '  Update cancelled.' -ForegroundColor Yellow
                    Write-Host ''
                    exit 1
                }
                Restore-RocmRollGitFiles -RepositoryPath $instanceFolder -Paths $dirtyFiles
            }

            $updateResult = Invoke-UpdateComfyUIInstance -InstanceName $Context.InstanceName -Repo $repo -Ref $ref
            Invoke-InstallComfyDeps -InstanceName $Context.InstanceName -EnvironmentName $envName
            Invoke-ApplyExtraModelPaths -InstanceName $Context.InstanceName -Mode 'Update' | Out-Null

            $stateFile = Get-StateFilePath -Type 'instance' -Name $Context.InstanceName
            $stateHash = ConvertTo-StateHashtable -InputObject $instState
            $stateHash['comfyui'] = @{
                repo   = $repo
                ref    = $ref
                commit = [string]$updateResult.commit
            }
            $stateHash['updatedAt'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            Write-StateFile -Path $stateFile -State $stateHash

            Write-Host ''
            $applyPatches = Read-Host '  Apply ComfyUI patches after update? [Y/n]'
            if ($applyPatches -notmatch '^[nN]') {
                $envState = Get-EnvironmentState -Name $envName
                $gfx = ''
                if ($envState -and $envState.PSObject.Properties['gpu'] -and $envState.gpu -and $envState.gpu.PSObject.Properties['gfx']) {
                    $gfx = [string]$envState.gpu.gfx
                }
                Invoke-ApplyAllComfyPatches -InstanceName $Context.InstanceName -GfxOverride $gfx
            } else {
                Write-Host '  Skipped ComfyUI patches.' -ForegroundColor Yellow
            }
        }
        default { Show-RocmRollHelp -Command 'comfyui' }
    }
}

function Invoke-RocmRollCacheCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Cache')
    $sub = $Context.SubCommand
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
            if ($Context.FlagAll) {
                Remove-AllCache | Out-Null
            } else {
                if ($Context.ParsedOptions.Flags.ContainsKey('temp')) { Remove-TempFolder }
                Remove-PartialDownloads | Out-Null
            }
        }
        'prune' {
            $days = if ($Context.OlderThanDays) { [int]$Context.OlderThanDays } else { 30 }
            Remove-OldCacheFiles -OlderThanDays $days | Out-Null
        }
        default { Show-RocmRollHelp -Command 'cache' }
    }
}

function Invoke-RocmRollLogsCommand {
    param([Parameter(Mandatory)][object]$Context)
    $cfg = Get-Config
    switch ($Context.SubCommand) {
        'show' {
            $logs = @(Get-ChildItem $cfg.LogsFolder -Recurse -File -Include '*.log','*.jsonl' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 20)
            Write-Host ''
            Write-Host '  Recent ROCmRoll Logs' -ForegroundColor Cyan
            Write-Host ''
            if ($logs.Count -eq 0) {
                Write-Host '  No logs found.' -ForegroundColor Gray
            } else {
                $logs | ForEach-Object { Write-Host "  $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $($_.FullName)" }
            }
            Write-Host ''
        }
        'prune' {
            $cutoff = (Get-Date).AddDays(-30)
            $logs = @(Get-ChildItem $cfg.LogsFolder -Recurse -File -Include '*.log','*.jsonl' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
            foreach ($log in $logs) {
                Remove-Item -LiteralPath $log.FullName -Force
            }
            Write-Host ''
            Write-Host "  Pruned $($logs.Count) log file(s) older than 30 days." -ForegroundColor Green
            Write-Host ''
        }
        default { Show-RocmRollHelp -Command 'logs' }
    }
}

function Invoke-RocmRollStateCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.State')
    $cfg = Get-Config
    $global = Get-GlobalState
    $runtimeFiles = @(Get-ChildItem $cfg.RuntimeStateFolder -Filter 'runtime-*.json' -ErrorAction SilentlyContinue)
    $envFiles = @(Get-ChildItem $cfg.EnvStateFolder -Filter 'environment-*.json' -ErrorAction SilentlyContinue)
    $instanceFiles = @(Get-ChildItem $cfg.InstanceStateFolder -Filter 'instance-*.json' -ErrorAction SilentlyContinue)

    Write-Host ''
    Write-Host '  ROCmRoll State Summary' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("  {0,-14} {1}" -f 'Global', $(if ($global) { 'present' } else { 'not found' })) -ForegroundColor Gray
    Write-Host ("  {0,-14} {1}" -f 'Runtimes', $runtimeFiles.Count) -ForegroundColor Gray
    Write-Host ("  {0,-14} {1}" -f 'Environments', $envFiles.Count) -ForegroundColor Gray
    Write-Host ("  {0,-14} {1}" -f 'Instances', $instanceFiles.Count) -ForegroundColor Gray
    Write-Host ''
    Write-Host ("  {0,-14} {1}" -f 'State folder', $cfg.StateFolder) -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-RocmRollConfigCommand {
    param([Parameter(Mandatory)][object]$Context)
    $sub = $Context.SubCommand
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
        default { Show-RocmRollHelp -Command 'config' }
    }
}

function Show-RocmRollEnvironmentDetail {
    param(
        [Parameter(Mandatory)][object]$State,
        [string]$Name = ''
    )

    $envName = if ($State.PSObject.Properties['name'] -and $State.name) { [string]$State.name } else { $Name }
    Write-Host ("    {0,-24} status={1,-10} runtime={2}" -f $envName, $State.status, $State.runtimeVersion) -ForegroundColor Gray
    if ($State.PSObject.Properties['path'] -and $State.path) {
        Write-Host ("      {0}" -f $State.path) -ForegroundColor DarkGray
    }
}

function Invoke-RocmRollEnvCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.Environment','RocmRoll.Runtime','RocmRoll.State','RocmRoll.Utilities'
    )
    $cfg = Get-Config
    $sub = if ($Context.SubCommand) { $Context.SubCommand } else { 'list' }

    switch ($sub) {
        'list' {
            Write-Host ''
            Write-Host '  ROCmRoll Environments' -ForegroundColor Cyan
            Write-Host ''

            if ($Context.EnvName) {
                $state = Get-EnvironmentState -Name $Context.EnvName
                if ($state) {
                    Show-RocmRollEnvironmentDetail -State $state -Name $Context.EnvName
                } else {
                    Write-Host "  Environment '$($Context.EnvName)' not found." -ForegroundColor Yellow
                }
                Write-Host ''
                return
            }

            $files = @(Get-ChildItem $cfg.EnvStateFolder -Filter 'environment-*.json' -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) {
                Write-Host '  No environments found.' -ForegroundColor Gray
            } else {
                foreach ($file in $files) {
                    $state = Read-StateFile -Path $file.FullName
                    if ($state) {
                        $fallbackName = $file.BaseName -replace '^environment-', ''
                        Show-RocmRollEnvironmentDetail -State $state -Name $fallbackName
                    }
                }
            }
            Write-Host ''
        }
        'create' {
            Invoke-CreatePythonRuntime -Version $Context.PythonVersion | Out-Null
            Invoke-CreateEnvironment -Name $Context.EnvName | Out-Null
        }
        'edit' {
            $state = Get-EnvironmentState -Name $Context.EnvName
            if (-not $state) {
                Write-Host ''
                Write-Host "  ERROR  Environment '$($Context.EnvName)' state not found." -ForegroundColor Red
                Write-Host ''
                exit 1
            }

            $ok = Test-EnvironmentIntegrity -Name $Context.EnvName
            $status = if ($ok) { 'ready' } else { 'broken' }
            $path = if ($state.PSObject.Properties['path'] -and $state.path) { [string]$state.path } else { Join-Path $cfg.EnvironmentsFolder $Context.EnvName }
            $runtime = if ($state.PSObject.Properties['runtimeVersion'] -and $state.runtimeVersion) { [string]$state.runtimeVersion } else { $Context.PythonVersion }
            Set-EnvironmentState -Name $Context.EnvName -Path $path -RuntimeVersion $runtime -Status $status

            $bound = $false
            foreach ($file in @(Get-ChildItem $cfg.InstanceStateFolder -Filter 'instance-*.json' -ErrorAction SilentlyContinue)) {
                $inst = Read-StateFile -Path $file.FullName
                if ($inst -and $inst.PSObject.Properties['environment'] -and $inst.environment -eq $Context.EnvName) {
                    try {
                        Set-EnvironmentInstancePath -EnvironmentName $Context.EnvName -InstanceName $inst.name
                        $bound = $true
                    } catch {
                        Write-LogWarn "Could not rebind environment '$($Context.EnvName)' to instance '$($inst.name)': $($_.Exception.Message)" -Comp 'RocmRoll.Env'
                    }
                }
            }

            Write-Host ''
            Write-Host "  Environment '$($Context.EnvName)' validated as $status." -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
            if ($bound) { Write-Host '  Instance path bindings refreshed.' -ForegroundColor Green }
            Write-Host ''
        }
        'remove' {
            $state = Get-EnvironmentState -Name $Context.EnvName
            $envFolder = if ($state -and $state.PSObject.Properties['path'] -and $state.path) {
                [string]$state.path
            } else {
                Join-Path $cfg.EnvironmentsFolder $Context.EnvName
            }
            $stateFile = Join-Path $cfg.EnvStateFolder "environment-$($Context.EnvName).json"

            Write-Host ''
            Write-Host "  Remove environment '$($Context.EnvName)'?" -ForegroundColor Yellow
            Write-Host "  Folder: $envFolder" -ForegroundColor DarkGray
            $confirm = Read-Host '  Type YES to continue'
            if ($confirm -cne 'YES') {
                Write-Host '  Aborted.' -ForegroundColor Yellow
                Write-Host ''
                exit 1
            }

            Remove-FolderTree -Path $envFolder -ParentFolder $cfg.EnvironmentsFolder -Description 'environment'
            if (Test-Path $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
            Write-Host ''
            Write-Host "  Environment '$($Context.EnvName)' removed." -ForegroundColor Green
            Write-Host ''
        }
        default { Show-RocmRollHelp -Command 'env' }
    }
}

function Invoke-RocmRollProfileCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @(
        'RocmRoll.Profiles','RocmRoll.State','RocmRoll.Launcher','RocmRoll.ComfyDesktop'
    )
    $cfg = Get-Config
    switch ($Context.SubCommand) {
        'list' {
            $all = @(Get-ProfileList -Config $cfg)
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
        'apply' {
            $state = Get-InstanceState -Name $Context.InstanceName
            if (-not $state) {
                Write-Host ''
                Write-Host "  ERROR  Instance '$($Context.InstanceName)' state not found." -ForegroundColor Red
                Write-Host ''
                exit 1
            }

            $channel = if ($state.PSObject.Properties['channel'] -and $state.channel) { [string]$state.channel } else { 'stable' }
            $environment = if ($state.PSObject.Properties['environment'] -and $state.environment) { [string]$state.environment } else { '' }
            if (-not $environment) {
                Write-Host ''
                Write-Host "  ERROR  Instance '$($Context.InstanceName)' has no environment binding." -ForegroundColor Red
                Write-Host ''
                exit 1
            }

            $envState = Get-EnvironmentState -Name $environment
            $gfx = ''
            if ($envState -and $envState.PSObject.Properties['gpu'] -and $envState.gpu -and $envState.gpu.PSObject.Properties['gfx']) {
                $gfx = [string]$envState.gpu.gfx
            }

            $profileName = if ($Context.ProfileName) {
                try {
                    Get-ProfilePath -Name $Context.ProfileName -Config $cfg | Out-Null
                } catch {
                    Write-Host ''
                    Write-Host "  ERROR  Unknown profile: '$($Context.ProfileName)'" -ForegroundColor Red
                    Write-Host "  Run 'rocmroll profile list' to see available profiles." -ForegroundColor DarkGray
                    Write-Host ''
                    exit 1
                }
                $Context.ProfileName
            } else {
                Resolve-ChannelDefaultProfile -Channel $channel -Config $cfg
            }

            $profileObj = Get-ProfileObject -Name $profileName -Config $cfg

            Invoke-GenerateLaunchers -InstanceName $Context.InstanceName -EnvironmentName $environment `
                -GfxVersion $gfx -ProfileName $profileName -Channel $channel

            $existingDesktopId = if ($state.PSObject.Properties['comfyDesktopId'] -and $state.comfyDesktopId) { [string]$state.comfyDesktopId } else { '' }
            $desktopId = Register-ComfyDesktopInstance -InstanceName $Context.InstanceName `
                -InstanceState $state -EnvironmentState $envState `
                -GfxFamily $gfx -ExistingId $existingDesktopId -ProfileObject $profileObj
            if ($desktopId) {
                Set-InstanceComfyDesktopId -Name $Context.InstanceName -ComfyDesktopId $desktopId
            }

            Write-Host ''
            Write-Host "  Applied profile '$profileName' to instance '$($Context.InstanceName)'." -ForegroundColor Green
            Write-Host ''
        }
        'show' {
            $obj = Get-ProfileObject -Name $Context.ProfileName -Config $cfg
            Write-Host ''
            Write-Host '  ROCmRoll Profile Detail' -ForegroundColor Cyan
            $obj | Show-ProfileDetail
            Write-Host ''
        }
        'create' { New-ProfileInteractive -Name $Context.ProfileName -Config $cfg }
        'remove' { Remove-Profile -Name $Context.ProfileName -Config $cfg }
        default { Show-RocmRollHelp -Command 'profile' }
    }
}

function Invoke-RocmRollPatchCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.ComfyPatch')
    switch ($Context.SubCommand) {
        'list' { Show-ComfyPatchList -InstanceName $Context.InstanceName }
        'apply' {
            if ($Context.PatchId) {
                Invoke-ApplyComfyPatch -PatchId $Context.PatchId -InstanceName $Context.InstanceName -GfxOverride $Context.GfxOverride
            } else {
                Invoke-ApplyAllComfyPatches -InstanceName $Context.InstanceName -GfxOverride $Context.GfxOverride
            }
        }
        'remove' { Invoke-RemoveComfyPatch -PatchId $Context.PatchId -InstanceName $Context.InstanceName }
        default { Show-RocmRollHelp -Command 'patch' }
    }
}

function Invoke-RocmRollWorkspaceCommand {
    param([Parameter(Mandatory)][object]$Context)
    Import-RocmRollCommandModules -ModulesDir $Context.ModulesDir -Names @('RocmRoll.Workspace')
    $cfg = Get-Config
    $subCmd = $Context.SubCommand
    $workspaceName = $Context.WorkspaceTargetName

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
                Write-Host "  Run 'rocmroll workspace create --name NAME' to create one." -ForegroundColor DarkGray
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
                    Write-Host '  No workspaces found. Run: rocmroll workspace create --name NAME' -ForegroundColor Yellow
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
        default { Show-RocmRollHelp -Command 'workspace' }
    }
}

function Invoke-RocmRollHelpCommand {
    param([Parameter(Mandatory)][object]$Context)
    Show-RocmRollHelp -Command $Context.HelpTarget
}

Export-ModuleMember -Function Invoke-RocmRollInitCommand, Invoke-RocmRollInstanceCommand,
    Invoke-RocmRollDoctorCommand, Invoke-RocmRollRocmCommand, Invoke-RocmRollComfyUiCommand,
    Invoke-RocmRollCacheCommand, Invoke-RocmRollEnvCommand, Invoke-RocmRollStateCommand,
    Invoke-RocmRollLogsCommand, Invoke-RocmRollConfigCommand,
    Invoke-RocmRollProfileCommand, Invoke-RocmRollPatchCommand, Invoke-RocmRollWorkspaceCommand,
    Invoke-RocmRollHelpCommand,
    Invoke-RocmRollPlanCommand, Invoke-RocmRollApplyCommand, Invoke-RocmRollDestroyCommand, Invoke-RocmRollImportCommand
