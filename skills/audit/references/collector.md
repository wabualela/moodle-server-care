# The read-only collector (`scripts/collect/moodle-audit-collect.sh`)

## Contents
1. What it is and why it exists
2. Before the run: checks Claude does, steps the owner does
3. Running it (flags, timing, cost)
4. What it reads
5. What it writes (layout)
6. Privacy: what is masked, and the review before sharing
7. Adapting to a different server
8. PostgreSQL sites (manual read-only queries)
9. Known limits of the evidence
10. Testing changes to the collector

## 1. What it is and why it exists
One root run that turns 1-60 days of server evidence into aggregates: web access and error logs, PHP-FPM master and
slow logs, DB status deltas, statement digests and the slow log, process memory (PSS), Moodle's own checks, settings,
scheduled tasks and ad hoc queue, the Moodle cron log, mail logs, crontabs, security configuration and network
counters. It masks personal data, writes `PRIVACY_CHECK.txt`, and packs a tarball (at most 50 MB) for analysis.

Why a script rather than ad hoc commands: the logs that matter are root-only, the owner must be able to read exactly
what runs as root before it runs, and raw logs must never leave the server (they hold IPs, e-mails, phone numbers,
session keys). The script is the reviewed, repeatable boundary: everything it prints is aggregated and masked.

It changes nothing: no restart or reload, no `SET GLOBAL`, no writes to the DB, `/etc`, `/var` or `/tmp`. Some
commands that look harmless are deliberately avoided because they write: `php-fpm -tt` appends to the FPM log,
`ufw status` writes `/run/ufw.lock`, `nstat` writes a history file, `logrotate` without `-d` rotates. `nginx -T` can
append warnings to the error log, so it runs after the error logs were read.

## 2. Before the run
Claude (read-only, no root):
1. `bash scripts/collect/selftest.sh` must print `FAIL 0`. It checks this server's bash, GNU sed and gawk against the
   masking corpus (leaks must disappear, harmless text must stay byte-identical). Never run the collector after a
   failing self-test: a mask that silently does nothing would put personal data in the tarball.
2. `bash scripts/collect/moodle-audit-collect.sh --dry-run` prints every step, its timeout, output file and the
   exact files it would read. Check that the site access log, its format (`perf` = with timings), the FPM pool and
   slow log, the Moodle cron log and the DB family were discovered correctly. If not, pass `--site-log`, `--moodle`
   or `--env`.
3. Pick the time with `scripts/quiet-hours.sh`: off-peak, and not within an hour before (or 15 minutes after)
   `logrotate.timer` or `apt-daily-upgrade.timer` (the script warns). A rotation between the two passes over the
   access log spoils per-client detail; an automatic upgrade can restart the DB and break the 60-second status delta.
