# Maintenance night: step details

Every step of `assets/night-plan-template.md`, with the reason, the commands, the check and the way back. Times are
relative to T0 (the reboot). `<backup>` is the backup install name (default `moodle-backup`).

## Contents
1. Choosing the night and the items
2. Backup handling (cases a and b)
3. Local dump (case b)
4. Provider snapshot
5. Countdown banner and maintenance mode
6. Pre-checks
7. unattended-upgrades window
8. Redis password
9. DB password rotation
10. Reboot
11. Post-checks and opening the site
12. After the night
13. Order of changes and why
14. Monitoring during the night (T-45 and T+12)

## 1. Choosing the night and the items

- **Night**: inside the measured quiet window (audit module: requests per hour over 14 days), not before an exam day,
  with the owner awake or reachable for the snapshot and his two scripts. The owner's approval names the date and
  time; in Arabic "ليلة الجمعة" usually means the night Thursday → Friday: confirm in writing which calendar day.
- **Items**: only what needs the window: a pending reboot (kernel, OpenSSL and other libraries), Redis `requirepass`,
  a DB password rotation, the unattended-upgrades move, DB server restarts for approved settings. Each item is
  approved separately; anything not ready by the day before (a `--check` not `Ready: yes`) is dropped, not improvised.
- **Expected downtime**: maintenance page about 15 min (T-10 → T+5) for Redis + DB password + reboot. Announce a wider
  window (see the announcement notes).

## 2. Backup handling (cases a and b)

Decide the day before which case applies:
- **(a)** the nightly backup (`skills/backup`) is installed and has a successful run. At T-120: one manual run with
  `sudo systemctl start --no-block <backup>.service`, then poll `systemctl show -p ActiveState,SubState,Result
  <backup>.service` every 1–2 min until `ActiveState=inactive`. Do not use a blocking `start`: a Claude tool call stops
  waiting after 10 min and a run can take longer. Then `Result` must be `success` and `/var/lib/<backup>/status` must
  show `last_ok` from this run. **Not `success`** (for example an expired token: `invalid_grant` / `AADSTS50173` in
  `journalctl -u <backup>.service -n 50`): switch to case (b) at T-30 tonight; the owner fixes the backup after the
  night. Not finished by T-35: `sudo systemctl stop <backup>.service`, then case (b).
- **(b)** no backup yet, or no successful run: local dump at T-30 (section 3) in addition to the snapshot.
- **In either case**, a timer that exists and is enabled is disabled before the banner (T-120 in case (a); at T-45 in
  case (b): `systemctl is-enabled <backup>.timer` prints `enabled` → `sudo systemctl disable --now <backup>.timer` and
  note it), so the timer cannot start a dump inside the window and does not come back at boot (`stop` alone would).
- **After the night** (T+10): `sudo systemctl enable --now <backup>.timer`; `systemctl list-timers '<backup>*'` shows
  the next run. Check `systemctl show -p Persistent` = `no`, so enabling never starts a run at once (if `yes`, enable
  it only when a run fits before the apt window). **Enabled before the timer's slot**: it runs at the slot, after the
  window. **Enabled after the slot**: no run tonight, and healthchecks.io (its cron schedule plus grace) would send a
  false "down" alert later in the night: either start one run by hand early enough to end before the apt window
  (`--no-block`, poll as at T-120), or the owner pauses the check until the next night's run.
- The first backup after the window is the first set whose config bundle holds the new DB/Redis passwords; older sets
  keep the old ones (restore a set with its own config).

## 3. Local dump (case b)

```bash
D=/root/pre-maintenance-$(date +%F); sudo install -d -m 700 "$D"
sudo bash -c "mariadb-dump --single-transaction --quick --hex-blob --routines --events --triggers \
  --default-character-set=utf8mb4 --max-allowed-packet=1G <dbname> | zstd -q -T2 -3 -o $D/<dbname>.sql.zst"
sudo bash -c "zstd -q -t $D/<dbname>.sql.zst && zstdcat $D/<dbname>.sql.zst | tail -n 1"   # -- Dump completed ...
```
Root over the unix socket, no password (never `--print-defaults`, never a password on the command line). It holds
personal data and the old passwords: root-only folder, owner deletes it after about 7 good days.

## 4. Provider snapshot

The rollback for a bad kernel or a server that does not come back. Mandatory before a reboot.
- DigitalOcean: Droplets → the droplet → Backups & Snapshots (older UI: Snapshots) → Take live snapshot. Other
  providers have the same idea (Hetzner: Snapshots; AWS: EBS snapshot / AMI; Linode: Backups → Take a snapshot).
- Name it `pre-maintenance-<date>`; start at T-60 (time grows with used disk); it must show **complete** before T0.
- Check whether the server has a boot menu: `GRUB_TIMEOUT=0` means no menu in the console, so the snapshot (or the
  provider's recovery image) is the only quick way back to the old kernel.
- Snapshots cost per GB: the owner deletes it after about 7 good days.
- A snapshot taken after T-40 also carries Moodle's `maintenance_later` schedule (and, after T-10, the maintenance
  flag file): after a restore, the first request switches the site to maintenance. Run the checks, then
  `maintenance-mode.sh disable` (it also clears the schedule).

