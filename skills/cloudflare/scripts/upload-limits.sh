#!/bin/bash
# upload-limits.sh - show every layer that limits a Moodle upload and the effective limit a teacher gets.
#
# Layers, outermost first: Cloudflare (request body cap by plan) -> web server (nginx client_max_body_size or
# Apache LimitRequestBody) -> PHP-FPM (post_max_size, upload_max_filesize) -> Moodle (site maxbytes, then course
# and activity limits, which can only be lower). An upload larger than an outer layer fails with that layer's
# error page (Cloudflare 413, nginx 413) instead of Moodle's clear "file too large" message, which is why the
# owner on the first server chose to align all layers to the Cloudflare cap.
#
# Read-only. Uses sudo -n (if available) to read nginx -T and to run Moodle's admin/cli/cfg.php as the web user.
#
# Usage: upload-limits.sh [--cf-limit SIZE] [--brief]
#   --cf-limit  Cloudflare body cap for the zone's plan (default 100M: Free and Pro; Business 200M; Enterprise by
#               contract). Use 0 when the site is not behind Cloudflare. Verify the current numbers on Cloudflare's
#               plan page; they are not readable from the server.
#   --brief     only the summary lines
# Environment overrides: MOODLE, PHP, WEBUSER, VHOST, SITE, NGINX_BIN, APACHE_ETC, PHP_ETC.
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
NGINX_BIN="${NGINX_BIN:-$(command -v nginx || echo /usr/sbin/nginx)}"
APACHE_ETC="${APACHE_ETC:-/etc/apache2}"; PHP_ETC="${PHP_ETC:-/etc/php}"
PHP="${PHP:-php}"; WEBUSER="${WEBUSER:-www-data}"
CF_LIMIT=""; BRIEF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cf-limit) CF_LIMIT="${2:?}"; shift 2 ;;
    --brief) BRIEF=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$CF_LIMIT" ]; then if [ "${CLOUDFLARE:-}" = yes ]; then CF_LIMIT=100M; else CF_LIMIT=0; fi; fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

run_as_web() {  # run a command as the PHP-FPM pool user (Moodle CLI rule: never as root or the operator)
  if [ "$(id -u)" = 0 ]; then runuser -u "$WEBUSER" -- "$@"
  elif [ -n "$SUDO" ]; then sudo -n -u "$WEBUSER" -- "$@"
  elif [ "$(id -un)" = "$WEBUSER" ]; then "$@"
  else return 1; fi
}

to_bytes() {  # 100M / 1g / 256m / 104857600 / 0 -> bytes ("" if unparsable)
  local v="${1// /}" n u
  [[ "$v" =~ ^([0-9]+)([kKmMgG]?)[bB]?$ ]] || { echo ""; return; }
  n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
  case "$u" in k|K) echo $((n * 1024)) ;; m|M) echo $((n * 1048576)) ;; g|G) echo $((n * 1073741824)) ;; *) echo "$n" ;; esac
}
human() { local b="$1"; [ -z "$b" ] && { echo "?"; return; }; [ "$b" = 0 ] && { echo "unlimited"; return; }
  awk -v b="$b" 'BEGIN { if (b >= 1073741824) printf "%.1f GB", b/1073741824; else if (b >= 1048576) printf "%d MB", b/1048576; else printf "%d KB", b/1024 }'; }
say() { [ "$BRIEF" = 1 ] || echo "$@"; }

declare -A LIM=()   # layer -> bytes (0 = unlimited)

# --- Cloudflare ------------------------------------------------------------------------------------------------
LIM[cloudflare]=$(to_bytes "$CF_LIMIT")

