function Get-SiteTemplate {
    param([Parameter(Mandatory)][string]$File)
    Join-Path $PSScriptRoot "../templates/site/$File"
}

function Get-SiteProject {
    param([Parameter(Mandatory)][string]$Name)
    "$((Get-WpdConfig).InfraPrefix)-$Name"
}

function Get-SiteUrl {
    param([Parameter(Mandatory)][string]$Name, [string]$Prefix = '')
    $c = Get-WpdConfig
    $port = if ($c.HttpsPort -ne 443) { ":$($c.HttpsPort)" } else { '' }
    "https://$Prefix$Name.$($c.Tld)$port"
}

function Format-SiteCompose {
    # Renders templates/site/docker-compose.yml.tpl. Required: Name, Tld, Php, DbPassword. Optional: Network, HttpsPort, Project.
    param([Parameter(Mandatory)][hashtable]$Vars)
    foreach ($k in 'Name', 'Tld', 'Php', 'DbPassword') {
        if (-not $Vars[$k]) { throw "Format-SiteCompose: missing '$k'." }
    }
    $v = @{ Network = 'wpd-net'; HttpsPort = 443; Project = "wpd-$($Vars.Name)" }
    foreach ($k in $Vars.Keys) { $v[$k] = $Vars[$k] }
    $port = if ([int]$v.HttpsPort -ne 443) { ":$($v.HttpsPort)" } else { '' }
    $v.Url = "https://$($v.Name).$($v.Tld)$port"
    $text = (Get-Content (Get-SiteTemplate 'docker-compose.yml.tpl') -Raw) -replace "`r`n", "`n"
    foreach ($k in $v.Keys) { $text = $text.Replace("{{$k}}", [string]$v[$k]) }
    if ($text -match '\{\{(\w+)\}\}') { throw "Format-SiteCompose: unresolved token {{$($Matches[1])}}." }
    $text
}

function New-RandomPassword {
    # Letters and digits only, so the value is safe in YAML, shell and URLs.
    param([int]$Length = 24)
    $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    -join (1..$Length | ForEach-Object { $chars[[Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)] })
}

function Write-SiteFile {
    # UTF-8 without BOM, LF endings: these files are read by Docker and PHP.
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Invoke-SiteCompose {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$ComposeArgs, [switch]$Retry)
    $file = Join-Path (Join-Path (Get-WpdConfig).SitesRoot $Name) 'docker-compose.yml'
    $a = @('compose', '-p', (Get-SiteProject $Name), '-f', $file) + $ComposeArgs
    if ($Retry) { Invoke-DockerRetry $a } else { Invoke-Docker $a }
}

function Invoke-SiteWpCli {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$WpArgs)
    Invoke-SiteCompose $Name (@('--profile', 'tools', 'run', '--rm', '-T', 'wpcli', 'wp') + $WpArgs)
}

function Get-SiteCertFiles {
    param([Parameter(Mandatory)][string]$Name)
    $infra = (Get-WpdConfig).InfraRoot
    @(Join-Path $infra "certs/$Name.pem"; Join-Path $infra "certs/$Name-key.pem"; Join-Path $infra "dynamic/$Name.yml")
}

function Get-SiteDockerObjects {
    # Containers, volumes and networks carrying exactly this site's compose project label.
    param([Parameter(Mandatory)][string]$Name)
    $f = "label=com.docker.compose.project=$(Get-SiteProject $Name)"
    [pscustomobject]@{
        Containers = @(Invoke-Docker @('ps', '-a', '-q', '--filter', $f) | Where-Object { $_ })
        Volumes    = @(Invoke-Docker @('volume', 'ls', '-q', '--filter', $f) | Where-Object { $_ })
        Networks   = @(Invoke-Docker @('network', 'ls', '-q', '--filter', $f) | Where-Object { $_ })
    }
}

