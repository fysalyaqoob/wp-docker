BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
}

Describe 'Get-WpdConfig' {
    BeforeEach {
        $script:saved = @{ H = $env:WPD_HOME; S = $env:WPD_SITES_ROOT }
        $env:WPD_HOME = Join-Path ([IO.Path]::GetTempPath()) "wpd-test-$([guid]::NewGuid())"
        $env:WPD_SITES_ROOT = $null
    }
    AfterEach {
        $env:WPD_HOME = $script:saved.H; $env:WPD_SITES_ROOT = $script:saved.S
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
}

Describe 'Assert-SiteName' {
    It 'accepts <_>' -ForEach 'acme', 'acme-2', ('a' * 42) { { Assert-SiteName $_ } | Should -Not -Throw }
    It 'rejects <_>' -ForEach 'Acme', 'a b', 'a.b', '..\x', '', ('a' * 43), '-a', 'a-' {
        { Assert-SiteName $_ } | Should -Throw
    }
}
