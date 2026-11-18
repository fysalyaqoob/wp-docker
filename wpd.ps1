#!/usr/bin/env pwsh
param([Parameter(Position = 0)][string]$Command = 'help', [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Platform', 'Config', 'Docker', 'Infra', 'Doctor') { . (Join-Path $PSScriptRoot "lib/$f.ps1") }

$usage = @'
Usage: wpd <command> [args]
  setup | doctor | resume | new | clone | up | down | list | rm | help
'@

switch ($Command) {
    'setup' { Initialize-Infra }
    'resume' { Resume-PortConflicts }
    'doctor' { if (@(Invoke-Doctor | Where-Object { -not $_.Ok }).Count) { exit 1 } }
    { $_ -in 'new', 'clone', 'up', 'down', 'list', 'rm' } {
        Write-Host "'$Command' is not implemented yet."; exit 1
    }
    'help' { Write-Host $usage }
    default { Write-Host "Unknown command '$Command'."; Write-Host $usage; exit 1 }
}
