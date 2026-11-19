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
        ($p | ForEach-Object { "$($_[0]) -> $($_[1])" }) | Should -Be @(
            'https://live.example.com -> https://acme.test:8443', 'http://live.example.com -> https://acme.test:8443',
            'https://www.live.example.com -> https://acme.test:8443', 'http://www.live.example.com -> https://acme.test:8443',
            '//live.example.com -> //acme.test:8443', '//www.live.example.com -> //acme.test:8443')
    }
    It 'strips www to make the twin when the old URL has it' {
        $p = @(Get-UrlReplacements 'http://www.live.example.com' 'https://acme.test')
        ($p | ForEach-Object { $_[0] }) | Should -Contain 'https://live.example.com'
    }
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
        $script:cronOn = $true; $script:active = 'akismet', 'wp-mail-smtp', 'wp-rocket'; $script:failOn = $null
        Mock Invoke-SiteWpCli {
            $script:calls.Add($WpArgs)
            if ($script:failOn -and $WpArgs[0] -eq $script:failOn) { throw 'boom' }
            if ($WpArgs[0] -eq 'eval') { return $(if ($script:cronOn) { 'wpd-cron-off' } else { 'wpd-cron-on' }) }
            if ($WpArgs[0] -eq 'plugin' -and $WpArgs[1] -eq 'list') { return $script:active }
        }
    }
    AfterEach {
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }
    It 'search-replaces every URL form with --all-tables --precise' {
        Set-CloneSafety 'acme' 'https://live.example.com'
        $sr = @($script:calls | Where-Object { $_[0] -eq 'search-replace' })
        $sr.Count | Should -Be 6
        foreach ($a in $sr) { $a | Should -Contain '--all-tables'; $a | Should -Contain '--precise'; $a[2] | Should -Match '^(https://acme\.test|//acme\.test)$' }
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

        Set-CloneSafety 'safe' "https://$live"

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
}
