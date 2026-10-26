# Maintenance night <DATE> <T0 local time> (<SITE>): the night's script

> Template (moodle-server-care, skills/maintenance). Copy it to the server's runbook folder, fill every `<...>`, delete
> the rows that do not apply, and get the owner's approval of the date, the items and the announcement. During the
> night, tick each row and write the real time next to it (from `date`, not from memory).

**Owner approval:** <date and words of the approval>. **T0** = the reboot at <HH:MM>. Maintenance page from about
T-10 to about T+5 (<announced window with buffer, e.g. T-15 → T+30>). **T0 follows the owner, not the clock:** the
reboot waits until the DB password step is reported finished (row T0).
**Items tonight** (delete what does not apply): provider snapshot · countdown banner · unattended-upgrades window ·
Redis password · DB password rotation · reboot (kernel <running> → <newest>, OpenSSL) · <other approved item>.
**Backup case:** (a) nightly backup installed with a successful run → manual run before the window, timer disabled for
the window; (b) not installed / no successful run → local `--single-transaction` dump at T-30 to a root-only file.
Case (a) falls back to (b) tonight if the T-120 run does not end with `Result=success`. In **either** case a timer that
exists and is enabled is disabled before T-40 (rows T-120 / T-45) and enabled again at T+10.
**Temporary sudo** (if the session executes): expires <date time> by `revoke-*-sudo.timer`: still active tonight? <yes/no>

## Before the night
- [ ] Announcement sent ≥ 24 h before (`assets/announcement-ar.md`), reminder the same evening; teachers told about
      quiz close times and timed attempts.
