function Test-Infra {
    $c = Get-WpdConfig
    $p = $c.InfraPrefix
    $r = [System.Collections.Generic.List[object]]::new()
    $add = { param($n, $ok, $fix) $r.Add([pscustomobject]@{ Name = $n; Ok = [bool]$ok; Fix = if ($ok) { '' } else { $fix } }) }

    $dockerOk = $true
    try { Assert-DockerRunning } catch { $dockerOk = $false }
    & $add 'Docker running' $dockerOk 'Start Docker Desktop and wait until it says it is running.'

    foreach ($port in $c.HttpPort, $c.HttpsPort) {
        $h = Get-PortHolder -Port $port -Protocol tcp
        $ok = (-not $h) -or (Test-OwnHolder $h)
        & $add "Port $port free for Traefik" $ok $(if (-not $ok) { Get-PortFix -Port $port -Holder $h -Role web })
    }
    $h = Get-PortHolder -Port $c.DnsPort -Protocol udp
    $ok = (-not $h) -or (Test-OwnHolder $h)
    & $add "Port $($c.DnsPort) free for DNS" $ok $(if (-not $ok) { Get-PortFix -Port $c.DnsPort -Holder $h -Role dns })

    & $add 'mkcert installed' ([bool](Get-MkcertPath)) "Run 'wpd setup' to install mkcert."
    & $add 'mkcert CA trusted' (Test-MkcertTrusted) "Run 'wpd setup' (it runs mkcert -install)."
    & $add '.test DNS hook registered' (Test-TestDns) "Run 'wpd setup' (one-time admin/sudo prompt to route .test to the local DNS)."

    $running = {
        param($name)
        if (-not $dockerOk) { return $false }
        try { (Invoke-Docker @('inspect', '-f', '{{.State.Running}}', $name)) -contains 'true' } catch { $false }
    }
    $netOk = $dockerOk
    if ($dockerOk) { try { Invoke-Docker @('network', 'inspect', $c.Network) | Out-Null } catch { $netOk = $false } }
    & $add "Network $($c.Network) exists" $netOk "Run 'wpd setup'."
    & $add "Traefik container ($p-traefik) up" (& $running "$p-traefik") "Run 'wpd setup'."
    & $add "DNS container ($p-dns) up" (& $running "$p-dns") "Run 'wpd setup'."
    $r.ToArray()
}

function Invoke-Doctor {
    $results = Test-Infra
    foreach ($x in $results) {
        if ($x.Ok) { Write-Host "[ ok ] $($x.Name)" } else { Write-Host "[FAIL] $($x.Name)`n       Fix: $($x.Fix)" }
    }
    Write-Host "`nTip: Docker Desktop keeps its disk image on C: by default. To move it to another drive: Docker Desktop > Settings > Resources > Advanced > Disk image location."
    $results
}
