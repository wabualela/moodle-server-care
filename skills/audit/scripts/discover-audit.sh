#!/usr/bin/env bash
# discover-audit.sh - read-only readiness check for the audit module (moodle-server-care).
#
#   bash discover-audit.sh [--env FILE]
#
# Run as the operator (no sudo needed; files only root can read are reported as "not readable", never forced).
# It reports what evidence exists (log formats and retention, slow logs, status pages, sysstat), what the 48-hour
# monitor and the root collector need, and which observability gaps are worth proposing to the owner.  It changes
# nothing and makes no network request.  Output: one line per check: STATUS  item  detail
#   OK    = ready;  GAP = missing evidence (a proposal, each one a change that needs approval);
#   INFO  = fact;   WARN = something that limits or endangers the audit.
set -u -o pipefail
set +x
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-env.sh
. "$HERE/lib-env.sh"
ENVF=$(msc_env_path)
[[ ${1:-} == --env ]] && ENVF=$2
p() { printf '%-5s %-26s %s\n' "$1" "$2" "$3"; }

echo "== audit readiness on $(hostname) at $(date '+%F %T %z') (as $(id -un))"
if [[ ! -r $ENVF ]]; then p WARN server.env "missing: run skills/start/scripts/detect-env.sh first"; exit 2; fi
age=$(( ( $(date +%s) - $(stat -c %Y -- "$ENVF") ) / 3600 ))
p INFO server.env "$ENVF (${age} h old$( ((age > 24)) && echo '; older than a day: rerun detect-env.sh'))"
msc_parse_env "$ENVF" MOODLE DOCROOT RELEASE PHP FPM_SOCK VHOST DBTYPE WEBUSER \
  || { p WARN server.env "not usable (see the message above): rerun skills/start/scripts/detect-env.sh"; exit 2; }
