BeforeAll {
    . "$PSScriptRoot/../lib/Platform.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../lib/Docker.ps1"
    . "$PSScriptRoot/../lib/Infra.ps1"
    . "$PSScriptRoot/../lib/Site.ps1"
    . "$PSScriptRoot/../lib/Safety.ps1"
    . "$PSScriptRoot/../lib/CloneSsh.ps1"

    # A small real fixture: wp-content with themes, plugins, uploads (binary bytes) packed by the real tar.
    $script:fx = Join-Path ([IO.Path]::GetTempPath()) "wpd-clone-fx-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $src = Join-Path $script:fx 'src'
    foreach ($d in 'themes/mytheme', 'plugins/myplugin', 'uploads/2024') { New-Item -ItemType Directory (Join-Path $src $d) -Force | Out-Null }
    Set-Content (Join-Path $src 'themes/mytheme/style.css') '/* Theme Name: mytheme */'
    Set-Content (Join-Path $src 'plugins/myplugin/myplugin.php') '<?php /* Plugin Name: myplugin */'
    [IO.File]::WriteAllBytes((Join-Path $src 'uploads/2024/a.bin'), [byte[]](0..255 + 255..0))
    $script:tgz = Join-Path $script:fx 'content.tar.gz'
    & (Get-TarPath) -czf $script:tgz -C $src themes plugins uploads
    $script:sql = Join-Path $script:fx 'live.sql'
    Set-Content $script:sql "DROP TABLE IF EXISTS ``zz_options``;`nCREATE TABLE ``zz_options`` (a int);`nCREATE TABLE ``zz_posts`` (a int);`nCREATE TABLE ``zz_users`` (a int);`n"

    $script:realProc = ${function:Invoke-WpdProcess}
    $script:env0 = @{}
    foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_INFRA_PREFIX') { $script:env0[$n] = [Environment]::GetEnvironmentVariable($n) }
    $env:WPD_HOME = Join-Path $script:fx 'home'
    $env:WPD_SITES_ROOT = Join-Path $script:fx 'sites'
    $env:WPD_INFRA_PREFIX = 'wpdunit'
    New-Item -ItemType Directory $env:WPD_SITES_ROOT -Force | Out-Null
}
AfterAll {
    Remove-Item $script:fx -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($n in $script:env0.Keys) { [Environment]::SetEnvironmentVariable($n, $script:env0[$n]) }
}

Describe 'ConvertTo-ShSingleQuoted' {
    It 'wraps in single quotes' { ConvertTo-ShSingleQuoted '/var/www/x' | Should -Be "'/var/www/x'" }
    It 'neutralizes an injection attempt' {
        ConvertTo-ShSingleQuoted "/x'; rm -rf ~; '" | Should -Be "'/x'\''; rm -rf ~; '\'''"
    }
}

Describe 'Assert-SshTarget / Assert-RemotePath' {
    It 'accepts user@host and aliases' {
        foreach ($t in 'me@example.com', 'my-alias', 'deploy@10.0.0.5', 'a_b.c@host-1') { { Assert-SshTarget $t } | Should -Not -Throw }
    }
    It 'rejects option-like, spaced and shell-ish targets' {
        foreach ($t in '-oProxyCommand=calc', '-x', 'a b', 'a;b', 'me@host$(id)', '', 'a@b/c', "a`nb") {
            { Assert-SshTarget $t } | Should -Throw "*SSH target*"
        }
    }
    It 'accepts absolute paths, including odd characters, and rejects the rest' {
        { Assert-RemotePath '/var/www/my site/wp' } | Should -Not -Throw
        { Assert-RemotePath "/x'; rm -rf ~; '" } | Should -Not -Throw
        foreach ($p in 'relative/path', '-rf', '', "/a`nb", "/a`0b", "/a`rb") { { Assert-RemotePath $p } | Should -Throw "*remote path*" }
    }
}

