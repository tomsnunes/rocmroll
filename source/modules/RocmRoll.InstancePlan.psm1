#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.InstancePlan - Plan/apply/destroy engine for declarative instance
    definitions.

.DESCRIPTION
    Compares a ComfyUIInstance definition (RocmRoll.InstanceDefinition)
    against recorded ROCmRoll state and the actual filesystem, produces a
    classified list of actions (NOOP/CREATE/UPDATE/REPAIR/REPLACE/DELETE/
    PRESERVE/WARNING/DESTRUCTIVE), and can apply that plan.

    Apply is capable of performing every action a full 'instance install' or
    'instance update' can: for anything beyond the lightweight extra_model_paths.yaml
    and launcher reconciliation it delegates to RocmRoll.Core.Invoke-FullInstall,
    the same function those imperative commands already use, so the
    declarative workflow (plan/apply/destroy) reuses the imperative subset
    under the hood rather than reimplementing it. Destroy similarly delegates
    to RocmRoll.Instance.Remove-RocmRollInstance, the function 'instance
    remove --all' already uses.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Utilities.psm1')

function New-InstancePlanAction {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]
        [ValidateSet('NOOP', 'CREATE', 'UPDATE', 'REPAIR', 'REPLACE', 'DELETE', 'PRESERVE', 'WARNING', 'DESTRUCTIVE')]
        [string]$Type,
        [string]$Target = '',
        [string]$Reason = '',
        [object]$Destructive = $null
    )

    $isDestructive = if ($null -ne $Destructive) { [bool]$Destructive } else { $Type -in @('REPLACE', 'DELETE', 'DESTRUCTIVE') }

    return [pscustomobject]@{
        Id          = $Id
        Type        = $Type
        Target      = $Target
        Reason      = $Reason
        Destructive = $isDestructive
    }
}

function Get-InstancePlanDeclaredNodeNames {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][object]$Definition
    )

    $names = New-Object System.Collections.Generic.List[string]

    $manifestPath = Join-Path $Config.ManifestsFolder 'custom-nodes.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($node in @($manifest.default)) {
            if ($node -and $node.PSObject.Properties['name'] -and $node.name) { $names.Add([string]$node.name) | Out-Null }
        }
    }

    $overlayNodesPath = Join-Path (Join-Path (Join-Path $Config.OverlaysFolder $Definition.Name) 'instance') 'custom_nodes.json'
    if (Test-Path -LiteralPath $overlayNodesPath) {
        $overlay = Get-Content -LiteralPath $overlayNodesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($node in @($overlay.default)) {
            if ($node -and $node.PSObject.Properties['name'] -and $node.name) { $names.Add([string]$node.name) | Out-Null }
        }
    }

    return @($names)
}

