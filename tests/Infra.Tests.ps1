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

Describe 'stop/resume safety (unit, everything mocked)' {
    BeforeEach {
        $script:savedHome = $env:WPD_HOME
        $env:WPD_HOME = Join-Path ([IO.Path]::GetTempPath()) "wpd-test-$([guid]::NewGuid())"
        New-Item -ItemType Directory $env:WPD_HOME | Out-Null
        $script:state = Join-Path $env:WPD_HOME 'stopped.json'
        $script:ran = [System.Collections.Generic.List[string]]::new()
        Mock Get-PortHolder { if ($Port -eq 80) { 'httpd' } elseif ($Port -eq 443) { 'nginx' } }
        Mock Get-ServerStopPlan {
            [pscustomobject]@{ Name = $Holder; Kind = 'process'; Stop = "STOP-$Holder"; Start = "START-$Holder" }
        }
    }
    AfterEach {
        Remove-Item $env:WPD_HOME -Recurse -Force -ErrorAction SilentlyContinue
        $env:WPD_HOME = $script:savedHome
    }
    It 'a state-write failure means nothing is stopped' {
        Mock Write-StoppedRecords { throw 'disk full' }
        { Stop-PortConflicts -Ask { 'y' } -StopRunner { param($c) $script:ran.Add($c) } } | Should -Throw '*NOT stopped*'
        $script:ran.Count | Should -Be 0
    }
    It 'when the second stop throws, the first stays recorded and the second is not' {
        { Stop-PortConflicts -Ask { 'y' } -StopRunner { param($c) if ($c -eq 'STOP-nginx') { throw 'denied' }; $script:ran.Add($c) } } | Should -Throw '*denied*'
        $script:ran | Should -Be @('STOP-httpd')
        $rec = @(Get-Content $script:state -Raw | ConvertFrom-Json)
        $rec.Name | Should -Be @('httpd')
    }
    It 'the record exists before the stop runs' {
        Stop-PortConflicts -Ask { 'y' } -StopRunner { param($c) if ($c -eq 'STOP-httpd') { $script:seen = Test-Path $script:state } }
        $script:seen | Should -BeTrue
    }
    It 'Resume with an empty Start keeps the entry and never reports success' {
        '[{"Name":"X","Kind":"process","Stop":"s","Start":""}]' | Set-Content $script:state
        $out = Resume-PortConflicts -StartRunner { param($c) $script:ran.Add($c) } 6>&1 3>&1 | Out-String
        $script:ran.Count | Should -Be 0
        $out | Should -Not -Match 'Restarted'
        Test-Path $script:state | Should -BeTrue
    }
    It 'Resume with a failing Start keeps the entry and never reports success' {
        '[{"Name":"X","Kind":"process","Stop":"s","Start":"go"}]' | Set-Content $script:state
        $out = Resume-PortConflicts -StartRunner { throw 'nope' } 6>&1 3>&1 | Out-String
        $out | Should -Not -Match 'Restarted'
        Test-Path $script:state | Should -BeTrue
    }
}

