# moodle-health: what each check does, why, and how to adapt it

Loaded on demand from SKILL.md. The script is `scripts/moodle-health` (python3 >= 3.7, standard library only),
installed as `/usr/local/sbin/moodle-health`; settings in `/etc/default/moodle-health` (template
`assets/moodle-health.default`). `moodle-health --self-check` prints which checks are active on this server and why
the others are skipped.

## Contents
1. Decision logic (confirmation, re-arm, mute, disk full, time budget, crash)
2. The checks one by one
3. Adapting to a different server
4. State files
5. Tuning thresholds

## 1. Decision logic
Each run (every minute, systemd timer) runs all checks, collects `(level, key, message)` items and sends ONE ping to
healthchecks.io: success (`<url>`) with the problem list as body, or failure (`<url>/fail`).

| Rule | Why |
|---|---|
| **2 of the last 3 runs** (`CONFIRM_NEED`/`CONFIRM_OF`): a critical item alerts only when seen in 2 of the last 3 runs; until then the body says `pending (confirming)` | one slow request, a PHP-FPM reload or a log rotation must not wake the owner at night; a real outage is still reported within about 2 minutes |
| **Warnings never alert**: they ride in the body of a success ping (healthchecks dashboard / email shows them) | frozen bounces, a single max_children hit, a slow login page are worth seeing, not worth a 3 a.m. alarm |
| **Re-arm**: if a NEW critical key is confirmed while the check is already failing, send one success ping, then the failure | healthchecks.io notifies only on a state change; without re-arm a second, different outage during the first one would be silent |
| **Atomic state writes** (temp file + fsync + rename); if `history.json` cannot be written, confirmation is switched off and the run alerts at once with "state directory not writable (disk full?)" | the independent review found the original design silent on a full disk: it could never "confirm" anything |
| **Time budget 40 s** inside the unit's `TimeoutStartSec=55`; every tool call gets at most the time left; when the budget is used up the remaining checks are skipped (a warning says so) and **never reported as failures** | a hung DB ping or curl must not stretch a run past the next timer tick; skipped is not the same as broken |
| **Order**: services, site, DB, Redis, 5xx, FPM, Apache, disk/mem, cron, fail2ban, mail, extra sites, certificate, Moodle status checks | the essentials run first, the slow Moodle CLI check last |
| **Mute** (`--mute N`, max 720 min): critical items are still shown, but the ping is a success with `MUTED (planned work)` | planned work should not page the owner; mute does NOT stop the probes and cannot hide missing pings (see operating.md) |
| **Crash**: an unexpected exception in a timer run sends `/fail` "moodle-health crashed: <type>" (not during dry-run, self-check, status, baseline or mute commands, and not while muted) | a broken monitor must not look like a healthy one |
| **Dry run** sends nothing, writes no state, and shows every critical item as `CRITICAL` (no confirmation) | it is the review tool before enabling and after any change |
| **Test guard**: if `MOODLE_HEALTH_CONF` or `MOODLE_HEALTH_STATE` is overridden but `MOODLE_HEALTH_URLFILE` is not, nothing is sent | the first server got a false Telegram alert from a test that used the real URL file |