function Remove-SiteDockerObjects {
    param([Parameter(Mandatory)][string]$Name)
    $o = Get-SiteDockerObjects $Name
    if ($o.Containers) { Invoke-Docker (@('rm', '-f', '-v') + $o.Containers) | Out-Null }
    if ($o.Networks) { Invoke-Docker (@('network', 'rm') + $o.Networks) | Out-Null }
    if ($o.Volumes) { Invoke-Docker (@('volume', 'rm', '-f') + $o.Volumes) | Out-Null }
}

function Update-TraefikCerts {
    # Traefik's file watcher does not see files written from the Windows host through Docker Desktop's bind mount
    # (verified: new cert ignored until restart), so reload by restarting the shared proxy. Takes about a second.
    Invoke-Docker @('restart', "$((Get-WpdConfig).InfraPrefix)-traefik") | Out-Null
}

function Remove-SiteFiles {
    # Deletes <SitesRoot>/<name> and this site's cert files, nothing else.
    param([Parameter(Mandatory)][string]$Name, [switch]$RequireMarker)
    Assert-SiteName $Name
    $c = Get-WpdConfig
    $root = [IO.Path]::GetFullPath($c.SitesRoot).TrimEnd('\', '/')
    $dir = [IO.Path]::GetFullPath((Join-Path $c.SitesRoot $Name))
    if (-not $dir.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete '$dir': it is not inside the sites root."
    }
    foreach ($f in Get-SiteCertFiles $Name) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path -LiteralPath $dir)) { return }
    if ($RequireMarker -and -not (Test-WpdSiteFolder $dir)) {
        Write-Warning "The folder $dir is not a wpd site (no compose file rendered by wpd), so it was left alone."
        return
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
}

function Test-WpdSiteFolder {
    # A folder is ours only if its compose file carries the header wpd renders into it.
    param([Parameter(Mandatory)][string]$Dir)
    $f = Join-Path $Dir 'docker-compose.yml'
    (Test-Path -LiteralPath $f -PathType Leaf) -and [bool](Select-String -LiteralPath $f -Pattern 'Rendered by wpd' -SimpleMatch -List)
}

function Assert-SiteExists {
    param([Parameter(Mandatory)][string]$Name)
    Assert-SiteName $Name
    $dir = Join-Path (Get-WpdConfig).SitesRoot $Name
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'docker-compose.yml'))) { throw "No site named '$Name' in $((Get-WpdConfig).SitesRoot)." }
}

