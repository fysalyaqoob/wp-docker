function Invoke-Docker {
    param([string[]]$DockerArgs)
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & docker @DockerArgs 2>$errFile
        $code = $LASTEXITCODE
        $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
        $detail = (@($err) + @($out) | Where-Object { $_ }) -join "`n"
        throw "docker $($DockerArgs -join ' ') failed (exit $code): $detail".Trim()
    }
    # @($null) would be one empty element, which is truthy; return nothing for empty output.
    @($out | Where-Object { $null -ne $_ }) -as [string[]]
}

function Assert-DockerRunning {
    $ok = $false
    try { & docker info *> $null; $ok = ($LASTEXITCODE -eq 0) } catch { $ok = $false }
    if (-not $ok) { throw 'Docker is not running (or not installed). Start Docker Desktop and try again.' }
}
