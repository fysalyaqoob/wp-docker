BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
}

Describe 'Get-WpdConfig' {
    BeforeEach {
        $script:saved = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:saved[$n] = [Environment]::GetEnvironmentVariable($n)
            [Environment]::SetEnvironmentVariable($n, $null)
        }
        $env:WPD_HOME = Join-Path ([IO.Path]::GetTempPath()) "wpd-test-$([guid]::NewGuid())"
    }
    AfterEach {
        Remove-Item $env:WPD_HOME -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($n in $script:saved.Keys) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }
    It 'defaults SitesRoot to Get-DefaultSitesRoot' {
        (Get-WpdConfig).SitesRoot | Should -Be (Get-DefaultSitesRoot)
        (Get-DefaultSitesRoot) | Should -Match 'Sites$'
    }
    It 'WPD_SITES_ROOT overrides the default' {
        $env:WPD_SITES_ROOT = 'X:\custom'
        (Get-WpdConfig).SitesRoot | Should -Be 'X:\custom'
    }
    It 'reads config.json when env is unset' {
        New-Item -ItemType Directory $env:WPD_HOME | Out-Null
        '{"SitesRoot":"Y:\\fromfile"}' | Set-Content (Join-Path $env:WPD_HOME 'config.json')
        (Get-WpdConfig).SitesRoot | Should -Be 'Y:\fromfile'
    }
    It 'exposes Tld, Network and InfraRoot' {
        $c = Get-WpdConfig
        $c.Tld | Should -Be 'test'
        $c.Network | Should -Be 'wpd-net'
        $c.InfraRoot | Should -Not -BeNullOrEmpty
    }
    It 'defaults ports and prefix' {
        $c = Get-WpdConfig
        $c.HttpPort | Should -Be 80
        $c.HttpsPort | Should -Be 443
        $c.DnsPort | Should -Be 53
        $c.InfraPrefix | Should -Be 'wpd'
    }
    It 'overrides ports and prefix from env, prefix drives the network name' {
        $env:WPD_HTTP_PORT = '8080'; $env:WPD_HTTPS_PORT = '8443'; $env:WPD_DNS_PORT = '5353'; $env:WPD_INFRA_PREFIX = 'wpdtest'
        $c = Get-WpdConfig
        $c.HttpPort | Should -Be 8080
        $c.HttpsPort | Should -Be 8443
        $c.DnsPort | Should -Be 5353
        $c.InfraPrefix | Should -Be 'wpdtest'
        $c.Network | Should -Be 'wpdtest-net'
    }
    It 'rejects a non-numeric port with a clear error' {
        $env:WPD_HTTP_PORT = 'abc'
        { Get-WpdConfig } | Should -Throw '*WPD_HTTP_PORT*'
    }
    It 'reports a malformed config.json clearly' {
        New-Item -ItemType Directory $env:WPD_HOME | Out-Null
        '{ not json' | Set-Content (Join-Path $env:WPD_HOME 'config.json')
        { Get-WpdConfig } | Should -Throw '*invalid JSON*'
    }
}

Describe 'Assert-SiteName' {
    It 'accepts <_>' -ForEach 'acme', 'acme-2', ('a' * 42) { { Assert-SiteName $_ } | Should -Not -Throw }
    It 'rejects <_>' -ForEach 'Acme', 'a b', 'a.b', '..\x', '', ('a' * 43), '-a', 'a-' {
        { Assert-SiteName $_ } | Should -Throw
    }
    It 'rejects reserved Windows device name <_>' -ForEach 'con', 'prn', 'aux', 'nul', 'com1', 'com9', 'lpt1', 'lpt9' {
        { Assert-SiteName $_ } | Should -Throw '*reserved*'
    }
    It 'still accepts names that merely contain a device name' -ForEach 'console', 'com10', 'lpt0', 'auxx', 'my-con' {
        { Assert-SiteName $_ } | Should -Not -Throw
    }
    It 'rejects a trailing newline' {
        { Assert-SiteName "acme`n" } | Should -Throw
    }
}

Describe 'Docker helpers' {
    It 'Invoke-Docker does not merge stderr into output' {
        Mock docker { Write-Error 'a warning' -ErrorAction Continue; 'real-output'; $global:LASTEXITCODE = 0 }
        (Invoke-Docker @('ps')) | Should -Be @('real-output')
    }
    It 'Invoke-Docker actually passes its arguments to docker' {
        Mock docker { "got:$($args -join ',')"; $global:LASTEXITCODE = 0 }
        Invoke-Docker @('ps', '-a') | Should -Be 'got:ps,-a'
    }
    It 'Invoke-Docker returns nothing falsy-safe for empty output' {
        Mock docker { $global:LASTEXITCODE = 0 }
        $r = Invoke-Docker @('network', 'ls')
        [bool]$r | Should -BeFalse
    }
    It 'Invoke-Docker puts stderr in the exception on failure' {
        Mock docker { Write-Error 'boom-detail' -ErrorAction Continue; $global:LASTEXITCODE = 1 }
        { Invoke-Docker @('ps') } | Should -Throw '*boom-detail*'
    }
    It 'Assert-DockerRunning gives the friendly message when the daemon is down' {
        Mock docker { $global:LASTEXITCODE = 1 }
        { Assert-DockerRunning } | Should -Throw '*Start Docker Desktop*'
    }
    It 'Assert-DockerRunning gives the friendly message when the docker CLI is missing' {
        Mock docker { throw [System.Management.Automation.CommandNotFoundException]::new('docker') }
        { Assert-DockerRunning } | Should -Throw '*Start Docker Desktop*'
    }
}
