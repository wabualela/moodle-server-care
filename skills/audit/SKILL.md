---
name: audit
description: Read-only performance and security audit of a production Moodle server, ending in an Arabic team report. Discovers what evidence exists, measures quiet hours from 14 days of access logs, runs a reviewed root collector that turns logs, DB statistics, cron, mail and security facts into masked aggregates, installs a self-expiring unprivileged 48-hour monitor, analyses the results with rules of evidence, fact-checks the report against the operations log, and publishes it privately. Use it first on any Moodle server not yet examined, and whenever the owner says the platform is slow or heavy, students complain, traffic jumped after a launch, a server upgrade is being considered, someone asks "why is Moodle slow", "is the server overloaded", "when is the quiet time for maintenance", "measure before and after a fix", or wants a team report on the server's health, even if they do not say "audit".
---

# Moodle server audit (read-only), monitor and team report

## 1. Read `../../shared/core-rules.md` first
Everything here follows it: Arabic with the owner, analyse → propose → approval → one step at a time, the change
protocol, secrets, evidence. This module is read-only except three small, reversible, approved changes: optional
observability settings (§5 step 3), the monitor's lines in the operator's crontab (step 5), and publishing the report.

## 2. When to use it
- A Moodle server this plugin has not audited yet (the `start` module recommends it first).
- "The platform is slow / heavy", complaints after a launch or a migration, before buying a bigger server, before or
  after a fix (measure both sides the same way), or a request for a health/security report for the team.
- To find the quiet hours before any risky change (`scripts/quiet-hours.sh` alone is fine for that).

Signs worth an audit: pages that "sometimes" hang, sign-up or enrolment slower than other pages, PHP-FPM
`max_children` warnings, 502/504 bursts, nightly failing units, a reboot pending for weeks, nobody knows the busy
hours, or no one can say whether the server or the page is slow.

## 3. Discovery (read-only)
`<SKILL_DIR>` below is this skill's base directory (shown when the skill loads).
```bash
cd <SKILL_DIR>
bash ../start/scripts/detect-env.sh            # if ~/.config/moodle-server-care/server.env is missing or > 1 day old
bash scripts/discover-audit.sh                 # readiness: log format and retention, FPM/DB slow logs, status pages,
                                               # sysstat, cron log, monitor prerequisites; OK / GAP / WARN / INFO lines
bash scripts/collect/selftest.sh               # masking and parsers on this server's sed/gawk: must end FAIL 0
bash scripts/collect/moodle-audit-collect.sh --dry-run   # the root plan: which logs, formats, steps (reads nothing)
sudo bash scripts/quiet-hours.sh --days 14 --tz <STUDENTS_TZ>   # read-only; logs are root/adm only
```
Plus a short first look by area, all read-only, to write the first hypotheses (`references/interpreting-the-data.md`
§1): `uptime; nproc; free -m; df -h; vmstat 1 5`, `systemctl --failed`, `journalctl -p warning -n 200 --no-pager`,
the site vhost and `nginx -T | less` (or `apache2ctl -S`), the FPM pool file, `ls /etc/php/*/fpm/conf.d`, the DB
config files under `/etc/mysql`, Moodle's `version.php`, Site administration → Notifications and → Reports → System
status (or `admin/cli/checks.php` as the web user), the list of other vhosts and Docker containers.

Ask the owner (Arabic) what only they know: since when and for whom it is slow, what changed then, busiest days and
hours, students' country and time zone, who reads the report. Then decide what applies:

| Server differs | Then |
|---|---|
| Access log without `rt=/urt=` | propose the perf log format first (observability §1); without it, timings are missing |
| Fewer than 14 days of logs | collect what exists; say so; re-collect later for weekly patterns |
| Apache, PostgreSQL, Postfix, no Redis, Moodle 4.x, other PHP | supported with limits: `references/collector.md` §7, `references/monitor.md` §6 |
| Operator cannot read config.php / no user crontab | monitor runs without DB columns / ask before any alternative |
| No sudo for Claude | the owner runs the root collector (`assets/collector-owner-steps-ar.md`) |
| A previous audit exists | compare with it (`--baseline DIR`, same windows and weekdays) |
| Logs or DB hold no Moodle (wrong site picked) | stop; rerun detect-env with the right directory |