Describe 'Get-ServerStopPlan on Windows (Get-CimInstance mocked)' -Skip:(-not $IsWindows) {
    It 'quotes a path with spaces and an apostrophe and keeps the arguments' {
        Mock Get-CimInstance { [pscustomobject]@{ ProcessId = 5; ParentProcessId = 1; ExecutablePath = "C:\Program Files\La'ragon\httpd.exe"
            CommandLine = "`"C:\Program Files\La'ragon\httpd.exe`" -f `"C:\x y\httpd.conf`"" } }
        $plan = Get-ServerStopPlan -Holder 'httpd'
        $plan.Start | Should -Match ([regex]::Escape("-FilePath 'C:\Program Files\La''ragon\httpd.exe'"))
        $plan.Start | Should -Match ([regex]::Escape('-f "C:\x y\httpd.conf"'))
        { [scriptblock]::Create($plan.Start) } | Should -Not -Throw
    }
    It 'returns no plan when the executable path is unknown' {
        Mock Get-CimInstance { [pscustomobject]@{ ProcessId = 5; ParentProcessId = 1; ExecutablePath = $null; CommandLine = $null } }
        Get-ServerStopPlan -Holder 'httpd' | Should -BeNullOrEmpty
    }
    It 'returns no plan when no process is found' {
        Mock Get-CimInstance { }
        Get-ServerStopPlan -Holder 'httpd' | Should -BeNullOrEmpty
    }
    It 'returns no plan for an unrecognized holder' {
        Get-ServerStopPlan -Holder 'mystery' | Should -BeNullOrEmpty
    }
    It 'stops only the recorded PIDs and restarts only the root process' {
        Mock Get-CimInstance {
            [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; ExecutablePath = 'C:\a\httpd.exe'; CommandLine = '"C:\a\httpd.exe" -d x' }
            [pscustomobject]@{ ProcessId = 11; ParentProcessId = 10; ExecutablePath = 'C:\a\httpd.exe'; CommandLine = '"C:\a\httpd.exe" -d x -child' }
        }
        $plan = Get-ServerStopPlan -Holder 'httpd'
        $plan.Stop | Should -Match 'Stop-Process -Id 10,11 '
        $plan.Stop | Should -Not -Match '-Name'
        $plan.Start | Should -Not -Match 'child'
    }
}

Describe 'Register-TestDns' {
    It 'does nothing when the rule already exists (no elevation)' {
        Mock Test-TestDns { $true }
        Mock Start-Process { }
        Register-TestDns
        Should -Invoke Start-Process -Times 0
    }
    It 'throws a clear error when the hook is still missing after elevation' -Skip:(-not $IsWindows) {
        Mock Test-TestDns { $false }
        Mock Start-Process { }
        Mock Write-Host { }
        { Register-TestDns } | Should -Throw '*not created*'
        Should -Invoke Start-Process -Times 1
    }
}

Describe 'Initialize-Infra branches (everything mocked)' {
    BeforeEach {
        $script:keepEnv = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_INFRA_PREFIX', 'WPD_NETWORK') { $script:keepEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $env:WPD_HOME = Join-Path ([IO.Path]::GetTempPath()) "wpd-test-$([guid]::NewGuid())"
        $env:WPD_SITES_ROOT = Join-Path $env:WPD_HOME 'sites'
        $env:WPD_HTTP_PORT = '8080'
        $env:WPD_INFRA_PREFIX = $null; $env:WPD_NETWORK = $null
        Mock Assert-DockerRunning { }
        Mock Stop-PortConflicts { }
        Mock Start-Sleep { }
        Mock Get-PortHolder { $null }
        Mock Get-ServerStopPlan { $null }
        Mock Get-MkcertPath { 'mk' }
        Mock Test-MkcertTrusted { $true }
        Mock Install-Mkcert { }
        Mock Register-TestDns { }
        Mock Invoke-DockerRetry { }
        Mock Invoke-Docker {
            if ($DockerArgs[0] -eq 'compose') { $script:envAtCompose = $env:WPD_HTTP_PORT; $script:netAtCompose = $env:WPD_NETWORK }
        }
    }
    AfterEach {
        Remove-Item $env:WPD_HOME -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:keepEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:keepEnv[$n]) }
    }
    It 'happy path runs compose with WPD_* set, then restores the environment' {
        Initialize-Infra 6>$null
        $script:envAtCompose | Should -Be '8080'
        $script:netAtCompose | Should -Be 'wpd-net'
        $env:WPD_NETWORK | Should -BeNullOrEmpty
        $env:WPD_HTTP_PORT | Should -Be '8080'
        Should -Invoke Register-TestDns -Times 1
    }
    It 'a declined/unrecognized web holder aborts before install, pull and compose' {
        Mock Get-PortHolder { 'httpd' } -ParameterFilter { $Port -eq 8080 }
        { Initialize-Infra 6>$null } | Should -Throw '*httpd*'
        Should -Invoke Install-Mkcert -Times 0
        Should -Invoke Invoke-DockerRetry -Times 0
        Should -Invoke Invoke-Docker -Times 0
    }
    It 'a foreign DNS holder aborts before install and compose' {
        Mock Get-PortHolder { 'svchost' } -ParameterFilter { $Protocol -eq 'udp' }
        { Initialize-Infra 6>$null } | Should -Throw '*Internet Connection Sharing*'
        Should -Invoke Install-Mkcert -Times 0
        Should -Invoke Invoke-Docker -Times 0
    }
    It 'installs mkcert only when it is missing' {
        $script:n = 0
        Mock Get-MkcertPath { $script:n++; if ($script:n -eq 1) { $null } else { 'mk' } }
        Initialize-Infra 6>$null
        Should -Invoke Install-Mkcert -Times 1
    }
    It 'does not install mkcert when present' {
        Initialize-Infra 6>$null
        Should -Invoke Install-Mkcert -Times 0
    }
    It 'restores the environment even when compose fails' {
        Mock Invoke-Docker { if ($DockerArgs[0] -eq 'compose') { throw 'bind failed' } }
        { Initialize-Infra 6>$null } | Should -Throw '*bind failed*'
        $env:WPD_NETWORK | Should -BeNullOrEmpty
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
    It 'httpd on 80 with no stop plan says to stop it manually, not that setup will offer' {
        Mock Get-PortHolder { 'httpd' } -ParameterFilter { $Port -eq 80 }
        Mock Get-ServerStopPlan { $null }
        $bad = Test-Infra | Where-Object { -not $_.Ok }
        $bad.Fix | Should -Match 'manually'
        $bad.Fix | Should -Not -Match 'offer to stop'
    }
    It 'httpd on 80 yields a Fix naming httpd and wpd setup offering to stop it' {
        Mock Get-PortHolder { 'httpd' } -ParameterFilter { $Port -eq 80 }
        Mock Get-ServerStopPlan { [pscustomobject]@{ Name = 'Apache'; Kind = 'process'; Stop = 's'; Start = 'r' } }
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
