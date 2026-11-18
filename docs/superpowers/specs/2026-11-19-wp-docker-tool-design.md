# WP Docker Tool: Design

Date: 2026-11-19. Status: draft for approval.

## Intent and why

The owner builds and tests WordPress sites for clients (agency work). They want Docker to replace every other local server (currently Laragon, whose Apache holds ports 80/443 on their machine). Two jobs:

1. **New site**: blank WordPress, built locally, deployed to live later.
2. **Clone live site**: pull an existing live site down (files + database) to develop and test safely.

Success: one command per job, sites reachable at `https://<name>.test` with a trusted padlock, no admin prompt when adding a site, and the old local server can be uninstalled.

## Goals

- `wpd new <name>` creates a working WordPress site in under a few minutes.
- `wpd clone <name>` imports a live site by either path the owner uses:
  - SSH + WP-CLI (pull files and DB directly), or
  - All-in-One WP Migration `.wpress` file (the most common case).
- 1-2 sites run at once, each on its own `<name>.test` domain with HTTPS (mkcert).
- Adding a site needs no hosts-file edit and no admin prompt after one-time setup.
- Windows 11 first. Docker Desktop is already installed and running (v29.8.1).
- A thin Claude skill that tells Claude when and how to call the CLI.
- Shareable: README, MIT license, no personal paths or accounts in the repo; sites root configurable. Hosted in a public GitHub repo under the owner's personal account, never the owner's work account. Owner approved the design on 2026-11-19.

## Non-goals

- Deploying to live hosts. Not now.
- Many simultaneous sites, Kubernetes, multi-user setups.
- macOS/Linux support (keep paths portable where free, do not test).
- Replacing the migration plugin's push-back flow.

## Anti-goals (failure even if it "works")

- Needing the owner to edit hosts files or approve admin prompts per site.
- A clone that still points at live URLs (links, assets, emails hitting the real site).
- A clone that can send real emails or run live cron jobs to real customers.
- Behavior that varies run to run.
- Silently deleting a site's database or files.

## Constraints and facts found on this machine

- Laragon Apache (`httpd.exe`) listens on 80 and 443. Laragon must be stopped (or its ports changed) before the proxy can start. The CLI must detect this and say so plainly.
- UDP 53 is held by Internet Connection Sharing (`SharedAccess` service, `svchost`). A local DNS container may not bind it. This is the biggest technical risk (see Risks).
- `mkcert` is not installed. Setup must install it (winget) and its local CA.
- No existing project files in this folder; no git repo.
- `.local` domains clash with mDNS on Windows. Default TLD is `.test`.

## Approaches considered

| | A. Skill only | B. CLI + thin skill | C. Compose template only |
|--|--|--|--|
| Deterministic | no | yes | mostly |
| Works without Claude | no | yes | yes |
| Up-front work | least | most | least |
| Removes per-site setup hassle | partly | yes | no |

**Chosen: B** (owner agreed; the owner said "go with your pick"). Reason: repeatable results matter for client work. Language choice, PowerShell, is the assistant's call because the owner is on Windows and spoke about outcomes, not tools.

## Design

### Shared infrastructure (one set, always on)

- **Traefik** reverse proxy owns ports 80/443, routes by hostname via Docker labels, serves mkcert certificates. Runs on a shared Docker network `wpd-net`.
- **Local DNS container** (dnsmasq) answers `*.test` with `127.0.0.1`.
- **Windows NRPT rule** (`Add-DnsClientNrptRule -Namespace .test`) sends only `.test` lookups to that DNS. One-time, needs admin once.
- **mkcert**: one wildcard cert for `*.test`, installed once; CLI points Traefik at it.
- `wpd setup` does all of this once and is safe to re-run. `wpd doctor` checks every piece and prints what is wrong in plain words.

### Per-site stack (`D:\Development\Clients\<name>\`)

Sites root is `D:\Development\Clients` (owner's decision: nothing for sites on C:). Configurable, but that is the default. Note: Docker Desktop keeps its own image/volume storage on C: by default, so named volumes (e.g. database data) would sit there. Assistant's call: bind-mount the database data folder under the site's D: folder too, so everything per site lives on D:. If bind-mounted MariaDB proves slow or has permission problems on Windows, the builder reports it and the owner decides (alternative: move Docker Desktop's disk image to D: in its settings).

- `wordpress` (Apache or php-fpm image, current PHP version selectable per site), `db` (MariaDB), `wpcli` (run-on-demand).
- Site files bind-mounted to a normal folder so the owner can open them in an editor.
- PHP settings baked in: large `upload_max_filesize`, `post_max_size`, `memory_limit`, `max_execution_time`, so `.wpress` imports of large sites work.
- Traefik labels set the `<name>.test` host rule.
- WordPress config: `WP_HOME`/`WP_SITEURL` set to the `.test` URL, `WP_ENVIRONMENT_TYPE=local`, debug on.

