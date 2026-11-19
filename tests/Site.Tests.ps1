BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
    . "$PSScriptRoot/../lib/Infra.ps1"
    . "$PSScriptRoot/../lib/Site.ps1"
}

Describe 'Format-SiteCompose' {
    BeforeAll {
        $script:out = Format-SiteCompose @{ Name = 'acme'; Tld = 'test'; Php = '8.2'; DbPassword = 'Pw12345' }
    }
    It 'routes the site host through Traefik' {
        $script:out | Should -Match ([regex]::Escape('Host(`acme.test`)'))
        $script:out | Should -Match ([regex]::Escape('Host(`mail.acme.test`)'))
    }
    It 'bind-mounts only the code folders from the site folder' {
        foreach ($d in 'themes', 'plugins', 'mu-plugins') {
            $script:out | Should -Match ([regex]::Escape("./wp-content/${d}:/var/www/html/wp-content/$d"))
        }
        $script:out | Should -Not -Match '\./wp-content:'
        $script:out | Should -Not -Match '(?m)^\s+- \.:'
    }
    It 'keeps core and uploads in named volumes' {
        $script:out | Should -Match '(?m)^\s+- core:/var/www/html$'
        $script:out | Should -Match '(?m)^\s+- uploads:/var/www/html/wp-content/uploads$'
    }
    It 'uses the chosen PHP tag' {
        $script:out | Should -Match 'wordpress:php8\.2-apache'
        (Format-SiteCompose @{ Name = 'acme'; Tld = 'test'; Php = '8.4'; DbPassword = 'x' }) | Should -Match 'wordpress:php8\.4-apache'
    }
    It 'sets the WordPress constants' {
        $script:out | Should -Match "WP_HOME', 'https://acme.test'"
        $script:out | Should -Match "WP_ENVIRONMENT_TYPE', 'local'"
        $script:out | Should -Match "DISABLE_WP_CRON', true"
        $script:out | Should -Not -Match '\{\{'
    }
    It 'puts a non-default HTTPS port in the URL and the redirect' {
        $o = Format-SiteCompose @{ Name = 'acme'; Tld = 'test'; Php = '8.3'; DbPassword = 'x'; HttpsPort = 8443 }
        $o | Should -Match "WP_HOME', 'https://acme.test:8443'"
        $o | Should -Match 'redirectscheme.port=8443'
    }
    It 'throws when a required variable is missing' {
        { Format-SiteCompose @{ Name = 'acme'; Tld = 'test'; Php = '8.3' } } | Should -Throw '*DbPassword*'
    }
}

