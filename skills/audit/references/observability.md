# Observability gaps worth closing (each item is a CHANGE)

`scripts/discover-audit.sh` lists these as `GAP`. Propose them to the owner as one small batch, apply one at a time
with the change protocol of `../../shared/core-rules.md` §3, in a quiet hour, and log each in the operations log.
Ideally they run 7-14 days before the collector, so the audit has the evidence. They are cheap and reversible; none
needs a restart (reloads only), except enabling `performance_schema` (§6).

Placeholders: `<SKILL_DIR>` = this skill's base directory, `<PHPV>` = PHP version of the site (from server.env `PHP`,
e.g. 8.3), `<POOL>` = the site's pool file,
`<VHOST>` = the site's web server config file, `<SITE>` = host name. Use real values; check every path exists first.

## Contents
1. Access log with request and upstream times (nginx `perf` format; Apache `%D`)
2. PHP-FPM status page and nginx stub_status on a loopback-only listener
3. PHP-FPM slow log
4. sysstat history
5. MySQL/MariaDB slow query log
6. performance_schema (maintenance night only)
7. Temporary extra detail during a measurement window

## 1. Access log with times
Why: without per-request times there is no way to tell server slowness from network or browser slowness, or to
measure a fix. `rt` = `$request_time` (whole request including sending), `urt` = `$upstream_response_time` (PHP).

nginx: put `assets/nginx-perf-logformat.conf` in `/etc/nginx/conf.d/` (the `log_format` must be at http level) and
change the site's `access_log` line to use it.
```bash
V=$(readlink -f <VHOST>)        # sites-enabled entries are usually symlinks: back up and edit the real file
sudo mkdir -p -m 700 /root/observability-$(date +%F)
sudo cp -a "$V" /root/observability-$(date +%F)/     # never leave a backup inside sites-enabled/ or conf.d/:
                                                     # nginx would load it as a second copy of the site
sudo install -m 0644 <SKILL_DIR>/assets/nginx-perf-logformat.conf /etc/nginx/conf.d/perf-logformat.conf
# in "$V": access_log /var/log/nginx/<site>-access.log perf;     (keep the same file name: rotation stays valid)
sudo nginx -t && sudo systemctl reload nginx
sudo tail -n 2 /var/log/nginx/<site>-access.log        # lines now end in rt=0.123 urt=0.120
```
Rollback: `sudo cp -a /root/observability-<date>/<file> "$V"`, remove the conf.d file, `nginx -t`, reload. The format is the standard combined
format plus two fields at the end, so every combined-log tool keeps working.

Apache: add `%D` (microseconds) at the end of a copy of the combined format, e.g.
`LogFormat "%h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\" D=%D" combined_d`, use it in the
site's `CustomLog`, `apache2ctl configtest`, `systemctl reload apache2`. The collector does not parse `D=` as `urt`
yet; convert it in the analysis (microseconds) or extend `access_agg.awk` in the plugin repo.

## 2. PHP-FPM status page and nginx stub_status (loopback only)
Why: a pool can fill in a few seconds and empty again between one-minute samples. FPM's cumulative counters
(`max active processes`, `max listen queue`, `max children reached`) catch such bursts even when read once a minute.
`pm.status_listen` (PHP 8.0+) answers from a separate side pool, so the page still works when every worker is busy,
which is exactly when it is needed.

```bash
sudo cp -a <POOL> <POOL>.bak-$(date +%F)
# append inside the [pool] section of <POOL> (pick a free loopback port: ss -Hltn | grep 9001 must be empty):
#   pm.status_path   = /fpm-status
#   pm.status_listen = 127.0.0.1:9001
sudo php-fpm<PHPV> -t && sudo systemctl reload php<PHPV>-fpm      # reload is graceful; never restart in the day
ss -Hltn | grep 127.0.0.1:9001
```
nginx loopback server, `/etc/nginx/conf.d/local-status.conf`:
```nginx
server {
    listen 127.0.0.1:8081;
    server_name localhost;
    access_log off;
    allow 127.0.0.1;
    deny all;
    location = /nginx-status { stub_status; }
    location = /fpm-status {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /fpm-status;
        fastcgi_pass 127.0.0.1:9001;
    }
    location / { return 404; }
}
```
```bash
sudo nginx -t && sudo systemctl reload nginx
curl -s http://127.0.0.1:8081/nginx-status; curl -s http://127.0.0.1:8081/fpm-status
curl -s -o /dev/null -w '%{http_code}\n' https://<SITE>/fpm-status        # must be 404 (not public)
```
Check first that `nginx -V` lists `--with-http_stub_status_module` (Debian builds do). Rollback: remove the two pool
lines and the conf.d file; test; reload both.
Note for the owner: `?full` lists every worker's current request URI (query strings can hold session keys), and
127.0.0.1 is not a user boundary: every local account can read it. Keep it loopback-only and remove it after the
audit if other people have shell accounts.

