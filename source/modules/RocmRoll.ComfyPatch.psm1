#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.ComfyPatch - Apply, track and remove text patches on ComfyUI instance files.

    ComfyUI patches are stored in source\patches\comfyui\ as individual JSON files.
    Each patch targets files inside the ComfyUI checkout with named operations:
      comment-line  - comment out every line that contains a match string
      comment-block - comment out a function/block starting from a match string
      replace-text  - string replacement across the full file content

    Patch state per instance is stored in .state\patches\comfyui\{instanceName}.json.
    Original files are backed up in .state\patches\comfyui\{instanceName}\{patchId}\ before
    modification, enabling full rollback via Invoke-RemoveComfyPatch.

    This module is separate from the package patch system (RocmRoll.Packages) which
    replaces whole files inside Python site-packages.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:_ComfyPatchDir = $PSScriptRoot
$script:_ComfyCfg      = $null

# ============================================================
# Dependency import
# ============================================================

function Import-ComfyPatchDeps {
    # Do NOT use -Force: forcing a module reload from inside a module scope removes the
    # existing global export (Get-Config, etc.) without reliably restoring it.  Only
    # import modules that are not yet present in the session; they are always pre-loaded
    # by the install flow (Core) or the 'patch' CLI handler in rocmroll.ps1.
    if (-not (Get-Module -Name 'RocmRoll.Config'))   { Import-Module (Join-Path $script:_ComfyPatchDir 'RocmRoll.Config.psm1')   -Global }
    if (-not (Get-Module -Name 'RocmRoll.Logging'))  { Import-Module (Join-Path $script:_ComfyPatchDir 'RocmRoll.Logging.psm1')  -Global }
    if (-not (Get-Module -Name 'RocmRoll.Encoding')) { Import-Module (Join-Path $script:_ComfyPatchDir 'RocmRoll.Encoding.psm1') -Global }
    if (-not (Get-Module -Name 'RocmRoll.State'))    { Import-Module (Join-Path $script:_ComfyPatchDir 'RocmRoll.State.psm1')    -Global }
    # Cache config here while Get-Config is guaranteed in scope (same function as the import).
    $script:_ComfyCfg = Get-Config
}

# ============================================================
# Path helpers
# ============================================================

function Get-ComfyPatchesDir {
    if (-not $script:_ComfyCfg) { Import-ComfyPatchDeps }
    return Join-Path $script:_ComfyCfg.SourceFolder 'patches\comfyui'
}

function Get-ComfyPatchStateDir {
    if (-not $script:_ComfyCfg) { Import-ComfyPatchDeps }
    return Join-Path $script:_ComfyCfg.PatchStateFolder 'comfyui'
}

function Get-ComfyPatchStatePath {
    param([Parameter(Mandatory)][string]$InstanceName)
    return Join-Path (Get-ComfyPatchStateDir) "$InstanceName.json"
}

# ============================================================
# Patch manifest loading
# ============================================================