Describe 'Invoke-WpdProcess (real process, byte-exact)' {
    It 'streams stdout to a file without altering bytes and reports exit code and stderr' {
        $out = Join-Path $script:fx 'rt.tgz'
        $r = Invoke-WpdProcess -FilePath (Get-TarPath) -ArgumentList @('-czf', '-', '-C', (Join-Path $script:fx 'src'), 'uploads') -OutFile $out
        $r.ExitCode | Should -Be 0
        $dest = Join-Path $script:fx 'rt'
        New-Item -ItemType Directory $dest | Out-Null
        & (Get-TarPath) -xzf $out -C $dest
        [IO.File]::ReadAllBytes((Join-Path $dest 'uploads/2024/a.bin')) | Should -Be ([byte[]](0..255 + 255..0))
        $bad = Invoke-WpdProcess -FilePath (Get-TarPath) -ArgumentList @('-czf', '-', '-C', $script:fx, 'does-not-exist') -OutFile (Join-Path $script:fx 'bad.tgz')
        $bad.ExitCode | Should -Not -Be 0
        $bad.Stderr | Should -Not -BeNullOrEmpty
    }
}

Describe 'Expand-WpdTar' {
    It 'extracts a real archive into an empty directory' {
        $d = Join-Path $script:fx 'ex'
        Expand-WpdTar -Archive $script:tgz -Destination $d
        Get-Content (Join-Path $d 'themes/mytheme/style.css') | Should -Match 'mytheme'
        (Get-Item (Join-Path $d 'uploads/2024/a.bin')).Length | Should -Be 512
    }
    It 'throws on a corrupt archive' {
        $bad = Join-Path $script:fx 'bad.tar.gz'
        [IO.File]::WriteAllBytes($bad, [byte[]](1..200))
        { Expand-WpdTar -Archive $bad -Destination (Join-Path $script:fx 'exbad') } | Should -Throw '*extract*'
    }
}

Describe 'Get-SqlTablePrefix' {
    It 'finds a non-default prefix, ignoring plugin tables that merely end in options' {
        $f = Join-Path $script:fx 'p.sql'
        @('CREATE TABLE `zz_aioseo_options` (a int);', 'CREATE TABLE `zz_options` (a int);', 'CREATE TABLE `zz_posts` (a int);',
          'CREATE TABLE `zz_users` (a int);', 'INSERT INTO `zz_options` VALUES (1);') | Set-Content $f
        Get-SqlTablePrefix $f | Should -Be 'zz_'
    }
    It 'handles IF NOT EXISTS and the wp_ default' {
        $f = Join-Path $script:fx 'p2.sql'
        @('CREATE TABLE IF NOT EXISTS `wp_options` (a int);', 'CREATE TABLE IF NOT EXISTS `wp_posts` (a int);', 'CREATE TABLE IF NOT EXISTS `wp_users` (a int);') | Set-Content $f
        Get-SqlTablePrefix $f | Should -Be 'wp_'
    }
    It 'throws when no WordPress tables are present' {
        $f = Join-Path $script:fx 'p3.sql'
        'CREATE TABLE `foo` (a int);' | Set-Content $f
        { Get-SqlTablePrefix $f } | Should -Throw '*WordPress*'
    }
}

