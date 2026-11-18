function Get-WpdHome {
    if ($env:WPD_HOME) { return $env:WPD_HOME }
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.wpd'
}

function Get-WpdConfig {
    # SitesRoot precedence: env WPD_SITES_ROOT, ~/.wpd/config.json, default.
    $wpdHome = Get-WpdHome
    $root = $env:WPD_SITES_ROOT
    if (-not $root) {
        $file = Join-Path $wpdHome 'config.json'
        if (Test-Path $file) { $root = (Get-Content $file -Raw | ConvertFrom-Json).SitesRoot }
    }
    if (-not $root) { $root = Get-DefaultSitesRoot }
    @{
        SitesRoot = $root
        Tld       = 'test'
        Network   = 'wpd-net'
        InfraRoot = Join-Path $wpdHome 'infra'
    }
}

function Assert-SiteName {
    param([string]$Name)
    if ($Name -cnotmatch '^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$') {
        throw "Invalid site name '$Name'. Use 1-42 lowercase letters, digits or hyphens, starting and ending with a letter or digit (no spaces, dots, uppercase or path characters)."
    }
}
