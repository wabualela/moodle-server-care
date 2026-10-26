#!/bin/bash
# secrets-perms.sh — read-only: find secret-bearing files and logs that any local account can read, and check that the
# process which must read them (the PHP-FPM pool user of that app, or the web user) still can. Prints modes, owners and
# a suggested fix. NEVER prints file contents.
#
# Usage: bash secrets-perms.sh [--all] [EXTRA_PATH ...]
#   --all   also list files that are fine (default: only EXPOSED / BROKEN / CHECK rows)
# Why: on shared boxes (other apps, dev tools, docker-group users, service accounts) a world-readable .env, cached
# config or cron log leaks DB passwords, API keys and personal data. The fix must keep the real reader working:
# change the GROUP first, then the mode, or the app starts failing (HTTP 500) between the two commands.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

ALL=0; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) EXTRA+=("$1") ;;
  esac; shift
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROOTS="$MSC_SCAN_ROOTS"
HOMES="${MSC_HOMES:-/root $(awk -F: '$6 ~ "^/home/" {print $6}' /etc/passwd)}"
SYSFILES="${MSC_SYSTEM_SECRETS:-/etc/exim4/passwd.client /etc/postfix/sasl_passwd /etc/msmtprc /etc/mysql/debian.cnf /etc/redis/redis.conf}"
SKIP_RE='/(vendor|node_modules|\.git|\.cache|\.npm|\.claude)/'
[ -n "${DATAROOT:-}" ] && SKIP_RE="$SKIP_RE|^${DATAROOT}/"

