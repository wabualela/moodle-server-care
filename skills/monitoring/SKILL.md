---
name: monitoring
description: Sets up alerting so the owner of a production Moodle server hears within minutes, on his phone and before students complain, when the web server, PHP, the database, mail, cron, the disk or Moodle itself fails - external uptime monitors (UptimeRobot keyword monitor on the login page plus an origin port monitor) and a one-minute on-server health check (moodle-health) reporting to healthchecks.io with Telegram, with 2-of-3 confirmation, a Moodle status-check baseline and safe install order. Use it whenever a Moodle server has no alerting, an outage was discovered through user complaints, the owner asks for uptime/downtime alerts, Telegram or phone notifications, healthchecks.io, UptimeRobot, a heartbeat, "tell me when the site is down", or when planning maintenance or a reboot on a server that already runs moodle-health (mute, pause) - even if the word "monitoring" is not used.
---

# Monitoring: know before the students do

## 1. Read first
Read `../../shared/core-rules.md` (change protocol, secrets, approval, testing). Then this file. Details load on
demand from `references/` (list in §9).

## 2. When to use / signs
- No alerting at all, or only provider e-mails nobody reads. Outages are found by students, teachers or the owner.
- The first server's trigger: after moving behind Cloudflare, fail2ban banned Cloudflare edge addresses and every
  student behind them was locked out; it was discovered only through complaints.
- A move behind Cloudflare, a new MTA, a new server, or an upcoming maintenance night (monitoring should exist before).
- The server already runs `moodle-health` and work is planned (mute + pause: `references/operating.md` §1), an alert
  arrived (§2 there), or Moodle was upgraded (re-baseline, §3 there).

## 3. Discovery (read-only)
```bash
bash ../start/scripts/detect-env.sh     # if ~/.config/moodle-server-care/server.env is missing or older than a day
bash scripts/discover.sh                # existing monitoring, tools, services, logs, MTA, proxy ranges, other vhosts
bash scripts/discover.sh --net          # + DNS lookup of hc-ping.com (nothing is pinged)
bash scripts/install.sh plan            # renders config/units for THIS server into a staging dir, previews the checks
```
Decide per finding (details: `references/checks.md` §3):

| Finding | Action |
|---|---|
| `moodle-health` already installed | read its config and `--status`; upgrade path (`install.md` §4), never a second copy |
| another agent alerts the owner (Netdata, Zabbix, monit...) | do not duplicate: ask whether it reaches his phone and covers the site; propose only the missing layer |
| Apache instead of nginx / Postfix instead of exim / no Redis / PostgreSQL | supported; the installer detects them (`SERVICES`, `ACCESS_LOG`, `MTA`, `REDIS_CHECK`, `DBTYPE`) |
| access log not "combined"-like | the 5xx check would be blind: adapt the log format (nginx module) or leave `ACCESS_LOG` empty |
| behind Cloudflare but no real-IP ranges file | run the `cloudflare` module first (real IP); the fail2ban-vs-edge check needs that file |
| firewall admits only Cloudflare on 443 | skip the UptimeRobot port monitor or allow the monitor's addresses (`external-uptime.md`) |
| SSO redirects the login page | adjust `LOGIN_PATH`/`LOGIN_MARKER` (`checks.md` §3) |
| Moodle/dataroot/logs under `/home` | fine: the unit gets `ProtectHome=read-only` |
| no systemd, python3 < 3.7, no curl | **stop and ask** (cron fallback / OS upgrade / package install = owner approval) |
| `hc-ping.com` does not resolve / no outbound HTTPS | stop: the on-server layer cannot report; fix egress first |

## 4. Proposal to the owner (Arabic template; fill from discovery)
```
**تنبيه فوري عند تعطل المنصة — اقتراح**

الوضع الآن: لا يوجد تنبيه آلي؛ <نعرف بالأعطال من شكاوى الطلاب / مثال حديث>.

ما أقترحه (طبقتان):
| الطبقة | ماذا تفحص | كل كم | التنبيه |
|---|---|---|---|
| خارجية (UptimeRobot، في حسابك) | هل تفتح صفحة الدخول فعلاً للطالب من الإنترنت؟ <+ هل الخادم نفسه يرد خلف Cloudflare؟> | 5 دقائق | تطبيق الجوال + البريد <+ تيليجرام إن أتاحته الخطة> |
| داخلية (على الخادم، تُبلغ healthchecks.io) | <الخدمات: ...>، قاعدة البيانات، PHP، أخطاء 5xx، القرص والذاكرة، المهام المجدولة، طابور البريد، حظر fail2ban لعناوين Cloudflare، شهادة الموقع، فحوص Moodle الداخلية | كل دقيقة | تيليجرام + البريد، وتنبيه أيضاً إذا توقفت النبضات (الخادم متوقف) |

ضمانات ضد الإزعاج: لا تنبيه إلا إذا تكررت المشكلة في فحصين من آخر ثلاثة؛ المشكلات القديمة المعروفة في Moodle تُسجَّل
كخط أساس ولا تنبه إلا إذا تغيرت؛ التحذيرات الصغيرة تظهر في اللوحة دون تنبيه؛ كتم مؤقت أثناء الصيانة.
الفحص للقراءة فقط: لا يغيّر شيئاً في المنصة، وهو خفيف: طلب واحد لصفحة الدخول كل دقيقة، وفحوص Moodle الداخلية كل 15 دقيقة.

المطلوب منك: حسابان مجانيان (healthchecks.io وUptimeRobot)، ربط تيليجرام، وحفظ رابط الفحص على الخادم بأمر لا يُظهره
(أرسل لك الخطوات بالتفصيل). لا ترسل لي الرابط ولا كلمات المرور.
الترتيب: أثبّت الفحص والمؤقت متوقف ← أسجّل خط الأساس وأجرّب دون إرسال ← تحفظ أنت الرابط ← أفعّل بعد موافقتك.
التراجع: إيقاف المؤقت بأمر واحد، وكل الملفات تُنقل إلى أرشيف.
```

