function Get-RiskyPlugins {
    param([string]$ListPath = (Join-Path $PSScriptRoot '../templates/risky-plugins.txt'))
    if (-not (Test-Path -LiteralPath $ListPath)) { throw "Risky plugin list not found: $ListPath" }
    @(Get-Content -LiteralPath $ListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Get-UrlReplacements {
    # (old, new) pairs: https://, http:// and protocol-relative forms of the live host and its www/non-www twin,
    # then the same with "/" written as "\/" (JSON in postmeta, block attributes, customizer) and URL-encoded.
    # Limits (accepted): plain text replace, so https://live.com also matches inside https://live.com.au;
    # double-escaped (\/) and other encodings are not covered, the final host check catches leftovers.
    param([Parameter(Mandatory)][string]$OldUrl, [Parameter(Mandatory)][string]$NewUrl)
    $u = $OldUrl.Trim()
    if ($u -notmatch '^(https?:)?//?[a-z0-9.-]+(:\d+)?(/.*)?$') { throw "Invalid live URL '$OldUrl'. Use something like https://www.example.com (letters, digits, dots, hyphens, optional port and path)." }
    $old = $u -replace '^(https?:)?//?', ''
    $slash = $old.IndexOf('/')
    $old = if ($slash -ge 0) { $old.Substring(0, $slash).ToLowerInvariant() + $old.Substring($slash) } else { $old.ToLowerInvariant() }
    $old = $old.TrimEnd('/')
    $new = $NewUrl.TrimEnd('/')
    $newHost = $new -replace '^https?:', ''
    $twin = if ($old -like 'www.*') { $old.Substring(4) } else { "www.$old" }
    $pairs = @()
    foreach ($h in $old, $twin) { $pairs += , @("https://$h", $new); $pairs += , @("http://$h", $new) }
    # Protocol-relative last, so it only catches what the scheme forms left behind.
    foreach ($h in $old, $twin) { $pairs += , @("//$h", $newHost) }
    $plain = $pairs
    foreach ($p in $plain) { $pairs += , @($p[0].Replace('/', '\/'), $p[1].Replace('/', '\/')) }
    foreach ($p in $plain | Where-Object { $_[0] -match '^https?://' }) {
        $pairs += , @([uri]::EscapeDataString($p[0]), [uri]::EscapeDataString($p[1]))
    }
    $pairs
}

function Assert-NoLiveHost {
    # Anti-goal check: no table may still contain the live host (any form: plain, escaped, encoded, host alone).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$OldUrl)
    $h = ($OldUrl.Trim() -replace '^(https?:)?//?', '') -replace '[/:].*$', ''
    $h = ($h.ToLowerInvariant() -replace '^www\.', '')
    $out = @(Invoke-SiteWpCli $Name @('db', 'search', $h, '--all-tables', '--table_column_once', '--one_line', '--before_context=0', '--after_context=0') |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($out) {
        $shown = ($out | Select-Object -First 15) -join "`n  "
        throw "The live host '$h' is still present in the database after URL replacement (forms the tool does not cover). Tables and columns found:`n  $shown"
    }
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
    $cron = (Invoke-SiteWpCli $Name @('eval', '--skip-plugins', '--skip-themes', 'echo (defined("DISABLE_WP_CRON") && DISABLE_WP_CRON) ? "wpd-cron-off" : "wpd-cron-on";') | Out-String)
    if ($cron -notmatch 'wpd-cron-off') { Invoke-SiteWpCli $Name @('config', 'set', 'DISABLE_WP_CRON', 'true', '--raw') | Out-Null }

    $risky = Get-RiskyPlugins
    foreach ($status in 'active', 'active-network') {
        $found = @(Invoke-SiteWpCli $Name @('plugin', 'list', "--status=$status", '--field=name') | ForEach-Object { "$_".Trim() })
        $hit = @($found | Where-Object { $risky -contains $_ })
        if ($hit) {
            $net = if ($status -eq 'active-network') { @('--network') } else { @() }
            Invoke-SiteWpCli $Name (@('plugin', 'deactivate') + $net + $hit) | Out-Null
            Write-Host "Deactivated risky plugins: $($hit -join ', ')"
        }
    }

    # Last, so the safe defaults above are applied even when this throws.
    Assert-NoLiveHost $Name $OldUrl
}