Describe 'site lifecycle (unit, Docker and mkcert mocked)' {
    BeforeEach {
        $script:saved = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:saved[$n] = [Environment]::GetEnvironmentVariable($n)
            [Environment]::SetEnvironmentVariable($n, $null)
        }
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "wpd-site-$([guid]::NewGuid())"
        New-Item -ItemType Directory $script:tmp | Out-Null
        $env:WPD_HOME = Join-Path $script:tmp 'home'
        $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites with space'
        $env:WPD_INFRA_PREFIX = 'wpdtest'
        New-Item -ItemType Directory $env:WPD_SITES_ROOT | Out-Null
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:failOn = $null
        $script:psOutput = @()
        Mock Assert-DockerRunning {}
        Mock Start-Sleep {}
        Mock Get-MkcertPath { 'mkcert-stub' }
        Mock New-MkcertCertificate {
            Set-Content -LiteralPath $CertFile -Value 'CERT'; Set-Content -LiteralPath $KeyFile -Value 'KEY'
            $script:certHosts = $Hosts
        }
        Mock Invoke-Docker {
            $a = $DockerArgs -join ' '
            $script:calls.Add($a)
            if ($script:failOn -and $a -like $script:failOn) { throw 'simulated docker failure' }
            if ($a -like 'network ls*') { return 'wpdtest-net' }
            if ($a -like 'ps -a -q*' -or $a -like 'ps -q*') { return $script:psOutput }
            @()
        }
    }
    AfterEach {
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }

    Context 'New-WpdSite' {
        It 'creates folder, certs, credentials and returns the documented shape' {
            $r = New-WpdSite smoke -Php 8.2
            $r.Name | Should -Be 'smoke'
            $r.Url | Should -Be 'https://smoke.test'
            $r.Path | Should -Be (Join-Path $env:WPD_SITES_ROOT 'smoke')
            $r.AdminUser | Should -Be 'admin'
            $r.AdminPassword.Length | Should -BeGreaterOrEqual 20
            foreach ($f in 'docker-compose.yml', 'php.ini', '.gitignore', '.wpd-credentials.txt',
                'wp-content/themes', 'wp-content/plugins', 'wp-content/mu-plugins', 'wp-content/mu-plugins/wpd-mail.php') {
                Test-Path (Join-Path $r.Path $f) | Should -BeTrue -Because $f
            }
            (Get-Content (Join-Path $r.Path '.gitignore') -Raw) | Should -Match '\.wpd-credentials\.txt'
            $cred = Get-Content (Join-Path $r.Path '.wpd-credentials.txt') -Raw
            $cred | Should -Match ([regex]::Escape($r.AdminPassword))
            $compose = Get-Content (Join-Path $r.Path 'docker-compose.yml') -Raw
            $dbPw = [regex]::Match($cred, 'DB password:\s*(\S+)').Groups[1].Value
            $dbPw.Length | Should -BeGreaterOrEqual 20
            $dbPw | Should -Not -Be $r.AdminPassword
            $compose | Should -Match ([regex]::Escape($dbPw))
            $script:certHosts | Should -Be @('smoke.test', 'mail.smoke.test')
            $dyn = Get-Content (Join-Path $env:WPD_HOME 'infra/dynamic/smoke.yml') -Raw
            $dyn | Should -Match 'certFile: /certs/smoke\.pem'
            $dyn | Should -Match 'keyFile: /certs/smoke-key\.pem'
            Test-Path (Join-Path $env:WPD_HOME 'infra/certs/smoke.pem') | Should -BeTrue
        }
        It 'reloads Traefik after writing the certificate (its file watcher misses host writes)' {
            New-WpdSite smoke
            ($script:calls | Where-Object { $_ -eq 'restart wpdtest-traefik' }) | Should -HaveCount 1
        }
        It 'never prints the DB password' {
            $out = New-WpdSite smoke 6>&1 5>&1 4>&1 3>&1 | Out-String
            $cred = Get-Content (Join-Path $env:WPD_SITES_ROOT 'smoke/.wpd-credentials.txt') -Raw
            $dbPw = [regex]::Match($cred, 'DB password:\s*(\S+)').Groups[1].Value
            $out | Should -Not -Match ([regex]::Escape($dbPw))
        }
        It 'refuses an existing folder and changes nothing' {
            $dir = Join-Path $env:WPD_SITES_ROOT 'acme'
            New-Item -ItemType Directory $dir | Out-Null
            Set-Content (Join-Path $dir 'keep.txt') 'mine'
            { New-WpdSite acme } | Should -Throw '*already exists*'
            (Get-ChildItem $dir -Force).Count | Should -Be 1
            (Get-Content (Join-Path $dir 'keep.txt')) | Should -Be 'mine'
            Test-Path (Join-Path $env:WPD_HOME 'infra') | Should -BeFalse
            ($script:calls | Where-Object { $_ -match '^(compose|rm|volume rm)' }) | Should -BeNullOrEmpty
        }
        It 'refuses when containers of that site already exist' {
            $script:psOutput = @('abc123')
            { New-WpdSite acme } | Should -Throw '*already exist*'
            Test-Path (Join-Path $env:WPD_SITES_ROOT 'acme') | Should -BeFalse
            ($script:calls | Where-Object { $_ -match '^(compose|rm |volume rm)' }) | Should -BeNullOrEmpty
        }
        It 'rejects bad names and bad PHP versions before touching anything' {
            { New-WpdSite 'Bad Name' } | Should -Throw '*Invalid site name*'
            { New-WpdSite acme -Php '8.3; rm' } | Should -Throw '*PHP*'
            $script:calls.Count | Should -Be 0
        }
        It 'tells you to run wpd setup when the network is missing' {
            Mock Invoke-Docker { if (($DockerArgs -join ' ') -like 'network ls*') { return @() }; @() }
            { New-WpdSite acme } | Should -Throw '*wpd setup*'
            Test-Path (Join-Path $env:WPD_SITES_ROOT 'acme') | Should -BeFalse
        }
        It 'cleans up everything it created when startup fails' {
            $script:failOn = 'compose * up *'
            { New-WpdSite smoke } | Should -Throw '*simulated docker failure*'
            Test-Path (Join-Path $env:WPD_SITES_ROOT 'smoke') | Should -BeFalse
            Test-Path (Join-Path $env:WPD_HOME 'infra/certs/smoke.pem') | Should -BeFalse
            Test-Path (Join-Path $env:WPD_HOME 'infra/certs/smoke-key.pem') | Should -BeFalse
            Test-Path (Join-Path $env:WPD_HOME 'infra/dynamic/smoke.yml') | Should -BeFalse
            ($script:calls | Where-Object { $_ -match 'volume ls' }) | Should -Not -BeNullOrEmpty
        }
        It 'cleans up when WordPress install fails' {
            $script:failOn = '*core install*'
            { New-WpdSite smoke } | Should -Throw '*simulated docker failure*'
            Test-Path (Join-Path $env:WPD_SITES_ROOT 'smoke') | Should -BeFalse
            Test-Path (Join-Path $env:WPD_HOME 'infra/dynamic/smoke.yml') | Should -BeFalse
        }
    }

    Context 'Remove-WpdSite' {
        BeforeEach {
            $script:dir = Join-Path $env:WPD_SITES_ROOT 'acme'
            New-Item -ItemType Directory (Join-Path $script:dir 'wp-content') -Force | Out-Null
            Set-Content (Join-Path $script:dir 'docker-compose.yml') 'x'
            $other = Join-Path $env:WPD_SITES_ROOT 'other'
            New-Item -ItemType Directory $other | Out-Null
            Set-Content (Join-Path $other 'f.txt') 'other site'
        }
        It 'without -Force and with a "no" answer leaves everything intact' {
            { Remove-WpdSite acme -Ask { 'n' } } | Should -Throw '*Nothing was deleted*'
            Test-Path $script:dir | Should -BeTrue
            ($script:calls | Where-Object { $_ -match '^(rm|volume rm|compose)' }) | Should -BeNullOrEmpty
        }
        It 'refuses on empty input' {
            { Remove-WpdSite acme -Ask { '' } } | Should -Throw '*Nothing was deleted*'
            Test-Path $script:dir | Should -BeTrue
        }
        It 'refuses when asking itself fails (non-interactive)' {
            { Remove-WpdSite acme -Ask { throw 'no console' } } | Should -Throw '*Nothing was deleted*'
            Test-Path $script:dir | Should -BeTrue
        }
        It 'names containers, volumes and the folder, and says it cannot be undone' {
            $script:question = $null
            Remove-WpdSite acme -Ask { param($q) $script:question = $q; 'y' }
            $script:question | Should -Match 'containers'
            $script:question | Should -Match 'volumes'
            $script:question | Should -Match ([regex]::Escape($script:dir))
            $script:question | Should -Match 'cannot be undone'
        }
        It 'on yes deletes the site folder and its certs, only that site' {
            $infra = Join-Path $env:WPD_HOME 'infra'
            New-Item -ItemType Directory (Join-Path $infra 'certs'), (Join-Path $infra 'dynamic') -Force | Out-Null
            foreach ($f in 'certs/acme.pem', 'certs/acme-key.pem', 'dynamic/acme.yml', 'certs/other.pem', 'dynamic/other.yml') { Set-Content (Join-Path $infra $f) 'x' }
            Remove-WpdSite acme -Ask { 'yes' }
            Test-Path $script:dir | Should -BeFalse
            foreach ($f in 'certs/acme.pem', 'certs/acme-key.pem', 'dynamic/acme.yml') { Test-Path (Join-Path $infra $f) | Should -BeFalse }
            foreach ($f in 'certs/other.pem', 'dynamic/other.yml') { Test-Path (Join-Path $infra $f) | Should -BeTrue }
            Test-Path (Join-Path $env:WPD_SITES_ROOT 'other/f.txt') | Should -BeTrue
        }
        It '-Force skips the question' {
            Remove-WpdSite acme -Force -Ask { throw 'must not ask' }
            Test-Path $script:dir | Should -BeFalse
        }
        It 'only removes docker objects labelled with this exact compose project' {
            $script:psOutput = @('c1')
            Remove-WpdSite acme -Force
            ($script:calls | Where-Object { $_ -match 'filter' }) | ForEach-Object { $_ | Should -Match 'label=com\.docker\.compose\.project=wpdtest-acme$' }
        }
        It 'rejects path-like names and unknown sites' {
            { Remove-WpdSite '..\other' -Force } | Should -Throw '*Invalid site name*'
            { Remove-WpdSite 'nosuch' -Force } | Should -Throw '*No site*'
            Test-Path (Join-Path $env:WPD_SITES_ROOT 'other/f.txt') | Should -BeTrue
        }
    }

    Context 'Get-WpdSites, Start-WpdSite, Stop-WpdSite' {
        BeforeEach {
            foreach ($n in 'one', 'two') {
                New-Item -ItemType Directory (Join-Path $env:WPD_SITES_ROOT $n) | Out-Null
                Set-Content (Join-Path $env:WPD_SITES_ROOT "$n/docker-compose.yml") 'x'
            }
            New-Item -ItemType Directory (Join-Path $env:WPD_SITES_ROOT 'not-a-site') | Out-Null
        }
        It 'lists only wpd sites and marks the running ones' {
            Mock Invoke-Docker { 'wpdtest-two' }
            $s = @(Get-WpdSites)
            $s.Name | Should -Be @('one', 'two')
            ($s | Where-Object Name -eq 'one').Running | Should -BeFalse
            ($s | Where-Object Name -eq 'two').Running | Should -BeTrue
            ($s | Where-Object Name -eq 'two').Url | Should -Be 'https://two.test'
        }
        It 'up and down call compose for that site only' {
            Start-WpdSite one
            Stop-WpdSite one
            ($script:calls | Where-Object { $_ -match 'compose' -and $_ -match 'wpdtest-one' -and $_ -match ' up -d$' }) | Should -Not -BeNullOrEmpty
            ($script:calls | Where-Object { $_ -match ' stop$' }) | Should -Not -BeNullOrEmpty
        }
        It 'up and down refuse unknown sites' {
            { Start-WpdSite nosuch } | Should -Throw '*No site*'
            { Stop-WpdSite nosuch } | Should -Throw '*No site*'
        }
    }
}