function Get-InstancePlan {
    <#
    .SYNOPSIS
        Builds a classified action list comparing a definition's declared
        state against ROCmRoll-recorded state and the filesystem.
    #>
    param([Parameter(Mandatory)][object]$Definition)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ModelPaths.psm1') -Force -Global

    $cfg     = Get-Config
    $name    = $Definition.Name
    $state   = Get-InstanceState -Name $name
    $actions = New-Object System.Collections.Generic.List[object]

    # -- extra_model_paths.yaml ----------------------------------------------
    $mpStatus = Get-ExtraModelPathsStatus -InstanceName $name
    $mpPath   = $mpStatus.InstancePath
    if ($mpStatus.Status -eq 'missing') {
        $actions.Add((New-InstancePlanAction -Id 'modelPaths.extra_model_paths' -Type 'CREATE' -Target $mpPath `
            -Reason 'extra_model_paths.yaml does not exist yet.')) | Out-Null
    } elseif ($Definition.ModelPaths.PreserveOnUpdate) {
        $actions.Add((New-InstancePlanAction -Id 'modelPaths.extra_model_paths' -Type 'PRESERVE' -Target $mpPath `
            -Reason 'Existing file will be preserved during update.')) | Out-Null
    } else {
        switch ($mpStatus.Status) {
            'managed' {
                $actions.Add((New-InstancePlanAction -Id 'modelPaths.extra_model_paths' -Type 'NOOP' -Target $mpPath `
                    -Reason 'extra_model_paths.yaml already matches the managed source.')) | Out-Null
            }
            'source-changed' {
                $actions.Add((New-InstancePlanAction -Id 'modelPaths.extra_model_paths' -Type 'UPDATE' -Target $mpPath `
                    -Reason 'The overlay/template source changed since ROCmRoll last applied this file.')) | Out-Null
            }
            default {
                $actions.Add((New-InstancePlanAction -Id 'modelPaths.extra_model_paths' -Type 'WARNING' -Target $mpPath `
                    -Reason "extra_model_paths.yaml is $($mpStatus.Status); replacing it requires approval (instance repair --force, or apply --allow-destructive)." `
                    -Destructive $true)) | Out-Null
            }
        }
    }

    # -- ComfyUI source ref/commit --------------------------------------------
    $instancePath = if ($state -and $state.PSObject.Properties['path'] -and $state.path) { [string]$state.path } else { Join-Path $cfg.InstancesFolder $name }
    $currentRef = if ($state -and $state.PSObject.Properties['comfyui'] -and $state.comfyui -and $state.comfyui.PSObject.Properties['ref']) { [string]$state.comfyui.ref } else { '' }
    # Check for the .git marker, not bare folder existence: the instance
    # folder can already exist (e.g. holding a generated extra_model_paths.yaml)
    # without a real ComfyUI checkout inside it.
    $isGitCheckout = Test-Path -LiteralPath (Join-Path $instancePath '.git')
    if (-not $state -or -not $isGitCheckout) {
        $actions.Add((New-InstancePlanAction -Id 'comfyui.source' -Type 'CREATE' -Target $instancePath `
            -Reason 'ComfyUI checkout does not exist yet.')) | Out-Null
    } elseif ($currentRef -and $currentRef -ne $Definition.ComfyUI.Ref) {
        $actions.Add((New-InstancePlanAction -Id 'comfyui.source' -Type 'UPDATE' -Target $instancePath `
            -Reason "Current ref: $currentRef`nDesired ref: $($Definition.ComfyUI.Ref)")) | Out-Null
    } else {
        $actions.Add((New-InstancePlanAction -Id 'comfyui.source' -Type 'NOOP' -Target $instancePath `
            -Reason "ComfyUI source already at desired ref ($($Definition.ComfyUI.Ref)).")) | Out-Null
    }

    # -- Channel ------------------------------------------------------------------
    # Only compared when state already records a channel (an existing
    # instance); a brand-new instance is fully covered by the environment/
    # comfyui.source CREATE actions below, which already converge on the
    # declared channel via the install pipeline.
    $currentChannel = if ($state -and $state.PSObject.Properties['channel'] -and $state.channel) { [string]$state.channel } else { '' }
    if ($currentChannel -and $currentChannel -ne $Definition.Channel) {
        $actions.Add((New-InstancePlanAction -Id 'channel' -Type 'UPDATE' -Target $name `
            -Reason "Current channel: $currentChannel`nDesired channel: $($Definition.Channel)")) | Out-Null
    }

    # -- Python environment / runtime --------------------------------------------
    $envName  = if ($state -and $state.PSObject.Properties['environment'] -and $state.environment) { [string]$state.environment } else { '' }
    $envState = if ($envName) { Get-EnvironmentState -Name $envName } else { $null }
    $envPath  = if ($envState -and $envState.PSObject.Properties['path'] -and $envState.path) { [string]$envState.path } else { '' }
    if (-not $envState -or -not $envPath -or -not (Test-Path -LiteralPath $envPath)) {
        $actions.Add((New-InstancePlanAction -Id 'environment' -Type 'CREATE' -Target $envName `
            -Reason 'Python environment/runtime not found for this instance.')) | Out-Null
    } else {
        $actions.Add((New-InstancePlanAction -Id 'environment' -Type 'NOOP' -Target $envPath -Reason 'Python environment present.')) | Out-Null

        # Only compared when the environment already exists - if it doesn't,
        # the CREATE action above already covers converging on the declared
        # pythonVersion via the install pipeline.
        $currentPythonVersion = if ($envState.PSObject.Properties['runtimeVersion'] -and $envState.runtimeVersion) { [string]$envState.runtimeVersion } else { '' }
        if ($currentPythonVersion -and $currentPythonVersion -ne $Definition.PythonVersion) {
            $actions.Add((New-InstancePlanAction -Id 'pythonVersion' -Type 'UPDATE' -Target $envName `
                -Reason "Current Python version: $currentPythonVersion`nDesired Python version: $($Definition.PythonVersion)")) | Out-Null
        }
    }

    # -- Launcher -----------------------------------------------------------------
    $launcherPath = Join-Path $cfg.LaunchersFolder "$name.ps1"
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        $actions.Add((New-InstancePlanAction -Id 'launcher' -Type 'CREATE' -Target $launcherPath -Reason 'Launcher not found.')) | Out-Null
    } else {
        $actions.Add((New-InstancePlanAction -Id 'launcher' -Type 'NOOP' -Target $launcherPath -Reason 'Launcher present.')) | Out-Null
    }

    # -- Custom nodes: unmanaged node detection ------------------------------------
    $nodesDir = Join-Path $instancePath 'custom_nodes'
    if (Test-Path -LiteralPath $nodesDir) {
        $declaredNames = @(Get-InstancePlanDeclaredNodeNames -Config $cfg -Definition $Definition)
        $installedDirs = @(Get-ChildItem -LiteralPath $nodesDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $unmanaged = @($installedDirs | Where-Object { $declaredNames -notcontains $_ })
        if ($unmanaged.Count -gt 0) {
            $actions.Add((New-InstancePlanAction -Id 'customNodes.unmanaged' -Type 'WARNING' -Target $nodesDir `
                -Reason "custom_nodes folder contains unmanaged node(s): $($unmanaged -join ', '). pruneUnmanaged=$($Definition.CustomNodes.PruneUnmanaged) - not modified by apply.")) | Out-Null
        }
    }

    # -- Declared shared path vs resolved workspace path ---------------------------
    if ($Definition.Paths.shared) {
        $declaredShared = ($Definition.Paths.shared -replace '/', '\').TrimEnd('\')
        $resolvedShared = $cfg.SharedFolder.TrimEnd('\')
        if ($declaredShared -and -not $resolvedShared.EndsWith($declaredShared, [System.StringComparison]::OrdinalIgnoreCase)) {
            $actions.Add((New-InstancePlanAction -Id 'paths.shared' -Type 'WARNING' -Target $resolvedShared `
                -Reason "Declared spec.paths.shared ('$($Definition.Paths.shared)') differs from the resolved workspace shared path ('$resolvedShared'). ROCmRoll paths are workspace-level, not managed per-instance by apply.")) | Out-Null
        }
    }

    # .ToArray(), not @($actions) - @() on a non-empty List[object] here throws on some PS 5.1 builds.
    return [pscustomobject]@{
        ApiVersion = 'rocmroll.dev/v1'
        Kind       = 'InstancePlan'
        Instance   = $name
        CreatedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        Actions    = $actions.ToArray()
    }
}

