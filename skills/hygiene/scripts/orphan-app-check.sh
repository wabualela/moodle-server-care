#!/bin/bash
# orphan-app-check.sh — read-only: everything on THIS server that still belongs to an app the owner says has moved to
# another server: DNS, last traffic, worker units (systemd/supervisor), cron lines, vhosts, certificates, deploy SSH
# keys (and when each key was last used), databases, Redis use, other apps that reference it, and the PHP-FPM pool it
# shares with other sites (which must NOT be touched).
#
# Usage: bash orphan-app-check.sh --dir APP_DIR --host APP_HOST [--host ANOTHER] [--key-hint WORD]
#   --key-hint  a word expected in the deploy key's comment (default: the last path component of --dir)
# Prints names, paths, counts and dates; never secrets. Reads .env only for DB_CONNECTION/DB_DATABASE/REDIS_HOST/
# QUEUE_CONNECTION, which are not secrets.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

DIR=""; HOSTS=(); HINT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2%/}"; shift ;;
    --host) HOSTS+=("$2"); shift ;;
    --key-hint) HINT="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac; shift
done
[ -n "$DIR" ] && [ ${#HOSTS[@]} -gt 0 ] || { echo "usage: $0 --dir APP_DIR --host APP_HOST [--host ...] [--key-hint WORD]" >&2; exit 2; }
HINT="${HINT:-$(basename "$DIR")}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
msc_webconf_dump > "$TMP/web.txt"
LOCAL_IPS=" $(msc_local_ips | tr '\n' ' ') "

msc_hr "DNS and traffic"
for h in "${HOSTS[@]}"; do
  ips=$(getent ahosts "$h" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  here=no; for ip in $ips; do case "$LOCAL_IPS" in *" $ip "*) here=yes ;; esac; done
  echo "  $h -> ${ips:-NXDOMAIN}  (points to this server: $here; behind a proxy/CDN this cannot be told from DNS)"
done
for lf in $(awk '/access_log|CustomLog/ {for (i=1;i<=NF;i++) if ($i ~ /^\//) {gsub(/;/,"",$i); print $i}}' "$TMP/web.txt" | sort -u); do
  for h in "${HOSTS[@]}"; do
    case "$lf" in *"$h"*|*"$(basename "$DIR")"*)
      echo "  access log $lf: $($SUDO stat -c '%s B, last written %y' "$lf" 2>/dev/null | cut -d. -f1)" ;;
    esac
  done
done | sort -u

msc_hr "worker processes and units"
grep -rlsF "$DIR" /etc/systemd/system /lib/systemd/system 2>/dev/null | grep -v '\.wants/' | while read -r u; do
  n=$(basename "$u")
  echo "  systemd $n: active=$(systemctl is-active "$n" 2>/dev/null) enabled=$(systemctl is-enabled "$n" 2>/dev/null) restarts=$(systemctl show -p NRestarts --value "$n" 2>/dev/null)"
done
$SUDO grep -rlsF "$DIR" /etc/supervisor 2>/dev/null | sed 's/^/  supervisor: /'
for p in /proc/[0-9]*; do
  c=$($SUDO readlink "$p/cwd" 2>/dev/null) || continue
  case "$c" in "$DIR"|"$DIR"/*) echo "  process ${p#/proc/} ($(cat "$p/comm" 2>/dev/null)) runs in $c" ;; esac
done | head -n 10

msc_hr "cron"
for u in $(msc_cron_users); do $SUDO crontab -l -u "$u" 2>/dev/null | grep -F "$DIR" | msc_redact_cron | sed "s#^#  crontab $u: #"; done
$SUDO grep -rsF "$DIR" /etc/crontab /etc/cron.d 2>/dev/null | msc_redact_cron | sed 's/^/  /'

msc_hr "web server"
awk -v d="$DIR" -v hs="${HOSTS[*]}" '
  /^# configuration file / { f = $4; sub(/:$/, "", f); next }
  { n = split(hs, H, " "); for (i = 1; i <= n; i++) if (index($0, H[i])) hit[f] = 1; if (index($0, d)) hit[f] = 1 }
  END { for (k in hit) print "  enabled config mentions it: " k }' "$TMP/web.txt"
while read -r f; do
  for h in "${HOSTS[@]}" "$DIR"; do $SUDO grep -qF "$h" "$f" 2>/dev/null && { echo "  disabled config mentions it: $f"; break; }; done
done < <(msc_webconf_disabled)
sock=$(awk -v d="$DIR" '/^# configuration file /{f=$4} index($0,d){hit[f]=1} /fastcgi_pass[[:space:]]+unix:/{s=$0; sub(/.*unix:/,"",s); sub(/;.*/,"",s); sk[f]=s} END{for (k in hit) if (k in sk) print sk[k]}' "$TMP/web.txt" | head -n 1)
if [ -n "$sock" ]; then
  users=$(awk -v s="$sock" '/^# configuration file /{f=$4} index($0,s){print f}' "$TMP/web.txt" | sort -u | wc -l)
  echo "  PHP-FPM socket used: $sock, referenced by $users enabled config file(s)"
  [ "$users" -gt 1 ] && echo "  -> SHARED pool: other sites use it. Do NOT stop, restart or remove this pool or its PHP version."