# Opt-in: set WPD_INTEGRATION=1. Alternate ports and prefix, never touches 80/443/53 or Laragon.
Describe 'Site integration (real Docker, alternate ports)' -Tag Integration -Skip:(-not $env:WPD_INTEGRATION) {
    BeforeAll {
        $script:keep = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:keep[$n] = [Environment]::GetEnvironmentVariable($n)
        }
        $base = if ($env:WPD_INT_BASE) { $env:WPD_INT_BASE } else { [IO.Path]::GetTempPath() }
        $script:tmp = Join-Path $base "wpd site int $([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory $script:tmp -Force | Out-Null
        $env:WPD_HOME = Join-Path $script:tmp 'home'
        $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites'
        $env:WPD_HTTP_PORT = '8080'; $env:WPD_HTTPS_PORT = '8443'; $env:WPD_DNS_PORT = '5354'; $env:WPD_INFRA_PREFIX = 'wpdtest'
        $script:curl = { param([string[]]$a) & curl.exe --silent --show-error --ssl-no-revoke --resolve 'smoke.test:8443:127.0.0.1' @a }
    }
    AfterAll {
        foreach ($proj in 'wpdtest-smoke') {
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
    It 'rendered compose file validates with docker compose, in a path with spaces' {
        $dir = Join-Path $script:tmp 'render check'
        New-Item -ItemType Directory $dir | Out-Null
        Set-Content (Join-Path $dir 'php.ini') 'x'
        $y = Format-SiteCompose @{ Name = 'acme'; Tld = 'test'; Php = '8.3'; DbPassword = 'Pw12345'; Network = 'wpdtest-net' }
        [IO.File]::WriteAllText((Join-Path $dir 'docker-compose.yml'), $y)
        $cfg = (& docker compose -f (Join-Path $dir 'docker-compose.yml') --profile tools config --format json) -join "`n" | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0
        $cfg.services.wordpress.labels.'traefik.http.routers.wpd-acme.rule' | Should -Be 'Host(`acme.test`)'
        $themes = $cfg.services.wordpress.volumes | Where-Object { $_.target -eq '/var/www/html/wp-content/themes' }
        $themes.type | Should -Be 'bind'
        $themes.source | Should -Be (Join-Path $dir 'wp-content/themes').Replace('\', '\')
        $cfg.services.wordpress.environment.WORDPRESS_CONFIG_EXTRA | Should -Match "WP_HOME', 'https://acme.test'"
    }
    It 'creates a site that serves HTTPS and accepts the returned admin login' {
        Initialize-Infra
        $site = New-WpdSite smoke -Php 8.2
        $site.Url | Should -Be 'https://smoke.test:8443'
        $code = & $script:curl @('-o', 'NUL', '-w', '%{http_code}', 'https://smoke.test:8443/')
        $code | Should -Be '200'
        $mail = & curl.exe --silent --ssl-no-revoke --resolve 'mail.smoke.test:8443:127.0.0.1' -o NUL -w '%{http_code}' 'https://mail.smoke.test:8443/'
        $mail | Should -Be '200'
        $jar = Join-Path $script:tmp 'jar.txt'
        & $script:curl @('-c', $jar, '-b', $jar, '-o', 'NUL', 'https://smoke.test:8443/wp-login.php')
        $hdr = & $script:curl @('-c', $jar, '-b', $jar, '-i', '-o', '-', '--data-urlencode', 'log=admin', '--data-urlencode', "pwd=$($site.AdminPassword)", '--data-urlencode', 'wp-submit=Log In', '--data-urlencode', 'testcookie=1', 'https://smoke.test:8443/wp-login.php')
        ($hdr -join "`n") | Should -Match 'wordpress_logged_in'
        $dash = & $script:curl @('-b', $jar, 'https://smoke.test:8443/wp-admin/')
        ($dash -join "`n") | Should -Match 'Dashboard'
    }
    It 'measures front page and wp-login load time of the hybrid layout' {
        $t = { param($p) 1..6 | ForEach-Object { [double](& $script:curl @('-o', 'NUL', '-w', '%{time_total}', "https://smoke.test:8443/$p")) } }
        $front = & $t ''
        $login = & $t 'wp-login.php'
        Write-Host "TIMING front page (s): $($front -join ' ')"
        Write-Host "TIMING wp-login.php (s): $($login -join ' ')"
        ($front | Measure-Object -Minimum).Minimum | Should -BeGreaterThan 0
    }
    It 'serves seeded default themes and plugins from the bind-mounted folders' {
        $d = Join-Path $env:WPD_SITES_ROOT 'smoke/wp-content'
        (Get-ChildItem (Join-Path $d 'themes') -Directory).Count | Should -BeGreaterThan 0
        Test-Path (Join-Path $d 'plugins/akismet') | Should -BeTrue
    }
    It 'applies the PHP limits and keeps mail local' {
        # CLI forces max_execution_time=0, so read that one from the mounted ini and the others from the loaded config.
        $ini = (& docker compose -p wpdtest-smoke exec -T wordpress php -r 'echo ini_get("upload_max_filesize"),"|",ini_get("post_max_size"),"|",ini_get("memory_limit");') -join ''
        $ini | Should -Be '2G|2G|512M'
        ((& docker compose -p wpdtest-smoke exec -T wordpress cat /usr/local/etc/php/conf.d/wpd.ini) -join "`n") | Should -Match 'max_execution_time = 600'
        $f = Join-Path $env:WPD_SITES_ROOT 'smoke/docker-compose.yml'
        $php = 'echo json_encode([WP_ENVIRONMENT_TYPE, WP_HOME, WP_SITEURL, DISABLE_WP_CRON, WP_DEBUG]);'
        $consts = (& docker compose -p wpdtest-smoke -f $f --profile tools run --rm -T wpcli wp eval $php) -join ''
        $consts | Should -Be '["local","https:\/\/smoke.test:8443","https:\/\/smoke.test:8443",true,true]'
        $mu = (& docker compose -p wpdtest-smoke -f $f --profile tools run --rm -T wpcli wp plugin list --status=must-use --field=name) -join ' '
        $mu | Should -Match 'wpd-mail'
    }
    It 'lists, stops, starts and refuses duplicates' {
        (Get-WpdSites | Where-Object Name -eq 'smoke').Running | Should -BeTrue
        Stop-WpdSite smoke
        (Get-WpdSites | Where-Object Name -eq 'smoke').Running | Should -BeFalse
        Start-WpdSite smoke
        (Get-WpdSites | Where-Object Name -eq 'smoke').Running | Should -BeTrue
        { New-WpdSite smoke } | Should -Throw '*already exist*'
    }
    It 'rm removes containers, volumes, certs and folder' {
        Remove-WpdSite smoke -Force
        (& docker ps -a -q --filter 'label=com.docker.compose.project=wpdtest-smoke') | Should -BeNullOrEmpty
        (& docker volume ls -q --filter 'label=com.docker.compose.project=wpdtest-smoke') | Should -BeNullOrEmpty
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'smoke') | Should -BeFalse
        Test-Path (Join-Path $env:WPD_HOME 'infra/dynamic/smoke.yml') | Should -BeFalse
    }
}
