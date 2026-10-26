#!/bin/bash
set +x
# discover.sh (backup module): read-only facts needed to plan the nightly off-provider backup of this Moodle site.
# Prints sizes, counts, tools, schedules and existing backup traces. Changes nothing; prints no secret (rclone configs
# and option files are only stat'ed, never read; DB access is root over the socket, counts only).
#
# Usage: bash discover.sh [--quick] [--name NAME]
#   --quick   skip the slow parts (filedir file count, code size)
#   --name    backup unit prefix to look for (default moodle-backup)
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
QUICK=0; NAME=moodle-backup
while [ $# -gt 0 ]; do
  case "$1" in --quick) QUICK=1; shift ;; --name) NAME=${2:-moodle-backup}; shift 2 ;; *) echo "usage: $0 [--quick] [--name NAME]" >&2; exit 2 ;; esac
done
# shellcheck source=lib-env.sh
. "$(dirname "$0")/lib-env.sh"
ENVF=$(msc_env_path)
[ -r "$ENVF" ] || { echo "missing $ENVF: run skills/start/scripts/detect-env.sh first"; exit 2; }
msc_parse_env "$ENVF" MOODLE DATAROOT SITE RELEASE DBTYPE DBNAME HANDBOOK OPS_LOG || { echo "cannot use $ENVF (see above)"; exit 2; }
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"
say() { printf '%-28s %s\n' "$1" "$2"; }
need() { [ -n "$SUDO" ] || [ "$(id -u)" = 0 ]; }

echo "== backup discovery (read-only) $(date '+%F %T %Z') on $(hostname) =="
say "site / release" "${SITE:-?} / ${RELEASE:-?}"
say "moodle / dataroot" "${MOODLE:-?} / ${DATAROOT:-?}"
say "db" "${DBTYPE:-?} ${DBNAME:-?}"
case "${DBTYPE:-}" in pgsql) say "STOP" "PostgreSQL: moodle-backup dumps MariaDB/MySQL only. Stop and ask (references/design.md, PostgreSQL)";; esac

# --- tools
RV=$(rclone version 2>/dev/null | sed -n 1p)
say "rclone" "${RV:-NOT INSTALLED (apt install rclone; owner approval: a package install)}"
if [ -n "$RV" ]; then
  for b in onedrive s3 crypt; do rclone help backend "$b" >/dev/null 2>&1 && say "  backend $b" "available" || say "  backend $b" "MISSING"; done
fi
for t in zstd mariadb-dump mysqldump python3 curl flock setpriv git sendmail; do
  p=$(command -v "$t" 2>/dev/null); say "tool $t" "${p:-missing}"
done
say "time zone" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
say "apt-daily-upgrade" "$(systemctl show apt-daily-upgrade.timer -p TimersCalendar --value 2>/dev/null | sed -nE 's/.*OnCalendar=([^;]*);.*/\1/p') + $(systemctl show apt-daily-upgrade.timer -p RandomizedDelayUSec --value 2>/dev/null) random"
say "MTA" "$(for s in exim4 postfix; do systemctl is-active --quiet $s 2>/dev/null && printf '%s ' $s; done)"
say "provider (dmi)" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null) (backups must go to ANOTHER provider)"

# --- DB size (root over the socket; counts only)
if need && [ "${DBTYPE:-}" != pgsql ]; then
  CLI=mariadb; command -v mariadb >/dev/null || CLI=mysql
  q="SELECT COUNT(*), ROUND(SUM(data_length+index_length)/1024/1024/1024,2), SUM(engine<>'InnoDB') FROM information_schema.tables WHERE table_schema='${DBNAME:-x}' AND table_type='BASE TABLE'"
  r=$(printf '%s;\n' "$q" | $SUDO "$CLI" -N -B 2>/dev/null | tr '\t' ' ')
  if [ -n "$r" ]; then
    read -r n gb noninno <<<"$r"
    say "db tables / size GB" "$n / $gb (non-InnoDB tables: ${noninno:-?}; must be 0 for a consistent --single-transaction dump)"
  else
    say "db" "root cannot query over the socket: a DB_DEFAULTS_FILE (owner) will be needed"
  fi
  say "db server" "$(printf 'SELECT VERSION();\n' | $SUDO "$CLI" -N -B 2>/dev/null)"
else
  say "db" "(skipped: needs sudo, or pgsql)"
