BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
    . "$PSScriptRoot/../lib/Infra.ps1"
}

Describe 'Install-WpdSkill (temp home, nothing real touched)' {
    BeforeEach {
        $script:h = Join-Path ([IO.Path]::GetTempPath()) "wpd-skill-$([guid]::NewGuid())"
        New-Item -ItemType Directory $script:h | Out-Null
    }
    AfterEach { Remove-Item $script:h -Recurse -Force -ErrorAction SilentlyContinue }
    It 'copies the skill under .claude/skills/wpd only after a yes' {
        Mock Read-Host { 'y' }
        Install-WpdSkill -HomeDir $script:h
        Get-Content (Join-Path $script:h '.claude/skills/wpd/SKILL.md') -Raw | Should -Match 'name: wpd'
    }
    It 'does nothing on the default (empty) or no answer' {
        Mock Read-Host { '' }
        Install-WpdSkill -HomeDir $script:h
        Test-Path (Join-Path $script:h '.claude') | Should -BeFalse
    }
}
