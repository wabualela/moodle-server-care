---
name: hygiene
description: Operational and security hygiene for a production Moodle server, one independent item at a time - failing systemd timers (certbot renewing dead certificates, logrotate duplicate stanzas), the web user's cron mailbox growing by gigabytes, world-readable secrets and logs (.env and cached config, config.php, cron logs, ~/.my.cnf), side apps left in debug mode, accounts stuck in Moodle's new-user password loop, fail2ban dead on Debian 12, MariaDB listening on all addresses, abandoned projects, Docker leftovers, personal-data files, and apps that moved away but left workers, cron lines, vhosts, certificates and deploy keys behind. Use it whenever `systemctl --failed` is not empty, certbot or logrotate fail, /var/mail grows, an audit lists hygiene findings, or the owner asks to clean up the server, remove old projects or data, tighten permissions or check what still runs - even if they never say "hygiene".
---

# Hygiene: small, independent fixes that remove noise and risk

## 1. Read first
Read `../../shared/core-rules.md` before anything else (change protocol §3, secrets §5, deleting §6, placeholders
§12). Then read the server handbook and the tail of the operations log. Load `~/.config/moodle-server-care/server.env`
(written by `skills/start/scripts/detect-env.sh`; run it if missing or older than a day). Every script here sources it
and accepts overrides from the environment (`WEBUSER=apache bash scripts/…`).

Each item below is independent: its own discovery, proposal, procedure, verification and log entry. Never batch two
items into one change; the owner approves items by number.

Module-local placeholders (in addition to core-rules §12): `<APP_DIR>` / `<APP_HOST>` a side app's directory and host
name; `<APP_USER>` / `<APP_GROUP>` the PHP-FPM pool user/group serving it; `<CERT_NAME>` a certbot certificate name;
`<TOPIC>` a short archive name; `<DATE>` = `date +%F`.

## 2. When to use: signs

| Sign | Item | Details |
|---|---|---|
| `systemctl --failed` lists certbot / logrotate / an app worker | H1, H2, H10 | `references/timers-certbot-logrotate.md` |
| Expired certificates in `certbot certificates`, renewal errors twice a day | H1 | same |
| `logrotate.service` failed, "duplicate log entry" | H2 | same |
| `/var/mail/<WEBUSER>` large and growing; local MTA busy with cron mail | H3 | `references/cron-mailbox.md` |
| `.env`, cached config, `config.php`, cron logs, `~/.my.cnf` readable by any account | H4 | `references/secrets-and-log-modes.md` |
| A side app shows stack traces; `APP_DEBUG=true` or `APP_ENV=local` | H5 | `references/laravel-debug.md` |
| Thousands of `user_password_updated` events a day; users who can never log in | H6 | `references/password-loop.md` |
| fail2ban failed since boot: "Have not found any log file for sshd jail" | H7 | `references/fail2ban-journald.md` |
| `ss` shows `*:3306` although `bind-address = 127.0.0.1` | H8 | `references/db-localhost.md` |
| Old Moodle copies, demo sites, Docker images with no containers, CSV/SQL dumps | H9 | `references/abandoned-projects.md` |
| An app "moved to the new server" but its worker, cron line or vhost is still here | H10 | `references/orphaned-app.md` |
| An approved delete or purge is refused by the session's permission system | all | `references/owner-run-deletions.md` |

## 3. Discovery (read-only)
`<SKILL_DIR>` = this skill's base directory (shown when the skill loads).
```bash
cd <SKILL_DIR>
bash scripts/hygiene-scan.sh                  # one-table overview of H0-H10 (add --full for every detail)
bash scripts/hygiene-scan.sh --with-moodle    # also the password-loop report (Moodle CLI as the web user, read-only)
```
Per item (all read-only, no secrets printed):

