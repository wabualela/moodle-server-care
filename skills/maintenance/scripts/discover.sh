#!/bin/bash
set +x
# discover.sh (maintenance module): read-only facts needed to plan one announced maintenance night: pending reboot
# and kernel, processes still on replaced libraries, unattended-upgrades schedule and origins, boot menu, provider,
# Redis and DB password state (presence only, never values), maintenance mode, backup timer, temporary sudo.
# Changes nothing. Prints no secret: config files are grepped for key NAMES and counts only.
#
# Usage: bash discover.sh [--backup-name NAME]   (default moodle-backup)
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
BNAME=moodle-backup
[ "${1:-}" = --backup-name ] && BNAME=${2:-moodle-backup}
# shellcheck source=lib-env.sh
. "$(dirname "$0")/lib-env.sh"
ENVF=$(msc_env_path)
[ -r "$ENVF" ] || { echo "missing $ENVF: run skills/start/scripts/detect-env.sh first"; exit 2; }
msc_parse_env "$ENVF" MOODLE DATAROOT SITE RELEASE || { echo "cannot use $ENVF (see above)"; exit 2; }
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"
say() { printf '%-30s %s\n' "$1" "$2"; }

echo "== maintenance discovery (read-only) $(date '+%F %T %Z') on $(hostname) =="
say "site / release" "${SITE:-?} / ${RELEASE:-?} (--enablelater exists in every supported Moodle)"
# --- reboot and kernel
RUNK=$(uname -r); NEWK=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1)
say "kernel running / newest" "$RUNK / ${NEWK:-?}"
if [ -f /var/run/reboot-required ]; then
  say "reboot-required" "yes since $(stat -c %y /var/run/reboot-required | cut -d. -f1): $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"
else say "reboot-required" "no"; fi
say "last boots" "$(last -x reboot 2>/dev/null | head -n 3 | awk '{print $5,$6,$7,$8}' | tr '\n' ';')"
if [ -n "$SUDO" ] || [ "$(id -u)" = 0 ]; then
  procs=$($SUDO grep -l '(deleted)' /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 | xargs -r ps -o comm= -p 2>/dev/null | sort | uniq -c | sort -rn | head -n 12 | awk '{printf "%s(%s) ", $2, $1}')
  say "on replaced libraries" "${procs:-none}"
  np=$(cat /run/nginx.pid 2>/dev/null); [ -n "$np" ] && say "nginx master old libssl" "$($SUDO grep -c 'libssl.*(deleted)\|libcrypto.*(deleted)' /proc/$np/maps 2>/dev/null) mappings (a reload does not fix this; restart or reboot)"
else say "on replaced libraries" "(needs sudo)"; fi
say "needrestart / checkrestart" "$(command -v needrestart || echo -) / $(command -v checkrestart || echo -)"
# --- unattended-upgrades
say "apt-daily-upgrade.timer" "$(systemctl show apt-daily-upgrade.timer -p TimersCalendar --value 2>/dev/null | sed -nE 's/.*OnCalendar=([^;]*);.*/\1/p') + $(systemctl show apt-daily-upgrade.timer -p RandomizedDelayUSec --value 2>/dev/null); drop-ins: $(systemctl show apt-daily-upgrade.timer -p DropInPaths --value 2>/dev/null)"
say "next upgrade run" "$(systemctl list-timers apt-daily-upgrade.timer --no-pager --no-legend 2>/dev/null | awk '{print $1,$2,$3}')"
say "unattended-upgrades" "$(systemctl is-active unattended-upgrades 2>/dev/null); $(grep -hE 'Unattended-Upgrade "|Update-Package-Lists' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | tr -s ' \n' ' ')"
UU=/etc/apt/apt.conf.d/50unattended-upgrades
if [ -r "$UU" ]; then
  say "  origins" "$(sed -n '/Origins-Pattern/,/};/p' "$UU" | grep -vE '^\s*//' | grep -oE '"[^"]+"' | tr '\n' ' ')"
  say "  blacklist entries" "$(sed -n '/Package-Blacklist/,/};/p' "$UU" | grep -vE '^\s*//' | grep -cE '^\s*"')"
  say "  Automatic-Reboot" "$(grep -E '^\s*Unattended-Upgrade::Automatic-Reboot\s' "$UU" | grep -oE '"[^"]+"' || echo 'not set (false)')"
fi
say "third-party repos" "$(grep -rhoE 'https?://[^ ]+' /etc/apt/sources.list.d/ 2>/dev/null | sort -u | tr '\n' ' ')"
say "upgrades restarted services" "$(zgrep -hE 'Restarting|restart' /var/log/unattended-upgrades/unattended-upgrades-dpkg.log* 2>/dev/null | grep -oE '(mariadb|mysql|nginx|apache2|php[0-9.]*-fpm|redis-server|postgresql)' | sort | uniq -c | tr -s ' \n' ' ' || echo '(log not readable)')"
# --- boot and provider
say "GRUB_TIMEOUT" "$(grep -hsE '^GRUB_TIMEOUT=' /etc/default/grub /etc/default/grub.d/*.cfg | tail -n 1) (0 = no boot menu: the snapshot is the kernel rollback)"
say "provider (dmi)" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
say "disk used (snapshot time)" "$(df -h --output=used / | tail -n 1 | tr -d ' ')"
say "time zone" "$(timedatectl show -p Timezone --value 2>/dev/null)"
# --- Moodle state
CONF="${MOODLE:-/nonexistent}/config.php"
if [ -r "$CONF" ] || [ -n "$SUDO" ]; then
  keys() { $SUDO grep -E "^\s*\\\$CFG->($1)\s*=" "$CONF" 2>/dev/null | sed -E 's/^\s*\$CFG->([a-z_]+).*/\1/' | sort | uniq -c | tr -s ' \n' ' '; }
  say "config.php session keys" "$(keys 'session_handler_class|session_redis_[a-z_]+') (names only)"
  dbh=$($SUDO sed -nE "s/^\s*\\\$CFG->dbhost\s*=\s*'([^']*)'.*/\1/p" "$CONF" | head -1)
  case "$dbh" in localhost|127.0.0.1|'') dbh=local ;; *) dbh="NOT local (rotation through the DB provider)" ;; esac
  say "config.php db keys" "dbtype=$($SUDO sed -nE "s/^\s*\\\$CFG->dbtype\s*=\s*'([^']*)'.*/\1/p" "$CONF" | head -1) dbhost=$dbh dbuser-set=$($SUDO grep -cE '^\s*\$CFG->dbuser\s*=' "$CONF") dbpass-lines=$($SUDO grep -c 'dbpass' "$CONF") (values not shown)"
