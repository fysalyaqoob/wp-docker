BeforeAll {
    foreach ($f in 'Platform', 'Config', 'Docker', 'Infra', 'Doctor', 'Site', 'Safety', 'CloneSsh', 'Wpress') { . (Join-Path $PSScriptRoot "../lib/$f.ps1") }
}

# Opt-in: WPD_INTEGRATION=1. Real Docker, alternate ports and prefix, temp home and sites root. Takes minutes.
Describe 'end to end smoke (setup, new, https, list, rm)' -Tag Integration -Skip:(-not $env:WPD_INTEGRATION) {
    BeforeAll {
        $script:keep = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') { $script:keep[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "wpd e2e $([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory $script:tmp -Force | Out-Null
        $env:WPD_HOME = Join-Path $script:tmp 'home'; $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites'
        $env:WPD_HTTP_PORT = '8080'; $env:WPD_HTTPS_PORT = '8443'; $env:WPD_DNS_PORT = '5354'; $env:WPD_INFRA_PREFIX = 'wpdtest'
        $script:siteDir = Join-Path $env:WPD_SITES_ROOT 'e2e'
    }
    AfterAll {
        $f = 'label=com.docker.compose.project=wpdtest-e2e'
        $c = & docker ps -a -q --filter $f; if ($c) { & docker rm -f -v @c *> $null }
        $v = & docker volume ls -q --filter $f; if ($v) { & docker volume rm -f @v *> $null }
        $n = & docker network ls -q --filter $f; if ($n) { & docker network rm @n *> $null }
        foreach ($c in 'wpdtest-traefik', 'wpdtest-dns') { & docker rm -f $c *> $null }
        & docker network rm wpdtest-net wpdtest_default *> $null
        & docker rmi wpdtest-dns:local *> $null
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:keep.Keys) { [Environment]::SetEnvironmentVariable($n, $script:keep[$n]) }
    }
    It 'setup then new e2e serves 200 over trusted https' {
        Initialize-Infra
        New-WpdSite 'e2e' | Out-Null
        $code = & curl.exe --silent --show-error --ssl-no-revoke --resolve 'e2e.test:8443:127.0.0.1' -o NUL -w '%{http_code}' 'https://e2e.test:8443/'
        $code | Should -Be '200'
    }
    It 'list shows it running' {
        $s = @(Get-WpdSites | Where-Object Name -eq 'e2e')
        $s.Count | Should -Be 1
        $s[0].Running | Should -BeTrue
    }
    It 'rm -Force removes folder, containers, volumes and certs' {
        Remove-WpdSite 'e2e' -Force
        Test-Path $script:siteDir | Should -BeFalse
        @(& docker ps -a -q --filter 'label=com.docker.compose.project=wpdtest-e2e').Count | Should -Be 0
        @(& docker volume ls -q --filter 'label=com.docker.compose.project=wpdtest-e2e').Count | Should -Be 0
        @(Get-ChildItem (Join-Path (Get-WpdConfig).InfraRoot 'certs') -Filter 'e2e*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
