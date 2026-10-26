---
name: maintenance
description: Plans and runs one announced maintenance night on a production Moodle server - provider snapshot as rollback, Moodle countdown banner (maintenance.php --enablelater) with verified switch to CLI maintenance, unattended-upgrades moved into the quiet window, Redis requirepass for Moodle sessions and MUC stores, Moodle DB password rotation run by the owner, reboot for kernel/OpenSSL, pre/post checks, rollback, nightly-backup handling, and Arabic announcements for students and teachers. Use it whenever a Moodle server has a pending reboot or kernel update, services still running old OpenSSL, automatic upgrades restarting the DB in busy hours, Redis without a password, a leaked or stale DB password, or when the owner asks for a maintenance window, downtime announcement or "صيانة" - even if only one of these items is mentioned.
---

# Maintenance: one announced night, every risky item in one window

## 1. Read first
Read `../../shared/core-rules.md` (approval, quiet hours, secrets, change protocol). Then `references/night-script.md`
(the reason and the commands for each step). The night's script is `assets/night-plan-template.md`, filled per server.

## 2. When to use / signs
- `/var/run/reboot-required` exists or the running kernel is older than the newest installed; processes map deleted
  libraries (nginx on an old OpenSSL survives reloads).
- unattended-upgrades runs in a busy hour and restarted the DB, nginx, Redis or PHP-FPM there.
- Redis answers PING without a password while Moodle keeps sessions/caches in it.
- The Moodle DB password was exposed (transcript, log, world-readable file, history) or must rotate.
- Several such items: batch them into ONE announced night instead of several surprises.

## 3. Discovery (read-only)
```bash
bash ../start/scripts/detect-env.sh                     # if server.env is missing or older than a day
bash scripts/discover.sh                                # reboot, libraries, apt schedule/origins, GRUB, provider, Redis, DB keys and logs, config.php readers, backup, sudo
sudo bash scripts/set-redis-password.sh --check --moodle <MOODLE>   # Redis item: every precondition, no secret printed
sudo bash scripts/rotate-db-password.sh --check --moodle <MOODLE>   # DB item: every precondition, no secret printed
sudo bash scripts/maintenance-mode.sh status            # maintenance state, login page code
```
Also: quiet window (audit module), the handbook's open items, the backup module's state. Decide per finding:

| Finding | Action |
|---|---|
| nothing pending and no item approved | no night needed: say so |
| `GRUB_TIMEOUT=0` | the provider snapshot is the only quick kernel rollback: mandatory |
| provider without snapshots | stop and ask (a fresh full backup and a tested restore become the rollback) |
| Redis used by other apps | they get the password in the same window, or drop the Redis item |
| Redis already protected / ACL users / TLS / cluster / remote | drop the Redis item; stop and ask |
| DB is MySQL, PostgreSQL, remote/managed, or not `mysql_native_password` | the rotation script refuses: adapt (references/db-password.md) or drop the item |
| PHP from a third-party repository not in unattended-upgrades origins | owner decision A1/A2 (references/unattended-upgrades.md) |
| no nightly backup yet | backup case (b): local dump before the window |
| DB general log or binlog on | the rotation's hash would be recorded: owner decision (accept, or switch off for the night) |
| operator account in the web server's group, config.php group-readable | tell the owner: sessions can read the new password too (references/db-password.md §9) |
| RHEL family / no systemd timers for apt | stop and ask (different tooling) |

