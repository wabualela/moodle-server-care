---
name: tuning
description: Moodle-side performance fixes on a production Moodle server, each measured and reversible. Reviews scheduled tasks (every-minute tasks, cohort/meta sync, question preview cleanup, enabled tasks of disabled plugins that still cost DB locks, cron_keepalive) and reschedules only owner-approved ones with dry-run, backup and verify scripts; measures DB load before/after honestly (Questions/s, page server time); checks static-caching settings and renames theme files with spaces that cause 404s; installs or upgrades plugins safely (no dev folders, quiet-hour maintenance, CLI upgrade with max_input_vars=5000); applies sha256-pinned vendor patches; reference procedures for slow front-page counters, heavy front pages, session locks and H5P, the RemUI cache bug and e-mail login scans. Use it whenever a Moodle site or its database is slow, cron looks heavy, the owner wants to install, update or patch a plugin or theme, or asks to tune or speed up Moodle, even if this module is not named.
---

# Tuning: Moodle-side performance fixes

## 1. Read first
Read `../../shared/core-rules.md` before anything else (change protocol, approval, secrets, testing, placeholders).
Read the server handbook and the tail of the operations log. Load facts from `~/.config/moodle-server-care/server.env`
(run `../start/scripts/detect-env.sh` if it is missing or older than a day). Every script here reads that file and
accepts overrides (`MOODLE=... PHP=... WEBUSER=... bash script.sh`).

## 2. When to use / signs
- The database is busy while the site is quiet; the slow-query log is dominated by one cron task; many cron
  runners overlap (`pgrep -fc admin/cli/cron.php` shows 3 or more).
- Scheduled tasks run every minute that do not need to; tasks of disabled plugins are still enabled.
- The front page is slow even when idle, or very heavy (hundreds of `<script>` tags).
- Static images come back `private, max-age=10`; `/favicon.ico` or a theme file 404s many times a day.
- The owner wants to install or upgrade a plugin, or a vendor (theme/page builder) function is the measured cost.
- Requests wait on the session lock (FPM slow log), the H5P editor "freezes", RemUI course AJAX calls are slow.
Usually run after the `audit` module (it supplies the evidence and the measured quiet hours); can run alone.

