BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
    . "$PSScriptRoot/../lib/Infra.ps1"
    . "$PSScriptRoot/../lib/Site.ps1"
    . "$PSScriptRoot/../lib/Safety.ps1"
}

Describe 'Get-RiskyPlugins' {
    It 'skips comments and blank lines and trims' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "risky-$([guid]::NewGuid()).txt"
        try {
            "# comment`n`n  foo  `n   # indented comment`nbar`n" | Set-Content $f
            Get-RiskyPlugins $f | Should -Be @('foo', 'bar')
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
    It 'seed file lists the required plugins and no comment lines' {
        $list = Get-RiskyPlugins (Join-Path $PSScriptRoot '../templates/risky-plugins.txt')
        foreach ($s in 'woocommerce-gateway-stripe', 'wp-mail-smtp', 'mailchimp-for-wp', 'wp-rocket', 'updraftplus') { $list | Should -Contain $s }
        $list | Where-Object { $_ -match '^#|\s' } | Should -BeNullOrEmpty
    }
}

Describe 'Get-UrlReplacements' {
    It 'covers https, http and protocol-relative for host and www twin' {
        $p = @(Get-UrlReplacements 'https://live.example.com/' 'https://acme.test:8443')
        ($p[0..5] | ForEach-Object { "$($_[0]) -> $($_[1])" }) | Should -Be @(
            'https://live.example.com -> https://acme.test:8443', 'http://live.example.com -> https://acme.test:8443',
            'https://www.live.example.com -> https://acme.test:8443', 'http://www.live.example.com -> https://acme.test:8443',
            '//live.example.com -> //acme.test:8443', '//www.live.example.com -> //acme.test:8443')
    }
    It 'strips www to make the twin when the old URL has it' {
        $p = @(Get-UrlReplacements 'http://www.live.example.com' 'https://acme.test')
        ($p | ForEach-Object { $_[0] }) | Should -Contain 'https://live.example.com'
    }
}

Describe 'Get-UrlReplacements (escaped, encoded, validation)' {
    BeforeAll { $script:pairs = @(Get-UrlReplacements 'HTTPS://Live.Example.com/' 'https://acme.test:8443') }
    It 'lowercases the host' { $script:pairs[0][0] | Should -Be 'https://live.example.com' }
    It 'adds JSON-escaped pairs with the slash escaped on both sides' {
        $e = @($script:pairs | Where-Object { $_[0] -like '*\/*' } | ForEach-Object { "$($_[0]) -> $($_[1])" })
        $e.Count | Should -Be 6
        $e | Should -Contain 'https:\/\/live.example.com -> https:\/\/acme.test:8443'
        $e | Should -Contain 'http:\/\/www.live.example.com -> https:\/\/acme.test:8443'
        $e | Should -Contain '\/\/live.example.com -> \/\/acme.test:8443'
    }
    It 'adds URL-encoded https and http pairs for both hosts' {
        $e = @($script:pairs | Where-Object { $_[0] -like '*%2F*' } | ForEach-Object { "$($_[0]) -> $($_[1])" })
        $e.Count | Should -Be 4
        $e | Should -Contain 'https%3A%2F%2Flive.example.com -> https%3A%2F%2Facme.test%3A8443'
    }
    It 'applied in order as real string replaces leaves no live host in any covered form' {
        $s = 'a http://live.example.com/x b https:\/\/www.live.example.com\/y c \/\/live.example.com d https%3A%2F%2Flive.example.com%2Fz e //www.live.example.com/q'
        foreach ($p in $script:pairs) { $s = $s.Replace($p[0], $p[1]) }
        $s | Should -Not -Match 'live\.example'
        $s | Should -Match ([regex]::Escape('https:\/\/acme.test:8443\/y'))
        $s | Should -Match 'https%3A%2F%2Facme.test%3A8443%2Fz'
        $s | Should -Match '//acme.test:8443/q'
    }
    It 'rejects malformed live URLs' {
        foreach ($bad in 'ftp://x.com', 'not a url', 'https://', '//-x.com', 'https://-x.com', 'https://ex ample.com', 'javascript:alert(1)') {
            { Get-UrlReplacements $bad 'https://acme.test' } | Should -Throw '*Invalid live URL*'
        }
    }
    It 'accepts port and path' { { Get-UrlReplacements 'http://Host.com:8080/blog' 'https://acme.test' } | Should -Not -Throw }
}

Describe 'Set-CloneSafety' {
    BeforeEach {
        $script:saved = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTPS_PORT', 'WPD_INFRA_PREFIX') {
            $script:saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null)
        }
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "wpd-safety-$([guid]::NewGuid())"
        $env:WPD_HOME = Join-Path $script:tmp 'home'; $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites'
        New-Item -ItemType Directory (Join-Path $env:WPD_SITES_ROOT 'acme') -Force | Out-Null
        Set-Content (Join-Path $env:WPD_SITES_ROOT 'acme/docker-compose.yml') '# Rendered by wpd'
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:cronOn = $true; $script:active = 'akismet', 'wp-mail-smtp', 'wp-rocket'; $script:network = @(); $script:urlHits = @(); $script:bareHits = @(); $script:failOn = $null
        Mock Invoke-SiteWpCli {
            $script:calls.Add($WpArgs)
            if ($script:failOn -and $WpArgs[0] -eq $script:failOn) { throw 'boom' }
            if ($WpArgs[0] -eq 'eval') { return $(if ($script:cronOn) { 'wpd-cron-off' } else { 'wpd-cron-on' }) }
            if ($WpArgs[0] -eq 'plugin' -and $WpArgs[1] -eq 'list') { return $(if ($WpArgs[2] -eq '--status=active') { $script:active } else { $script:network }) }
            if ($WpArgs[0] -eq 'db' -and $WpArgs[1] -eq 'search') { return $(if ($WpArgs[2] -eq 'live.example.com') { $script:bareHits } else { $script:urlHits }) }
        }
    }
    AfterEach {
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }
    It 'search-replaces every URL form with --all-tables --precise' {
        Set-CloneSafety 'acme' 'https://live.example.com'
        $sr = @($script:calls | Where-Object { $_[0] -eq 'search-replace' })
        $sr.Count | Should -Be 16
        foreach ($a in $sr) { $a | Should -Contain '--all-tables'; $a | Should -Contain '--precise'; $a[2] | Should -Match 'acme\.test' }
        $sr[0][1] | Should -Be 'https://live.example.com'
    }
    It 'discourages search engines and deactivates only installed active risky plugins' {
        Set-CloneSafety 'acme' 'https://live.example.com'
        ($script:calls | Where-Object { $_[0] -eq 'option' } | ForEach-Object { $_ -join ' ' }) | Should -Be 'option update blog_public 0'
        $d = @($script:calls | Where-Object { $_[0] -eq 'plugin' -and $_[1] -eq 'deactivate' })
        $d.Count | Should -Be 1
        $d[0][2..($d[0].Count - 1)] | Should -Be @('wp-mail-smtp', 'wp-rocket')
    }
    It 'does nothing for plugins when none are risky, and never deletes' {
        $script:active = @('akismet')
        Set-CloneSafety 'acme' 'https://live.example.com'
        $script:calls | Where-Object { $_[1] -in 'deactivate', 'delete', 'uninstall' } | Should -BeNullOrEmpty
    }
    It 'only sets DISABLE_WP_CRON when it is not already on' {
        Set-CloneSafety 'acme' 'https://live.example.com'
        $script:calls | Where-Object { $_[0] -eq 'config' } | Should -BeNullOrEmpty
        $script:calls.Clear(); $script:cronOn = $false
        Set-CloneSafety 'acme' 'https://live.example.com'
        ($script:calls | Where-Object { $_[0] -eq 'config' } | ForEach-Object { $_ -join ' ' }) | Should -Be 'config set DISABLE_WP_CRON true --raw'
    }
    It 'restores the wpd mail mu-plugin and is idempotent' {
        $f = Join-Path $env:WPD_SITES_ROOT 'acme/wp-content/mu-plugins/wpd-mail.php'
        Set-CloneSafety 'acme' 'https://live.example.com'
        (Get-Content $f -Raw) | Should -Match 'mailpit'
        Set-Content $f 'tampered'
        Set-CloneSafety 'acme' 'https://live.example.com'
        (Get-Content $f -Raw) | Should -Match 'mailpit'
    }
    It 'throws loudly and stops when search-replace fails' {
        $script:failOn = 'search-replace'
        { Set-CloneSafety 'acme' 'https://live.example.com' } | Should -Throw '*search-replace failed*live URLs*'
        $script:calls | Where-Object { $_[0] -eq 'option' } | Should -BeNullOrEmpty
    }
    It 'deactivates risky network-active plugins with --network' {
        $script:active = @(); $script:network = @('wp-rocket', 'akismet')
        Set-CloneSafety 'acme' 'https://live.example.com'
        ($script:calls | Where-Object { $_[1] -eq 'deactivate' } | ForEach-Object { $_ -join ' ' }) | Should -Be 'plugin deactivate --network wp-rocket'
    }
    It 'searches for URL-shaped forms of the bare host (no www) and then the bare host, and passes when nothing is found' {
        Set-CloneSafety 'acme' 'https://www.Live.example.com/'
        $q = @($script:calls | Where-Object { $_[0] -eq 'db' } | ForEach-Object { $_[2] })
        $q | Should -Be @('//live.example.com', '\/\/live.example.com', '%2F%2Flive.example.com', 'live.example.com')
        $script:calls | Where-Object { $_[0] -eq 'db' } | ForEach-Object { $_ | Should -Contain '--all-tables' }
    }
    It 'throws listing tables when a URL-shaped live host remains, after applying the other defaults' {
        $script:urlHits = @('wp_posts:post_content', 'wp_options:option_value')
        { Set-CloneSafety 'acme' 'https://live.example.com' } | Should -Throw '*still present*wp_posts:post_content*'
        $script:calls | Where-Object { $_[0] -eq 'option' } | Should -Not -BeNullOrEmpty
    }
    It 'only warns (no throw) when the bare host remains, capped at 20 lines' {
        $script:bareHits = 1..25 | ForEach-Object { "wp_users:user_email$_" }
        { Set-CloneSafety 'acme' 'https://live.example.com' -WarningVariable w -WarningAction SilentlyContinue } | Should -Not -Throw
        Set-CloneSafety 'acme' 'https://live.example.com' -WarningVariable w -WarningAction SilentlyContinue
        $w.Count | Should -Be 1
        "$($w[0])" | Should -Match 'email'
        "$($w[0])" | Should -Match 'and 5 more'
        "$($w[0])" | Should -Not -Match 'user_email21'
    }
    It 'checks cron with plugins and themes skipped' {
        Set-CloneSafety 'acme' 'https://live.example.com'
        $script:calls | Where-Object { $_[0] -eq 'eval' } | ForEach-Object { $_ | Should -Contain '--skip-plugins'; $_ | Should -Contain '--skip-themes' }
    }
    It 'seed list includes premium variants' {
        $l = Get-RiskyPlugins
        foreach ($s in 'wp-mail-smtp-pro', 'mc4wp-premium', 'woocommerce-payments', 'klaviyo', 'jetpack') { $l | Should -Contain $s }
    }
    It 'rejects an unknown site' {
        { Set-CloneSafety 'nope' 'https://live.example.com' } | Should -Throw '*No site named*'
    }
}

