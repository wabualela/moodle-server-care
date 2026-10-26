# The 48-hour unprivileged monitor (`scripts/monitor/`)

## Contents
1. Why a monitor, and why this one
2. Prepare, test, install (commands)
3. Status, stop, extend, clean up
4. What it records (metrics.csv, ttfb.csv, events, snapshots)
5. Safety design (self-expiry, watchdog, locks)
6. Adapting to a different server
7. Reading the data (pitfalls)

## 1. Why a monitor, and why this one
The collector shows what the logs remember; the monitor shows what the box does minute by minute at the real peaks,
which the owner usually cannot describe precisely. On the first server it settled the central question ("is the
server overloaded?") with evidence: low CPU at the busiest hour, no PHP request queued, front-page time flat across
the day and night. So the slowness was in the page, not in capacity, and a server upgrade was not needed.

Design constraints: no root, no package, no service change, nothing in `/etc`; a user crontab; stops itself; tiny
overhead (about 0.1 s CPU per minute, one short DB connection per minute, four GETs every 5 minutes); no personal
data or IP addresses in its files.

Choose the window so it contains the busiest days of the week (ask the owner, then confirm with
`scripts/quiet-hours.sh`): 48 hours that include the first working day and an evening peak is the minimum.

## 2. Prepare, test, install
Run as the operator, never with sudo.
```bash
bash <SKILL_DIR>/scripts/monitor/setup.sh --hours 48 --test      # prepares + one sample, no crontab change
```
`setup.sh` reads server.env and finds: the site URL, the PHP binary and version, the FPM socket and
`pm.max_children` (threshold at 80 %), a second PHP-FPM version if other apps run on the box, the root disk, web/DB
unit names, a local Redis on port 6379, whether DB sampling is possible (MySQL/MariaDB and `config.php` readable by
the operator) and a readable Moodle cron log. It creates `~/moodle-audit/monitor/<YYYYmmdd-HHMMSS>/` (mode 700)
with `run.sh`, `dbstat.php`, `monitor.env` (plain KEY=value, parsed, never sourced) and `END_EPOCH`.

TTFB probes go to the origin by default (`curl --resolve <host>:443:127.0.0.1`): that measures server time without
a CDN in the way. If the origin certificate is not publicly trusted (for example a Cloudflare origin certificate) or
nginx does not listen on loopback, setup falls back to public DNS and says so; with Cloudflare in front, public
probes include the edge near the server, not the students' network.

`--test` runs one metrics sample and one TTFB cycle and prints `run.sh status`; `monitor.err` should be empty. The
first metrics row has empty delta columns (no previous sample).

Install only after the owner approved (it is a change to the operator's crontab; log it):
```bash
bash .../setup.sh --hours 48 --install-cron
```
It appends three lines marked `# MSC-MONITOR` (no `MAILTO` line: it would outlive the monitor and silence later
jobs; each line redirects its own output): metrics every minute (`flock -n` + `timeout -k 5 55`
+ `nice -n 10` + `ionice -c3`), TTFB every 5 minutes, and a watchdog at minute 7 of each hour that removes every
marked line one hour after the end even if the data directory is gone. It refuses when `crontab -l` fails for any
reason other than "no crontab", and when a monitor is already installed.

## 3. Status, stop, extend, clean up
```bash
D=~/moodle-audit/monitor/<stamp>
"$D/run.sh" status          # time left, rows, last TTFB cycle, last events
tail -f "$D/events.log"
"$D/run.sh" stop            # removes only the marked lines; deletes the cookie jar
```
Extend: the watchdog has the old end time built in, so stop, write a new `END_EPOCH` (at most 8 days ahead), and
install again.

After the analysis, the data holds no personal data, but delete it only when no marked line is left:
`crontab -l | grep -q '# MSC-MONITOR' && echo "still installed" || rm -rf -- "$D"` (the owner may prefer to keep it
with the audit).

## 4. What it records
`metrics.csv`, one row per minute, 96 columns. Suffixes: `_s` per second, `_pm` per minute, `_d` raw delta over the
interval, `_pct` and `cpu_*`/`psi_*` percent. Delta columns are empty on the first row, after a reboot, after a gap of
more than 600 s, or when a counter went backwards (service restart).

| Columns | Source and meaning |
|---|---|
| load1/5/15, procs_running/blocked | `/proc/loadavg`, `/proc/stat` |
| cpu_user..cpu_idle | `/proc/stat` delta, % of all CPUs (sum 100) |
| mem_avail_mb .. swap_used_mb | `/proc/meminfo` |
| pswpin_s, pswpout_s, pgmajfault_s, allocstall_s, refault_file_s | `/proc/vmstat` delta |
| psi_cpu_some .. psi_io_full | `/proc/pressure/*` total= delta, % of the interval |
| disk_r_iops .. disk_await_ms | `/proc/diskstats` of the root disk |
| cg_cpu_{db,php,php2,cron,web,redis} | cgroup v2 `cpu.stat` of each unit, % of ONE core |
| cg_mem_mb_{db,php,cron}, cg_mempsi_some_{php,db} | cgroup `memory.current`, memory pressure |
| fpm_children, fpm_R, fpm_active60, fpm_rss_mb, fpm_listen_q | the site pool: children of the master of the site's PHP version; R = running now; active60 = children whose CPU time changed in the last minute; listen_q = accept queue of the FPM socket (> 0 means requests waited) |
| fpm2_children, fpm2_listen_q | the second PHP-FPM version (other apps) |
| db_rss_mb, my_* | DB server RSS; `SHOW GLOBAL STATUS` via `dbstat.php`: connections, Threads_running sampled 6 times 2 s apart (avg, max), long-running statements of Moodle's DB user, qps, slow queries per minute, full joins, temp tables on disk, buffer pool reads, checkpoint age, row-lock waits, aborted clients |
| redis_* | Redis INFO: memory, clients, ops/s, hit % over the interval, evictions, keys over all databases, uptime |
| tcp_estab_443/80, tcp_synrecv, tcp_timewait, web_acceptq_443 | `ss` state counts; accept queue of :443 |
| client_rtt_p50/p90/n | `ss -i` RTT of established :443 connections (values only, no addresses). Behind a CDN this is the RTT to the CDN, not to students |
| listen_drops_d .. out_segs_d | `/proc/net/netstat` + `/proc/net/snmp` deltas |
| cron_php_procs, adhoc_procs | php processes running `admin/cli/cron.php` / `adhoc_task.php` (not the `sh -c` wrappers) |
| users_5min, cron_ge10s_5m, cron_failed_5m | every 5th minute only: logged-in users active in 5 min (one indexed COUNT), cron tasks that took 10 s or more and failed tasks, from the bytes appended to the cron log |

`ttfb.csv`: four GETs every 5 minutes, 3 s apart (robots.txt = web server only, login page, front page, course
index), with curl's DNS/connect/TLS/TTFB/total, HTTP code and version. One cookie jar keeps one guest session alive,
so the probes do not create thousands of guest sessions when `autologinguests` is on. The user agent
`moodle-audit-monitor/1.0` lets the collector exclude these requests.

`events.log`: start/stop, reboot, DB/Redis restarts and reachability, PHP-FPM or web master PID changes, probe
failures and thresholds (edge-triggered: one line when crossed, one when cleared): FPM children at 80 % of
`max_children`, FPM accept queue > 0, Threads_running max ≥ 2×CPUs (min 8), memory pressure (full) > 1 %, swap-out,
SYN-RECV > 900, listen drops, TTFB > 3 s. While a threshold is active, `snap/<time>.txt` (at most one per 10 min)
holds the top 25 processes by CPU (command names only), `ss -s` and the last processlist aggregate.

## 5. Safety design
- Self-expiry first, on every run: `END_EPOCH` reached, missing, invalid or more than 8 days ahead; data directory
  over 100 MB; `monitor.err` over 1 MB. Then it removes its lines (only when `crontab -l` succeeded and contained the
  marker), deletes the cookie jar, logs `stopped <reason>`, and retries the removal at most once per hour if writing
  the crontab fails.
- The watchdog line removes the marked lines one hour after the end without needing the data directory.
- `flock -n` skips an overrunning run instead of queueing it; `timeout -k 5` kills a stuck run so it cannot hold
  the lock. A manual `run.sh metrics` takes a separate inner lock, so it never races cron on the state files.
- Never root (both scripts refuse). No POST. No retries. config.php is parsed by a regex in memory (never included,
  never printed); PHP runs with `-n` and `zend.exception_ignore_args=1` so no trace prints argument values.

## 6. Adapting to a different server
| Difference | Effect / what to do |
|---|---|
| config.php not readable by the operator | DB columns stay empty (`DB_ENABLED=0`). Do not loosen config.php's mode for the monitor. If DB sampling matters, the owner may create a read-only account for it (a change, owner decision); otherwise rely on the collector's 60-s status delta |
| PostgreSQL | DB columns empty; the rest works |
| Redis with a password | INFO is refused, Redis columns empty (the monitor never handles that password) |
| No Redis, or Redis on another host | `REDIS=` empty, or set `REDIS=host:port` in monitor.env |
| Apache | `WEB_UNIT=apache2`; master PID events work; `web_acceptq_443` from the :443 listener |
| FPM on TCP (`listen = 127.0.0.1:9000`) | `FPM_SOCK=127.0.0.1:9000`: the accept queue is read from the TCP listener |
| cgroup v1 or units with other names | `cg_*` columns empty; set `DB_UNIT`, `WEB_UNIT`, `REDIS_UNIT` in monitor.env |
| No readable cron log | cron columns empty; pass `--cronlog FILE` if one exists; the collector reads it as root |
| User crontab not allowed | stop and ask; a systemd user timer dies at logout unless lingering is enabled (a change) |
| Server time zone differs from the students' | everything is server local time; set `MON_TZ=` in monitor.env only if the owner wants another zone, and say which in the report |

## 7. Reading the data
- One sample per minute: a 4-10 s burst can start and end between samples. Cumulative counters (FPM status page
  `max children reached`, `listen_drops_d`) catch what instant values miss; propose the FPM status page
  (observability §2) when bursts are suspected.
- `fpm_rss_mb` counts shared OPcache many times; use `cg_mem_mb_php` for the real cost.
- Exclude minutes when other work ran (the collector run, analysis tools, a backup): compute "other CPU" = total CPU
  minus the service cgroups and list the minutes above about 10 % of a core.
- The probe is a guest on a local connection: it measures server time for the guest front page, not a logged-in
  dashboard and not the network to students.
- Say the load level reached: "flat under load" is proven only up to the busiest hour observed. Compare it with the
  busiest hour in 14 days of access logs.
- Join TTFB cycles to the metrics row of the same minute; the metrics columns are sampled a few seconds before the
  probes. Repeat the correlation with the next minute's row as a sensitivity check.