## 3. Discovery (read-only)
`<SKILL_DIR>` = this skill's base directory (shown when the skill loads).
```bash
cd <SKILL_DIR>/scripts
. ./lib-env.sh && msc_load_env; echo "$RELEASE $DOCROOT $PHP $WEBUSER $DBTYPE"   # parsed, never sourced
bash run-as-web.sh perf-settings.php                 # caching/debug/session/MUC settings, CHECK marks
bash run-as-web.sh tasks-review.php --plan-out=/tmp/msc-tasks-plan.txt --quiet-hour=<H>   # plan 0644; refuses a symlink
pgrep -fc 'admin/cli/cron.php'; sudo crontab -u "$WEBUSER" -l | grep -v '^#'
bash run-as-web.sh db-load-sample.php --samples=5 --interval=60 --label=baseline
bash run-as-web.sh frontpage-blocks.php              # front-page blocks, shortcodes, stored scripts
bash static-check.sh --origin; bash static-check.sh  # headers from origin and through the CDN
sudo bash ../../audit/scripts/measure-endpoints.sh --from "<from>" --to "<to>"   # page server time per endpoint (perf log)
```
`run-as-web.sh` copies a PHP script to a fresh `/tmp` directory and runs it as `<WEBUSER>` with `<PHP>` and
`--moodle=<MOODLE>` (the web user cannot read the operator's home). All of the above only read.

**When the server differs:**
| Difference | What to do |
|---|---|
| Moodle 4.x (no `public/`) | Nothing: scripts read `DOCROOT`; CLI is always `<MOODLE>/admin/cli/`. Moodle 3.x: review/verify still work; prefer the admin UI for changes |
| PostgreSQL | `db-load-sample.php` reports transactions/s and rows read/s instead of Questions/s; tasks scripts unchanged |
| Apache instead of nginx | `measure-endpoints.sh` (audit module) needs a log ending in `rt=... urt=...`; with Apache add `%D` (microseconds) to a LogFormat in a separate step or skip page-time numbers and say so. Static-file fixes go through the web-server module the owner uses |
| No Redis / file or DB sessions | Session-lock reference still applies; read-only sessions need a handler that supports them |
| Not RemUI/Edwiser | Skip the RemUI items and the version-pinned patches; the methods (pins, measure, copy test) still apply |
| No sudo for the operator | Discovery partly (no logs); the owner applies task changes in the admin UI; no vendor patches or plugin installs |
| `$CFG->scheduled_tasks` or `preventscheduledtaskchanges` in config.php | Task changes belong in config.php: ask the owner |
| Several web/cron nodes | Settings are shared (DB); check cron runners and file changes on every node |
Stop and ask when discovery shows something this module does not describe (for example a custom cron runner).

## 4. What to propose to the owner
Lead with the measured problem, then a table of changes with "what users notice" and the rollback. Templates in
`assets/owner-texts-ar.md` (tasks, plugin install, vendor patch, front-page counters, settings, report, support note).
Short form:

> **الخلاصة:** معظم ضغط قاعدة البيانات من المهام المجدولة. نقترح <N> تعديلات لا يلاحظها المستخدمون، ويمكن التراجع عنها
> كلها بأمر واحد. القياس الحالي: <X> استعلاماً في الثانية (<N> عينات × 60 ثانية الساعة <HH>).
> | التعديل | الحالي | المقترح | ماذا يلاحظ المستخدمون |
> |---|---|---|---|
> | تنظيف معاينات الأسئلة | كل دقيقة | يومياً الساعة <HH:MM> | لا شيء |
> | مزامنة الأفواج والدورات المرتبطة | كل دقيقة | كل 15 دقيقة | لا شيء عادةً (التسجيل من داخل مودل فوري) |
> | <N> مهمة لإضافات معطّلة | مفعّلة | معطّلة | لا شيء |
> هل نوافق على الكل أم على بعضها؟

One change (or one approved batch of the same kind) at a time; never two changes inside one measurement window.

## 5. Procedure
Every step: backup → change → test → apply → verify → log (core-rules §3). Write the rollback before the change.

### 5.1 Scheduled tasks (details: `references/scheduled-tasks.md`)
1. **Backup:** none needed by hand: `tasks-apply.php --execute` refuses to run without `--backup=FILE` and writes
   the old values of every task and setting it will touch before changing anything. Move the file to
   `/root/tuning-<date>/` (mode 700) afterwards, with the approved plan.
2. **Change:** the draft belongs to the web user (it cannot be edited in place in `/tmp`), so write the approved
   copy as a new file: all approved `sed 's/^#? //' /tmp/msc-tasks-plan.txt > /tmp/msc-tasks-approved.txt`, or copy
   and un-comment only the approved lines. `disable` acts only while the plugin is still disabled (else KEEP);
   `disable-anyway` needs the owner's approval for that task by name.
3. **Test:** `bash run-as-web.sh tasks-apply.php --plan=/tmp/msc-tasks-approved.txt` (dry run: current → target;
   refuses the whole plan on any invalid line, a config.php override or an unknown task).
4. **Apply:** take the `before` DB sample, then
   `bash run-as-web.sh tasks-apply.php --plan=/tmp/msc-tasks-approved.txt --execute --backup=/tmp/msc-tasks-backup-$(date +%F-%H%M).json`.
   No maintenance mode, no purge, no reload.
5. **Verify:** `bash run-as-web.sh tasks-verify.php --plan=/tmp/msc-tasks-approved.txt --wait=600` (every line OK; no
   enabled task of a disabled plugin due in both readings; no task newly in fail delay compared with the review);
   `after` DB sample; later the daily task's first run at its new time and a comparable-hour sample.
6. **Rollback:** put the backup where the web user can read it
   (`sudo install -o "$WEBUSER" -m 600 /root/tuning-<date>/<backup>.json /tmp/`), then
   `bash run-as-web.sh tasks-apply.php --restore=/tmp/<backup>.json` (dry run) and again with `--execute`; or per
   task in Site administration → Server → Tasks → Scheduled tasks (Reset to default / untick Disabled), or
   `admin/cli/scheduled_task.php --enable='<class>'`.

### 5.2 Measuring honestly (details: `references/db-load-measurement.md`)
- `db-load-sample.php` before and after, same settings, several samples, median and range; its `log line:` goes into
  the log entry. State what else changed in the window, the DB uptime, and "preliminary" until a comparable-hour
  confirmation. Page changes: `../audit/scripts/measure-endpoints.sh` with window A = a full day before and window B
  = a full day after (`--from2/--to2`), same weekday.

### 5.3 Static caching on the Moodle side (details: `references/static-caching.md`)
1. **Backup:** note the current values from `perf-settings.php` in the log draft (old values are the rollback).
2. **Change:** settings with `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=<n> --set=<v>` (a value
   forced in config.php is changed there, with a file backup). Theme file with spaces: first prove the failing URL
   form in the access log; then `rename-theme-file.php --component=<c> --filearea=<a> --from='<old>' --to=<new>`.
3. **Test:** `rename-theme-file.php` without `--execute` (dry run shows file, setting change, cache reset).
4. **Apply:** quiet hour when the theme revision changes (themedesignermode, purges, renames reset theme caches).
5. **Verify:** `static-check.sh` (origin and CDN), 404 count of that URL per day, setting values.
6. **Rollback:** `cfg.php` with the old value; rename back (same command, `--from`/`--to` swapped).
Web-server parts (X-Accel override for public plugin images, `/favicon.ico` location, gzip types) belong to the
`nginx` module; CDN cache rules to the `cloudflare` module.

### 5.4 Installing or upgrading a plugin (details: `references/plugin-install.md`)
1. **Backup:** the script tars the old plugin directory to `/root/tuning-plugin-<component>-<date>/`; a recent DB
   backup must exist for an upgrade (Moodle cannot downgrade).
2. **Change / 3. Test:** `bash install-plugin.sh check <SRC_DIR>` (dev folders excluded, `php -l`, versions,
   dependencies, nothing else pending, rsync preview with deletions).
4. **Apply:** `bash install-plugin.sh install <SRC_DIR> --window=<HH-HH> --execute` inside the measured quiet hours:
   maintenance on → copy as the code-tree owner → `php -d max_input_vars=5000 admin/cli/upgrade.php --non-interactive`
   → maintenance off.
5. **Verify:** the script checks nothing pending, the new version, login page 200; then check timings once caches are
   warm, new settings and new scheduled tasks (`tasks-review.php`).
6. **Rollback:** new plugin: `admin/cli/uninstall_plugins.php` (irreversible data removal: owner's go-ahead). Upgrade:
   restore files from the tar and the DB from the backup. If the upgrade fails, maintenance stays on and the script
   prints the two choices: decide with the owner.

### 5.5 Vendor patches (details: `references/vendor-patches.md`)
1. **Backup:** `vendorpatch.sh apply` saves the replaced files (and the vendor `version.php`) under
   `/var/backups/moodle-vendor-patches/<UTC>-<name>-apply/`.
2. **Change:** a minimal diff with marker comments in the owner's repository, pinned with `vendorpatch.sh pin`.
3. **Test:** on a copy of the site, output compared for several viewer types; `bash test-vendorpatch.sh` once per
   server; `vendorpatch.sh status <diff>` must say "NOT applied" (pinned originals).
4. **Apply:** `sudo bash vendorpatch.sh apply <diff>` (staged patch, `php -l`, hash check, atomic swap as the file owner).
5. **Verify:** `status` exit 0; page/AJAX timings before vs after; error log clean.
6. **Rollback:** `sudo bash vendorpatch.sh revert <diff>` or `restore <backup dir>`.
The Edwiser RemUI 5.2.2 / page builder 4.2.26 course-card patches and the owner's course-card counts helper plugin
(`<COUNTS_HELPER>`; component name and repository are recorded in the server handbook, not here) are **optional and
version-pinned**: only for servers on exactly those releases (`vendor-patches.md` §6–7).

### 5.6 Reference procedures (each with discovery, options, backup, verify, rollback)
| Problem | Reference | Usual first option |
|---|---|---|
| Front page counts enrolments on every render | `references/frontpage-counters.md` | static numbers or hide the section (content change) |
| Heavy front page (duplicate scripts, trackers, site loader) | `references/frontend-weight.md` | clean stored block HTML, one tag manager |
| Session-lock waits, H5P editor freezes | `references/session-locks.md` | H5P content-hub search off; read-only sessions |
| RemUI course AJAX slow, config cache churn | `references/remui-cache-bug.md` | vendor ticket; pinned patch after a copy test |
| `LOWER(email)` full scan on login | `references/email-lookup.md` | accept and report upstream (no core patches) |

## 6. Verification checklist
- [ ] Before and after measured with the same method, sample counts and window stated; nothing else changed in it.
- [ ] Tasks: every plan line OK in `tasks-verify.php`; no permanently-due enabled task of a disabled plugin; no task
      newly in fail delay (pre-existing failures are reported separately, not fixed by rescheduling); daily task ran
      at its new time (confirmed at the next real run, with the time).
- [ ] Settings: values read back; static headers checked from origin and through the CDN.
- [ ] Plugin: nothing pending, version installed, maintenance window start/end recorded from the script output.
- [ ] Vendor patch: `status` exit 0; marker count as expected; detection of a lost patch in place.
- [ ] All sites on the box still answer (the `hygiene`/`nginx` smoke probes, or `curl -I --resolve`).
- [ ] Backup file paths and rollback commands written in the log entry; owner told what changed and what is next.

## 7. Log entry example
```
### 2026-01-15 02:50 — scheduled tasks rescheduled, <n> tasks of disabled plugins disabled, cron_keepalive 120  (session: <name>, approved by owner: yes — tuning plan item 2)
- What/why: cron made most DB statement time; question_preview_cleanup every minute; cohort/meta sync every minute
  although observers enrol immediately; <n> enabled tasks of disabled plugins locked on every poll; <n> cron runners.
- Files/settings touched: via core\task\manager::configure_scheduled_task (tasks-apply.php, dry run first, plugin
  states re-checked at apply time): question_preview_cleanup_task 37 1 * * *; enrol_cohort_sync and enrol_meta_sync
  */15 * * * *; disabled: <list of classes>; cron_keepalive 180 -> 120. completion_regular_task unchanged.
- Backup / rollback: /root/tuning-2026-01-15/msc-tasks-backup-2026-01-15-0250.json (+ approved plan);
  tasks-apply.php --restore=<file> --execute, or per task "Reset to default" in the admin UI.
- Verified: tasks-verify.php all OK, permanently due 0 (was <n>, two readings 10 min apart); DB Questions/s median
  <A> -> <B> (5 x 60 s each, 02:40-02:45 and 02:52-02:57, DB uptime <d> d; preliminary, confirm at the same hour).
- Next: confirm the daily task's first run tomorrow; comparable-hour DB sample on 2026-01-22 02:45; if a listed plugin is enabled
  again, enable its task.
```

## 8. Pitfalls we hit on the first server
1. **CLI upgrade failed after maintenance was already on**: PHP CLI `max_input_vars` was 1000, Moodle requires 5000.
   Always `-d max_input_vars=5000` (install-plugin.sh does it).
2. **Enabled tasks of disabled plugins** were invisible in day-to-day admin but made most lock traffic. Disable them
   with a re-check of the plugin state at apply time, and record the list (a plugin enabled later needs its task).
3. **"Permanently due" from one reading** includes tasks delayed by busy runners. Read twice, 10 minutes apart.
4. **Measurement confounders**: the DB had been restarted 20 minutes before the baseline for an unrelated fix, and
   only two 60-second samples existed; the report had to say "preliminary". Take the baseline yourself, several
   samples, and list every other change in the window.
5. **The favicon hypothesis needed proof**: the linked URL worked; the 404s were a double-encoded form of a file name
   with a space. Find the failing URL form in the logs before renaming anything.
6. **A CDN claim went stale**: a note said page-builder images bypassed the CDN because of Set-Cookie; a later check
   showed HIT. Verify with headers at the time of writing, and correct the log with a new entry.
7. **A test harness reached production**: a script called a mail binary by absolute path, bypassing the PATH mocks,
   and two test mails hit the live relay. Scripts here call tools by name; test them only with mocks first in PATH
   and a mock Moodle `config.php`, never against the live site.
8. **Estimated times in log entries** had to be corrected later: take times from `date`/script output (`stat -c %z`).
9. **Vendor patches vanish on upgrade**: pins make apply refuse other releases; keep a status check, and keep the
   helper's "expected patches" setting equal to what is really applied, or its check reports a false failure.
10. **A first fix draft would have defeated the cache it fixed** (RemUI stamp written "now + 60"): measure cache hit
    rate on a copy before production.
11. **Page-builder editing**: the classic block "Configure" form mangles large HTML; the page builder regenerates a
    dynamic shortcode element on save if any part of it is left. Use the builder's own editor, remove the whole element.
12. **sudo and redirects**: `sudo cmd > /root/x` fails (the redirect runs as the caller); use `sudo sh -c '... > /root/x'`.
    The web user cannot read the operator's home: run PHP through `run-as-web.sh`.
13. **Moodle 5.1+ layout**: CLI scripts stay in `<MOODLE>/admin/cli/`, web files moved to `public/`; plugin paths
    are under `public/`. Read the layout from `version.php`, never assume.

## 9. Files in this module
| File | Purpose |
|---|---|
| `scripts/run-as-web.sh` | run a PHP script as the web user from a private /tmp copy, adds `--moodle` |
| `scripts/lib-env.sh` | parse-only loader for server.env (overrides win, never sourced), `msc_as`, `msc_root` |
| `scripts/tasks-review.php` | read-only task review; writes a draft plan with every proposal commented `#? ` |
| `scripts/tasks-apply.php` | applies approved plan lines (dry run default, backup required, `--restore`) |
| `scripts/tasks-verify.php` | read-only check of plan lines, permanently-due tasks (`--wait`), fail delays, cron |
| `scripts/db-load-sample.php` | read-only DB load samples (MySQL/MariaDB Questions/s, PostgreSQL xact/s) with a log line |
| `scripts/perf-settings.php` | read-only list of speed-relevant settings with CHECK marks |
| `scripts/static-check.sh` | read-only headers of the front page and its static files (origin or CDN) |
| `scripts/rename-theme-file.php` | list/rename stored setting files with unsafe names (dry run default) |
| `scripts/frontpage-blocks.php` | read-only inventory of front-page blocks, shortcodes and stored scripts |
| `scripts/install-plugin.sh` + `scripts/plugin-info.php` | safe plugin install/upgrade (check, then windowed execute) |
| `scripts/vendorpatch.sh` + `scripts/test-vendorpatch.sh` | pinned vendor patches: status, pin, apply, revert, restore; tests |
| `references/*.md` | scheduled tasks, DB measurement, static caching, plugin install, vendor patches, front-page counters, front-end weight, session locks, RemUI cache bug, e-mail lookup |
| `assets/owner-texts-ar.md` | Arabic proposals, report and support note |
| `assets/tasks-plan.example.txt` | plan format with the first server's proven set |
| `assets/vendor-patch.sha256.example` | pin file format |
