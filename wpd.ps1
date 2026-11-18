#!/usr/bin/env pwsh
param([Parameter(Position = 0)][string]$Command = 'help', [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Platform', 'Config', 'Docker') { . (Join-Path $PSScriptRoot "lib/$f.ps1") }

$usage = @'
Usage: wpd <command> [args]
  setup | doctor | resume | new | clone | up | down | list | rm | help
'@

switch ($Command) {
    { $_ -in 'setup', 'doctor', 'resume', 'new', 'clone', 'up', 'down', 'list', 'rm' } {
        Write-Host "'$Command' is not implemented yet."; exit 1
    }
    'help' { Write-Host $usage }
    default { Write-Host "Unknown command '$Command'."; Write-Host $usage; exit 1 }
}
