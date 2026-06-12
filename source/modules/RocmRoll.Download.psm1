#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Download - Cached file downloads with checksum verification and resume.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Logging.psm1')

function Get-CachedFilePath {
    param([string]$Url, [string]$DestFolder)
    $filename = Split-Path ([uri]$Url).LocalPath -Leaf
    return Join-Path $DestFolder $filename
}

function Test-FileIntegrity {
    param(
        [string]$FilePath,
        [string]$ExpectedSha256 = '',
        [long]$ExpectedSize     = 0
    )
    if (-not (Test-Path $FilePath)) { return $false }
    if ($ExpectedSize -gt 0) {
        $actual = (Get-Item $FilePath).Length
        if ($actual -ne $ExpectedSize) { return $false }
    }
    if ($ExpectedSha256) {
        $hash = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
        if ($hash.ToUpper() -ne $ExpectedSha256.ToUpper()) { return $false }
    }
    return $true
}

function Invoke-CachedDownload {
    param(
        [string]$Url,
        [string]$DestFolder,
        [string]$ExpectedSha256 = '',
        [long]$ExpectedSize     = 0,
        [switch]$Force
    )

    if (-not (Test-Path $DestFolder)) {
        New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
    }

    $destFile    = Get-CachedFilePath -Url $Url -DestFolder $DestFolder
    $partialFile = "$destFile.partial"

    if (-not $Force -and (Test-Path $destFile)) {
        if (Test-FileIntegrity -FilePath $destFile -ExpectedSha256 $ExpectedSha256 -ExpectedSize $ExpectedSize) {
            Write-LogInfo "Cache hit: $(Split-Path $destFile -Leaf)" -Comp 'RocmRoll.Download'
            return $destFile
        }
        Write-LogWarn "Cached file failed integrity check, redownloading: $destFile" -Comp 'RocmRoll.Download'
        Remove-Item $destFile -Force
    }

    Write-LogInfo "Downloading: $Url" -Comp 'RocmRoll.Download'
    $start = Get-Date
    $response = $null
    $stream = $null
    $fs = $null

    try {
        $wr = [System.Net.HttpWebRequest]::Create($Url)
        $wr.UserAgent = 'ROCmRoll/1.0'

        $resumeFrom = 0
        if (Test-Path $partialFile) {
            $resumeFrom = (Get-Item $partialFile).Length
            if ($resumeFrom -gt 0) {
                $wr.AddRange([long]$resumeFrom)
                Write-LogDebug "Resuming from byte $resumeFrom" -Comp 'RocmRoll.Download'
            }
        }

        $response = $wr.GetResponse()
        $stream   = $response.GetResponseStream()
        $fileMode = if ($resumeFrom -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $fs       = [System.IO.FileStream]::new($partialFile, $fileMode, [System.IO.FileAccess]::Write)

        $buffer = New-Object byte[] 131072
        $read   = 0
        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) { $fs.Write($buffer, 0, $read) }
        } while ($read -gt 0)

        $fs.Close()
        $stream.Close()
        $response.Close()
    } catch {
        if ($null -ne $fs) { $fs.Close() }
        if ($null -ne $stream) { $stream.Close() }
        if ($null -ne $response) { $response.Close() }
        throw "ROCMROLL-DOWNLOAD-001: Failed to download '$Url': $_"
    }

    if (-not (Test-FileIntegrity -FilePath $partialFile -ExpectedSha256 $ExpectedSha256 -ExpectedSize $ExpectedSize)) {
        Remove-Item $partialFile -Force
        throw "ROCMROLL-DOWNLOAD-002: Integrity check failed after download: $Url"
    }

    Move-Item -Path $partialFile -Destination $destFile -Force
    $elapsed = ((Get-Date) - $start).TotalSeconds
    Write-LogSuccess "Downloaded $(Split-Path $destFile -Leaf) in $([math]::Round($elapsed,1))s" -Comp 'RocmRoll.Download'
    return $destFile
}

Export-ModuleMember -Function Get-CachedFilePath, Test-FileIntegrity, Invoke-CachedDownload
