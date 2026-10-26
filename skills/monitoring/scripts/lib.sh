# lib.sh — sourced by discover.sh and install.sh of the monitoring module (not executed on its own).
# Loads the non-secret facts written by skills/start/scripts/detect-env.sh (parsed, never sourced) and provides
# read-only detection helpers.
# Variables already set in the environment win over server.env, so `SITE=example.org bash install.sh` is an override.
# Nothing here prints secrets, reads the ping URL file, or changes the system.
# shellcheck shell=bash
set +x

MSC_VARS="MOODLE DOCROOT DATAROOT SITE WWWROOT RELEASE DBTYPE DBNAME PHP FPM_SOCK WEBUSER VHOST ORIGIN_IP CLOUDFLARE"
# Base directories, overridable so a test harness can point them at mock trees.
MH_NGINX_DIR="${MH_NGINX_DIR:-/etc/nginx}"
MH_APACHE_DIRS="${MH_APACHE_DIRS:-/etc/apache2 /etc/httpd}"
MH_LOG_DIR_APACHE="${MH_LOG_DIR_APACHE:-/var/log/apache2}"
MH_VARLOG="${MH_VARLOG:-/var/log}"
MH_CRON_D="${MH_CRON_D:-/etc/cron.d}"

mh_env_file() {
  if [ -n "${MSC_ENV:-}" ]; then printf '%s\n' "$MSC_ENV"; return; fi
  local h="${HOME:-}"
  if [ ! -r "$h/.config/moodle-server-care/server.env" ] && [ -n "${SUDO_USER:-}" ]; then
    h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  fi
  printf '%s\n' "$h/.config/moodle-server-care/server.env"
}