function Get-InstancePlanSummary {
    param([Parameter(Mandatory)][object]$Plan)

    $summary = [ordered]@{
        create      = 0
        update      = 0
        repair      = 0
        replace     = 0
        delete      = 0
        preserve    = 0
        warnings    = 0
        destructive = 0
    }
    foreach ($action in $Plan.Actions) {
        switch ($action.Type) {
            'CREATE'   { $summary['create']++ }
            'UPDATE'   { $summary['update']++ }
            'REPAIR'   { $summary['repair']++ }
            'REPLACE'  { $summary['replace']++ }
            'DELETE'   { $summary['delete']++ }
            'PRESERVE' { $summary['preserve']++ }
            'WARNING'  { $summary['warnings']++ }
        }
        if ($action.Destructive) { $summary['destructive']++ }
    }
    return $summary
}

function Format-InstancePlanText {
    param([Parameter(Mandatory)][object]$Plan)

    $colorByType = @{
        NOOP        = 'DarkGray'
        CREATE      = 'Cyan'
        UPDATE      = 'Cyan'
        REPAIR      = 'Cyan'
        REPLACE     = 'Red'
        DELETE      = 'Red'
        PRESERVE    = 'Green'
        WARNING     = 'Yellow'
        DESTRUCTIVE = 'Red'
    }

    Write-Host ''
    Write-Host "  Plan: $($Plan.Instance)" -ForegroundColor Cyan
    Write-Host ''
    foreach ($action in $Plan.Actions) {
        $color = if ($colorByType.ContainsKey($action.Type)) { $colorByType[$action.Type] } else { 'Gray' }
        $label = $action.Type.PadRight(9)
        $destructiveTag = if ($action.Destructive) { ' [DESTRUCTIVE]' } else { '' }
        Write-Host "  $label $($action.Id)$destructiveTag" -ForegroundColor $color
        foreach ($line in ($action.Reason -split "`n")) {
            if ($line) { Write-Host "            $line" -ForegroundColor Gray }
        }
        Write-Host ''
    }

    $summary = Get-InstancePlanSummary -Plan $Plan
    Write-Host '  Summary:' -ForegroundColor Yellow
    Write-Host "    $($summary.create) to create, $($summary.update) to update, $($summary.replace) to replace, $($summary.delete) to delete, $($summary.preserve) preserved, $($summary.warnings) warning(s), $($summary.destructive) destructive." -ForegroundColor Gray
    Write-Host ''
}

