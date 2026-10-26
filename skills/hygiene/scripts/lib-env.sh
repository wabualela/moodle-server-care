# lib-env.sh — sourced by the hygiene scripts (not executed on its own).
# Loads the non-secret facts written by skills/start/scripts/detect-env.sh (parsed, never sourced: several hygiene
# scripts run as root) and provides small read-only helpers.
# Variables already set in the environment win over the file, so `WEBUSER=apache bash script.sh` is an override.
# Nothing here prints secrets or changes the system.
# shellcheck shell=bash

MSC_VARS="MOODLE DOCROOT DATAROOT SITE WWWROOT RELEASE DBTYPE DBNAME PHP FPM_SOCK WEBUSER VHOST ORIGIN_IP CLOUDFLARE"
# Base directories, overridable for tests (a harness points them at mock trees).
MSC_NGINX_DIR="${MSC_NGINX_DIR:-/etc/nginx}"
MSC_APACHE_DIR="${MSC_APACHE_DIR:-/etc/apache2}"
MSC_MAIL_DIRS="${MSC_MAIL_DIRS:-/var/mail /var/spool/mail}"
MSC_CRON_FILES="${MSC_CRON_FILES:-/etc/crontab /etc/cron.d}"
MSC_SCAN_ROOTS="${MSC_SCAN_ROOTS:-/var/www /srv /opt /home}"
MSC_FPM_POOL_GLOB="${MSC_FPM_POOL_GLOB:-/etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf}"
MSC_LE_DIR="${MSC_LE_DIR:-/etc/letsencrypt}"
MSC_AUTH_KEYS_GLOB="${MSC_AUTH_KEYS_GLOB:-/root/.ssh/authorized_keys /home/*/.ssh/authorized_keys}"

# Path of server.env. Under sudo, HOME is usually /root, so fall back to the invoking user's home.
msc_env_file() {
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

msc_load_env() {
  local f
  f=$(msc_env_file)
  MSC_ENV_LOADED=""
  # shellcheck disable=SC2086
  msc_parse_env "$f" $MSC_VARS && MSC_ENV_LOADED="$f"
  WEBUSER="${WEBUSER:-www-data}"
}

# msc_redact_cron: filter for crontab lines before they are printed. Crontabs often carry `mysqldump -pXXX`,
# `curl -u user:pass`, `?token=`, healthchecks ping URLs and MAILTO addresses; none of that may reach the transcript.
# Keeps paths and schedules (what the checks need); `mkdir -p` and `find -print` are left alone.
msc_redact_cron() {
  LC_ALL=C sed -E 's#(://[^/:@[:space:]]*):[^@/[:space:]]+@#\1:<redacted>@#g
/(mysql|mariadb|mysqldump|mariadb-dump|mysqladmin)/s/(^|[[:space:]])-p[^[:space:]]+/\1-p<redacted>/g
s/--password[= ][^[:space:]]+/--password=<redacted>/g
s/((token|key|secret|pass|password|passwd|pwd|auth|sesskey)=)[^&"'"'"'[:space:];]+/\1<redacted>/Ig
/(curl|wget)/s/((^|[[:space:]])(-u|--user)[[:space:]]*[^:[:space:]]+):[^[:space:]]+/\1:<redacted>/g
/redis-cli/s/((^|[[:space:]])-a[[:space:]]+)[^[:space:]]+/\1<redacted>/g
s/(sshpass[[:space:]]+-p[[:space:]]*)[^[:space:]]+/\1<redacted>/g
s#(hc-ping\.com/)[^[:space:]"'"'"']+#\1<redacted>#g
s/[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/<email>@\1/g'
}

# Run privileged reads with sudo when not root and passwordless sudo exists; otherwise run as is (and miss some data).
msc_init_sudo() {
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then SUDO="sudo -n"; else MSC_NO_ROOT=1; fi
  fi
}

msc_have() { command -v "$1" >/dev/null 2>&1; }

# Application roots (scan roots without /home), for "does another app reference this?" searches.
msc_app_roots() { for r in $MSC_SCAN_ROOTS; do [ "$r" = /home ] || printf '%s\n' "$r"; done; }

msc_hr() { printf '\n== %s ==\n' "$*"; }

# Effective web server configuration as text (nginx -T, or the enabled Apache files). Read-only.
msc_webconf_dump() {
  if msc_have nginx || [ -x /usr/sbin/nginx ]; then
    local ngx; ngx=$(command -v nginx || echo /usr/sbin/nginx)
    $SUDO "$ngx" -T 2>/dev/null && return 0
  fi
  local d f
  for d in "$MSC_APACHE_DIR" /etc/httpd; do
    [ -d "$d" ] || continue
    for f in "$d"/apache2.conf "$d"/conf/httpd.conf "$d"/sites-enabled/* "$d"/conf-enabled/* "$d"/conf.d/*.conf; do
      [ -e "$f" ] || continue
      printf '# configuration file %s:\n' "$f"
      $SUDO cat "$f" 2>/dev/null
    done
  done
}

# Config files that exist but are not loaded (nginx/apache sites-available without a link in sites-enabled).
msc_webconf_disabled() {
  local base f n linked
  for base in "$MSC_NGINX_DIR" "$MSC_APACHE_DIR"; do
    [ -d "$base/sites-available" ] || continue
    for f in "$base"/sites-available/*; do
      [ -f "$f" ] || continue
      n=$(basename "$f"); linked=0
      for l in "$base"/sites-enabled/*; do
        [ -e "$l" ] || continue
        if [ "$(readlink -f "$l")" = "$(readlink -f "$f")" ]; then linked=1; break; fi
      done
      [ "$linked" -eq 0 ] && printf '%s\n' "$f"
    done
  done
}

# Users with a crontab (needs root to list the spool), plus the web user.
msc_cron_users() {
  {
    printf '%s\n' "$WEBUSER" root ${MSC_CRON_USERS:-}
    $SUDO ls /var/spool/cron/crontabs/ 2>/dev/null
    [ -d /var/spool/cron/crontabs ] || $SUDO ls /var/spool/cron/ 2>/dev/null | grep -vE '^(atjobs|atspool|lastrun)$'
  } | sort -u
}

# All local IPv4/IPv6 addresses (to tell "DNS points here" from "points elsewhere").
msc_local_ips() {
  { hostname -I 2>/dev/null | tr ' ' '\n'; ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1; \
    [ -n "${ORIGIN_IP:-}" ] && printf '%s\n' "$ORIGIN_IP"; } | grep -v '^$' | sort -u
}
