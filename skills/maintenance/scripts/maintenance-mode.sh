#!/usr/bin/env bash
set +x
# maintenance-mode.sh: Moodle CLI maintenance mode for a maintenance night, with verification at every step.
# Part of moodle-server-care (skills/maintenance). Uses Moodle's own admin/cli/maintenance.php as the web user.
#
#   sudo bash maintenance-mode.sh status            read-only: on/off, scheduled time, HTTP code of the login page
#   sudo bash maintenance-mode.sh schedule N        countdown banner now, CLI maintenance in N minutes (--enablelater=N)
#   sudo bash maintenance-mode.sh confirm           after the scheduled time: make sure it is on (trigger, else --enable)
#   sudo bash maintenance-mode.sh enable            CLI maintenance now
#   sudo bash maintenance-mode.sh disable           off (also clears a pending schedule)
# Options: --moodle DIR  --php php8.x  --web-user USER  --site HOST (defaults from the operator's server.env)
#
# How --enablelater works (Moodle core, lib/setup.php): it stores config maintenance_later = now + N min. Until then
# every page shows a red "maintenance in X minutes" banner. The FIRST request after that time (a web page or a CLI
# script such as cron) switches the site to CLI maintenance (moodledata/climaintenance.html). If nothing requests a
# page, nothing switches: that is why "confirm" triggers it with a harmless CLI read and falls back to --enable.
# maintenance.php exits 0 even when it refuses ("already enabled"), so this script checks the state, not exit codes.
set -u -o pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" != 0 ] && [ "${MMS_TEST:-0}" = 1 ]; then TEST=1; else TEST=0; for v in $(compgen -v MMS_); do unset "$v"; done; fi
CMD=${1:-status}; [ $# -gt 0 ] && shift
N=""
if [ "$CMD" = schedule ]; then N=${1:-}; [ $# -gt 0 ] && shift; fi
OPT_MOODLE=""; OPT_PHP=""; OPT_WEB=""; OPT_SITE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --moodle) OPT_MOODLE=${2:-}; shift 2 || shift ;;
    --php) OPT_PHP=${2:-}; shift 2 || shift ;;
    --web-user) OPT_WEB=${2:-}; shift 2 || shift ;;
    --site) OPT_SITE=${2:-}; shift 2 || shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
OP_USER=${SUDO_USER:-}; [ "$OP_USER" = root ] && OP_USER=""
OP_HOME=""; [ -n "$OP_USER" ] && OP_HOME=$(getent passwd "$OP_USER" | cut -d: -f6)
envval() { [ -n "$OP_HOME" ] && [ -r "$OP_HOME/.config/moodle-server-care/server.env" ] || return 0
  sed -nE "s/^$1=(.*)$/\1/p" "$OP_HOME/.config/moodle-server-care/server.env" | head -n 1 | sed -E "s/^'(.*)'$/\1/; s/\\\\(.)/\1/g"; }
[ "$TEST" = 1 ] && envval() { :; }
MOODLE=${MMS_MOODLE:-${OPT_MOODLE:-$(envval MOODLE)}}
WEB=${MMS_WEB:-${OPT_WEB:-$(envval WEBUSER)}}; WEB=${WEB:-www-data}
PHPNAME=${OPT_PHP:-$(envval PHP)}; PHPNAME=${PHPNAME:-php}
PHP=${MMS_PHP:-$(command -v "$PHPNAME" 2>/dev/null || echo "/usr/bin/$PHPNAME")}
SITE=${OPT_SITE:-$(envval SITE)}
RUNUSER=${MMS_RUNUSER:-/usr/sbin/runuser}
CURL=${MMS_CURL:-$(command -v curl 2>/dev/null || echo /usr/bin/curl)}

die() { echo "maintenance-mode: $*" >&2; exit 1; }
[ "$TEST" = 1 ] || [ "$(id -u)" = 0 ] || die "run it with sudo"
[ -n "$MOODLE" ] && [ -f "$MOODLE/config.php" ] || die "Moodle directory unknown or without config.php (pass --moodle DIR)"
[ -x "$PHP" ] || die "PHP CLI $PHP not found (pass --php php8.x)"
DATAROOT=$(sed -nE "s/^[[:space:]]*\\\$CFG->dataroot[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/p" "$MOODLE/config.php" | head -n 1)
[ -n "$DATAROOT" ] || die "no plain \$CFG->dataroot line in config.php"
FLAG="$DATAROOT/climaintenance.html"
CLI="$MOODLE/admin/cli"

