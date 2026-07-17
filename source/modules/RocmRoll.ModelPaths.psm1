#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.ModelPaths - Safe, drift-aware extra_model_paths.yaml management.

.DESCRIPTION
    Resolves the desired extra_model_paths.yaml content (custom overlay or
    template), classifies the on-disk file against ROCmRoll-recorded state
    (managed / custom-unknown / drifted / source-changed / missing), and
    applies changes according to install/repair/update/apply semantics so
    that update and repair never silently overwrite a user-edited file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Utilities.psm1')

function Get-ExtraModelPathsInstancePath {
    param([Parameter(Mandatory)][string]$InstanceName)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    return Join-Path (Join-Path $cfg.InstancesFolder $InstanceName) 'extra_model_paths.yaml'
}

function Get-ExtraModelPathsOverlayPath {
    param([Parameter(Mandatory)][string]$InstanceName)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    return Join-Path (Get-InstanceOverlayInstanceFolder -InstanceName $InstanceName) 'extra_model_paths.yaml'
}

function Get-ExtraModelPathsTemplatePath {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    return Join-Path $cfg.TemplatesFolder 'extra_model_paths.yaml.tpl'
}

function Get-RocmRollBuiltinExtraModelPathsTemplate {
    return @"
rocmroll:
  base_path: {SharedFolder}
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

function Get-ExtraModelPathsDesiredContent {
    <#
    Resolves the content ROCmRoll would write for an instance right now:
    the overlays\<instanceName>\instance\extra_model_paths.yaml overlay if present,
    otherwise the shared template, otherwise a built-in default. Returns
    both the rendered content (with {SharedFolder} substituted) and the
    raw source content/hash so callers can detect source-only changes.
    #>
    param([Parameter(Mandatory)][string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config

    $overlayPath  = Get-ExtraModelPathsOverlayPath -InstanceName $InstanceName
    $templatePath = Get-ExtraModelPathsTemplatePath

    if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
        $source        = 'overlay'
        $sourcePath    = $overlayPath
        $sourceContent = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    } elseif (Test-Path -LiteralPath $templatePath -PathType Leaf) {
        $source        = 'template'
        $sourcePath    = $templatePath
        $sourceContent = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    } else {
        $source        = 'builtin'
        $sourcePath    = ''
        $sourceContent = Get-RocmRollBuiltinExtraModelPathsTemplate
    }

    $sharedSlash      = $cfg.SharedFolder -replace '\\', '/'
    $renderedContent  = $sourceContent -replace '\{SharedFolder\}', $sharedSlash

    return [pscustomobject]@{
        Content       = $renderedContent
        Source        = $source
        SourcePath    = $sourcePath
        SourceContent = $sourceContent
        SourceHash    = (Get-RocmRollStringHash -Content $sourceContent)
    }
}

function Get-ExtraModelPathsStatus {
    <#
    Classifies the on-disk extra_model_paths.yaml for an instance:
      missing         - file does not exist
      managed         - file matches what ROCmRoll last wrote, and the
                         overlay/template source has not changed since
      custom-unknown  - file exists but ROCmRoll has no managed-file record
      drifted         - file exists and its hash differs from the recorded
                         contentHash (edited by hand, or record is stale)
      source-changed  - file still matches the recorded contentHash, but the
                         overlay/template source used to generate it changed
    #>
    param([Parameter(Mandatory)][string]$InstanceName)

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global

    $instancePath = Get-ExtraModelPathsInstancePath -InstanceName $InstanceName

    if (-not (Test-Path -LiteralPath $instancePath -PathType Leaf)) {
        return [pscustomobject]@{
            Status        = 'missing'
            InstancePath  = $instancePath
            ManagedEntry  = $null
            CurrentHash   = $null
            Desired       = $null
        }
    }

    $currentHash  = Get-RocmRollFileHash -Path $instancePath
    $managedEntry = Get-InstanceManagedFile -Name $InstanceName -Key 'extra_model_paths.yaml'

    if (-not $managedEntry) {
        return [pscustomobject]@{
            Status        = 'custom-unknown'
            InstancePath  = $instancePath
            ManagedEntry  = $null
            CurrentHash   = $currentHash
            Desired       = $null
        }
    }

    $recordedContentHash = if ($managedEntry.PSObject.Properties['contentHash']) { [string]$managedEntry.contentHash } else { '' }
    if ($recordedContentHash -and $recordedContentHash -ne $currentHash) {
        return [pscustomobject]@{
            Status        = 'drifted'
            InstancePath  = $instancePath
            ManagedEntry  = $managedEntry
            CurrentHash   = $currentHash
            Desired       = $null
        }
    }

    $desired             = Get-ExtraModelPathsDesiredContent -InstanceName $InstanceName
    $recordedSourceHash  = if ($managedEntry.PSObject.Properties['sourceHash']) { [string]$managedEntry.sourceHash } else { '' }
    if ($recordedSourceHash -and $desired.SourceHash -ne $recordedSourceHash) {
        return [pscustomobject]@{
            Status        = 'source-changed'
            InstancePath  = $instancePath
            ManagedEntry  = $managedEntry
            CurrentHash   = $currentHash
            Desired       = $desired
        }
    }

    return [pscustomobject]@{
        Status        = 'managed'
        InstancePath  = $instancePath
        ManagedEntry  = $managedEntry
        CurrentHash   = $currentHash
        Desired       = $desired
    }
}

function Invoke-ConfirmExtraModelPathsOverwrite {
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [Parameter(Mandatory)][object]$Status,
        [switch]$Force
    )

    if ($Force) { return $true }

    Write-Host ''
    Write-Host "  extra_model_paths.yaml is '$($Status.Status)' for instance '$InstanceName':" -ForegroundColor Yellow
    Write-Host "    $($Status.InstancePath)" -ForegroundColor Gray
    Write-Host '  This file was not generated by ROCmRoll, or was edited after ROCmRoll wrote it.' -ForegroundColor DarkGray
    $confirm = Read-Host '  Replace it with the ROCmRoll-managed version? [y/N]'
    return ($confirm -match '^[yY]')
}

function Write-RocmRollExtraModelPathsFile {
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [Parameter(Mandatory)][string]$InstancePath,
        [switch]$WhatIf
    )

    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.State.psm1') -Force -Global

    $desired = Get-ExtraModelPathsDesiredContent -InstanceName $InstanceName

    if ($WhatIf) {
        Write-LogInfo "Would write extra_model_paths.yaml from $($desired.Source): $InstancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
        return $InstancePath
    }

    Write-RocmRollTextFile -Path $InstancePath -Content $desired.Content -CreateDirectory
    $normalizedContent = ConvertTo-RocmRollCrlfText -Text $desired.Content
    $contentHash = Get-RocmRollStringHash -Content $normalizedContent

    Set-InstanceManagedFile -Name $InstanceName -Key 'extra_model_paths.yaml' -Info @{
        path          = $InstancePath
        source        = $desired.Source
        sourcePath    = $desired.SourcePath
        sourceHash    = $desired.SourceHash
        contentHash   = $contentHash
        lastAppliedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }

    Write-LogSuccess "Generated extra_model_paths.yaml from $($desired.Source): $InstancePath" -Comp 'RocmRoll.ModelPaths'
    return $InstancePath
}