## 4. What to propose to the owner (Arabic)
```
**خطة فحص المنصة (قراءة فقط)**

**الهدف:** معرفة سبب <البطء / المخاطر> بالدليل، وما الذي ليس سبباً، ثم خطة إصلاح مرتبة.

| الخطوة | ماذا | تغيير على الخادم؟ | المدة |
|---|---|---|---|
| 1 | فحص أولي للإعدادات والسجلات | لا | ساعة |
| 2 | (اختياري) تفعيل قياسات ناقصة: <زمن كل طلب في السجل / صفحة حالة PHP / سجل الطلبات البطيئة / sysstat> | نعم، صغير وقابل للرجوع، بإعادة تحميل فقط | 30 دقيقة |
| 3 | سكربت جمع للقراءة فقط لآخر 14 يوماً، تشغّله أنت بعد مراجعة الملفات | لا | 5–8 دقائق |
| 4 | مراقبة خفيفة 48 ساعة تتوقف وحدها، من حسابي دون صلاحيات root | سطور في جدول مهام حسابي فقط | يومان |
| 5 | جمع ثانٍ يغطي فترة المراقبة، ثم تحليل مستقل وتدقيق للأرقام | لا | يوم |
| 6 | تقرير بالعربية للفريق (خاص، تشاركه أنت)، بعد مراجعته مقابل سجل العمليات | لا | — |

**الخصوصية:** لا تخرج السجلات من الخادم، وتُخفى عناوين IP والبريد والجوالات وكلمات المرور قبل أي تحليل.
**الموعد المقترح للجمع:** <الساعة الهادئة> (من سجلات 14 يوماً).
**أحتاج منك:** موافقتك على البنود <2 و4>، وتشغيل السكربت في الخطوة 3، و<أوقات الذروة / بلد الطلاب / ما الذي تغيّر>.
هل أبدأ بالخطوة 1؟
```

## 5. Procedure
Each step says what changes. "No change" steps still get evidence; change steps follow core rules §3.

**Step 1. Readiness and first look (no change).** Run §3. Write the first hypotheses (H1..Hn) and the area notes
(`assets/area-note-template.md`) in the session's scratch directory. Verify: server.env current, self-test FAIL 0,
the dry-run found the right access log, format, FPM pool, cron log and DB family.

**Step 2. Quiet hours (no change).** `quiet-hours.sh --days 14` in the server's zone and in the students' zone,
optionally `--php-only` and `--humans`. Record the quiet window and the morning ramp in the handbook; every later
risky step and the collector run go there.

**Step 3. Observability gaps (CHANGE, optional, owner approval per item).** From the `GAP` lines, propose the cheap
ones (`references/observability.md`): perf log format, FPM status page and nginx stub_status on loopback, FPM slow
log, sysstat, DB slow log. One at a time, in the quiet window:
- Backup: the resolved file, `F=$(readlink -f <file>); sudo cp -a "$F" "$F.bak-$(date +%F)"`: a vhost in
  `sites-enabled/` is usually a symlink, and `cp -a` of the link gives a second link (nginx loads it as a duplicate
  site, the "backup" changes with the file, and restoring it does nothing). When the real file sits in a directory
  read by glob (nginx `sites-enabled/*`, `/etc/logrotate.d/`), put the copy in `/root/<topic>-YYYY-MM-DD/` instead.
- Change: the exact lines in the reference, idempotent.
- Test: `nginx -t`, `php-fpm<PHPV> -t`, `logrotate -d`.
- Apply: `systemctl reload` (never restart PHP-FPM or nginx in the day).
- Verify: the new log lines / status endpoints answer locally and NOT publicly; site status codes unchanged.
- Rollback: restore the backup, test, reload. Log each item. Then wait 7-14 days before the collector if the timings
  were missing (the baseline needs them).

**Step 4. Collector run #1, 14 days (no change; the owner runs it as root).**
- Before: self-test, dry-run, hashes and `git status` clean (`references/collector.md` §2); fill and send
  `assets/collector-owner-steps-ar.md`.
- Run in the quiet window: `sudo bash .../moodle-audit-collect.sh --days 14` (add `--split <date>` when a launch or
  change date is known).
- Verify: `PRIVACY_CHECK.txt` TOTAL `0 0 0 0 0`; `_index.tsv` without unexpected exit codes, timeouts or skips; the
  review checklist of `references/collector.md` §6. `agg_meta.tsv`: `lines_bad_timestamp` near 0.
- Rollback: nothing on the server changed; delete the output folder if the run was wrong and run again.

