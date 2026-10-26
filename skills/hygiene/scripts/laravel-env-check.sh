#!/bin/bash
# laravel-env-check.sh — read-only: find Laravel apps on this server and report, per app, ONLY the non-secret keys
# APP_ENV and APP_DEBUG (from .env and from the cached config the app actually uses), the cache file, modes, the
# hostnames that serve it, debug tooling installed in vendor/, and environment-dependent code to review before a switch.
# Never prints any other .env or config value.
#
# Usage: bash laravel-env-check.sh [APP_DIR ...]     (default: every directory with an 'artisan' file under
#        /var/www /srv /opt /home, depth 3)
# Why: APP_DEBUG=true shows full stack traces (with environment values and secrets) to anyone who triggers an error.
# When bootstrap/cache/config.php exists, Laravel reads THAT file, not .env: editing .env alone changes nothing.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

APPS=("$@")
if [ ${#APPS[@]} -eq 0 ]; then
  mapfile -t APPS < <($SUDO find $MSC_SCAN_ROOTS -maxdepth 3 -name artisan -type f 2>/dev/null | xargs -r -n1 dirname | sort -u)
fi
[ ${#APPS[@]} -eq 0 ] && { echo "no Laravel apps found"; exit 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
msc_webconf_dump > "$TMP/web.txt"

envkey() { $SUDO grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"'"'"' \r'; }

for app in "${APPS[@]}"; do
  msc_hr "$app"
  [ -f "$app/artisan" ] || $SUDO test -f "$app/artisan" || { echo "  not a Laravel app (no artisan)"; continue; }
  hosts=$(awk -v r="$app/public" '
      /^# configuration file / { if (hit && names != "") print names; hit = 0; names = ""; next }
      /server_name/ { n = $0; sub(/.*server_name[[:space:]]+/, "", n); sub(/;.*/, "", n); names = names " " n }
      index($0, r) { hit = 1 }
      END { if (hit && names != "") print names }' "$TMP/web.txt" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
  echo "  served as : ${hosts:-(no enabled vhost found: maybe abandoned, see the abandoned-projects item)}"
  ver=$($SUDO sed -nE 's/.*"laravel\/framework".*"v?([0-9][^"]*)".*/\1/p' "$app/composer.lock" 2>/dev/null | head -n 1)
  [ -z "$ver" ] && ver=$($SUDO awk '/"name": "laravel\/framework"/{f=1} f&&/"version"/{gsub(/[",]/,"");print $2;exit}' "$app/composer.lock" 2>/dev/null)
  echo "  laravel   : ${ver:-?}"
  if $SUDO test -f "$app/.env"; then
    echo "  .env      : APP_ENV=$(envkey "$app/.env" APP_ENV)  APP_DEBUG=$(envkey "$app/.env" APP_DEBUG)  ($($SUDO stat -c '%a %U:%G' "$app/.env"))"
  else
    echo "  .env      : missing"
  fi
  cache="$app/bootstrap/cache/config.php"
  if $SUDO test -f "$cache"; then
    owner=$($SUDO stat -c %U "$cache")
    runas="$WEBUSER"; [ "$owner" != root ] && runas="$owner"
    # Evaluate the cached array as an unprivileged user (never as root: the file is writable by the app) and print
    # only app.env and app.debug.
    vals=$($SUDO runuser -u "$runas" -- php -r '$c = @include $argv[1]; if (!is_array($c)) { echo "unreadable"; exit; }
      echo ($c["app"]["env"] ?? "?"), " ", var_export($c["app"]["debug"] ?? null, true);' "$cache" 2>/dev/null)
    echo "  cache     : $cache  ($($SUDO stat -c '%a %U:%G, %y' "$cache" | cut -d. -f1))"
    echo "              app.env / app.debug in cache = ${vals:-unreadable as $runas}   <- this is what the app uses"
  else
    echo "  cache     : none (the app reads .env on every request)"
  fi
  dbg=""
  for pkg in barryvdh/laravel-debugbar laravel/telescope spatie/laravel-ignition facade/ignition itsgoingd/clockwork; do
    $SUDO test -d "$app/vendor/$pkg" && dbg="$dbg $pkg"
  done
  echo "  debug pkgs:${dbg:- none}"
  [ -n "$dbg" ] && echo "              (with APP_DEBUG=true these expose traces/requests; old facade/ignition < 2.5.2 had a remote-code bug)"
  envcode=$($SUDO grep -rnE "environment\(|isLocal\(|isProduction\(|env\('APP_ENV'|APP_ENV" "$app/app" "$app/routes" "$app/bootstrap" "$app/config" \
      --include='*.php' 2>/dev/null | grep -v "^$app/config/app.php" | wc -l)
  echo "  env-dependent code lines in app/ routes/ bootstrap/ config/: $envcode  (review them before APP_ENV=production)"
  deploy=$($SUDO grep -rlsE "artisan migrate( |$)" "$app"/*.sh "$app"/deploy* "$app"/.github/workflows 2>/dev/null | head -n 3 | tr '\n' ' ')
  [ -n "$deploy" ] && echo "  deploy scripts calling 'artisan migrate' (needs --force in production): $deploy"
  logf="$app/storage/logs/laravel.log"
  $SUDO test -f "$logf" && echo "  laravel.log: last written $($SUDO stat -c %y "$logf" | cut -d. -f1)"
done
echo
echo "Only APP_ENV / APP_DEBUG values are printed by design. Do not print other keys of .env or the cached config."
