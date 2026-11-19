BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
    . "$PSScriptRoot/../lib/Infra.ps1"
    . "$PSScriptRoot/../lib/Site.ps1"
    . "$PSScriptRoot/../lib/Safety.ps1"
    . "$PSScriptRoot/../lib/CloneSsh.ps1"
    . "$PSScriptRoot/../lib/Wpress.ps1"

    $script:fx = Join-Path ([IO.Path]::GetTempPath()) "wpd-wpress-fx-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory $script:fx -Force | Out-Null

    function script:New-TestWpress {
        # Writes the exact AI1WM layout: name 255 + size 14 + mtime 12 + path 4096, NUL padded, decimal size/mtime.
        # Quirks kept: non-zero 8-byte tail in every path field, end block with empty name and junk in the size field.
        param([string]$File, [object[]]$Entries, [switch]$Truncate, [switch]$NoEnd)
        $fs = [IO.File]::Create($File)
        try {
            foreach ($e in $Entries) {
                $h = [byte[]]::new(4377)
                $n = [Text.Encoding]::ASCII.GetBytes([string]$e.Name); [Array]::Copy($n, 0, $h, 0, $n.Length)
                $s = [Text.Encoding]::ASCII.GetBytes([string]$e.Data.Length); [Array]::Copy($s, 0, $h, 255, $s.Length)
                $m = [Text.Encoding]::ASCII.GetBytes('1700000000'); [Array]::Copy($m, 0, $h, 269, $m.Length)
                $p = [Text.Encoding]::ASCII.GetBytes([string]$e.Path); [Array]::Copy($p, 0, $h, 281, $p.Length)
                [Array]::Copy([Text.Encoding]::ASCII.GetBytes('a1b2c3d4'), 0, $h, 281 + 4088, 8)
                $fs.Write($h, 0, $h.Length)
                $d = [byte[]]$e.Data
                if ($Truncate -and [object]::ReferenceEquals($e, $Entries[-1])) { $d = $d[0..($d.Length - 3)] }
                $fs.Write($d, 0, $d.Length)
            }
            if (-not $NoEnd) {
                $h = [byte[]]::new(4377)
                $s = [Text.Encoding]::ASCII.GetBytes('1548406660'); [Array]::Copy($s, 0, $h, 255, $s.Length)
                [Array]::Copy([Text.Encoding]::ASCII.GetBytes('ffeeddcc'), 0, $h, 281 + 4088, 8)
                $fs.Write($h, 0, $h.Length)
            }
        } finally { $fs.Dispose() }
    }
    function script:B([string]$t) { , [Text.Encoding]::UTF8.GetBytes($t) }

    $script:pkg = '{"SiteURL":"https://live.example.com","HomeURL":"https://live.example.com"}'
    $script:sqlText = "DROP TABLE IF EXISTS ``SERVMASK_PREFIX_options``;`nCREATE TABLE ``SERVMASK_PREFIX_options`` (a int);`nCREATE TABLE ``SERVMASK_PREFIX_posts`` (a int);`nCREATE TABLE ``SERVMASK_PREFIX_users`` (a int);`nINSERT INTO ``SERVMASK_PREFIX_options`` VALUES ('SERVMASK_PREFIX_user_roles');`n"
    function script:Std-Entries { @(
        @{ Name = 'package.json'; Path = '.'; Data = (B $script:pkg) },
        @{ Name = 'style.css'; Path = 'themes/mytheme'; Data = (B '/* t */') },
        @{ Name = 'a.bin'; Path = 'uploads/2024/05'; Data = [byte[]](0..255) },
        @{ Name = 'multisite.json'; Path = '.'; Data = (B '{}') },
        @{ Name = 'x.txt'; Path = 'storage/foo'; Data = (B 'ignored') },
        @{ Name = 'database.sql'; Path = '.'; Data = (B $script:sqlText) }
    ) }
}
AfterAll { Remove-Item $script:fx -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Expand-Wpress' {
    BeforeEach { $script:w = Join-Path $script:fx ([guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $script:w | Out-Null }

    It 'extracts content, database and url, ignoring non-content entries' {
        $f = Join-Path $script:w 'a.wpress'; New-TestWpress $f (Std-Entries)
        $dest = Join-Path $script:w 'out'
        $r = Expand-Wpress $f $dest
        $r.OldUrl | Should -Be 'https://live.example.com'
        $r.FileCount | Should -Be 2
        $r.DatabasePath | Should -Be (Join-Path $dest 'database.sql')
        (Get-Content $r.DatabasePath -Raw) | Should -Be $script:sqlText
        (Get-Content (Join-Path $dest 'themes/mytheme/style.css') -Raw) | Should -Be '/* t */'
        [IO.File]::ReadAllBytes((Join-Path $dest 'uploads/2024/05/a.bin')).Length | Should -Be 256
        Test-Path (Join-Path $dest 'storage') | Should -BeFalse
        Test-Path (Join-Path $dest 'multisite.json') | Should -BeFalse
    }
    It 'also accepts a wp-content/ prefix' {
        $f = Join-Path $script:w 'a.wpress'
        New-TestWpress $f @(@{ Name = 'package.json'; Path = '.'; Data = (B $script:pkg) }, @{ Name = 's.css'; Path = 'wp-content/themes/t'; Data = (B 'x') }, @{ Name = 'database.sql'; Path = '.'; Data = (B 'x') })
        $dest = Join-Path $script:w 'out'
        (Expand-Wpress $f $dest).FileCount | Should -Be 1
        Test-Path (Join-Path $dest 'themes/t/s.css') | Should -BeTrue
    }
    It 'throws on a truncated archive' {
        $f = Join-Path $script:w 'a.wpress'; New-TestWpress $f (Std-Entries) -Truncate -NoEnd
        { Expand-Wpress $f (Join-Path $script:w 'out') } | Should -Throw '*truncated*'
    }
    It 'throws when database.sql is missing' {
        $f = Join-Path $script:w 'a.wpress'; New-TestWpress $f @((Std-Entries)[0..2])
        { Expand-Wpress $f (Join-Path $script:w 'out') } | Should -Throw '*database.sql*'
    }
    It 'throws when no url can be found, and honours an -OldUrl override' {
        $f = Join-Path $script:w 'a.wpress'
        New-TestWpress $f @(@{ Name = 'database.sql'; Path = '.'; Data = (B 'CREATE TABLE x (a int);') })
        { Expand-Wpress $f (Join-Path $script:w 'o1') } | Should -Throw '*site URL*'
        (Expand-Wpress $f (Join-Path $script:w 'o2') -OldUrl 'https://o.example.com').OldUrl | Should -Be 'https://o.example.com'
    }
    It 'falls back to the siteurl row with a warning' {
        $f = Join-Path $script:w 'a.wpress'
        New-TestWpress $f @(@{ Name = 'database.sql'; Path = '.'; Data = (B "INSERT INTO ``SERVMASK_PREFIX_options`` VALUES (1,'siteurl','https://row.example.com','yes');`n") })
        (Expand-Wpress $f (Join-Path $script:w 'o') -WarningAction SilentlyContinue).OldUrl | Should -Be 'https://row.example.com'
    }
    It 'rejects traversal, absolute, drive and backslash names without writing outside the destination' {
        $cases = @(
            @{ Name = 'evil'; Path = '../evil' }, @{ Name = '..'; Path = 'themes' }, @{ Name = 'evil'; Path = '/etc' },
            @{ Name = 'evil'; Path = 'C:/Windows' }, @{ Name = 'evil'; Path = 'themes\..\..\evil' }, @{ Name = 'a\b'; Path = 'themes' }, @{ Name = 'evil'; Path = 'themes/../../evil' }
        )
        foreach ($c in $cases) {
            $d = Join-Path $script:w ([guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $d | Out-Null
            $f = Join-Path $d 'a.wpress'
            New-TestWpress $f @(@{ Name = $c.Name; Path = $c.Path; Data = (B 'x') }, @{ Name = 'database.sql'; Path = '.'; Data = (B 'x') })
            { Expand-Wpress $f (Join-Path $d 'sub/out') -OldUrl 'https://a.example.com' } | Should -Throw
            @(Get-ChildItem $d -Recurse -File | Where-Object { $_.Name -ne 'a.wpress' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Convert-SqlPrefixToken' {
    It 'replaces the token across chunk boundaries' {
        $in = Join-Path $script:fx 'in.sql'; $out = Join-Path $script:fx 'out.sql'
        $t = 'SERVMASK_PREFIX_'
        $text = ((1..300 | ForEach-Object { "x$t$_ y${t}options 'z${t}user_roles'`n" }) -join '') + "tail $t"
        [IO.File]::WriteAllText($in, $text)
        foreach ($chunk in 7, 16, 17, 31, 1024) {
            Convert-SqlPrefixToken $in $out 'wp_' -ChunkSize $chunk
            [IO.File]::ReadAllText($out) | Should -Be $text.Replace($t, 'wp_')
        }
    }
}

Describe 'Import-Wpress' {
    BeforeEach {
        $env0 = @{}; foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_INFRA_PREFIX') { $env0[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:env0 = $env0
        $env:WPD_HOME = Join-Path $script:fx 'home'; $env:WPD_SITES_ROOT = Join-Path $script:fx 'sites'; $env:WPD_INFRA_PREFIX = 'wpdunit'
        New-Item -ItemType Directory $env:WPD_SITES_ROOT -Force | Out-Null
        $script:f = Join-Path $script:fx 'imp.wpress'; New-TestWpress $script:f (Std-Entries)
        $script:created = 0; $script:cleaned = 0; $script:got = $null; $script:throwImport = $null
        Mock Assert-DockerRunning {}
        Mock New-WpdSite { $script:created++; New-Item -ItemType Directory (Join-Path $env:WPD_SITES_ROOT $Name) | Out-Null; [pscustomobject]@{ Name = $Name; Url = "https://$Name.test"; Path = (Join-Path $env:WPD_SITES_ROOT $Name); AdminUser = 'admin'; AdminPassword = 'pw' } }
        Mock Import-SiteContent {
            if ($script:throwImport) { throw $script:throwImport }
            $script:got = [pscustomobject]@{ OldUrl = $OldUrl; NoUploads = [bool]$NoUploads; Sql = (Get-Content $SqlFile -Raw); Theme = (Test-Path (Join-Path $ContentDir 'themes/mytheme/style.css')); Dir = $ContentDir }
        }
        Mock Remove-FailedImportSite { $script:cleaned++; Remove-Item (Join-Path $env:WPD_SITES_ROOT $Name) -Recurse -Force }
    }
    AfterEach { foreach ($n in $script:env0.Keys) { [Environment]::SetEnvironmentVariable($n, $script:env0[$n]) }; Remove-Item (Join-Path $script:fx 'sites') -Recurse -Force -ErrorAction SilentlyContinue }

    It 'replaces the prefix token, passes the url and removes the temp folder' {
        $s = Import-Wpress -Name 'wp1' -File $script:f -NoUploads
        $s.Name | Should -Be 'wp1'
        $script:got.OldUrl | Should -Be 'https://live.example.com'
        $script:got.NoUploads | Should -BeTrue
        $script:got.Theme | Should -BeTrue
        $script:got.Sql | Should -Not -Match 'SERVMASK'
        $script:got.Sql | Should -Match 'CREATE TABLE `wp_options`'
        $script:got.Sql | Should -Match "'wp_user_roles'"
        Test-Path $script:got.Dir | Should -BeFalse
        $script:cleaned | Should -Be 0
    }
    It 'creates nothing when the archive is bad' {
        $bad = Join-Path $script:fx 'bad.wpress'; New-TestWpress $bad @((Std-Entries)[0..2])
        { Import-Wpress -Name 'wp2' -File $bad } | Should -Throw '*database.sql*'
        $script:created | Should -Be 0
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'wp2') | Should -BeFalse
    }
    It 'refuses an existing site and a bad name without touching it' {
        New-Item -ItemType Directory (Join-Path $env:WPD_SITES_ROOT 'have') | Out-Null
        { Import-Wpress -Name 'have' -File $script:f } | Should -Throw '*already exists*'
        { Import-Wpress -Name 'Bad Name' -File $script:f } | Should -Throw
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'have') | Should -BeTrue
        $script:cleaned | Should -Be 0
    }
    It 'removes the new site folder when the import fails' {
        $script:throwImport = 'boom'
        { Import-Wpress -Name 'wp3' -File $script:f } | Should -Throw '*boom*'
        $script:cleaned | Should -Be 1
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'wp3') | Should -BeFalse
    }
    It 'keeps the site when the failure came after the data was imported' {
        $ex = [InvalidOperationException]::new('the clone was created but needs attention: x'); $ex.Data['WpdImported'] = $true
        $script:throwImport = $ex
        { Import-Wpress -Name 'wp4' -File $script:f } | Should -Throw '*needs attention*'
        $script:cleaned | Should -Be 0
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'wp4') | Should -BeTrue
    }
}