function Get-ComfyPatchList {
    <#
    .SYNOPSIS
        Returns all ComfyUI patch definitions sorted by filename.
    #>
    Import-ComfyPatchDeps
    $dir = Get-ComfyPatchesDir
    if (-not (Test-Path $dir)) { return @() }
    $patches = @()
    foreach ($f in (Get-ChildItem $dir -Filter '*.json' | Sort-Object Name)) {
        try {
            $patches += (Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch {
            Write-LogWarn "Failed to load patch file '$($f.Name)': $_" -Comp 'RocmRoll.ComfyPatch'
        }
    }
    return $patches
}

function Get-ComfyPatchObject {
    <#
    .SYNOPSIS
        Returns a single patch definition by ID. Throws if not found.
    #>
    param([Parameter(Mandatory)][string]$PatchId)
    Import-ComfyPatchDeps
    $patches = Get-ComfyPatchList
    $patch = $patches | Where-Object { $_.id -eq $PatchId } | Select-Object -First 1
    if (-not $patch) {
        throw "ROCMROLL-CPATCH-001: ComfyUI patch '$PatchId' not found in source/patches/comfyui/"
    }
    return $patch
}

# ============================================================
# Patch state (per-instance applied-patch tracking)
# ============================================================

function Get-ComfyPatchState {
    <#
    .SYNOPSIS
        Reads the applied-patch state for an instance. Returns empty state if not present.
    #>
    param([Parameter(Mandatory)][string]$InstanceName)
    Import-ComfyPatchDeps
    $path = Get-ComfyPatchStatePath -InstanceName $InstanceName
    if (-not (Test-Path $path)) {
        return [PSCustomObject]@{
            type     = 'comfyui-patch-state'
            instance = $InstanceName
            patches  = @()
        }
    }
    try {
        return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-LogWarn "Failed to read patch state for '$InstanceName': $_" -Comp 'RocmRoll.ComfyPatch'
        return [PSCustomObject]@{
            type     = 'comfyui-patch-state'
            instance = $InstanceName
            patches  = @()
        }
    }
}

function Set-ComfyPatchState {
    <#
    .SYNOPSIS
        Writes the applied-patch state for an instance atomically.
    #>
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [Parameter(Mandatory)][object]$State
    )
    Import-ComfyPatchDeps
    $dir = Get-ComfyPatchStateDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Get-ComfyPatchStatePath -InstanceName $InstanceName
    $tmp  = "$path.tmp"
    $json = $State | ConvertTo-Json -Depth 10
    Write-RocmRollTextFile -Path $tmp -Content $json
    Move-Item -Path $tmp -Destination $path -Force
}

# ============================================================
# Architecture applicability check
# ============================================================

function Test-ComfyPatchApplicable {
    <#
    .SYNOPSIS
        Returns $true if the patch's architectures field matches the instance GPU.
        If architectures is the string "all", always returns $true.
    #>
    param(
        [Parameter(Mandatory)][object]$Patch,
        [Parameter(Mandatory)][string]$InstanceName
    )
    Import-ComfyPatchDeps
    $arch = $Patch.architectures
    if ($arch -is [string] -and $arch -eq 'all') {
        return $true
    }

    $instState = Get-InstanceState -Name $InstanceName
    if (-not $instState) {
        Write-LogWarn "Instance state not found for '$InstanceName' - cannot check architecture" -Comp 'RocmRoll.ComfyPatch'
        return $false
    }
    $envState = Get-EnvironmentState -Name ([string]$instState.environment)
    if (-not $envState -or -not $envState.gpu) {
        Write-LogWarn "GPU info not found in environment state for '$($instState.environment)'" -Comp 'RocmRoll.ComfyPatch'
        return $false
    }
    $gfx = [string]$envState.gpu.gfx
    return (@($arch) -contains $gfx)
}

# ============================================================
# File operation handlers
# ============================================================

function Invoke-CommentLine {
    <#
    .SYNOPSIS
        Comments out every line that contains the match string.
        Preserves existing indentation: "    foo()" becomes "    # foo()"
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Match
    )
    $result = [string[]]::new($Lines.Length)
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $line = $Lines[$i]
        if ($line.Contains($Match)) {
            $stripped  = $line.TrimStart()
            $indent    = $line.Length - $stripped.Length
            $result[$i] = $line.Substring(0, $indent) + '# ' + $stripped
        } else {
            $result[$i] = $line
        }
    }
    return $result
}

function Invoke-CommentBlock {
    <#
    .SYNOPSIS
        Comments out a function/block starting from the first line that contains match.
        Comments the match line and all subsequent lines with greater indentation.
        Stops at the first non-blank line that returns to the same or lesser indentation.
        Blank lines within the block are left as-is to preserve readability.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Match
    )
    $result    = [System.Collections.Generic.List[string]]::new()
    $defIndent = -1
    # state: 0=searching  1=inBlock  2=done
    $state     = 0

    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $line = $Lines[$i]
        if ($state -eq 0) {
            if ($line.Contains($Match)) {
                $state     = 1
                $stripped  = $line.TrimStart()
                $defIndent = $line.Length - $stripped.Length
                $result.Add($line.Substring(0, $defIndent) + '# ' + $stripped)
            } else {
                $result.Add($line)
            }
        } elseif ($state -eq 1) {
            if ($line.Trim() -eq '') {
                # blank lines inside function kept as-is
                $result.Add($line)
            } else {
                $stripped      = $line.TrimStart()
                $currentIndent = $line.Length - $stripped.Length
                if ($currentIndent -gt $defIndent) {
                    $result.Add($line.Substring(0, $currentIndent) + '# ' + $stripped)
                } else {
                    # dedented - end of block
                    $state = 2
                    $result.Add($line)
                }
            }
        } else {
            $result.Add($line)
        }
    }

    return ,$result.ToArray()
}