function New-WpdSite {
    param([Parameter(Mandatory)][string]$Name, [string]$Php = '8.3')
    Assert-SiteName $Name
    if ($Php -notmatch '^\d{1,2}\.\d{1,2}\z') { throw "Invalid PHP version '$Php'. Use a version like 8.3." }
    Assert-DockerRunning
    $c = Get-WpdConfig
    if (-not (Invoke-Docker @('network', 'ls', '--filter', "name=^$($c.Network)$", '--format', '{{.Name}}'))) {
        throw "Shared network '$($c.Network)' not found. Run 'wpd setup' first."
    }
    if (-not (Get-MkcertPath)) { throw "mkcert is not installed. Run 'wpd setup'." }
    if (-not (Test-MkcertTrusted)) { throw "The mkcert local CA is not trusted yet (a certificate made now would not be trusted by your browser). Run 'wpd setup' first." }

    $dir = Join-Path $c.SitesRoot $Name
    $found = @()
    if (Test-Path -LiteralPath $dir) { $found += "folder $dir" }
    $o = Get-SiteDockerObjects $Name
    if ($o.Containers) { $found += 'containers' }
    if ($o.Volumes) { $found += 'volumes' }
    if (Get-SiteCertFiles $Name | Where-Object { Test-Path -LiteralPath $_ }) { $found += 'certificate files' }
    if ($found) { throw "Site '$Name' already exists ($($found -join ', ')). Nothing was changed. Remove it with 'wpd rm $Name' or pick another name." }

    $dbPassword = New-RandomPassword
    $adminPassword = New-RandomPassword
    $url = Get-SiteUrl $Name
    $succeeded = $false; $certWritten = $false
    try {
        Write-Host "Creating $Name ($url, PHP $Php)..."
        New-Item -ItemType Directory $dir -Force -ErrorAction Stop | Out-Null
        foreach ($d in 'themes', 'plugins', 'mu-plugins') { New-Item -ItemType Directory (Join-Path $dir "wp-content/$d") -Force | Out-Null }
        Copy-Item (Get-SiteTemplate 'wpd-mail.php') (Join-Path $dir 'wp-content/mu-plugins/wpd-mail.php')
        Write-SiteFile (Join-Path $dir 'php.ini') (Get-Content (Get-SiteTemplate 'php.ini') -Raw)
        Write-SiteFile (Join-Path $dir '.gitignore') ".wpd-credentials.txt`ndocker-compose.yml`n"
        Write-SiteFile (Join-Path $dir 'docker-compose.yml') (Format-SiteCompose @{
            Name = $Name; Tld = $c.Tld; Php = $Php; DbPassword = $dbPassword
            Network = $c.Network; HttpsPort = $c.HttpsPort; Project = (Get-SiteProject $Name)
        })

        # Per-site certificate (site name and mail host as SANs) in Traefik's watched folders.
        foreach ($sub in 'certs', 'dynamic') { New-Item -ItemType Directory (Join-Path $c.InfraRoot $sub) -Force | Out-Null }
        $cert, $key, $dyn = Get-SiteCertFiles $Name
        $certWritten = $true
        New-MkcertCertificate -Hosts @("$Name.$($c.Tld)", "mail.$Name.$($c.Tld)") -CertFile $cert -KeyFile $key
        Write-SiteFile $dyn "tls:`n  certificates:`n    - certFile: /certs/$Name.pem`n      keyFile: /certs/$Name-key.pem`n"
        try { Update-TraefikCerts } catch { throw "Could not reload Traefik ($($_.Exception.Message)). Run 'wpd setup' and try again." }

        Write-Host 'Pulling images (retries on Docker Hub timeouts)...'
        Invoke-SiteCompose $Name @('--profile', 'tools', 'pull', '--quiet') -Retry | Out-Null
        Invoke-SiteCompose $Name @('up', '-d') | Out-Null

        Write-Host 'Waiting for WordPress files...'
        $ready = $false
        for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
            try { Invoke-SiteCompose $Name @('exec', '-T', 'wordpress', 'test', '-f', 'wp-config.php') | Out-Null; $ready = $true }
            catch { Start-Sleep -Seconds 2 }
        }
        if (-not $ready) { throw 'WordPress did not finish setting up its files within 2 minutes.' }
        # A fresh named volume is root-owned; Apache runs as www-data and must write uploads.
        Invoke-SiteCompose $Name @('exec', '-T', '-u', 'root', 'wordpress', 'chown', 'www-data:www-data', '/var/www/html/wp-content/uploads') | Out-Null

        Write-Host 'Installing WordPress...'
        # The admin password travels as an environment variable (docker copies it from this process's environment),
        # so it never appears in docker.exe's argument list.
        $env:WPD_ADMIN_PW = $adminPassword
        try {
            Invoke-SiteCompose $Name @('--profile', 'tools', 'run', '--rm', '-T', '-e', 'WPD_ADMIN_PW', 'wpcli', 'sh', '-c',
                'wp core install --url="$1" --title="$2" --admin_user=admin --admin_password="$WPD_ADMIN_PW" --admin_email="$3" --skip-email',
                'sh', $url, $Name, "admin@$Name.$($c.Tld)") | Out-Null
        } finally { Remove-Item Env:WPD_ADMIN_PW -ErrorAction SilentlyContinue }
        try { Invoke-SiteWpCli $Name @('rewrite', 'structure', '/%postname%/', '--hard') | Out-Null }
        catch { Write-Warning "Pretty permalinks were not enabled: $($_.Exception.Message)" }

        Write-SiteFile (Join-Path $dir '.wpd-credentials.txt') (@(
            "Site: $url", "Mail: $(Get-SiteUrl $Name 'mail.')", "Admin URL: $url/wp-admin/",
            'Admin user: admin', "Admin password: $adminPassword",
            'DB name: wordpress', 'DB user: wp', "DB password: $dbPassword") -join "`n")
        $succeeded = $true
    } catch {
        # Never let a password reach an error message.
        $msg = $_.Exception.Message
        foreach ($pw in $dbPassword, $adminPassword) { $msg = $msg.Replace($pw, '***') }
        if ($msg -ne $_.Exception.Message) { throw $msg }
        throw
    } finally {
        # finally (not catch) so Ctrl+C is cleaned up too. Everything here was created by this call:
        # the pre-check above guarantees no folder, containers, volumes or certs existed before.
        if (-not $succeeded) {
            Write-Warning "Creating '$Name' did not finish; removing what was created."
            try { Remove-SiteDockerObjects $Name } catch { Write-Warning "Docker cleanup incomplete: $($_.Exception.Message)" }
            try { Remove-SiteFiles $Name } catch { Write-Warning "File cleanup incomplete: $($_.Exception.Message)" }
            if ($certWritten) { try { Update-TraefikCerts } catch { Write-Warning "Could not reload Traefik: $($_.Exception.Message)" } }
        }
    }
    [pscustomobject]@{ Name = $Name; Url = $url; Path = $dir; AdminUser = 'admin'; AdminPassword = $adminPassword }
}