function ConvertTo-InstancePlanJson {
    param([Parameter(Mandatory)][object]$Plan)

    $summary = Get-InstancePlanSummary -Plan $Plan
    $data = [ordered]@{
        apiVersion = $Plan.ApiVersion
        kind       = $Plan.Kind
        instance   = $Plan.Instance
        createdAt  = $Plan.CreatedAt
        summary    = $summary
        actions    = @($Plan.Actions | ForEach-Object {
            [ordered]@{
                id          = $_.Id
                type        = $_.Type
                target      = $_.Target
                reason      = $_.Reason
                destructive = $_.Destructive
            }
        })
    }
    return ($data | ConvertTo-Json -Depth 10)
}

function Save-InstancePlan {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$Path
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global

    $json = ConvertTo-InstancePlanJson -Plan $Plan
    Write-RocmRollTextFile -Path $Path -Content $json -CreateDirectory
    $normalized = ConvertTo-RocmRollCrlfText -Text $json
    $hash = Get-RocmRollStringHash -Content $normalized
    Set-InstanceLastPlan -Name $Plan.Instance -Path $Path -ContentHash $hash
    return $Path
}

function Get-InstancePlanActionsHash {
    <#
    Hashes only the actions list (not CreatedAt) so two plans generated at
    different times but describing the same state compare as identical.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1') -Force -Global

    $actionsData = @($Plan.Actions | ForEach-Object {
        [ordered]@{ id = $_.Id; type = $_.Type; target = $_.Target; reason = $_.Reason; destructive = $_.Destructive }
    })
    $json = ($actionsData | ConvertTo-Json -Depth 10)
    return (Get-RocmRollStringHash -Content (ConvertTo-RocmRollCrlfText -Text $json))
}

function Test-InstancePlanStale {
    <#
    .SYNOPSIS
        Returns $true if a previously saved plan's actions no longer match
        what Get-InstancePlan would produce right now for the same definition.
    #>
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][object]$SavedPlan
    )

    $freshPlan = Get-InstancePlan -Definition $Definition
    return (Get-InstancePlanActionsHash -Plan $freshPlan) -ne (Get-InstancePlanActionsHash -Plan $SavedPlan)
}