## 4. Proposal to the owner (Arabic template)
```
**ليلة صيانة واحدة معلنة — اقتراح**

| البند | لماذا | المدة | من ينفّذ |
|---|---|---|---|
| لقطة كاملة للخادم من لوحة المزوّد قبل البدء | هي طريق التراجع إن لم يعد الخادم | قبل النافذة | أنت (لوحة المزوّد) |
| لافتة عدّ تنازلي داخل المنصة قبل 30 دقيقة | ينهي الطلاب عملهم قبل التوقف | — | Claude |
| نقل التحديثات التلقائية إلى <الوقت> | كانت تعيد تشغيل <الخدمات> في ساعة مزدحمة | دقيقة | Claude |
| كلمة مرور لـ Redis | يصل إليه حالياً أي برنامج على الخادم | ~2 دقيقة داخل الصيانة | أنت (سكربت في طرفيتك) |
| تغيير كلمة مرور قاعدة البيانات | <السبب> | ~3 دقائق داخل الصيانة | أنت (سكربت في نافذة SSH مستقلة على جهازك، لا يراها Claude) |
| إعادة تشغيل الخادم | نواة جديدة معلّقة منذ <التاريخ> وتحديثات أمنية لـ OpenSSL | ~3 دقائق | Claude |
| إسكات التنبيهات قبل النافذة وإعادتها بعدها | حتى لا يصلك تنبيه كاذب بتعطل المنصة أثناء إعادة التشغيل | دقيقتان | Claude ثم أنت (إيقاف الفحوص الخارجية مؤقتاً) |

الموعد المقترح: <اليوم والتاريخ> الساعة <T0> (أهدأ ساعات المنصة حسب السجلات).
التوقف الفعلي: نحو <15> دقيقة، والإعلان يقول <نافذة أوسع> احتياطاً.
النسخ الاحتياطي: <تشغيل يدوي قبل النافذة وإيقاف المؤقت أثناءها / نسخة محلية من القاعدة قبل النافذة>.
الإعلان: نص جاهز للطلاب والمعلمين (رسالة قصيرة، إعلان في المنصة، تنبيه للمعلمين) لتعتمده.
المطلوب منك: الموافقة على الموعد والبنود، واللقطة، وتشغيل السكربتين في نافذة SSH مستقلة على جهازك (ليست طرفية تطبيق
Claude ولا طرفية VS Code، ودون مشاركة الشاشة)، ومدير كلمات المرور جاهز، وحفظ بصمة السكربت التي أرسلها لك قبل الليلة.
التراجع: لكل بند طريق رجوع مكتوب، والأخير هو استعادة اللقطة.
```

## 5. Procedure
Fill `assets/night-plan-template.md` for this server (times from the quiet window, items approved, backup case) and
store it with the server's runbooks. Each step: backup → change → test → apply → verify → log; rollback written first.

1. **Approval and announcement (T-24 h).** Owner approves date, items, text. Send `assets/announcement-ar.md` (owner's
   channel), reminder the same evening. Why: students lose quiz attempts and work if surprised.
2. **Day before: re-run discovery and both `--check` scripts** → `Ready: yes`. Anything not ready is dropped. Freeze
   the DB script as `/root/rotate-db-password.sh` (root 0700) and give the owner its sha256 (references/db-password.md
   §4). Why: the plugin copy is writable by every session, and the script handles the new secret as root.
3. **Backup (T-120, case a)**: `systemctl start --no-block`, poll until inactive (a blocking start outlives a Claude
   tool call), `Result=success`, then `systemctl disable --now <backup>.timer`. Not success: case (b) tonight.
   Rollback: enable it again. Case (b): local `--single-transaction` dump at T-30 (night-script §3); an existing
   enabled timer is disabled at T-45 in case (b) too.
4. **Snapshot (T-60 → T-15, owner)**: complete before T0. It is the rollback for everything below.
4a. **Monitoring quiet (T-45)** (`references/night-script.md` §14): `sudo moodle-health --mute 90`, then
   `sudo systemctl stop moodle-health.timer`, and only then the owner pauses the healthchecks.io check and the
   UptimeRobot monitors. Why this order: a muted moodle-health still sends success pings, and the next ping un-pauses
   a paused check, so the reboot's silence would raise a false DOWN alert at night. No monitoring module: the owner
   pauses whatever external monitors exist. Rollback: the T+12 step.
5. **Banner (T-40)**: `sudo bash scripts/maintenance-mode.sh schedule 30`; verify the banner from outside.
   Rollback: `maintenance-mode.sh disable`.
