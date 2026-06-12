#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Locking - File-based process locks with stale detection.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

function Get-LockPath {
    param([string]$LockName)
    Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Config.psm1') -Force -Global
    $cfg = Get-Config
    return Join-Path $cfg.LocksFolder "$LockName.lock"
}

function Test-LockStale {
    param([string]$LockPath, [int]$MaxAgeMinutes = 120)
    if (-not (Test-Path $LockPath)) { return $true }
    try {
        $data = Get-Content $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lockPid = [int]$data.pid
        $age     = (Get-Date) - [datetime]$data.acquiredAt
        if ($age.TotalMinutes -gt $MaxAgeMinutes) { return $true }
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        return ($null -eq $proc)
    } catch {
        return $true
    }
}

function Invoke-AcquireLock {
    param(
        [string]$LockName,
        [switch]$Force,
        [int]$MaxAgeMinutes = 120
    )
    $path = Get-LockPath -LockName $LockName
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (Test-Path $path) {
        if ($Force -or (Test-LockStale -LockPath $path -MaxAgeMinutes $MaxAgeMinutes)) {
            Remove-Item $path -Force
        } else {
            $data = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            throw "ROCMROLL-LOCK-001: Lock '$LockName' is held by PID $($data.pid) since $($data.acquiredAt). Use --force to override stale locks."
        }
    }

    $lockData = @{
        lockName   = $LockName
        pid        = $PID
        acquiredAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        host       = $env:COMPUTERNAME
    }
    Write-RocmRollTextFile -Path $path -Content ($lockData | ConvertTo-Json)
    return $path
}

function Invoke-ReleaseLock {
    param([string]$LockName)
    $path = Get-LockPath -LockName $LockName
    if (Test-Path $path) {
        try {
            $data = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$data.pid -eq $PID) {
                Remove-Item $path -Force
            }
        } catch {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WithLock {
    param(
        [string]$LockName,
        [scriptblock]$ScriptBlock,
        [switch]$Force
    )
    Invoke-AcquireLock -LockName $LockName -Force:$Force | Out-Null
    try {
        & $ScriptBlock
    } finally {
        Invoke-ReleaseLock -LockName $LockName
    }
}

Export-ModuleMember -Function Get-LockPath, Test-LockStale,
    Invoke-AcquireLock, Invoke-ReleaseLock, Invoke-WithLock