| Script | Item | Shows |
|---|---|---|
| `cert-references.sh [--no-dns]` | H1 | each certificate: expiry, domains, enabled/disabled vhost references, DNS, renewal failures, verdict |
| `logrotate-check.sh` | H2 | `logrotate -d` errors, files claimed by two stanzas, big logs without a stanza, next run |
| `cron-output-check.sh [--sample 120]` | H3 | job lines that mail their output, MAILTO in effect, mailbox size and growth |
| `mbox-header-stats.awk` | H3 | per-month and per-subject counts of a mailbox, headers only |
| `secrets-perms.sh [--all]` | H4 | EXPOSED / BROKEN files with mode, owner, the real reader (FPM pool) and the fix |
| `laravel-env-check.sh [APP_DIR]` | H5 | APP_ENV/APP_DEBUG in `.env` and in the cache the app uses, debug packages, env-dependent code |
| `password-loop.php` | H6 | users with `create_password=1`, why mail fails (category), event counts (IDs only) |
| `fail2ban-check.sh` | H7 | service state and error, effective sshd backend, failed SSH logins, your own address's failures |
| `db-listen-check.sh` | H8 | non-loopback listeners, socket activation, bind settings, remote accounts and clients, firewall |
| `inventory-paths.sh --discover / PATH / --personal-data / --docker` | H9 | candidates, proof of non-use, git state, siblings, data files, Docker |
| `orphan-app-check.sh --dir --host` | H10 | every piece of a moved app still on this box, in removal order |
| `probe-sites.sh` | all | status of every hosted name at the origin, for before/after diffs |

**When the server differs:** Apache instead of nginx (scripts read `sites-enabled`; use `apachectl configtest`,
`a2dissite`); Postfix instead of exim (same mailbox path); no certbot (find the other ACME client or skip H1); no
Laravel apps (skip H5); PostgreSQL (H8 uses `listen_addresses`); Moodle 4.x (CLI in `<MOODLE>/admin/cli`, docroot
`<MOODLE>`; on 5.1+ the CLI stays in `<MOODLE>/admin/cli` and the docroot is `<MOODLE>/public`); Redis absent (ignore
its rows). If a finding does not match any case in the reference, stop and ask rather than improvise.

## 4. What to propose to the owner
Use `assets/proposal-ar.md`: one table row per applicable item (what was found with numbers from the scripts, what you
propose, effect on students, rollback, timing), items the owner approves by number, irreversible steps marked and
handed over with `assets/owner-command-ar.md`. Short form for a single item:

> **البند <رقم>: <العنوان>.** وجدت: <الدليل بالأرقام>. لماذا يهم: <سطر واحد>. أقترح: <الخطوات>. الأثر على الطلاب:
> <لا يوجد / انقطاع ثوانٍ في ساعة هادئة>. التراجع: <كيف>. هل توافق؟

## 5. Procedure
Rules for every item: backup → change → test → apply → verify → log → report (core-rules §3). Take a
`probe-sites.sh` snapshot before any change that touches web config, certificates or apps, and diff after. Times in
the log come from `date` or `stat`, never from memory.

**H1 Dead certificates** (`references/timers-certbot-logrotate.md` §3)
1. Backup: `/etc/letsencrypt` and `/etc/nginx` as tgz in `/root/certs-cleanup-<DATE>/` (700); probe snapshot.
2. Change: `certbot delete --cert-name <CERT_NAME>` only for `DEAD-UNREFERENCED`; `DEAD-BUT-ENABLED` waits for its vhost (H10).
3. Test: `nginx -t`. 4. Apply: nothing to reload. 5. Verify (quiet hour: the nginx authenticator reloads nginx during
   a dry run): `certbot renew --dry-run` all succeeded; probe diff empty.
6. Rollback: extract only that certificate's `live/`, `archive/` and `renewal/<CERT_NAME>.conf` from the tgz (never
   the whole archive over `/`: it would undo renewals made since). Confirm at the next real `certbot.timer` run.

**H2 logrotate** (`references/timers-certbot-logrotate.md` §4)
1. Backup = change: move the duplicate stanza to `/root/logrotate.d-<name>.bak-<DATE>` (never keep backups inside
   `/etc/logrotate.d/`: logrotate reads them). New stanzas from `assets/logrotate-custom-log.conf`.