Describe 'Import-LiveSite (ssh/scp mocked at the Invoke-WpdProcess helper)' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:hasWp = 0; $script:dumpExit = 0; $script:tarExit = 0; $script:rmExit = 0; $script:sshExit = 0
        $script:imported = $null; $script:cleaned = @(); $script:created = 0; $script:importThrow = $null
        Mock Assert-DockerRunning {}
        Mock Invoke-WpdProcess {
            if ($FilePath -ne 'ssh') { return (& $script:realProc -FilePath $FilePath -ArgumentList $ArgumentList -OutFile $OutFile) }   # tar runs for real
            $script:calls.Add([pscustomobject]@{ File = $FilePath; Args = @($ArgumentList); OutFile = $OutFile })
            $cmd = "$($ArgumentList[-1])"
            $r = @{ ExitCode = 0; Stdout = ''; Stderr = '' }
            if ($script:sshExit) { return [pscustomobject]@{ ExitCode = $script:sshExit; Stdout = ''; Stderr = 'Host key verification failed.' } }
            if ($cmd -like 'command -v wp*') { $r.ExitCode = $script:hasWp }
            elseif ($cmd -like '*option get siteurl*') { $r.Stdout = "Deprecated: noise`nhttps://live.example.com`n" }
            elseif ($cmd -like '*db export*') { $r.ExitCode = $script:dumpExit; if ($script:dumpExit) { $r.Stderr = 'dump failed' } }
            elseif ($cmd -like 'cat *') { Copy-Item $script:sql $OutFile }
            elseif ($cmd -like '*tar czf*') {
                $r.ExitCode = $script:tarExit
                if ($script:tarExit) { [IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3)); $r.Stderr = 'tar: broken pipe' } else { Copy-Item $script:tgz $OutFile }
            }
            elseif ($cmd -like 'rm -f*') { $r.ExitCode = $script:rmExit }
            [pscustomobject]$r
        }
        Mock New-WpdSite { $script:created++; [pscustomobject]@{ Name = $Name; Url = "https://$Name.test"; Path = (Join-Path $env:WPD_SITES_ROOT $Name); AdminUser = 'admin'; AdminPassword = 'pw' } }
        Mock Import-SiteContent {
            if ($script:importThrow) { throw $script:importThrow }
            $script:imported = [pscustomobject]@{
                ContentDir = $ContentDir; SqlFile = $SqlFile; OldUrl = $OldUrl; NoUploads = [bool]$NoUploads
                Theme = (Test-Path (Join-Path $ContentDir 'themes/mytheme/style.css')); SqlText = (Get-Content $SqlFile -Raw)
            }
        }
        Mock Remove-SiteDockerObjects { $script:cleaned += 'docker' }
        Mock Remove-SiteFiles { $script:cleaned += 'files' }
        Mock Update-TraefikCerts { $script:cleaned += 'traefik' }
    }

    It 'pulls with exact, option-injection-proof ssh argument arrays and imports real extracted content' {
        $r = Import-LiveSite -Name 'acme' -Target 'me@example.com' -RemotePath '/var/www/live'
        $r.Name | Should -Be 'acme'
        $pre = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '--', 'me@example.com')
        foreach ($c in $script:calls) {
            $c.File | Should -Be 'ssh'
            @($c.Args[0..5]) | Should -Be $pre
            $c.Args.Count | Should -Be 7
        }
        $cmds = @($script:calls | ForEach-Object { $_.Args[6] })
        $cmds[0] | Should -Be 'command -v wp >/dev/null 2>&1'
        $cmds[1] | Should -Be "wp --path='/var/www/live' option get siteurl --skip-plugins --skip-themes"
        $dumpCmd = $cmds | Where-Object { $_ -like '*db export*' }
        $dumpCmd | Should -Match "^umask 077; wp --path='/var/www/live' db export '/tmp/wpd-[0-9a-f]{32}\.sql' --add-drop-table$"
        ($cmds | Where-Object { $_ -like 'cat *' }) | Should -Match "^cat '/tmp/wpd-[0-9a-f]{32}\.sql'$"
        ($cmds | Where-Object { $_ -like '*tar czf*' }) | Should -Match "^cd '/var/www/live/wp-content' && .*tar czf - "
        ($cmds | Where-Object { $_ -like 'rm -f*' }) | Should -Match "^rm -f '/tmp/wpd-[0-9a-f]{32}\.sql'$"
        $script:imported.OldUrl | Should -Be 'https://live.example.com'
        $script:imported.Theme | Should -BeTrue
        $script:imported.SqlText | Should -Match 'zz_options'
        $script:imported.NoUploads | Should -BeFalse
        Test-Path $script:imported.ContentDir | Should -BeFalse   # temp dir removed
    }
    It 'quotes a hostile remote path so it cannot break out of the remote shell' {
        Import-LiveSite -Name 'acme' -Target 'host' -RemotePath "/x'; rm -rf ~; '" | Out-Null
        $all = ($script:calls | ForEach-Object { $_.Args[6] }) -join "`n"
        $all | Should -Match ([regex]::Escape("--path='/x'\''; rm -rf ~; '\'''"))
        $all | Should -Not -Match "--path='/x'; rm"
    }
    It 'rejects a hostile ssh target before any process runs' {
        { Import-LiveSite -Name 'acme' -Target '-oProxyCommand=calc' -RemotePath '/x' } | Should -Throw '*SSH target*'
        { Import-LiveSite -Name 'acme' -Target 'a b' -RemotePath '/x' } | Should -Throw '*SSH target*'
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath "/x`n/y" } | Should -Throw '*remote path*'
        { Import-LiveSite -Name 'Bad Name' -Target 'host' -RemotePath '/x' } | Should -Throw '*Invalid site name*'
        Should -Invoke Invoke-WpdProcess -Times 0 -Exactly
    }
    It 'refuses an existing site folder without any ssh traffic and leaves it alone' {
        $d = Join-Path $env:WPD_SITES_ROOT 'exists'
        New-Item -ItemType Directory $d -Force | Out-Null
        try {
            { Import-LiveSite -Name 'exists' -Target 'host' -RemotePath '/x' } | Should -Throw '*already exists*'
            Should -Invoke Invoke-WpdProcess -Times 0 -Exactly
            Test-Path $d | Should -BeTrue
            $script:cleaned | Should -BeNullOrEmpty
        } finally { Remove-Item $d -Recurse -Force }
    }
    It 'stops with "WP-CLI not found on the remote" and leaves no site folder' {
        $script:hasWp = 1
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' } | Should -Throw '*WP-CLI not found on the remote*'
        Should -Invoke New-WpdSite -Times 0 -Exactly
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'acme') | Should -BeFalse
    }
    It 'excludes uploads from the tar with -NoUploads and includes them otherwise' {
        Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' -NoUploads | Out-Null
        $tar = @($script:calls | ForEach-Object { $_.Args[6] } | Where-Object { $_ -like '*tar czf*' })
        $tar.Count | Should -Be 1
        $tar[0] | Should -Not -Match 'uploads'
        $tar[0] | Should -Match 'themes plugins mu-plugins'
        $script:imported.NoUploads | Should -BeTrue
        $script:calls.Clear()
        Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' | Out-Null
        (@($script:calls | ForEach-Object { $_.Args[6] } | Where-Object { $_ -like '*tar czf*' }))[0] | Should -Match 'uploads'
    }
    It 'on a failure mid-pull never creates the site, removes the temp dir and the remote dump' {
        $script:tarExit = 2
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' } | Should -Throw '*tar*'
        Should -Invoke New-WpdSite -Times 0 -Exactly
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'acme') | Should -BeFalse
        @($script:calls | ForEach-Object { $_.Args[6] } | Where-Object { $_ -like 'rm -f*' }).Count | Should -Be 1
        $tmpOut = ($script:calls | Where-Object { $_.OutFile -and $_.Args[6] -like '*tar czf*' }).OutFile
        Test-Path (Split-Path $tmpOut) | Should -BeFalse
    }
    It 'removes the remote dump even when the export itself fails' {
        $script:dumpExit = 1
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' } | Should -Throw '*dump failed*'
        @($script:calls | ForEach-Object { $_.Args[6] } | Where-Object { $_ -like 'rm -f*' }).Count | Should -Be 1
        Should -Invoke New-WpdSite -Times 0 -Exactly
    }
    It 'only warns when the remote dump cannot be deleted' {
        $script:rmExit = 1
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' 3>$null } | Should -Not -Throw
    }
    It 'explains a connection or host key failure (exit 255) without offering to bypass checking' {
        $script:sshExit = 255
        $err = $null
        try { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Host key verification failed'
        $err | Should -Match 'ssh host'
        $err | Should -Not -Match 'StrictHostKeyChecking'
    }
    It 'cleans up everything it created when the import fails before completing' {
        $script:importThrow = 'wp db import failed'
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' 3>$null } | Should -Throw '*wp db import failed*'
        $script:cleaned | Should -Contain 'docker'
        $script:cleaned | Should -Contain 'files'
        $script:cleaned | Should -Contain 'traefik'
    }
    It 'keeps the site and says it needs attention when only the final safety check throws' {
        $ex = [InvalidOperationException]::new('the clone was created but needs attention: live URL left')
        $ex.Data['WpdImported'] = $true
        $script:importThrow = $ex
        { Import-LiveSite -Name 'acme' -Target 'host' -RemotePath '/x' } | Should -Throw '*created but needs attention*'
        $script:cleaned | Should -BeNullOrEmpty
    }
}

