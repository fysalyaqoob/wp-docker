#!/usr/bin/env pwsh
param([Parameter(Position = 0)][string]$Command = 'help', [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Platform', 'Config', 'Docker', 'Infra', 'Doctor', 'Site', 'Safety', 'CloneSsh', 'Wpress') { . (Join-Path $PSScriptRoot "lib/$f.ps1") }

$usage = @'
Usage: wpd <command> [args]
  setup | doctor | resume | new | clone | up | down | list | rm | help
  new <name> [--php 8.3]   create a WordPress site at https://<name>.test
  up|down <name>           start / stop a site (data is kept)
  list                     show sites and whether they run
  rm <name> [--force]      delete a site (asks first unless --force)
  clone <name> --ssh <user@host|alias> --path </remote/wordpress/folder> [--no-uploads]
                           clone a live site over SSH (key or agent login, remote WP-CLI needed; untested against a real server)
  clone <name> --wpress <file> [--old-url https://live.example.com] [--no-uploads]
                           clone from an All-in-One WP Migration .wpress file (no plugin or license needed)
  clone: live URL replacement is a plain text replace, so https://live.com also rewrites inside https://live.com.au
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

function Read-CloneArgs {
    # Returns @{ Name; Ssh; Path; Wpress; NoUploads } from "<name> --ssh <target> --path <dir> [--no-uploads] | --wpress <file>".
    param([string[]]$Tokens)
    $r = @{ Name = $null; Ssh = $null; Path = $null; Wpress = $null; OldUrl = $null; NoUploads = $false }
    $Tokens = @($Tokens | Where-Object { $_ })
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t -match '^--?(ssh|path|wpress|old-url)$') {
            $i++
            if ($i -ge $Tokens.Count) { throw "$t needs a value." }
            $key = if ($Matches[1] -eq 'old-url') { 'OldUrl' } else { (Get-Culture).TextInfo.ToTitleCase($Matches[1]) }
            $r[$key] = $Tokens[$i]
        }
        elseif ($t -match '^--?no-uploads$') { $r.NoUploads = $true }
        elseif ($t.StartsWith('-')) { throw "Unknown option '$t'." }
        elseif ($r.Name) { throw "Unexpected argument '$t'." }
        else { $r.Name = $t }
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
    'clone' {
        $p = Read-CloneArgs $Rest
        if ($p.Wpress) {
            if (-not $p.Name) { throw 'Usage: wpd clone <name> --wpress <file> [--old-url https://live.example.com] [--no-uploads]' }
            $s = Import-Wpress -Name $p.Name -File $p.Wpress -OldUrl $p.OldUrl -NoUploads:$p.NoUploads
        } else {
        if (-not $p.Name -or -not $p.Ssh -or -not $p.Path) { throw 'Usage: wpd clone <name> --ssh <user@host> --path </remote/wordpress/folder> [--no-uploads]' }
        $s = Import-LiveSite -Name $p.Name -Target $p.Ssh -RemotePath $p.Path -NoUploads:$p.NoUploads
        }
        Write-Host ''
        Write-Host "Clone ready: $($s.Url)"
        Write-Host "Admin login: $($s.AdminUser) / $($s.AdminPassword)"
        Write-Host "Folder: $($s.Path) (credentials in .wpd-credentials.txt)"
    }
    'help' { Write-Host $usage }
    default { Write-Host "Unknown command '$Command'."; Write-Host $usage; exit 1 }
}
