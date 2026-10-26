# Interpreting the data: method, rules of evidence, where each answer is

## Contents
1. The sequence (phases and deliverables)
2. Rules of evidence
3. Which file answers which question
4. Typical findings on Moodle servers (check each)
5. Area notes and the lead synthesis
6. Independent verification of the numbers
7. Using sub-agents

## 1. The sequence
| Phase | What | Output |
|---|---|---|
| 0 | Read-only first look by area: system (CPU, memory, disk, network, history), web server config, PHP-FPM and OPcache, database config and status, Moodle config and plugins, other projects on the box | one short area note each (`assets/area-note-template.md`), a first list of hypotheses H1..Hn ranked by likely impact on students |
| 1 | Close the observability gaps the owner approves (`references/observability.md`) | log entries |
| 2 | Collector run #1: 14 days (baseline) | tarball, privacy review |
| 3 | 48-hour monitor over the busiest days | `metrics.csv`, `ttfb.csv`, events |
| 4 | Collector run #2: `--days 3` covering the monitor window (adds what run #1 showed was missing) | tarball |
| 5 | Area work (traffic, PHP, DB, ops/mail/security, monitor capacity, monitor TTFB, network, cron/events), independent of each other | one note per area with file citations |
| 6 | Lead synthesis: verdict, hypotheses verdicts, ranked causes, operational defects, prioritised fix plan, open questions for the owner | synthesis note in the session's scratch directory |
| 7 | Independent verification of every number that goes into the team report | corrections list |
| 8 | Arabic team report from `assets/report-template.html` | private artifact or file |
| 9 | Fact-check of the report against the operations log before publishing (`references/fact-check.md`) | corrected report |

Ask the owner early (in Arabic) what only they know: when the slowness started and for whom (students on phones,
teachers, admins), what changed then (a launch, a migration, a new theme or plugin), the busiest days and hours, the
students' country and time zone, and who else will read the report. Each hypothesis should be testable with a file.

Small servers or a short engagement: phases 0, 2, 5 (one combined pass), 6, 8, 9 are the minimum. Do not skip the
verification of numbers or the fact-check.

## 2. Rules of evidence
- **Rates, not totals.** Compare per hour or per full day. Divide by the exact window length in hours (check
  `agg_meta.tsv` first_ts/last_ts; a period that starts at midnight but was meant to start at a launch hour inflates
  rates). Compare the same weekdays and hours before and after.
- **Name the sample.** Every number carries what was measured, where, when, and n: "front page, server time (nginx
  urt), median of 4,123 requests, Mon-Wed". Small n (under about 50) makes p95/p99 unstable.
- **Server time is not student time.** `urt` = PHP time on the server; `rt` adds sending the response (large images
  over slow mobile links make `rt` much larger than `urt`); the monitor's TTFB is measured from the server itself.
  None includes the students' network or browser rendering. Say "on the server" in the report, and measure the
  browser side separately (PageSpeed, a probe from the students' country) when that is the claim.
- **Detection time is not duration** (FPM "executing too slow (N sec)"); **"seems busy" with idle > 0 is not
  pressure**; **counters start at the last restart** (DB status, FPM status, `/proc/net`).
- **Load level reached.** "Server time stays flat under load" is shown only up to the busiest hour observed; state
  that level and compare it with the historic peak in 14 days of logs.
- **Exclude yourself.** The monitor's probes (UA `moodle-audit-monitor`) and the collector's own DB statements are in
  the data; subtract them where they matter (front-page rates, PHP time shares, DB rates).
- **Percentiles.** Collector percentiles are nearest-rank over exact histograms. A "median of hourly p95" is not a
  pooled p95: say which.
- **Capacity.** Little's law: mean busy workers = request rate × mean service time (3,600 PHP requests/h × 0.3 s =
  0.3 busy workers on average). Compare with `pm.max_children` and with `fpm_listen_q` (any non-zero minute means
  requests queued).
- **Correlation.** For "does X slow down when load rises": hourly urt p95 against hourly PHP requests (Pearson r and
  Spearman ρ), and peak vs trough hours. A flat line means the cost is in the page, not in capacity.