## 5. Countdown banner and maintenance mode

`scripts/maintenance-mode.sh` wraps Moodle's `admin/cli/maintenance.php` and checks the result each time.
- **T-40** `sudo bash scripts/maintenance-mode.sh schedule 30`: Moodle stores `maintenance_later` = now + 30 min and
  every page shows the red countdown banner (core `maintenance_warning`). At the time, the **first request** (a page,
  or a CLI script such as cron) switches to CLI maintenance by itself. Check the banner from outside on the login page.
  Refused when CLI maintenance is already on. Cancel: `maintenance-mode.sh disable` (also clears the schedule).
- **T-10** `maintenance-mode.sh confirm`: if the flag file is not there yet (no request since the time), it boots
  Moodle once with a harmless CLI read (the same code path as the first request) and, if that still does not switch,
  falls back to `--enable`. `maintenance.php` exits 0 even when it refuses, which is why the script checks the state.
- CLI maintenance needs neither the DB nor Redis: students get a plain 503 page while both change. CLI scripts (as the
  web user) keep working, which the two password scripts use for their checks.
- Without the banner (very short window, or the owner prefers not): `maintenance-mode.sh enable` at T-10.

## 6. Pre-checks (T-15)

`sudo bash scripts/night-checks.sh pre` saves a snapshot of the state (kernel, reboot-required, failed units, services,
listeners, processes on replaced libraries, buffer pool, Redis PING, maintenance flag, Moodle CLI DB read, Moodle's
Redis settings, login page, unknown-host refusal, mail queue, apt and backup timers). Plus:
- backup case (a): `systemctl is-active <backup>.service` = inactive and `systemctl list-timers --all '<backup>*'`
  shows no next run; case (b): dump complete;
- `set-redis-password.sh --check` and `rotate-db-password.sh --check` → `Ready: yes` (maintenance ON by now or soon);
- snapshot complete.
Anything unexpected: stop and decide with the owner before T-10 (cancelling is cheap until maintenance starts).

## 7. unattended-upgrades window (T-12)

See `unattended-upgrades.md`. Drop-in from `assets/apt-daily-upgrade.override.conf.in` (render `@APT_AT@`, e.g.
`03:45`, and `@APT_DELAY@`, e.g. `15m`), then `sudo systemctl daemon-reload` and `systemctl list-timers
apt-daily-upgrade.timer` must show the new time. Done inside the window so that the first night after it already
upgrades at the new time; it changes nothing user-visible.

## 8. Redis password (T-10 → T-6)

See `redis-auth.md`. The owner runs `sudo bash <skill>/scripts/set-redis-password.sh --moodle <MOODLE>` in his own
SSH terminal (it shows a generated password once and needs his paste back). It refuses without CLI maintenance, with
unknown Redis clients, ACL users, an existing password or a non-local Redis. It must end with `REDIS PASSWORD SET`.
The session then checks without the password: `night-checks.sh` (Redis `NOAUTH` without password, Moodle's Redis
settings `ok`). **Order**: Redis before the DB password (the DB rotation then checks Moodle CLI with Redis already
protected; and the Redis script's own phpredis check has already proven Moodle's sessions and stores work).
- If the Redis item follows another procedure (an older runbook) that ends with `maintenance.php --disable`, **skip that
  line on the night**: maintenance stays on until T+3, and the DB rotation refuses to start (or stops before any
  change) when maintenance is off.
- A whole-file backup of config.php taken by a Redis procedure holds the **old** DB password. Its "restore the backup"
  rollback is valid only until the DB rotation starts. After that, undo Redis by removing only its own lines
  (`set-redis-password.sh --rollback` does exactly that), or roll back the DB password first.

## 9. DB password rotation (T-6 → T-1)

See `db-password.md`. Before the night the session installs the frozen root-owned copy `/root/rotate-db-password.sh`
and records its sha256 (the owner keeps it outside the server). On the night the owner, in a **standalone SSH client
window** (never a terminal tab inside the Claude app, never an editor's integrated terminal, no screen sharing),
first checks `sudo sha256sum /root/rotate-db-password.sh` against his record, then runs `sudo bash
/root/rotate-db-password.sh --moodle <MOODLE>`. **The session does not read the owner's terminal** (no terminal-reading
tools, no screenshots); it waits for his report. It must end with `ROTATION COMPLETE`, exit 0; the owner tells the
session only the exit code (`echo $?`) and the backup folder name (its time stamp is the `--since` of the T+5 log
check). Any other exit: the table in `db-password.md` §5 (1 = nothing changed, continue without it; 2 = done with a
warning; 3 = **do not reboot** until the rollback is done; 130 / dropped connection = check `STATUS`).

## 10. Reboot (T0)

**Only after** the owner has reported the DB password step (exit code and folder name, or "not run") **and**
`pgrep -af '[r]otate-db-password'` prints nothing (the brackets keep pgrep from matching the calling shell). If the
owner is still busy at T0, wait: T0 follows the owner, not the clock. Exit 3: no reboot before the rollback is done.
Then `sudo systemctl reboot`. Why a reboot and not service restarts: the new kernel needs it, and it restarts every
service on the updated libraries at once (nginx in particular keeps the old OpenSSL across reloads). Reconnect after
about a minute; if SSH does not return within 5 min, use the provider's web console. See `reboot-rollback.md`.

