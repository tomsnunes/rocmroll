#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.InstanceDefinition - Declarative ComfyUIInstance YAML schema
    parsing, validation, and defaulting.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.YamlLite.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Utilities.psm1')

$script:KnownSpecKeys = @('channel', 'pythonVersion', 'profile', 'gfx', 'sharedWorkflows', 'comfyui', 'modelPaths', 'customNodes', 'requirements', 'paths', 'updatePolicy')
$script:KnownSubKeys = @{
    comfyui      = @('repo', 'ref')
    modelPaths   = @('source', 'preserveOnUpdate', 'repairPolicy', 'overlayPath')
    customNodes  = @('source', 'file', 'pruneUnmanaged')
    requirements = @('source', 'file')
    paths        = @('shared', 'models', 'input', 'output', 'temp', 'user')
    updatePolicy = @('strategy', 'allowDestructive', 'requirePlan')
}

function Get-InstanceDefinitionPath {
    <# Default location: overlays\<name>\<name>.yaml - alongside that
       instance's environment\/instance\ overlay files. #>
    param([Parameter(Mandatory)][string]$InstanceName)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    return Join-Path (Get-InstanceOverlayFolder -InstanceName $InstanceName) "$InstanceName.yaml"
}

function Get-InstanceDefinitionWarnings {
    param([object]$SpecNode)

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($SpecNode -isnot [System.Collections.IDictionary]) { return @($warnings) }

    foreach ($key in $SpecNode.Keys) {
        if ($script:KnownSpecKeys -notcontains $key) {
            $warnings.Add("Unknown field: spec.$key") | Out-Null
            continue
        }
        if ($script:KnownSubKeys.ContainsKey($key)) {
            $subNode = $SpecNode[$key]
            if ($subNode -is [System.Collections.IDictionary]) {
                foreach ($subKey in $subNode.Keys) {
                    if ($script:KnownSubKeys[$key] -notcontains $subKey) {
                        $warnings.Add("Unknown field: spec.$key.$subKey") | Out-Null
                    }
                }
            }
        }
    }
    return @($warnings)
}

