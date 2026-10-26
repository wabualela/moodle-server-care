#!/bin/bash
# setup.sh - prepare the unprivileged, self-expiring monitor (moodle-server-care audit module).
#
#   bash setup.sh [--hours 48] [--env FILE] [--base DIR] [--cronlog FILE] [--probe origin|public]
#                 [--no-redis] [--test] [--install-cron]
#
# Without --install-cron it changes nothing outside the new data directory: it creates
#   <base>/<YYYYmmdd-HHMMSS>/ (mode 700) with run.sh, dbstat.php, monitor.env and END_EPOCH,
# prints the facts it found and the crontab block to install.  --test runs one metrics sample and one TTFB cycle
# (read-only: one DB connection, a few GET requests).  --install-cron appends the block to the CURRENT user's
# crontab (a change: only after the owner approved it, and log it).  Run as the operator, never as root.
set -u -o pipefail
set +x
umask 077
if (( EUID == 0 )); then echo "setup.sh: run as the operator, not as root" >&2; exit 1; fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOURS=48; ENVF="$HOME/.config/moodle-server-care/server.env"; BASE="$HOME/moodle-audit/monitor"
OPT_CRONLOG=""; PROBE=""; TEST=0; INSTALL=0; NOREDIS=0
while (($#)); do
  case $1 in
    --hours) HOURS=$2; shift 2 ;;
    --env) ENVF=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --cronlog) OPT_CRONLOG=$2; shift 2 ;;
    --probe) PROBE=$2; shift 2 ;;
    --test) TEST=1; shift ;;
    --no-redis) NOREDIS=1; shift ;;
    --install-cron) INSTALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ $HOURS =~ ^[0-9]+$ ]] && (( HOURS >= 1 && HOURS <= 192 )) || { echo "--hours must be 1..192 (8 days)" >&2; exit 2; }
[[ -z $PROBE || $PROBE == origin || $PROBE == public ]] || { echo "--probe origin|public" >&2; exit 2; }
if (( INSTALL )) && crontab -l 2>/dev/null | grep -qF '# MSC-MONITOR'; then
  echo "a monitor is already installed in this crontab; stop it first (<data dir>/run.sh stop)" >&2; exit 1
fi

command -v gawk >/dev/null 2>&1 || { echo "the monitor needs gawk (mawk lacks the functions run.sh uses); installing it is a package change: owner approval" >&2; exit 2; }
# shellcheck source=../lib-env.sh
. "$HERE/../lib-env.sh"
[[ -r $ENVF ]] || { echo "no $ENVF: run skills/start/scripts/detect-env.sh first" >&2; exit 2; }
msc_parse_env "$ENVF" MOODLE WWWROOT PHP FPM_SOCK DBTYPE CLOUDFLARE || { echo "cannot use $ENVF (see above)" >&2; exit 2; }
safe() { [[ $1 =~ ^[A-Za-z0-9_./:@%+,=-]*$ ]] && printf '%s' "$1"; }   # monitor.env takes plain values only
MOODLE=$(safe "${MOODLE:-}"); WWWROOT=$(safe "${WWWROOT:-}"); PHPN=$(safe "${PHP:-}"); FPM_SOCK=$(safe "${FPM_SOCK:-}")
DBTYPE=$(safe "${DBTYPE:-}"); CLOUDFLARE=$(safe "${CLOUDFLARE:-}")
[[ -n $MOODLE && -n $WWWROOT ]] || { echo "MOODLE or WWWROOT missing in $ENVF" >&2; exit 2; }
PHPV=${PHPN#php}
PHPBIN=$(command -v "$PHPN" || command -v php || echo /usr/bin/php)

# pm.max_children of the site's pool (pool files are normally world-readable)
FPM_MAX=0
for pf in /etc/php/"$PHPV"/fpm/pool.d/*.conf; do
  [[ -r $pf ]] || continue
  l=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$pf" | head -n 1)
  if [[ -z $FPM_SOCK || ${l#/var} == "${FPM_SOCK#/var}" ]]; then
    FPM_MAX=$(sed -nE 's/^[[:space:]]*pm\.max_children[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$pf" | head -n 1); FPM_MAX=${FPM_MAX:-0}
    break
  fi
done
# a second PHP-FPM version with a running master (other applications on the box)
PHPV2=""; FPM_SOCK2=""
for d in /etc/php/*/fpm; do
  v=$(cut -d/ -f4 <<< "$d"); [[ $v == "$PHPV" ]] && continue
  if pgrep -f "php-fpm: master process \\(/etc/php/$v/" >/dev/null 2>&1; then
    PHPV2=$v
    FPM_SOCK2=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' /etc/php/"$v"/fpm/pool.d/*.conf 2>/dev/null | head -n 1)
    break
  fi
done
# root filesystem's disk (for disk_* columns)
SRC=$(findmnt -no SOURCE / 2>/dev/null); DISK=$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -n 1)
[[ -n $DISK ]] || DISK=$(basename -- "$SRC" | sed -E 's/p?[0-9]+$//')
# units
WEB_UNIT=nginx; systemctl cat nginx.service >/dev/null 2>&1 || WEB_UNIT=apache2
DB_UNIT=mariadb; systemctl cat mariadb.service >/dev/null 2>&1 || DB_UNIT=mysql
REDIS=""; (( NOREDIS )) || if ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE '^(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\*):6379$'; then REDIS=127.0.0.1:6379; fi
# DB sampling: MySQL family and config.php readable by this user (never loosen its mode for the monitor)
DB_ENABLED=0; DBNOTE=""
case $DBTYPE in
  mysqli|mariadb|auroramysql)
    if [[ -r $MOODLE/config.php ]]; then DB_ENABLED=1; else DBNOTE="config.php not readable by $(id -un): DB columns stay empty"; fi ;;
  *) DBNOTE="dbtype $DBTYPE: DB columns stay empty (MySQL/MariaDB only)" ;;