Describe 'Import-SiteContent (docker and WP-CLI mocked)' {
    BeforeEach {
        $script:wp = [System.Collections.Generic.List[string]]::new()
        $script:dk = [System.Collections.Generic.List[string]]::new()
        $script:cp = [System.Collections.Generic.List[string]]::new()
        $script:safety = $null
        $site = Join-Path $env:WPD_SITES_ROOT 'imp'
        foreach ($d in 'themes', 'plugins', 'mu-plugins') { New-Item -ItemType Directory (Join-Path $site "wp-content/$d") -Force | Out-Null }
        Set-Content (Join-Path $site 'docker-compose.yml') '# Rendered by wpd'
        Set-Content (Join-Path $site '.wpd-credentials.txt') "Site: x`nAdmin password: old`nDB name: wordpress"
        $script:content = Join-Path $script:fx 'content'
        Remove-Item $script:content -Recurse -Force -ErrorAction SilentlyContinue
        Expand-WpdTar -Archive $script:tgz -Destination $script:content
        Mock Assert-SiteExists {}
        Mock Invoke-SiteWpCli { $script:wp.Add(($WpArgs -join ' ')); if (($WpArgs -join ' ') -like 'user get*') { throw 'no such user' } }
        Mock Invoke-SiteCompose { $script:dk.Add(($ComposeArgs -join ' ')); if ($ComposeArgs[0] -eq 'ps') { 'cid123' } }
        Mock Invoke-Docker { $script:cp.Add(($DockerArgs -join ' ')) }
        Mock Set-CloneSafety { $script:safety = "$Name|$OldUrl"; if ($script:safetyThrow) { throw $script:safetyThrow } }
        $script:safetyThrow = $null
    }
    AfterEach { Remove-Item (Join-Path $env:WPD_SITES_ROOT 'imp') -Recurse -Force -ErrorAction SilentlyContinue }

    It 'copies code folders to the bind mounts, sets the prefix before importing, then applies clone safety' {
        Import-SiteContent -Name 'imp' -ContentDir $script:content -SqlFile $script:sql -OldUrl 'https://live.example.com' -AdminPassword 'newpw'
        $site = Join-Path $env:WPD_SITES_ROOT 'imp/wp-content'
        Test-Path (Join-Path $site 'themes/mytheme/style.css') | Should -BeTrue
        Test-Path (Join-Path $site 'plugins/myplugin/myplugin.php') | Should -BeTrue
        $iConfig = $script:wp.FindIndex({ param($s) $s -like 'config set table_prefix zz_*' })
        $iImport = $script:wp.FindIndex({ param($s) $s -like 'db import*' })
        $iConfig | Should -BeGreaterOrEqual 0
        $iImport | Should -BeGreaterThan $iConfig
        $script:wp[$iImport - 1] | Should -Be 'db clean --yes'
        ($script:cp -join "`n") | Should -Match 'cp .*uploads.*cid123:/var/www/html/wp-content/uploads/'
        ($script:dk -join "`n") | Should -Match 'chown -R www-data:www-data /var/www/html/wp-content/uploads'
        $script:safety | Should -Be 'imp|https://live.example.com'
        (Get-Content (Join-Path $env:WPD_SITES_ROOT 'imp/.wpd-credentials.txt') -Raw) | Should -Match 'Admin password: newpw'
    }
    It 'skips uploads with -NoUploads' {
        Import-SiteContent -Name 'imp' -ContentDir $script:content -SqlFile $script:sql -OldUrl 'https://live.example.com' -NoUploads
        ($script:cp -join "`n") | Should -Not -Match 'uploads'
    }
    It 'does not set a prefix for the wp_ default' {
        $f = Join-Path $script:fx 'wp.sql'
        @('CREATE TABLE `wp_options` (a int);', 'CREATE TABLE `wp_posts` (a int);', 'CREATE TABLE `wp_users` (a int);') | Set-Content $f
        Import-SiteContent -Name 'imp' -ContentDir $script:content -SqlFile $f -OldUrl 'https://live.example.com'
        $script:wp | Where-Object { $_ -like 'config set table_prefix*' } | Should -BeNullOrEmpty
    }
    It 'fails before touching anything when the dump has no WordPress tables or the URL is invalid' {
        $f = Join-Path $script:fx 'junk.sql'; 'select 1;' | Set-Content $f
        { Import-SiteContent -Name 'imp' -ContentDir $script:content -SqlFile $f -OldUrl 'https://live.example.com' } | Should -Throw '*WordPress*'
        { Import-SiteContent -Name 'imp' -ContentDir $script:content -SqlFile $script:sql -OldUrl 'not a url' } | Should -Throw '*Invalid live URL*'
        $script:wp.Count | Should -Be 0
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'imp/wp-content/themes/mytheme') | Should -BeFalse
    }
    It 'wraps a final safety failure as "created but needs attention" flagged as imported' {
        $script:safetyThrow = 'A live URL for x is still present'
        $err = $null
        try { Import-SiteContent -Name 'imp' -ContentDir $script:content -SqlFile $script:sql -OldUrl 'https://live.example.com' } catch { $err = $_.Exception }
        $err.Message | Should -Match 'the clone was created but needs attention: A live URL'
        $err.Data['WpdImported'] | Should -BeTrue
    }
}