# --- nginx: every client_max_body_size with its context ---------------------------------------------------------
if [ -x "$NGINX_BIN" ]; then
  say "== nginx client_max_body_size (default 1m when unset) =="
  $SUDO "$NGINX_BIN" -T 2>/dev/null | awk -v site="${SITE:-}" '
    /^# configuration file / { file = $4; sub(/:$/, "", file); next }
    { line = $0; sub(/#.*/, "", line) }
    {
      n = split(line, ch, "")
      tok = line
      if (tok ~ /client_max_body_size/) {
        v = tok; sub(/.*client_max_body_size[[:space:]]+/, "", v); sub(/;.*/, "", v)
        ctx = (depth == 0) ? "main" : stack[depth]
        where = ctx; if (ctx == "server" && srvname != "") where = "server(" srvname ")"
        if (ctx ~ /^location/) where = "server(" srvname ") " ctx
        printf "  %-10s %-60s %s\n", v, substr(where, 1, 60), file
      }
      if (tok ~ /server_name[[:space:]]/ && stack[depth] == "server") { s = tok; sub(/.*server_name[[:space:]]+/, "", s); sub(/;.*/, "", s); srvname = s }
      for (i = 1; i <= n; i++) {
        if (ch[i] == "{") {
          pre = substr(line, 1, i - 1); gsub(/^.*[;}]/, "", pre); gsub(/^[[:space:]]+|[[:space:]]+$/, "", pre)
          split(pre, w, /[[:space:]]+/); kind = w[1]
          if (kind == "location") kind = "location " w[2] (w[3] != "" ? " " w[3] : "")
          depth++; stack[depth] = kind; if (kind == "server") srvname = ""
        } else if (ch[i] == "}") { if (depth > 0) depth-- }
      }
    }' > "$WORK/cmbs"
  [ "$BRIEF" = 1 ] || cat "$WORK/cmbs"
  # Effective for the site: the server-level value in the site vhost, else the http-level value, else 1m.
  SRV=$(grep -E "server\([^)]*${SITE:-@none@}" "$WORK/cmbs" 2>/dev/null | grep -v ' location ' | awk '{print $1}' | tail -n 1)
  HTTPV=$(awk '$2 == "http" {print $1}' "$WORK/cmbs" 2>/dev/null | tail -n 1)
  EFF="${SRV:-${HTTPV:-1m}}"
  LIM[nginx]=$(to_bytes "$EFF")
  say "  effective for ${SITE:-the site} (server level, else http level): $EFF  (a location-level value above overrides it for that location)"
fi

# --- Apache ----------------------------------------------------------------------------------------------------
if [ -d "$APACHE_ETC" ]; then
  say "== Apache LimitRequestBody (default 1 GiB since 2.4.54, unlimited before) =="
  AL=$(grep -RhsiE '^[[:space:]]*LimitRequestBody[[:space:]]+[0-9]+' "$APACHE_ETC" | awk '{print $2}' | sort -n | head -n 1)
  grep -RnsiE '^[[:space:]]*LimitRequestBody' "$APACHE_ETC" | sed 's/^/  /' | { [ "$BRIEF" = 1 ] && cat >/dev/null || cat; }
  [ -n "$AL" ] && LIM[apache]="$AL"
fi

# --- PHP-FPM ---------------------------------------------------------------------------------------------------
PHPVER=$(printf '%s' "$PHP" | sed -nE 's/^php([0-9]+\.[0-9]+)$/\1/p')
if [ -n "$PHPVER" ] && [ -d "$PHP_ETC/$PHPVER/fpm" ]; then
  say "== PHP $PHPVER FPM (php.ini, then conf.d in order, then pool overrides win) =="
  for key in post_max_size upload_max_filesize max_execution_time max_input_time memory_limit; do
    last=""; src=""
    for f in "$PHP_ETC/$PHPVER/fpm/php.ini" $(ls "$PHP_ETC/$PHPVER/fpm/conf.d/"*.ini 2>/dev/null | sort); do
      v=$(sed -nE "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\"?([^\";[:space:]]+).*/\1/p" "$f" 2>/dev/null | tail -n 1)
      [ -n "$v" ] && { last="$v"; src="$f"; }
    done
    for f in "$PHP_ETC/$PHPVER/fpm/pool.d/"*.conf; do
      v=$(sed -nE "s/^[[:space:]]*php_(admin_)?value\[$key\][[:space:]]*=[[:space:]]*([^;[:space:]]+).*/\2/p" "$f" 2>/dev/null | tail -n 1)
      [ -n "$v" ] && { last="$v"; src="$f (pool)"; }
    done
    say "  $(printf '%-20s %-8s %s' "$key" "${last:-default}" "$src")"
    case "$key" in
      post_max_size) LIM[php_post]=$(to_bytes "${last:-8M}") ;;
      upload_max_filesize) LIM[php_upload]=$(to_bytes "${last:-2M}") ;;
    esac
  done