# Opt-in: set WPD_INTEGRATION=1. Alternate ports and prefix, never touches 80/443/53 or Laragon.
Describe 'Clone safety integration (real Docker, alternate ports)' -Tag Integration -Skip:(-not $env:WPD_INTEGRATION) {
    BeforeAll {
        $script:keep = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:keep[$n] = [Environment]::GetEnvironmentVariable($n)
        }
        $base = if ($env:WPD_INT_BASE) { $env:WPD_INT_BASE } else { [IO.Path]::GetTempPath() }
        $script:tmp = Join-Path $base "wpd safety int $([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory $script:tmp -Force | Out-Null
        $env:WPD_HOME = Join-Path $script:tmp 'home'
        $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites'
        $env:WPD_HTTP_PORT = '8080'; $env:WPD_HTTPS_PORT = '8443'; $env:WPD_DNS_PORT = '5354'; $env:WPD_INFRA_PREFIX = 'wpdtest'
    }
    AfterAll {
        foreach ($proj in 'wpdtest-safe') {
            $f = "label=com.docker.compose.project=$proj"
            $c = & docker ps -a -q --filter $f; if ($c) { & docker rm -f -v @c *> $null }
            $v = & docker volume ls -q --filter $f; if ($v) { & docker volume rm -f @v *> $null }
            $n = & docker network ls -q --filter $f; if ($n) { & docker network rm @n *> $null }
        }
        foreach ($c in 'wpdtest-traefik', 'wpdtest-dns') { & docker rm -f $c *> $null }
        & docker network rm wpdtest-net wpdtest_default *> $null
        & docker rmi wpdtest-dns:local *> $null
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:keep.Keys) { [Environment]::SetEnvironmentVariable($n, $script:keep[$n]) }
    }
    It 'replaces live URLs everywhere (serialized data intact), discourages indexing, deactivates risky plugins' {
        Initialize-Infra
        New-WpdSite 'safe' | Out-Null
        $plug = Join-Path $env:WPD_SITES_ROOT 'safe/wp-content/plugins'
        foreach ($s in 'wp-mail-smtp', 'harmless-one') {
            New-Item -ItemType Directory (Join-Path $plug $s) | Out-Null
            Set-Content (Join-Path $plug "$s/$s.php") "<?php`n/* Plugin Name: $s */"
        }
        Invoke-SiteWpCli 'safe' @('plugin', 'activate', 'wp-mail-smtp', 'harmless-one') | Out-Null
        $live = 'live.example.com'
        $ser = "a:2:{s:1:`"a`";s:$(('https://' + $live + '/x').Length):`"https://$live/x`";s:1:`"b`";a:1:{i:0;s:$(('//www.' + $live).Length):`"//www.$live`";}}"
        Invoke-SiteWpCli 'safe' @('option', 'update', 'wpd_plain', "http://$live and https://www.$live/p and //$live/q") | Out-Null
        Invoke-SiteWpCli 'safe' @('eval', "update_option('wpd_ser', unserialize('$ser'));") | Out-Null

        $php = '$id = wp_insert_post(["post_title"=>"t","post_status"=>"publish"]); $j = json_encode(["u"=>"https://live.example.com/a.jpg","w"=>"http://www.live.example.com/b","r"=>"//live.example.com/c"]); update_post_meta($id, "_elementor_data", $j); update_option("wpd_json", $j); update_option("wpd_jsonser", ["k"=>$j, "n"=>[1,2]]); echo $id;'
        Invoke-SiteWpCli 'safe' @('eval', $php) | Out-Null

        Invoke-SiteWpCli 'safe' @('option', 'update', 'admin_email', "info@$live") | Out-Null
        Invoke-SiteWpCli 'safe' @('user', 'update', '1', "--user_email=info@$live") | Out-Null

        Set-CloneSafety 'safe' "https://$live" -WarningVariable warn -WarningAction SilentlyContinue
        "$warn" | Should -Match 'user_email|admin_email|wp_users|wp_options'
        "$warn" | Should -Match 'email'

        $chk = '$p = get_posts(["numberposts"=>1,"post_status"=>"publish","orderby"=>"ID","order"=>"DESC"])[0]; $m = get_post_meta($p->ID, "_elementor_data", true); $o = get_option("wpd_jsonser"); echo json_encode([json_decode($m, true)["u"], json_decode(get_option("wpd_json"), true)["w"], json_decode($o["k"], true)["r"], is_array($o) && $o["n"] === [1,2], strpos($m . get_option("wpd_json") . $o["k"], "live.example") === false]);'
        $r = (Invoke-SiteWpCli 'safe' @('eval', $chk)) -join '' | ConvertFrom-Json
        $r[0] | Should -Be 'https://safe.test:8443/a.jpg'
        $r[1] | Should -Be 'https://safe.test:8443/b'
        $r[2] | Should -Be '//safe.test:8443/c'
        $r[3] | Should -BeTrue
        $r[4] | Should -BeTrue

        (Invoke-SiteWpCli 'safe' @('option', 'get', 'wpd_plain')) -join '' | Should -Not -Match 'live\.example'
        $out = (Invoke-SiteWpCli 'safe' @('eval', '$v = get_option("wpd_ser"); echo is_array($v) ? "ok:" . $v["a"] . "|" . $v["b"][0] : "BROKEN"; echo "|" . strlen($v["a"]);')) -join ''
        $out | Should -Match '^ok:https://safe\.test:8443/x\|//safe\.test:8443\|\d+$'
        $out | Should -Not -Match 'live\.example'
        (Invoke-SiteWpCli 'safe' @('option', 'get', 'blog_public')) -join '' | Should -Be '0'
        $active = @(Invoke-SiteWpCli 'safe' @('plugin', 'list', '--status=active', '--field=name'))
        $active | Should -Not -Contain 'wp-mail-smtp'
        $active | Should -Contain 'harmless-one'
        Test-Path (Join-Path $plug 'wp-mail-smtp') | Should -BeTrue
    }
    It 'throws and names the table when a URL-shaped live host survives (upper-case scheme and host: the replacements are case-sensitive)' {
        Invoke-SiteWpCli 'safe' @('option', 'update', 'wpd_upper', 'see HTTPS://LIVE.EXAMPLE.COM/x') | Out-Null
        { Set-CloneSafety 'safe' 'https://live.example.com' -WarningAction SilentlyContinue } | Should -Throw '*still present*wp_options*'
        Invoke-SiteWpCli 'safe' @('option', 'delete', 'wpd_upper') | Out-Null
        { Set-CloneSafety 'safe' 'https://live.example.com' -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}
