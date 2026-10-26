#!/bin/bash
set +x
# render-install.sh: build the install tree for moodle-backup on THIS server, in a staging directory. Changes nothing on
# the system: it reads server.env and a few file existence checks, and writes only under --out. The output holds the
# two scripts, the three systemd units, /etc/default/<NAME> with this server's values, the docs and the owner setup
# scripts, plus INSTALL.txt with the exact, numbered install commands (each needs the owner's go-ahead).
#
# Usage: bash render-install.sh --backend sharepoint|s3 --at HH:MM --hard-stop HH:MM --out DIR [options]
#   --backend B        sharepoint (Microsoft 365 document library) or s3 (Cloudflare R2 / S3-compatible)
#   --at HH:MM         timer start, server local time (inside the measured quiet window)
#   --hard-stop HH:MM  no step starts after this; the unit kills the run 5 min later. Must end before the apt window
#   --out DIR          staging directory (new or empty)
#   --apt-at HH:MM     start of the unattended-upgrades window (default: read from apt-daily-upgrade.timer)
#   --name NAME        unit/file prefix (default moodle-backup); two sites on one server need two names
#   --set-prefix P     object name prefix (default moodle)
#   --weekly-dow N     weekly copy day, date +%u (default 5)
#   --letsencrypt yes|no  include /etc/letsencrypt (certificate private keys) in the encrypted bundle (default yes)
#   --handbook PATH / --log PATH   operator documents to include (default ~/SERVER-HANDBOOK.md, ~/SERVER-OPS-LOG.md)
#   --sqlite name=PATH (repeatable)  another app's SQLite DB to copy consistently every night (owner decision)
#   --extra PATH (repeatable)        another path for the bundle (owner decision)
#   --env FILE         server.env to read (default ~/.config/moodle-server-care/server.env)
set -euo pipefail
umask 022
HERE=$(cd "$(dirname -- "$0")" && pwd)
SKILL=$(cd "$HERE/.." && pwd)
# shellcheck source=lib-env.sh
. "$HERE/lib-env.sh"

ENVF=$(msc_env_path)
BACKEND_IN=""; AT=""; HARD=""; OUT=""; APT_AT=""; NAME=moodle-backup; SET_PREFIX=moodle; DOW=5; LE=yes
HANDBOOK="$HOME/SERVER-HANDBOOK.md"; OPSLOG="$HOME/SERVER-OPS-LOG.md"; SQLITE=(); EXTRA=()
die() { echo "render-install: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND_IN=${2:-}; shift 2 ;;
    --at) AT=${2:-}; shift 2 ;;
    --hard-stop) HARD=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --apt-at) APT_AT=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --set-prefix) SET_PREFIX=${2:-}; shift 2 ;;
    --weekly-dow) DOW=${2:-}; shift 2 ;;
    --letsencrypt) LE=${2:-}; shift 2 ;;
    --handbook) HANDBOOK=${2:-}; shift 2 ;;
    --log) OPSLOG=${2:-}; shift 2 ;;
    --sqlite) SQLITE+=("${2:-}"); shift 2 ;;
    --extra) EXTRA+=("${2:-}"); shift 2 ;;
    --env) ENVF=${2:-}; shift 2 ;;
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
case "$BACKEND_IN" in
  sharepoint|onedrive) BACKEND=onedrive; LABEL="SharePoint library"; RETMODE=apply; TPSH=8 ;;
  s3|r2) BACKEND=s3; LABEL="S3-compatible bucket"; RETMODE=check; TPSH=0 ;;
  *) die "--backend sharepoint|s3 is required" ;;
