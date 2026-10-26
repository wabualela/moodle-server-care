# Operating the monitoring: planned work, reboots, alerts, upgrades

Loaded on demand from SKILL.md. Owner-facing versions of these steps are in `owner-steps-ar.md` §5–§6.

## 1. Planned work
Mute silences the on-server alerts; it does not stop the probes and it cannot hide missing pings. Pick the row:

| Work | On the server (session) | Owner |
|---|---|---|
| Config reload, short service restart, maintenance mode for a few minutes | `sudo moodle-health --mute <minutes>` (max 720) before; `--unmute` after; then `--dry-run` must be clean | pause the UptimeRobot keyword monitor if visitors will see errors; resume after |
| DB or Redis maintenance | as above. Note: the DB ping keeps running while muted; with socket activation (MariaDB `mariadb.socket`) a ping can **start the database again** if only `mariadb.service` was stopped. Stop both units when the DB must stay down, or expect the restart | as above |
| Reboot, or anything that stops the timer | 1) `sudo moodle-health --mute <minutes>` (covers the minutes after boot while services settle); 2) `sudo systemctl stop moodle-health.timer`; 3) owner pauses the check; 4) reboot. The enabled timer starts again 2 min after boot | after the session's step 2: pause the check in healthchecks.io and the UptimeRobot monitors; resume the monitors after the session confirms the site is back |
| Stopping monitoring for longer (server move) | `sudo systemctl disable --now moodle-health.timer` | pause the check (or delete it) and the monitors |

Why the timer is stopped before the owner pauses the check: healthchecks.io resumes a paused check when the next ping
arrives (unless the check is set to need a manual resume). A muted script still pings every minute, so a check paused
while the timer runs is un-paused within a minute, and the reboot's silence then raises a "down" alert. After the
reboot the first ping un-pauses the check by itself; if the check is set to manual resume, the owner resumes it.

After the work: `sudo moodle-health --unmute` (or let the mute expire), `sudo moodle-health --dry-run` → "all checks
OK" or only known warnings, `systemctl is-active moodle-health.timer` → active, the owner sees green in both
dashboards. Put these lines into any maintenance-night timeline (maintenance module): mute + stop timer at T-45 min,
unmute + dry run + resume at the end.

## 2. When an alert arrives (session runbook)
1. Read, do not change: `sudo moodle-health --status` (last result, confirming keys, mute), `journalctl -u
   moodle-health --since -30min --no-pager`, `sudo moodle-health --dry-run` (current state).
2. Locate with the matrix in `external-uptime.md` (ask the owner what UptimeRobot shows).
3. Follow the message: `svc:` → `systemctl status <unit>`, its journal; `site` → the vhost error log, FPM log; `db` →
   DB journal, disk; `5xx` → which URLs (`awk '$9 ~ /^50/' <access log> | tail`); `f2b:` → which jail banned which edge
   address (`fail2ban-client status <jail>`), unban only with the owner's go-ahead and fix the jail (real client IP,
   `ignoreip` for the proxy ranges: cloudflare and hygiene modules); `mailq` → `exim -bp | head` / `mailq | head`,
   the relay log (mail module); `disk` → `du` of the dataroot/logs; `cron` → the cron log tail, `crontab -u <WEBUSER> -l`;
   `moodle:<ref>` → `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/checks.php -v --filter=<ref>`; `cert` → certbot timer
   and the cloudflare module's renewal notes.
4. Propose the fix to the owner (Arabic), get approval, apply with the change protocol. Report and log.
5. If the alert was false (monitor bug, wrong threshold): say so plainly, log it as an incident entry, fix the cause
   (config or script) with the change protocol. A monitor that cries wolf gets ignored.

## 3. After a Moodle upgrade or plugin change
Status checks can change their messages or add new ones. Right after the upgrade (inside the change window, while
muted): `sudo moodle-health --dry-run`. If it lists `Moodle status check ... different message` or new refs that are
expected (read them with `checks.php -v --filter=<ref>`), show them to the owner and re-record:
`sudo moodle-health --baseline`. Unexpected ones are real findings: report them.

## 4. Changes that affect the monitors
| Change | Update |
|---|---|
| server moves to a new IP | UptimeRobot port/ping monitor target (owner); re-run `install.sh plan` on the new server |
| a vhost added or removed on the box | `EXTRA_SITES` in `/etc/default/moodle-health` and the owner's UptimeRobot list |
| Cloudflare ranges regenerated (cloudflare module) | nothing: the script reads `CF_RANGES_FILE` every run |
| PHP version change (php8.3 → php8.4) | `SERVICES` (FPM unit), `PHPBIN`, `FPM_LOGS`; `--self-check` + `--dry-run` |
| Redis password added (maintenance module) | nothing: `NOAUTH` counts as alive |
| MTA switched (exim ↔ Postfix) | `MTA`, `SERVICES` |
| Moodle cron log path changed | `CRON_LOG` |
Each edit of `/etc/default/moodle-health`: backup (`cp -a ... .bak-YYYY-MM-DD`), edit, `--self-check`, `--dry-run`,
log. No reload is needed: every run reads the file.

## 5. Monthly look (10 minutes)
- healthchecks.io event log: alerts last month, each explained? Any flapping key?
- `sudo moodle-health --status`: no long-standing warning nobody acts on.
- UptimeRobot: monitors still match the vhosts on the box; uptime numbers for the owner's report.
- `--test-fail` only if the owner wants to re-check his phone's notification settings.