function Get-InstanceDestroyPlan {
    <#
    .SYNOPSIS
        Builds a DELETE/PRESERVE action list for tearing down an instance,
        in the same shape Get-InstancePlan produces (so Format-InstancePlanText
        and ConvertTo-InstancePlanJson both work on it unchanged).
    #>
    param([Parameter(Mandatory)][string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global

    $cfg   = Get-Config
    $state = Get-InstanceState -Name $InstanceName
    $actions = New-Object System.Collections.Generic.List[object]

    $instancePath = if ($state -and $state.PSObject.Properties['path'] -and $state.path) { [string]$state.path } else { Join-Path $cfg.InstancesFolder $InstanceName }
    $envName      = if ($state -and $state.PSObject.Properties['environment'] -and $state.environment) { [string]$state.environment } else { '' }
    $envState     = if ($envName) { Get-EnvironmentState -Name $envName } else { $null }
    $envPath      = if ($envState -and $envState.PSObject.Properties['path'] -and $envState.path) { [string]$envState.path } elseif ($envName) { Join-Path $cfg.EnvironmentsFolder $envName } else { '' }
    $launcherPath = Join-Path $cfg.LaunchersFolder "$InstanceName.ps1"
    $stateFile    = Join-Path $cfg.InstanceStateFolder "instance-$InstanceName.json"
    $patchStateFile = Join-Path $cfg.PatchStateFolder "comfyui\$InstanceName.json"

    $exists = $state -or (Test-Path -LiteralPath $instancePath) -or ($envPath -and (Test-Path -LiteralPath $envPath)) -or
        (Test-Path -LiteralPath $launcherPath) -or (Test-Path -LiteralPath $stateFile)

    if (-not $exists) {
        $actions.Add((New-InstancePlanAction -Id 'instance' -Type 'NOOP' -Target $InstanceName `
            -Reason "Instance '$InstanceName' not found; nothing to destroy.")) | Out-Null
        return [pscustomobject]@{
            ApiVersion = 'rocmroll.dev/v1'; Kind = 'InstanceDestroyPlan'; Instance = $InstanceName
            CreatedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); Actions = $actions.ToArray()
        }
    }

    if (Test-Path -LiteralPath $instancePath) {
        $actions.Add((New-InstancePlanAction -Id 'comfyui.source' -Type 'DELETE' -Target $instancePath -Reason 'ComfyUI checkout will be deleted.')) | Out-Null
    }
    if ($envPath -and (Test-Path -LiteralPath $envPath)) {
        $actions.Add((New-InstancePlanAction -Id 'environment' -Type 'DELETE' -Target $envPath -Reason 'Python environment will be deleted.')) | Out-Null
    }
    if (Test-Path -LiteralPath $launcherPath) {
        $actions.Add((New-InstancePlanAction -Id 'launcher' -Type 'DELETE' -Target $launcherPath -Reason 'Launcher files will be deleted.')) | Out-Null
    }
    if (Test-Path -LiteralPath $patchStateFile) {
        $actions.Add((New-InstancePlanAction -Id 'patches' -Type 'DELETE' -Target $patchStateFile -Reason 'Patch state/backups will be deleted.')) | Out-Null
    }
    $desktopId = if ($state -and $state.PSObject.Properties['comfyDesktopId'] -and $state.comfyDesktopId) { [string]$state.comfyDesktopId } else { '' }
    if ($desktopId) {
        $actions.Add((New-InstancePlanAction -Id 'comfyDesktop' -Type 'DELETE' -Target $desktopId -Reason 'ComfyUI Desktop registration will be removed.')) | Out-Null
    }
    $actions.Add((New-InstancePlanAction -Id 'state' -Type 'DELETE' -Target $stateFile -Reason 'Recorded instance/environment state will be deleted.')) | Out-Null

    $actions.Add((New-InstancePlanAction -Id 'shared' -Type 'PRESERVE' -Target $cfg.SharedFolder `
        -Reason 'Shared models/input/output/temp/user/workflows are never touched by destroy.')) | Out-Null
    $overlayFolder = Get-InstanceOverlayFolder -InstanceName $InstanceName
    if (Test-Path -LiteralPath $overlayFolder) {
        $actions.Add((New-InstancePlanAction -Id 'overlays' -Type 'PRESERVE' -Target $overlayFolder `
            -Reason 'Overlay/definition files are kept so apply can recreate this instance later.')) | Out-Null
    }

    return [pscustomobject]@{
        ApiVersion = 'rocmroll.dev/v1'; Kind = 'InstanceDestroyPlan'; Instance = $InstanceName
        CreatedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); Actions = $actions.ToArray()
    }
}

function Invoke-InstanceDestroy {
    <#
    .SYNOPSIS
        Confirms and executes a destroy plan built by Get-InstanceDestroyPlan.
        Assumes the caller already printed the plan (Format-InstancePlanText/
        ConvertTo-InstancePlanJson), unlike Invoke-InstanceApply which prints
        it itself.

    .DESCRIPTION
        Calls RocmRoll.Instance.Remove-RocmRollInstance - the same function
        'instance remove --all' uses - so destroy tears down exactly what a
        full removal already does, rather than reimplementing it.
    #>
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][object]$Plan,
        [switch]$AutoApprove,
        [switch]$DryRun
    )

    $deleteActions = @($Plan.Actions | Where-Object { $_.Type -eq 'DELETE' })
    if ($deleteActions.Count -eq 0 -or $DryRun) {
        return [pscustomobject]@{ Destroyed = $false; Cancelled = $false }
    }

    if (-not $AutoApprove) {
        Write-Host ''
        $typed = Read-Host "  Type the instance name to confirm destroying it ('$($Definition.Name)')"
        if ($typed -cne $Definition.Name) {
            Write-Host '  Destroy cancelled.' -ForegroundColor Yellow
            Write-Host ''
            return [pscustomobject]@{ Destroyed = $false; Cancelled = $true }
        }
    }

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Instance.psm1') -Force -Global
    Remove-RocmRollInstance -InstanceName $Definition.Name -Force

    Write-Host ''
    Write-Host "  Instance '$($Definition.Name)' destroyed." -ForegroundColor Green
    Write-Host ''
    return [pscustomobject]@{ Destroyed = $true; Cancelled = $false }
}

function Invoke-InstanceApply {
    <#
    .SYNOPSIS
        Executes a plan, capable of performing every action a full 'instance
        install'/'instance update' can.

    .DESCRIPTION
        Anything that needs the install/update pipeline - a missing or
        changed environment, a channel or Python version change, or a
        missing/outdated ComfyUI checkout - is executed first, by a single
        call to RocmRoll.Core.Invoke-FullInstall, the same function 'instance
        install' (new instance) and 'instance update' (existing instance, no
        scope flags) already use. This is what makes apply capable of doing
        everything install/update can: it reuses that pipeline rather than
        reimplementing pieces of it, and it is idempotent the same way
        re-running install/update already is.

        A pending launcher-only CREATE (nothing else pending) is handled
        directly without paying for the full pipeline.

        extra_model_paths.yaml (via RocmRoll.ModelPaths) is reconciled last,
        after the pipeline, applying the plan's PRESERVE/CREATE/UPDATE/
        destructive-approval semantics as the final word - it must not run
        before the pipeline: writing that file with -CreateDirectory would
        create the instance folder ahead of the ComfyUI clone step, which
        would then wrongly see an existing folder and skip cloning.

        Informational WARNING actions (unmanaged custom nodes, a declared
        paths.shared mismatch) are never auto-applied - see Non-Goals in
        docs/declarative-instances.md.
    #>
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][object]$Plan,
        [switch]$AutoApprove,
        [switch]$AllowDestructive,
        [switch]$DryRun
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ModelPaths.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Launcher.psm1') -Force -Global

    $allowDestructiveEffective = $AllowDestructive -or [bool]$Definition.UpdatePolicy.AllowDestructive
    $destructiveActions = @($Plan.Actions | Where-Object { $_.Destructive })
    if ($destructiveActions.Count -gt 0 -and -not $allowDestructiveEffective) {
        Write-Host ''
        Write-Host '  BLOCKED  The following destructive action(s) require approval:' -ForegroundColor Red
        foreach ($blocked in $destructiveActions) { Write-Host "    $($blocked.Type) $($blocked.Id) - $($blocked.Target)" -ForegroundColor Red }
        Write-Host '  Re-run with --allow-destructive, or set updatePolicy.allowDestructive: true in the definition.' -ForegroundColor DarkGray
        Write-Host ''
        return [pscustomobject]@{ Applied = @(); Blocked = $destructiveActions; Skipped = @() }
    }

    $executableActions = @($Plan.Actions | Where-Object { $_.Type -in @('CREATE', 'UPDATE', 'REPAIR') })
    if ($executableActions.Count -gt 0 -and -not $AutoApprove -and -not $DryRun) {
        Format-InstancePlanText -Plan $Plan
        $confirm = Read-Host '  Apply these changes? [y/N]'
        if ($confirm -notmatch '^[yY]') {
            Write-Host '  Apply cancelled.' -ForegroundColor Yellow
            Write-Host ''
            return [pscustomobject]@{ Applied = @(); Blocked = @(); Skipped = $executableActions }
        }
    }

    $applied = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    foreach ($action in $Plan.Actions) { $byId[$action.Id] = $action }

    # -- Everything that needs the install/update pipeline, first (see .DESCRIPTION) --
    $pipelineIds = @('comfyui.source', 'channel', 'pythonVersion', 'environment')
    $pipelineActions = @($Plan.Actions | Where-Object { $_.Id -in $pipelineIds -and $_.Type -in @('CREATE', 'UPDATE') })
    $launcherAction = if ($byId.ContainsKey('launcher')) { $byId['launcher'] } else { $null }

    if ($pipelineActions.Count -gt 0) {
        if ($DryRun) {
            Write-Host "  [dry-run] Would run the install/update pipeline (channel=$($Definition.Channel), pythonVersion=$($Definition.PythonVersion)):" -ForegroundColor DarkGray
            foreach ($pipelineAction in $pipelineActions) {
                Write-Host "    $($pipelineAction.Type) $($pipelineAction.Id)" -ForegroundColor DarkGray
                $applied.Add($pipelineAction) | Out-Null
            }
            if ($launcherAction -and $launcherAction.Type -eq 'CREATE') { $applied.Add($launcherAction) | Out-Null }
        } else {
            Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Core.psm1') -Force -Global
            $instanceExists = ($null -ne (Get-InstanceState -Name $Definition.Name))
            Invoke-FullInstall -InstanceName $Definition.Name -Channel $Definition.Channel -PythonVersion $Definition.PythonVersion `
                -GfxOverride $Definition.Gfx -ProfileName $Definition.Profile -SharedWorkflows:$Definition.SharedWorkflows -IsUpdate:$instanceExists
            foreach ($pipelineAction in $pipelineActions) { $applied.Add($pipelineAction) | Out-Null }
            # Invoke-FullInstall always (re)generates launchers as one of its
            # final steps, so a pending launcher CREATE is covered by it too.
            if ($launcherAction -and $launcherAction.Type -eq 'CREATE') { $applied.Add($launcherAction) | Out-Null }
        }
    } elseif ($launcherAction -and $launcherAction.Type -eq 'CREATE') {
        # Nothing pipeline-level pending - regenerate just the launcher.
        $launcherState = Get-InstanceState -Name $Definition.Name
        $launcherEnvName = if ($launcherState -and $launcherState.PSObject.Properties['environment'] -and $launcherState.environment) { [string]$launcherState.environment } else { '' }
        $launcherEnvState = if ($launcherEnvName) { Get-EnvironmentState -Name $launcherEnvName } else { $null }
        if (-not $launcherEnvState) {
            Write-LogWarn "Cannot regenerate launcher for '$($Definition.Name)': no environment state found." -Comp 'RocmRoll.InstancePlan'
            $skipped.Add($launcherAction) | Out-Null
        } elseif ($DryRun) {
            Write-Host "  [dry-run] Would regenerate launcher for $($Definition.Name)" -ForegroundColor DarkGray
            $applied.Add($launcherAction) | Out-Null
        } else {
            $gfx = if ($launcherEnvState.PSObject.Properties['gpu'] -and $launcherEnvState.gpu -and $launcherEnvState.gpu.PSObject.Properties['gfx']) { [string]$launcherEnvState.gpu.gfx } else { $Definition.Gfx }
            Invoke-GenerateLaunchers -InstanceName $Definition.Name -EnvironmentName $launcherEnvName `
                -GfxVersion $gfx -Channel $Definition.Channel -ProfileName $Definition.Profile
            $applied.Add($launcherAction) | Out-Null
        }
    }

    # -- extra_model_paths.yaml: handled after the pipeline (see .DESCRIPTION) ----
    $mpAction = if ($byId.ContainsKey('modelPaths.extra_model_paths')) { $byId['modelPaths.extra_model_paths'] } else { $null }
    if ($mpAction -and $mpAction.Type -in @('CREATE', 'UPDATE')) {
        if ($DryRun) {
            Write-Host "  [dry-run] Would apply extra_model_paths.yaml ($($mpAction.Type))" -ForegroundColor DarkGray
        } else {
            Invoke-ApplyExtraModelPaths -InstanceName $Definition.Name -Mode 'Apply' -Force:$mpAction.Destructive | Out-Null
        }
        $applied.Add($mpAction) | Out-Null
    } elseif ($mpAction -and $mpAction.Type -eq 'WARNING' -and $mpAction.Destructive) {
        # Only reached once the destructive-approval gate above already passed.
        if ($DryRun) {
            Write-Host '  [dry-run] Would replace extra_model_paths.yaml (destructive)' -ForegroundColor DarkGray
        } else {
            Invoke-ApplyExtraModelPaths -InstanceName $Definition.Name -Mode 'Apply' -Force | Out-Null
        }
        $applied.Add($mpAction) | Out-Null
    }

    # -- Everything else (informational WARNINGs) is never auto-applied -----------
    foreach ($action in $Plan.Actions) {
        $alreadyHandled = ($action.Id -eq 'modelPaths.extra_model_paths') -or ($action.Id -in $pipelineIds) -or ($action.Id -eq 'launcher')
        if (-not $alreadyHandled -and $action.Type -in @('CREATE', 'UPDATE', 'REPAIR')) {
            $skipped.Add($action) | Out-Null
        }
    }

    if (-not $DryRun) {
        Set-InstanceDefinitionRecord -Name $Definition.Name -SourcePath $Definition.SourcePath -ContentHash $Definition.ContentHash
    }

    Write-Host ''
    Write-Host "  Apply complete for '$($Definition.Name)': $($applied.Count) applied, $($skipped.Count) skipped." -ForegroundColor Green
    Write-Host ''

    return [pscustomobject]@{ Applied = $applied.ToArray(); Blocked = @(); Skipped = $skipped.ToArray() }
}

Export-ModuleMember -Function New-InstancePlanAction, Get-InstancePlan, Get-InstancePlanSummary,
    Format-InstancePlanText, ConvertTo-InstancePlanJson, Save-InstancePlan, Test-InstancePlanStale,
    Get-InstanceDestroyPlan, Invoke-InstanceDestroy, Invoke-InstanceApply
