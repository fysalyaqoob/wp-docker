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
        return "$Holder is using port $Port. Run 'wpd setup': it will offer to stop $Holder (you confirm), and 'wpd resume' starts it again."
    }
    if ($Role -eq 'dns' -and $Holder -eq 'svchost') {
        return "A Windows service (svchost) is using port $Port, usually Internet Connection Sharing. Disable Internet Connection Sharing (service SharedAccess) or free the port, then re-run 'wpd setup'."
    }
    "'$Holder' is using port $Port and wpd does not recognize it, so it will not stop it. Stop it yourself or free the port, then re-run 'wpd setup'."
}

function Stop-PortConflicts {
    # Asks per recognized server; stops only on an explicit yes. Unrecognized holders are never touched.
    # -Confirm is accepted for the documented contract; asking is always on.
    param(
        [switch]$Confirm,
        [scriptblock]$Ask = { param($q) Read-Host $q },
        [scriptblock]$StopRunner = { param($cmd) Invoke-ServerCommand $cmd }
    )
    $c = Get-WpdConfig
    $seen = @{}
    $stopped = @()
    foreach ($port in $c.HttpPort, $c.HttpsPort) {
        $holder = Get-PortHolder -Port $port -Protocol tcp
        if (-not $holder -or (Test-OwnHolder $holder) -or $seen[$holder]) { continue }
        $seen[$holder] = $true
        $plan = Get-ServerStopPlan -Holder $holder
        if (-not $plan) { Write-Warning (Get-PortFix -Port $port -Holder $holder -Role web); continue }
        $answer = & $Ask "Port $port is held by '$holder' ($($plan.Name)). Stop it so Traefik can use it? 'wpd resume' restarts it. [y/N]"
        if ($answer -notmatch '^\s*(y|yes)\s*$') { Write-Host "Leaving $holder running."; continue }
        & $StopRunner $plan.Stop
        Write-Host "Stopped $($plan.Name)."
        $stopped += [pscustomobject]@{ Name = $plan.Name; Kind = $plan.Kind; Stop = $plan.Stop; Start = $plan.Start }
    }
    if ($stopped) {
        $file = Get-StoppedFile
        $all = @()
        if (Test-Path $file) { $all += @(Get-Content $file -Raw | ConvertFrom-Json) }
        New-Item -ItemType Directory (Split-Path $file) -Force | Out-Null
        ConvertTo-Json -InputObject @($all + $stopped) | Set-Content $file
    }
}

function Resume-PortConflicts {
    param([scriptblock]$StartRunner = { param($cmd) Invoke-ServerCommand $cmd })
    $file = Get-StoppedFile
    if (-not (Test-Path $file)) { Write-Host 'Nothing to resume: wpd has not stopped any server.'; return }
    $failed = @()
    foreach ($s in @(Get-Content $file -Raw | ConvertFrom-Json)) {
        try { & $StartRunner $s.Start; Write-Host "Restarted $($s.Name)." }
        catch { Write-Warning "Could not restart $($s.Name): $($_.Exception.Message). Start it manually."; $failed += $s }
    }
    if ($failed) { ConvertTo-Json -InputObject @($failed) | Set-Content $file } else { Remove-Item $file }
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

    $env:WPD_INFRA_PREFIX = $c.InfraPrefix; $env:WPD_NETWORK = $c.Network
    $env:WPD_HTTP_PORT = "$($c.HttpPort)"; $env:WPD_HTTPS_PORT = "$($c.HttpsPort)"; $env:WPD_DNS_PORT = "$($c.DnsPort)"
    $env:WPD_INFRA_ROOT = $c.InfraRoot -replace '\\', '/'
    $env:WPD_DOCKER_SOCK = Get-DockerSocketPath
    Invoke-Docker @('compose', '-p', $c.InfraPrefix, '-f', (Join-Path $c.InfraRoot 'docker-compose.yml'), 'up', '-d') | Out-Null

    Register-TestDns
    Write-Host "Infra ready: Traefik on $($c.HttpPort)/$($c.HttpsPort), DNS on $($c.DnsPort), network $($c.Network)."
}