esac
if (( DB_ENABLED )) && ! "$PHPBIN" -n -d extension=mysqlnd -d extension=mysqli -r 'exit(function_exists("mysqli_init")?0:1);' 2>/dev/null; then
  DB_ENABLED=0; DBNOTE="$PHPBIN cannot load mysqli with -n: DB columns stay empty"
fi
# Moodle cron log: a readable log that contains Moodle task lines
CRONLOG=$OPT_CRONLOG
if [[ -z $CRONLOG ]]; then
  for f in /var/log/*cron*/*.log /var/log/moodle*.log /var/log/*moodle*/*.log; do
    [[ -r $f ]] || continue
    if tail -c 65536 -- "$f" 2>/dev/null | grep -q 'Execute scheduled task'; then CRONLOG=$f; break; fi
  done
fi
RUN_TH=$(( $(nproc) * 2 )); (( RUN_TH < 8 )) && RUN_TH=8

STAMP=$(date +%Y%m%d-%H%M%S)
D=$BASE/$STAMP
[[ $D =~ [[:space:]%] ]] && { echo "data directory path must not contain spaces or %: $D" >&2; exit 2; }
[[ -e $D ]] && { echo "$D already exists" >&2; exit 2; }
mkdir -p "$D/state" "$D/snap"; chmod 700 "$BASE" "$D" "$D/state" "$D/snap"
install -m 0700 "$HERE/run.sh" "$D/run.sh"
install -m 0600 "$HERE/dbstat.php" "$D/dbstat.php"