- **Inference vs fact.** Mark estimates as estimates ("about", "likely") and say what would confirm them. Never round
  a partial result up.
- **Privacy.** Client identifiers are collector pseudonyms; never try to unmask them. Quote no personal data.

## 3. Which file answers which question
| Question | Look at |
|---|---|
| Is the server overloaded? | monitor: `cpu_idle`, `psi_*`, `fpm_listen_q`, `fpm_children` vs max, `my_run_max`, `mem_avail_mb`, swap; collector: `per_hour.tsv` urt p95 vs `php_req`; `30_php/fpm_events_hourly.tsv` (max_children reached) |
| Which pages are slow, and how much time do they cost in total? | `20_web/site/endpoint_summary_P1.tsv`, `top_paths_P1.tsv` (list `by_sum_urt` = share of all PHP time), `slowest_requests.tsv`, `scripts/measure-endpoints.sh` |
| Why is a page slow? | `30_php/slow_wait_class.tsv`, `slow_entries.tsv` (request, wait class, first app frame, SMTP caller), `slow_lockwait_by_request.tsv`; `40_db/digest_by_time.tsv`, `digest_by_rows.tsv`; theme or plugin code named in the frames |
| What changed when the slowness started? | `--split` at that date: P0 vs P1 of `per_day.tsv`, `ua_classes_daily.tsv`, `top_paths_P0/P1`; `10_system/apt_history_window.txt`, `unit_events.tsv`; `25_moodle/moodle_info.txt` plugins and versions |
| Real students, bots or a flood? | `ua_classes_daily.tsv` (mobile vs desktop vs bots), `per_minute.tsv` (front_req, top_client_share), `per_minute_top_client.tsv`, `top_clients_P1.tsv`, `top_prefix16_P1.tsv`, `status_detail.tsv` |
| Errors students see? | `status_detail.tsv` (every 5xx, 414), `per_day.tsv` s5xx, `20_web/errors/*`, `25_moodle/checks.txt` |
| What does the DB spend its time on? | `40_db/digest_by_time.tsv`, `conn_attribution.tsv` / `conn_peers.tsv` (web vs cron), `status_delta.tsv` (qps, lock statements), `slowlog_hourly.tsv`, `50_cron_mail/cron_tasks.tsv` |
| Is cron the load? | `cron_tasks.tsv` (sum and max seconds per task class), `moodle_info.txt` scheduled tasks (every-minute schedules; `disabled=0` with `component_enabled=0` = enabled tasks of disabled plugins), ad hoc queue, monitor `cron_php_procs` |
| Does mail block pages? | slow log wait class SMTP and `smtp_caller`; endpoint groups `POST /login/signup.php`, `GET /enrol/index.php`, `/login/forgot_password.php` (a constant ~2 s mode = synchronous SMTP); `moodle_info.txt` smtphosts; `mail_daily.tsv` |
| Restarts and outages? | `boots.txt`, `unit_events.tsv`, `deleted_libs.tsv` (old OpenSSL still mapped), `apt_history_window.txt`, `unattended_upgrades.txt` (daytime restarts), `per_minute.tsv` 5xx/499 around those times |
| When are the quiet hours? | `scripts/quiet-hours.sh` (14 days, by weekday, server and students' zone) |
| Memory | `pss_by_group.tsv` (real share per service), monitor `mem_avail_mb`, swap, `psi_mem_*` |
| Network and geography | monitor `client_rtt_*` (before any CDN), `rt` vs `urt` for large responses, bytes per page (`top_paths` bytes columns), SYN-RECV and drops (`70_network/*`) |
| Security posture | `listeners.txt` (DB on all interfaces?), `sshd_effective.txt`, `fail2ban_cfg.txt`, `btmp_daily.tsv`, `secret_file_modes.tsv`, `certs.txt`, `moodle_info.txt` (debug, getremoteaddrconf, cookiesecure), `checks.txt` security section |
| Operations hygiene | `failed_units.txt`, `logrotate_debug.txt`, `certbot_runs.tsv`, `mailbox_stat.txt` (cron mail piling up), crontabs without output redirection |

## 4. Typical findings on Moodle servers (check each)
Seen on the first server; each is a question to answer with evidence on the next one, not a conclusion.
- **Synchronous e-mail inside requests**: sign-up, self-enrolment welcome messages and password resets wait for the
  external SMTP server (constant ~1-3 s, rare 15-50 s hangs). Fix path: local MTA as smarthost (mail module).
- **Theme or page-builder blocks that count enrolments per course card on every view** (front page, enrolment
  page), loading full user rows, and builds of cards that are never shown. Fix path: vendor patch or static counts
  (tuning module); confirm with slow-log frames and DB digests.
- **Scheduled tasks**: preview cleanup or enrolment syncs every minute, enabled tasks of disabled plugins taking a
  lock on every cron poll, overlapping cron runners; often most of the DB time with little student impact.
- **Session-lock waits** on pages that do not need a writable session.
- **Scanner floods** on `/` and non-existent `.php` paths reaching PHP; no request limits; no default server, so
  unknown host names reach an application. Fix path: nginx module (dry-run limits first).
- **Distance and page weight**: server far from students, no CDN, duplicated libraries and trackers in page HTML,
  large course images; static Moodle URLs (`/theme/styles.php/...`) not cached at the edge.
- **Operations**: reboot pending for weeks, unattended upgrades restarting services at the morning ramp, logrotate
  failing every night (a duplicate stanza), certbot failing on dead domains (hiding real failures), cron output mailed
  into a growing local mailbox, accounts in a password-reset loop (invalid e-mail with `create_password`), debug modes
  and world-readable secrets in other apps on the box, the DB listening on all interfaces after a package upgrade,
  fail2ban dead since a reboot, `getremoteaddrconf` trusting client headers, no off-provider backup.
- **Ruled out with evidence** belongs in the report too: capacity (CPU, memory, pool never queued), the database
  (no slow student queries), other projects (their load did not move Moodle's times), traffic volume itself.

## 5. Area notes and the lead synthesis
Area note (`assets/area-note-template.md`): headline in two lines; data and method (windows in exact hours,
exclusions, how percentiles were computed); findings, each with the number, the file it came from and n; hypothesis
verdicts (CONFIRMED / PARTIAL / REFUTED / NOT TESTABLE, with the deciding evidence); new issues; limits; "what the
team report should say" (plain sentences the lead can reuse).

Lead synthesis: 1) verdict in plain words; 2) causes ranked by what students feel (impact per visit × how many
visits); 3) hypotheses table; 4) operational defects and risks (not necessarily slowness), each with severity;
5) prioritised fix plan: one line per fix with expected effect, risk, effort, approval needed, reversible?, and the
module that implements it (cloudflare, mail, nginx, tuning, hygiene, backup, maintenance); quick wins first, then
browser-side work, then one maintenance night for everything that needs a restart; 6) what the next measurement must
confirm; 7) questions only the owner or management can answer; 8) reconciliation where area notes disagree.

Keep these working notes in the session's scratch directory (or the audit folder the owner chose); they are inputs
to the team report, not documents to circulate.

## 6. Independent verification of the numbers
Before any number reaches the team report, a second pass (a fresh sub-agent, or Claude with no access to the first
pass's conclusions) recomputes it from the aggregates and tries to refute it. On the first server this changed about
a dozen claims: a load ratio, a count of floods, a mobile share compared on different bases, a byte mean that
included the monitor's probes, units (KiB vs kB), a "plateau" that was only a slowing decline, a causal claim with no
evidence. Keep a "claims dropped or corrected" list in the synthesis; it also helps the owner trust the result.

## 7. Using sub-agents
Run the area work in parallel, each with: the exact files (paths inside the extracted tarball), the questions from §3
for its area, the hypotheses list, the rules of §2, and the instruction to cite a file for every number and to say
"not measurable from these data" rather than guess. Sub-agents work on copies of the aggregates in the session's
scratch directory, never on the server's live files, and never with sudo. Verify anything surprising a sub-agent
reports before repeating it (core rules §9).
