# wpd

Create new WordPress sites, or clone live ones, into Docker and serve them at `https://<name>.test` with trusted HTTPS. A small PowerShell 7 CLI for Windows 11 and macOS.

## Status (read this first)

- Windows 11: verified end to end.
- macOS: written to spec but UNTESTED. Expect rough edges; reports welcome.
- `clone --ssh`: verified by mocks and by a real-Docker importer test, but NOT against a real server.
- `clone --wpress`: verified against a real backup file.

## Prerequisites

- Docker Desktop (running).
- PowerShell 7.3 or newer (`pwsh`). Not Windows PowerShell 5.1.
- mkcert (`winget install FiloSottile.mkcert` on Windows, `brew install mkcert` on macOS). `wpd setup` installs it if missing.
- git.

## Install

```
git clone <this repo> wpd
cd wpd
pwsh ./wpd.ps1 setup
```

Optional: make `wpd` shorter to type. PowerShell profile: `function wpd { pwsh /path/to/wpd/wpd.ps1 @args }`, or put the repo folder on your PATH and add a small `wpd` wrapper script.

## One-time `wpd setup`

It asks before stopping any local web server or disabling anything. It installs mkcert (via winget or brew) without a separate prompt, and adds the `.test` DNS hook (admin or sudo once). What it does:

- Asks where site folders live (sites root) and saves it.
- Installs mkcert if needed and trusts its local CA (`mkcert -install`) so browsers accept `https://*.test`.
- Registers a `.test` DNS hook so `anything.test` resolves to your machine:
  - Windows: an NRPT rule (one admin prompt, once).
  - macOS: `/etc/resolver/test` (sudo, once).
- Starts two shared containers: Traefik (HTTPS routing on 80/443) and dnsmasq (answers `.test`).
- Offers (default no) to install the Claude skill to `~/.claude/skills/wpd/SKILL.md`.

### Port 80/443 conflicts

If another web server holds 80/443, `setup` and `doctor` name it. For a recognized local server (Laragon, XAMPP, MAMP, IIS, nginx, Apache) `setup` offers to stop it, only after an explicit yes. Nothing is stopped otherwise. `wpd resume` restarts what `setup` stopped. Unrecognized holders are reported with the process name and left alone.

## Commands

| Command | What it does | Example |
|--|--|--|
| `wpd setup` | One-time machine setup (above) | `wpd setup` |
| `wpd doctor` | Checks everything, prints a fix for each failure | `wpd doctor` |
| `wpd resume` | Restart a local server that setup stopped | `wpd resume` |
| `wpd new <name> [--php 8.3]` | New site at `https://<name>.test`, prints admin login once | `wpd new acme` |
| `wpd clone <name> --ssh <user@host\|alias> --path <dir> [--no-uploads]` | Clone a live site over SSH (needs key or agent login and WP-CLI on the server) | `wpd clone acme --ssh deploy@live.example.com --path /var/www/html` |
| `wpd clone <name> --wpress <file> [--old-url <url>] [--no-uploads]` | Clone from an All-in-One WP Migration backup, no plugin or license needed | `wpd clone acme --wpress ~/backups/acme.wpress --old-url https://live.example.com` |
| `wpd up <name>` / `wpd down <name>` | Start or stop a site, data kept | `wpd down acme` |
| `wpd list` | Sites and whether they run | `wpd list` |
| `wpd rm <name> [--force]` | Delete containers, volumes, certs and folder; asks first unless `--force` | `wpd rm acme` |
| `wpd help` | Usage | |

## Where sites live

Sites root, first match wins: env `WPD_SITES_ROOT`, then `SitesRoot` in `~/.wpd/config.json`, then the default `~/Sites`. `setup` asks once and writes the config file. Each site is a folder `<sites root>/<name>`.

## Layout (hybrid) and why

WordPress core, uploads and the database live in Docker volumes. Only `wp-content/themes`, `plugins` and `mu-plugins` are on disk (bind-mounted) so you can edit them in your editor. Reason: measured on Windows, a full bind mount from a Windows drive was about 15x to 40x slower than a Docker volume (front page about 2 to 4 s versus about 0.07 s). See `docs/spike-notes.md`.

Tip (optional): Docker Desktop keeps its disk image on C: by default. To move it: Docker Desktop > Settings > Resources > Advanced > Disk image location.

## Clone safety defaults

After a clone, the site is made safe to poke at:

- Outgoing mail goes to Mailpit (a local inbox container), not real recipients.
- WP-Cron is off.
- Known risky plugins (mail, payment, marketing automation) are deactivated, never deleted.
- Search engines discouraged.
- Live URLs are replaced everywhere, including inside serialized data. A final check scans the database for the live host. A warning means a leftover that is probably harmless (typically email addresses on the live domain). A failure means live URLs remain; the message says how to fix them with `wp search-replace`.

## Troubleshooting

Run `wpd doctor`. Each failing line has a `Fix:`:

- "Docker running": start Docker Desktop and wait until it says running.
- "Port 80/443 free for Traefik" / "Port N free for DNS": another program holds the port; the message names it. Re-run `wpd setup` to be offered a stop, or stop it yourself.
- "mkcert installed" / "mkcert CA trusted" / ".test DNS hook registered": run `wpd setup`.
- "Network", "Traefik container", "DNS container": run `wpd setup`.

## Known limits

- Live URL replacement is a plain substring match on the host: replacing `https://live.com` also rewrites inside `https://live.com.au`.
- Double-escaped URLs and unusual encodings are not rewritten; the final live-host check catches them as a failure.
- Creating or removing a site restarts the shared Traefik container (about 1 s blip for other running sites), because Traefik does not see cert files written from the host through Docker Desktop mounts.
- WP-Cron is off, so scheduled posts do not publish by themselves.
- The live-host check scans all tables and can take a while on a large database.

## Contributing and tests

Unit tests (fast, everything mocked):

```
pwsh -NoProfile -Command "Invoke-Pester ./tests -ExcludeTag Integration -Output Normal"
```

Integration tests use real Docker, alternate ports and a throwaway prefix, temp home and temp sites root, and clean up after themselves. They are opt-in and take minutes:

```
$env:WPD_INTEGRATION = 1
pwsh -NoProfile -Command "Invoke-Pester ./tests -Tag Integration -Output Normal"
```

They use `WPD_HTTP_PORT=8080`, `WPD_HTTPS_PORT=8443`, `WPD_DNS_PORT=5354`, `WPD_INFRA_PREFIX=wpdtest` so they do not touch a real install. The `.wpress` integration test also needs `WPD_WPRESS_DIR` pointing at a folder with a real `.wpress` file (otherwise it is skipped). `tests/E2E.Tests.ps1` is the end-to-end smoke test.

## License

MIT, see `LICENSE`.

Note: mail is routed to Mailpit by an mu-plugin hook that runs last. API-based mailers (Brevo, Mailgun API, SES API and similar) bypass it and are covered only by the deactivate list after a clone. WP-Cron is off, so scheduled jobs and scheduled posts do not fire.
