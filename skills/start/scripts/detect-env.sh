#!/bin/bash
# detect-env.sh — read-only discovery of a Moodle production server for the moodle-server-care plugin.
# Prints a summary and writes NON-SECRET facts to ~/.config/moodle-server-care/server.env.
# It never prints passwords, tokens or DB credentials, and changes nothing on the system.
#
# Usage: bash detect-env.sh [MOODLE_DIR]
#   MOODLE_DIR  the directory holding Moodle's config.php (asked for when several sites are found)
set -uo pipefail
set +x

OUT_DIR="$HOME/.config/moodle-server-care"
OUT="$OUT_DIR/server.env"
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

say() { printf '%-22s %s\n' "$1" "$2"; }
cfgval() {  # cfgval FILE KEY -> value of $CFG->KEY = '...'; (simple single-line literals only)
  sed -nE "s/^[[:space:]]*\\\$CFG->$2[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n 1
}

echo "== moodle-server-care: environment discovery (read-only) =="
say "date" "$(date '+%F %T %Z')"
say "hostname" "$(hostname)"
say "os" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
RUNK=$(uname -r); NEWK=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1)
say "kernel running/newest" "$RUNK / ${NEWK:-?}$( [ -f /var/run/reboot-required ] && echo '  (reboot-required)')"
ORIGIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p')
say "primary IPv4" "${ORIGIN_IP:-?} (from the routing table; behind NAT this is the private address)"

# --- Moodle site(s) ---
MOODLE="${1:-}"
if [ -z "$MOODLE" ]; then
  mapfile -t CANDS < <($SUDO find /var/www /srv /opt /home -maxdepth 4 -name config.php -type f 2>/dev/null \
    | while read -r f; do grep -q 'CFG->wwwroot' "$f" 2>/dev/null && dirname "$f"; done | sort -u)
  if [ "${#CANDS[@]}" -eq 1 ]; then MOODLE="${CANDS[0]}"
  elif [ "${#CANDS[@]}" -gt 1 ]; then
    echo "Several Moodle sites found; run again with one of them as the argument:"; printf '  %s\n' "${CANDS[@]}"; exit 2
  else echo "No Moodle config.php found under /var/www /srv /opt /home; pass the directory as an argument."; exit 2; fi
fi
CONF="$MOODLE/config.php"
read_conf() { if [ -r "$CONF" ]; then cat "$CONF"; else $SUDO cat "$CONF"; fi; }
TMPC=$(mktemp); chmod 600 "$TMPC"; trap 'rm -f "$TMPC"' EXIT
# keep only the non-secret keys we need: the full config.php (with the DB password) never lands in a temp file
read_conf 2>/dev/null | grep -E '^[[:space:]]*\$CFG->(wwwroot|dataroot|dbtype|dbname|dbhost|prefix|session_handler_class)[[:space:]]*=' > "$TMPC" \
  || { echo "cannot read $CONF"; exit 2; }
WWWROOT=$(cfgval "$TMPC" wwwroot); DATAROOT=$(cfgval "$TMPC" dataroot)
DBTYPE=$(cfgval "$TMPC" dbtype); DBNAME=$(cfgval "$TMPC" dbname); DBHOST=$(cfgval "$TMPC" dbhost); PREFIX=$(cfgval "$TMPC" prefix)
SITE=$(printf '%s' "$WWWROOT" | sed -E 's#^[a-z]+://##; s#/.*##')
if [ -f "$MOODLE/public/version.php" ]; then DOCROOT="$MOODLE/public"; VFILE="$MOODLE/public/version.php"
else DOCROOT="$MOODLE"; VFILE="$MOODLE/version.php"; fi
RELEASE=$(sed -nE "s/^\\\$release[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/p" "$VFILE" 2>/dev/null | head -n 1)
GITREF=$(git -C "$MOODLE" describe --tags --always 2>/dev/null || $SUDO git -C "$MOODLE" describe --tags --always 2>/dev/null || echo "not a git checkout")
say "moodle dir" "$MOODLE"
say "moodle release" "${RELEASE:-?} (git: $GITREF)"
say "docroot" "$DOCROOT"
say "wwwroot / site" "$WWWROOT / $SITE"
say "dataroot" "$DATAROOT"
say "db" "${DBTYPE:-?} name=${DBNAME:-?} host=${DBHOST:-?} prefix=${PREFIX:-?} (credentials not read)"
grep -qE "session_handler_class.*redis" "$TMPC" && say "sessions" "redis" || say "sessions" "not redis (or not set in config.php)"

