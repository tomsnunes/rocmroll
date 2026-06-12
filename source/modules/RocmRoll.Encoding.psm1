#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Encoding - UTF-8 without BOM and CRLF text helpers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RocmRollUtf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

function ConvertTo-RocmRollCrlfText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) {
        $Text = $Text.Substring(1)
    }

    return ([string]$Text -replace "`r`n|`r|`n", "`r`n")
}

function Write-RocmRollTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Content,
        [switch]$CreateDirectory
    )

    if ($CreateDirectory) {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $normalized = ConvertTo-RocmRollCrlfText -Text $Content
    [System.IO.File]::WriteAllText($Path, $normalized, $script:RocmRollUtf8NoBom)
}

function Write-RocmRollTextLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [switch]$CreateDirectory,
        [switch]$NoFinalNewline
    )

    $content = ($Lines | ForEach-Object { ConvertTo-RocmRollCrlfText -Text $_ }) -join "`r`n"
    if (-not $NoFinalNewline -and $Lines.Count -gt 0) {
        $content += "`r`n"
    }

    Write-RocmRollTextFile -Path $Path -Content $content -CreateDirectory:$CreateDirectory
}

function Add-RocmRollTextLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Line,
        [switch]$CreateDirectory
    )

    if ($CreateDirectory) {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $content = (ConvertTo-RocmRollCrlfText -Text $Line) + "`r`n"
    [System.IO.File]::AppendAllText($Path, $content, $script:RocmRollUtf8NoBom)
}

function New-RocmRollUtf8NoBomEncoding {
    return (New-Object System.Text.UTF8Encoding -ArgumentList $false)
}

Export-ModuleMember -Function ConvertTo-RocmRollCrlfText,
    Write-RocmRollTextFile, Write-RocmRollTextLines, Add-RocmRollTextLine,
    New-RocmRollUtf8NoBomEncoding