## 11. Post-checks and opening the site (T+3 → T+5)

1. `sudo bash scripts/night-checks.sh post --rotation-dir /root/dbpw-rotation-<time>`: kernel = newest,
   reboot-required no, services active, buffer pool load completed, Redis NOAUTH without password, **Moodle CLI DB read
   ok and Moodle Redis settings ok before maintenance is switched off**, listeners as before, the diff against "pre".
   The DB password lines (the script prints counts only):
   - `Access denied for user '<dbuser>'@... (using password: YES)` in the DB server's journal since the time in the
     folder name (`dbpw-rotation-YYYYmmddTHHMMSS` = just before the `ALTER`) → expected 0. `--since` and not `-b`:
     it also covers the minutes before the reboot. Lines with `(using password: NO)` come from tools run without a
     password (an operator's `mariadb`), not from Moodle, and are reported separately; older `YES` lines from before
     the rotation are outside the window. If the DB server logs to a file (`log_error`), the script says so: check
     that file instead;
   - connections of the Moodle DB user after the first page load (as root, a count only) → greater than 0;
   - password lines left in the operator's `~/.my.cnf` (a file check printing only a count; no login attempt, so
     nothing new in the DB log) → 0. Not 0 (exit 2 or 130 left it): the `sed` line from `db-password.md` §6.
2. `sudo bash scripts/maintenance-mode.sh disable` → login page 200 from outside and through 127.0.0.1.
3. Log in as an admin (owner) and open one course; Site administration → Plugins → Caching → Configuration: the
   Redis stores are Ready.
4. After 3 min: the Moodle cron log shows no DB or Redis errors (cron runners started before the change may log errors
   until they exit); `night-checks.sh post --rotation-dir ...` again: access denied (using password: YES) = 0, Moodle
   DB user connections > 0.
5. Backup timer back on (section 2).

## 12. After the night

- Log entry per change (no secrets; backup folder names only), customised-files table (apt drop-in, redis.conf,
  config.php session line, MUC config), handbook plan items.
- Owner, after about 7 good days: delete the snapshot; `shred -u` the folders holding old passwords
  (`/root/dbpw-rotation-*`, the local dump of case b); remove stale copies of old passwords (old `config.php.bak-*`,
  editor histories, shell histories with inline `-p...`).
- Tools that called `redis-cli` without a password (monitors, collectors) now get NOAUTH: give them
  `REDISCLI_AUTH` from a root-only file, or accept empty Redis columns.
- If the temporary passwordless sudo was only for the night, let its timer expire (or revoke now).
- Tell the owner the remaining risk if discovery found it (`db-password.md` §9): the operator account in the web
  server's group can still read the new password in config.php.

## 13. Order of changes and why

backup → snapshot → banner → (dump) → pre-checks → apt window → maintenance on → Redis → DB password → reboot →
post-checks → maintenance off → backup timer on.
- Backup and snapshot first: every later step has a way back.
- Redis before DB: each script ends with its own proof (phpredis PONG for Moodle's Redis settings, then the Moodle CLI
  DB read), so a problem is caught by the step that caused it, before the reboot.
- Reboot last: it is the hardest to undo and it restarts everything on the new libraries; it also proves that the
  new passwords survive a restart (redis.conf, config.php).
- Undo in reverse order of application.

## 14. Monitoring during the night (T-45 and T+12)

Why: a maintenance page and a reboot look like an outage to every monitor. The monitoring module's `moodle-health`
keeps pinging healthchecks.io while muted (mute only silences its own alerts), and healthchecks.io un-pauses a paused
check at the next ping. If the owner pauses the check while the timer still runs, the next minute un-pauses it and
the reboot's silence then sends a false DOWN alert to the owner's phone at night. Alerts that cry wolf get ignored
later, so the order matters.
- **T-45 (session):** `sudo moodle-health --mute 90` (covers the window and the minutes after boot, when services
  settle); `sudo systemctl stop moodle-health.timer`; `systemctl is-active moodle-health.timer` → `inactive`. Then tell
  the owner to pause the healthchecks.io check and the UptimeRobot monitors (`../monitoring/references/owner-steps-ar.md`
  §5).
- **Reboot:** the enabled timer starts again about 2 minutes after boot; the mute is still active, so the maintenance
  page until T+5 raises no alert.
- **T+12 (after post-checks and opening the site):** `sudo systemctl start moodle-health.timer` (no-op when it already
  runs); `sudo moodle-health --unmute`; `sudo moodle-health --dry-run` → "all checks OK" or only known warnings. The
  owner resumes the monitors (a check set to "manual resume" needs his click) and confirms green in both dashboards.
- **No monitoring module installed:** the owner pauses whatever external monitors exist at T-45 and resumes them at
  T+12.
- **Rollback / aborted night:** do the T+12 steps anyway; a timer left stopped means no alerting at all.
