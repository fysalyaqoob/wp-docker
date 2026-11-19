# Clone a live WordPress site over SSH (Windows OpenSSH / macOS ssh, tar over ssh, remote WP-CLI).
# Key or agent authentication only: ssh runs with BatchMode=yes, so it never prompts for a password, and host key
# checking is left at ssh's default (an unknown host fails with a hint to run `ssh <target>` once and answer its prompt).
# NOT verified against a real server (no live SSH test exists); the ssh calls are covered by mocks only.

function ConvertTo-ShSingleQuoted {
    # Safe for a POSIX remote shell: a single quote becomes '\''.
    param([Parameter(Mandatory)][string]$Text)
    "'" + $Text.Replace("'", "'\''") + "'"
}

function Assert-SshTarget {
    # user@host or a host alias from ~/.ssh/config. No leading "-" (would be an ssh option), no spaces or shell characters.
    param([string]$Target)
    if ($Target -notmatch '^[A-Za-z0-9._@-]+\z' -or $Target.StartsWith('-') -or $Target.Length -gt 255) {
        throw "Invalid SSH target '$Target'. Use user@host or a host alias (letters, digits, dots, underscores, hyphens and @ only, not starting with '-')."
    }
}

function Assert-RemotePath {
    param([string]$Path)
    if ($Path -notmatch '^/[^\r\n\0]*\z' -or $Path.Length -gt 4096) {
        throw "Invalid remote path '$Path'. Use the absolute path of the WordPress folder on the server, for example /var/www/html (no line breaks, must start with /)."
    }
}

function Invoke-WpdSsh {
    # One remote command. Returns the Invoke-WpdProcess result. Exit 255 is ssh itself failing (connect, auth, host key).
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$RemoteCommand, [string]$OutFile, [switch]$AllowFailure)
    $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '--', $Target, $RemoteCommand)
    $r = if ($OutFile) { Invoke-WpdProcess -FilePath 'ssh' -ArgumentList $a -OutFile $OutFile } else { Invoke-WpdProcess -FilePath 'ssh' -ArgumentList $a }
    if ($r.ExitCode -eq 255) {
        throw ("Could not connect to '$Target' over SSH: $("$($r.Stderr)".Trim())`n" +
            "wpd uses key or agent login only and never asks for a password. If this is a new host, run  ssh $Target  once and answer its host key prompt, then try again.")
    }
    if ($r.ExitCode -ne 0 -and -not $AllowFailure) { throw "Remote command failed (exit $($r.ExitCode)): $("$($r.Stderr)".Trim())" }
    $r
}

function Expand-WpdTar {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory $Destination -Force | Out-Null
    # bsdtar/GNU tar refuse absolute paths and ".." members by default; no -P is passed on purpose.
    $r = Invoke-WpdProcess -FilePath (Get-TarPath) -ArgumentList @('-xzf', $Archive, '-C', $Destination)
    if ($r.ExitCode -ne 0) { throw "Could not extract the downloaded wp-content archive: $("$($r.Stderr)".Trim())" }
    $l = @(Get-ChildItem -LiteralPath $Destination -Recurse -Force | Where-Object LinkType)
    if ($l) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue; throw "Archive contains links (e.g. $($l[0].FullName)); refusing." }
}

function Get-SqlTablePrefix {
    # The table prefix is the P for which P+options, P+posts and P+users all exist in the dump (a plugin table such as
    # aioseo_options alone does not qualify). Streams the file; nothing is held but table names.
    param([Parameter(Mandatory)][string]$SqlFile)
    $names = [System.Collections.Generic.HashSet[string]]::new()
    $rd = [IO.File]::OpenText($SqlFile)
    try {
        while ($null -ne ($line = $rd.ReadLine())) {
            if ($line.StartsWith('CREATE TABLE') -and $line -match '^CREATE TABLE (?:IF NOT EXISTS )?`([^`]+)`') { [void]$names.Add($Matches[1]) }
        }
    } finally { $rd.Dispose() }
    $found = @($names | Where-Object { $_ -like '*options' } | ForEach-Object { $_.Substring(0, $_.Length - 7) } |
        Where-Object { $_ -match '^[A-Za-z0-9_]*\z' -and $names.Contains("${_}posts") -and $names.Contains("${_}users") } | Sort-Object Length)
    if (-not $found) { throw 'The database dump does not contain WordPress tables (no options, posts and users tables with a common prefix).' }
    $found[0]
}

