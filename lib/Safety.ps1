function Get-RiskyPlugins {
    param([string]$ListPath = (Join-Path $PSScriptRoot '../templates/risky-plugins.txt'))
    if (-not (Test-Path -LiteralPath $ListPath)) { throw "Risky plugin list not found: $ListPath" }
    @(Get-Content -LiteralPath $ListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Get-UrlReplacements {
    # (old, new) pairs for https://, http:// and protocol-relative forms of the live host and its www/non-www twin.
    param([Parameter(Mandatory)][string]$OldUrl, [Parameter(Mandatory)][string]$NewUrl)
    $old = ($OldUrl.Trim() -replace '^(https?:)?//', '').TrimEnd('/')
    if (-not $old -or $old -match '\s') { throw "Invalid live URL '$OldUrl'." }
    $new = $NewUrl.TrimEnd('/')
    $newHost = $new -replace '^https?:', ''
    $twin = if ($old -like 'www.*') { $old.Substring(4) } else { "www.$old" }
    $pairs = @()
    foreach ($h in $old, $twin) { $pairs += , @("https://$h", $new); $pairs += , @("http://$h", $new) }
    # Protocol-relative last, so it only catches what the scheme forms left behind.
    foreach ($h in $old, $twin) { $pairs += , @("//$h", $newHost) }
    $pairs
}

function Set-CloneSafety {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$OldUrl)
    Assert-SiteExists $Name
    $dir = Join-Path (Get-WpdConfig).SitesRoot $Name

    # Mail routing lives in a wpd-owned mu-plugin; an import may have replaced wp-content, so put it back.
    $mu = Join-Path $dir 'wp-content/mu-plugins'
    New-Item -ItemType Directory $mu -Force | Out-Null
    Copy-Item (Get-SiteTemplate 'wpd-mail.php') (Join-Path $mu 'wpd-mail.php') -Force

    foreach ($p in Get-UrlReplacements $OldUrl (Get-SiteUrl $Name)) {
        try { Invoke-SiteWpCli $Name @('search-replace', $p[0], $p[1], '--all-tables', '--precise', '--skip-plugins', '--skip-themes') | Out-Null }
        catch { throw "URL search-replace failed for '$($p[0])'; the clone still contains live URLs. Fix the problem and run it again. $($_.Exception.Message)" }
    }

    Invoke-SiteWpCli $Name @('option', 'update', 'blog_public', '0') | Out-Null

    # DISABLE_WP_CRON normally comes from the compose env, but an imported wp-config.php would not carry it.
    $cron = (Invoke-SiteWpCli $Name @('eval', 'echo (defined("DISABLE_WP_CRON") && DISABLE_WP_CRON) ? "wpd-cron-off" : "wpd-cron-on";') | Out-String)
    if ($cron -notmatch 'wpd-cron-off') { Invoke-SiteWpCli $Name @('config', 'set', 'DISABLE_WP_CRON', 'true', '--raw') | Out-Null }

    $risky = Get-RiskyPlugins
    $active = @(Invoke-SiteWpCli $Name @('plugin', 'list', '--status=active', '--field=name') | ForEach-Object { "$_".Trim() })
    $hit = @($active | Where-Object { $risky -contains $_ })
    if ($hit) {
        Invoke-SiteWpCli $Name (@('plugin', 'deactivate') + $hit) | Out-Null
        Write-Host "Deactivated risky plugins: $($hit -join ', ')"
    }
}
