#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.Logging - Structured logging with JSONL and console output.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RocmRoll.Encoding.psm1')

$script:LogLevel = 'INFO'
$script:LogFile  = $null
$script:JsonlFile = $null
$script:UseColor  = $true
$script:JsonOnly  = $false
$script:Quiet     = $false

$script:LevelOrder = @{ TRACE=0; DEBUG=1; INFO=2; SUCCESS=3; WARN=4; ERROR=5; FATAL=6 }

$script:LevelColors = @{
    TRACE   = 'DarkGray'
    DEBUG   = 'Gray'
    INFO    = 'Cyan'
    SUCCESS = 'Green'
    WARN    = 'Yellow'
    ERROR   = 'Red'
    FATAL   = 'Magenta'
}

function Initialize-Logging {
    param(
        [string]$Level     = 'INFO',
        [string]$LogFile   = '',
        [string]$JsonlFile = '',
        [switch]$NoColor,
        [switch]$JsonOnly,
        [switch]$Quiet
    )
    $script:LogLevel  = $Level.ToUpper()
    $script:LogFile   = if ($LogFile)   { $LogFile }   else { $null }
    $script:JsonlFile = if ($JsonlFile) { $JsonlFile } else { $null }
    $script:UseColor  = -not $NoColor.IsPresent
    $script:JsonOnly  = $JsonOnly.IsPresent
    $script:Quiet     = $Quiet.IsPresent

    foreach ($f in @($script:LogFile, $script:JsonlFile) | Where-Object { $_ }) {
        $dir = Split-Path $f -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Message,
        [string]$Component  = 'RocmRoll',
        [string]$Operation  = '',
        [string]$Instance   = '',
        [hashtable]$Data    = @{}
    )

    $levelNum    = $script:LevelOrder[$Level]
    $currentNum  = $script:LevelOrder[$script:LogLevel]
    if ($null -eq $levelNum -or $levelNum -lt $currentNum) { return }

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    $entry = [ordered]@{
        timestamp = $timestamp
        level     = $Level
        component = $Component
        operation = $Operation
        instance  = $Instance
        message   = $Message
        data      = $Data
    }

    # JSONL file
    if ($script:JsonlFile) {
        Add-RocmRollTextLine -Path $script:JsonlFile -Line ($entry | ConvertTo-Json -Compress -Depth 6)
    }

    # Human log file
    if ($script:LogFile) {
        Add-RocmRollTextLine -Path $script:LogFile -Line "[$timestamp] [$Level] [$Component] $Message"
    }

    if ($script:Quiet -and $Level -notin @('ERROR','FATAL')) { return }
    if ($script:JsonOnly) { return }

    $color = if ($script:UseColor) { $script:LevelColors[$Level] } else { $null }
    $prefix = "[$Level]".PadRight(9)
    $line   = "$prefix $Message"

    if ($color) {
        Write-Host $line -ForegroundColor $color
    } else {
        Write-Host $line
    }
}

function Write-LogTrace   { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level TRACE   -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }
function Write-LogDebug   { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level DEBUG   -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }
function Write-LogInfo    { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level INFO    -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }
function Write-LogSuccess { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level SUCCESS -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }
function Write-LogWarn    { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level WARN    -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }
function Write-LogError   { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level ERROR   -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }
function Write-LogFatal   { param([string]$Msg,[string]$Comp='RocmRoll',[string]$Op='',[string]$Inst='',[hashtable]$Data=@{}) Write-Log -Level FATAL   -Message $Msg -Component $Comp -Operation $Op -Instance $Inst -Data $Data }

# Lines from pip/git that are worth showing at INFO even without --verbose
$script:ProgressPattern = '(?i)(downloading |installing collected|successfully installed|already satisfied|collecting |resolving |building wheel|cloning into|fetching |error:|warning:|failed |exception)'

function ConvertTo-NativeOutputLine {
    param([object]$Output)

    if ($null -eq $Output) { return '' }

    if ($Output -is [System.Management.Automation.ErrorRecord]) {
        if ($Output.Exception -and $Output.Exception.Message) {
            return [string]$Output.Exception.Message
        }
        if ($null -ne $Output.TargetObject) {
            return [string]$Output.TargetObject
        }
    }

    return [string]$Output
}

function Invoke-LoggedNativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Comp = 'RocmRoll',
        [string]$Op = '',
        [string]$Inst = ''
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $outputLines = [System.Collections.Generic.List[string]]::new()
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = (ConvertTo-NativeOutputLine -Output $_).TrimEnd()
            if (-not $line) { return }
            $outputLines.Add($line)
            if ($line -match $script:ProgressPattern) {
                Write-LogInfo -Msg $line -Comp $Comp -Op $Op -Inst $Inst
            } else {
                Write-LogDebug -Msg $line -Comp $Comp -Op $Op -Inst $Inst
            }
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $tail = if ($outputLines.Count -gt 20) { $outputLines | Select-Object -Last 20 } else { $outputLines }
            foreach ($line in $tail) {
                Write-LogWarn -Msg $line -Comp $Comp -Op $Op -Inst $Inst
            }
        }
        return $exitCode
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

Export-ModuleMember -Function Initialize-Logging, Write-Log,
    Write-LogTrace, Write-LogDebug, Write-LogInfo, Write-LogSuccess,
    Write-LogWarn, Write-LogError, Write-LogFatal, Invoke-LoggedNativeCommand,
    ConvertTo-NativeOutputLine
