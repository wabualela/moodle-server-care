# lib-env.sh — sourced by the tuning module's bash scripts. Loads the non-secret facts written by
# skills/start/scripts/detect-env.sh (~/.config/moodle-server-care/server.env). Variables already set in the
# environment win over the file, so every script accepts overrides such as  MOODLE=/srv/moodle bash script.sh
#
# The file is parsed, never sourced (scripts here run as root through sudo), and only when it belongs to the invoking
# user (or root) and is not group/world writable. Under sudo, the invoking user's file is used (SUDO_USER's home).
# shellcheck shell=bash

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
    local keys="MOODLE DOCROOT DATAROOT SITE WWWROOT RELEASE DBTYPE DBNAME PHP PHP_GUESSED FPM_SOCK WEBUSER VHOST ORIGIN_IP CLOUDFLARE"
    local f home
    f=${MSC_ENV:-}
    if [ -z "$f" ]; then
        home=$HOME
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        fi
        f="$home/.config/moodle-server-care/server.env"
    fi
    # shellcheck disable=SC2086
    [ -f "$f" ] && { msc_parse_env "$f" $keys || echo "msc: $f not used (see above)" >&2; }
    PHP=${PHP:-php}
    WEBUSER=${WEBUSER:-www-data}
    if [ -z "${DOCROOT:-}" ] && [ -n "${MOODLE:-}" ]; then
        if [ -f "$MOODLE/public/version.php" ]; then DOCROOT="$MOODLE/public"; else DOCROOT="$MOODLE"; fi
    fi
    export MOODLE DOCROOT DATAROOT SITE WWWROOT RELEASE DBTYPE DBNAME PHP FPM_SOCK WEBUSER VHOST ORIGIN_IP CLOUDFLARE
    [ -z "${PHP_GUESSED+x}" ] || export PHP_GUESSED
}

# msc_as USER CMD...  run a command as USER (root: runuser; same user: directly; otherwise passwordless sudo).
# Tools are called by name, never by absolute path, so a test harness can put mocks first in PATH.
msc_as() {
    local user=$1; shift
    if [ "$(id -un)" = "$user" ]; then "$@"
    elif [ "$(id -u)" -eq 0 ]; then runuser -u "$user" -- "$@"
    else sudo -n -u "$user" -- "$@"
    fi
}

# msc_root CMD...  run a command as root (directly when already root, else passwordless sudo).
msc_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n -- "$@"; fi
}

msc_need() {  # msc_need VAR...  stop when a required fact is missing
    local v
    for v in "$@"; do
        if [ -z "${!v:-}" ]; then
            echo "msc: $v is not known. Run skills/start/scripts/detect-env.sh first, or set $v=... in the environment." >&2
            exit 2
        fi
    done
}