## 3. PHP-FPM slow log
Why: a stack trace of every request slower than N seconds names the code that waited (SMTP, session lock, DB,
external HTTP). On the first server it proved that sign-up and enrolment waited for the mail server.
```bash
sudo cp -a <POOL> <POOL>.bak-$(date +%F)
# in <POOL>:  slowlog = /var/log/php<PHPV>-fpm-slow.log
#             request_slowlog_timeout = 5s        (2s for a short measurement window: §7)
#             request_slowlog_trace_depth = 20
sudo php-fpm<PHPV> -t && sudo systemctl reload php<PHPV>-fpm
```
Add log rotation (the slow log is usually not covered): `/etc/logrotate.d/php<PHPV>-fpm-slow` with `weekly`,
`rotate 8`, `compress`, `missingok`, `notifempty`, `copytruncate`; test with `logrotate -d`. Rollback: remove the
lines, reload.

## 4. sysstat history
Why: CPU, run queue, memory, paging, disk and network history for every day, so a complaint about "last Tuesday" can
be checked. About 1-3 MB per day.
```bash
sudo apt-get install -y sysstat           # a package install: owner approval
grep -c '^ENABLED=' /etc/default/sysstat  # must print 1; otherwise edit the file by hand
sudo cp -a /etc/default/sysstat /etc/default/sysstat.bak-$(date +%F)
sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat && grep '^ENABLED=' /etc/default/sysstat
sudo systemctl enable --now sysstat
systemctl list-timers 'sysstat*'
```
Optional 1-minute resolution: `sudo systemctl edit sysstat-collect.timer` with `[Timer]`, `OnCalendar=`,
`OnCalendar=*:*:00`. Usage: `sar -u`, `sar -q`, `sar -r`, `sar -B`, `sar -d -p`, `sar -n DEV`, `sar -f
/var/log/sysstat/saDD`. Rollback: `systemctl disable --now sysstat`.

## 5. MySQL/MariaDB slow query log
Why: names the queries over N seconds with their timing and rows examined. On the first server it showed that every
slow query came from scheduled tasks, not from student pages, which redirected the fix to the task schedule.
In a config file under `/etc/mysql/mariadb.conf.d/` (MySQL: `/etc/mysql/mysql.conf.d/`), e.g. `99-slowlog.cnf`:
```ini
[mysqld]
slow_query_log      = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time     = 1
```
It takes effect at the next restart; to avoid a restart now, also set it live (session-independent, reverts at
restart): `sudo mariadb -e "SET GLOBAL slow_query_log=1; SET GLOBAL long_query_time=1;"` (this is a `SET GLOBAL`:
a change, approval, log it). Make sure `/var/log/mysql/*.log` is covered by a logrotate stanza once only (two stanzas
for the same file make logrotate fail every night: it happened on the first server).

## 6. performance_schema
Statement digests (the best "which queries cost the most time" evidence) need `performance_schema = ON`. MariaDB
ships it OFF; MySQL ON. Turning it on needs a DB restart and about 100-400 MB of memory: only in an announced
maintenance night (maintenance module), never in the day.

## 7. Temporary extra detail during a measurement window
For the 3-7 days of a measurement only, then revert (put a dated reminder in the log entry):
- FPM `request_slowlog_timeout = 2s` (the 1-5 s band hides mail and lock waits),
- nginx `error_log <file> warn;` (shows "buffered to a temporary file" warnings).
Both via backup → edit → test → reload; revert the same way.