- [ ] `bash scripts/discover.sh` re-run the day before; kernel/reboot-required as expected.
- [ ] Redis: other programs using it identified (discover: clients, other apps' `.env` REDIS_* keys); they get the
      password in the same window, or the Redis item is dropped.
- [ ] Owner: password-manager entries ready (Redis password, new DB password).
- [ ] Owner: a **standalone SSH client window** on his own computer for both scripts (Windows Terminal / PowerShell
      `ssh`, macOS Terminal, PuTTY). **Not** a terminal tab inside the Claude app, **not** an editor's integrated
      terminal (VS Code Remote-SSH): Claude sessions can read those. No screen sharing or recording during the steps.
      Login tested the day before.
- [ ] DB password script frozen after its final review (session, owner's go-ahead, log entry):
      `sudo install -o root -g root -m 700 <SKILL_DIR>/scripts/rotate-db-password.sh /root/rotate-db-password.sh && sudo sha256sum /root/rotate-db-password.sh`.
      Hash here: **`<fill in at install>`**, in the log entry, and kept by the owner outside the server. Any later
      change to the script = install again, new hash.
- [ ] `sudo bash scripts/set-redis-password.sh --check` → `Ready: yes` (maintenance OFF shows as info).
- [ ] `sudo bash /root/rotate-db-password.sh --check --moodle <MOODLE>` → `Ready: yes` (read-only, prints no secret).
- [ ] Provider snapshot procedure known (panel path, expected duration for <disk used> GB); console access tested.
- [ ] Rollback plan below read by whoever runs the night.

## The night
| Time | Step | Who | Done (real time) |
|---|---|---|---|
| T-120 → T-65 | **Backup, case (a):** `sudo systemctl start --no-block <backup>.service`, poll `systemctl show -p ActiveState,SubState,Result <backup>.service` every 1–2 min until `ActiveState=inactive` (a blocking `start` outlives a Claude tool call, which stops waiting after 10 min); `Result` = success; status `last_ok` = this run. **Not success** (e.g. token expired: `invalid_grant` in `journalctl -u <backup>.service -n 50`): case (b) at T-30 tonight, fix after the night. Either way then `sudo systemctl disable --now <backup>.timer` (`stop` alone comes back at boot). Not finished by T-35: `systemctl stop`, then case (b) | session | |
| T-60 → T-15 | Provider **snapshot** "pre-maintenance-<DATE>", must show **complete** before T0 (it is the rollback; with `GRUB_TIMEOUT=0` there is no boot menu) | owner (panel) | |
| T-45 | **Case (b) with a timer that exists:** `systemctl is-enabled <backup>.timer` prints `enabled` → `sudo systemctl disable --now <backup>.timer` and note it (T+10 turns it back on). No unit: nothing to do | session | |
| T-45 | **Monitoring quiet** (`references/night-script.md` §14): `sudo moodle-health --mute 90`; `sudo systemctl stop moodle-health.timer`; `systemctl is-active moodle-health.timer` = inactive. **Then** the owner pauses the healthchecks.io check and the UptimeRobot monitors (a muted script still pings, and a ping un-pauses a paused check: wrong order = false DOWN alert at the reboot). No monitoring module: owner pauses whatever external monitors exist | session, then owner | |
| T-40 | **Countdown banner:** `sudo bash scripts/maintenance-mode.sh schedule 30` → banner now, CLI maintenance at T-10 by itself. Check the banner on the login page from outside. Cancel before T-10: `maintenance-mode.sh disable` | session | |
| T-30 | **Case (b) only:** local dump (`references/night-script.md` §3) to `/root/pre-maintenance-<DATE>/`, check the trailer | session | |
| T-15 | `sudo bash scripts/night-checks.sh pre`; backup OK (a: service inactive and no next run; b: dump complete); both `--check` scripts `Ready: yes` | session | |
| T-12 | unattended-upgrades window → <APT_AT> (`references/unattended-upgrades.md`): drop-in, `daemon-reload`, `list-timers` shows it | session | |
| T-10 | `sudo bash scripts/maintenance-mode.sh confirm` → ON (triggers the schedule, falls back to `--enable`) | session | |
| T-10 → T-6 | **Redis password**: the owner runs `sudo bash scripts/set-redis-password.sh --moodle <MOODLE>` in his standalone window → `REDIS PASSWORD SET`; tells the session only the backup folder name. If the Redis item follows an older procedure that ends with `maintenance.php --disable`, **skip that line tonight**: maintenance stays on until T+3 | owner | |
| T-6 → T-1 | **DB password**: the owner, in his **standalone SSH client window**, first checks `sudo sha256sum /root/rotate-db-password.sh` against his record, then runs `sudo bash /root/rotate-db-password.sh --moodle <MOODLE>` → `ROTATION COMPLETE`, exit 0. **The session does not read the owner's terminal** (no terminal-reading tools, no screenshots) and waits. The script re-checks everything right after `ROTATE`, backs up config.php to `/root/dbpw-rotation-<time>/`, keeps its SQL out of the slow log, replaces only the dbpass line. The owner tells the session only the exit code (`echo $?`) and the backup folder name. Any other ending: "If the rotation does not end with exit 0" below | owner (session waits) | |
| T0 | **Only after** the owner reported the DB step (exit code and folder, or "not run") **and** `pgrep -af '[r]otate-db-password'` prints nothing. Owner still busy: wait. Exit 3: no reboot before the rollback is done. Then `sudo systemctl reboot` (new kernel; every service restarts on the updated libraries) | session | |
| T+3 | `sudo bash scripts/night-checks.sh post`: kernel = newest, services active, buffer pool loaded, Redis NOAUTH without password, Moodle CLI DB read ok, Moodle Redis settings ok, listeners. **Then** `maintenance-mode.sh disable`, login 200 | session | |
| T+5 | DB password post-checks, maintenance off, in this order: (1) login page 200, no "Database connection failed" in the body; (2) `sudo bash scripts/night-checks.sh post --rotation-dir /root/dbpw-rotation-<time>`: access denied **with a password** for the Moodle DB user since the folder's time stamp = 0 (`--since` from the folder name also covers the minutes before the reboot, which `-b` would miss; lines "without a password" come from tools, not Moodle; older lines from before the rotation are outside the window); (3) Moodle DB user connections > 0 after the first page load; (4) cron log clean after 3 min; (5) operator `~/.my.cnf` password lines = 0 (a count, no login attempt). Not 0: the `sed` line from `references/db-password.md` §6 | session | |
| T+10 | **Backup back on** (if it was disabled at T-120 or T-45): `sudo systemctl enable --now <backup>.timer`; `systemctl list-timers '<backup>*'` shows the next run; `systemctl show -p Persistent` = no, so enabling never starts a run at once. **Enabled before the timer's slot** → it runs after the window: the first set with the new passwords. **Enabled after the slot** → no run tonight, and healthchecks.io would send a false "down" after its grace time: start one run by hand (`--no-block`, poll) early enough to end before the apt window, or the owner pauses the check until the next night | session (owner: healthchecks) | |
| T+12 | **Monitoring back:** `sudo systemctl start moodle-health.timer` (already running if it started after boot), `sudo moodle-health --unmute`, `sudo moodle-health --dry-run` → all OK or known warnings; the owner resumes healthchecks.io and UptimeRobot and sees green | session, then owner | |
| T+15 | Log entry (no secrets; backup folder names only), handbook updated, owner told; snapshot and `/root/*-<DATE>*` folders with old passwords deleted by the owner after ~7 good days (`shred -u`) | session / owner | |

### If the rotation does not end with exit 0
The owner reads out the exit code (`echo $?`) and, where asked, the `WARN`/`ERROR` lines (they hold no secret).

| Exit | Meaning | What to do |
|---|---|---|
| 1 | Failed; nothing is left changed (an automatic revert, if one was needed, succeeded) | Continue the night without the rotation (T0 as planned); reschedule it |
| 2 | The rotation is done, a follow-up step warned | Read the WARN lines. A failed FPM reload is fine: the reboot restarts FPM. A `~/.my.cnf` warning: fixed at T+5 (5). Then T0 |
| 3 | Manual attention needed | **Do not reboot.** `sudo bash /root/rotate-db-password.sh --rollback /root/dbpw-rotation-<time> --moodle <MOODLE>`, or the by-hand recipe it printed, until `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=version` prints the version. Then T0; reschedule the rotation |
| 130, SSH dropped, killed, power loss, reboot mid-run | Interrupted | Reconnect (standalone window). `pgrep -af '[r]otate-db-password'` still shows it (tmux): reattach and finish there. Otherwise `sudo ls -d /root/dbpw-rotation-*` (newest = this run; none = stopped before the backup, nothing changed), `sudo cat /root/dbpw-rotation-<time>/STATUS`, then the `cfg.php` check. **`complete` / `verified`**, version prints → in place; reload FPM; T+5 (5) catches `~/.my.cnf`. **`reverted`**, version prints → nothing changed. **`config`**, version prints → in place, last checks not run: reload FPM, T+5 (5). **Anything else, or no version** → `--rollback /root/dbpw-rotation-<time>`, then the `cfg.php` check, continue without the rotation |

## Rollback
- **Droplet/VM does not come back, or the new kernel misbehaves:** restore the snapshot (provider panel) or boot the
  provider's recovery image. The snapshot predates both password changes: it brings back the old DB password in
  config.php and the DB, and Redis without a password, consistently. Moodle works; reschedule the rotations. A
  snapshot taken after T-40 also carries the `maintenance_later` schedule (after T-10 the maintenance flag too): after
  the restore, run the checks, then `sudo bash scripts/maintenance-mode.sh disable` (it also clears the schedule).
- **DB password problem:** `sudo bash /root/rotate-db-password.sh --rollback /root/dbpw-rotation-<time> --moodle
  <MOODLE>`. Maintenance off: it asks first. config.php changed after the rotation (e.g. the Redis line): it lists the
  differences by line number and key only and asks; those lines are kept. It sets back only the dbpass line and the
  old DB password, checks the Moodle CLI DB read and reloads FPM.
- **Redis problem:** `sudo bash scripts/set-redis-password.sh --rollback /root/redis-auth-<time>` (removes only what it
  added; safe after the DB rotation because it never copies an old config.php back). A whole-file config.php backup
  from an older Redis procedure holds the OLD DB password: never copy it back after the DB rotation started.
- **Both:** undo in reverse order of application: DB password first, then Redis.
- **unattended-upgrades window:** `sudo systemctl revert apt-daily-upgrade.timer && sudo systemctl daemon-reload`.
- **Night aborted after the backup timer was disabled:** enable it again anyway.
- **Night aborted after T-45:** do the T+12 monitoring row anyway (start the timer, unmute, owner resumes the checks).
- **Maintenance page stuck:** `sudo bash scripts/maintenance-mode.sh disable`.