asweb() { (cd / && "$RUNUSER" -u "$WEB" -- "$PHP" "$@"); }
later() {   # epoch of a pending schedule, or empty
  local v; v=$(asweb "$CLI/cfg.php" --name=maintenance_later 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 1)
  [[ $v =~ ^[0-9]{9,}$ ]] && echo "$v" || true
}
http_code() {
  [ -n "$SITE" ] || { echo "-"; return; }
  "$CURL" -s -o /dev/null -m 15 -w '%{http_code}' --resolve "$SITE:443:127.0.0.1" "https://$SITE/login/index.php" 2>/dev/null || echo "?"
}
state() {
  if [ -f "$FLAG" ]; then echo "ON (CLI maintenance since $(stat -c '%y' "$FLAG" | cut -d. -f1))"
  else
    local l; l=$(later)
    if [ -n "$l" ]; then echo "SCHEDULED for $(date -d "@$l" '+%F %T %Z') (banner shown now)"; else echo "OFF"; fi
  fi
}

case "$CMD" in
  status)
    echo "moodle:   $MOODLE"
    echo "state:    $(state)"
    echo "login:    HTTP $(http_code) (503 = maintenance page; via 127.0.0.1)"
    ;;
  schedule)
    [[ $N =~ ^[1-9][0-9]{0,2}$ ]] || die "schedule N: N = minutes (1-999)"
    [ ! -f "$FLAG" ] || die "CLI maintenance is already ON: nothing to schedule (disable first if that was a mistake)"
    before=$(date +%s)
    asweb "$CLI/maintenance.php" --enablelater="$N" | sed 's/^/  moodle: /'
    l=$(later)
    [ -n "$l" ] || die "no maintenance_later stored: the schedule did not take (check the output above)"
    d=$(( l - before - N * 60 ))
    [ "$d" -ge -5 ] && [ "$d" -le 60 ] || die "maintenance_later is $(date -d "@$l" '+%T'), not about $N min from now: check by hand"
    echo "OK scheduled: banner visible now, CLI maintenance from $(date -d "@$l" '+%F %T %Z') (first request after that, or 'confirm')"
    echo "   cancel before then: sudo bash $0 disable"
    ;;
  confirm)
    if [ -f "$FLAG" ]; then echo "OK $(state)"; exit 0; fi
    l=$(later)
    if [ -n "$l" ] && [ "$l" -gt "$(date +%s)" ]; then die "the scheduled time $(date -d "@$l" '+%T') has not come yet; wait, or use 'enable'"; fi
    # a harmless CLI read boots lib/setup.php, which applies a due maintenance_later (same path as the first request)
    asweb "$CLI/cfg.php" --name=version >/dev/null 2>&1 || true
    if [ -f "$FLAG" ]; then echo "OK switched on by the due schedule: $(state)"; exit 0; fi
    echo "  schedule did not switch it on (none pending, or no trigger): falling back to --enable"
    asweb "$CLI/maintenance.php" --enable | sed 's/^/  moodle: /'
    [ -f "$FLAG" ] && echo "OK $(state)" || die "CLI maintenance is still OFF: check $FLAG and the output above"
    ;;
  enable)
    if [ -f "$FLAG" ]; then echo "OK already $(state)"; exit 0; fi
    asweb "$CLI/maintenance.php" --enable | sed 's/^/  moodle: /'
    [ -f "$FLAG" ] && echo "OK $(state)" || die "CLI maintenance is still OFF"
    ;;
  disable)
    asweb "$CLI/maintenance.php" --disable | sed 's/^/  moodle: /'
    [ ! -f "$FLAG" ] || die "climaintenance.html still present"
    [ -z "$(later)" ] || die "a maintenance_later schedule is still stored"
    echo "OK OFF; login page HTTP $(http_code)"
    ;;
  *) die "usage: $0 status | schedule N | confirm | enable | disable [--moodle DIR] [--php php8.x] [--web-user U] [--site HOST]" ;;
esac
