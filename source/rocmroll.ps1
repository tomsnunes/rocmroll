#Requires -Version 5.1
<#
.SYNOPSIS
    rocmroll.ps1 - Main CLI entrypoint for ComfyUI ROCmRoll.

.DESCRIPTION
    Bootstraps UTF-8 output, creates a CLI context, initializes configuration and
    logging, then dispatches to command modules.
#>

param(
    [Parameter(Position=0)]
    [string]$Command = 'help',

    [Parameter(Position=1, ValueFromRemainingArguments)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    Write-Warning "Unable to configure UTF-8 console output: $($_.Exception.Message)"
}

$scriptRoot = $PSScriptRoot
$modulesDir = Join-Path $scriptRoot 'modules'

Import-Module (Join-Path $modulesDir 'RocmRoll.Cli.psm1') -Force -Global

$context = New-CliContext -Command $Command -RemainingArgs $RemainingArgs -ScriptRoot $scriptRoot
Initialize-RocmRollCli -Context $context
Invoke-RocmRollCommand -Context $context