# msc_parse_env FILE [KEY ...] -- read server.env (written by skills/start/scripts/detect-env.sh) WITHOUT sourcing
# it: scripts that run as root must never execute a file in the operator's home. Accepts plain, 'single-quoted',
# "double-quoted" and printf-%q values. Sets only the listed keys (default: the documented ones; ask for others such
# as HANDBOOK or OPS_LOG by name, so generic names never clobber a script's own variables); a key that is
# already set in the environment wins, so `SITE=example.org bash script.sh` is an override. Refuses a symlink, a
# file owned by anyone other than the caller, the sudo caller or root, and a file group or others can write.
# Returns 1 (and sets nothing) when the file is missing or refused. Identical copies live in several modules
# (grep -rl 'msc_parse_env()' skills/); change them together.
msc_parse_env() {
  local f=$1 line k v owner mode keys
  shift
  keys=" ${*:-MOODLE DOCROOT DATAROOT SITE WWWROOT RELEASE DBTYPE DBNAME PHP PHP_GUESSED FPM_SOCK WEBUSER VHOST ORIGIN_IP CLOUDFLARE} "
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
  owner=$(stat -c %u -- "$f" 2>/dev/null) && mode=$(stat -c %a -- "$f" 2>/dev/null) || return 1
  if [ "$owner" != 0 ] && [ "$owner" != "$(id -u)" ] && [ "$owner" != "$(id -u -- "${SUDO_USER:-root}" 2>/dev/null)" ]; then
    echo "server.env: ignoring $f (owned by uid $owner)" >&2; return 1
  fi
  if (( 8#$mode & 8#022 )); then echo "server.env: ignoring $f (mode $mode: writable by group or others)" >&2; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    [[ $keys == *" $k "* ]] || continue
    [ -n "${!k+x}" ] && continue
    case $v in
      \$\'*) echo "server.env: $k has an escaped control character; ignored" >&2; continue ;;
      \'*\') v=${v:1:${#v}-2} ;;
      \"*\") v=${v:1:${#v}-2} ;;
      *\\*) v=$(printf '%s' "$v" | sed 's/\\\(.\)/\1/g') ;;
    esac
    printf -v "$k" '%s' "$v"
  done < "$f"
  return 0
}

mh_load_env() {
  local f k
  f=$(mh_env_file)
  MH_ENV_LOADED=""
  # parsed, never sourced (install.sh runs as root); variables already set in the environment win
  # shellcheck disable=SC2086
  msc_parse_env "$f" $MSC_VARS && MH_ENV_LOADED="$f"
  for k in $MSC_VARS; do [ -n "${!k+x}" ] || printf -v "$k" '%s' ""; done
  WEBUSER="${WEBUSER:-www-data}"
  [ -n "$SITE" ] || SITE=$(printf '%s' "$WWWROOT" | sed -E 's#^[a-z]+://##; s#[:/].*##')
}

mh_init_sudo() {
  SUDO=""
  [ -n "${MH_NO_SUDO:-}" ] && return 0     # test harness: never escalate
  if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then SUDO="sudo -n"; else MH_NO_ROOT=1; fi
  fi
}

# sbin directories appended (never prepended, so harness mocks stay first): an operator's PATH often lacks them,
# and tools such as exiqgrep, postqueue or fail2ban-client live there
mh_have() { PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" command -v "$1" >/dev/null 2>&1; }
mh_hr() { printf '\n== %s ==\n' "$*"; }
mh_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
# enabled / disabled / not-installed (systemctl prints "disabled" AND exits 1, so no "|| echo" fallback here)
mh_unit_enabled() { local s; s=$(systemctl is-enabled "$1" 2>/dev/null | head -n 1); echo "${s:-not-installed}"; }

# Web server serving the site: nginx, apache2 (Debian) or httpd (RHEL); empty if none is active.
mh_webserver() {
  if mh_active nginx; then echo nginx
  elif mh_active apache2; then echo apache2
  elif mh_active httpd; then echo httpd
  fi
}

# nginx file declaring server_name <SITE> (VHOST from server.env first).
mh_nginx_vhost() {
  if [ -n "${VHOST:-}" ] && [ -r "$VHOST" ]; then echo "$VHOST"; return; fi
  [ -n "$SITE" ] || return 0
  grep -RlsE "server_name[^;]*[[:space:]]${SITE//./\\.}([[:space:];]|$)" \
    "$MH_NGINX_DIR/sites-enabled/" "$MH_NGINX_DIR/conf.d/" 2>/dev/null | head -n 1
}

# Apache file declaring ServerName/ServerAlias <SITE>.
mh_apache_vhost() {
  local d
  [ -n "$SITE" ] || return 0
  local f
  for d in $MH_APACHE_DIRS; do
    [ -d "$d" ] || continue
    f=$(grep -RlsiE "^[[:space:]]*Server(Name|Alias)[[:space:]](.*[[:space:]])?${SITE//./\\.}(:[0-9]+)?([[:space:]]|$)" \
      "$d/sites-enabled/" "$d/conf.d/" "$d/vhosts.d/" 2>/dev/null | head -n 1)
    [ -n "$f" ] && { echo "$f"; return 0; }
  done
}

mh_apache_expand() {  # expand ${APACHE_LOG_DIR} and relative "logs/..." paths
  sed -E "s#\\$\\{APACHE_LOG_DIR\\}#$MH_LOG_DIR_APACHE#g; s#^\"##; s#\"\$##" | sed -E 's#^logs/#/var/log/httpd/#'
}

# Access log path(s) of the Moodle vhost (space separated) and, for a shared vhost_combined log, the vhost filter.
# Sets MH_ACCESS_LOG and MH_ACCESS_LOG_VHOST.
mh_access_logs() {
  local ws f logs="" vh=""
  MH_ACCESS_LOG=""; MH_ACCESS_LOG_VHOST=""
  ws=$(mh_webserver)
  case "$ws" in
    nginx)
      f=$(mh_nginx_vhost)
      if [ -n "$f" ]; then
        # conditional logs (access_log ... if=$var, e.g. a rate-limit log) record only a subset: never the 5xx source
        logs=$(grep -vE '^[[:space:]]*access_log[^;]*[[:space:]]if=' "$f" | sed -nE 's/^[[:space:]]*access_log[[:space:]]+([^;[:space:]]+).*/\1/p' | grep -vE '^(off|syslog:)' | sort -u | tr '\n' ' ')
      fi
      if [ -z "$logs" ]; then
        logs=$(grep -vE '^[[:space:]]*access_log[^;]*[[:space:]]if=' "$MH_NGINX_DIR/nginx.conf" 2>/dev/null | sed -nE 's/^[[:space:]]*access_log[[:space:]]+([^;[:space:]]+).*/\1/p' | grep -vE '^(off|syslog:)' | head -n 1)
        [ -n "$logs" ] || logs=/var/log/nginx/access.log
      fi ;;
    apache2|httpd)
      f=$(mh_apache_vhost)
      if [ -n "$f" ]; then
        logs=$(sed -nE 's/^[[:space:]]*CustomLog[[:space:]]+("[^"]+"|[^[:space:]]+).*/\1/Ip' "$f" | mh_apache_expand | grep -v '^|' | sort -u | tr '\n' ' ')
      fi
      if [ -z "$logs" ]; then
        logs="$MH_LOG_DIR_APACHE/other_vhosts_access.log"; vh="$SITE"
      fi ;;
  esac
  MH_ACCESS_LOG=$(printf '%s' "$logs" | sed -E 's/[[:space:]]+$//')
  MH_ACCESS_LOG_VHOST="$vh"
}

mh_apache_error_log() {
  local f
  f=$(mh_apache_vhost)
  [ -n "$f" ] && sed -nE 's/^[[:space:]]*ErrorLog[[:space:]]+("[^"]+"|[^[:space:]]+).*/\1/Ip' "$f" | mh_apache_expand | grep -v '^|' | head -n 1
}

# Active PHP-FPM units (php8.4-fpm, php-fpm ...).
mh_fpm_units() {
  systemctl list-units --type=service --state=active --no-legend --plain 'php*-fpm.service' 2>/dev/null \
    | awk '{print $1}' | sed 's/\.service$//' | sort -u | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
}

