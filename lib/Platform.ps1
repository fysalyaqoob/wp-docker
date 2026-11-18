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

function Get-DockerSocketPath {
    if ($IsWindows) { '//var/run/docker.sock' } else { '/var/run/docker.sock' }
}

function Get-KnownServers {
    # Recognized local servers that may hold ports 80/443. Process = holder process names.
    if ($IsWindows) {
        @(
            [pscustomobject]@{ Name = 'Apache (Laragon, XAMPP, WAMP)'; Process = @('httpd'); Kind = 'process'; Service = $null }
            [pscustomobject]@{ Name = 'nginx'; Process = @('nginx'); Kind = 'process'; Service = $null }
            [pscustomobject]@{ Name = 'IIS'; Process = @('System', 'w3wp'); Kind = 'service'; Service = 'W3SVC' }
        )
    } else {
        @(
            [pscustomobject]@{ Name = 'Apache'; Process = @('httpd', 'apache2'); Kind = 'service'; Service = 'apachectl' }
            [pscustomobject]@{ Name = 'nginx'; Process = @('nginx'); Kind = 'service'; Service = 'nginx' }
        )
    }
}

function Get-ServerStopPlan {
    # Returns @{Name; Kind; Stop; Start} (PowerShell command strings) or $null if the holder is not recognized.
    param([Parameter(Mandatory)][string]$Holder)
    $s = Get-KnownServers | Where-Object { $_.Process -contains $Holder } | Select-Object -First 1
    if (-not $s) { return $null }
    if ($IsWindows) {
        if ($s.Kind -eq 'service') {
            $svc = Get-Service -Name $s.Service -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne 'Running') { return $null }
            return [pscustomobject]@{ Name = $s.Name; Kind = 'service'
                Stop = "Stop-Service -Name '$($s.Service)' -Force"; Start = "Start-Service -Name '$($s.Service)'" }
        }
        $p = Get-CimInstance Win32_Process -Filter "Name='$Holder.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        $start = if ($p -and $p.ExecutablePath) {
            $procArgs = ($p.CommandLine -replace '^\s*("[^"]*"|\S+)\s*', '') -replace "'", "''"
            $exe = $p.ExecutablePath -replace "'", "''"
            $wd = (Split-Path $p.ExecutablePath) -replace "'", "''"
            if ($procArgs) { "Start-Process -FilePath '$exe' -ArgumentList '$procArgs' -WorkingDirectory '$wd' -WindowStyle Hidden" }
            else { "Start-Process -FilePath '$exe' -WorkingDirectory '$wd' -WindowStyle Hidden" }
        } else { "Write-Warning 'wpd could not record how to restart $Holder. Start it manually.'" }
        return [pscustomobject]@{ Name = $s.Name; Kind = 'process'
            Stop = "Get-Process -Name '$Holder' -ErrorAction SilentlyContinue | Stop-Process -Force"; Start = $start }
    }
    if ($s.Service -eq 'apachectl') {
        return [pscustomobject]@{ Name = $s.Name; Kind = 'service'; Stop = 'sudo apachectl stop'; Start = 'sudo apachectl start' }
    }
    [pscustomobject]@{ Name = $s.Name; Kind = 'service'
        Stop = "brew services stop $($s.Service)"; Start = "brew services start $($s.Service)" }
}

function Get-MkcertPath {
    $c = Get-Command mkcert -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = if ($IsWindows) { @(Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\mkcert.exe') }
             else { @('/opt/homebrew/bin/mkcert', '/usr/local/bin/mkcert') }
    $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Install-Mkcert {
    if ($IsWindows) {
        & winget install --id FiloSottile.mkcert -e --accept-source-agreements --accept-package-agreements
    } else {
        & brew install mkcert
    }
    if (-not (Get-MkcertPath)) { throw 'mkcert install did not produce a usable mkcert. Install it manually and re-run wpd setup.' }
}

function Test-MkcertTrusted {
    $mk = Get-MkcertPath
    if (-not $mk) { return $false }
    $pem = Join-Path ((& $mk -CAROOT) | Select-Object -First 1) 'rootCA.pem'
    if (-not (Test-Path $pem)) { return $false }
    if ($IsWindows) {
        $thumb = ([Security.Cryptography.X509Certificates.X509Certificate2]::new($pem)).Thumbprint
        return [bool](Test-Path "Cert:\CurrentUser\Root\$thumb")
    }
    & security verify-cert -c $pem *> $null
    $LASTEXITCODE -eq 0
}

function Test-TestDns {
    # True when the OS routes *.test to the local DNS container.
    if ($IsWindows) {
        return [bool](Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Namespace -contains '.test' -and $_.NameServers -contains '127.0.0.1' })
    }
    (Test-Path /etc/resolver/test) -and ((Get-Content /etc/resolver/test -Raw) -match 'nameserver\s+127\.0\.0\.1')
}

function Register-TestDns {
    # Idempotent: does nothing when the hook already exists. Otherwise elevates once.
    if (Test-TestDns) { return }
    if ($IsWindows) {
        Write-Host 'Registering the .test DNS rule needs administrator rights once (Windows NRPT rule). A UAC prompt will appear.'
        $cmd = "Add-DnsClientNrptRule -Namespace '.test' -NameServers 127.0.0.1"
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd
    } else {
        Write-Host 'Registering .test DNS needs sudo once (writes /etc/resolver/test).'
        & sudo mkdir -p /etc/resolver
        'nameserver 127.0.0.1' | & sudo tee /etc/resolver/test | Out-Null
    }
    if (-not (Test-TestDns)) { throw 'The .test DNS hook was not created. Re-run wpd setup and approve the elevation prompt.' }
}