2. Test: `logrotate -d /etc/logrotate.conf` without errors; `logrotate-check.sh` duplicates "none".
3. Apply: wait for the timer. 4. Verify: `Result=success` after the next run. 5. Rollback: move the file back.

**H3 Cron mailbox** (`references/cron-mailbox.md`)
1. Backup the crontab to `/root/crontab-<WEBUSER>.bak-<DATE>` (600); pre-create the log `640 <WEBUSER>:<WEBUSER>`
   in a rotated directory (`assets/logrotate-moodle-cron.conf`, replace `<WEBUSER>` before installing).
2. Change a copy: `MAILTO=""` first line + `>> <log> 2>&1` on the line that lacks it; diff; install with `crontab -u`.
3. Verify: mailbox size frozen (allow one last mail from a runner started earlier), log receives runs, one runner.
4. Rollback: reinstall the backup. 5. The old mailbox: owner decides archive/purge and runs the command.

**H4 Secrets and log modes** (`references/secrets-and-log-modes.md`)
1. Backup modes: `mode-snapshot.sh save /root/perms-before-<topic>-<DATE>.txt <files>`.
2. Change: `chgrp <APP_GROUP>` first, then `chmod 640` (`600` for home credential files); cron logs: dir 750, files
   640, `create 0640` in the logrotate stanza.
3. Test: `runuser -u <APP_USER> -- test -r` ok, `runuser -u nobody -- test -r` denied (this, not an HTTP probe, is
   the real test: OPcache can hide a broken mode until the next PHP-FPM reload).
4. Verify: `secrets-perms.sh` clean, probe diff empty, no permission errors in app logs.
5. Rollback: `mode-snapshot.sh restore … --apply`. Suggest rotating long-exposed secrets (separate owner decision).

**H5 Laravel debug/local** (`references/laravel-debug.md`)
1. Backup `.env`, the cached config and modes to `/root/app-mode-<DATE>/` (700); note status codes.
2. Change with `../nginx/scripts/replace-once.py --line --in-place` (APP_DEBUG first; APP_ENV only with explicit OK); rebuild the cache as the
   files' owner with the app's PHP version if a cache existed; re-apply `chgrp` + `chmod 640`.
3. Test: `laravel-config-keydiff.php` as the app user shows only `app.debug` (and `app.env`) changed.
4. Verify: same status codes, plain 404 for an unknown path, `artisan about --only=environment`.
5. Rollback: copy both files back and restore modes.

**H6 Password loop** (`references/password-loop.md`)
1. Backup: the report (IDs only) to a root-only file. 2. Dry run `--suspend --ids=…`.
3. Change: `--execute` (as site admin via `user_update_user`, sessions ended) for the IDs the owner chose; correct the
   e-mail instead for accounts to keep. 4. Verify: `--verify --since=<change time>` → 0 users, 0 events.
5. Rollback: unsuspend in the UI.

**H7 fail2ban** (`references/fail2ban-journald.md`)
1. Pre-check: your SSH source has 0 failures; admin static IPs in `ignoreip`; provider console works.
2. Change: install `assets/fail2ban-sshd-systemd.local` as `/etc/fail2ban/jail.d/zz-sshd-systemd.local`.
3. Test: `fail2ban-client -t`; effective backend `systemd`. 4. Apply: `systemctl restart fail2ban`.
5. Verify: active, `Total failed` grows, a new SSH session works. 6. Rollback: remove the file, restart.

**H8 Database listener** (`references/db-localhost.md`)
1. Stop if any remote client exists. Timing: quiet hour or maintenance night (DB restart of a few seconds).
2. Change: `assets/mariadb-socket-localhost.conf` as a socket drop-in + `daemon-reload` (or `bind-address` /
   `listen_addresses` for the other cases).
3. Test: `systemctl cat mariadb.socket`. 4. Apply: stop service + socket, start socket + service (never the socket alone).
5. Verify: only `127.0.0.1:3306`; login page 200; cron without DB errors. 6. Rollback: remove the drop-in, same restart.