4. Give the owner the hashes so the files run as root are the reviewed ones:
   `cd <SKILL_DIR>/scripts/collect && sha256sum moodle-audit-collect.sh mask.sed *.awk moodle_info.php | cut -c1-16,65-`
   and confirm `git -C <SKILL_DIR> status --porcelain .` is empty (`<SKILL_DIR>` = this skill's base directory).

Owner: runs the commands in `assets/collector-owner-steps-ar.md` (Arabic). The root run needs the owner's go-ahead
even when Claude has sudo: it reads every log on the box.

## 3. Running it
```bash
sudo bash <SKILL_DIR>/scripts/collect/moodle-audit-collect.sh --days 14            # baseline
sudo bash .../moodle-audit-collect.sh --days 3 --split 2026-01-10                            # after an event
```
| Flag | Meaning |
|---|---|
| `--days N` | history window, 1..60 (default 14). Use 14 for the first audit (two of every weekday), 3 to cover a 48-hour monitor window |
| `--split DATE` | P0 = before DATE, P1 = from DATE on (a launch, a change). Without it P1 is the whole window and the `*_P0` files hold only headers |
| `--env FILE` | server.env from `skills/start/scripts/detect-env.sh` (default: the sudo user's `~/.config/moodle-server-care/server.env`; it is parsed, never sourced, so it is not executed as root) |
| `--moodle DIR` | Moodle root when there is no server.env (only `wwwroot`, `dbtype`, `dbname`, `dataroot` are read from config.php) |
| `--site-log FILE` | the site's access log when discovery picks the wrong one |
| `--focus-date DATE` | package history also covers the day before DATE (an unexplained restart) |
| `--baseline DIR` | an earlier audit's folder of `.md` reports, copied masked, for before/after |
| `--with-tcpdump` | 20 s aggregate of inbound SYN packets (TTL, options, /16 prefixes). No pcap is written; `-p` (no promiscuous mode) |
| `--no-moodle-cli` | skip `checks.php` and `moodle_info.php` (for example while an upgrade is pending) |
| `--load-max N` | load guard (default 3/4 of the CPUs, at least 2), checked at the start and again before the access logs |
| `--force` / `--yes` | ignore the load guard / create the tarball despite privacy residuals (avoid both) |

Cost: 3-8 minutes at nice 19 / ionice idle, one core, peak memory about 40-60 MB per 100k log lines; the DB status
delta waits at least 60 s. Output 5-10 MB; files over 5 MB are capped with a `[TRUNCATED]` marker. One run at a time
(`flock` on `$OUTBASE/.collect.lock`). Output: `~operator/moodle-audit/collect/audit-<host>-<stamp>/` and `.tar.gz`
(0600, owned by the operator).

## 4. What it reads
`--dry-run` prints the exact list for the server. Summary by area:
- **System**: journal (boots, kernel OOM/stall/IO/SYN-flood lines, unit start/stop/fail events, the tail of earlier
  boots that ended in the window, the logs of the web, PHP, DB, Redis, MTA, cron, fail2ban, logrotate and certbot
  units; sshd/sudo/PAM lines are dropped and only counted), failed units and their unit files, apt/dpkg history,
  unattended-upgrades log and timers, `logrotate -d`, sysstat averages, PSS per process group, deleted-library
  mappings (a service still running an old OpenSSL after an upgrade), web server process start times (last reload),
  certbot run times, `du` of the usual big directories.
- **Web**: the site access log (aggregated by `access_agg.awk`), the other vhosts' access logs (combined format), all
  error logs (nginx and Apache formats), `nginx -T` or the enabled Apache config.
- **PHP**: the site pool's FPM master log (sanitised copy plus hourly events: seems busy, max_children, too slow), the
  slow log (stack traces classified by wait: SMTP, session lock, DB, HTTP out, Redis, file IO, CPU), FPM logs of other
  PHP versions on the box, the FPM config files (never `php-fpm -tt`).
- **Moodle** (as the web user, read-only): `admin/cli/checks.php` and `moodle_info.php` (settings that matter for
  speed and safety, cache stores without their configuration, scheduled tasks with schedule, disabled state and
  whether the owning plugin is enabled, the ad hoc queue by class, non-standard plugins and versions, counts of active
  users, the theme's colour and font settings). The script goes in on stdin, so the web user never needs to read the
  operator's home; the DB session is switched to READ ONLY.
- **Database** (MySQL/MariaDB, root unix-socket login only; if that fails every DB step is skipped and no other
  credential is tried): `SHOW GLOBAL STATUS` twice at least 60 s apart (rates use the real gap), variables (two
  secret-bearing ones dropped), performance_schema statement digests in seven orderings (first 1,024 characters of the
  normalised text, literals already replaced), table IO and full scans, InnoDB buffer pool and filtered engine status
  (TRANSACTIONS and deadlock sections removed), processlist aggregate without `INFO`, top 30 tables by size, the slow
  log through `mariadb-dumpslow`/`mysqldumpslow`, and a socket-peer attribution of connections to FPM, cron or CLI.
  Every statement runs with a 60 s session limit.
- **Cron and mail**: crontabs of root, the web user and the operator; the Moodle cron log (task classes, runs,
  seconds, failures; `cronlog_agg.awk`); exim or Postfix queue and per-day delivery, failure and deferral classes; the
  last 20 MB of the web user's local mailbox (subject classes only).
- **Security**: ufw files (ufw is not run), nft ruleset, listeners, effective sshd settings, failed SSH logins per
  day, fail2ban config, certificates and their expiry, modes of secret-bearing files (`.env`, cached Laravel config,
  `.my.cnf`; contents never read).
- **Network**: SYN-RECV per port (3 samples), listen backlogs, TCP counter deltas over 20 s.

It never reads `config.php` beyond the four keys above, `.env` contents, moodledata, `PROCESSLIST.INFO`, or the
InnoDB TRANSACTIONS/deadlock sections.

## 5. What it writes
```
00_meta/      _index.tsv (step, command, exit, seconds, bytes, file, note), run.log (masked), env.txt
10_system/    boots, kernel_events_daily.tsv, unit_events.tsv, failed units, unit_logs/, pss_by_group.tsv,
              apt/dpkg window, deleted_libs.tsv, web_processes.tsv, certbot_runs.tsv, sysstat.txt, du.txt
20_web/site/  per_minute/per_hour/per_day, endpoint_hourly + endpoint_summary_P0/P1, top_paths_P0/P1,
              top_clients (pseudonyms C0001..), top_prefix16, top_ua, ua_classes_daily, ajax_methods, ws_functions,
              slowest_requests, status_detail(_minute) (every 5xx, 414, installaddon), monitor_requests, agg_meta
20_web/other/<log>/   the same aggregates for the other vhosts (no timings)
20_web/errors/        error_types_daily.tsv, error_hourly_counters.tsv, php_messages_top.tsv
20_web/webserver_config.txt
25_moodle/    checks.txt, moodle_info.txt
30_php/       fpm_events_hourly.tsv, fpm_tooslow_top.tsv, fpm_seems_busy.tsv, fpm_log_sanitized.txt.gz,
              slow_*.tsv (daily, hourly, scripts, frames, wait classes, entries joined to their requests,
              session-lock waits by request), fpm_slow.log.gz, php_fpm_conf.txt
40_db/        status_t0/t60/delta, variables, digest_by_{time,rows,rows_sent,count,fulljoin,tmpdisk,noindex},
              digest_all_hashes, digest_meta, table_io, fullscan_tables, bp_stats, innodb_status_filtered,
              processlist_agg, schemas, tables_top, slowlog_*, conn_attribution, conn_peers
50_cron_mail/ crontab_*.txt, cron_tasks.tsv, cron_daily.tsv, mail_queue.txt, mail_daily.tsv,
              mail_fail_reasons.tsv, mailbox_summary.txt, mailbox_stat.txt
60_security/  ufw, nft_masked, listeners, sshd_effective, btmp_daily, fail2ban_cfg, certs, letsencrypt_tail,
              secret_file_modes.tsv
70_network/   synrecv_samples, synrecv_by_port, tcp_counters_t0_t20
PRIVACY_CHECK.txt
```

## 6. Privacy, and the review before sharing
Applied automatically: access logs are never copied (clients become per-run pseudonyms; networks appear as /16 or
/32 with counts; query strings are stripped except allowlisted `info=` and `wsfunction=` names; referers dropped; user
agents masked and cut to 300 characters; paths normalised so IDs, tokens, names and phone numbers in paths become
`N` or `*`). Free text goes through `mask.sed` (or the same rules in `maskfree()`): IPv4 (except the server's own
address, loopback, RFC 1918 and link-local), IPv6, e-mail, Saudi mobile numbers in every common form including
Arabic-Indic digits, any `+`-prefixed international number, secrets in key=value / JSON / INI / CLI / URL forms,
JWTs, long hex strings. PHP messages are scrubbed first (Moodle debug info dropped, quoted literals replaced).
Moodle cron output, mail subjects and task display names are reduced to classes and counts.

`PRIVACY_CHECK.txt` counts what is left per file in five columns (ipv4, email, phone, ipv6, other). With any non-zero
count the tarball is not created unless the operator confirms.

Review checklist (Claude, as the operator, after the run):
1. `PRIVACY_CHECK.txt`: TOTAL must be `0 0 0 0 0`, or every non-zero file understood.
2. `column -t -s$'\t' 00_meta/_index.tsv | less`: exit codes other than 0, `timeout`, `truncated`, `skipped`. A
   `grep` with no match exits 1; that is normal.
3. Read the free-text files by eye (masking is pattern-based; plain-word names cannot be caught):
   `20_web/webserver_config.txt`, `10_system/unit_logs/*`, `10_system/kernel_matches.txt`, `30_php/php_fpm_conf.txt`,
   `zless 30_php/fpm_log_sanitized.txt.gz`, `50_cron_mail/crontab_*.txt`, `25_moodle/*.txt`, `60_security/*`.
4. Extra sweep:
   ```bash
   zgrep -rEno '([0-9]{1,3}\.){3}[0-9]{1,3}' . | grep -vE '127\.0\.0\.1|0\.0\.0\.0|\.0\.0/16|<SERVER_IP>' | head
   zgrep -rEno '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' . | head
   zgrep -rEnoi '(password|passwd|pwd|secret|token)"?[ =:]+[^< ]' . | head
   ```
5. If anything was edited, re-create the tarball (command printed by the script) and keep it 0600.
6. The tarball stays on the server or goes to the analysis session only. Raw logs never leave the server. Delete the
   output when the analysis is done (it holds no personal data, but it is a detailed map of the server).

## 7. Adapting to a different server
| Difference | What the collector does | What Claude does |
|---|---|---|
| Moodle 4.x (no `public/`) | docroot = Moodle root; CLI is `admin/cli` in both layouts | nothing |
| Apache instead of nginx | reads `CustomLog`/`ErrorLog` from enabled sites, aggregates combined format, parses Apache error lines, dumps the enabled config | no timings unless the log format has them: propose `%D` (observability §1). Apache timings are not parsed as `urt` |
| Custom nginx log format | decides perf/combined from the last 300 lines | if `agg_meta.tsv` shows many `lines_bad_timestamp`, stop and adapt `parse_rec()` in `access_agg.awk` or propose the perf format |
| No `rt=/urt=` (combined) | counts, statuses, bytes, clients, user agents; no per-minute or endpoint timings | propose the perf format first (a reload), then collect again after 7-14 days |
| Different PHP version, several FPM pools | site pool found by its socket (server.env `FPM_SOCK`); other versions' FPM logs included | check the dry-run's pool line |
| mod_php (no FPM) | FPM steps produce empty files | rely on access-log timings and the slow query log |
| MySQL instead of MariaDB | `mysql` client, `mysqldumpslow`, `max_execution_time`, `mysql.user` | nothing |
| Root DB login not by unix socket | every DB step skipped ("root socket auth failed") | do not add credentials to the script; use `moodle_info.php` facts, or ask the owner whether a read-only monitoring account is wanted (a change) |
| PostgreSQL | DB steps skipped | §8 |
| Postfix | queue count, `postconf` routing, per-day sent/deferred/bounced from `/var/log/mail.log` or the journal | nothing |
| No Redis | Redis step says so | nothing |
| No systemd timers for logrotate | no timing warning | check `/etc/crontab` for `cron.daily` time |
| Logs rotated with dates (`access.log-20260101.gz`) | handled | nothing |
| Server time zone is UTC, students elsewhere | all times are server local (`env.txt` states the zone); `MSC_TZ=Zone` changes it | report both zones; convert with `quiet-hours.sh --tz` |

When discovery is wrong and no flag fixes it, stop and ask; do not edit the collector on the production server.
Change it in the plugin repository, run the self-test and the harness, review, then pull it onto the server.

## 8. PostgreSQL sites
The collector skips DB steps. With the owner's go-ahead, read-only facts as the `postgres` user (counts and sizes
only, no rows):
```bash
sudo -u postgres psql -XAt -c "select version()"
sudo -u postgres psql -XAt -c "select datname, pg_size_pretty(pg_database_size(datname)), numbackends, xact_commit, blks_hit*100.0/nullif(blks_hit+blks_read,0) from pg_stat_database where datname = '<DBNAME>'"
sudo -u postgres psql -XAt -c "select state, count(*) from pg_stat_activity group by 1"
sudo -u postgres psql -XAt -d '<DBNAME>' -c "select relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid)) from pg_stat_user_tables order by pg_total_relation_size(relid) desc limit 30"
# only if the extension exists (query text is normalised; still read it before sharing):
sudo -u postgres psql -XAt -d '<DBNAME>' -c "select calls, round(total_exec_time::numeric/1000,1) s, left(query,200) from pg_stat_statements order by total_exec_time desc limit 20"
```

## 9. Known limits of the evidence
- nginx `urt` is server (upstream) time; `rt` adds sending the response. Neither is browser time.
- Access-log percentiles are nearest-rank over the requests that have timings; a 404 answered by nginx has no `urt`.
- The FPM "executing too slow (N sec)" number is when FPM noticed, not the request duration.
- "seems busy" with idle > 0 is FPM topping up spare workers, not pressure (`fpm_seems_busy.tsv` says which).
- The digest table can be full (`digest_meta.tsv` `Performance_schema_digest_lost` > 0): newer query shapes are then
  invisible. DB counters start at the last DB restart.
- Connection attribution is often "unmapped" (MariaDB ships the socket instruments off); `conn_peers.tsv` still
  counts connections per class.
- The collector's own requests and the monitor's probes are in the logs (UA `moodle-audit-monitor`); exclude them
  where it matters (front-page rates, PHP time shares).

## 10. Testing changes to the collector
Never test on production data or as root. In a scratch directory: synthetic inputs (documentation IPs 192.0.2.0/24,
198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32; example.* domains; made-up secrets), fake privileged commands first
in `PATH`, then:
```bash
MSC_COLLECT_TEST=1 MSC_COLLECT_TEST_ENV=<file that points the inputs at synthetic data> OUTBASE=<scratch> \
  PATH=<fakebin>:$PATH bash moodle-audit-collect.sh --moodle <stub>
```
Test mode is refused as root. Library mode (`MSC_COLLECT_LIB=1`, then `source` the script) exposes the functions
(`privacy_check`, `cfg_logs`, `detect_fmt`, `log_chain`) for unit tests. A fake command must be called through
`PATH`: a script that calls `/usr/sbin/sendmail` or any binary by absolute path bypasses the mock and reaches the
real service (this happened once on the first server: two test mails reached the live MTA).
