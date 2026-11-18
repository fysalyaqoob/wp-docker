# wpd spike notes (Task 1)

Date: 2026-11-19. Host: Windows 11 Pro, Docker engine and client 29.8.1 (Docker Desktop exe file version 4.93.0.240920), pwsh 7.7.0. Throwaway findings that later tasks rely on.

## Summary

| Question | Answer |
|--|--|
| Can DNS bind 127.0.0.1:53 with ICS untouched? | Yes. No need to disable SharedAccess. |
| Does NRPT `.test` -> 127.0.0.1 resolve through the system resolver? | Yes (`Resolve-DnsName anything.test` returns 127.0.0.1). |
| Do ports 80/443 need freeing for the spike? | No (Traefik tested on 8080/8443). Laragon httpd holds 80/443 and will need handling in `wpd setup`. |
| mkcert + Traefik HTTPS without `-k`? | Yes, but NOT with a bare `*.test` wildcard (see Risk A) and curl needs `--ssl-no-revoke` (see Risk B). |
| `.wpress` layout | Matches expectation with two corrections (see below). |
| Bind mount from D: | About 15x to 40x slower than a Docker volume. Real problem (see Risk C). |

## 1. Port 53 and ICS

- ICS (`SharedAccess`) is Manual/Running. It did not block `127.0.0.1:53`.
- Working command (Docker publishes to loopback only):
  `docker run -d --name wpd-dns -p 127.0.0.1:53:53/udp -p 127.0.0.1:53:53/tcp alpine:3.20 sh -c "apk add --no-cache dnsmasq >/dev/null && dnsmasq -k --address=/test/127.0.0.1 --no-resolv"`
  Takes about 10 s to be ready (apk install at start). For the real tool, build or pin an image with dnsmasq preinstalled, so startup does not need network.
- Direct query works: `Resolve-DnsName anything.test -Server 127.0.0.1` -> 127.0.0.1.
- Docker Hub pulls timed out once (`auth.docker.io` token timeout); retrying worked. `wpd setup` should retry pulls.

## 2. NRPT

- Added by the owner in their own admin shell (the UAC prompt from `Start-Process -Verb RunAs` was never shown to the agent session, three attempts, nothing executed).
- Rule seen: `Get-DnsClientNrptRule` -> Namespace `{.test}`, NameServers `127.0.0.1`.
- Verified with the system resolver, no `-Server`: `Resolve-DnsName anything.test` -> 127.0.0.1 (with dnsmasq container running; run `ipconfig /flushdns` first).
- Equivalent command: `Add-DnsClientNrptRule -Namespace ".test" -NameServers 127.0.0.1`
- Doctor check idea: `Get-DnsClientNrptRule | ? Namespace -contains '.test'`, then `Resolve-DnsName probe.test`.

## 3. mkcert and Traefik HTTPS

- `winget install FiloSottile.mkcert` -> installed; alias at `%LOCALAPPDATA%\Microsoft\WinGet\Links\mkcert.exe`. A shell opened before the install does not see it on PATH; `wpd setup` must call it by full path or refresh PATH.
- `mkcert -install` added the CA to the CurrentUser Root store (no admin needed; no dialog appeared). It also printed a Java keystore error (`cacerts` access denied); harmless, ignore.
- Traefik: **v3.1 fails against Docker 29** (docker provider error `Error response from daemon: ` with empty body, because Docker 29 rejects the old client API version). **Use `traefik:v3.6` or newer.** v3.6 worked.
- Working Traefik run (alternate ports, cert via file provider):
  Runnable (PowerShell; run in the folder holding test.pem, test-key.pem, dyn.yml; create the network first with `docker network create wpd-net`):
  ```powershell
  $d = (Get-Location).Path
  docker run -d --name wpd-traefik --network wpd-net -p 127.0.0.1:8080:80 -p 127.0.0.1:8443:443 -v "${d}:/certs:ro" -v "${d}\dyn.yml:/etc/traefik/dyn.yml:ro" -v //var/run/docker.sock:/var/run/docker.sock:ro traefik:v3.6 --providers.docker=true --providers.docker.exposedbydefault=false --providers.docker.network=wpd-net --providers.file.filename=/etc/traefik/dyn.yml --entrypoints.web.address=:80 --entrypoints.websecure.address=:443
  ```
  `dyn.yml` in full:
  ```yaml
  tls:
    certificates:
      - certFile: /certs/test.pem
        keyFile: /certs/test-key.pem
  ```
  Cert that worked (multi-SAN, see Risk A): `mkcert -cert-file test.pem -key-file test-key.pem "*.test" hello.test` (the wildcard does not match on Windows; the explicit hello.test is what works).
