#!/bin/bash
set +x
# night-checks.sh (maintenance module): read-only pre- and post-checks for a maintenance night. Prints one
# "key: value" line per check, saves them, and in "post" mode shows what changed against the "pre" file.
# Changes nothing on the server. Prints no secret (Redis is probed without a password: NOAUTH after the Redis step
# is the expected answer; Moodle's own Redis settings are checked by redis-check.php as the web user).
#
# Usage (with sudo, as the operator):
#   sudo bash night-checks.sh pre  [--backup-name NAME]
#   sudo bash night-checks.sh post [--rotation-dir /root/dbpw-rotation-<stamp> | --since "YYYY-MM-DD HH:MM:SS"] [--backup-name NAME]
#     --rotation-dir: the DB rotation's backup folder; its name is the time just before the ALTER, used as --since
#     --since: count DB "Access denied ... (using password: YES)" lines for the Moodle DB user after that time
#              (password: NO lines come from tools run without a password and are counted separately), plus the
#              Moodle DB user's connections and the password lines left in the operator's ~/.my.cnf (counts only)
# Files: ~/.cache/moodle-server-care/night-<pre|post>-<date>.txt of the operator (SUDO_USER).
set -uo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
MODE=${1:-}; [ $# -gt 0 ] && shift
SINCE=""; BNAME=moodle-backup
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE=${2:-}; shift 2 || shift ;;
    --rotation-dir)   # dbpw-rotation-YYYYmmddTHHMMSS -> "YYYY-mm-dd HH:MM:SS"
      SINCE=$(basename -- "${2:-}" | sed -nE 's/^dbpw-rotation-([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})$/\1-\2-\3 \4:\5:\6/p')
      [ -n "$SINCE" ] || { echo "--rotation-dir: expected a folder named dbpw-rotation-YYYYmmddTHHMMSS" >&2; exit 2; }
      shift 2 || shift ;;
    --backup-name) BNAME=${2:-moodle-backup}; shift 2 || shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in pre|post) ;; *) echo "usage: sudo bash $0 pre|post [--rotation-dir DIR | --since 'YYYY-MM-DD HH:MM:SS'] [--backup-name NAME]" >&2; exit 2 ;; esac
[[ -z $SINCE || $SINCE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]] || { echo "--since: YYYY-MM-DD HH:MM[:SS]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run it with sudo (it reads root-only state)" >&2; exit 2; }
OP_USER=${SUDO_USER:-root}; OP_HOME=$(getent passwd "$OP_USER" | cut -d: -f6)
ENVF="$OP_HOME/.config/moodle-server-care/server.env"
[ -r "$ENVF" ] || { echo "missing $ENVF: run detect-env.sh as the operator first" >&2; exit 2; }
envval() { sed -nE "s/^$1=(.*)$/\1/p" "$ENVF" | head -n 1 | sed -E "s/^'(.*)'$/\1/; s/\\\\(.)/\1/g"; }
MOODLE=$(envval MOODLE); DATAROOT=$(envval DATAROOT); SITE=$(envval SITE); PHPN=$(envval PHP); WEB=$(envval WEBUSER)
WEB=${WEB:-www-data}; PHP=$(command -v "${PHPN:-php}" || echo "/usr/bin/${PHPN:-php}")
OUTD="$OP_HOME/.cache/moodle-server-care"; mkdir -p "$OUTD"; chown "$OP_USER" "$OUTD" 2>/dev/null
OUT="$OUTD/night-$MODE-$(date +%F).txt"
HERE=$(cd "$(dirname -- "$0")" && pwd)

lines=()
kv() { lines+=("$1: $2"); printf '%-26s %s\n' "$1:" "$2"; }

echo "== night-checks $MODE $(date '+%F %T %Z') on $(hostname) =="
kv "time" "$(date '+%F %T %Z')"
kv "uptime" "$(uptime -p)"
kv "kernel" "$(uname -r) (newest installed: $(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1))"
kv "reboot-required" "$([ -f /var/run/reboot-required ] && echo yes || echo no)"
kv "failed units" "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
svcs=""
for s in nginx apache2 "${PHPN:-php}-fpm" mariadb mysql postgresql redis-server exim4 postfix cron fail2ban; do
  st=$(systemctl is-active "$s" 2>/dev/null); [ "$st" = inactive ] && ! systemctl cat "$s" >/dev/null 2>&1 && continue
  [ -z "$st" ] || [ "$st" = unknown ] || svcs+="$s=$st "
done
kv "services" "$svcs"
kv "listeners" "$(ss -Hltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ')"
kv "on replaced libraries" "$(grep -l '(deleted)' /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 | xargs -r ps -o comm= -p 2>/dev/null | sort -u | tr '\n' ' ')"
if command -v mariadb >/dev/null && systemctl is-active --quiet mariadb 2>/dev/null; then
  kv "db buffer pool load" "$(printf "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_load_status';\n" | mariadb --no-defaults -N -B 2>/dev/null | cut -f2)"
fi
if command -v redis-cli >/dev/null; then
  kv "redis PING (no password)" "$(printf 'PING\n' | timeout 5 redis-cli 2>&1 | head -n 1) (NOAUTH = password required)"