fi
MUC="${DATAROOT:-/nonexistent}/muc/config.php"
if $SUDO test -r "$MUC" 2>/dev/null; then
  nr=$($SUDO grep -cE "^\s*'plugin' => 'redis'," "$MUC"); ne=$($SUDO grep -cE "^\s*'password' => '',\s*$" "$MUC")
  say "MUC redis stores" "$nr (empty 'password' entries in the file: $ne)"
fi
say "maintenance mode" "$([ -n "${DATAROOT:-}" ] && $SUDO test -f "$DATAROOT/climaintenance.html" && echo ON || echo off)"
# --- Redis
if command -v redis-cli >/dev/null; then
  pong=$(printf 'PING\n' | timeout 5 redis-cli 2>&1 | head -n 1)
  say "redis PING (no password)" "$pong $( [ "$pong" = PONG ] && echo '(no requirepass: candidate for set-redis-password.sh)' || echo '(password required or not running)')"
  if [ "$pong" = PONG ]; then
    say "redis version" "$(printf 'INFO server\n' | redis-cli 2>/dev/null | sed -nE 's/^redis_version:([0-9.]+).*/\1/p')"
    say "redis keyspace" "$(printf 'INFO keyspace\n' | redis-cli 2>/dev/null | grep -E '^db[0-9]+' | cut -d, -f1 | tr '\n' ' ')"
  fi
  [ -n "$SUDO" ] && say "redis clients (process)" "$($SUDO ss -Htnp state established '( dport = :6379 )' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | sed 's/users:(("//; s/"$//' | sort | uniq -c | tr -s ' \n' ' ')"
  say "other apps naming Redis" "$($SUDO grep -lsE '^REDIS_(HOST|PASSWORD|URL)=' /var/www/*/.env /srv/*/.env 2>/dev/null | tr '\n' ' ') (key names only)"
else say "redis" "redis-cli not installed (no local Redis?)"; fi
# --- operator option files (presence and mode only)
for f in "$HOME/.my.cnf" /root/.my.cnf; do $SUDO test -e "$f" 2>/dev/null && say "option file (not read)" "$f $($SUDO stat -c '%U %a' "$f")"; done
# --- DB logs that could record a password hash during a rotation (settings only, as root over the socket)
if command -v mariadb >/dev/null && { [ -n "$SUDO" ] || [ "$(id -u)" = 0 ]; }; then
  lg=$(printf 'SELECT @@slow_query_log, @@log_slow_admin_statements, @@long_query_time, @@general_log, @@log_bin, @@log_error;\n' \
       | $SUDO mariadb --no-defaults -N -B 2>/dev/null | tr '\t' ' ')
  [ -n "$lg" ] && say "db logs" "slow_query_log admin_stmts long_query_time general_log log_bin log_error = $lg (the rotation script switches the slow log off per session; general log / binlog would record the hash)"
fi
# --- remaining risk after a rotation: can the operator account (and so every Claude session) read config.php?
if [ -n "${MOODLE:-}" ]; then
  cst=$($SUDO stat -c '%U:%G %a' "$MOODLE/config.php" 2>/dev/null); cgrp=${cst#*:}; cgrp=${cgrp%% *}
  ingrp=no; id -nG 2>/dev/null | tr ' ' '\n' | grep -qx -- "$cgrp" && ingrp=yes
  say "config.php owner/mode" "${cst:-?}; operator $(id -un) in group $cgrp: $ingrp$( [ "$ingrp" = yes ] && echo ' (sessions can read the DB password without sudo: tell the owner, db-password.md section 9)')"
fi
# --- backup and sudo
say "backup timer $BNAME" "$(systemctl is-enabled $BNAME.timer 2>/dev/null || echo not-installed); next: $(systemctl list-timers $BNAME.timer --no-pager --no-legend 2>/dev/null | awk '{print $1,$2,$3}'); Persistent=$(systemctl show -p Persistent --value $BNAME.timer 2>/dev/null)"
say "backup last ok" "$(sed -n 's/^last_ok=//p' /var/lib/$BNAME/status 2>/dev/null || echo -)"
say "passwordless sudo" "$([ -n "$SUDO" ] && echo "yes for $(id -un)" || echo no); revoke timers: $(systemctl list-timers --all --no-pager --no-legend 2>/dev/null | grep -oE 'revoke[^ ]*' | tr '\n' ' ')"
say "failed units" "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
QH="$(cd "$(dirname "$0")/../.." && pwd)/audit/scripts/quiet-hours.sh"
[ -f "$QH" ] && say "quiet hours" "measure with: bash $QH" || say "quiet hours" "measure them (audit module) before choosing the night"
echo "== end =="
