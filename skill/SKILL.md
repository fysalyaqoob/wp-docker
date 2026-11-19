---
name: wpd
description: Create or clone local WordPress sites in Docker at https://<name>.test with the wpd CLI. Use when the user wants a new local WordPress site, wants to clone a live WordPress site (over SSH or from an All-in-One WP Migration .wpress file) for development or testing, or wants to start, stop, list or remove those local sites.
---

# wpd: local WordPress sites in Docker

`wpd` is a PowerShell 7 CLI (`pwsh ./wpd.ps1 <command>` from the repo, or the `wpd` alias if the user set one up). Sites run at `https://<name>.test` with trusted HTTPS. Works on Windows 11 and macOS (macOS is untested).

## Always start with doctor

Run `wpd doctor` before anything else. It prints `[ ok ]` or `[FAIL]` per check with a `Fix:` line. Relay the fix text to the user as written. Do not improvise other fixes.

## Commands

| Command | Use |
|--|--|
| `wpd new <name> [--php 8.3]` | New site. Prints the admin login once. |
| `wpd clone <name> --ssh <user@host\|alias> --path </remote/wordpress/folder> [--no-uploads]` | Clone a live site over SSH (key or agent login, WP-CLI needed on the server). Not verified against a real server. |
| `wpd clone <name> --wpress <file> [--old-url https://live.example.com] [--no-uploads]` | Clone from a .wpress backup. No plugin or license needed. |
| `wpd up <name>` / `wpd down <name>` | Start or stop a site. Data is kept. |
| `wpd list` | Sites and whether they run. |
| `wpd rm <name>` | Delete a site: containers, volumes, certs and folder. Asks first. |
| `wpd setup`, `wpd resume` | One-time setup; restart a local server that setup stopped. |

## Rules (hard)

- Never run `wpd rm`, and never pass `--force`, without asking the user first and getting a clear yes for that specific site.
- `wpd setup` asks the user interactive questions (stop a local web server on port 80/443, install the skill, sites root). Never answer those for the user. Tell the user to run `wpd setup` themselves and answer. Never stop a local web server (Laragon, XAMPP, MAMP, IIS, nginx, Apache), disable Internet Connection Sharing, or change any system setting without the user's explicit yes in chat.
- Never print credentials beyond what `wpd new` and `wpd clone` print once. Do not cat `.wpd-credentials.txt` or wp-config.
- Never commit or push credentials, `.wpd-credentials.txt`, or site folders to git.
- Do not guess a site name when cloning; ask.

## New site

1. `wpd doctor`, fix anything failing (relay fixes).
2. `wpd new <name>`. Tell the user the URL and admin login it printed. Site folder holds only `wp-content/themes`, `plugins`, `mu-plugins`; core, uploads and database live in Docker volumes.

## Clone

1. `wpd doctor`. Ask for the source: SSH target and remote WordPress path, or a .wpress file (and the live URL if it is not auto-detected).
2. Run the matching `wpd clone`. Large sites take minutes. Use `--no-uploads` for a faster clone when media is not needed.
3. Report the result and any warnings.

## Safety defaults after a clone

- Outgoing mail goes to Mailpit (a local inbox), never to real recipients.
- WP-Cron is off, so scheduled posts do not fire.
- Known risky plugins (mail, payment, marketing automation) are deactivated, never deleted.
- Search engines are discouraged (`blog_public` 0).
- Live URLs are replaced, then a live-URL check scans the database. A warning (for example an email address on the live domain) is informational. A failure (live URL still present in the data, or search-replace failed) means the clone still points at the live site: do not hand it over as safe; show the user the message and the suggested `wp search-replace` command.

## Platform notes

- Windows: `.test` routing uses an NRPT rule (admin prompt once during setup). Use `curl.exe --ssl-no-revoke` for manual HTTPS checks.
- macOS: `/etc/resolver/test` (sudo once during setup). Untested; say so if something fails.