fi
if [ -n "$MOODLE" ] && [ -x "$PHP" ]; then
  kv "maintenance flag" "$([ -f "$DATAROOT/climaintenance.html" ] && echo "ON since $(stat -c %y "$DATAROOT/climaintenance.html" | cut -d. -f1)" || echo off)"
  v=$(cd / && runuser -u "$WEB" -- "$PHP" "$MOODLE/admin/cli/cfg.php" --name=version 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 1)
  kv "moodle CLI DB read" "$([[ $v =~ ^[0-9]{10} ]] && echo "ok (version $v)" || echo "FAILED")"
  if [ -f "$HERE/redis-check.php" ]; then
    # an unchecked mktemp would leave d empty and copy into / as root
    d=$(mktemp -d /tmp/msc-redischeck.XXXXXX) && [ -n "$d" ] && [ -d "$d" ] || { echo "mktemp failed" >&2; exit 2; }
    chmod 755 "$d"; cp "$HERE/redis-check.php" "$d/"; chmod 644 "$d/redis-check.php"
    rc_out=$(cd / && runuser -u "$WEB" -- "$PHP" "$d/redis-check.php" "$MOODLE/config.php" 2>&1); rc=$?; rm -rf "$d"
    case $rc in 0) kv "moodle redis settings" "ok ($(grep -c '^OK' <<<"$rc_out") target(s) PONG)" ;;
                3) kv "moodle redis settings" "not used" ;;
                *) kv "moodle redis settings" "FAILED: $(grep -E '^FAIL' <<<"$rc_out" | tr '\n' ';')" ;; esac
  fi
fi
if [ -n "$SITE" ]; then
  kv "login page (local)" "HTTP $(curl -s -o /dev/null -m 15 -w '%{http_code} %{time_starttransfer}s' --resolve "$SITE:443:127.0.0.1" "https://$SITE/login/index.php" 2>/dev/null)"
  kv "unknown host refused" "HTTP $(curl -s -o /dev/null -m 10 -w '%{http_code}' -H 'Host: unknown.invalid' http://127.0.0.1/ 2>/dev/null) (000/444 = refused by a default server)"
fi
if command -v exim >/dev/null; then kv "mail queue" "$(exim -bpc 2>/dev/null) message(s) (exim)"
elif command -v postqueue >/dev/null; then kv "mail queue" "$(postqueue -p 2>/dev/null | tail -n 1)"; fi
kv "apt-daily-upgrade next" "$(systemctl list-timers apt-daily-upgrade.timer --no-pager --no-legend 2>/dev/null | awk '{print $1,$2,$3}') (calendar: $(systemctl show apt-daily-upgrade.timer -p TimersCalendar --value 2>/dev/null | sed -nE 's/.*OnCalendar=([^;]*);.*/\1/p'))"
kv "backup timer" "$(systemctl is-enabled "$BNAME.timer" 2>/dev/null || echo not-installed) / service $(systemctl is-active "$BNAME.service" 2>/dev/null); next: $(systemctl list-timers "$BNAME.timer" --no-pager --no-legend 2>/dev/null | awk '{print $1,$2,$3}')"
kv "backup last ok" "$(sed -n 's/^last_ok=//p' "/var/lib/$BNAME/status" 2>/dev/null || echo -)"
if [ "$MODE" = post ] && [ -n "$SINCE" ]; then
  dbu=$(sed -nE "s/^[[:space:]]*\\\$CFG->dbuser[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/p" "$MOODLE/config.php" | head -n 1)
  if [[ $dbu =~ ^[A-Za-z0-9_]{1,80}$ ]]; then
    jl=$(journalctl -u mariadb -u mysql --since "$SINCE" --no-pager 2>/dev/null | grep -F "Access denied for user '$dbu'@" || true)
    nyes=$(grep -cF '(using password: YES)' <<<"$jl" || true); nno=$(grep -cF '(using password: NO)' <<<"$jl" || true)
    kv "db access denied since $SINCE" "$nyes with a password (expected 0); $nno without a password (tools, not Moodle)"
    if command -v mariadb >/dev/null; then
      le=$(printf 'SELECT @@log_error;\n' | mariadb --no-defaults -N -B 2>/dev/null)
      case "$le" in /*) kv "db error log" "$le (a file: the journal may not hold the lines above; check that file)" ;; esac
      nc=$(printf "SELECT COUNT(*) FROM information_schema.processlist WHERE user='%s';\n" "$dbu" | mariadb --no-defaults -N -B 2>/dev/null)
      kv "db connections (moodle user)" "${nc:-?} (expected > 0 once a page or cron ran)"
    fi
  else
    kv "db access denied since $SINCE" "skipped (dbuser not readable from config.php)"
  fi
  mc="$OP_HOME/.my.cnf"
  if [ -L "$mc" ]; then kv "operator ~/.my.cnf password lines" "symlink (check by hand)"
  elif [ -f "$mc" ]; then kv "operator ~/.my.cnf password lines" "$(grep -ciE '^[[:space:]]*pass' "$mc" || true) (expected 0 after the rotation; count only)"
  else kv "operator ~/.my.cnf password lines" "no file"; fi
fi
printf '%s\n' "${lines[@]}" > "$OUT"; chown "$OP_USER" "$OUT" 2>/dev/null
echo "saved: $OUT"
if [ "$MODE" = post ]; then
  PRE=$(ls -t "$OUTD"/night-pre-*.txt 2>/dev/null | head -n 1)
  if [ -n "$PRE" ]; then
    echo "== changed since $PRE (time/uptime lines omitted) =="
    diff <(grep -vE '^(time|uptime|login page)' "$PRE") <(grep -vE '^(time|uptime|login page)' "$OUT") | sed -n 's/^</  before:/p; s/^>/  after: /p' || true   # differences are the point, not an error
  fi
fi
exit 0
