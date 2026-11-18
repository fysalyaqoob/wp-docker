function Get-StoppedFile { Join-Path (Get-WpdHome) 'stopped.json' }

function Test-OwnHolder {
    # Docker Desktop's backend proxies published ports, so it holding a port means our own containers do.
    param([string]$Holder)
    $Holder -match '^(com\.docker|docker|vpnkit|wslrelay|wslhost|limactl)'
}

function Invoke-ServerCommand {
    param([Parameter(Mandatory)][string]$Command)
    & ([scriptblock]::Create($Command))
}

function Get-PortFix {
    # Explains how to resolve a port held by $Holder. $Role is 'web' (80/443) or 'dns' (53).
    param([int]$Port, [string]$Holder, [string]$Role)
    if ($Role -eq 'web' -and (Get-KnownServers | Where-Object { $_.Process -contains $Holder })) {
        if (Get-ServerStopPlan -Holder $Holder -Port $Port) {
            return "$Holder is using port $Port. Run 'wpd setup': it will offer to stop $Holder (you confirm), and 'wpd resume' starts it again."
        }
        return "$Holder is using port $Port, but wpd cannot safely stop and restart it here. Stop $Holder manually, then re-run 'wpd setup'."
    }
    if ($Role -eq 'dns' -and $Holder -eq 'svchost') {
        return "A Windows service (svchost) is using port $Port, usually Internet Connection Sharing. Disable Internet Connection Sharing (service SharedAccess) or free the port, then re-run 'wpd setup'."
    }
    "'$Holder' is using port $Port and wpd does not recognize it, so it will not stop it. Stop it yourself or free the port, then re-run 'wpd setup'."
}

