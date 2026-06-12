#Requires -Version 5.1
<#
.SYNOPSIS
    RocmRoll.UI - Console UX helpers: banners, step indicators, progress.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TotalSteps   = 0
$script:CurrentStep  = 0
$script:UseColor     = $true
$script:StartTime    = $null

function Initialize-UI {
    param(
        [int]$TotalSteps = 9,
        [switch]$NoColor
    )
    $script:TotalSteps  = $TotalSteps
    $script:CurrentStep = 0
    $script:UseColor    = -not $NoColor.IsPresent
    $script:StartTime   = Get-Date
}

function Format-BannerLine {
    param(
        [string]$Text,
        [int]$Width
    )

    $contentWidth = $Width - 4
    if ($Text.Length -gt $contentWidth) {
        $Text = $Text.Substring(0, $contentWidth)
    }

    return '| ' + $Text.PadRight($contentWidth) + ' |'
}

function Write-Banner {
    param(
        [string]$InstanceName = '',
        [string]$Channel      = '',
        [string]$PythonVersion= '',
        [string]$GpuName      = '',
        [string]$GfxFamily    = '',
        [string]$Architecture = ''
    )

    $width = 64
    $border = '+' + ('-' * ($width - 2)) + '+'
    $lines = @(
        $border
        (Format-BannerLine -Text 'ComfyUI ROCmRoll' -Width $width)
        (Format-BannerLine -Text "Instance: $InstanceName" -Width $width)
        (Format-BannerLine -Text "Channel : $Channel" -Width $width)
        (Format-BannerLine -Text "Python  : $PythonVersion" -Width $width)
    )

    if ($GpuName) {
        $lines += Format-BannerLine -Text "GPU     : $GpuName / $GfxFamily / $Architecture" -Width $width
    }

    $lines += $border
    $banner = $lines -join [Environment]::NewLine

    if ($script:UseColor) {
        Write-Host $banner -ForegroundColor Cyan
    } else {
        Write-Host $banner
    }
}

function Write-Step {
    param([string]$Title)
    $script:CurrentStep++
    $label = "[$($script:CurrentStep)/$($script:TotalSteps)] $Title"
    if ($script:UseColor) {
        Write-Host "`n$label" -ForegroundColor White
        Write-Host ('-' * $label.Length) -ForegroundColor DarkGray
    } else {
        Write-Host "`n$label"
        Write-Host ('-' * $label.Length)
    }
}

function Write-StepResult {
    param(
        [string]$Symbol = '[OK]',
        [string]$Message,
        [string]$Color  = 'Green'
    )
    $line = "  $Symbol $Message"
    if ($script:UseColor) {
        Write-Host $line -ForegroundColor $Color
    } else {
        Write-Host $line
    }
}

function Write-StepOk   { param([string]$Msg) Write-StepResult -Symbol '[OK]' -Message $Msg -Color 'Green' }
function Write-StepInfo { param([string]$Msg) Write-StepResult -Symbol '->' -Message $Msg -Color 'Cyan' }
function Write-StepWarn { param([string]$Msg) Write-StepResult -Symbol '[WARN]' -Message $Msg -Color 'Yellow' }
function Write-StepFail { param([string]$Msg) Write-StepResult -Symbol '[FAIL]' -Message $Msg -Color 'Red' }

function Write-Summary {
    $elapsed = ((Get-Date) - $script:StartTime).TotalSeconds
    Write-Host "`nCompleted in $([math]::Round($elapsed,1))s" -ForegroundColor Gray
}

Export-ModuleMember -Function Initialize-UI, Write-Banner, Write-Step,
    Write-StepOk, Write-StepInfo, Write-StepWarn, Write-StepFail, Write-Summary