fi

# --- moodledata
if [ -n "${DATAROOT:-}" ] && need; then
  say "filedir size" "$($SUDO du -sh "$DATAROOT/filedir" 2>/dev/null | cut -f1)"
  if [ "$QUICK" = 0 ]; then
    say "filedir files" "$($SUDO find "$DATAROOT/filedir" -type f 2>/dev/null | wc -l)"
    say "filedir top folders" "$($SUDO find "$DATAROOT/filedir" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l) (each costs one Graph call per full listing on SharePoint)"
    say "filedir new in 30 days" "$($SUDO find "$DATAROOT/filedir" -type f -mtime -30 -printf '%s\n' 2>/dev/null | awk '{n++; s+=$1} END {printf "%d files, %.0f MB", n, s/1048576}')"
    say "largest file" "$($SUDO find "$DATAROOT/filedir" -type f -printf '%s\n' 2>/dev/null | sort -n | tail -n 1 | awk '{printf "%.0f MB", $1/1048576}')"
  fi
  for d in secret muc lang cache localcache temp sessions trashdir lock; do
    [ -e "$DATAROOT/$d" ] && say "  moodledata/$d" "$($SUDO du -sh "$DATAROOT/$d" 2>/dev/null | cut -f1)"
  done
fi
if [ -n "${MOODLE:-}" ] && [ "$QUICK" = 0 ]; then
  say "code size (no .git)" "$($SUDO du -sh --exclude=.git "$MOODLE" 2>/dev/null | cut -f1)"
fi
say "free on /var/backups" "$(df -h --output=avail /var/backups 2>/dev/null | tail -n 1 | tr -d ' ')"

# --- existing backups and configs (names, sizes, modes only)
say "backup units" "$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'backup' | tr '\n' ' ')"
say "$NAME installed" "$([ -e /usr/local/sbin/$NAME ] && echo yes || echo no); timer: $(systemctl is-enabled $NAME.timer 2>/dev/null || echo not-installed)"
for f in /root/.config/rclone/rclone.conf /var/lib/*/rclone/rclone.conf "$HOME/.config/rclone/rclone.conf"; do
  $SUDO test -e "$f" 2>/dev/null && say "rclone config (not read)" "$f $($SUDO stat -c '%U %a %s B %y' "$f" 2>/dev/null)"
done
if need; then
  say "cron backup lines" "$($SUDO grep -RilE 'backup|dump|rclone|rsync' /etc/cron.d /var/spool/cron/crontabs 2>/dev/null | tr '\n' ' ')"
  say "local dumps (names)" "$($SUDO find /root /var/backups /home -maxdepth 3 -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.sql.zst' -o -name '*.tar' -o -name '*.tar.gz' \) -size +50M -printf '%p(%s) ' 2>/dev/null | head -c 1500)"
fi
say "letsencrypt" "$([ -d /etc/letsencrypt ] && echo present || echo absent)"
say "other apps' SQLite" "$($SUDO find /var/www /srv -maxdepth 5 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name 'database.sqlite' \) -printf '%p(%s) ' 2>/dev/null | head -c 1500)"
# Handbook and operations log: server.env (HANDBOOK/OPS_LOG, when detect-env.sh writes them), the files the CLAUDE.md
# pointers name (older servers use other names), then the default names.
docs=""
for c in "$HOME/.claude/CLAUDE.md" /etc/claude-code/CLAUDE.md; do
  [ -r "$c" ] && docs="$docs $(grep -oE '(~|/home/[A-Za-z0-9._-]+|/root)/[A-Za-z0-9._-]+\.md' "$c" | sed "s#^~#$HOME#" | grep -viE '/CLAUDE\.md$|/MEMORY\.md$' | tr '\n' ' ')"
done
say "handbook / log" "$(for f in ${HANDBOOK:-} ${OPS_LOG:-} $docs "$HOME"/SERVER-HANDBOOK.md "$HOME"/SERVER-OPS-LOG.md; do [ -f "$f" ] && echo "$f"; done | sort -u | tr '\n' ' ')"
QH="$(cd "$(dirname "$0")/../.." && pwd)/audit/scripts/quiet-hours.sh"
[ -f "$QH" ] && say "quiet hours" "measure with: bash $QH" || say "quiet hours" "measure them (audit module) before choosing the timer"
echo "== end =="
