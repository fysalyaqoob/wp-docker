# The only OS-specific file. Branch on $IsWindows/$IsMacOS here and nowhere else.

function Get-DefaultSitesRoot {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Sites'
}

function Get-PortHolder {
    # Returns the owning process name, or $null when the port is free.
    param(
        [Parameter(Mandatory)][int]$Port,
        [ValidateSet('tcp', 'udp')][string]$Protocol = 'tcp'
    )
    if ($IsWindows) {
        $procId = if ($Protocol -eq 'tcp') {
            (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
        } else {
            (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
        }
        if (-not $procId) { return $null }
        return (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
    }
    $spec = if ($Protocol -eq 'tcp') { @("-iTCP:$Port", '-sTCP:LISTEN') } else { @("-iUDP:$Port") }
    $line = (& lsof -nP -F c @spec 2>$null) | Where-Object { $_ -like 'c*' } | Select-Object -First 1
    if ($line) { $line.Substring(1) } else { $null }
}