## 5. Procedure
Every step: backup → change → test → apply → verify → log, rollback written first. Exact commands:
`references/install.md`. Owner steps (Arabic): `references/owner-steps-ar.md`.

**Golden rule for every test (the first server's false alert):** never run the script in a mode that can send
(normal run, `--test-fail`) unless `MOODLE_HEALTH_URLFILE` points at a path that does not exist and
`MOODLE_HEALTH_STATE`/`MOODLE_HEALTH_CONF` at scratch paths, ideally with `MOODLE_HEALTH_PING_SINK`. Use
`scripts/selftest.sh`. Never read or print `/etc/default/moodle-health.url`.

1. **External monitors (owner, no server change).** Send `owner-steps-ar.md` §4. Monitors: keyword `logintoken` on
   `https://<SITE>/login/index.php` (alert when absent), TCP 443 on `<ORIGIN_IP>` behind Cloudflare, one per other
   site. Verify: all Up within 10 minutes; if the keyword monitor is Down while the site works, check Cloudflare bot
   protection (`external-uptime.md`). Rollback: the owner deletes the monitors.
2. **Plan (read-only).** `bash scripts/install.sh plan`; review the staged config with the owner (services, extra
   sites, thresholds). Why: values come from this server's discovery, never from another server's config.
3. **Install, timer off.** Backup: automatic for existing files (`/root/moodle-health-YYYY-MM-DD/`). Change:
   `sudo bash scripts/install.sh install --yes`. Test: parse check, `systemd-analyze verify`, dry run of the installed
   script. Apply: `daemon-reload` only. Verify: modes 755/644/644, timer `disabled`. Rollback: remove the four files
   (or restore the backup), `daemon-reload`.
4. **Baseline + dry run (state dir only, sends nothing).** `sudo bash scripts/install.sh baseline --yes`. Show the
   owner the refs recorded as known (real, pre-existing Moodle warnings worth fixing later). Require "Dry run clean"
   or each CRITICAL line fixed or accepted. Why before the URL: otherwise the known failing checks alert at the first
   real run. Rollback: `rm /var/lib/moodle-health/moodle-checks.baseline` (re-run later).
5. **healthchecks.io check + URL (owner).** Send `owner-steps-ar.md` §1–§3 (period 1 min, grace >= 3 min, Telegram via
   @HealthchecksBot, e-mail too). Print the command with `bash scripts/install.sh url-command`; the owner runs it in
   his own SSH session. Verify without reading: `sudo stat -c '%U %a %s' /etc/default/moodle-health.url` (root 600)
   and `sudo grep -c '^https://' ...` (1). Rollback: the owner deletes the file.
6. **Enable (owner go-ahead at that moment).** `sudo bash scripts/install.sh enable` (pre-checks) → `enable --yes`.
   Apply: `systemctl enable --now moodle-health.timer`. Verify: `--status` shows `status ok, ping: sent`; the owner
   sees green with "all checks OK". Rollback: `systemctl disable --now moodle-health.timer` + owner pauses the check.
7. **Optional end-to-end test (owner chooses the minute).** `sudo /usr/local/sbin/moodle-health --test-fail`: one
   "TEST" alert, recovery 5 s later. Announce it first; it sends a real message (core-rules §4).
8. **Document.** Log entry (§7), customised-files table (4 files + state dir), handbook: where it lives, how to mute,
   what alerts mean, who owns the two accounts. Add "mute + stop timer / pause check" to any maintenance timeline.

## 6. Verification checklist
- [ ] `bash scripts/selftest.sh <scratch>` passed on this server before installing (no real URL used).
- [ ] UptimeRobot: keyword monitor Up, alert contact = owner's phone app (+ e-mail); port monitor Up (behind Cloudflare).
- [ ] `--self-check`: every check that applies here is `active`; skipped ones explained to the owner.
- [ ] Baseline recorded before the URL file existed; dry run clean (or accepted lines listed in the log entry).
- [ ] URL file root 600, one https line, content never displayed; not in any log, transcript or repo.
- [ ] Timer enabled; `systemctl list-timers moodle-health.timer` shows the next run; `last.json` status ok, ping sent.
- [ ] healthchecks.io: period 1 min, grace >= 3 min, Telegram AND e-mail attached, check green.
- [ ] Owner knows: how alerts look, the matrix (owner-steps §6), mute/pause before reboots (owner-steps §5).
- [ ] Log entry + customised-files table + handbook updated.

## 7. Log entry example
```
### 2026-03-27 10:42 — moodle-health monitoring installed and enabled  (session: <name>, approved by owner: yes)
- What/why: no alerting; outages were found by students. One-minute read-only check → healthchecks.io → Telegram
  (owner's account), plus owner's UptimeRobot keyword + port monitors. Alerts after 2 of 3 runs; missing pings alert.
- Files/settings touched: new /usr/local/sbin/moodle-health, /etc/default/moodle-health (no secrets),
  /etc/systemd/system/moodle-health.{service,timer}; state /var/lib/moodle-health; URL file
  /etc/default/moodle-health.url written by the owner (root 600, not read). Baseline: <refs> (pre-existing).
- Backup / rollback: new files only; `systemctl disable --now moodle-health.timer` (owner pauses the check);
  `install.sh uninstall --yes` archives everything to /root/moodle-health-removed-<date>/.
- Verified: selftest passed in a scratch harness; dry run clean; first runs 10:41 and 10:42 status ok, ping sent;
  owner confirmed the green check and the UptimeRobot monitors Up.
- Next: optional --test-fail at a time the owner picks; monthly look (operating.md §5).
```

## 8. Pitfalls we hit on the first server (generalised)
- **Outage found by students.** fail2ban banned Cloudflare edge addresses after the move behind Cloudflare; no
  monitor existed. Now: external keyword monitor + an inside check that alerts on any ban inside the proxy ranges.
- **False alert from a test.** The owner had saved the URL three minutes earlier; a session then ran the not-yet-
  installed script with a deliberately failing config to test confirmation, assuming no URL file existed. Two
  `/fail` pings → a Telegram DOWN alert → a manual "false alarm" ping. Fix: URLFILE/STATE/CONF overrides, a ping sink,
  a built-in refusal to send with test settings and the real URL path, and a harness that aborts if the URL path
  exists. Check for live alert credentials before ANY non-dry test.
- **Install order.** Known failing Moodle status checks (environment, router) would have alerted on the first real
  run. Baseline (with message hashes) and dry run come before the owner writes the URL; the installer enforces it.
- **Silent on a full disk** (found by an independent review before install): a state file that cannot be written
  meant nothing could ever be "confirmed". Atomic writes; if state cannot be saved, alert at once and say why.
- **One bad sample is not an outage.** 2 of the last 3 runs; warnings ride in the body without alerting.
- **Hung probes.** A 40 s internal budget inside a 55 s unit timeout, essentials first; skipped checks are reported
  as a warning, never as failures.
- **healthchecks alerts only on a change**: a second problem while already failing was silent. Re-arm (success then
  failure) when a new key is confirmed.
- **Frozen bounces from a mail test looked like a mail outage.** Frozen/old bounces and held mail are warnings; only
  real mail stuck longer than 15 min (10+ messages) is critical.
- **Mute is not a pause.** Probes keep running while muted (the DB ping can restart a socket-activated MariaDB if only
  the service was stopped), and missing pings during a reboot alert regardless. Stop the timer, then the owner pauses
  the check (a paused check resumes on the next ping) and the UptimeRobot monitors. The first server's maintenance
  timeline had "mute + pause" without stopping the timer; corrected here.
- **Moodle CLI as root** would leave root-owned cache files in the dataroot: checks.php runs as the web user (setpriv).
- **Estimated times in log entries were wrong elsewhere on the first server**: take times from `date`/`stat`.

## 9. Files in this module
| File | What it is |
|---|---|
| `scripts/moodle-health` | the check (python3, stdlib only): `--dry-run`, `--self-check`, `--status`, `--baseline`, `--mute N`/`--unmute`, `--test-fail`; installed as `/usr/local/sbin/moodle-health` |
| `scripts/install.sh` | staged installer: `plan`, `install`, `baseline`, `url-command`, `enable`, `status`, `uninstall` (change steps need `--yes`) |
| `scripts/discover.sh` | read-only discovery for this module (`--net` adds a DNS lookup) |
| `scripts/lib.sh` | shared read-only detection helpers (sourced) |
| `scripts/selftest.sh` | harness with mocks for the script, installer and discovery; sends nothing, never reads the real URL |
| `assets/moodle-health.default` | settings template with placeholders and comments (no secrets) |
| `assets/moodle-health.service`, `assets/moodle-health.timer` | systemd units (oneshot every minute, sandboxed, 55 s timeout) |
| `references/checks.md` | every check, the decision logic, adapting to other servers, state files, tuning |
| `references/install.md` | exact install/upgrade/removal steps and the URL-file testing rule |
| `references/external-uptime.md` | UptimeRobot design, Cloudflare notes, diagnosis matrix |
| `references/operating.md` | planned work and reboots, alert runbook, re-baseline after upgrades, monthly look |
| `references/owner-steps-ar.md` | owner steps in Arabic: accounts, Telegram, URL command, monitors, pausing, alert meanings |
