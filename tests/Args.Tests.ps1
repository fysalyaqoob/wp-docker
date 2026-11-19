BeforeAll {
    $src = Get-Content (Join-Path $PSScriptRoot '../wpd.ps1') -Raw
    Invoke-Expression ([regex]::Match($src, '(?s)function Read-SiteArgs.*?\r?\n}\r?\n').Value)
}
Describe 'Read-SiteArgs' {
    It 'accepts --php and --force together with a name' {
        $r = Read-SiteArgs @('acme', '--php', '8.2', '--force')
        $r.Name | Should -Be 'acme'; $r.Php | Should -Be '8.2'; $r.Force | Should -BeTrue
    }
    It 'rejects unknown options' { { Read-SiteArgs @('acme', '--nope') } | Should -Throw '*Unknown option*' }
}