6. **Pre-checks (T-15)**: `sudo bash scripts/night-checks.sh pre` + both `--check` + backup state + snapshot done.
7. **apt window (T-12)**: drop-in from `assets/apt-daily-upgrade.override.conf.in`; `systemd-analyze verify`;
   `daemon-reload`; `list-timers`. Rollback: `systemctl revert apt-daily-upgrade.timer`.
8. **Maintenance on (T-10)**: `maintenance-mode.sh confirm` (triggers the schedule, falls back to `--enable`).
9. **Redis (T-10 → T-6, owner's terminal)**: `sudo bash scripts/set-redis-password.sh --moodle <MOODLE>` → `REDIS
   PASSWORD SET`. Session verifies without the password (`night-checks.sh`: NOAUTH, Moodle Redis settings ok).
   Rollback: `--rollback /root/redis-auth-<time>`.
10. **DB password (T-6 → T-1, owner's standalone SSH window)**: the owner checks `sha256sum` of the frozen copy, runs
    `sudo bash /root/rotate-db-password.sh --moodle <MOODLE>` → `ROTATION COMPLETE`, exit 0, and reports only the exit
    code and the backup folder. **Do not read his terminal** (it shows the new password once). Other exits: the table
    in references/db-password.md §5. Rollback: `--rollback /root/dbpw-rotation-<time>` (dbpass line only).
11. **Reboot (T0)**: only after the owner reported the DB step and `pgrep -af '[r]otate-db-password'` is empty (exit 3:
    no reboot before the rollback). `sudo systemctl reboot` (owner's go-ahead at that moment). Console if SSH does not
    return. Rollback: snapshot / recovery image (then `maintenance-mode.sh disable`: the snapshot carries the schedule).
12. **Post-checks (T+3 → T+5)**: `night-checks.sh post --rotation-dir /root/dbpw-rotation-<time>`; Moodle CLI DB read
    and Redis settings ok BEFORE `maintenance-mode.sh disable`; login 200; owner logs in; caching page shows Redis
    stores Ready; access denied **with a password** since the folder's time = 0, Moodle DB connections > 0, operator
    `~/.my.cnf` password lines = 0.
13. **Backup timer on (T+10)**: `systemctl enable --now <backup>.timer`; next run listed. Enabled after the timer's
    slot: one manual run that ends before the apt window, or the owner pauses the healthchecks check (else a false
    "down" alert later that night).
13a. **Monitoring back (T+12)**: `sudo systemctl start moodle-health.timer` (it also starts by itself after boot),
    `sudo moodle-health --unmute`, `sudo moodle-health --dry-run` → all OK or known warnings; the owner resumes the
    monitors and sees green. Do this even when the night is aborted.
14. **Log and report (T+15)**: one entry per change, no secrets; customised-files table; handbook; Arabic report.

## 6. Verification checklist
- [ ] Snapshot complete before T0; name and time recorded.
- [ ] Kernel = newest; `reboot-required` gone; nothing maps deleted libraries; failed units no worse than before.
- [ ] Services active as before; listeners as before; DB buffer pool loaded; mail queue normal.
- [ ] Redis: PING without password → NOAUTH; `redis-check.php` → PONG for sessions and every redis store.
- [ ] DB: Moodle CLI DB read ok; no "Access denied ... (using password: YES)" for the Moodle user since the folder's
      time stamp; Moodle DB connections back; operator `~/.my.cnf` has no password line; STATUS = `complete`.
- [ ] The DB script ran from the frozen root copy whose sha256 matched the owner's record; nobody read his terminal.
- [ ] Maintenance off; login page 200 from outside; an admin login and a course page work; cron log clean after 3 min.
- [ ] `apt-daily-upgrade` next run at the new time; backup timer enabled with its next run listed.
- [ ] Monitoring: `moodle-health.timer` active, not muted, `--dry-run` clean; owner resumed healthchecks.io and
      UptimeRobot; no false alert during the night (or explained).
- [ ] Owner told: snapshot and `/root/*` folders with old passwords to delete after ~7 good days; monitors needing
      `REDISCLI_AUTH`; stale password copies to remove.

## 7. Log entry example
```
### 2026-03-13 02:24 — maintenance night: reboot (kernel), Redis password, DB password rotation, apt window  (session: <name>, approved by owner: yes)
- What/why: pending kernel since <date>, nginx on replaced OpenSSL, Redis without password, DB password exposed in <where>.
- Files/settings touched: /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf (<APT_AT> + 15m); /etc/redis/redis.conf
  (marked requirepass block, by the owner's script); config.php (session_redis_auth line; dbpass line, by the owner's
  scripts); moodledata/muc/config.php (<n> redis store passwords); reboot 02:00:12 (from `last -x`); frozen script
  /root/rotate-db-password.sh sha256 <hash>.
- Backup / rollback: snapshot pre-maintenance-2026-03-13 (complete 01:41); /root/redis-auth-<time>/, /root/dbpw-rotation-<time>/
  (old password: delete after ~7 days); both scripts' --rollback; `systemctl revert apt-daily-upgrade.timer`.
- Verified: night-checks post diff (kernel <old> -> <new>, reboot-required gone, deleted-library processes none), Redis NOAUTH
  without password + redis-check PONG x<n>, CLI DB read ok, rotation exit 0 STATUS complete, access denied with a password
  since 01:56:40 (folder time) = 0, Moodle DB connections 3, ~/.my.cnf password lines 0, login 200, backup timer next <HH:MM>;
  moodle-health timer active, unmuted, dry run clean; owner resumed the external checks.
- Next: owner deletes the snapshot and the /root folders after <date>; monitors get REDISCLI_AUTH.
```

## 8. Pitfalls we hit on the first server (generalised)
- **The night's backup slot and the new apt window collided** in the first drafts: plan backup timer, apt window and
  the maintenance window together, and disable the backup timer for the window (`stop` alone returns at boot).
- **`maintenance.php --enablelater` does nothing by itself at the time**: the first request switches the site. With no
  traffic at night it may not switch; and the script exits 0 even when it refuses. Always `confirm` (trigger, else
  `--enable`) and check the flag file.
- **A whole-file config.php restore would undo the other change**: the Redis backup copy of config.php holds the old
  DB password once the DB rotates. Both scripts roll back surgically (only their own line); undo in reverse order.
- **Tools that print option files leak DB passwords** (`mariadb-dump --print-defaults`, `my_print_defaults`); an
  exposed value may also be stale (an old `~/.my.cnf`). Check whether an exposed value is live (hash comparison inside
  the DB, never printing it) before calling it an incident; remove passwords from operator option files.
- **Password-manager pastes add a CR/LF**: a hidden prompt then reads an empty second value and the confirmation word
  gets an empty line. The scripts ignore empty lines; still, the owner runs them in his own terminal, never through a
  session, and `tmux clear-history` after a generated password was shown.
- **Secrets on command lines** (`sed "s/.../$P/"`, `redis-cli -a $P`) in the first runbook draft: the scripts send
  values on stdin only.
- **A transient sudo-expiry timer** vanished on reboot and drifted on every daemon-reload: use a fixed-date
  `OnCalendar` + `Persistent=true` unit pair (references/temporary-sudo.md).
- **Ambiguous date words** ("ليلة الجمعة"): confirm the calendar day in writing; announce a window wider than the real
  downtime.
- **No boot menu** (`GRUB_TIMEOUT=0`, common on cloud images) means the snapshot is the kernel rollback: never reboot
  without a complete one.
- **Monitors raise false alarms during the night** unless they are quieted in the right order: mute, stop the health
  timer, then pause the external checks (a muted script's pings un-pause a paused check).
- **nginx reloads do not load a new OpenSSL**; only a restart or the reboot does.
- **The owner's terminal was readable by Claude sessions.** A terminal tab inside the Claude app or an editor's
  integrated terminal shows the generated password to any session that reads it: the owner uses a standalone SSH
  client window, no screen sharing, and the session never reads it.
- **The script the owner ran as root lay in a folder every session could write.** Freeze a root-owned copy after the
  final review and have the owner compare its sha256 on the night.
- **The slow log was on** (1 s threshold, admin statements logged): a stalled `ALTER USER` would have written the hash
  there. Every SQL batch now starts with `SET SESSION slow_query_log=0`; discovery reports the general log and binlog.
- **After a dropped connection nobody could tell how far the run got.** The STATUS file in the backup folder records
  state words; the night plan has a table per exit code and a path for interrupted runs.
- **A whole-file config.php restore** in the by-hand recipe (and in an older Redis procedure) would undo the other
  change: show change positions first (`diff | grep '^[0-9]'`), set back only the dbpass line.
- **An "update ~/.my.cnf with the new password" option** would have recreated the leak; the scripts only remove it.
- **A Redis procedure ended with `maintenance.php --disable`**: on a combined night that would switch maintenance off
  before the DB step. Skip it; the DB script re-checks maintenance right after `ROTATE`.
- **`journalctl -b` misses the minutes before the reboot** and `(using password: NO)` lines come from tools: count
  `YES` lines since the rotation folder's time stamp.
- **A blocking `systemctl start` of the backup inside a Claude tool call** outlives the 10-minute limit: `--no-block`
  and poll. A backup timer enabled after its slot leaves healthchecks waiting: plan the T+10 step.
- **Estimated times in log entries were wrong**: take times from `date`, `last -x`, `stat`.

## 9. Files in this module
| File | What it is |
|---|---|
| `scripts/discover.sh` | read-only discovery: reboot, libraries, apt schedule/origins, GRUB, provider, Redis/DB/MUC presence (no values), backup, sudo |
| `scripts/lib-env.sh` | parse-only server.env loader for discover.sh (the owner-run scripts read three keys with their own parser) |
| `scripts/maintenance-mode.sh` | `status` (read-only), `schedule N` (banner + --enablelater), `confirm`, `enable`, `disable`, each verified |
| `scripts/night-checks.sh` | read-only pre/post checks, saved and diffed; with `--rotation-dir`: access denied with/without a password since the rotation, Moodle DB connections, `~/.my.cnf` password lines (counts only) |
| `scripts/set-redis-password.sh` | owner-run: Redis requirepass + Moodle sessions + MUC stores together (`--check`, `--rollback`) |
| `scripts/redis-check.php` | read-only: Moodle's Redis settings tested with phpredis as the web user (PONG/NOAUTH), no secret printed |
| `scripts/rotate-db-password.sh` | owner-run from a frozen root copy: MariaDB password rotation for the Moodle user (`--check`, `--rollback` of the dbpass line only, STATUS file, slow log off, re-check after `ROTATE`) |
| `assets/night-plan-template.md` | the night's script (timeline, owners, rollback) to fill per server |
| `assets/announcement-ar.md` | Arabic announcements: short message, in-platform post, teachers, reminder, done, postponed |
| `assets/apt-daily-upgrade.override.conf.in` | systemd drop-in moving unattended-upgrades into the quiet window |
| `assets/temp-sudo-nopasswd.in`, `assets/revoke-temp-sudo.{service,timer}.in` | temporary passwordless sudo with a fixed-date expiry |
| `references/night-script.md` | every step: why, commands, checks, rollback; order of changes |
| `references/unattended-upgrades.md` | move the window, third-party PHP (A1/A2), hold option, restarts after library updates |
| `references/redis-auth.md` | Redis password design, discovery, script, verification, rollback, side effects |
| `references/db-password.md` | DB rotation scope, steps, frozen copy and standalone terminal, exit-code table, rollback and interrupted runs, secrets, backups interplay, remaining risk, adaptations |
| `references/reboot-rollback.md` | why reboot, snapshot, reboot, warm-up, rollback, no-reboot alternative |
| `references/temporary-sudo.md` | the fixed-date temporary sudo pattern |