# --- map document roots to the PHP-FPM pool that serves them (nginx), then pool -> user:group ---
msc_webconf_dump | awk '
  /^# configuration file / { depth = 0; insrv = 0; next }
  {
    line = $0; sub(/#.*/, "", line)
    if (!insrv && line ~ /(^|[[:space:]])server[[:space:]]*\{/) { insrv = 1; sdepth = depth; root = ""; sock = "" }
    o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
    if (insrv && match(line, /(^|[[:space:]])root[[:space:]]+[^;]+;/)) { r = substr(line, RSTART, RLENGTH); sub(/.*root[[:space:]]+/, "", r); sub(/;.*/, "", r); if (root == "") root = r }
    if (insrv && match(line, /fastcgi_pass[[:space:]]+unix:[^;]+/)) { x = substr(line, RSTART, RLENGTH); sub(/.*unix:/, "", x); if (sock == "") sock = x }
    depth += o - c
    if (insrv && depth <= sdepth) { if (root != "" && sock != "") print root "\t" sock; insrv = 0 }
  }' | sort -u > "$TMP/root_sock.tsv"
: > "$TMP/pools.tsv"
for pool in $MSC_FPM_POOL_GLOB; do
  [ -f "$pool" ] || continue
  l=$(sed -nE 's/^listen[[:space:]]*=[[:space:]]*(\S+).*/\1/p' "$pool" | head -n 1)
  u=$(sed -nE 's/^user[[:space:]]*=[[:space:]]*(\S+).*/\1/p' "$pool" | head -n 1)
  g=$(sed -nE 's/^group[[:space:]]*=[[:space:]]*(\S+).*/\1/p' "$pool" | head -n 1)
  printf '%s\t%s\t%s\n' "${l#/var}" "$u" "${g:-$u}" >> "$TMP/pools.tsv"
done
reader_for() {  # path -> "user:group" of the FPM pool whose docroot contains the path's app; empty if none
  local p="$1" root sock app u g
  while IFS=$'\t' read -r root sock; do
    app="${root%/public}"; app="${app%/html}"
    case "$p" in "$app"/*|"$root"/*)
      IFS=$'\t' read -r _ u g < <(awk -F'\t' -v s="${sock#/var}" '$1==s' "$TMP/pools.tsv" | head -n 1)
      [ -n "${u:-}" ] && { printf '%s:%s\n' "$u" "$g"; return; } ;;
    esac
  done < "$TMP/root_sock.tsv"
}
webuser_rd() { printf '%s:%s\n' "$WEBUSER" "$(id -gn "$WEBUSER" 2>/dev/null || echo "$WEBUSER")"; }

# --- candidate files ---
{
  [ -n "${MOODLE:-}" ] && printf '%s\tmoodle-config\n' "$MOODLE/config.php"
  [ -n "${DATAROOT:-}" ] && printf '%s\tmoodle-muc-config\n' "$DATAROOT/muc/config.php"
  # Laravel apps
  $SUDO find $ROOTS -maxdepth 3 -name artisan -type f 2>/dev/null | while read -r a; do
    d=$(dirname "$a"); printf '%s\tlaravel-env\n%s\tlaravel-config-cache\n' "$d/.env" "$d/bootstrap/cache/config.php"
  done
  # generic secret file names under the web/app roots
  $SUDO find $ROOTS -maxdepth 4 -type f \( -name '.env' -o -name '.env.*' -o -name 'wp-config.php' -o -name '*.pem' \
      -o -name '*.key' -o -name '.my.cnf' -o -name '.pgpass' -o -name '.netrc' -o -name '.git-credentials' \
      -o -name 'rclone.conf' -o -name 'credentials' -o -name 'id_rsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' \) \
      ! -name '*.example' ! -name '*.sample' ! -name '*.dist' ! -name '.env.testing' 2>/dev/null \
    | grep -vE "$SKIP_RE" | sed 's/$/\tsecret-name/'
  for h in $HOMES; do
    for f in .my.cnf .pgpass .netrc .git-credentials .config/rclone/rclone.conf .aws/credentials; do
      printf '%s\thome-secret\n' "$h/$f"
    done
  done
  for f in $SYSFILES; do
    printf '%s\tsystem-secret\n' "$f"
  done
  # log files written by cron redirections (task output can contain personal data)
  for u in $(msc_cron_users); do
    $SUDO crontab -l -u "$u" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -oE '>>?[[:space:]]*/[^ ;&|]+' | sed -E 's/^>>?[[:space:]]*//' \
      | grep -v '^/dev/' | sed 's/$/\tcron-log/'
  done
  for e in "${EXTRA[@]}"; do printf '%s\textra\n' "$e"; done
} | sort -u -t$'\t' -k1,1 > "$TMP/cands.tsv"

# cron log directories: rotated siblings too
awk -F'\t' '$2=="cron-log"{print $1}' "$TMP/cands.tsv" | while read -r f; do
  d=$(dirname "$f"); $SUDO find "$d" -maxdepth 1 -type f 2>/dev/null | sed 's/$/\tcron-log/'
done | sort -u >> "$TMP/cands.tsv"

can_read() {  # user path -> yes/no/? (authoritative only as root)
  if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
    if $SUDO runuser -u "$1" -- test -r "$2" 2>/dev/null; then echo yes; else echo no; fi
  else echo "?"; fi
}

printf '%-8s %-5s %-24s %-7s %-22s %-7s %-20s %s\n' VERDICT MODE OWNER:GROUP NOBODY READER READER? KIND PATH
sort -u -t$'\t' -k1,1 "$TMP/cands.tsv" | while IFS=$'\t' read -r f kind; do
  $SUDO test -f "$f" || continue
  st=$($SUDO stat -c '%a %U:%G' "$f" 2>/dev/null) || continue
  mode=${st%% *}; og=${st#* }
  nob=$(can_read nobody "$f")
  rd=""; rcan="-"
  case "$kind" in
    home-secret|system-secret) ;;
    moodle-*|laravel-*|cron-log) rd=$(reader_for "$f"); [ -z "$rd" ] && rd=$(webuser_rd) ;;
    *) rd=$(reader_for "$f") ;;
  esac
  if [ -n "$rd" ]; then rcan=$(can_read "${rd%%:*}" "$f"); else rd="(owner only)"; fi
  verdict=OK
  [ "$nob" = yes ] && verdict=EXPOSED
  [ "$rcan" = no ] && verdict=BROKEN
  [ "$nob" = "?" ] && [ $(( 0${mode: -1} & 4 )) -ne 0 ] && verdict=CHECK
  if [ "$verdict" != OK ] || [ "$ALL" -eq 1 ]; then
    printf '%-8s %-5s %-24s %-7s %-22s %-7s %-20s %s\n' "$verdict" "$mode" "$og" "$nob" "$rd" "$rcan" "$kind" "$f"
    if [ "$verdict" = EXPOSED ]; then
      case "$kind:$rd" in
        system-secret:*) echo "         fix: check the package default first; usually chmod 640 with the service's group" ;;
        *"(owner only)") echo "         fix: chmod 600 '$f'   (only its owner needs it)" ;;
        *) echo "         fix: chgrp ${rd#*:} '$f' && chmod 640 '$f'   (group first; verify ${rd%%:*} still reads it)" ;;
      esac
    fi
  fi
done
echo
echo "NOBODY=yes means any local account can read the file (mode bits and every parent directory allow it)."
echo "READER is the PHP-FPM pool user:group that serves the app (from the web config), else the web user."
echo "After 'php artisan config:cache' or a deploy, re-run: rebuilt files get default modes (often 644)."
