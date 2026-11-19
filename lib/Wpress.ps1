# Clone from an All-in-One WP Migration .wpress file. No plugin and no license; the archive is read directly.
# Layout (docs/spike-notes.md section 4): entries of a 4377-byte header (name 255, size 14, mtime 12, path 4096; ASCII, NUL padded,
# size and mtime decimal) followed by size bytes. End of archive = first byte of name is NUL (or fewer than 4377 bytes left).
# Table prefix: AI1WM dumps use the token SERVMASK_PREFIX_; it is replaced with 'wp_', the prefix wpd sites are created with,
# so the shared importer needs no wp-config change. (The original site's prefix is not preserved.)

$script:WpressHeader = 4377
$script:WpressContentDirs = @('themes', 'plugins', 'mu-plugins', 'uploads')

function Read-WpressBytes {
    param([IO.Stream]$Stream, [byte[]]$Buffer, [int]$Count)
    $got = 0
    while ($got -lt $Count) {
        $n = $Stream.Read($Buffer, $got, $Count - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    $got
}

function Get-WpressField {
    param([byte[]]$Header, [int]$Offset, [int]$Length)
    $end = $Offset
    while ($end -lt $Offset + $Length -and $Header[$end] -ne 0) { $end++ }   # ignore everything after the first NUL
    [Text.Encoding]::UTF8.GetString($Header, $Offset, $end - $Offset)
}

function Get-WpressEntryPath {
    # Relative path (forward slashes) from the entry's path + name; throws for anything that could escape the destination.
    param([string]$Name, [string]$Path)
    $rel = if ($Path -eq '.' -or $Path -eq '') { $Name } else { "$Path/$Name" }
    if ($rel -match '[\\:\x00-\x1f]' -or $rel.StartsWith('/')) { throw "Refusing archive entry with an unsafe path: '$rel'." }
    foreach ($seg in $rel.Split('/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { throw "Refusing archive entry with an unsafe path: '$rel'." }
    }
    $rel
}

function Expand-Wpress {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Destination, [string]$OldUrl)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "File not found: $File" }
    New-Item -ItemType Directory $Destination -Force | Out-Null
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $dbPath = Join-Path $Destination 'database.sql'
    $fs = [IO.File]::Open($File, 'Open', 'Read', 'Read')
    $header = [byte[]]::new($script:WpressHeader)
    $buf = [byte[]]::new(1MB)
    $count = 0; $haveDb = $false; $pkgText = $null
    try {
        [int64]$len = $fs.Length
        while ($true) {
            if ($len - $fs.Position -lt $script:WpressHeader) { break }
            if ((Read-WpressBytes $fs $header $script:WpressHeader) -lt $script:WpressHeader) { break }
            if ($header[0] -eq 0) { break }
            $name = Get-WpressField $header 0 255
            $sizeText = Get-WpressField $header 255 14
            [int64]$size = 0
            if (-not [int64]::TryParse($sizeText, [ref]$size) -or $size -lt 0) { throw "Corrupt .wpress: bad size field for an entry at offset $($fs.Position - $script:WpressHeader)." }
            $path = Get-WpressField $header 281 4096
            $rel = Get-WpressEntryPath $name $path
            if ($size -gt $len - $fs.Position) { throw "The .wpress file is truncated: entry data is shorter than its header says." }

            $target = $null; $toMemory = $false
            if ($rel -eq 'database.sql') { $target = $dbPath; $haveDb = $true }
            elseif ($rel -eq 'package.json') { $toMemory = $true }
            else {
                $r2 = if ($rel.StartsWith('wp-content/')) { $rel.Substring(11) } else { $rel }
                if ($r2.Contains('/') -and $script:WpressContentDirs -contains $r2.Split('/')[0]) {
                    $full = [IO.Path]::GetFullPath((Join-Path $Destination $r2))
                    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing archive entry outside the destination: '$rel'." }
                    $target = $full; $count++
                }
            }
            if ($toMemory) {
                if ($size -gt 4MB) { throw 'package.json in the archive is unexpectedly large.' }
                $pb = [byte[]]::new([int]$size)
                [void](Read-WpressBytes $fs $pb ([int]$size))
                $pkgText = [Text.Encoding]::UTF8.GetString($pb)
            }
            elseif ($target) {
                New-Item -ItemType Directory (Split-Path -Parent $target) -Force | Out-Null
                $out = [IO.File]::Create($target)
                try {
                    [int64]$left = $size
                    while ($left -gt 0) {
                        $want = [int][Math]::Min([int64]$buf.Length, $left)
                        $n = $fs.Read($buf, 0, $want)
                        if ($n -le 0) { throw 'The .wpress file is truncated: unexpected end of data.' }
                        $out.Write($buf, 0, $n); $left -= $n
                    }
                } finally { $out.Dispose() }
            }
            else { [void]$fs.Seek($size, [IO.SeekOrigin]::Current) }
        }
    } finally { $fs.Dispose() }
    if (-not $haveDb) { throw 'The .wpress file has no database.sql entry (truncated or not an All-in-One WP Migration backup).' }

    $url = $OldUrl
    if (-not $url -and $pkgText) {
        try { $pk = $pkgText | ConvertFrom-Json; $url = @($pk.SiteURL, $pk.HomeURL) | Where-Object { $_ -match '^https?://\S+$' } | Select-Object -First 1 } catch { }
    }
    if (-not $url) {
        $rd = [IO.File]::OpenText($dbPath)
        try {
            while ($null -ne ($line = $rd.ReadLine())) {
                if ($line.Contains("'siteurl'") -and $line -match "'siteurl','(https?://[^']+)'") { $url = $Matches[1]; break }
            }
        } finally { $rd.Dispose() }
        if ($url) { Write-Warning 'package.json has no site URL; using the siteurl row of the database.' }
    }
    if (-not $url) { throw 'Could not determine the original site URL from the archive. Pass it with --old-url https://live.example.com.' }
    [pscustomobject]@{ DatabasePath = $dbPath; FileCount = $count; OldUrl = $url.TrimEnd('/') }
}

function Convert-SqlPrefixToken {
    # Streams In to Out replacing SERVMASK_PREFIX_ with Prefix. The last token-length-1 characters of each chunk are held
    # back and prepended to the next one, so a token never straddles a chunk boundary unreplaced.
    param([Parameter(Mandatory)][string]$InFile, [Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][string]$Prefix, [int]$ChunkSize = 1MB)
    $token = 'SERVMASK_PREFIX_'; $hold = $token.Length - 1
    $rd = [IO.StreamReader]::new($InFile, [Text.UTF8Encoding]::new($false))
    $wr = [IO.StreamWriter]::new($OutFile, $false, [Text.UTF8Encoding]::new($false))
    try {
        $chars = [char[]]::new($ChunkSize); $carry = ''
        while (($n = $rd.Read($chars, 0, $chars.Length)) -gt 0) {
            $s = ($carry + [string]::new($chars, 0, $n)).Replace($token, $Prefix)
            if ($s.Length -gt $hold) { $wr.Write($s.Substring(0, $s.Length - $hold)); $carry = $s.Substring($s.Length - $hold) } else { $carry = $s }
        }
        $wr.Write($carry.Replace($token, $Prefix))
    } finally { $rd.Dispose(); $wr.Dispose() }
}

function Import-Wpress {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$File,
        [string]$OldUrl,
        [switch]$NoUploads
    )
    Assert-SiteName $Name
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "File not found: $File" }
    $dir = Join-Path (Get-WpdConfig).SitesRoot $Name
    if (Test-Path -LiteralPath $dir) { throw "Site '$Name' already exists (folder $dir). Nothing was changed. Remove it with 'wpd rm $Name' or pick another name." }
    Assert-DockerRunning

    $work = Join-Path ([IO.Path]::GetTempPath()) "wpd-wpress-$([guid]::NewGuid().ToString('N'))"
    $created = $false; $keep = $false
    try {
        Write-Host 'Reading the .wpress archive...'
        $x = Expand-Wpress -File $File -Destination (Join-Path $work 'content') -OldUrl $OldUrl
        Write-Host "Unpacked $($x.FileCount) files."
        $sql = Join-Path $work 'import.sql'
        Convert-SqlPrefixToken $x.DatabasePath $sql 'wp_'
        Remove-Item -LiteralPath $x.DatabasePath -Force

        $site = New-WpdSite $Name
        $created = $true
        Import-SiteContent -Name $Name -ContentDir (Join-Path $work 'content') -SqlFile $sql -OldUrl $x.OldUrl -NoUploads:$NoUploads -AdminPassword $site.AdminPassword
        $keep = $true
        $site
    } catch {
        if ($created -and $_.Exception.Data['WpdImported']) { $keep = $true }
        throw
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        if ($created -and -not $keep) { Remove-FailedImportSite $Name }
    }
}