fi

msc_hr "certificates"
if $SUDO test -d "$MSC_LE_DIR/renewal"; then
  for c in $($SUDO ls "$MSC_LE_DIR/renewal/" 2>/dev/null | grep '\.conf$'); do
    n=${c%.conf}; pem="$MSC_LE_DIR/live/$n/cert.pem"
    san=" $($SUDO openssl x509 -in "$pem" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | sed 's/DNS://' | tr '\n' ' ') $n "
    for h in "${HOSTS[@]}"; do
      case "$san" in *" $h "*)
        echo "  certbot certificate '$n' covers $h, expires $($SUDO openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
        echo "    delete it only AFTER the vhost that uses it is disabled (nginx -t fails otherwise): certbot delete --cert-name $n" ;;
      esac
    done
  done
fi

msc_hr "deploy SSH keys (comment contains '$HINT' or 'deploy')"
for ak in $MSC_AUTH_KEYS_GLOB; do
  $SUDO test -f "$ak" || continue
  $SUDO grep -nF -e "$HINT" -e deploy "$ak" 2>/dev/null | while IFS=: read -r ln rest; do
    fp=$(printf '%s\n' "$rest" | $SUDO ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
    cm=$(printf '%s\n' "$rest" | awk '{print $NF}')
    last=$($SUDO journalctl --no-pager -o short-iso _COMM=sshd _COMM=sshd-session 2>/dev/null | grep -F "$fp" | tail -n 1 | awk '{print $1}')
    echo "  $ak line $ln: comment '$cm', fingerprint $fp, last accepted login in journal: ${last:-none in the journal}"
  done
done

msc_hr "data and services the app used"
if $SUDO test -f "$DIR/.env"; then
  for k in DB_CONNECTION DB_DATABASE REDIS_HOST QUEUE_CONNECTION CACHE_DRIVER CACHE_STORE SESSION_DRIVER; do
    v=$($SUDO grep -E "^$k=" "$DIR/.env" | tail -n 1 | cut -d= -f2- | tr -d '"'"'"'\r'); [ -n "$v" ] && echo "  .env $k=$v"
  done
  db=$($SUDO grep -E '^DB_DATABASE=' "$DIR/.env" | tail -n 1 | cut -d= -f2- | tr -d '"'"'"'\r')
  if [ -n "$db" ] && [ "${db#/}" = "$db" ] && { msc_have mariadb || msc_have mysql; }; then
    cli=$(command -v mariadb || command -v mysql)
    t=$($SUDO "$cli" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${db//\'/}'" 2>/dev/null)
    echo "  database '$db' on this server: ${t:-unknown} table(s)"
  fi
fi
$SUDO find "$DIR" -maxdepth 3 -name '*.sqlite' -printf '  sqlite %p: %s B, modified %TY-%Tm-%Td %TH:%TM (still written = something here still runs)\n' 2>/dev/null

msc_hr "other apps referencing it"
$SUDO find $(msc_app_roots) -maxdepth 3 -type f \( -name '.env' -o -name 'config.php' -o -name '*.conf' -o -name '*.json' \) ! -path "$DIR/*" 2>/dev/null \
  | xargs -r $SUDO grep -lsF -e "$DIR" $(printf -- '-e %s ' "${HOSTS[@]}") 2>/dev/null | head -n 10 | sed 's/^/  /'
echo
echo "Remove in this order (each step verified): worker -> cron line -> vhost (nginx -t, reload) -> certificate ->"
echo "archive the tree (tar, count entries) and move it out -> unit file + daemon-reload -> vhost file and logs ->"
echo "deploy key line (after the owner confirms a NEW SSH session still works). See references/orphaned-app.md."