esac
re_hm='^([01][0-9]|2[0-3]):[0-5][0-9]$'
[[ $AT =~ $re_hm ]] || die "--at HH:MM is required"
[[ $HARD =~ $re_hm ]] || die "--hard-stop HH:MM is required"
[ -n "$OUT" ] || die "--out DIR is required"
[[ $NAME =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || die "--name: lowercase letters, digits, dashes"
[[ $SET_PREFIX =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--set-prefix: lowercase letters, digits, dashes"
[[ $DOW =~ ^[1-7]$ ]] || die "--weekly-dow 1-7"
case "$LE" in yes|no) ;; *) die "--letsencrypt yes|no" ;; esac
[ -r "$ENVF" ] || die "$ENVF not found: run skills/start/scripts/detect-env.sh first"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then die "$OUT exists and is not empty"; fi

# server.env holds non-secret facts written by detect-env.sh; parsed, never sourced
msc_parse_env "$ENVF" MOODLE DOCROOT DATAROOT DBTYPE DBNAME WEBUSER SITE || die "cannot use $ENVF (see above)"
for v in MOODLE DATAROOT DBTYPE DBNAME WEBUSER SITE; do [ -n "${!v:-}" ] || die "$v missing in $ENVF"; done
case "$DBTYPE" in mariadb|mysqli|auroramysql) ;; pgsql) die "dbtype pgsql is not supported by moodle-backup: stop and ask (references/design.md)";; *) die "dbtype '$DBTYPE' unknown";; esac