MOODLE=${MOODLE:-}; DOCROOT=${DOCROOT:-}; RELEASE=${RELEASE:-}; PHPN=${PHP:-}
FPM_SOCK=${FPM_SOCK:-}; VHOST=${VHOST:-}; DBTYPE=${DBTYPE:-}; WEBUSER=${WEBUSER:-www-data}
PHPV=${PHPN#php}
p INFO moodle "$RELEASE at $MOODLE (docroot $DOCROOT)"
p INFO timezone "server $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null) ($(date +%z)); students' zone: ask the owner, report both"

# ---- web server, access log, format, retention
if command -v nginx >/dev/null 2>&1 || [[ -x /usr/sbin/nginx ]]; then WEB=nginx; else WEB=apache; fi
p INFO "web server" "$WEB; site vhost ${VHOST:-not found}"
ALOG=""; AFMT=""
if [[ -r $VHOST ]]; then
  read -r ALOG AFMT < <(grep -hE '^[[:space:]]*(access_log|CustomLog)[[:space:]]+' -- "$VHOST" | grep -v ' if=' \
      | sed -E 's/^[[:space:]]*(access_log|CustomLog)[[:space:]]+"?([^"[:space:];]+)"?([[:space:]]+([^[:space:];]+))?.*/\2 \4/; s#\$\{APACHE_LOG_DIR\}#/var/log/apache2#' \
      | grep '^/' | head -n 1)
fi
if [[ -n $ALOG ]]; then
  if [[ $WEB == nginx ]]; then
    def=$(grep -rhzoE "log_format[[:space:]]+${AFMT:-combined}[[:space:]][^;]*;" /etc/nginx 2>/dev/null | tr '\0\n' '  ')
    if [[ -z $AFMT || $AFMT == combined ]]; then p GAP "access log format" "$ALOG uses 'combined': no request times. Propose the perf format (references/observability.md §1)"
    elif [[ $def == *'$upstream_response_time'* && $def == *'$request_time'* ]]; then p OK "access log format" "$ALOG uses '$AFMT' with request_time and upstream_response_time"
    else p GAP "access log format" "$ALOG uses '$AFMT' without both timings: propose the perf format"; fi
  else
    p GAP "access log format" "$ALOG (Apache '$AFMT'): add %D (microseconds) to measure server time; the collector reads it as combined only"
  fi
  n=$(ls -1 "$ALOG".* 2>/dev/null | wc -l); old=$(ls -1tr "$ALOG"* 2>/dev/null | head -n 1)
  days=$(( ( $(date +%s) - $(stat -c %Y -- "$old" 2>/dev/null || date +%s) ) / 86400 ))
  if (( days >= 13 )); then p OK "log retention" "$n rotated files, oldest about $days days"; else p WARN "log retention" "only about $days days of access logs ($n rotations): the 14-day baseline and quiet hours need 14"; fi
  [[ -r $ALOG ]] && p OK "log readable" "as $(id -un)" || p INFO "log readable" "not as $(id -un) (quiet-hours.sh and measure-endpoints.sh need sudo; read-only)"
else
  p WARN "access log" "not found in the vhost; pass --site-log to the collector"
fi
if [[ $WEB == nginx ]]; then
  grep -rqsE '^[[:space:]]*stub_status' /etc/nginx && p OK "nginx stub_status" "configured" || p GAP "nginx stub_status" "not configured (references/observability.md §2)"
fi

# ---- PHP-FPM
POOL=""
for pf in /etc/php/"$PHPV"/fpm/pool.d/*.conf; do
  [[ -r $pf ]] || continue
  l=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$pf" | head -n 1)
  if [[ -z $FPM_SOCK || ${l#/var} == "${FPM_SOCK#/var}" ]]; then POOL=$pf; break; fi
done
if [[ -n $POOL ]]; then
  g() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^;]*[^;[:space:]]).*/\1/p" "$POOL" | head -n 1; }
  p INFO "fpm pool" "$POOL: pm=$(g pm) max_children=$(g 'pm\.max_children') start=$(g 'pm\.start_servers') spare=$(g 'pm\.min_spare_servers')-$(g 'pm\.max_spare_servers') max_requests=$(g 'pm\.max_requests')"
  sl=$(g slowlog); st=$(g request_slowlog_timeout)
  if [[ -n $sl && -n $st && $st != 0 ]]; then p OK "fpm slow log" "$sl after $st"; else p GAP "fpm slow log" "slowlog/request_slowlog_timeout not set: stack traces of slow requests are lost (observability §3)"; fi
  [[ -n $(g 'pm\.status_path') ]] && p OK "fpm status page" "pm.status_path=$(g 'pm\.status_path') listen=$(g 'pm\.status_listen')" \
    || p GAP "fpm status page" "not set: sub-minute pool saturation is invisible (observability §2)"
  p INFO "fpm timeouts" "request_terminate_timeout=$(g request_terminate_timeout) catch_workers_output=$(g catch_workers_output)"
else
  p WARN "fpm pool" "no readable pool file for $PHPN / $FPM_SOCK (mod_php or another layout: FPM steps will be empty)"
fi
others=$(for d in /etc/php/*/fpm; do v=$(cut -d/ -f4 <<< "$d"); [[ $v != "$PHPV" ]] && pgrep -f "php-fpm: master process \\(/etc/php/$v/" >/dev/null && echo "$v"; done | tr '\n' ' ')
[[ -n $others ]] && p INFO "other php-fpm" "running: $others(other applications share the box; the collector reads their FPM logs too)"

# ---- system history
command -v sar >/dev/null 2>&1 && p OK sysstat "installed ($(ls /var/log/sysstat 2>/dev/null | wc -l) data files)" || p GAP sysstat "not installed: no CPU/memory/disk history (observability §4)"
p INFO journal "$(journalctl --disk-usage 2>/dev/null | sed 's/^.*take up //')"

# ---- database
case $DBTYPE in
  mysqli|mariadb|auroramysql)
    sq=$(grep -rhsE '^[[:space:]]*(slow_query_log|slow-query-log|long_query_time|slow_query_log_file)[[:space:]]*=' /etc/mysql 2>/dev/null | tr '\n' ' ')
    if [[ $sq == *slow* ]]; then p OK "db slow log" "$sq"; else p GAP "db slow log" "not enabled in /etc/mysql (or not readable): propose slow_query_log=1, long_query_time=1 (observability §5)"; fi
    ps=$(grep -rhsE '^[[:space:]]*performance_schema[[:space:]]*=' /etc/mysql 2>/dev/null | tail -n 1)
    p INFO "performance_schema" "${ps:-not set in config (MariaDB default OFF, MySQL default ON)}; digest analysis needs it ON (a restart: maintenance night)" ;;
  pgsql) p WARN database "PostgreSQL: the collector skips DB steps; use the manual read-only queries in references/collector.md" ;;
  *) p WARN database "dbtype '$DBTYPE' unknown" ;;
esac

# ---- Moodle cron log
cl=""
for f in /var/log/*cron*/*.log /var/log/moodle*.log /var/log/*moodle*/*.log; do
  [[ -r $f ]] || continue
  tail -c 65536 -- "$f" 2>/dev/null | grep -q 'Execute scheduled task' && { cl=$f; break; }
done
[[ -n $cl ]] && p OK "moodle cron log" "$cl" || p INFO "moodle cron log" "none readable as $(id -un) (the collector finds it from the $WEBUSER crontab as root)"

# ---- services
for s in redis-server exim4 postfix fail2ban sysstat unattended-upgrades; do
  systemctl cat "$s.service" >/dev/null 2>&1 || continue      # not installed
  p INFO "service $s" "$(systemctl is-active "$s" 2>/dev/null)"
done
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[[ -n $failed ]] && p WARN "failed units" "$failed" || p OK "failed units" "none"
[[ -f /var/run/reboot-required ]] && p WARN "reboot" "pending (/var/run/reboot-required): affects 'restart' findings and the maintenance module"

# ---- monitor prerequisites (unprivileged)
if crontab -l >/dev/null 2>&1 || crontab -l 2>&1 | grep -q 'no crontab'; then p OK "user crontab" "usable by $(id -un) ($(crontab -l 2>/dev/null | grep -cvE '^[[:space:]]*(#|$)') job lines now)"
else p WARN "user crontab" "not usable by $(id -un) (cron.allow/deny?)"; fi
crontab -l 2>/dev/null | grep -q 'MSC-MONITOR' && p WARN "monitor" "a monitor is already installed in this crontab"
php=$(command -v "$PHPN" || command -v php)
if [[ -n $php ]] && "$php" -n -d extension=mysqlnd -d extension=mysqli -r 'exit(function_exists("mysqli_init")?0:1);' 2>/dev/null; then p OK "monitor php" "$php loads mysqli with -n"
else p WARN "monitor php" "${php:-php} cannot load mysqli with -n: monitor DB columns will be empty"; fi
[[ -r $MOODLE/config.php ]] && p INFO "config.php" "readable by $(id -un): the monitor can sample the DB (credentials stay in memory, never printed)" \
  || p INFO "config.php" "not readable by $(id -un): monitor DB columns stay empty (do not loosen its mode)"
for t in gawk curl flock timeout ionice ss; do command -v "$t" >/dev/null 2>&1 || p WARN tool "$t missing"; done
gv=$(gawk --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
awk -v v="${gv:-0}" 'BEGIN { exit !(v >= 4.2) }' && p OK gawk "$gv" || p WARN gawk "${gv:-missing}: the collector needs gawk 4.2+"
p INFO "free space" "home: $(df -h "$HOME" | awk 'NR==2 {print $4}') available (collector output 5-50 MB, monitor 2-5 MB)"
sudo -n true 2>/dev/null && p INFO sudo "passwordless for $(id -un) (the root collector still needs the owner's go-ahead)" || p INFO sudo "needs a password: the owner runs the collector (assets/collector-owner-steps-ar.md)"

# ---- load now
read -r l1 l5 l15 _ < /proc/loadavg
p INFO load "now $l1 / $l5 / $l15 on $(nproc) CPUs; run the collector in a quiet hour (scripts/quiet-hours.sh)"