function Read-StoppedRecords {
    $file = Get-StoppedFile
    if (-not (Test-Path $file)) { return @() }
    try {
        $raw = Get-Content $file -Raw
        if (-not $raw -or -not $raw.Trim()) { throw 'file is empty' }
        @($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Cannot read $file ($($_.Exception.Message)). It records servers wpd stopped. Inspect it (restart those servers yourself if needed) or delete it, then try again."
    }
}

function Write-StoppedRecords {
    param([object[]]$Records)
    $file = Get-StoppedFile
    if (-not $Records) { if (Test-Path $file) { Remove-Item $file -ErrorAction Stop }; return }
    New-Item -ItemType Directory (Split-Path $file) -Force -ErrorAction Stop | Out-Null
    ConvertTo-Json -InputObject @($Records) | Set-Content $file -ErrorAction Stop
}

function Stop-PortConflicts {
    # Asks per recognized server; stops only on an explicit yes. Unrecognized holders are never touched.
    # The restart record is persisted BEFORE each stop, so a stopped server is never unrecorded.
    # -Confirm is accepted for the documented contract; asking is always on.
    param(
        [switch]$Confirm,
        [scriptblock]$Ask = { param($q) Read-Host $q },
        [scriptblock]$StopRunner = { param($cmd) Invoke-ServerCommand $cmd }
    )
    $c = Get-WpdConfig
    $seen = @{}
    [void](Read-StoppedRecords)   # fail early on a corrupt state file, before any stop
    foreach ($port in $c.HttpPort, $c.HttpsPort) {
        $holder = Get-PortHolder -Port $port -Protocol tcp
        if (-not $holder -or (Test-OwnHolder $holder) -or $seen[$holder]) { continue }
        $seen[$holder] = $true
        $plan = Get-ServerStopPlan -Holder $holder -Port $port
        if (-not $plan) { Write-Warning (Get-PortFix -Port $port -Holder $holder -Role web); continue }
        $answer = & $Ask "Port $port is held by '$holder' ($($plan.Name)). Stop it so Traefik can use it? 'wpd resume' restarts it. [y/N]"
        if ($answer -notmatch '^\s*(y|yes)\s*$') { Write-Host "Leaving $holder running."; continue }
        $before = @(Read-StoppedRecords)
        $entry = [pscustomobject]@{ Name = $plan.Name; Kind = $plan.Kind; Stop = $plan.Stop; Start = $plan.Start }
        try { Write-StoppedRecords ($before + $entry) }
        catch { throw "Cannot write $(Get-StoppedFile), so $holder was NOT stopped: $($_.Exception.Message)" }
        try { & $StopRunner $plan.Stop }
        catch {
            try { Write-StoppedRecords $before } catch { }
            throw "Could not stop $($plan.Name): $($_.Exception.Message)"
        }
        Write-Host "Stopped $($plan.Name)."
    }
}

function Resume-PortConflicts {
    param([scriptblock]$StartRunner = { param($cmd) Invoke-ServerCommand $cmd })
    $records = @(Read-StoppedRecords)
    if (-not (Test-Path (Get-StoppedFile))) { Write-Host 'Nothing to resume: wpd has not stopped any server.'; return }
    $failed = @()
    foreach ($s in $records) {
        if (-not $s.Start -or -not "$($s.Start)".Trim()) {
            Write-Warning "No restart command was recorded for $($s.Name). Start it manually."; $failed += $s; continue
        }
        try { & $StartRunner $s.Start; Write-Host "Restarted $($s.Name)." }
        catch { Write-Warning "Could not restart $($s.Name): $($_.Exception.Message). Start it manually."; $failed += $s }
    }
    Write-StoppedRecords $failed
}

function Wait-PortsFree {
    # After Stop-PortConflicts: wait briefly for 80/443 to free, then throw the fix text for whatever still holds them.
    param([int]$TimeoutSeconds = 5)
    $c = Get-WpdConfig
    for ($i = 0; $i -le $TimeoutSeconds * 2; $i++) {
        $busy = @()
        foreach ($port in $c.HttpPort, $c.HttpsPort) {
            $h = Get-PortHolder -Port $port -Protocol tcp
            if ($h -and -not (Test-OwnHolder $h)) { $busy += [pscustomobject]@{ Port = $port; Holder = $h } }
        }
        if (-not $busy) { return }
        if ($i -lt $TimeoutSeconds * 2) { Start-Sleep -Milliseconds 500 }
    }
    throw (($busy | ForEach-Object { Get-PortFix -Port $_.Port -Holder $_.Holder -Role web }) -join "`n")
}

function Invoke-DockerRetry {
    # Docker Hub pulls time out occasionally (see spike notes).
    param([string[]]$DockerArgs, [int]$Tries = 3)
    for ($i = 1; ; $i++) {
        try { return Invoke-Docker $DockerArgs } catch { if ($i -ge $Tries) { throw }; Start-Sleep -Seconds (2 * $i) }
    }
}

function Confirm-SitesRoot {
    # Ask once where sites live and save it; skipped when env or config.json already decides it.
    $file = Join-Path (Get-WpdHome) 'config.json'
    $saved = if (Test-Path $file) { (Get-Content $file -Raw | ConvertFrom-Json).SitesRoot }
    if (-not $env:WPD_SITES_ROOT -and -not $saved) {
        $def = Get-DefaultSitesRoot
        $a = Read-Host "Where should site folders live? [$def]"
        $root = if ($a) { $a } else { $def }
        New-Item -ItemType Directory (Split-Path $file) -Force | Out-Null
        @{ SitesRoot = $root } | ConvertTo-Json | Set-Content $file
    }
    New-Item -ItemType Directory (Get-WpdConfig).SitesRoot -Force | Out-Null
}

function Initialize-Infra {
    Assert-DockerRunning
    Confirm-SitesRoot
    $c = Get-WpdConfig
    Stop-PortConflicts
    Wait-PortsFree
    $dnsHolder = Get-PortHolder -Port $c.DnsPort -Protocol udp
    if ($dnsHolder -and -not (Test-OwnHolder $dnsHolder)) { throw (Get-PortFix -Port $c.DnsPort -Holder $dnsHolder -Role dns) }

    $mk = Get-MkcertPath
    if (-not $mk) { Write-Host 'Installing mkcert...'; Install-Mkcert; $mk = Get-MkcertPath }
    if (-not (Test-MkcertTrusted)) { Write-Host 'Trusting the mkcert local CA...'; & $mk -install }

    if (-not (Invoke-Docker @('network', 'ls', '--filter', "name=^$($c.Network)$", '--format', '{{.Name}}'))) { Invoke-Docker @('network', 'create', $c.Network) | Out-Null }

    foreach ($sub in 'dynamic', 'certs') { New-Item -ItemType Directory (Join-Path $c.InfraRoot $sub) -Force | Out-Null }
    Copy-Item (Join-Path $PSScriptRoot '../templates/infra/*') $c.InfraRoot -Force

    Write-Host 'Pulling images (retries on Docker Hub timeouts)...'
    Invoke-DockerRetry @('pull', 'alpine:3.20') | Out-Null
    Invoke-DockerRetry @('pull', 'traefik:v3.6') | Out-Null
    Invoke-Docker @('build', '-q', '-t', "$($c.InfraPrefix)-dns:local", '-f', (Join-Path $c.InfraRoot 'Dockerfile.dns'), $c.InfraRoot) | Out-Null

    $names = 'WPD_INFRA_PREFIX', 'WPD_NETWORK', 'WPD_HTTP_PORT', 'WPD_HTTPS_PORT', 'WPD_DNS_PORT', 'WPD_INFRA_ROOT', 'WPD_DOCKER_SOCK'
    $old = @{}; foreach ($n in $names) { $old[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:WPD_INFRA_PREFIX = $c.InfraPrefix; $env:WPD_NETWORK = $c.Network
        $env:WPD_HTTP_PORT = "$($c.HttpPort)"; $env:WPD_HTTPS_PORT = "$($c.HttpsPort)"; $env:WPD_DNS_PORT = "$($c.DnsPort)"
        $env:WPD_INFRA_ROOT = $c.InfraRoot -replace '\\', '/'
        $env:WPD_DOCKER_SOCK = Get-DockerSocketPath
        Invoke-Docker @('compose', '-p', $c.InfraPrefix, '-f', (Join-Path $c.InfraRoot 'docker-compose.yml'), 'up', '-d') | Out-Null
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $old[$n]) }
    }

    Register-TestDns
    Write-Host "Infra ready: Traefik on $($c.HttpPort)/$($c.HttpsPort), DNS on $($c.DnsPort), network $($c.Network)."
}