function Invoke-ReplaceText {
    <#
    .SYNOPSIS
        Replaces all occurrences of find with replace in file content.
    #>
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Find,
        [Parameter(Mandatory)][string]$Replace
    )
    return $Content.Replace($Find, $Replace)
}

function Invoke-PatchFileOperation {
    <#
    .SYNOPSIS
        Applies a single operation to a file on disk.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][object]$Operation
    )
    $enc    = New-Object System.Text.UTF8Encoding $false
    $opType = [string]$Operation.type
    switch ($opType) {
        'replace-text' {
            $content    = [System.IO.File]::ReadAllText($TargetPath, $enc)
            $newContent = Invoke-ReplaceText -Content $content -Find ([string]$Operation.find) -Replace ([string]$Operation.replace)
            [System.IO.File]::WriteAllText($TargetPath, $newContent, $enc)
        }
        'comment-line' {
            $lines    = [System.IO.File]::ReadAllLines($TargetPath, $enc)
            $newLines = Invoke-CommentLine -Lines ([string[]]$lines) -Match ([string]$Operation.match)
            [System.IO.File]::WriteAllLines($TargetPath, ([string[]]$newLines), $enc)
        }
        'comment-block' {
            $lines    = [System.IO.File]::ReadAllLines($TargetPath, $enc)
            $newLines = Invoke-CommentBlock -Lines ([string[]]$lines) -Match ([string]$Operation.match)
            [System.IO.File]::WriteAllLines($TargetPath, ([string[]]$newLines), $enc)
        }
        default {
            throw "ROCMROLL-CPATCH-002: Unknown patch operation type '$opType'"
        }
    }
}

# ============================================================
# Apply / Remove
# ============================================================