function Get-WpdSites {
    $c = Get-WpdConfig
    if (-not (Test-Path -LiteralPath $c.SitesRoot)) { return @() }
    Assert-DockerRunning
    $running = @(Invoke-Docker @('ps', '--filter', 'label=com.docker.compose.service=wordpress', '--format', '{{.Label "com.docker.compose.project"}}'))
    @(Get-ChildItem -LiteralPath $c.SitesRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'docker-compose.yml') } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Url = (Get-SiteUrl $_.Name); Running = ($running -contains (Get-SiteProject $_.Name)) }
    })
}

function Start-WpdSite {
    param([Parameter(Mandatory)][string]$Name)
    Assert-SiteExists $Name
    Assert-DockerRunning
    Invoke-SiteCompose $Name @('up', '-d') | Out-Null
    Write-Host "Started $Name at $(Get-SiteUrl $Name)"
}

function Stop-WpdSite {
    param([Parameter(Mandatory)][string]$Name)
    Assert-SiteExists $Name
    Assert-DockerRunning
    Invoke-SiteCompose $Name @('stop') | Out-Null
    Write-Host "Stopped $Name (data kept)."
}

function Remove-WpdSite {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force,
        [scriptblock]$Ask = { param($q) Read-Host $q }
    )
    Assert-SiteName $Name
    Assert-DockerRunning
    $c = Get-WpdConfig
    $dir = Join-Path $c.SitesRoot $Name
    $o = Get-SiteDockerObjects $Name
    $certs = @(Get-SiteCertFiles $Name | Where-Object { Test-Path -LiteralPath $_ })
    if (-not (Test-Path -LiteralPath $dir) -and -not $o.Containers -and -not $o.Volumes -and -not $certs) { throw "No site named '$Name'." }
    $folderNote = if (-not (Test-Path -LiteralPath $dir)) { 'there is no site folder' }
        elseif (Test-WpdSiteFolder $dir) { "the folder $dir including your themes, plugins and mu-plugins" }
        else { "Note: the folder $dir is NOT a wpd site, so it will be left alone" }
    if (-not $Force) {
        $q = "This will permanently delete site '$Name': its containers ($($o.Containers.Count)), its Docker volumes (WordPress core, uploads and the database: $($o.Volumes.Count)), its certificate files and $folderNote. This cannot be undone. Type y to delete [y/N]"
        $answer = try { & $Ask $q } catch { '' }
        if ($answer -notmatch '^\s*(y|yes)\s*$') { throw "Cancelled. Nothing was deleted." }
    }
    Remove-SiteDockerObjects $Name
    Remove-SiteFiles $Name -RequireMarker
    if ($certs) { try { Update-TraefikCerts } catch { Write-Warning "Could not reload Traefik: $($_.Exception.Message)" } }
    Write-Host "Removed $Name."
}