function Set-SiteAdminPassword {
    # An imported users table replaces the admin created by New-WpdSite, so make the login wpd printed work again.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Password)
    $c = Get-WpdConfig
    $env:WPD_ADMIN_PW = $Password
    try {
        $exists = $true
        try { Invoke-SiteWpCli $Name @('user', 'get', 'admin', '--field=ID', '--skip-plugins', '--skip-themes') | Out-Null } catch { $exists = $false }
        $script = if ($exists) { 'wp user update admin --user_pass="$WPD_ADMIN_PW" --skip-plugins --skip-themes && wp user set-role admin administrator --skip-plugins --skip-themes' }
                  else { 'wp user create admin "$1" --role=administrator --user_pass="$WPD_ADMIN_PW" --skip-plugins --skip-themes' }
        Invoke-SiteCompose $Name @('--profile', 'tools', 'run', '--rm', '-T', '-e', 'WPD_ADMIN_PW', 'wpcli', 'sh', '-c', $script, 'sh', "admin@$Name.$($c.Tld)") | Out-Null
    } finally { Remove-Item Env:WPD_ADMIN_PW -ErrorAction SilentlyContinue }
    $cred = Join-Path (Join-Path $c.SitesRoot $Name) '.wpd-credentials.txt'
    if (Test-Path -LiteralPath $cred) {
        Write-SiteFile $cred ((Get-Content -LiteralPath $cred -Raw) -replace '(?m)^Admin password: .*$', ('Admin password: ' + $Password.Replace('$', '$$')))
    }
}

function Clear-SiteDatabase {
    # Drops every table through wpdb. `wp db clean` is not used: it shells out to the mysql client, which in the
    # wordpress:cli image insists on TLS that the MariaDB container does not offer (verified), and it refuses to run
    # once the configured table prefix has no tables. Needs the configured prefix to still match the current tables.
    param([Parameter(Mandatory)][string]$Name)
    Invoke-SiteWpCli $Name @('eval', '--skip-plugins', '--skip-themes',
        'global $wpdb; $wpdb->query("SET FOREIGN_KEY_CHECKS=0"); foreach ($wpdb->get_col("SHOW TABLES") as $t) { $wpdb->query("DROP TABLE IF EXISTS `$t`"); }') | Out-Null
}