# FPM master logs of the active units (Debian /var/log/phpX.Y-fpm.log, RHEL /var/log/php-fpm/error.log).
mh_fpm_logs() {
  local u out=""
  for u in $(mh_fpm_units); do
    [ -f "$MH_VARLOG/$u.log" ] && out="$out $MH_VARLOG/$u.log"
  done
  [ -z "$out" ] && [ -f "$MH_VARLOG/php-fpm/error.log" ] && out=" $MH_VARLOG/php-fpm/error.log"
  printf '%s' "${out# }"
}

# Services that must stay active, from what is active now (never guessed).
mh_services() {
  local out="" s ws pg
  ws=$(mh_webserver); [ -n "$ws" ] && out="$ws"
  out="$out $(mh_fpm_units)"
  if mh_active mariadb; then out="$out mariadb"; elif mh_active mysql; then out="$out mysql"; elif mh_active mysqld; then out="$out mysqld"; fi
  pg=$(systemctl list-units --type=service --state=active --no-legend --plain 'postgresql@*.service' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | tr '\n' ' ')
  [ -n "$pg" ] && out="$out $pg"
  for s in redis-server redis exim4 exim postfix cron crond fail2ban; do mh_active "$s" && out="$out $s"; done
  printf '%s' "$out" | tr -s ' ' | sed -E 's/^ //; s/ $//'
}

# File written by the Moodle cron job: the redirect target of the cron.php line in the web user's crontab or cron.d.
mh_cron_log() {
  local line
  line=$( { $SUDO crontab -u "$WEBUSER" -l 2>/dev/null; cat "$MH_CRON_D"/* 2>/dev/null; } | grep -E 'admin/cli/cron\.php' | grep -vE '^[[:space:]]*#' | head -n 1)
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | sed -nE 's/.*admin\/cli\/cron\.php[^>]*>>?[[:space:]]*([^[:space:]&;|]+).*/\1/p' | grep -vE '^/dev/(null|stdout|stderr)$' | head -n 1
}

# File listing the CDN/proxy ranges trusted for the real client IP (nginx or Apache).
mh_cf_ranges_file() {
  local d f
  f=$(grep -RlsE '^[[:space:]]*set_real_ip_from[[:space:]]' "$MH_NGINX_DIR/conf.d/" "$MH_NGINX_DIR/sites-enabled/" 2>/dev/null | head -n 1)
  if [ -z "$f" ]; then
    for d in $MH_APACHE_DIRS; do
      [ -d "$d" ] || continue
      f=$(grep -RlsiE '^[[:space:]]*RemoteIP(Trusted|Internal)Proxy(List)?[[:space:]]' "$d/conf-enabled/" "$d/conf.d/" "$d/sites-enabled/" 2>/dev/null | head -n 1)
      [ -n "$f" ] && break
    done
  fi
  printf '%s' "$f"
}

# Other host names served on this machine (candidates for EXTRA_SITES): exact names only, not the Moodle site.
mh_other_vhosts() {
  {
    grep -RhosE '(^|[[:space:];{])server_name[[:space:]]+[^;]+' "$MH_NGINX_DIR/sites-enabled/" "$MH_NGINX_DIR/conf.d/" 2>/dev/null \
      | sed -E 's/^.*server_name[[:space:]]+//' | tr ' \t' '\n\n'
    local d
    for d in $MH_APACHE_DIRS; do
      [ -d "$d" ] && grep -RhsiE '^[[:space:]]*Server(Name|Alias)[[:space:]]' "$d/sites-enabled/" "$d/conf.d/" 2>/dev/null \
        | sed -E 's/^[[:space:]]*Server(Name|Alias)[[:space:]]+//I; s/:[0-9]+//g' | tr ' ' '\n'
    done
  } | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | grep -vxF "$SITE" | grep -vE '^(localhost|www\.)' | sort -u
}

# HTTP status of a local probe by SNI on a static path (read-only; same as the script's EXTRA_SITES probe).
mh_probe_code() {  # mh_probe_code HOST [PATH]
  curl -sk -o /dev/null --max-time 6 -A moodle-health -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1${2:-/favicon.ico}" 2>/dev/null || true
}

# Value of a simple $CFG->key = '...'; line, for NON-SECRET keys only (wwwroot, dataroot, dbtype, dbhost).
mh_cfg() {  # mh_cfg KEY
  case "$1" in wwwroot|dataroot|dbtype|dbhost|dbname) ;; *) echo "mh_cfg: refusing key $1" >&2; return 1 ;; esac
  [ -n "$MOODLE" ] || return 0
  { cat "$MOODLE/config.php" 2>/dev/null || $SUDO cat "$MOODLE/config.php" 2>/dev/null; } \
    | sed -nE "s/^[[:space:]]*\\\$CFG->$1[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" | head -n 1
}
