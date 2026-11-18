# WP Docker Tool (`wpd`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A shareable PowerShell CLI plus Claude skill that creates new WordPress sites or clones live ones into Docker, served at `https://<name>.test`.

**Architecture:** One shared Traefik proxy + dnsmasq DNS container on network `wpd-net`; per-site Compose stack (WordPress, MariaDB, WP-CLI, Mailpit). `wpd.ps1` dispatches to small modules in `lib/`. Compose files are rendered from templates in `templates/`.

**Tech Stack:** Windows PowerShell 5.1, Docker Desktop 29.x, Traefik, dnsmasq, mkcert, MariaDB, WP-CLI, Mailpit, Pester 5 for tests.

**Spec:** `docs/superpowers/specs/2026-11-19-wp-docker-tool-design.md`

## Global Constraints

- Windows 11 first; Windows PowerShell 5.1 compatible (no `&&`, `?:`, `??`).
- Default TLD `.test`. Never `.local`.
- Default sites root `D:\Development\Clients`; overridable (env `WPD_SITES_ROOT`, then `~\.wpd\config.json`). Nothing for sites on C:.
- Site files AND database data bind-mounted under `<SitesRoot>\<name>\`.
- Ports 80/443 owned by Traefik; CLI reports the holder generically (no hard-coded Laragon). It may stop a recognized local server (Laragon, XAMPP, WAMP, IIS, nginx, Apache) only after an explicit interactive yes, records it in `~\.wpd\stopped.json`, and `wpd resume` restarts it. Never silent, never default, never for unrecognized processes.
- DNS: dnsmasq answers `*.test` with `127.0.0.1`; Windows NRPT rule for namespace `.test` (one-time admin).
- PHP limits baked in: `upload_max_filesize`/`post_max_size` 2G, `memory_limit` 512M, `max_execution_time` 600.
- Generated WP config: `WP_HOME`/`WP_SITEURL` = local URL, `WP_ENVIRONMENT_TYPE=local`, `WP_DEBUG` on.
- Clone safety: mail forced to Mailpit, `DISABLE_WP_CRON` true, risky plugins deactivated, search engines discouraged, URL search-replace via WP-CLI.
- Never delete site data without explicit confirmation (`rm` prompts; `-Force` skips).
- Repo must be shareable: no machine-specific paths or credentials committed; README, LICENSE (MIT), `.gitignore`.

## Review Focus

- Site name with spaces, uppercase, dots or path characters: rejected with a clear message before anything is created.
- `new`/`clone` with a name that already exists: refuses, touches nothing.
- Docker Desktop not running: every command stops early with "start Docker Desktop".
- Truncated or corrupt `.wpress` (and one over 4 GB): fails with a clear error and leaves no half-made site behind.
- Live URL variants (`http://`, `https://`, `www.`) and serialized data: no live URL remains after clone.

## File Structure

- `wpd.ps1`: entry point, argument parsing, dispatch.
- `lib/Config.ps1`, `lib/Docker.ps1`, `lib/Infra.ps1`, `lib/Site.ps1`, `lib/Safety.ps1`, `lib/CloneSsh.ps1`, `lib/Wpress.ps1`, `lib/Doctor.ps1`: one responsibility each.
- `templates/infra/docker-compose.yml`, `templates/infra/dnsmasq.conf`, `templates/site/docker-compose.yml.tpl`, `templates/site/php.ini`, `templates/risky-plugins.txt`.
- `skill/SKILL.md`; `README.md`; `LICENSE`; `.gitignore`.
- `tests/*.Tests.ps1` (Pester 5; Docker-dependent tests tagged `Integration`).

---

### Task 1: Spike the three risks (throwaway findings)

**Files:** Create `docs/spike-notes.md` (findings only; scratch scripts not kept).

**Interfaces:** Produces: written answers the later tasks rely on.

- [ ] **Step 1:** First try the non-destructive route: bind a test DNS container to `127.0.0.1:53` with ICS and the existing web server untouched, and test Traefik on alternate ports (8080/8443) so nothing needs stopping. Only if port 53 truly cannot bind, ask the owner for an explicit yes before disabling ICS (`Stop-Service SharedAccess; Set-Service SharedAccess -StartupType Disabled`, admin) and before stopping any web server on 80/443. Record exactly what was changed so it can be undone.
- [ ] **Step 2:** Run dnsmasq in Docker publishing `127.0.0.1:53`; add NRPT rule `Add-DnsClientNrptRule -Namespace ".test" -NameServers 127.0.0.1`; verify `Resolve-DnsName anything.test` returns `127.0.0.1`. Record whether it works and the exact steps.
- [ ] **Step 3:** `winget install FiloSottile.mkcert`; `mkcert -install`; `mkcert "*.test"`; serve a test page through Traefik with it; verify `curl https://hello.test` gives 200 without `-k`.
- [ ] **Step 4:** Take one real `.wpress` from the owner's sites; record the archive header layout actually seen (expected: 4377-byte header = name 255, size 14, mtime 12, path 4096, ends with an all-zero block), and how table names appear in `database.sql` (expected prefix token `SERVMASK_PREFIX_`). Record bind-mount page-load time from D: for a stock WordPress.
- [ ] **Step 5:** Commit notes. Expected: all four answers written; any failure is reported to the owner before Task 3.