**H9 Abandoned projects and data** (`references/abandoned-projects.md`)
1. Inventory and classify (A re-creatable / B data / C deferred) with proof of non-use; owner approves item by item.
2. Change: `archive-path.sh --topic <TOPIC> --apply <EXACT_PATH>` (tgz + entry count + sha256, original moved into
   the root-only archive); Docker images by exact name; volumes only after backup and OK.
3. Test: `nginx -t` if a vhost file moved. 4. Verify: probe diff empty, disk freed. 5. Rollback: move back from
   `moved/`. 6. Final deletes later by the owner.

**H10 Orphaned app** (`references/orphaned-app.md`)
Owner confirms the app lives elsewhere → backups into `/root/<TOPIC>-cleanup-<DATE>/` → worker disabled → cron line
removed → vhost disabled (`nginx -t`, reload) → certificate deleted → tree archived → unit file removed
(`daemon-reload`) → vhost file and logs archived → deploy key line removed after the owner confirms a new SSH session.
Never touch the shared PHP-FPM pool. Verify with the probe diff (only `<APP_HOST>` changed). Rollback in reverse order,
certificate before the vhost.

**Irreversible steps** (mailbox purge, deleting archives or personal-data files, `docker volume rm`): run the
pre-checks yourself, then hand the owner one exact command (`references/owner-run-deletions.md`,
`assets/owner-command-ar.md`). If the permission system refuses a command, never work around it.

## 6. Verification checklist
- [ ] `systemctl --failed` empty, or every remaining entry explained in the handbook.
- [ ] certbot and logrotate: dry runs clean now, and `Result=success` recorded after their next real run.
- [ ] `cron-output-check.sh`: no `MAILS-OUTPUT` line for the web user; mailbox size frozen (and purged, if decided).
- [ ] `secrets-perms.sh`: no EXPOSED or BROKEN rows; rotated logs keep 640 (check the day after).
- [ ] `laravel-env-check.sh`: every served app `production` / `false` in the file the app actually reads.
- [ ] `password-loop.php --verify`: 0 looping users, 0 events since the change.
- [ ] `fail2ban-client status sshd`: active, failures counted; owner's new SSH session works.
- [ ] `db-listen-check.sh`: no NOT-LOOPBACK database listener; Moodle works.
- [ ] Archives in `/root/<TOPIC>-cleanup-<DATE>/` are mode 700 with MANIFEST; deletion dates in the handbook to-do.
- [ ] `probe-sites.sh` before/after: only the names you meant to change differ.
- [ ] One log entry per item, with backup, rollback and evidence; the customised-files table updated.

## 7. Log entry example (format from core-rules §3)
```
### YYYY-MM-DD HH:MM — web-user crontab: cron output no longer mailed  (session: <session name>, approved by owner: yes — hygiene H3)
- What/why: the ad hoc task runner line had no redirection, so cron mailed its output every minute to
  /var/mail/<WEBUSER> (local only, never read, task output with personal data).
- Files/settings touched: <WEBUSER> crontab: `MAILTO=""` added as the first line; `>> /var/log/moodle_cron/<site>_adhoc.log 2>&1`
  appended to the adhoc line; log pre-created 640 <WEBUSER>:<WEBUSER> (rotated by /etc/logrotate.d/moodle_cron).
- Backup / rollback: /root/crontab-<WEBUSER>.bak-YYYY-MM-DD (root 600); `sudo crontab -u <WEBUSER> <that file>`.
- Verified: last cron mail HH:MM:SS (runner started under the old crontab), none after; mailbox size frozen at <bytes>;
  adhoc log receives each run; one runner per minute.
- Next: owner decides the old mailbox (archive + purge or purge; irreversible, owner runs the command).
```

## 8. Pitfalls we hit on the first server (generalised)
1. **An expired certificate can still be in use.** One dead certificate was referenced by an enabled vhost of an
   orphaned app; deleting it first would have broken `nginx -t` and the next reload of every site. Check references,
   disable the vhost first.