else
  say "== PHP: $PHP FPM config not found under $PHP_ETC; reading the CLI values (may differ from FPM) =="
  for key in post_max_size upload_max_filesize; do
    v=$("$PHP" -r "echo ini_get('$key');" 2>/dev/null); say "  $key = ${v:-?} (CLI)"
    [ "$key" = post_max_size ] && LIM[php_post]=$(to_bytes "$v")
    [ "$key" = upload_max_filesize ] && LIM[php_upload]=$(to_bytes "$v")
  done
fi

# --- Moodle ----------------------------------------------------------------------------------------------------
if [ -n "${MOODLE:-}" ] && [ -f "$MOODLE/admin/cli/cfg.php" ]; then
  say "== Moodle =="
  MB=$(run_as_web "$PHP" "$MOODLE/admin/cli/cfg.php" --name=maxbytes 2>/dev/null | tr -d '[:space:]')
  FORCED=$({ cat "$MOODLE/config.php" 2>/dev/null || $SUDO cat "$MOODLE/config.php" 2>/dev/null; } | grep -E '^[[:space:]]*\$CFG->maxbytes[[:space:]]*=' | head -n 1)
  say "  site maxbytes = ${MB:-? (could not run cfg.php as $WEBUSER)}  (0 = only the PHP limit applies)"
  [ -n "$FORCED" ] && say "  config.php forces it: $FORCED  (change it there, not in the admin UI)"
  say "  course and activity limits can only be lower; they are not listed here."
  FV=$(printf '%s' "$FORCED" | sed -nE 's/.*=[[:space:]]*([0-9]+)[[:space:]]*;.*/\1/p')
  [ -n "$FV" ] && MB="$FV"          # config.php wins over the database value
  [[ "${MB:-}" =~ ^[0-9]+$ ]] && LIM[moodle]="$MB"
fi

# --- summary ---------------------------------------------------------------------------------------------------
echo "== upload limit by layer =="
MIN=""; MINL=""
for l in cloudflare nginx apache php_post php_upload moodle; do
  [ -n "${LIM[$l]+x}" ] || continue
  b="${LIM[$l]}"; printf '  %-12s %s\n' "$l" "$(human "$b")"
  [ -z "$b" ] || [ "$b" = 0 ] && continue
  if [ -z "$MIN" ] || [ "$b" -lt "$MIN" ]; then MIN="$b"; MINL="$l"; fi
done
echo "  effective: $(human "${MIN:-0}") (set by $MINL)"
# What Moodle shows teachers: the smallest of PHP's two limits and maxbytes (when maxbytes > 0).
SHOWN=""
for l in php_post php_upload moodle; do
  b="${LIM[$l]:-}"; { [ -z "$b" ] || [ "$b" = 0 ]; } && continue
  if [ -z "$SHOWN" ] || [ "$b" -lt "$SHOWN" ]; then SHOWN="$b"; fi
done
[ -n "$SHOWN" ] && echo "  Moodle shows teachers: $(human "$SHOWN")"
if [ -n "$MIN" ] && [ -n "$SHOWN" ] && [ "$SHOWN" -gt "$MIN" ]; then
  echo "  NOTE: Moodle advertises more than the $MINL layer accepts. A teacher may start an upload that fails with a"
  echo "        raw error. Align Moodle maxbytes (and the web server) to $(human "$MIN") - see references/upload-limits.md."
fi
if [ -n "${LIM[php_post]:-}" ] && [ -n "${LIM[php_upload]:-}" ] && [ "${LIM[php_post]}" != 0 ] && [ "${LIM[php_post]}" -lt "${LIM[php_upload]}" ]; then
  echo "  NOTE: post_max_size is smaller than upload_max_filesize; post_max_size wins for form uploads."
fi
exit 0