### Task 2: Skeleton, config, input validation

**Files:** Create `wpd.ps1`, `lib/Config.ps1`, `lib/Docker.ps1`, `tests/Config.Tests.ps1`.

**Interfaces:**
- Produces: `Get-WpdConfig -> hashtable @{SitesRoot; Tld; Network; InfraRoot}`; `Assert-SiteName([string]$Name) -> void` (throws); `Invoke-Docker([string[]]$Args) -> string[]` (throws on non-zero exit); `Assert-DockerRunning() -> void` (throws "start Docker Desktop"); `Get-PortHolder([int]$Port, [ValidateSet('tcp','udp')][string]$Protocol) -> string` (process name or `$null`).

- [ ] **Step 1:** Tests: default `SitesRoot` is `D:\Development\Clients`; env `WPD_SITES_ROOT` overrides it; `Assert-SiteName` accepts `acme`, `acme-2` and throws for `Acme`, `a b`, `a.b`, `..\x`, empty, 42-char name.
- [ ] **Step 2:** Run `Invoke-Pester tests/Config.Tests.ps1`; expect FAIL.
- [ ] **Step 3:** Implement per signatures; name pattern `^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$`. `wpd.ps1` dispatches `setup|doctor|resume|new|clone|up|down|list|rm|help` and prints usage for unknown input.
- [ ] **Step 4:** Run tests; expect PASS. Commit `feat: skeleton, config, name validation`.

### Task 3: `wpd setup` and `wpd doctor`

**Files:** Create `lib/Infra.ps1`, `lib/Doctor.ps1`, `templates/infra/*`, `tests/Infra.Tests.ps1`.

**Interfaces:**
- Consumes: Task 2 `Get-WpdConfig`, `Invoke-Docker`, `Get-PortHolder`.
- Produces: `Stop-PortConflicts([switch]$Confirm) -> void` (asks per recognized server, stops only on yes, writes `~\.wpd\stopped.json` with name, kind (service or process), and restart command); `Resume-PortConflicts() -> void` (restarts what the file lists, reports each, clears the file; no-op with a message if the file is absent); `Initialize-Infra() -> void` (idempotent: network, mkcert wildcard cert, dnsmasq, Traefik, NRPT rule); `Test-Infra() -> [pscustomobject[]]` each `@{Name; Ok; Fix}`, checks: Docker running, ports 80/443 holder, port 53 holder, mkcert installed and CA trusted, NRPT rule present, `wpd-net` exists, Traefik and DNS containers up.

- [ ] **Step 1:** Unit tests: `Stop-PortConflicts` with a mocked holder `httpd` and a "no" answer stops nothing and writes no state; with "yes" it stops it and the state file lists it; `Resume-PortConflicts` restarts exactly what the state file lists and clears it; an unrecognized holder is never stopped. Unit test `Test-Infra` with mocked `Get-PortHolder` returning `httpd`: result contains a failing item whose `Fix` names `httpd` and mentions `wpd setup` offering to stop it. Mock holder `svchost` on 53: `Fix` mentions Internet Connection Sharing. Integration test (tag): after `Initialize-Infra` twice, `Test-Infra` all `Ok`.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement using the exact commands proven in Task 1. NRPT step self-elevates once and says why.
- [ ] **Step 4:** Run unit tests, then integration; expect PASS. Commit `feat: setup and doctor`.

### Task 4: `wpd new` and lifecycle

**Files:** Create `lib/Site.ps1`, `templates/site/*`, `tests/Site.Tests.ps1`.

**Interfaces:**
- Consumes: Tasks 2-3.
- Produces: `New-WpdSite([string]$Name, [string]$Php='8.3') -> [pscustomobject]@{Name; Url; Path; AdminUser; AdminPassword}`; `Get-WpdSites() -> [pscustomobject[]]@{Name; Url; Running}`; `Start-WpdSite([string]$Name)`; `Stop-WpdSite([string]$Name)`; `Remove-WpdSite([string]$Name, [switch]$Force)`; `Format-SiteCompose([hashtable]$Vars) -> string` (renders template; `Vars`: Name, Tld, Php, DbPassword).

- [ ] **Step 1:** Tests: `Format-SiteCompose` output contains Traefik host rule ``Host(`acme.test`)``, bind mounts under the site folder, and the chosen PHP tag; `New-WpdSite` on an existing folder throws and changes nothing; `Remove-WpdSite` without `-Force` and without confirmation leaves the folder intact. Integration: `New-WpdSite smoke` then `Invoke-WebRequest https://smoke.test` returns 200, and the wp-admin login with the returned credentials works.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement. Generate random DB and admin passwords; store them in `<site>\.wpd-credentials.txt` (git-ignored by tool-generated `.gitignore` inside the site folder). Install WordPress with WP-CLI; write the PHP ini and WP constants from Global Constraints.
- [ ] **Step 4:** Run; expect PASS. Commit `feat: new site and lifecycle`.

