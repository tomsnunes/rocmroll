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

function Invoke-JsonEscapeString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    ($Value -replace '\\', '\\') -replace '"', '\"' -replace "`r`n", '\n' -replace "`n", '\n' -replace "`t", '\t'
}

function Format-RocmRollJson {
    <#
    .SYNOPSIS
        Serializes any hashtable or PSCustomObject to clean 2-space-indented JSON.
        Bypasses PowerShell 5.1 ConvertTo-Json depth/formatting quirks.
        Supports string values, string arrays, and nested objects.
    #>
    param(
        [Parameter(Mandatory)][object]$Data,
        [int]$Depth = 0
    )

    $p  = '  ' * $Depth
    $pi = '  ' * ($Depth + 1)

    $keys = if ($Data -is [System.Collections.IDictionary]) { @($Data.Keys) }
            else { @($Data.PSObject.Properties.Name) }

    $ln = [System.Collections.Generic.List[string]]::new()
    $ln.Add("${p}{")

    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k     = $keys[$i]
        $v     = if ($Data -is [System.Collections.IDictionary]) { $Data[$k] }
                 else { $Data.PSObject.Properties[$k].Value }
        $ek    = Invoke-JsonEscapeString ([string]$k)
        $comma = if ($i -lt $keys.Count - 1) { ',' } else { '' }

        if ($null -eq $v -or $v -is [string]) {
            $ln.Add("$pi`"$ek`": `"$(Invoke-JsonEscapeString ([string]$v))`"$comma")
        } elseif ($v -is [array] -or $v -is [System.Collections.IList]) {
            $arr = @($v)
            if ($arr.Count -eq 0) {
                $ln.Add("$pi`"$ek`": []$comma")
            } else {
                $ln.Add("$pi`"$ek`": [")
                $pii = '  ' * ($Depth + 2)
                for ($j = 0; $j -lt $arr.Count; $j++) {
                    $ac = if ($j -lt $arr.Count - 1) { ',' } else { '' }
                    $ln.Add("$pii`"$(Invoke-JsonEscapeString ([string]$arr[$j]))`"$ac")
                }
                $ln.Add("$pi]$comma")
            }
        } else {
            $inner = (Format-RocmRollJson -Data $v -Depth ($Depth + 1)) -split "`n"
            $ln.Add("$pi`"$ek`": $($inner[0].TrimStart())")
            for ($j = 1; $j -lt $inner.Count - 1; $j++) {
                $ln.Add($inner[$j])
            }
            $ln.Add($inner[$inner.Count - 1] + $comma)
        }
    }

    $ln.Add("${p}}")
    return $ln -join "`n"
}

Export-ModuleMember -Function ConvertTo-RocmRollCrlfText,
    Write-RocmRollTextFile, Write-RocmRollTextLines, Add-RocmRollTextLine,
    New-RocmRollUtf8NoBomEncoding, Invoke-JsonEscapeString, Format-RocmRollJson