function Read-InstanceDefinition {
    <#
    .SYNOPSIS
        Parses and validates a ComfyUIInstance YAML definition file.

    .DESCRIPTION
        Validation rules (spec: docs/declarative-instances.md):
          - apiVersion must be 'rocmroll.dev/v1'.
          - kind must be 'ComfyUIInstance'.
          - metadata.name is required and must be a safe instance name.
          - spec.channel is required and must resolve to a known channel.
          - Defaults: pythonVersion -> config default, modelPaths.preserveOnUpdate
            -> true, modelPaths.repairPolicy -> confirm, and similar per-field
            defaults for the rest of the schema.
          - Unrecognized fields are collected as warnings, not fatal errors.
        Throws ROCMROLL-DEF-* with a clear message on schema violations.
    #>
    param([Parameter(Mandatory)][string]$FilePath)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "ROCMROLL-DEF-000: Instance definition file not found: $FilePath"
    }

    $rawContent = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    $doc = ConvertFrom-YamlLite -Content $rawContent

    $apiVersion = Get-YamlLiteValue -Node $doc -Path 'apiVersion'
    if ($apiVersion -ne 'rocmroll.dev/v1') {
        throw "ROCMROLL-DEF-001: Unrecognized or missing apiVersion in '$FilePath' (expected 'rocmroll.dev/v1', got '$apiVersion')."
    }

    $kind = Get-YamlLiteValue -Node $doc -Path 'kind'
    if ($kind -ne 'ComfyUIInstance') {
        throw "ROCMROLL-DEF-002: Unsupported kind '$kind' in '$FilePath' (expected 'ComfyUIInstance')."
    }

    $name = Get-YamlLiteValue -Node $doc -Path 'metadata.name'
    if (-not $name -or $name -notmatch '^[A-Za-z0-9_\-]+$') {
        throw "ROCMROLL-DEF-003: metadata.name is required and must match ^[A-Za-z0-9_-]+`$ in '$FilePath'."
    }

    $cfg = Get-Config
    $channelRaw = Get-YamlLiteValue -Node $doc -Path 'spec.channel'
    if (-not $channelRaw) {
        throw "ROCMROLL-DEF-004: spec.channel is required in '$FilePath'."
    }
    $channel = Resolve-ChannelName -Channel $channelRaw
    $channelsManifestPath = Join-Path $cfg.ManifestsFolder 'channels.json'
    $channelsManifest = Get-Content -LiteralPath $channelsManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $channelsManifest.PSObject.Properties[$channel]) {
        throw "ROCMROLL-DEF-004: spec.channel '$channelRaw' does not resolve to a known channel in '$FilePath'."
    }

    $pythonVersion = Get-YamlLiteValue -Node $doc -Path 'spec.pythonVersion'
    if (-not $pythonVersion) { $pythonVersion = $cfg.RuntimeVersion }

    $profileName = Get-YamlLiteValue -Node $doc -Path 'spec.profile'
    if (-not $profileName) { $profileName = '' }

    $gfx = Get-YamlLiteValue -Node $doc -Path 'spec.gfx'
    if (-not $gfx) { $gfx = '' }

    $sharedWorkflowsRaw = Get-YamlLiteValue -Node $doc -Path 'spec.sharedWorkflows'
    $sharedWorkflows = if ($null -eq $sharedWorkflowsRaw) { $false } else { [bool]$sharedWorkflowsRaw }

    $comfyRepo = Get-YamlLiteValue -Node $doc -Path 'spec.comfyui.repo'
    if (-not $comfyRepo) { $comfyRepo = 'https://github.com/Comfy-Org/ComfyUI.git' }
    $comfyRef = Get-YamlLiteValue -Node $doc -Path 'spec.comfyui.ref'
    if (-not $comfyRef) { $comfyRef = 'master' }

    $modelPathsSource = Get-YamlLiteValue -Node $doc -Path 'spec.modelPaths.source'
    if (-not $modelPathsSource) { $modelPathsSource = 'overlay' }
    $preserveRaw = Get-YamlLiteValue -Node $doc -Path 'spec.modelPaths.preserveOnUpdate'
    $preserveOnUpdate = if ($null -eq $preserveRaw) { $true } else { [bool]$preserveRaw }
    $repairPolicy = Get-YamlLiteValue -Node $doc -Path 'spec.modelPaths.repairPolicy'
    if (-not $repairPolicy) { $repairPolicy = 'confirm' }
    $overlayPathRaw = Get-YamlLiteValue -Node $doc -Path 'spec.modelPaths.overlayPath'
    if (-not $overlayPathRaw) { $overlayPathRaw = "overlays/$name/instance/extra_model_paths.yaml" }

    $customNodesSource = Get-YamlLiteValue -Node $doc -Path 'spec.customNodes.source'
    if (-not $customNodesSource) { $customNodesSource = 'overlay' }
    $customNodesFile = Get-YamlLiteValue -Node $doc -Path 'spec.customNodes.file'
    if (-not $customNodesFile) { $customNodesFile = "overlays/$name/instance/custom_nodes.json" }
    $pruneRaw = Get-YamlLiteValue -Node $doc -Path 'spec.customNodes.pruneUnmanaged'
    $pruneUnmanaged = if ($null -eq $pruneRaw) { $false } else { [bool]$pruneRaw }

    $requirementsSource = Get-YamlLiteValue -Node $doc -Path 'spec.requirements.source'
    if (-not $requirementsSource) { $requirementsSource = 'overlay' }
    $requirementsFile = Get-YamlLiteValue -Node $doc -Path 'spec.requirements.file'
    if (-not $requirementsFile) { $requirementsFile = "overlays/$name/environment/requirements.txt" }

    $paths = @{
        shared = Get-YamlLiteValue -Node $doc -Path 'spec.paths.shared'
        models = Get-YamlLiteValue -Node $doc -Path 'spec.paths.models'
        input  = Get-YamlLiteValue -Node $doc -Path 'spec.paths.input'
        output = Get-YamlLiteValue -Node $doc -Path 'spec.paths.output'
        temp   = Get-YamlLiteValue -Node $doc -Path 'spec.paths.temp'
        user   = Get-YamlLiteValue -Node $doc -Path 'spec.paths.user'
    }

    $updateStrategy = Get-YamlLiteValue -Node $doc -Path 'spec.updatePolicy.strategy'
    if (-not $updateStrategy) { $updateStrategy = 'safe' }
    $allowDestructiveRaw = Get-YamlLiteValue -Node $doc -Path 'spec.updatePolicy.allowDestructive'
    $allowDestructive = if ($null -eq $allowDestructiveRaw) { $false } else { [bool]$allowDestructiveRaw }
    $requirePlanRaw = Get-YamlLiteValue -Node $doc -Path 'spec.updatePolicy.requirePlan'
    $requirePlan = if ($null -eq $requirePlanRaw) { $true } else { [bool]$requirePlanRaw }

    # @() at the call site too - an empty-list return can still collapse to $null without it.
    $warnings = @(Get-InstanceDefinitionWarnings -SpecNode (Get-YamlLiteValue -Node $doc -Path 'spec'))
    $contentHash = Get-RocmRollStringHash -Content $rawContent

    return [pscustomobject]@{
        ApiVersion      = $apiVersion
        Kind            = $kind
        Name            = $name
        Channel         = $channel
        ChannelRaw      = $channelRaw
        PythonVersion   = $pythonVersion
        Profile         = $profileName
        Gfx             = $gfx
        SharedWorkflows = $sharedWorkflows
        ComfyUI         = @{ Repo = $comfyRepo; Ref = $comfyRef }
        ModelPaths      = @{ Source = $modelPathsSource; PreserveOnUpdate = $preserveOnUpdate; RepairPolicy = $repairPolicy; OverlayPath = $overlayPathRaw }
        CustomNodes     = @{ Source = $customNodesSource; File = $customNodesFile; PruneUnmanaged = $pruneUnmanaged }
        Requirements    = @{ Source = $requirementsSource; File = $requirementsFile }
        Paths           = $paths
        UpdatePolicy    = @{ Strategy = $updateStrategy; AllowDestructive = $allowDestructive; RequirePlan = $requirePlan }
        SourcePath      = $FilePath
        ContentHash     = $contentHash
        Warnings        = $warnings
    }
}