# --- web server and PHP ---
NGINXBIN=$(command -v nginx || { [ -x /usr/sbin/nginx ] && echo /usr/sbin/nginx; })
NGINX=""; [ -n "$NGINXBIN" ] && NGINX=$("$NGINXBIN" -v 2>&1 | sed 's#.*/##')
APACHEBIN=$(command -v apache2 || { [ -x /usr/sbin/apache2 ] && echo /usr/sbin/apache2; })
APACHE=""; [ -n "$APACHEBIN" ] && APACHE=$("$APACHEBIN" -v 2>/dev/null | sed -nE 's#.*Apache/([0-9.]+).*#\1#p')
say "web server" "${NGINX:+nginx $NGINX }${APACHE:+apache $APACHE}"
VHOST=""; FPM_SOCK=""
if [ -n "$NGINX" ]; then
  VHOST=$(grep -RlE "server_name[^;]*[[:space:]]$SITE([[:space:];]|$)" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
  [ -n "$VHOST" ] && FPM_SOCK=$(grep -oE 'fastcgi_pass[[:space:]]+unix:[^;]+' "$VHOST" | head -n 1 | sed 's/.*unix://')
fi
say "site vhost" "${VHOST:-?}"
say "php-fpm socket" "${FPM_SOCK:-?}"
PHPVER=""; WEBUSER=""
for pool in /etc/php/*/fpm/pool.d/*.conf; do
  [ -f "$pool" ] || continue
  L=$(sed -nE 's/^listen[[:space:]]*=[[:space:]]*(\S+).*/\1/p' "$pool" | head -n 1)
  if [ -n "$FPM_SOCK" ] && [ "${L#/var}" = "${FPM_SOCK#/var}" ]; then
    PHPVER=$(echo "$pool" | cut -d/ -f4); WEBUSER=$(sed -nE 's/^user[[:space:]]*=[[:space:]]*(\S+).*/\1/p' "$pool" | head -n 1)
  fi
done
PHP_GUESSED=0
[ -z "$PHPVER" ] && { PHPVER=$(ls -d /etc/php/*/fpm 2>/dev/null | cut -d/ -f4 | sort -V | tail -n 1); PHP_GUESSED=1; }
PHP="php${PHPVER}"; WEBUSER="${WEBUSER:-www-data}"
say "php for the site" "$PHP (pool user $WEBUSER); installed: $(ls /etc/php 2>/dev/null | tr '\n' ' ')"
say "php cli max_input_vars" "$($PHP -r 'echo ini_get("max_input_vars");' 2>/dev/null) (upgrades need -d max_input_vars=5000)"

# --- services ---
for s in mariadb mysql postgresql redis-server exim4 postfix fail2ban certbot.timer unattended-upgrades docker; do
  st=$(systemctl is-active "$s" 2>/dev/null); [ "$st" = "unknown" ] || [ -z "$st" ] || say "service $s" "$st"
done
say "failed units" "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
say "listeners" "$($SUDO ss -Hltn 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"

# --- Cloudflare in front? ---
if [ -n "$SITE" ]; then
  H=$(curl -sI --max-time 10 "https://$SITE/login/index.php" 2>/dev/null | tr -d '\r')
  CF=no; echo "$H" | grep -qi '^server: cloudflare' && CF=yes
  say "cloudflare in front" "$CF$(echo "$H" | sed -nE 's/^cf-ray: .*-([A-Z]{3})$/ (edge seen from server: \1)/Ip')"
  say "real-ip config" "$(grep -RlsE 'real_ip_header' /etc/nginx/ 2>/dev/null | tr '\n' ' ' || true)"
fi

# --- other sites on this server ---
if [ -n "$NGINX" ]; then
  say "enabled vhosts" "$(ls /etc/nginx/sites-enabled/ 2>/dev/null | tr '\n' ' ')"
  say "default_server" "$(grep -RlsE 'default_server' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | tr '\n' ' ' || echo none)"
fi
say "web-user crontab lines" "$($SUDO crontab -u "$WEBUSER" -l 2>/dev/null | grep -cvE '^\s*(#|$)')"

WEB=none; [ -n "$NGINX" ] && WEB=nginx; [ -z "$NGINX" ] && [ -n "$APACHE" ] && WEB=apache
MTA=none; for m in exim4 postfix; do systemctl is-active --quiet "$m" 2>/dev/null && { MTA=$m; break; }; done
ACCESS_LOG=""
[ -n "$VHOST" ] && ACCESS_LOG=$(grep -E '^[[:space:]]*access_log[[:space:]]+/' "$VHOST" | grep -v ' if=' | head -n 1 | awk '{print $2}')
SERVER_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)
HANDBOOK=""; OPS_LOG=""
for f in "$HOME/SERVER-HANDBOOK.md" "$HOME"/*-SERVER.md; do [ -f "$f" ] && { HANDBOOK=$f; break; }; done
for f in "$HOME/SERVER-OPS-LOG.md" "$HOME"/*-SERVER-LOG.md; do [ -f "$f" ] && { OPS_LOG=$f; break; }; done
say "access log" "${ACCESS_LOG:-?}"
say "mta / tz" "$MTA / $SERVER_TZ"
say "handbook / ops log" "${HANDBOOK:-none} / ${OPS_LOG:-none}"
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }   # single-quote a value for the env file

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
{
  echo "# written by detect-env.sh on $(date '+%F %T'); non-secret facts only (values single-quoted)"
  for k in MOODLE DOCROOT DATAROOT SITE WWWROOT RELEASE DBTYPE DBNAME DBHOST PHP PHP_GUESSED FPM_SOCK WEBUSER VHOST \
           ORIGIN_IP WEB MTA ACCESS_LOG SERVER_TZ HANDBOOK OPS_LOG; do
    printf '%s=%s\n' "$k" "$(q "${!k:-}")"
  done
  printf 'CLOUDFLARE=%s\n' "$(q "${CF:-unknown}")"
} > "$OUT"; chmod 600 "$OUT"
echo "== written: $OUT =="