- Test app: `traefik/whoami` with labels `traefik.enable=true`, ``traefik.http.routers.h.rule=Host(`hello.test`)``, `traefik.http.routers.h.entrypoints=websecure`, `traefik.http.routers.h.tls=true`.
- Result with system DNS (no `--resolve`): `curl.exe --ssl-no-revoke https://hello.test:8443/` -> 200, verify 0. `Invoke-WebRequest https://hello.test:8443/` -> 200.

### Risk A: wildcard `*.test` is rejected by Windows
`mkcert "*.test"` alone gives `SEC_E_WRONG_PRINCIPAL` in curl (Schannel) for `hello.test`: a wildcard directly under a single-label TLD does not match. Traefik did serve the right cert; the client refuses it.
Fix: give each site its own SAN. Regenerate the cert (or one multi-SAN cert) when a site is added: `mkcert -cert-file test.pem -key-file test-key.pem hello.test other.test ...` then reload Traefik (file provider watches the mounted dir; `docker restart` also works). A wildcard under the site name (`*.mysite.test`) is fine (two labels). Task 3 design should be per-site (or `<name>.test` + `*.<name>.test`) certs, not one `*.test`.

### Risk B: curl on Windows fails revocation check
With the right cert, plain `curl.exe https://hello.test:8443/` still fails: `CRYPT_E_NO_REVOCATION_CHECK` (mkcert certs have no CRL/OCSP). Use `--ssl-no-revoke` in any curl-based checks (doctor, smoke tests). Browsers and .NET (`Invoke-WebRequest`) are unaffected.

## 4. `.wpress` layout (one real file, structure only)

Sample: an All-in-One WP Migration backup from a site's `wp-content\ai1wm-backups\` folder in the Laragon www tree, 1477 MB, 18,994 entries. No content recorded or kept.

