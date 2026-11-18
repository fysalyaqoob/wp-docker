BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
    . "$PSScriptRoot/../lib/Infra.ps1"
    . "$PSScriptRoot/../lib/Doctor.ps1"
}

Describe 'port conflicts (unit, everything mocked)' {
    BeforeEach {
        $script:saved = @{}
        foreach ($n in 'WPD_HOME', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:saved[$n] = [Environment]::GetEnvironmentVariable($n)
            [Environment]::SetEnvironmentVariable($n, $null)
        }
        $env:WPD_HOME = Join-Path ([IO.Path]::GetTempPath()) "wpd-test-$([guid]::NewGuid())"
        New-Item -ItemType Directory $env:WPD_HOME | Out-Null
        $script:state = Join-Path $env:WPD_HOME 'stopped.json'
        $script:ran = [System.Collections.Generic.List[string]]::new()
        $script:runner = { param($cmd) $script:ran.Add($cmd) }
        Mock Get-PortHolder { 'httpd' } -ParameterFilter { $Port -in 80, 443 }
        Mock Get-ServerStopPlan {
            if ($Holder -eq 'httpd') { [pscustomobject]@{ Name = 'Apache'; Kind = 'process'; Stop = 'STOP-HTTPD'; Start = 'START-HTTPD' } }
        }
    }
    AfterEach {
        Remove-Item $env:WPD_HOME -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }

    It 'answering no stops nothing and writes no state' {
        Stop-PortConflicts -Ask { 'n' } -StopRunner $script:runner
        $script:ran.Count | Should -Be 0
        Test-Path $script:state | Should -BeFalse
    }
    It 'answering yes stops it once (both ports, one holder) and records it' {
        Stop-PortConflicts -Ask { 'y' } -StopRunner $script:runner
        $script:ran | Should -Be @('STOP-HTTPD')
        $rec = @(Get-Content $script:state -Raw | ConvertFrom-Json)
        $rec.Count | Should -Be 1
        $rec[0].Name | Should -Be 'Apache'
        $rec[0].Kind | Should -Be 'process'
        $rec[0].Start | Should -Be 'START-HTTPD'
    }
    It 'never stops an unrecognized holder and never asks' {
        Mock Get-PortHolder { 'mystery' } -ParameterFilter { $Port -in 80, 443 }
        $script:asked = 0
        Stop-PortConflicts -Ask { $script:asked++; 'y' } -StopRunner $script:runner 3>$null
        $script:ran.Count | Should -Be 0
        $script:asked | Should -Be 0
        Test-Path $script:state | Should -BeFalse
    }
    It 'ignores a port already held by Docker (our own Traefik)' {
        Mock Get-PortHolder { 'com.docker.backend' } -ParameterFilter { $Port -in 80, 443 }
        Stop-PortConflicts -Ask { 'y' } -StopRunner $script:runner
        $script:ran.Count | Should -Be 0
    }
    It 'Resume-PortConflicts restarts exactly what the file lists and clears it' {
        Stop-PortConflicts -Ask { 'y' } -StopRunner $script:runner
        $script:ran.Clear()
        Resume-PortConflicts -StartRunner $script:runner
        $script:ran | Should -Be @('START-HTTPD')
        Test-Path $script:state | Should -BeFalse
    }
    It 'Resume-PortConflicts is a no-op with a message when the file is absent' {
        $msg = Resume-PortConflicts -StartRunner $script:runner 6>&1
        $script:ran.Count | Should -Be 0
        ($msg | Out-String) | Should -Match 'Nothing to resume'
    }
    It 'Resume-PortConflicts keeps entries that failed to restart' {
        Stop-PortConflicts -Ask { 'y' } -StopRunner $script:runner
        Resume-PortConflicts -StartRunner { throw 'nope' } 6>$null 3>$null
        Test-Path $script:state | Should -BeTrue
    }
}

Describe 'Test-Infra (unit, everything mocked)' {
    BeforeEach {
        Mock Assert-DockerRunning { }
        Mock Get-PortHolder { $null }
        Mock Get-MkcertPath { 'mkcert' }
        Mock Test-MkcertTrusted { $true }
        Mock Test-TestDns { $true }
        Mock Invoke-Docker { 'true' }
    }
    It 'is all Ok on a healthy machine' {
        (Test-Infra | Where-Object { -not $_.Ok }).Count | Should -Be 0
    }
    It 'httpd on 80 yields a Fix naming httpd and wpd setup offering to stop it' {
        Mock Get-PortHolder { 'httpd' } -ParameterFilter { $Port -eq 80 }
        $bad = Test-Infra | Where-Object { -not $_.Ok }
        $bad.Fix | Should -Match 'httpd'
        $bad.Fix | Should -Match 'wpd setup'
        $bad.Fix | Should -Match 'stop'
    }
    It 'svchost on 53 yields a Fix mentioning Internet Connection Sharing' {
        Mock Get-PortHolder { 'svchost' } -ParameterFilter { $Port -eq 53 }
        $bad = Test-Infra | Where-Object { -not $_.Ok }
        $bad.Fix | Should -Match 'Internet Connection Sharing'
    }
    It 'reports Docker down and skips docker-dependent checks as failing' {
        Mock Assert-DockerRunning { throw 'Docker is not running' }
        $r = Test-Infra
        ($r | Where-Object Name -Like 'Docker running*').Ok | Should -BeFalse
        ($r | Where-Object Name -Like 'Traefik container*').Ok | Should -BeFalse
    }
    It 'flags missing mkcert, untrusted CA and missing DNS hook' {
        Mock Get-MkcertPath { $null }
        Mock Test-MkcertTrusted { $false }
        Mock Test-TestDns { $false }
        (Test-Infra | Where-Object { -not $_.Ok }).Count | Should -BeGreaterOrEqual 3
    }
}

# Opt-in: set WPD_INTEGRATION=1. Uses ports 8080/8443/5354 and prefix wpdtest (5353 is taken by browsers' mDNS).
Describe 'Infra integration (real Docker, alternate ports)' -Tag Integration -Skip:(-not $env:WPD_INTEGRATION) {
    BeforeAll {
        $script:keep = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:keep[$n] = [Environment]::GetEnvironmentVariable($n)
        }
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "wpd-int-$([guid]::NewGuid())"
        New-Item -ItemType Directory $script:tmp | Out-Null
        $env:WPD_HOME = Join-Path $script:tmp 'home'
        $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites'
        $env:WPD_HTTP_PORT = '8080'; $env:WPD_HTTPS_PORT = '8443'; $env:WPD_DNS_PORT = '5354'; $env:WPD_INFRA_PREFIX = 'wpdtest'
    }
    AfterAll {
        foreach ($c in 'wpdtest-traefik', 'wpdtest-dns') { & docker rm -f $c *> $null }
        & docker network rm wpdtest-net wpdtest_default *> $null
        & docker rmi wpdtest-dns:local *> $null
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:keep.Keys) { [Environment]::SetEnvironmentVariable($n, $script:keep[$n]) }
    }
    It 'Initialize-Infra twice leaves Test-Infra all Ok' {
        Initialize-Infra
        Initialize-Infra
        $r = Test-Infra
        ($r | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Name): $($_.Fix)" }) | Should -BeNullOrEmpty
    }
    It 'dnsmasq in the container answers *.test with 127.0.0.1' {
        (& docker exec wpdtest-dns nslookup anything.test 127.0.0.1) -join "`n" | Should -Match '127\.0\.0\.1'
    }
}