### Task 5: Clone safety defaults

**Files:** Create `lib/Safety.ps1`, `templates/risky-plugins.txt`, `tests/Safety.Tests.ps1`.

**Interfaces:**
- Produces: `Get-RiskyPlugins([string]$ListPath) -> string[]` (slugs; ignores blank and `#` lines); `Set-CloneSafety([string]$Name, [string]$OldUrl) -> void`: runs `wp search-replace` for `https://`, `http://` and protocol-relative forms of `OldUrl` (and its `www.` variant) with `--all-tables --precise`, sets `DISABLE_WP_CRON`, discourages search engines, deactivates plugins from the list that are installed.

- [ ] **Step 1:** Tests: `Get-RiskyPlugins` skips comments and blanks; seed file contains at least `woocommerce-gateway-stripe`, `wp-mail-smtp`, `mailchimp-for-wp`, `wp-rocket`, `updraftplus`. Integration: after `Set-CloneSafety` on a site with serialized option containing the live URL, `wp option get` shows no live URL and the option is still unserializable.
- [ ] **Step 2:** Run; expect FAIL. **Step 3:** Implement. **Step 4:** Run; expect PASS. Commit `feat: clone safety defaults`.

### Task 6: `wpd clone --ssh`

**Files:** Create `lib/CloneSsh.ps1`, `tests/CloneSsh.Tests.ps1`.

**Interfaces:**
- Consumes: Tasks 4-5.
- Produces: `Import-LiveSite([string]$Name, [string]$Target, [string]$RemotePath, [switch]$NoUploads) -> [pscustomobject]` (same shape as `New-WpdSite`). Uses Windows `ssh`/`scp` and tar over ssh; remote `wp db export` and `wp option get siteurl` give the dump and the old URL.

- [ ] **Step 1:** Tests (mocked ssh): missing remote WP-CLI yields error "WP-CLI not found on the remote" and no site folder is left; `-NoUploads` excludes `wp-content/uploads` from the tar; failure mid-pull removes the partial site folder.
- [ ] **Step 2:** Run; expect FAIL. **Step 3:** Implement; on any failure remove the new folder and containers it created. **Step 4:** Run; expect PASS. Commit `feat: clone over ssh`.

### Task 7: `wpd clone --wpress`

**Files:** Create `lib/Wpress.ps1`, `tests/Wpress.Tests.ps1`.

**Interfaces:**
- Produces: `Expand-Wpress([string]$File, [string]$Destination) -> [pscustomobject]@{DatabasePath; FileCount; OldUrl}` (layout as recorded in Task 1; streams the file, handles sizes over 4 GB; throws on a truncated archive or missing `database.sql`); `Import-Wpress([string]$Name, [string]$File) -> [pscustomobject]` (create blank site, expand, replace `SERVMASK_PREFIX_` with the site's table prefix, import DB, run `Set-CloneSafety`).

- [ ] **Step 1:** Tests build a tiny synthetic archive in the test: expands two files plus `database.sql`; truncated archive throws; archive without `database.sql` throws; failed import leaves no site folder.
- [ ] **Step 2:** Run; expect FAIL. **Step 3:** Implement with a `FileStream` reader; no whole-file reads. **Step 4:** Run; expect PASS. **Step 5:** Run against the real `.wpress` from Task 1; site loads at `https://<name>.test` with content intact. Commit `feat: clone from .wpress`.

### Task 8: Skill, README, share-ready repo

**Files:** Create `skill/SKILL.md`, `README.md`, `LICENSE`, `.gitignore`.

- [ ] **Step 1:** `SKILL.md`: when to use each command, run `wpd doctor` first, never run `rm`/`-Force` without asking the user, never stop Laragon or disable ICS without asking.
- [ ] **Step 2:** `README.md`: what it is, prerequisites (Docker Desktop, winget), one-time `wpd setup`, command table, how to configure sites root, troubleshooting from `doctor` messages. No personal paths or names.
- [ ] **Step 3:** `wpd setup` offers to copy `skill/SKILL.md` to `~\.claude\skills\wpd\SKILL.md`.
- [ ] **Step 4:** Verify no personal or work names, emails, or `C:\Users\...` paths appear in tracked files (`git grep -n -i -E 'C:\\Users|@gmail|@.*\.com'` returns nothing relevant). Commit.

### Task 9: End-to-end smoke test

**Files:** Create `tests/E2E.Tests.ps1` (tag `Integration`).

- [ ] **Step 1:** Test: `setup`, `new e2e`, GET `https://e2e.test` is 200 over trusted HTTPS, `list` shows it running, `rm e2e -Force` removes folder and containers.
- [ ] **Step 2:** Run `Invoke-Pester -Tag Integration`; expect PASS. Commit `test: end-to-end smoke`.