function Import-SiteContent {
    # Puts live content into an existing, running wpd site. Independent of SSH (also used for .wpress).
    # ContentDir holds themes/, plugins/, mu-plugins/ and optionally uploads/ (WordPress core and wp-config.php are never
    # imported, so the local WP_HOME/WP_SITEURL stay in force). SqlFile is a mysqldump of the live database.
    # Throws a plain error for anything before the import completes (the caller removes the site). A failure after the
    # import throws "the clone was created but needs attention: ..." with Data['WpdImported'] = $true (keep the site).
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ContentDir,
        [Parameter(Mandatory)][string]$SqlFile,
        [Parameter(Mandatory)][string]$OldUrl,
        [switch]$NoUploads,
        [string]$AdminPassword
    )
    Assert-SiteExists $Name
    if (-not (Test-Path -LiteralPath $ContentDir -PathType Container)) { throw "Content folder not found: $ContentDir" }
    if (-not (Test-Path -LiteralPath $SqlFile -PathType Leaf)) { throw "Database dump not found: $SqlFile" }
    $prefix = Get-SqlTablePrefix $SqlFile
    $null = Get-UrlReplacements $OldUrl (Get-SiteUrl $Name)   # validates the URL before anything is changed
    $dir = Join-Path (Get-WpdConfig).SitesRoot $Name

    Write-Host 'Copying themes, plugins and mu-plugins...'
    foreach ($d in 'themes', 'plugins', 'mu-plugins') {
        $from = Join-Path $ContentDir $d
        if (-not (Test-Path -LiteralPath $from -PathType Container)) { continue }
        $to = Join-Path $dir "wp-content/$d"
        New-Item -ItemType Directory $to -Force | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $from -Force) { Copy-Item -LiteralPath $item.FullName -Destination $to -Recurse -Force }
    }

    $cid = (Invoke-SiteCompose $Name @('ps', '-q', 'wordpress') | Select-Object -First 1)
    if (-not $cid) { throw "The WordPress container of '$Name' is not running." }
    $uploads = Join-Path $ContentDir 'uploads'
    if (-not $NoUploads -and (Test-Path -LiteralPath $uploads -PathType Container)) {
        Write-Host 'Copying uploads into the uploads volume...'
        Invoke-Docker @('cp', "$uploads$([IO.Path]::DirectorySeparatorChar).", "${cid}:/var/www/html/wp-content/uploads/") | Out-Null
        Invoke-SiteCompose $Name @('exec', '-T', '-u', 'root', 'wordpress', 'chown', '-R', 'www-data:www-data', '/var/www/html/wp-content/uploads') | Out-Null
    }

    # The live tables may use another prefix; WordPress must read the ones being imported.
    # Order matters: db clean only works while the configured prefix (wp_) still has tables, so clean first.
    Write-Host "Importing the database (table prefix $prefix)..."
    Clear-SiteDatabase $Name
    if ($prefix -ne 'wp_') { Invoke-SiteWpCli $Name @('config', 'set', 'table_prefix', $prefix, '--type=variable') | Out-Null }
    # /var/www/html is the core volume, shared with the WP-CLI container.
    Invoke-Docker @('cp', $SqlFile, "${cid}:/var/www/html/wpd-import.sql") | Out-Null
    try {
        Invoke-SiteCompose $Name @('exec', '-T', '-u', 'root', 'wordpress', 'chmod', '644', '/var/www/html/wpd-import.sql') | Out-Null
        # The mysql client directly, not `wp db import`: WP-CLI queries the server first without passing --skip-ssl and fails (verified).
        # The password stays in the container's own environment (MYSQL_PWD), never in a host-side argument.
        Invoke-SiteCompose $Name @('--profile', 'tools', 'run', '--rm', '-T', 'wpcli', 'sh', '-c',
            'MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql --skip-ssl -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" < wpd-import.sql') | Out-Null
    } finally {
        try { Invoke-SiteCompose $Name @('exec', '-T', '-u', 'root', 'wordpress', 'rm', '-f', '/var/www/html/wpd-import.sql') | Out-Null } catch { Write-Warning "Could not delete the temporary dump in the container: $($_.Exception.Message)" }
    }

    # From here the data is in; a failure keeps the site.
    try {
        if ($AdminPassword) { Set-SiteAdminPassword $Name $AdminPassword }
        try { Invoke-SiteWpCli $Name @('rewrite', 'flush', '--hard') | Out-Null } catch { Write-Warning "Permalinks were not flushed: $($_.Exception.Message)" }
        Write-Host 'Applying clone safety defaults...'
        Set-CloneSafety -Name $Name -OldUrl $OldUrl
    } catch {
        $ex = [InvalidOperationException]::new("the clone was created but needs attention: $($_.Exception.Message)")
        $ex.Data['WpdImported'] = $true
        throw $ex
    }
}

function Remove-FailedImportSite {
    # Removes only what this call created (the caller guarantees the site did not exist before).
    param([Parameter(Mandatory)][string]$Name)
    Write-Warning "Cloning '$Name' did not finish; removing what was created."
    try { Remove-SiteDockerObjects $Name } catch { Write-Warning "Docker cleanup incomplete: $($_.Exception.Message)" }
    try { Remove-SiteFiles $Name } catch { Write-Warning "File cleanup incomplete: $($_.Exception.Message)" }
    try { Update-TraefikCerts } catch { Write-Warning "Could not reload Traefik: $($_.Exception.Message)" }
}