## 2. The checks
| Check | Level | Config keys | Notes |
|---|---|---|---|
| services | crit per unit not `active` | `SERVICES` | systemd unit names; the installer takes them from what is active now (web server, every FPM version serving a site, DB, cache, MTA, cron, fail2ban). `systemctl` missing → skipped |
| site | crit | `WWWROOT` (or `SITE`), `PROBE_ADDR`, `LOGIN_PATH`, `LOGIN_MARKER`, `SLOW_SEC` | `curl -k --resolve <host>:<port>:<PROBE_ADDR>` GET of the login page **on this machine** (bypasses Cloudflare/DNS on purpose: the external monitor covers those). Crit on: not 200, 503 + "maintenance", DB error text, login form marker missing. Slow → warning. Reuses one cookie jar in the state dir so it does not create a new Moodle session every minute |
| extra sites | crit on no answer or 5xx | `EXTRA_SITES` (`host` or `host/path`) | other vhosts on the box, by SNI, on `/favicon.ico` by default (static: no PHP session, no DB). 404 means "alive" |
| db | crit | `DBTYPE`, `DBHOST` | `mariadb-admin`/`mysqladmin ping --connect-timeout=5` (exit 0 even on "access denied": it proves the server answers, no credentials needed); `pg_isready` for PostgreSQL. sqlsrv/oci: skipped (the login-page DB-error text still catches failures) |
| redis | crit | `REDIS_CHECK`, `REDIS_CLI_ARGS` | `redis-cli ping`; `NOAUTH` counts as alive, so a password-protected Redis needs no secret here |
| 5xx rate | crit | `ACCESS_LOG`, `ACCESS_LOG_VHOST`, `WINDOW_MIN`, `ERR5XX_MIN`, `ERR5XX_PCT` | tail (8 MB) of nginx or Apache "combined"-style logs: `[time] "request" status`. Crit when at least `ERR5XX_MIN` 500/502/503/504 AND at least `ERR5XX_PCT` % of requests in the window. A log whose lines do not parse gives a warning ("format not recognised"), so the check is never silently blind |
| php-fpm | warn on 1 hit, crit on >= 2 | `FPM_LOGS`, `WINDOW_MIN` | "server reached pm.max_children" lines in the FPM master log within the window |
| apache workers | warn | `APACHE_ERROR_LOG` | "reached MaxRequestWorkers" (AH00161/AH00484). Apache logs it about once per restart, so it can only be a warning; the audit module measures saturation properly |
| disk / memory | crit | `DISK_PATHS`, `DISK_CRIT_PCT`, `MEM_CRIT_PCT` | blocks and inodes per filesystem (deduplicated by device): `/`, dataroot, `/var/lib/mysql`, `/var/lib/postgresql`, `/var/log` by default; MemAvailable |
| cron | crit | `CRON_LOG`, `CRON_STALE_MIN` | mtime of the file the Moodle cron job writes. No log (output discarded) → skipped; Moodle's own `tool_task_cronrunning` status check reports CRITICAL after a day, or earlier with `MOODLE_WARN_AS_CRIT` (see §3) |
| fail2ban vs proxy | crit | `CF_RANGES_FILE` | any fail2ban jail holding a ban on an address inside the trusted proxy/CDN ranges (nginx `set_real_ip_from`, Apache `RemoteIPTrustedProxy[List]`, or a plain CIDR list). This was the first server's outage: after the move behind Cloudflare, fail2ban banned edge addresses and every student behind them was locked out |
| mail queue | crit for stuck mail, warn for bounces/hold | `MTA`, `MAIL_STUCK_MIN`, `MAIL_STUCK_CRIT` | exim: `exiqgrep -c -x -o <secs>` (unfrozen, older than) = stuck; `exiqgrep -c -z` = frozen (usually bounces that expire by themselves, e.g. from a test mail). Postfix: `postqueue -j` (3.1+), else `mailq` text; deferred/active mail older than the limit = stuck, old bounces (sender `MAILER-DAEMON`/empty) and `hold` = warnings. Fewer than `MAIL_STUCK_CRIT` stuck = warning |
| certificate | crit | `CERT_CRIT_DAYS` | `openssl s_client` to `PROBE_ADDR` with SNI, cached for an hour. Behind Cloudflare this is the **origin** certificate (Origin CA or Let's Encrypt); the edge certificate is Cloudflare's job |
| Moodle status checks | crit for new/changed ERROR/CRITICAL | `MOODLE`, `PHPBIN`, `WEBUSER`, `MOODLE_CHECKS_EVERY_MIN`, `MOODLE_CHECKS_IGNORE`, `MOODLE_WARN_AS_CRIT` | `admin/cli/checks.php --type=status` (Moodle 3.9+; found in `<MOODLE>/admin/cli/` on 4.x and 5.x) every 15 min, **as the web user via `setpriv`** (Moodle CLI as root leaves root-owned cache files in the dataroot and breaks the site). Compared with the baseline: a ref not in the baseline, or a baseline ref whose message changed (digits ignored, so changing counts are not "new"), is critical. "Could not run" twice in a row is critical |

## 3. Adapting to a different server
| Server differs | What to do |
|---|---|
| Apache instead of nginx | Nothing in the script; the installer reads `CustomLog`/`ErrorLog` of the vhost (`${APACHE_LOG_DIR}` expanded). A vhost without its own CustomLog writes to `other_vhosts_access.log` (vhost_combined): set `ACCESS_LOG_VHOST=<SITE>` (the installer does). RHEL: units `httpd`, `php-fpm`, `crond`; logs under `/var/log/httpd/` |
| mod_php (no FPM) | `FPM_LOGS` empty; Apache worker saturation shows as a warning only |
| Postfix instead of exim | `MTA=postfix` (installer sets it from the active service). Old Postfix without `-j` falls back to `mailq` |
| no MTA (Moodle sends straight to an external SMTP) | `MTA=none`; the mail module explains why a local relay is better |
| no Redis | `REDIS_CHECK=no` |
| PostgreSQL | `DBTYPE=pgsql`; `pg_isready` must exist (package `postgresql-client`) |
| remote DB / Redis | `DBHOST=<host>`; `REDIS_CLI_ARGS="-h <host> -p <port>"`. Liveness only, no credentials |
| Moodle 4.x | same; `checks.php` lives in `<MOODLE>/admin/cli/`. Moodle older than 3.9 has no checks.php: that part is skipped |
| Moodle 5.1+ | docroot is `public/`, but `admin/cli/checks.php` stays outside it; the script looks in both places |
| wwwroot with a sub-path or port (`https://host:8443/moodle`) | set `WWWROOT` exactly; the probe and certificate check use the host, port and path from it |
| site on plain http | probe uses port 80; certificate check skipped. Propose TLS (cloudflare module) |
| web server listens only on a public/private IP or IPv6 | `PROBE_ADDR=<that address>` (IPv6 without brackets, e.g. `::1`) |
| SSO forces a redirect away from the login page (SAML/OAuth `alternateloginurl`) | point `LOGIN_PATH` at a page that renders the Moodle form (auth_saml2: `/login/index.php?saml=off`), or at a page with a stable marker, and set `LOGIN_MARKER` to text it always contains. Verify with `--dry-run` |
| custom theme | every Moodle login form keeps the hidden `logintoken` field (CSRF protection), themes included. Verify once: `curl -s https://<SITE>/login/index.php \| grep -c logintoken` |
| cron output discarded (`> /dev/null`) | `CRON_LOG` empty; optionally `MOODLE_WARN_AS_CRIT=tool_task_cronrunning` so the cron WARNING (not run for more than `expectedcronfrequency` + 1 min) alerts. Watch a few dry runs first: with long keep-alive cron runs it may flap |
| not behind Cloudflare | `CF_RANGES_FILE` empty (or point it at the load balancer's ranges if a proxy sits in front) |
| Moodle, its dataroot or logs under `/home` | the installer writes `ProtectHome=read-only` into the unit (the default `yes` would hide them) |
| no systemd | stop and ask: a root cron line `* * * * * timeout 55 /usr/local/sbin/moodle-health` is the fallback |
| python3 < 3.7 | stop: the OS is too old; propose the upgrade first |
| several Moodle sites on one box | one install per box covers one site; add the others as `EXTRA_SITES` (liveness only) or ask the owner whether a second instance (own config, state and check) is wanted. That needs a renamed copy of the script and units: plan it explicitly |

## 4. State files (`/var/lib/moodle-health`, root 700)
| File | Content |
|---|---|
| `history.json` | last `CONFIRM_OF` results per critical key (confirmation) |
| `last.json` | time, status ok/fail, confirmed keys, messages, ping result (never the URL) |
| `moodle-checks.json` | cached checks.php result (refs + message hashes, ok, consecutive failures) |
| `moodle-checks.baseline` | refs known to fail when the baseline was recorded, with message hashes |
| `cert.json` | cached certificate end date |
| `cookies.txt` | the probe's Moodle session cookie (anonymous login-page session, not a user login) |
| `mute` | epoch until which alerts are muted |

## 5. Tuning thresholds
Start with the template defaults (they were right on the first server). After a week, read the healthchecks.io event
log (or `journalctl -u moodle-health --since -7d`: a line is written only on a status change or while failing) and:
- repeated `pending` that never confirms on the same key → a flapping probe: find the cause before raising limits;
- 5xx alerts during known heavy moments (exams) that were real → keep; alerts from one bot hammering a 500 → raise
  `ERR5XX_MIN`, or fix the 500 (nginx module);
- a warning that shows every day and is accepted → leave it (warnings do not page), or fix it.
Change one value at a time, `--dry-run`, log it (core-rules §3).