mins() { echo $(( 10#${1%%:*} * 60 + 10#${1##*:} )); }
TIMEOUT=$(( ( $(mins "$HARD") - $(mins "$AT") + 1440 ) % 1440 ))
[ "$TIMEOUT" -ge 30 ] && [ "$TIMEOUT" -le 240 ] || die "hard stop must be 30-240 min after --at (got $TIMEOUT)"
BUDGET=$(( TIMEOUT - 5 ))

if [ -z "$APT_AT" ]; then
  cal=$(systemctl show apt-daily-upgrade.timer -p TimersCalendar --value 2>/dev/null || true)
  APT_AT=$(sed -nE 's/.*OnCalendar=[^ ]* ([0-9]{1,2}):([0-9]{2}).*/\1:\2/p' <<<"$cal" | head -n 1)
  [[ $APT_AT =~ ^[0-9]: ]] && APT_AT="0$APT_AT"
fi
WARN=()
if [[ $APT_AT =~ $re_hm ]]; then
  gap=$(( ( $(mins "$APT_AT") - $(mins "$HARD") + 1440 ) % 1440 ))
  [ "$gap" -ge 5 ] && [ "$gap" -le 720 ] || WARN+=("the run can last until $HARD + 5 min but the apt window starts at $APT_AT: move one of them (maintenance module moves apt into the quiet window)")
else
  APT_AT="unknown"; WARN+=("could not read the apt-daily-upgrade window: check it by hand (systemctl cat apt-daily-upgrade.timer)")
fi

DB_UNIT=""
for u in mariadb.service mysql.service mysqld.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then DB_UNIT=$u; break; fi
done
TZN=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)

# ---------------------------------------------------------------- bundle paths (only what exists now)
cands=()
[ "${DOCROOT:-$MOODLE}" = "$MOODLE" ] || cands+=("$DOCROOT/config.php")
cands+=(/etc/nginx /etc/apache2 /etc/httpd /etc/php /etc/mysql /etc/my.cnf /etc/my.cnf.d /etc/postgresql
        /etc/exim4 /etc/default/exim4 /etc/postfix /etc/aliases /etc/mailname /etc/redis
        /etc/systemd/system /etc/logrotate.d /etc/cron.d /etc/fail2ban/jail.d /etc/fail2ban/jail.local /etc/ufw
        /etc/apt/apt.conf.d /etc/apt/sources.list.d /etc/sysctl.d /etc/security/limits.d /etc/ssh/sshd_config.d
        /etc/sudoers.d /var/spool/cron/crontabs)
[ "$LE" = no ] || cands+=(/etc/letsencrypt)
CP=()
for p in "${cands[@]}"; do [ -e "$p" ] && CP+=("$p"); done
CP+=("/etc/default/$NAME" /usr/local/sbin "/usr/local/share/$NAME")   # created by the install itself
for p in "$HANDBOOK" "$OPSLOG"; do if [ -e "$p" ]; then CP+=("$p"); else WARN+=("operator document $p not found: not in the bundle"); fi; done
for s in "${SQLITE[@]}"; do
  [[ $s =~ ^[A-Za-z0-9_-]+=/.+ ]] || die "--sqlite expects name=/absolute/path"
  [ -f "${s#*=}" ] || WARN+=("SQLite file ${s#*=} not found now")
done
for e in "${EXTRA[@]}"; do [ -e "$e" ] || WARN+=("extra path $e not found now"); done
q() { printf '%q' "$1"; }
cp_block=$(for p in "${CP[@]}"; do printf '  %s\n' "$(q "$p")"; done)
sq_block=$(for s in "${SQLITE[@]}"; do printf '%s ' "$(q "$s")"; done)
ex_block=$(for e in "${EXTRA[@]}"; do printf '%s ' "$(q "$e")"; done)

# ---------------------------------------------------------------- render
mkdir -p "$OUT/usr/local/sbin" "$OUT/etc/systemd/system" "$OUT/etc/default" "$OUT/usr/local/share/$NAME"
render() {  # render <template> <target>
  python3 -I - "$1" "$2" <<'PY' \
    "NAME=$NAME" "SITE=$SITE" "BACKEND=$BACKEND" "BACKEND_LABEL=$LABEL" "DB_UNIT=$DB_UNIT" "AT=$AT" \
    "HARD_STOP=$HARD" "TIMEOUT_MIN=$TIMEOUT" "BUDGET_MIN=$BUDGET" "APT_AT=$APT_AT" "SET_PREFIX=$SET_PREFIX" \
    "MOODLE=$(q "$MOODLE")" "DATAROOT=$(q "$DATAROOT")" "DBTYPE=$(q "$DBTYPE")" "DBNAME=$(q "$DBNAME")" \
    "WEBUSER=$(q "$WEBUSER")" "WEEKLY_DOW=$DOW" "HC_CRON=$((10#${AT##*:})) $((10#${AT%%:*})) * * *" "TZ=$TZN" \
    "RETENTION_MODE=$RETMODE" "TPSLIMIT_HINT=$TPSH" "SQLITE_DBS=${sq_block% }" "CONFIG_PATHS=$cp_block" \
    "EXTRA_PATHS=${ex_block% }" "RENDERED=$(date '+%F %T %Z')"
import sys
src, dst = sys.argv[1], sys.argv[2]
vals = dict(a.split("=", 1) for a in sys.argv[3:])
t = open(src).read()
for k, v in vals.items():
    t = t.replace("@" + k + "@", v)
if "@" in t.replace("@example.org", ""):
    import re
    left = sorted(set(re.findall(r"@[A-Z_]+@", t)))
    if left:
        sys.exit("unreplaced placeholders in %s: %s" % (src, left))
open(dst, "w").write(t)
PY
}
render "$SKILL/assets/moodle-backup.service.in"       "$OUT/etc/systemd/system/$NAME.service"
render "$SKILL/assets/moodle-backup.timer.in"         "$OUT/etc/systemd/system/$NAME.timer"
render "$SKILL/assets/moodle-backup-alert.service.in" "$OUT/etc/systemd/system/$NAME-alert.service"
render "$SKILL/assets/moodle-backup.default.in"       "$OUT/etc/default/$NAME"
[ -n "$DB_UNIT" ] || sed -i 's/^After=network-online.target  apt/After=network-online.target apt/' "$OUT/etc/systemd/system/$NAME.service"
install -m 0700 "$HERE/moodle-backup" "$OUT/usr/local/sbin/$NAME"
install -m 0700 "$HERE/moodle-backup-retention" "$OUT/usr/local/sbin/$NAME-retention"
for f in owner-setup-sharepoint.sh owner-setup-s3.sh; do install -m 0644 "$HERE/$f" "$OUT/usr/local/share/$NAME/$f"; done
for f in design.md install.md restore-tests.md; do install -m 0644 "$SKILL/references/$f" "$OUT/usr/local/share/$NAME/$f"; done
case "$BACKEND" in
  onedrive) install -m 0644 "$SKILL/references/owner-steps-sharepoint-ar.md" "$OUT/usr/local/share/$NAME/" ;;
  s3) install -m 0644 "$SKILL/references/owner-steps-s3-ar.md" "$OUT/usr/local/share/$NAME/" ;;
esac
cat > "$OUT/usr/local/share/$NAME/README.md" <<EOF
# $NAME on this server ($SITE)

Nightly encrypted off-provider backup (moodle-server-care, skills/backup), backend: $LABEL.
Rendered $(date '+%F %T %Z'). Timer $AT (+0-5 min), hard stop $HARD (+5 min), apt window $APT_AT.

