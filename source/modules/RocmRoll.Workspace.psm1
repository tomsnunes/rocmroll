#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Workspace - Named workspace management.

.DESCRIPTION
    A workspace is a JSON file in the workspaces\ directory that stores a set of path
    overrides applied on top of rocmroll.ini [paths] settings. Workspaces let you maintain
    separate root folders for different disks or purposes (dev, staging, production) and
    switch between them with a single command.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-ActiveWorkspaceName {
    param([hashtable]$Config = $null)
    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }
    if ($Config.Contains('ActiveWorkspace')) { return [string]$Config['ActiveWorkspace'] }
    return ''
}

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

function Get-WorkspaceList {
    param([hashtable]$Config = $null)

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $folder = $Config['WorkspacesFolder']
    $active = Get-ActiveWorkspaceName -Config $Config

    if (-not (Test-Path $folder)) { return @() }

    $result = @()
    foreach ($f in (Get-ChildItem -Path $folder -Filter '*.json' | Sort-Object Name)) {
        try {
            $obj = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $result += [PSCustomObject]@{
                Name        = $f.BaseName
                Description = if ($obj.description) { $obj.description } else { '' }
                IsActive    = ($f.BaseName -ieq $active)
                Object      = $obj
            }
        } catch {
            Write-LogWarn "Skipping malformed workspace file: $($f.Name)" -Comp 'RocmRoll.Workspace'
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Get single workspace object
# ---------------------------------------------------------------------------

function Get-WorkspaceObject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $path = Join-Path $Config['WorkspacesFolder'] "$Name.json"
    if (-not (Test-Path $path)) {
        throw "ROCMROLL-WORKSPACE-001: Workspace '$Name' not found at '$path'. Run 'rocmroll workspace list' to see available workspaces."
    }
    try {
        return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "ROCMROLL-WORKSPACE-002: Failed to parse workspace '$Name': $_"
    }
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

function Show-WorkspaceDetail {
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object]$WorkspaceData,
        [hashtable]$Config = $null
    )

    process {
        if (-not $Config) {
            Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
            $Config = Get-Config
        }

        $activeWs = Get-ActiveWorkspaceName -Config $Config
        $name     = if ($WorkspaceData.name) { $WorkspaceData.name } else { '(unnamed)' }
        $desc     = if ($WorkspaceData.description) { $WorkspaceData.description } else { '' }
        $created  = if ($WorkspaceData.createdAt)   { $WorkspaceData.createdAt }   else { '' }
        $isAct    = $name -ieq $activeWs
        $tag      = if ($isAct) { ' [active]' } else { '' }
        $color    = if ($isAct) { 'Green' } else { 'Cyan' }

        Write-Host ''
        Write-Host "  Workspace   : $name$tag" -ForegroundColor $color
        if ($desc)    { Write-Host "  Description : $desc" }
        if ($created) { Write-Host "  Created     : $created" -ForegroundColor DarkGray }

        if ($WorkspaceData.paths) {
            Write-Host '  Paths:' -ForegroundColor Yellow
            foreach ($kv in $WorkspaceData.paths.PSObject.Properties) {
                Write-Host ("    {0,-14} {1}" -f "$($kv.Name):", $kv.Value) -ForegroundColor Gray
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Set / clear active workspace (modifies [active] section in rocmroll.ini)
# ---------------------------------------------------------------------------

function Set-ActiveWorkspace {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $wsPath = Join-Path $Config['WorkspacesFolder'] "$Name.json"
    if (-not (Test-Path $wsPath)) {
        throw "ROCMROLL-WORKSPACE-003: Workspace '$Name' not found. Run 'rocmroll workspace list' to see available workspaces."
    }

    $iniPath = $Config['ConfigFilePath']
    Write-ActiveSection -IniPath $iniPath -WorkspaceName $Name
    Write-LogInfo "Active workspace set to '$Name'" -Comp 'RocmRoll.Workspace'
}

function Clear-ActiveWorkspace {
    param([hashtable]$Config = $null)

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $iniPath = $Config['ConfigFilePath']
    if (-not (Test-Path $iniPath)) { return }

    $lines    = @(Get-Content $iniPath -Encoding UTF8)
    $filtered = Remove-ActiveSectionLines $lines

    $content  = $filtered -join "`r`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($iniPath, $content, $encoding)

    Write-LogInfo 'Active workspace cleared' -Comp 'RocmRoll.Workspace'
}

function Remove-ActiveSectionLines {
    param([string[]]$Lines)
    $out      = [System.Collections.Generic.List[string]]::new()
    $inActive = $false
    foreach ($line in $Lines) {
        $t = $line.Trim()
        if ($t -match '^\[active\]$') { $inActive = $true;  continue }
        if ($inActive -and $t -match '^\[') { $inActive = $false }
        if (-not $inActive) { $out.Add($line) }
    }
    # Strip trailing blank lines
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') {
        $out.RemoveAt($out.Count - 1)
    }
    return $out
}

function Write-ActiveSection {
    param([string]$IniPath, [string]$WorkspaceName)

    $lines = @()
    if (Test-Path $IniPath) {
        $lines = @(Get-Content $IniPath -Encoding UTF8)
    }

    # Re-wrap into a mutable List: PowerShell unwraps the List<string> returned by
    # Remove-ActiveSectionLines into a fixed-size array when it crosses a function boundary.
    $filtered = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Remove-ActiveSectionLines $lines)) { $filtered.Add($line) }
    $filtered.Add('')
    $filtered.Add('[active]')
    $filtered.Add("workspace = $WorkspaceName")

    $content = $filtered -join "`r`n"
    [System.IO.File]::WriteAllText($IniPath, $content, (New-RocmRollUtf8NoBomEncoding))
}

# ---------------------------------------------------------------------------
# Create / Wizard
# ---------------------------------------------------------------------------

function New-WorkspaceInteractive {
    param(
        [string]$Name      = '',
        [switch]$EditMode,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    Write-Host ''
    if ($EditMode) {
        Write-Host '  ROCmRoll Workspace Editor' -ForegroundColor Cyan
        Write-Host '  -------------------------'
    } else {
        Write-Host '  ROCmRoll Workspace Wizard' -ForegroundColor Cyan
        Write-Host '  -------------------------'
    }

    if (-not $Name) {
        $Name = (Read-Host '  Workspace name (alphanumeric, hyphens)').Trim()
    }
    if (-not $Name -or $Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\-]*$') {
        throw 'ROCMROLL-WORKSPACE-004: Workspace name must start with a letter or digit and contain only letters, digits, and hyphens.'
    }

    $wsFolder = $Config['WorkspacesFolder']
    $destPath = Join-Path $wsFolder "$Name.json"
    $existing = $null
    $createdAt = [DateTime]::Now.ToString('o')

    if (Test-Path $destPath) {
        if (-not $EditMode) {
            $ow = (Read-Host "  Workspace '$Name' already exists. Overwrite? [y/N]").Trim()
            if ($ow -notmatch '^[yY]') { Write-Host '  Cancelled.'; return }
        }
        try { $existing = Get-Content $destPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($existing -and $existing.createdAt) { $createdAt = $existing.createdAt }
    }

    $defaultDesc = if ($existing -and $existing.description) { $existing.description } else { '' }
    $promptDesc  = if ($defaultDesc) { "  Description [$defaultDesc]" } else { '  Description (press Enter to skip)' }
    $inputDesc   = (Read-Host $promptDesc).Trim()
    $description = if ($inputDesc) { $inputDesc } elseif ($defaultDesc) { $defaultDesc } else { '' }

    $pathKeys = @('shared','userdata','instances','environments','runtimes','launchers','profiles','logs','state','cache')
    $pathDefaults = [ordered]@{
        shared       = 'shared'
        userdata     = 'shared\user'
        instances    = 'instances'
        environments = 'environments'
        runtimes     = 'runtimes'
        launchers    = 'launchers'
        profiles     = 'profiles'
        logs         = 'logs'
        state        = '.state'
        cache        = '.cache'
    }

    Write-Host ''
    Write-Host '  -- Path Configuration --' -ForegroundColor Yellow
    Write-Host '  Enter absolute paths (e.g. D:\ai\shared) or press Enter to keep the shown value.' -ForegroundColor DarkGray
    Write-Host ''

    $paths = [ordered]@{}
    foreach ($key in $pathKeys) {
        $existingVal = ''
        if ($existing -and $existing.paths) {
            $prop = $existing.paths.PSObject.Properties[$key]
            if ($prop) { $existingVal = $prop.Value }
        }
        $hint     = if ($existingVal) { $existingVal } else { $pathDefaults[$key] }
        $userInput = (Read-Host "  $($key.PadRight(12)) [$hint]").Trim()
        $chosen    = if ($userInput) { $userInput } elseif ($existingVal) { $existingVal } else { '' }
        if ($chosen) { $paths[$key] = $chosen }
    }

    $wsObj = [ordered]@{
        name        = $Name
        description = $description
        createdAt   = $createdAt
        paths       = $paths
    }

    Save-WorkspaceObject -WorkspaceObj $wsObj -DestPath $destPath -Config $Config

    Write-Host ''
    Write-Host "  Workspace '$Name' saved to: $destPath" -ForegroundColor Green

    if (-not $EditMode) {
        $sw = (Read-Host "  Switch to '$Name' now? [Y/n]").Trim()
        if ($sw -notmatch '^[nN]') {
            Write-ActiveSection -IniPath $Config['ConfigFilePath'] -WorkspaceName $Name
            Write-Host "  Active workspace: $Name" -ForegroundColor Green
            Write-LogInfo "Active workspace set to '$Name'" -Comp 'RocmRoll.Workspace'
        }
    }

    Write-LogSuccess "Workspace '$Name' saved at '$destPath'" -Comp 'RocmRoll.Workspace'
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------

function Remove-Workspace {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force,
        [hashtable]$Config = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    $path = Join-Path $Config['WorkspacesFolder'] "$Name.json"
    if (-not (Test-Path $path)) {
        throw "ROCMROLL-WORKSPACE-001: Workspace '$Name' not found."
    }

    $active   = Get-ActiveWorkspaceName -Config $Config
    $isActive = $Name -ieq $active

    if ($isActive) {
        Write-Host ''
        Write-Host "  Warning: '$Name' is the currently active workspace." -ForegroundColor Yellow
    }

    if (-not $Force) {
        $confirm = (Read-Host "  Remove workspace '$Name'? [y/N]").Trim()
        if ($confirm -notmatch '^[yY]') { Write-Host '  Cancelled.'; return }
    }

    Remove-Item $path -Force

    if ($isActive) {
        Clear-ActiveWorkspace -Config $Config
        Write-Host '  Active workspace cleared.' -ForegroundColor Yellow
    }

    Write-Host "  Workspace '$Name' removed." -ForegroundColor Yellow
    Write-LogInfo "Workspace '$Name' removed" -Comp 'RocmRoll.Workspace'
}

# ---------------------------------------------------------------------------
# Export current resolved paths as a new workspace
# ---------------------------------------------------------------------------

function Export-CurrentAsWorkspace {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [hashtable]$Config   = $null
    )

    if (-not $Config) {
        Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
        $Config = Get-Config
    }

    if (-not $Name -or $Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\-]*$') {
        throw 'ROCMROLL-WORKSPACE-004: Workspace name must start with a letter or digit and contain only letters, digits, and hyphens.'
    }

    $wsFolder = $Config['WorkspacesFolder']
    $destPath = Join-Path $wsFolder "$Name.json"

    if (Test-Path $destPath) {
        throw "ROCMROLL-WORKSPACE-005: Workspace '$Name' already exists at '$destPath'. Use 'rocmroll workspace edit --workspace $Name' to modify it."
    }

    $paths = [ordered]@{
        shared       = $Config['SharedFolder']
        userdata     = $Config['UserDataFolder']
        instances    = $Config['InstancesFolder']
        environments = $Config['EnvironmentsFolder']
        runtimes     = $Config['RuntimesFolder']
        launchers    = $Config['LaunchersFolder']
        profiles     = $Config['ProfilesFolder']
        logs         = $Config['LogsFolder']
        state        = $Config['StateFolder']
        cache        = $Config['CacheFolder']
    }

    $wsObj = [ordered]@{
        name        = $Name
        description = $Description
        createdAt   = [DateTime]::Now.ToString('o')
        paths       = $paths
    }

    Save-WorkspaceObject -WorkspaceObj $wsObj -DestPath $destPath -Config $Config

    Write-Host ''
    Write-Host "  Workspace '$Name' exported to: $destPath" -ForegroundColor Green
    Write-LogSuccess "Current paths exported as workspace '$Name'" -Comp 'RocmRoll.Workspace'
}

function Save-WorkspaceObject {
    param(
        [Parameter(Mandatory)][object]$WorkspaceObj,
        [Parameter(Mandatory)][string]$DestPath,
        [hashtable]$Config
    )

    $wsFolder = $Config['WorkspacesFolder']
    if (-not (Test-Path $wsFolder)) {
        New-Item -ItemType Directory -Path $wsFolder -Force | Out-Null
    }

    $json = Format-RocmRollJson -Data $WorkspaceObj
    [System.IO.File]::WriteAllText($DestPath, $json, (New-RocmRollUtf8NoBomEncoding))
}

Export-ModuleMember -Function `
    Get-WorkspaceList, Get-WorkspaceObject, `
    Show-WorkspaceDetail, `
    New-WorkspaceInteractive, `
    Set-ActiveWorkspace, Clear-ActiveWorkspace, `
    Remove-Workspace, `
    Export-CurrentAsWorkspace
