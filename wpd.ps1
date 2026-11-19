#!/usr/bin/env pwsh
param([Parameter(Position = 0)][string]$Command = 'help', [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Platform', 'Config', 'Docker', 'Infra', 'Doctor', 'Site') { . (Join-Path $PSScriptRoot "lib/$f.ps1") }

$usage = @'
Usage: wpd <command> [args]
  setup | doctor | resume | new | clone | up | down | list | rm | help
  new <name> [--php 8.3]   create a WordPress site at https://<name>.test
  up|down <name>           start / stop a site (data is kept)
  list                     show sites and whether they run
  rm <name> [--force]      delete a site (asks first unless --force)
'@

function Read-SiteArgs {
    # Returns @{ Name; Php; Force } from "<name> [--php 8.3] [--force]".
    param([string[]]$Tokens)
    $r = @{ Name = $null; Php = $null; Force = $false }
    $Tokens = @($Tokens | Where-Object { $_ })
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        switch -Regex ($Tokens[$i]) {
            '^--?php$' { $i++; if ($i -ge $Tokens.Count) { throw '--php needs a version, for example --php 8.3.' }; $r.Php = $Tokens[$i] }
            '^--?force$' { $r.Force = $true }
            '^-' { throw "Unknown option '$($Tokens[$i])'." }
            default { if ($r.Name) { throw "Unexpected argument '$($Tokens[$i])'." }; $r.Name = $Tokens[$i] }
        }
    }
    $r
}

function Get-RequiredName {
    param($Parsed, [string]$Verb)
    if (-not $Parsed.Name) { throw "Usage: wpd $Verb <name>" }
    $Parsed.Name
}

switch ($Command) {
    'setup' { Initialize-Infra }
    'resume' { Resume-PortConflicts }
    'doctor' { if (@(Invoke-Doctor | Where-Object { -not $_.Ok }).Count) { exit 1 } }
    'new' {
        $p = Read-SiteArgs $Rest
        $php = if ($p.Php) { $p.Php } else { '8.3' }
        $s = New-WpdSite (Get-RequiredName $p 'new') -Php $php
        Write-Host ''
        Write-Host "Site ready: $($s.Url)"
        Write-Host "Admin login: $($s.AdminUser) / $($s.AdminPassword)"
        Write-Host "Folder: $($s.Path) (credentials in .wpd-credentials.txt)"
    }
    'up' { Start-WpdSite (Get-RequiredName (Read-SiteArgs $Rest) 'up') }
    'down' { Stop-WpdSite (Get-RequiredName (Read-SiteArgs $Rest) 'down') }
    'list' {
        Assert-DockerRunning
        $sites = @(Get-WpdSites)
        if (-not $sites) { Write-Host "No sites yet. Create one with 'wpd new <name>'." }
        else { $sites | Format-Table Name, Url, Running -AutoSize | Out-String | Write-Host }
    }
    'rm' {
        $p = Read-SiteArgs $Rest
        Remove-WpdSite (Get-RequiredName $p 'rm') -Force:$p.Force
    }
    'clone' { Write-Host "'clone' is not implemented yet."; exit 1 }
    'help' { Write-Host $usage }
    default { Write-Host "Unknown command '$Command'."; Write-Host $usage; exit 1 }
}
