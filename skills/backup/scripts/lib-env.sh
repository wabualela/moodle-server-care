# lib-env.sh - sourced by the backup module's discovery and render scripts (not executed on its own).
# shellcheck shell=bash

# Path of server.env: $MSC_ENV, else the caller's home; under sudo HOME is usually /root, so fall back to the
# invoking user's home.
msc_env_path() {
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
