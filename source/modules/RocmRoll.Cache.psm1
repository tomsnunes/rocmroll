#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Cache - Cache management commands: list, verify, clean, prune.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

function Get-CacheSummary {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $result = @{}
    foreach ($folder in @('downloads', 'pip', 'wheelhouse', 'git', 'checksums')) {
        $path = Join-Path $cfg.CacheFolder $folder
        if (Test-Path $path) {
            $items = @(Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue)
            [int64]$totalBytes = 0
            foreach ($item in $items) {
                $totalBytes += $item.Length
            }
            $result[$folder] = @{
                path      = $path
                fileCount = $items.Count
                totalBytes= $totalBytes
            }
        } else {
            $result[$folder] = @{ path=$path; fileCount=0; totalBytes=0 }
        }
    }
    return $result
}

function Remove-PartialDownloads {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $partials = @(Get-ChildItem $cfg.DownloadsFolder -Recurse -Filter '*.partial' -ErrorAction SilentlyContinue)
    foreach ($f in $partials) {
        Remove-Item $f.FullName -Force
        Write-LogInfo "Removed partial: $($f.FullName)" -Comp 'RocmRoll.Cache'
    }
    return $partials.Count
}

function Remove-TempFolder {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    if (Test-Path $cfg.TempFolder) {
        Remove-Item $cfg.TempFolder -Recurse -Force
        New-Item -ItemType Directory -Path $cfg.TempFolder -Force | Out-Null
        Write-LogInfo "Temp folder cleared." -Comp 'RocmRoll.Cache'
    }
}


function Remove-OldCacheFiles {
    param([int]$OlderThanDays = 30)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $count  = 0
    $stale  = @(Get-ChildItem $cfg.DownloadsFolder -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -lt $cutoff })
    foreach ($f in $stale) {
        Remove-Item $f.FullName -Force
        $count++
    }
    Write-LogInfo "Pruned $count file(s) older than $OlderThanDays days." -Comp 'RocmRoll.Cache'
    return $count
}

function Remove-AllCache {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $fileCount = 0

    foreach ($folder in @($cfg.DownloadsFolder, $cfg.PipCacheFolder, $cfg.WheelhouseFolder, $cfg.GitCacheFolder, $cfg.TritonCacheFolder)) {
        if (Test-Path $folder) {
            $fileCount += @(Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue).Count
            Remove-Item $folder -Recurse -Force
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }

    if (Test-Path $cfg.TempFolder) {
        $fileCount += @(Get-ChildItem $cfg.TempFolder -Recurse -File -ErrorAction SilentlyContinue).Count
        Remove-Item $cfg.TempFolder -Recurse -Force
        New-Item -ItemType Directory -Path $cfg.TempFolder -Force | Out-Null
    }

    Write-LogSuccess "All caches cleared ($fileCount file(s) removed)." -Comp 'RocmRoll.Cache'
    return $fileCount
}

function Invoke-CacheVerify {
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    $checks = @()
    $checksumDir = $cfg.ChecksumsFolder
    if (Test-Path $checksumDir) {
        $hashFiles = @(Get-ChildItem $checksumDir -Filter '*.sha256' -ErrorAction SilentlyContinue)
        foreach ($hf in $hashFiles) {
            $targetName = $hf.BaseName
            $expected   = (Get-Content $hf.FullName -Raw).Trim().ToUpper()
            $targetFile = Get-ChildItem $cfg.DownloadsFolder -Recurse -Filter $targetName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $targetFile) {
                $checks += @{ file=$targetName; status='missing' }
                continue
            }
            $actual = (Get-FileHash $targetFile.FullName -Algorithm SHA256).Hash
            $checks += @{ file=$targetName; status=if ($actual -eq $expected) { 'ok' } else { 'mismatch' } }
        }
    }
    return $checks
}

Export-ModuleMember -Function Get-CacheSummary, Remove-PartialDownloads, Remove-TempFolder,
    Remove-OldCacheFiles, Remove-AllCache, Invoke-CacheVerify