function Import-LiveSite {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RemotePath,
        [switch]$NoUploads
    )
    Assert-SiteName $Name
    Assert-SshTarget $Target
    Assert-RemotePath $RemotePath
    $rp = if ($RemotePath.Length -gt 1) { $RemotePath.TrimEnd('/') } else { $RemotePath }
    $dir = Join-Path (Get-WpdConfig).SitesRoot $Name
    if (Test-Path -LiteralPath $dir) { throw "Site '$Name' already exists (folder $dir). Nothing was changed. Remove it with 'wpd rm $Name' or pick another name." }
    Assert-DockerRunning

    $q = ConvertTo-ShSingleQuoted $rp
    $work = Join-Path ([IO.Path]::GetTempPath()) "wpd-clone-$([guid]::NewGuid().ToString('N'))"
    $remoteSql = "/tmp/wpd-$([guid]::NewGuid().ToString('N')).sql"
    $qSql = ConvertTo-ShSingleQuoted $remoteSql
    $dumpStarted = $false; $created = $false; $keep = $false
    try {
        New-Item -ItemType Directory $work -Force | Out-Null
        Write-Host "Connecting to $Target..."
        if ((Invoke-WpdSsh $Target 'command -v wp >/dev/null 2>&1' -AllowFailure).ExitCode -ne 0) {
            throw 'WP-CLI not found on the remote. Install WP-CLI on the server (https://wp-cli.org) and make sure `wp` is on the PATH of a non-interactive ssh session.'
        }
        $url = "$((Invoke-WpdSsh $Target "wp --path=$q option get siteurl --skip-plugins --skip-themes" -AllowFailure).Stdout)" -split "`r?`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^https?://\S+$' } | Select-Object -Last 1
        if (-not $url) { throw "Could not read the live site URL with WP-CLI. Is $RemotePath the WordPress folder (the one containing wp-config.php)?" }

        Write-Host 'Exporting the remote database...'
        $dumpStarted = $true
        Invoke-WpdSsh $Target "umask 077; wp --path=$q db export $qSql --add-drop-table" | Out-Null
        $sql = Join-Path $work 'live.sql'
        Write-Host 'Downloading the database dump...'
        Invoke-WpdSsh $Target "cat $qSql" -OutFile $sql | Out-Null
        if ((Get-Item -LiteralPath $sql).Length -eq 0) { throw 'The downloaded database dump is empty.' }

        $items = if ($NoUploads) { 'themes plugins mu-plugins' } else { 'themes plugins mu-plugins uploads' }
        $wc = ConvertTo-ShSingleQuoted "$rp/wp-content"
        Write-Host "Downloading wp-content ($($items.Replace(' ', ', '))); this can take a while..."
        $tgz = Join-Path $work 'content.tar.gz'
        Invoke-WpdSsh $Target "cd $wc && l=''; for d in $items; do [ -d `"`$d`" ] && l=`"`$l `$d`"; done; tar czf - `$l" -OutFile $tgz | Out-Null
        $content = Join-Path $work 'content'
        Expand-WpdTar -Archive $tgz -Destination $content
        Remove-Item -LiteralPath $tgz -Force

        # Pulled and unpacked; only now is anything created locally.
        $site = New-WpdSite $Name
        $created = $true
        Import-SiteContent -Name $Name -ContentDir $content -SqlFile $sql -OldUrl $url -NoUploads:$NoUploads -AdminPassword $site.AdminPassword
        $keep = $true
        $site
    } catch {
        if ($created -and $_.Exception.Data['WpdImported']) { $keep = $true }
        throw
    } finally {
        if ($dumpStarted) {
            try {
                $rm = Invoke-WpdSsh $Target "rm -f $qSql" -AllowFailure
                if ($rm.ExitCode -ne 0) { Write-Warning "Could not delete the database dump on the server ($remoteSql). Remove it by hand: $("$($rm.Stderr)".Trim())" }
            } catch { Write-Warning "Could not delete the database dump on the server ($remoteSql). Remove it by hand: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        if ($created -and -not $keep) { Remove-FailedImportSite $Name }
    }
}