2. **Backups inside an included directory are live config.** A `.bak` copy in `/etc/logrotate.d/` (or a copy in
   `sites-enabled/`) is read and duplicates the original. Keep such backups in `/root/`.
3. **A dry run is not the scheduled run.** Failed units kept their old `failed` state until the next timer run;
   report "tested; confirmed at the next real run (time)", then check and log it.
4. **The mail server was not the cause of the password loop.** The runbook assumed the new SMTP relay would end the
   loop for "valid-looking" addresses; Moodle's own `validate_email()` rejected all of them before any SMTP. Decide
   with Moodle's function, not an outside regex.
5. **Stop the source before purging.** The crontab fix went live first; one more mail arrived from a runner started
   under the old crontab; only then was the mailbox purge handed to the owner.
6. **Group first, then mode.** A cached Laravel config was readable by its app only as "other"; `chmod 640` alone
   would have broken the app. And `artisan config:cache` later recreates the file `644` with the operator's group.
7. **The cache wins over `.env`.** An app had `APP_DEBUG=true` in a config cache built months earlier; the diff of
   changed keys (names only) proved that only `app.env`/`app.debug` changed when it was rebuilt.
8. **Socket activation ignores `bind-address`,** and restarting `mariadb.socket` alone orphans Moodle's connections.
   An unattended MariaDB upgrade had silently enabled the socket unit.
9. **Debian 12 has no `auth.log`;** fail2ban had been dead since a reboot weeks earlier while looking installed.
10. **Exact paths.** `/opt/moodle*` would have matched a kept maintenance folder; globs under `/root` need `sudo sh -c`.
11. **The permission system refuses irreversible commands even after approval** (a mailbox `truncate`, an `rm` of a
    student CSV, a DB read of phone numbers). Hand the owner the exact command; route data requests to the report builder.
12. **Never print credentials to check them.** Tools such as `mariadb-dump --print-defaults` print stored passwords
    into the transcript; a secret that reached a transcript counts as exposed and needs a rotation. Check presence,
    mode and validity without output.
13. **Test harnesses must not reach real services.** A mock-based test once sent real mail because the script called
    `/usr/sbin/sendmail` by absolute path, bypassing the mock. Scripts here call tools through `PATH`.
14. **A deploy key removal needs a second session.** The owner confirmed a new SSH login before the session ended.
15. **Times in the log must come from `date`/`stat`;** an independent fact-check had to correct estimated times.

## 9. Files in this module
- `SKILL.md`: this file.
- `references/timers-certbot-logrotate.md` (H0–H2), `cron-mailbox.md` (H3), `secrets-and-log-modes.md` (H4),
  `laravel-debug.md` (H5), `password-loop.md` (H6), `fail2ban-journald.md` (H7), `db-localhost.md` (H8),
  `abandoned-projects.md` (H9), `orphaned-app.md` (H10), `owner-run-deletions.md` (irreversible steps).
- `scripts/` (read-only unless noted): `hygiene-scan.sh`, `cert-references.sh`, `logrotate-check.sh`,
  `cron-output-check.sh`, `mbox-header-stats.awk`, `secrets-perms.sh`, `laravel-env-check.sh`,
  `laravel-config-keydiff.php`, `password-loop.php` (writes only with `--suspend --execute`), `fail2ban-check.sh`,
  `db-listen-check.sh`, `inventory-paths.sh`, `orphan-app-check.sh`, `probe-sites.sh` (GET requests to 127.0.0.1),
  `mode-snapshot.sh` (writes only with `restore --apply`), `archive-path.sh` (moves only with `--apply`),
  `lib-env.sh` (sourced helper: server.env parser, cron-line redaction). Exact text edits use the shared
  `../nginx/scripts/replace-once.py` (writes only with `--apply`).
- `assets/`: `proposal-ar.md`, `owner-command-ar.md` (Arabic texts for the owner), `fail2ban-sshd-systemd.local`,
  `mariadb-socket-localhost.conf`, `logrotate-custom-log.conf`, `logrotate-moodle-cron.conf`, `crontab-web-user.example`.