### Commands

- `wpd setup`, `wpd doctor`
- `wpd new <name> [--php 8.3]`: create stack, install WordPress with generated admin credentials, print URL and login.
- `wpd clone <name> --ssh user@host --path /remote/wp` : pull files (rsync/scp) and DB dump, import, search-replace live URL to local URL.
- `wpd clone <name> --wpress <file>`: create a blank site, unpack the `.wpress` file directly (no plugin, no license), restore files and database, fix URLs.
- `wpd up|down|list|rm <name>`; `rm` asks before deleting and says what will be lost.
- Claude skill: a short `SKILL.md` describing when to use each command, the preconditions (`wpd doctor`), and not to run destructive commands without asking.

### Clone safety defaults (anti-goal protection)

After any clone: run search-replace live to local URL (including serialized data via WP-CLI), disable outgoing email (mail-catching container, e.g. Mailpit, reachable at `mail.<name>.test`), discourage search engines, and deactivate known risky plugins if listed in a small config list (e.g. caching, backup, security plugins tied to the live host). This list is configurable.

## Risks and fallbacks (to resolve first in the plan)

1. **Port 53 blocked by ICS.** Owner does not use ICS and approved disabling it. Spike first: try binding the DNS container to `127.0.0.1:53` or an alias loopback address. If that fails, `wpd setup` (or `wpd doctor`) tells the owner to disable the ICS service (`SharedAccess`) and retries. No hosts-file fallback needed unless ICS is disabled and port 53 is still unusable; then stop and ask the owner.
2. **Laragon on 80/443.** CLI refuses to start the proxy while another process holds them and names the process.
3. **`.wpress` import without the Unlimited extension.** Owner has no Unlimited extension license, so the plugin's WP-CLI import and big-file import are unavailable. Decision (assistant's call): `wpd clone --wpress` does not drive the plugin at all. It unpacks the `.wpress` archive itself (a simple sequential file format) into the site folder, restores `database.sql` through WP-CLI/MariaDB, runs the URL search-replace, and applies the clone safety defaults. Spike verifies this on a real `.wpress` from one of the owner's sites. Manual browser import is the documented fallback only.
4. **mkcert CA** on Windows needs a one-time trust prompt.

## Decided by the owner

- Both jobs: new site and clone live site.
- Clone sources: SSH + WP-CLI and All-in-One WP Migration (mostly the latter).
- 1-2 sites at once, each on its own `.test` domain.
- HTTPS via mkcert, local DNS (not hosts-file editing).
- Approach B: CLI with thin skill.
- Sites root `D:\Development\Clients`.
- Does not use Internet Connection Sharing; disabling it is fine.
- Has no All-in-One WP Migration Unlimited extension license.

## Assistant's calls (owner can overrule)

- PowerShell for the CLI.
- Traefik for the proxy, dnsmasq for DNS.
- Default TLD `.test`, not `.local`.
- Mailpit for mail catching, Mailpit enabled by default on clones.
- Debug on and `WP_ENVIRONMENT_TYPE=local` in generated config.

## More assistant's calls (from the builder check; owner can overrule)

- **Laragon:** the CLI only detects and reports what holds 80/443; it never stops Laragon itself. Assumes the owner moves sites over and stops Laragon, no side-by-side running. Clean `https://name.test` stays the goal.
- **File performance:** site files are bind-mounted from D: as decided. NTFS bind mounts are slower under Docker Desktop. The first spike measures a page load and a `.wpress` import. If too slow, the builder reports it and the owner chooses (e.g. keep only `wp-content` themes/plugins on D: and the rest in Docker volumes).
- **SSH clone:** uses Windows OpenSSH (`ssh`, `scp`, tar over ssh); no rsync assumed. Remote WP-CLI is assumed present (owner already uses it); if missing, the CLI says so and stops. Uploads: pulled in full by default, `--no-uploads` skips them. No live-media proxying, because it would reintroduce live URLs.
- **Safety neutralization after clone:** all outgoing mail forced to Mailpit at the container level (not just plugin settings), `DISABLE_WP_CRON` set, payment-gateway and SMTP/email-marketing plugins on a seed deactivate list (WooCommerce gateways such as Stripe/PayPal, WP Mail SMTP, Mailchimp/SendGrid-style plugins, caching and backup plugins), list editable.
- **Skill location:** `SKILL.md` lives in this project folder; `wpd setup` offers to copy it to `~/.claude/skills`.

## Left to the builder

- Exact base images and versions, folder layout of the tool, sites root location, naming of containers/volumes.
- Credentials generation and storage format for new sites.
- Test strategy: a `doctor` check plus one end-to-end smoke test (new site returns HTTP 200 over HTTPS).