- Settings: /etc/default/$NAME (root 0600). Secrets: only /var/lib/$NAME/rclone/rclone.conf (root 0600, dir 0700).
- Status without sudo: cat /var/lib/$NAME/status ; whole last run: /var/lib/$NAME/last-run.log
- Checks: sudo /usr/local/sbin/$NAME --preflight ; sudo /usr/local/sbin/$NAME-retention --check
- Design: design.md. Install, operations, rollback: install.md. Restore tests and real restores: restore-tests.md.
- Owner steps (Arabic) and the owner's setup script are in this folder; the setup script holds no secret.
EOF
for f in "$OUT/usr/local/sbin/$NAME" "$OUT/usr/local/sbin/$NAME-retention" "$OUT/usr/local/share/$NAME"/*.sh; do bash -n "$f"; done

cat > "$OUT/INSTALL.txt" <<EOF
Install of $NAME on $(hostname) for $SITE (rendered $(date '+%F %T %Z')). Each numbered step needs the owner's go-ahead;
log every change in the operations log. Staging: $OUT
Backend $BACKEND; timer $AT (+0-5 min); hard stop $HARD; unit timeout ${TIMEOUT} min; apt window $APT_AT; tz $TZN.

0. Read-only pre-checks
   sudo stat -c '%U %a %n' /var/lib/$NAME/rclone /var/lib/$NAME/rclone/rclone.conf   # root 700 / root 600 (after the owner setup)
   ls /usr/local/sbin/$NAME* /etc/systemd/system/$NAME* /etc/default/$NAME 2>&1           # must not exist yet
   df -h /var/backups
1. Install (new files only; the timer stays disabled)
   sudo install -o root -g root -m 0700 $OUT/usr/local/sbin/$NAME $OUT/usr/local/sbin/$NAME-retention /usr/local/sbin/
   sudo install -d -o root -g root -m 0755 /usr/local/share/$NAME
   sudo install -o root -g root -m 0644 $OUT/usr/local/share/$NAME/* /usr/local/share/$NAME/
   sudo install -o root -g root -m 0600 $OUT/etc/default/$NAME /etc/default/$NAME
   sudo install -o root -g root -m 0644 $OUT/etc/systemd/system/$NAME.service $OUT/etc/systemd/system/$NAME.timer $OUT/etc/systemd/system/$NAME-alert.service /etc/systemd/system/
   sudo install -d -o root -g root -m 0700 /var/backups/$NAME
   sudo systemd-analyze verify /etc/systemd/system/$NAME.service /etc/systemd/system/$NAME.timer /etc/systemd/system/$NAME-alert.service
   sudo systemctl daemon-reload
   sha256sum /usr/local/share/$NAME/owner-setup-*.sh     # give these values to the owner: he runs the script as root and
                                                         # compares the hash first (never from a folder Claude can write)
2. Owner: the setup script in his own SSH session (owner steps, Arabic), then HC_URL with sudoedit /etc/default/$NAME
3. sudo /usr/local/sbin/$NAME --preflight        # expect OK everywhere except "no filedir mirror state"
4. Seed (first full upload) outside the timer window: references/install.md step 4 (systemd-run with the unit sandbox)
5. Dry run at night under the same sandbox: references/install.md step 5
6. First real run (owner go-ahead at that moment): sudo systemctl start --no-block $NAME.service, then poll
   systemctl show -p ActiveState,SubState,Result $NAME.service every 1-2 min until inactive (a blocking start outlives
   a Claude tool call, which stops waiting after 10 min); Result=success ; cat /var/lib/$NAME/status
7. Verify: references/install.md step 7, restore-tests.md section A
8. Enable: sudo /usr/local/sbin/$NAME --preflight && sudo systemctl enable --now $NAME.timer
   (SharePoint: only after the owner's Purview folder test printed "rmdir OK", owner steps 4.4)
Rollback: sudo systemctl disable --now $NAME.timer  (full removal: references/install.md "Rollback")
EOF
echo "== rendered into $OUT =="
find "$OUT" -type f | sort | sed "s#^$OUT/#  #"
echo "backend=$BACKEND timer=$AT hard_stop=$HARD timeout=${TIMEOUT}min apt=$APT_AT db_unit=${DB_UNIT:-none} tz=$TZN"
echo "bundle paths (${#CP[@]}):"; printf '  %s\n' "${CP[@]}"
if [ "${#WARN[@]}" -gt 0 ]; then echo "WARNINGS:"; printf '  - %s\n' "${WARN[@]}"; fi
echo "next: read $OUT/INSTALL.txt; nothing was installed."