function Invoke-ApplyComfyPatch {
    <#
    .SYNOPSIS
        Applies a single ComfyUI patch to an instance.
        Backs up each target file before modification.
        Skips if already applied (idempotent). Skips if architecture does not match.
    #>
    param(
        [Parameter(Mandatory)][string]$PatchId,
        [Parameter(Mandatory)][string]$InstanceName
    )
    Import-ComfyPatchDeps

    $patchState = Get-ComfyPatchState -InstanceName $InstanceName
    $alreadyApplied = @($patchState.patches) | Where-Object { $_ -and $_.id -eq $PatchId }
    if ($alreadyApplied) {
        Write-LogInfo "Patch '$PatchId' already applied to '$InstanceName' - skipping" -Comp 'RocmRoll.ComfyPatch'
        return
    }

    $patch = Get-ComfyPatchObject -PatchId $PatchId

    if (-not (Test-ComfyPatchApplicable -Patch $patch -InstanceName $InstanceName)) {
        Write-LogInfo "Patch '$PatchId' is not applicable to '$InstanceName' (architecture mismatch) - skipping" -Comp 'RocmRoll.ComfyPatch'
        return
    }

    $instState = Get-InstanceState -Name $InstanceName
    if (-not $instState) {
        throw "ROCMROLL-CPATCH-003: Instance '$InstanceName' not found"
    }
    $instanceFolder = [string]$instState.path
    $backupRoot     = Join-Path (Get-ComfyPatchStateDir) "$InstanceName\$PatchId"
    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    Write-LogInfo "Applying ComfyUI patch '$PatchId': $($patch.title)" -Comp 'RocmRoll.ComfyPatch' -Op 'ApplyPatch' -Inst $InstanceName

    $patchedFiles = @()
    foreach ($fileSpec in $patch.files) {
        $relativePath = [string]$fileSpec.path
        $targetPath   = Join-Path $instanceFolder ($relativePath -replace '/', '\')

        if (-not (Test-Path $targetPath)) {
            throw "ROCMROLL-CPATCH-004: Target file not found for patch '$PatchId': $targetPath"
        }

        $encodedName = $relativePath -replace '[/\\]', '---'
        $backupPath  = Join-Path $backupRoot $encodedName
        if (-not (Test-Path $backupPath)) {
            Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
            Write-LogInfo "  Backed up: $relativePath" -Comp 'RocmRoll.ComfyPatch'
        }

        foreach ($op in $fileSpec.operations) {
            Write-LogInfo "  [$($op.type)] $relativePath" -Comp 'RocmRoll.ComfyPatch'
            Invoke-PatchFileOperation -TargetPath $targetPath -Operation $op
        }

        $patchedFiles += $relativePath
        Write-LogSuccess "  Patched: $relativePath" -Comp 'RocmRoll.ComfyPatch'
    }

    $existingPatches = @($patchState.patches) | Where-Object { $_ }
    $newEntry = [PSCustomObject]@{
        id        = $PatchId
        version   = [string]$patch.version
        appliedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        files     = $patchedFiles
    }
    $updatedState = [PSCustomObject]@{
        type      = 'comfyui-patch-state'
        instance  = $InstanceName
        updatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        patches   = @($existingPatches) + @($newEntry)
    }
    Set-ComfyPatchState -InstanceName $InstanceName -State $updatedState
    Write-LogSuccess "Patch '$PatchId' applied to '$InstanceName'" -Comp 'RocmRoll.ComfyPatch' -Op 'ApplyPatch' -Inst $InstanceName
}

function Invoke-RemoveComfyPatch {
    <#
    .SYNOPSIS
        Removes a ComfyUI patch by restoring the backed-up originals.
        Warns if patch is not in the applied list.
        Throws if the backup folder is missing.
    #>
    param(
        [Parameter(Mandatory)][string]$PatchId,
        [Parameter(Mandatory)][string]$InstanceName
    )
    Import-ComfyPatchDeps

    $patchState   = Get-ComfyPatchState -InstanceName $InstanceName
    $appliedEntry = @($patchState.patches) | Where-Object { $_ -and $_.id -eq $PatchId } | Select-Object -First 1
    if (-not $appliedEntry) {
        Write-LogWarn "Patch '$PatchId' is not applied to '$InstanceName'" -Comp 'RocmRoll.ComfyPatch'
        return
    }

    $backupRoot = Join-Path (Get-ComfyPatchStateDir) "$InstanceName\$PatchId"
    if (-not (Test-Path $backupRoot)) {
        throw "ROCMROLL-CPATCH-005: Backup folder not found for '$PatchId' on '$InstanceName'. Cannot restore. Suggested: rocmroll repair --instance $InstanceName --component comfyui"
    }

    $instState      = Get-InstanceState -Name $InstanceName
    $instanceFolder = [string]$instState.path

    Write-LogInfo "Removing ComfyUI patch '$PatchId' from '$InstanceName'" -Comp 'RocmRoll.ComfyPatch' -Op 'RemovePatch' -Inst $InstanceName

    foreach ($backupFile in (Get-ChildItem $backupRoot -File)) {
        $relativePath = $backupFile.Name -replace '---', '/'
        $targetPath   = Join-Path $instanceFolder ($relativePath -replace '/', '\')
        $targetDir    = Split-Path $targetPath -Parent
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $backupFile.FullName -Destination $targetPath -Force
        Write-LogSuccess "  Restored: $relativePath" -Comp 'RocmRoll.ComfyPatch'
    }

    $remainingPatches = @($patchState.patches) | Where-Object { $_ -and $_.id -ne $PatchId }
    $updatedState = [PSCustomObject]@{
        type      = 'comfyui-patch-state'
        instance  = $InstanceName
        updatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        patches   = $remainingPatches
    }
    Set-ComfyPatchState -InstanceName $InstanceName -State $updatedState
    Write-LogSuccess "Patch '$PatchId' removed from '$InstanceName'" -Comp 'RocmRoll.ComfyPatch' -Op 'RemovePatch' -Inst $InstanceName
}

function Invoke-ApplyAllComfyPatches {
    <#
    .SYNOPSIS
        Applies all ComfyUI patches to an instance in file order.
        Skips already-applied patches (idempotent) and architecture-mismatched patches.
        Non-fatal: logs warnings on individual patch failures rather than aborting.
    #>
    param([Parameter(Mandatory)][string]$InstanceName)
    Import-ComfyPatchDeps

    $patches = Get-ComfyPatchList
    if (-not $patches -or $patches.Count -eq 0) {
        Write-LogInfo "No ComfyUI patches defined" -Comp 'RocmRoll.ComfyPatch'
        return
    }

    $applied = 0
    foreach ($patch in $patches) {
        try {
            Invoke-ApplyComfyPatch -PatchId $patch.id -InstanceName $InstanceName
            $applied++
        } catch {
            Write-LogWarn "Patch '$($patch.id)' failed and was skipped: $_" -Comp 'RocmRoll.ComfyPatch' -Inst $InstanceName
        }
    }
    Write-LogInfo "ComfyUI patch pass complete ($applied of $($patches.Count) patches processed)" -Comp 'RocmRoll.ComfyPatch' -Inst $InstanceName
}

# ============================================================
# Display
# ============================================================

function Show-ComfyPatchList {
    <#
    .SYNOPSIS
        Without --instance: lists all available patches.
        With --instance: shows applied/pending status for each patch.
    #>
    param([string]$InstanceName = '')
    Import-ComfyPatchDeps

    $patches = Get-ComfyPatchList
    if (-not $patches -or $patches.Count -eq 0) {
        Write-Host "No ComfyUI patches defined in source/patches/comfyui/"
        return
    }

    if ($InstanceName) {
        $patchState = Get-ComfyPatchState -InstanceName $InstanceName
        $appliedIds = @(@($patchState.patches) | Where-Object { $_ } | ForEach-Object { $_.id })
        Write-Host "ComfyUI patches for instance '$InstanceName':" -ForegroundColor Cyan
        Write-Host ''
        foreach ($p in $patches) {
            $isApplied = $appliedIds -contains $p.id
            $status    = if ($isApplied) { '[applied]' } else { '[pending]' }
            $color     = if ($isApplied) { 'Green' }     else { 'Yellow' }
            $arch      = if ($p.architectures -is [string]) { $p.architectures } else { ($p.architectures -join ', ') }
            Write-Host ("  {0,-11} {1}" -f $status, $p.id) -ForegroundColor $color
            Write-Host ("               {0}" -f $p.title)
            Write-Host ("               arch: {0}" -f $arch)
            Write-Host ''
        }
    } else {
        Write-Host "Available ComfyUI patches:" -ForegroundColor Cyan
        Write-Host ''
        foreach ($p in $patches) {
            $arch = if ($p.architectures -is [string]) { $p.architectures } else { ($p.architectures -join ', ') }
            Write-Host ("  {0}" -f $p.id) -ForegroundColor White
            Write-Host ("    {0}" -f $p.title)
            Write-Host ("    arch: {0}" -f $arch)
            Write-Host ("    issue: {0}" -f $p.issue)
            Write-Host ''
        }
    }
}

# ============================================================
# Exports
# ============================================================

Export-ModuleMember -Function `
    Get-ComfyPatchList, Get-ComfyPatchObject, `
    Get-ComfyPatchState, Set-ComfyPatchState, `
    Test-ComfyPatchApplicable, `
    Invoke-CommentLine, Invoke-CommentBlock, Invoke-ReplaceText, `
    Invoke-ApplyComfyPatch, Invoke-RemoveComfyPatch, Invoke-ApplyAllComfyPatches, `
    Show-ComfyPatchList
