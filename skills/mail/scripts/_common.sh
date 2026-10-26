#!/bin/bash
# _common.sh — helpers shared by the mail module scripts. Sourced, not executed.
#
# Loads ~/.config/moodle-server-care/server.env (written by skills/start/scripts/detect-env.sh). Variables that are
# already set in the environment win over the file, so every value can be overridden per run, e.g.
#   MOODLE=/srv/moodle WEBUSER=apache bash mail-discover.sh
# Test/harness overrides: MSC_ENV (env file), MSC_NO_SUDO=1 (run everything as the current user),
# EXIM_DIR, EXIM_DEFAULT, EXIM_LOGDIR, EXIM_BIN, POSTFIX_DIR, MAILLOG.
set +x

MSC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  local f="${MSC_ENV:-}" h="${HOME:-}"
  if [ -z "$f" ]; then   # under sudo HOME is usually /root: fall back to the invoking user's file
    if [ ! -r "$h/.config/moodle-server-care/server.env" ] && [ -n "${SUDO_USER:-}" ]; then
      h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    fi
    f="$h/.config/moodle-server-care/server.env"
  fi
  MSC_ENV_FILE=""
  msc_parse_env "$f" && MSC_ENV_FILE="$f"     # parsed, never sourced; variables set in the environment win
  : "${WEBUSER:=www-data}" "${PHP:=php}"
  command -v "$PHP" >/dev/null 2>&1 || PHP=php
  return 0
}

msc_sudo_init() {
  if [ "${MSC_NO_SUDO:-0}" = 1 ] || [ "$(id -u)" = 0 ]; then SUDO=""
  elif sudo -n true 2>/dev/null; then SUDO="sudo -n"
  else SUDO="sudo"; fi
}

# Binaries are looked up through PATH (with the sbin directories appended, never prepended), so a test harness
# can put mocks first. Never call an MTA by absolute path: on the first server a test that did so reached the
# live relay.
msc_which() { PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin" command -v "$1" 2>/dev/null || true; }

msc_exim_init() {
  EXIM_DIR="${EXIM_DIR:-/etc/exim4}"
  EXIM_DEFAULT="${EXIM_DEFAULT:-/etc/default/exim4}"
  EXIM_LOGDIR="${EXIM_LOGDIR:-/var/log/exim4}"
  EXIM_BIN="${EXIM_BIN:-$(msc_which exim4)}"
  [ -n "$EXIM_BIN" ] || EXIM_BIN="$(msc_which exim)"
  EXIM_CONF="$EXIM_DIR/update-exim4.conf.conf"
  local split
  split=$(sed -nE "s/^dc_use_split_config='([^']*)'.*/\1/p" "$EXIM_CONF" 2>/dev/null | tail -n 1)
  if [ "$split" = "true" ]; then
    EXIM_TPL="$EXIM_DIR/conf.d/transport/30_exim4-config_remote_smtp_smarthost"
    EXIM_MACROS="$EXIM_DIR/conf.d/main/000_localmacros"
  else
    EXIM_TPL="$EXIM_DIR/exim4.conf.template"
    EXIM_MACROS="$EXIM_DIR/exim4.conf.localmacros"
  fi
}

msc_postfix_init() {
  POSTFIX_DIR="${POSTFIX_DIR:-/etc/postfix}"
  POSTCONF_BIN="$(msc_which postconf)"
  MAILLOG="${MAILLOG:-/var/log/mail.log}"
}

# Prints exim | postfix | other:<name> | none, based first on what listens on port 25.
msc_detect_mta() {
  local who
  who=$($SUDO ss -Hltnp 'sport = :25' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n 1 | sed -E 's/^users:\(\("//; s/"$//')
  case "$who" in
    exim*) echo exim; return ;;
    master|postfix*) echo postfix; return ;;
    ?*) echo "other:$who"; return ;;
  esac
  [ -n "${EXIM_BIN:-}" ] && { echo exim; return; }
  [ -n "$(msc_which postconf)" ] && { echo postfix; return; }
  [ -n "$(msc_which sendmail)" ] && { echo "other:sendmail-binary"; return; }
  echo none
}

# Masks e-mail local parts and exim authenticator ids (A=plain:<user> -> A=plain) in log output.
msc_redact() {
  sed -E 's/(A=[A-Za-z0-9_-]+):[^ ]*/\1/g; s/[A-Za-z0-9._%+=-]+@([A-Za-z0-9.-]+)/…@\1/g'
}

# Runs moodle-mail.php as the web user (from a 0644 copy in /tmp: the operator's home is usually 0700).
# Usage: msc_moodle_php <action args...>   (stdin is passed through, for --restore)
msc_moodle_php() {
  local src="$MSC_DIR/moodle-mail.php" tmp rc
  if [ -z "${MOODLE:-}" ] || [ ! -e "$MOODLE/config.php" ]; then
    echo "MOODLE is not set or $MOODLE/config.php is missing (run skills/start/scripts/detect-env.sh or set MOODLE=...)" >&2
    return 2
  fi
  tmp=$(mktemp /tmp/msc-moodle-mail-XXXXXX.php) || return 2
  cat "$src" > "$tmp"; chmod 644 "$tmp"
  if [ "${MSC_NO_SUDO:-0}" = 1 ] || [ "$(id -un)" = "$WEBUSER" ]; then
    "$PHP" "$tmp" --config="$MOODLE/config.php" "$@"
  elif [ "$(id -u)" = 0 ]; then
    runuser -u "$WEBUSER" -- "$PHP" "$tmp" --config="$MOODLE/config.php" "$@"
  else
    ${SUDO:-sudo} -u "$WEBUSER" "$PHP" "$tmp" --config="$MOODLE/config.php" "$@"
  fi
  rc=$?
  rm -f "$tmp"
  return $rc
}

msc_hr() { printf '\n== %s ==\n' "$*"; }
