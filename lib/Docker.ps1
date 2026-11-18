function Invoke-Docker {
    param([string[]]$Args)
    $out = & docker @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $($Args -join ' ') failed: $($out -join "`n")" }
    [string[]]@($out)
}

function Assert-DockerRunning {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker is not running. Start Docker Desktop and try again.' }
}