# TTFB probe target: the origin (127.0.0.1, bypasses any CDN; measures server time only) unless that fails
PROBE_RESOLVE=""
if [[ $PROBE != public ]]; then
  hp=${WWWROOT#*://}; hp=${hp%%/*}; [[ $hp == *:* ]] || { [[ $WWWROOT == https:* ]] && hp=$hp:443 || hp=$hp:80; }
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$hp:127.0.0.1" -A 'moodle-audit-monitor/1.0' "${WWWROOT%/}/robots.txt" 2>/dev/null)
  if [[ $code =~ ^[23] ]]; then PROBE_RESOLVE=127.0.0.1
  elif [[ $PROBE == origin ]]; then echo "WARNING: origin probe failed (http $code); probes will use public DNS" >&2; fi
fi

{
  echo "# monitor.env written by setup.sh on $(date '+%F %T %z'); plain KEY=value, read by run.sh (never sourced)"
  echo "BASE_URL=${WWWROOT%/}"
  echo "PROBE_RESOLVE=$PROBE_RESOLVE"
  echo "PROBE_LABELS=robots login home courses"
  echo "PROBE_PATHS=/robots.txt /login/index.php / /course/index.php"
  echo "PHP=$PHPBIN"
  echo "PHPV=$PHPV"
  echo "PHPV2=$PHPV2"
  echo "FPM_SOCK=$FPM_SOCK"
  echo "FPM_SOCK2=$FPM_SOCK2"
  echo "FPM_MAX=$FPM_MAX"
  echo "DISK=$DISK"
  echo "WEB_UNIT=$WEB_UNIT"
  echo "DB_UNIT=$DB_UNIT"
  echo "REDIS_UNIT=redis-server"
  echo "REDIS=$REDIS"
  echo "DB_ENABLED=$DB_ENABLED"
  echo "MOODLE_CONFIG=$MOODLE/config.php"
  echo "CRONLOG=$CRONLOG"
  echo "RUN_TH=$RUN_TH"
  echo "SYN_TH=900"
  echo "MON_TZ="
} > "$D/monitor.env"
chmod 600 "$D/monitor.env"
grep -vE '^#' "$D/monitor.env" | grep -E '=[^=]*[^A-Za-z0-9_./:@%+,= -]' && { echo "monitor.env has unexpected characters" >&2; exit 2; }
echo $(( $(date +%s) + HOURS * 3600 )) > "$D/END_EPOCH"
END=$(cat "$D/END_EPOCH")

echo "== monitor prepared: $D"
if [[ -n $PROBE_RESOLVE ]]; then PROBES="origin via $PROBE_RESOLVE (server time only, no CDN)"
else PROBES="public DNS${CLOUDFLARE:+ (cloudflare=$CLOUDFLARE: if yes, probes include the CDN edge)}"; fi
printf '  %-14s %s\n' "ends" "$(date -d "@$END" '+%F %T %z') ($HOURS h)" "site" "$WWWROOT" \
  "probes" "$PROBES" \
  "php" "$PHPBIN (pool max_children $FPM_MAX; second FPM: ${PHPV2:-none})" "disk" "$DISK" \
  "db" "$DB_UNIT, sampling $([[ $DB_ENABLED == 1 ]] && echo on || echo "off ($DBNOTE)")" \
  "redis" "${REDIS:-none}" "cron log" "${CRONLOG:-none found (cron columns stay empty; --cronlog FILE)}"

if (( TEST )); then
  echo "== test run (one metrics sample, one TTFB cycle)"
  "$D/run.sh" metrics && "$D/run.sh" ttfb && "$D/run.sh" status
  echo "monitor.err:"; cat "$D/monitor.err" 2>/dev/null || echo "(empty)"
  rm -f -- "$D/state/jar"
fi

need() { command -v "$1" 2>/dev/null || echo "/usr/bin/$1"; }
FLOCK=$(need flock); TMO=$(need timeout); NICE=$(need nice); IONICE=$(need ionice)
# No MAILTO line: it would stay in the crontab after the monitor is gone (only marked lines are removed) and silence
# every job added below it later. Each line sends its own output to monitor.err or /dev/null instead.
BLOCK=$(cat <<EOF
* * * * * $FLOCK -n $D/state/m.lock $TMO -k 5 55 $NICE -n 10 $IONICE -c3 $D/run.sh metrics >>$D/monitor.err 2>&1 # MSC-MONITOR
*/5 * * * * $FLOCK -n $D/state/t.lock $TMO -k 5 240 $NICE -n 10 $D/run.sh ttfb >>$D/monitor.err 2>&1 # MSC-MONITOR
7 * * * * [ \$(date +\%s) -lt $(( END + 3600 )) ] || { rm -f -- $D/state/jar; c=\$(crontab -l) && printf '\%s\n' "\$c" | grep -vF '# MSC-MONITOR' | crontab -; } >/dev/null 2>&1 # MSC-MONITOR
EOF
)
echo "== crontab block (metrics every minute, TTFB every 5 min, watchdog removes all three 1 h after the end):"
printf '%s\n' "$BLOCK"

if (( INSTALL )); then
  cur=$(crontab -l 2>&1); rc=$?
  if (( rc != 0 )); then
    if [[ $cur == *"no crontab for"* ]]; then cur=""; else echo "crontab -l failed ($cur); nothing installed" >&2; exit 1; fi
  fi
  if [[ $cur == *"# MSC-MONITOR"* ]]; then echo "a monitor is already installed in this crontab; stop it first (run.sh stop)" >&2; exit 1; fi
  { [[ -n $cur ]] && printf '%s\n' "$cur"; printf '%s\n' "$BLOCK"; } | crontab - || { echo "crontab install failed" >&2; exit 1; }
  echo "== installed. crontab now has $(crontab -l | grep -cF '# MSC-MONITOR') monitor lines. Log this change in the operations log."
  echo "   status: $D/run.sh status    stop early: $D/run.sh stop"
else
  echo "== not installed (add --install-cron after the owner approved, or paste the block with crontab -e)."
fi
