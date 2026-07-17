#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.YamlLite - Minimal YAML subset reader for declarative instance
    definitions.

.DESCRIPTION
    PowerShell 5.1 has no built-in YAML support, and the project avoids
    external module dependencies, so this implements only the subset the
    ComfyUIInstance schema needs: nested block mappings of scalar values
    (strings/booleans/null), '#' comments, and blank lines.

    NOT supported (by design, not needed by the schema): YAML lists/flow
    style ({}/[]), anchors/aliases, multi-document files, and tab
    indentation. Any of these raise a clear ROCMROLL-YAML error rather than
    silently mis-parsing.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-YamlLiteScalar {
    param([AllowNull()][string]$Raw)

    if ($null -eq $Raw) { return $null }
    $value = $Raw.Trim()
    if ($value.Length -eq 0) { return $null }

    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        return $value.Substring(1, $value.Length - 2)
    }
    if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
        return $value.Substring(1, $value.Length - 2)
    }

    $hashIndex = $value.IndexOf(' #')
    if ($hashIndex -ge 0) { $value = $value.Substring(0, $hashIndex).TrimEnd() }
    if ($value.Length -eq 0) { return $null }

    switch ($value.ToLowerInvariant()) {
        'true'  { return $true }
        'false' { return $false }
        'null'  { return $null }
        '~'     { return $null }
        default { return $value }
    }
}

function ConvertFrom-YamlLite {
    <#
    .SYNOPSIS
        Parses a YAML-lite document into nested [ordered] hashtables.

    .PARAMETER Content
        Raw YAML text. Use this or -Path.

    .PARAMETER Path
        File to read (UTF-8). Use this or -Content.
    #>
    param(
        [string]$Content,
        [string]$Path
    )

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "ROCMROLL-YAML-001: File not found: $Path"
        }
        $Content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }
    if ($null -eq $Content) { $Content = '' }

    $rawLines = $Content -split "`r`n|`r|`n"
    $entries = New-Object System.Collections.Generic.List[object]

    for ($lineNumber = 0; $lineNumber -lt $rawLines.Count; $lineNumber++) {
        $line = $rawLines[$lineNumber]
        if ($line -match '^\s*$') { continue }
        $trimmedStart = $line.TrimStart(' ')
        if ($trimmedStart.StartsWith('#')) { continue }
        if ($line -match "`t") {
            throw "ROCMROLL-YAML-002: Tab indentation is not supported (line $($lineNumber + 1)). Use spaces."
        }
        if ($trimmedStart.StartsWith('- ') -or $trimmedStart -eq '-') {
            throw "ROCMROLL-YAML-003: YAML lists are not supported by this parser (line $($lineNumber + 1))."
        }
        if ($trimmedStart.StartsWith('{') -or $trimmedStart.StartsWith('[')) {
            throw "ROCMROLL-YAML-004: YAML flow style ({}/[]) is not supported by this parser (line $($lineNumber + 1))."
        }

        $indent = $line.Length - $trimmedStart.Length
        if (-not ($trimmedStart -match '^(?<key>[A-Za-z0-9_.\-]+):(?:\s(?<value>.*))?$')) {
            throw "ROCMROLL-YAML-005: Could not parse line $($lineNumber + 1): '$line'"
        }

        $entries.Add([pscustomobject]@{
            Indent = $indent
            Key    = $Matches['key']
            Value  = if ($Matches.ContainsKey('value')) { $Matches['value'] } else { '' }
            Line   = $lineNumber + 1
        }) | Out-Null
    }

    $root  = [ordered]@{}
    $stack = New-Object System.Collections.Generic.List[object]
    $stack.Add([pscustomobject]@{ Indent = -1; Node = $root }) | Out-Null

    foreach ($entry in $entries) {
        while ($stack.Count -gt 1 -and $entry.Indent -le $stack[$stack.Count - 1].Indent) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $parentFrame = $stack[$stack.Count - 1]
        if ($entry.Indent -le $parentFrame.Indent) {
            throw "ROCMROLL-YAML-006: Inconsistent indentation at line $($entry.Line): '$($entry.Key)'"
        }
        $parent = $parentFrame.Node

        $scalarValue = Convert-YamlLiteScalar -Raw $entry.Value
        if ($null -eq $scalarValue -and [string]::IsNullOrWhiteSpace($entry.Value)) {
            $child = [ordered]@{}
            $parent[$entry.Key] = $child
            $stack.Add([pscustomobject]@{ Indent = $entry.Indent; Node = $child }) | Out-Null
        } else {
            $parent[$entry.Key] = $scalarValue
        }
    }

    return $root
}

function Get-YamlLiteValue {
    <#
    .SYNOPSIS
        Walks a dotted path (e.g. 'spec.modelPaths.preserveOnUpdate') through
        nested YamlLite output. Returns $null if any segment is missing.
    #>
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Path
    )

    $current = $Node
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary] -and $current.Contains($segment)) {
            $current = $current[$segment]
        } else {
            return $null
        }
    }
    return $current
}

Export-ModuleMember -Function ConvertFrom-YamlLite, Get-YamlLiteValue