function Get-InstanceDefinitionSnapshot {
    <#
    .SYNOPSIS
        Reverse-engineers a definition snapshot from an existing instance's
        recorded state and filesystem, for 'instance import'. Shape matches
        Read-InstanceDefinition's output so both feed Get-InstancePlan and
        ConvertTo-InstanceDefinitionYaml the same way.

    .DESCRIPTION
        spec.profile is always left empty ("") - the profile an instance was
        installed/launched with is not persisted anywhere in instance state,
        so it cannot be reliably recovered. An empty profile resolves to the
        channel default, which is the closest safe guess.
    #>
    param([Parameter(Mandatory)][string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.ModelPaths.psm1') -Force -Global

    $cfg = Get-Config
    $state = Get-InstanceState -Name $InstanceName
    if (-not $state) {
        throw "ROCMROLL-DEF-010: Instance '$InstanceName' not found in state. Nothing to import. Run 'instance list' to see installed instances."
    }

    $channel = if ($state.PSObject.Properties['channel'] -and $state.channel) { [string]$state.channel } else { 'stable' }
    $channel = Resolve-ChannelName -Channel $channel

    $envName = if ($state.PSObject.Properties['environment'] -and $state.environment) { [string]$state.environment } else { '' }
    $envState = if ($envName) { Get-EnvironmentState -Name $envName } else { $null }
    $pythonVersion = if ($envState -and $envState.PSObject.Properties['runtimeVersion'] -and $envState.runtimeVersion) { [string]$envState.runtimeVersion } else { $cfg.RuntimeVersion }
    $gfx = if ($envState -and $envState.PSObject.Properties['gpu'] -and $envState.gpu -and $envState.gpu.PSObject.Properties['gfx']) { [string]$envState.gpu.gfx } else { '' }

    $comfyRepo = if ($state.PSObject.Properties['comfyui'] -and $state.comfyui -and $state.comfyui.PSObject.Properties['repo'] -and $state.comfyui.repo) { [string]$state.comfyui.repo } else { 'https://github.com/Comfy-Org/ComfyUI.git' }
    $comfyRef = if ($state.PSObject.Properties['comfyui'] -and $state.comfyui -and $state.comfyui.PSObject.Properties['ref'] -and $state.comfyui.ref) { [string]$state.comfyui.ref } else { 'master' }

    $modelPathsOverlay = Get-ExtraModelPathsOverlayPath -InstanceName $InstanceName
    $modelPathsSource = if (Test-Path -LiteralPath $modelPathsOverlay -PathType Leaf) { 'overlay' } else { 'template' }

    $customNodesPath = Join-Path (Get-InstanceOverlayInstanceFolder -InstanceName $InstanceName) 'custom_nodes.json'
    $customNodesSource = if (Test-Path -LiteralPath $customNodesPath -PathType Leaf) { 'overlay' } else { 'template' }

    $requirementsPath = Join-Path (Get-InstanceOverlayEnvironmentFolder -InstanceName $InstanceName) 'requirements.txt'
    $requirementsSource = if (Test-Path -LiteralPath $requirementsPath -PathType Leaf) { 'overlay' } else { 'template' }

    $userDefaultWorkflows = Join-Path (Join-Path $cfg.InstancesFolder "$InstanceName\user\default") 'workflows'
    $sharedWorkflowsLink = Get-Item -LiteralPath $userDefaultWorkflows -ErrorAction SilentlyContinue
    $sharedWorkflows = [bool]($sharedWorkflowsLink -and $sharedWorkflowsLink.LinkType -eq 'SymbolicLink')

    return [pscustomobject]@{
        Name            = $InstanceName
        Channel         = $channel
        PythonVersion   = $pythonVersion
        Profile         = ''
        Gfx             = $gfx
        SharedWorkflows = $sharedWorkflows
        ComfyUI         = @{ Repo = $comfyRepo; Ref = $comfyRef }
        ModelPaths      = @{ Source = $modelPathsSource; PreserveOnUpdate = $true; RepairPolicy = 'confirm'; OverlayPath = "overlays/$InstanceName/instance/extra_model_paths.yaml" }
        CustomNodes     = @{ Source = $customNodesSource; File = "overlays/$InstanceName/instance/custom_nodes.json"; PruneUnmanaged = $false }
        Requirements    = @{ Source = $requirementsSource; File = "overlays/$InstanceName/environment/requirements.txt" }
        Paths           = @{
            shared = $cfg.SharedFolder
            models = $cfg.SharedModelsFolder
            input  = $cfg.InputFolder
            output = $cfg.OutputFolder
            temp   = $cfg.TempDataFolder
            user   = $cfg.UserDataFolder
        }
        UpdatePolicy    = @{ Strategy = 'safe'; AllowDestructive = $false; RequirePlan = $true }
    }
}

function Format-YamlLiteScalar {
    <# Renders "" for an empty/null scalar so ConvertFrom-YamlLite reads it
       back as an explicit empty string rather than starting a nested map -
       a bare "key:" with nothing after it means "nested mapping follows". #>
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return '""' }
    return [string]$Value
}

function Format-YamlLiteBool {
    param([bool]$Value)
    if ($Value) { return 'true' } else { return 'false' }
}

function ConvertTo-InstanceDefinitionYaml {
    <#
    .SYNOPSIS
        Renders a definition snapshot (Get-InstanceDefinitionSnapshot or
        Read-InstanceDefinition's output) as ComfyUIInstance YAML text.
    #>
    param([Parameter(Mandatory)][object]$Snapshot)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('apiVersion: rocmroll.dev/v1') | Out-Null
    $lines.Add('kind: ComfyUIInstance') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('metadata:') | Out-Null
    $lines.Add("  name: $($Snapshot.Name)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('spec:') | Out-Null
    $lines.Add("  channel: $($Snapshot.Channel)") | Out-Null
    $lines.Add("  pythonVersion: `"$($Snapshot.PythonVersion)`"") | Out-Null
    $lines.Add("  profile: $(Format-YamlLiteScalar $Snapshot.Profile)") | Out-Null
    $lines.Add("  gfx: $(Format-YamlLiteScalar $Snapshot.Gfx)") | Out-Null
    $lines.Add("  sharedWorkflows: $(Format-YamlLiteBool $Snapshot.SharedWorkflows)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('  comfyui:') | Out-Null
    $lines.Add("    repo: $($Snapshot.ComfyUI.Repo)") | Out-Null
    $lines.Add("    ref: $($Snapshot.ComfyUI.Ref)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('  modelPaths:') | Out-Null
    $lines.Add("    source: $($Snapshot.ModelPaths.Source)") | Out-Null
    $lines.Add("    preserveOnUpdate: $(Format-YamlLiteBool $Snapshot.ModelPaths.PreserveOnUpdate)") | Out-Null
    $lines.Add("    repairPolicy: $($Snapshot.ModelPaths.RepairPolicy)") | Out-Null
    if ($Snapshot.ModelPaths.Source -eq 'overlay') {
        $lines.Add("    overlayPath: $($Snapshot.ModelPaths.OverlayPath)") | Out-Null
    }
    $lines.Add('') | Out-Null
    $lines.Add('  customNodes:') | Out-Null
    $lines.Add("    source: $($Snapshot.CustomNodes.Source)") | Out-Null
    $lines.Add("    file: $($Snapshot.CustomNodes.File)") | Out-Null
    $lines.Add("    pruneUnmanaged: $(Format-YamlLiteBool $Snapshot.CustomNodes.PruneUnmanaged)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('  requirements:') | Out-Null
    $lines.Add("    source: $($Snapshot.Requirements.Source)") | Out-Null
    $lines.Add("    file: $($Snapshot.Requirements.File)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('  paths:') | Out-Null
    $lines.Add("    shared: $($Snapshot.Paths.shared)") | Out-Null
    $lines.Add("    models: $($Snapshot.Paths.models)") | Out-Null
    $lines.Add("    input: $($Snapshot.Paths.input)") | Out-Null
    $lines.Add("    output: $($Snapshot.Paths.output)") | Out-Null
    $lines.Add("    temp: $($Snapshot.Paths.temp)") | Out-Null
    $lines.Add("    user: $($Snapshot.Paths.user)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('  updatePolicy:') | Out-Null
    $lines.Add("    strategy: $($Snapshot.UpdatePolicy.Strategy)") | Out-Null
    $lines.Add("    allowDestructive: $(Format-YamlLiteBool $Snapshot.UpdatePolicy.AllowDestructive)") | Out-Null
    $lines.Add("    requirePlan: $(Format-YamlLiteBool $Snapshot.UpdatePolicy.RequirePlan)") | Out-Null

    return ($lines.ToArray() -join "`n") + "`n"
}

function Export-InstanceDefinition {
    <#
    .SYNOPSIS
        Writes a ComfyUIInstance YAML definition reverse-engineered from an
        existing instance's state ('instance import'). Refuses to overwrite
        an existing definition file unless -Force is given.
    #>
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [string]$OutPath = '',
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1') -Force -Global

    $targetPath = if ($OutPath) { $OutPath } else { Get-InstanceDefinitionPath -InstanceName $InstanceName }
    if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and -not $Force) {
        throw "ROCMROLL-DEF-011: Definition file already exists: $targetPath. Use -Force to overwrite."
    }

    $snapshot = Get-InstanceDefinitionSnapshot -InstanceName $InstanceName
    $yaml = ConvertTo-InstanceDefinitionYaml -Snapshot $snapshot
    Write-RocmRollTextFile -Path $targetPath -Content $yaml -CreateDirectory

    return $targetPath
}

Export-ModuleMember -Function Get-InstanceDefinitionPath, Read-InstanceDefinition,
    Get-InstanceDefinitionSnapshot, ConvertTo-InstanceDefinitionYaml, Export-InstanceDefinition