**Step 5. 48-hour monitor (CHANGE: the operator's crontab only).**
- Prepare and test (no change): `bash scripts/monitor/setup.sh --hours 48 --test` → one metrics row with 96 fields,
  four TTFB rows, empty `monitor.err`. Choose 48 h that include the busiest days.
- Backup: `crontab -l > ~/moodle-audit/crontab.bak-YYYY-MM-DD` (or note "no crontab").
- Apply after approval: `setup.sh --hours 48 --install-cron` (it refuses if `crontab -l` fails or a monitor exists).
- Verify after 10 minutes: `<dir>/run.sh status` shows rows growing, TTFB cycles, no errors; `crontab -l` shows three
  `# MSC-MONITOR` lines with absolute paths.
- Rollback: `<dir>/run.sh stop` (removes only its lines); it also stops itself at the end, and the watchdog line
  removes everything one hour later. Log the install and, later, the self-stop.

**Step 6. Collector run #2 (no change).** After the monitor ends: `--days 3` so it covers the monitor window. Add
anything run #1 showed was missing (for example `--focus-date` for an unexplained restart).

**Step 7. Analysis (no change).** `references/interpreting-the-data.md`: area work in parallel (sub-agents on copies
of the aggregates in the scratch directory), lead synthesis (verdict, ranked causes, ruled out, defects, fix plan
mapped to modules, owner questions), then an independent re-computation of every number that goes into the report.
Spot checks of single endpoints before/after: `scripts/measure-endpoints.sh`.

**Step 8. Team report (no change to the server).** Fill `assets/report-template.html` (`references/team-page.md`):
the platform's colours from `25_moodle/moodle_info.txt` § theme_identity, chart data from the aggregates, every
`{{…}}` replaced, `DATA.example = false`. Fact-check it against the operations log with a separate checker
(`references/fact-check.md`, `assets/factcheck-template.md`); apply corrections; add a correction entry to the log if
log entries were wrong. Owner approves the text. Publish as a private Artifact (load `artifact-design` first) or
give the file; record the URL in the handbook, never in the plugin.

**Step 9. Hand-off.** Present the fix plan in Arabic: each fix with effect, risk, approval, and the module that does
it (`cloudflare`, `mail`, `nginx`, `tuning`, `hygiene`, `backup`, `maintenance`). Update the handbook (quiet hours,
audit date, report URL, plan) and keep the audit working notes on the server, not in the plugin. Later: after the
fixes, repeat steps 5-8 with the same windows for the "after" measurement and update the same report.

## 6. Verification checklist
- [ ] server.env current; `selftest.sh` FAIL 0; dry-run discovery correct (log, format, pool, cron log, DB)
- [ ] quiet window measured from 14 days (server and students' zone) and written in the handbook
- [ ] every observability change: backup, test, reload, local-only check, log entry
- [ ] collector: PRIVACY_CHECK all zero, free text read by eye, tarball 0600, raw logs never left the server
- [ ] monitor: installed only after approval; three marked lines; self-stopped (event "stopped END_EPOCH reached");
      `crontab -l` has no marked line afterwards
- [ ] every number in the report has a file, a period and n; "on the server" vs "in the browser" said
- [ ] dry runs and pending confirmations not reported as done; times from the log/ctime, not estimates
- [ ] independent number check and fact-check done; corrections applied; owner approved the text
- [ ] report published privately; URL in the handbook; no personal data, IP, secret or unwanted name in it

## 7. Log entry examples
```
### 2026-01-12 03:20 — monitor installed in the operator's crontab (48 h)  (session: audit, approved by owner: yes)
- What/why: 48-hour unprivileged monitor over the weekend peak (audit step 5).
- Files/settings touched: operator crontab (+3 lines '# MSC-MONITOR', no MAILTO line); data ~/moodle-audit/monitor/20260112-032001/.
- Backup / rollback: ~/moodle-audit/crontab.bak-2026-01-12; `<dir>/run.sh stop`; self-expires 2026-01-14 03:20, watchdog removes the lines 1 h later.
- Verified: run.sh status 10 rows, 2 TTFB cycles, monitor.err empty.
- Next: self-stop check on 2026-01-14 04:30; collector run #2 --days 3 after 05:00.

### 2026-01-15 04:05 — FPM slow log enabled (5 s)  (session: audit, approved by owner: yes)
- What/why: stack traces of requests over 5 s (observability §3).
- Files/settings touched: /etc/php/<PHPV>/fpm/pool.d/<pool>.conf (slowlog, request_slowlog_timeout, trace depth); new /etc/logrotate.d/php<PHPV>-fpm-slow.
- Backup / rollback: <pool>.conf.bak-2026-01-15; restore, php-fpm<PHPV> -t, systemctl reload php<PHPV>-fpm; remove the logrotate file.
- Verified: php-fpm -t OK, reload 04:05:12 (stat -c %z), no 5xx in the reload minute, logrotate -d clean.
- Next: read the slow log at collector run #1.
```
Read-only steps (discovery, collector runs, analysis) need no entry unless they found something important; record
the audit itself once (dates, report URL) in the handbook history.

## 8. Pitfalls we hit on the first server (generalised)
- **"Read-only" commands that write.** `php-fpm -tt` appends its dump to the FPM log, `ufw status` writes a lock
  file, `nstat` writes a history file, `nginx -T` logs its own warnings into the error log. The collector reads the
  config files instead and runs `nginx -T` after the error logs. Keep it that way when extending it.
- **Bad timing spoils a run.** A log rotation between the two passes over the access log shifts file names; an
  automatic upgrade restarted the DB during the status delta window. Check the timers and the quiet window first.
- **One-minute samples miss bursts.** The pool filled within seconds, more than once, and the monitor saw nothing; FPM's
  cumulative status counters would have. Propose the status page when floods are suspected.
- **Misread log fields.** FPM's "executing too slow (N sec)" is when it noticed, not the duration; "seems busy" with
  idle workers is FPM topping up spares; `urt` is server time only.
- **Measuring yourself.** The monitor's own front-page probes sat inside the front-page statistics, and a collector
  run inside the monitor window showed up as CPU; exclude them by user agent and by minute.
- **Wrong denominators.** Rates divided by the wrong number of hours came out a few per cent high; shares compared on different
  bases (all requests vs browser requests) looked like a change. Normalise and compare like with like.
- **Load level.** The monitor ran well below the launch peak. "Flat under load" was true only up to what
  was observed; say the level.
- **Hidden DB evidence.** The statement digest table was full (new query shapes invisible), and connection
  attribution came back "unmapped" because the socket instruments are off by default. Check `digest_meta.tsv` and
  `conn_peers.tsv` before trusting the DB picture.
- **Guest probes create sessions.** With `autologinguests` on, probes without a cookie jar would have created
  thousands of guest sessions; the monitor keeps one jar and deletes it when it stops.
- **Behind a CDN** the client RTT the server sees is to the CDN edge, and public probes go through the edge; probe the
  origin (`--resolve host:443:127.0.0.1`) for server time and measure the students' side separately.
- **Run #2 must be planned from run #1.** The first run lacked time by status code and split mail endpoints by
  method; the second added them. Write down what run #1 could not answer.
- **Reports drift from reality.** The fact-check found estimated times, a note that later events had made wrong,
  failed-unit states from runs before the fix, and a stale-credential claim. Fact-check every time.
- **Tools that echo secrets.** `mariadb-dump --print-defaults`, `my_print_defaults` and similar tools print the
  passwords stored in client config files straight into the transcript. Never run them, not even "to check a
  config"; the collector logs in to the DB only through root's unix socket and never reads credential files. If a
  secret does reach a transcript, treat it as exposed and plan a rotation (`maintenance` module).
- **Mocks must sit on PATH.** A test harness called `/usr/sbin/sendmail` by absolute path and two test mails reached
  the live MTA. Call commands through `PATH`, mock them there, and switch off auto-detected live services (a local
  Redis, the DB) in harnesses.

## 9. Files in this module
| File | Purpose |
|---|---|
| `scripts/discover-audit.sh` | read-only readiness check (evidence available, gaps, monitor/collector prerequisites) |
| `scripts/lib-env.sh` | parse-only server.env loader shared by the audit scripts (the file is never sourced) |
| `scripts/quiet-hours.sh` | average requests per hour per weekday from 14 days of logs; quietest window; server or students' zone |
| `scripts/measure-endpoints.sh` | urt/rt percentiles of chosen endpoints for one window or before/after windows; the plugin's one latency tool (mail and tuning call it too); `--prefix` for a sub-path site |
| `scripts/collect/moodle-audit-collect.sh` | the root, read-only collector (dry-run, test and library modes) |
| `scripts/collect/*.awk`, `mask.sed` | aggregators (access, error, FPM, slow log, cron, MySQL slow log, network) and masking |
| `scripts/collect/moodle_info.php` | Moodle facts as the web user via stdin (settings, tasks, ad hoc queue, plugins, theme colours) |
| `scripts/collect/selftest.sh` | masking and parser self-test on synthetic data; run before any root run |
| `scripts/monitor/setup.sh`, `run.sh`, `dbstat.php` | the self-expiring unprivileged monitor |
| `references/collector.md` | running, reading, privacy review, adapting the collector; PostgreSQL queries |
| `references/monitor.md` | monitor install, columns, safety design, adaptation, reading pitfalls |
| `references/observability.md` | the optional evidence improvements as changes (perf log, status pages, slow logs, sysstat) |
| `references/interpreting-the-data.md` | phases, rules of evidence, question → file map, typical Moodle findings, verification |
| `references/team-page.md` | structure, filling, theme colours, Arabic writing rules and publishing of the team report |
| `references/fact-check.md` | the independent fact-check before publishing |
| `assets/report-template.html` | Arabic team report template (light/dark, brand variables, three charts) |
| `assets/collector-owner-steps-ar.md` | Arabic steps for the owner to verify and run the collector |
| `assets/area-note-template.md`, `assets/factcheck-template.md` | working-note and fact-check skeletons |
| `assets/nginx-perf-logformat.conf` | the `perf` log format (combined + rt/urt) |