# Opt-in: set WPD_INTEGRATION=1. Alternate ports and prefix, never touches 80/443/53 or Laragon.
# Real Docker, no SSH: a source site is exported with WP-CLI and imported into a second site as if it were a live pull.
Describe 'Import-SiteContent integration (real Docker, alternate ports)' -Tag Integration -Skip:(-not $env:WPD_INTEGRATION) {
    BeforeAll {
        $script:keep = @{}
        foreach ($n in 'WPD_HOME', 'WPD_SITES_ROOT', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_PREFIX') {
            $script:keep[$n] = [Environment]::GetEnvironmentVariable($n)
        }
        $base = if ($env:WPD_INT_BASE) { $env:WPD_INT_BASE } else { [IO.Path]::GetTempPath() }
        $script:tmp = Join-Path $base "wpd imp int $([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory $script:tmp -Force | Out-Null
        $env:WPD_HOME = Join-Path $script:tmp 'home'
        $env:WPD_SITES_ROOT = Join-Path $script:tmp 'sites'
        $env:WPD_HTTP_PORT = '8080'; $env:WPD_HTTPS_PORT = '8443'; $env:WPD_DNS_PORT = '5354'; $env:WPD_INFRA_PREFIX = 'wpdtest'
    }
    AfterAll {
        foreach ($proj in 'wpdtest-srcsite', 'wpdtest-dstsite', 'wpdtest-dstnoup') {
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
    It 'imports wp-content and a database with another table prefix into a new site, safely' {
        Initialize-Infra
        New-WpdSite 'srcsite' | Out-Null
        $live = 'live.example.com'
        # Source "live" site: other table prefix, a theme, a plugin, an upload, a post and an option carrying the live URL.
        Invoke-SiteWpCli 'srcsite' @('config', 'set', 'table_prefix', 'zz_', '--type=variable') | Out-Null
        Invoke-SiteWpCli 'srcsite' @('db', 'clean', '--yes') | Out-Null
        Invoke-SiteWpCli 'srcsite' @('core', 'install', '--url=https://live.example.com', '--title=Live', '--admin_user=liveadmin', '--admin_password=Zx9-live-pass-1', '--admin_email=a@live.example.com', '--skip-email') | Out-Null
        Invoke-SiteWpCli 'srcsite' @('post', 'create', '--post_title=Hello Live', '--post_status=publish', "--post_content=<a href=`"https://$live/p`">x</a>") | Out-Null
        Invoke-SiteWpCli 'srcsite' @('option', 'update', 'wpd_live_opt', "https://$live/x and //www.$live/y") | Out-Null
        $sc = Join-Path $env:WPD_SITES_ROOT 'srcsite/wp-content'
        New-Item -ItemType Directory (Join-Path $sc 'themes/livetheme') -Force | Out-Null
        Set-Content (Join-Path $sc 'themes/livetheme/style.css') '/* Theme Name: livetheme */'
        New-Item -ItemType Directory (Join-Path $sc 'plugins/liveplugin') -Force | Out-Null
        Set-Content (Join-Path $sc 'plugins/liveplugin/liveplugin.php') '<?php /* Plugin Name: liveplugin */'
        $exp = Join-Path $script:tmp 'export'
        New-Item -ItemType Directory (Join-Path $exp 'uploads/2024') -Force | Out-Null
        Copy-Item (Join-Path $sc 'themes') $exp -Recurse; Copy-Item (Join-Path $sc 'plugins') $exp -Recurse
        [IO.File]::WriteAllBytes((Join-Path $exp 'uploads/2024/live.bin'), [byte[]](0..255))
        Invoke-SiteWpCli 'srcsite' @('db', 'export', 'wpd-export.sql', '--add-drop-table') | Out-Null
        $cid = (Invoke-SiteCompose 'srcsite' @('ps', '-q', 'wordpress')) | Select-Object -First 1
        $sqlFile = Join-Path $script:tmp 'live.sql'
        Invoke-Docker @('cp', "${cid}:/var/www/html/wpd-export.sql", $sqlFile) | Out-Null
        (Get-Content $sqlFile -Raw) | Should -Match '`zz_options`'

        # Import with uploads.
        New-WpdSite 'dstsite' | Out-Null
        $before = Get-Content (Join-Path $env:WPD_SITES_ROOT 'dstsite/docker-compose.yml') -Raw
        Import-SiteContent -Name 'dstsite' -ContentDir $exp -SqlFile $sqlFile -OldUrl "https://$live" -AdminPassword 'Local-Admin-Pw-9'
        $dc = Join-Path $env:WPD_SITES_ROOT 'dstsite/wp-content'
        Test-Path (Join-Path $dc 'themes/livetheme/style.css') | Should -BeTrue
        Test-Path (Join-Path $dc 'plugins/liveplugin/liveplugin.php') | Should -BeTrue
        Test-Path (Join-Path $dc 'mu-plugins/wpd-mail.php') | Should -BeTrue
        $up = (Invoke-SiteCompose 'dstsite' @('exec', '-T', 'wordpress', 'ls', '/var/www/html/wp-content/uploads/2024')) -join ' '
        $up | Should -Match 'live\.bin'
        (Invoke-SiteWpCli 'dstsite' @('post', 'list', '--field=post_title') -join "`n") | Should -Match 'Hello Live'
        (Invoke-SiteWpCli 'dstsite' @('config', 'get', 'table_prefix')) -join '' | Should -Be 'zz_'
        (Invoke-SiteWpCli 'dstsite' @('option', 'get', 'wpd_live_opt')) -join '' | Should -Be 'https://dstsite.test:8443/x and //dstsite.test:8443/y'
        (Invoke-SiteWpCli 'dstsite' @('db', 'search', $live, '--all-tables', '--table_column_once', '--one_line')) | Should -BeNullOrEmpty
        $cfg = (Invoke-SiteCompose 'dstsite' @('exec', '-T', 'wordpress', 'cat', 'wp-config.php')) -join "`n"
        $cfg | Should -Not -Match 'live\.example'
        $cfg | Should -Not -Match "define\(\s*'WP_HOME', 'https://live"
        $code = & curl.exe --silent --show-error --ssl-no-revoke --resolve 'dstsite.test:8443:127.0.0.1' -o NUL -w '%{http_code}' 'https://dstsite.test:8443/'
        $code | Should -Be '200'
        # The local admin works even though the imported users table replaced the original one.
        (Invoke-SiteWpCli 'dstsite' @('user', 'list', '--field=user_login')) -join ' ' | Should -Match 'admin'
        # Mail routing mu-plugin and the rm marker survive.
        (Get-Content (Join-Path $env:WPD_SITES_ROOT 'dstsite/docker-compose.yml') -Raw) | Should -Be $before
        Test-WpdSiteFolder (Join-Path $env:WPD_SITES_ROOT 'dstsite') | Should -BeTrue

        # Import without uploads.
        New-WpdSite 'dstnoup' | Out-Null
        Import-SiteContent -Name 'dstnoup' -ContentDir $exp -SqlFile $sqlFile -OldUrl "https://$live" -NoUploads
        $up2 = try { (Invoke-SiteCompose 'dstnoup' @('exec', '-T', 'wordpress', 'ls', '/var/www/html/wp-content/uploads/2024')) -join ' ' } catch { '' }
        $up2 | Should -Not -Match 'live\.bin'
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'dstnoup/wp-content/themes/livetheme/style.css') | Should -BeTrue

        # rm works on an imported site.
        Remove-WpdSite dstsite -Force
        Test-Path (Join-Path $env:WPD_SITES_ROOT 'dstsite') | Should -BeFalse
        (& docker ps -a -q --filter 'label=com.docker.compose.project=wpdtest-dstsite') | Should -BeNullOrEmpty
    }
}