- Entry = 4377-byte header + `size` bytes of data, repeated. Header: name 255 + size 14 + mtime 12 + path 4096 = 4377. Confirmed (walk by offsets landed exactly on the end block).
- Fields are ASCII, NUL-padded. Size and mtime are decimal strings. Entry 0 was `package.json`, mtime a Unix epoch number. `path` is `.` for root-level files.
- Correction 1: the last 8 bytes of the 4096-byte `path` field were non-zero on entry 0 (an 8-char hex-looking token; meaning unknown, possibly a format version or signature, unconfirmed). Parser must ignore the tail of `path` after the first NUL.
- Correction 2: the terminator block is NOT all zero. It is 4377 bytes at the very end of the file with an empty name (first byte 0) and non-zero content in the size field (a decimal number equal to the total payload length, 1548406660, which equals the block's own offset) and the same kind of 8 non-zero bytes at the end of the path field (meaning unknown, unconfirmed). **Detect end of archive by first byte of name == 0 (or fewer than 4377 bytes left), not by checking for an all-zero block.**
- `database.sql` is a normal entry (here entry #18,993, 40 MB, near the end, after files). Do not assume it is first.
- Table names appear as `SERVMASK_PREFIX_<name>` in CREATE TABLE / INSERT / DROP statements (e.g. `SERVMASK_PREFIX_options`, `SERVMASK_PREFIX_comments`; 7148 occurrences in the first 3 MB). No literal `wp_` in CREATE TABLE. Importer should replace `SERVMASK_PREFIX_` with the target table prefix (also expect it inside option/usermeta values such as `SERVMASK_PREFIX_user_roles`; a plain replace of the token covers it).
- The other .wpress files found (three other .wpress files in the Laragon www tree, and two 2018 files in a personal projects folder) were not opened. The 2018 files may use an older format; unverified.

### Risk C: bind-mount page-load time from D:
Stock `wordpress:php8.2-apache` + `mariadb:10.11`, installed via install.php, `curl` total time per request:

| | Bind mount `D:\...:/var/www/html` | Docker named volume |
|--|--|--|
| front page (6 requests) | 3.98, 2.63, 2.81, 2.39, 1.24, 1.54 s | 0.19, 0.07, 0.07, 0.08, 0.07, 0.06 s |
| wp-login.php (4 requests) | 0.33, 0.34, 0.98, 0.31 s | 0.026, 0.022, 0.035, 0.020 s |

The bind mount from D: is about 15x to 40x slower. Cold first hit about 4 s. Plugins-heavy sites will be worse. Task 3/4 design should keep WordPress core + wp-content in a named volume (or WSL2 filesystem) and, if edits from Windows are required, mount only `wp-content/themes` and `plugins` (or sync), rather than bind-mounting the whole site from D:.

## Tooling notes

- pwsh 7.7.0 at `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`; Pester modules listed: **6.2.0** and the built-in **3.4.0**. The plan says Pester 5. Not tested here. Use `pwsh` (never Windows PowerShell 5.1, where `Invoke-Pester` may resolve to 3.4.0), and `Import-Module Pester -MinimumVersion 5.0`. Pester 6 accepted for v5-style tests is unverified; run Task 2's first test early to confirm.
- In PowerShell `gl` is `Get-Location`, not `ls`.

## System changes made (with undo)

| Change | By | Undo |
|--|--|--|
| NRPT rule `.test` -> 127.0.0.1 | owner, admin shell, manually | admin: `Get-DnsClientNrptRule \| ? Namespace -contains '.test' \| Remove-DnsClientNrptRule -Force` |
| mkcert local CA in CurrentUser Root store, CA files in `%LOCALAPPDATA%\mkcert` | agent (`mkcert -install`) | **Do this first.** `mkcert -uninstall`, then delete `%LOCALAPPDATA%\mkcert` (run before uninstalling mkcert) |
| mkcert installed via winget | agent | `winget uninstall FiloSottile.mkcert` |
| Docker images pulled by this spike (none of these four were present locally beforehand; the owner's own pre-existing images were not touched) | agent | Only the ones this spike pulled: `docker rmi alpine:3.20 traefik:v3.1 traefik:v3.6 traefik/whoami` (skip any you now use yourself) |

Not changed: ICS/SharedAccess (Manual, Running), Laragon httpd on 80/443 (never stopped), system settings.
Test containers, volume (`wpd-spike-vol`), networks and the D:\Development\wpd-spike-tmp folder were removed.

## Verified on Windows only; NOT verified on macOS

Everything above was run on Windows 11 only. Untested on macOS:
- NRPT is Windows-only. macOS needs a resolver file `/etc/resolver/test` pointing at 127.0.0.1 (unverified).
- Binding `127.0.0.1:53` on macOS is untested.
- `mkcert` via `brew` and `mkcert -install` (keychain prompt) are untested.
- Docker socket path: `//var/run/docker.sock` is the Windows form; macOS uses `/var/run/docker.sock`. Untested.
- Bind-mount slowness may differ on macOS; the 15x to 40x figure is Windows (D: drive) only.
- The Schannel wildcard and revocation quirks (Risks A and B) are Windows-specific.
