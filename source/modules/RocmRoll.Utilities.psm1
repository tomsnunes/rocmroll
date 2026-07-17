#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Utilities - General-purpose filesystem and process helpers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

function Test-PathInsideFolder {
    param(
        [string]$Path,
        [string]$ParentFolder
    )

    if (-not $Path -or -not $ParentFolder) { return $false }

    $resolvedParent = [System.IO.Path]::GetFullPath($ParentFolder).TrimEnd('\')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $resolvedPath.StartsWith("$resolvedParent\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-QuietNativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-SafeGitRepositoryArguments {
    param(
        [string]$RepositoryPath,
        [string[]]$Arguments
    )

    return @('-c', "safe.directory=$RepositoryPath", '-C', $RepositoryPath) + $Arguments
}

function Get-RocmRollStringHash {
    param([AllowNull()][string]$Content)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Content)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return "sha256:$hex"
}

function Get-RocmRollFileHash {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return "sha256:$hex"
}

function Remove-FolderTree {
    param(
        [string]$Path,
        [string]$ParentFolder,
        [string]$Description
    )

    if (-not (Test-Path $Path)) { return }

    if (-not (Test-PathInsideFolder -Path $Path -ParentFolder $ParentFolder)) {
        throw "ROCMROLL-REMOVE-001: Refusing to remove $Description path outside expected folder: $Path"
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        Write-LogWarn "Normal removal failed for $Description. Retrying after ACL reset." -Comp 'RocmRoll'
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Invoke-QuietNativeCommand -FilePath 'icacls.exe' -Arguments @($Path, '/grant', "${currentUser}:(OI)(CI)F", '/T', '/C') | Out-Null

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        Invoke-QuietNativeCommand -FilePath 'takeown.exe' -Arguments @('/F', $Path, '/R', '/D', 'Y') | Out-Null
        Invoke-QuietNativeCommand -FilePath 'icacls.exe' -Arguments @($Path, '/grant', "${currentUser}:(OI)(CI)F", '/T', '/C') | Out-Null
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        throw "ROCMROLL-REMOVE-003: Failed to remove $Description path '$Path'. Run the remove command from an elevated PowerShell session and try again. Last error: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Test-PathInsideFolder, Invoke-QuietNativeCommand,
    Get-SafeGitRepositoryArguments, Remove-FolderTree,
    Get-RocmRollStringHash, Get-RocmRollFileHash