function Invoke-ApplyExtraModelPaths {
    <#
    .SYNOPSIS
        Mode-aware, drift-safe extra_model_paths.yaml writer.

    .DESCRIPTION
        Install : missing -> create. managed -> replace only with -Force.
                  custom/drifted -> preserve unless -Force.
        Repair  : missing -> create. managed -> always regenerate.
                  custom/drifted -> ask for confirmation (or -Force).
        Update  : missing -> create. managed or custom/drifted -> always
                  preserve; never overwrites an existing file.
        Apply   : missing -> create. managed -> regenerate (the plan/apply
                  engine only calls this for CREATE/UPDATE actions).
                  custom/drifted -> requires -Force (destructive-approval
                  already happened at the plan/apply layer).
    #>
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [ValidateSet('Install', 'Repair', 'Update', 'Apply')]
        [string]$Mode = 'Install',
        [switch]$Force,
        [switch]$WhatIf
    )

    $status       = Get-ExtraModelPathsStatus -InstanceName $InstanceName
    $instancePath = $status.InstancePath

    if ($status.Status -eq 'missing') {
        return Write-RocmRollExtraModelPathsFile -InstanceName $InstanceName -InstancePath $instancePath -WhatIf:$WhatIf
    }

    # 'source-changed' means the on-disk file still matches what ROCmRoll last
    # wrote (only the overlay/template source changed) - safe to auto-refresh.
    # Only 'custom-unknown'/'drifted' mean the on-disk content itself diverged
    # from ROCmRoll's record, which is what actually needs confirmation.
    $isCustomOrDrifted = $status.Status -in @('custom-unknown', 'drifted')

    switch ($Mode) {
        'Update' {
            Write-LogInfo "Preserving existing extra_model_paths.yaml during update: $instancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
            return $instancePath
        }
        'Install' {
            if ($isCustomOrDrifted) {
                if ($Force) {
                    return Write-RocmRollExtraModelPathsFile -InstanceName $InstanceName -InstancePath $instancePath -WhatIf:$WhatIf
                }
                Write-LogWarn "extra_model_paths.yaml exists and is not ROCmRoll-managed ($($status.Status)); preserving. Use --force or 'instance repair --comfyui' to replace it: $instancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
                return $instancePath
            }
            if ($Force) {
                return Write-RocmRollExtraModelPathsFile -InstanceName $InstanceName -InstancePath $instancePath -WhatIf:$WhatIf
            }
            if ($status.Status -eq 'source-changed') {
                Write-LogInfo "extra_model_paths.yaml source changed but existing file preserved (use --force to refresh): $instancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
            } else {
                Write-LogInfo "extra_model_paths.yaml already up to date: $instancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
            }
            return $instancePath
        }
        'Repair' {
            if ($isCustomOrDrifted) {
                if (-not (Invoke-ConfirmExtraModelPathsOverwrite -InstanceName $InstanceName -Status $status -Force:$Force)) {
                    Write-LogWarn "Skipped extra_model_paths.yaml repair; kept existing $($status.Status) file: $instancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
                    return $instancePath
                }
            }
            return Write-RocmRollExtraModelPathsFile -InstanceName $InstanceName -InstancePath $instancePath -WhatIf:$WhatIf
        }
        'Apply' {
            if ($isCustomOrDrifted -and -not $Force) {
                Write-LogWarn "extra_model_paths.yaml is $($status.Status); apply requires approval to replace it. Preserving: $instancePath" -Comp 'RocmRoll.ModelPaths' -Inst $InstanceName
                return $instancePath
            }
            return Write-RocmRollExtraModelPathsFile -InstanceName $InstanceName -InstancePath $instancePath -WhatIf:$WhatIf
        }
    }
}

Export-ModuleMember -Function Get-ExtraModelPathsInstancePath, Get-ExtraModelPathsOverlayPath,
    Get-ExtraModelPathsTemplatePath, Get-ExtraModelPathsDesiredContent, Get-ExtraModelPathsStatus,
    Invoke-ConfirmExtraModelPathsOverwrite, Invoke-ApplyExtraModelPaths
