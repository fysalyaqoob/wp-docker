function Get-WpdHome {
    if ($env:WPD_HOME) { return $env:WPD_HOME }
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.wpd'
}

function Get-PortSetting {
    param([string]$EnvName, [int]$Default)
    $v = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not $v) { return $Default }
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw "$EnvName must be a port number (1-65535), got '$v'." }
    $n
}

function Get-WpdConfig {
    # SitesRoot precedence: env WPD_SITES_ROOT, ~/.wpd/config.json, default.
    $wpdHome = Get-WpdHome
    $root = $env:WPD_SITES_ROOT
    if (-not $root) {
        $file = Join-Path $wpdHome 'config.json'
        if (Test-Path $file) {
            try { $root = (Get-Content $file -Raw | ConvertFrom-Json -ErrorAction Stop).SitesRoot }
            catch { throw "Cannot read $file (invalid JSON). Fix it or delete it and run 'wpd setup' again." }
        }
    }
    if (-not $root) { $root = Get-DefaultSitesRoot }
    $prefix = if ($env:WPD_INFRA_PREFIX) { $env:WPD_INFRA_PREFIX } else { 'wpd' }
    @{
        SitesRoot   = $root
        Tld         = 'test'
        InfraPrefix = $prefix
        Network     = "$prefix-net"
        InfraRoot   = Join-Path $wpdHome 'infra'
        HttpPort    = Get-PortSetting 'WPD_HTTP_PORT' 80
        HttpsPort   = Get-PortSetting 'WPD_HTTPS_PORT' 443
        DnsPort     = Get-PortSetting 'WPD_DNS_PORT' 53
    }
}

function Assert-SiteName {
    param([string]$Name)
    # \z, not $: "$" would accept a trailing newline.
    if ($Name -cnotmatch '^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?\z') {
        throw "Invalid site name '$Name'. Use 1-42 lowercase letters, digits or hyphens, starting and ending with a letter or digit (no spaces, dots, uppercase or path characters)."
    }
    # Windows device names are unusable as folder names there; reject everywhere so a site is portable.
    if ($Name -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])\z') {
        throw "Invalid site name '$Name': it is a reserved Windows device name. Pick another name."
    }
}
