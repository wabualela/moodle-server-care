#!/bin/bash
# moodle-smoke.sh - read-only smoke tests for every Moodle URL form that an nginx PHP-location change can break.
#
# Moodle depends on "slash arguments" (PATH_INFO): theme/styles.php/..., lib/javascript.php/..., lib/requirejs.php/...,
# theme/image.php/..., theme/font.php/..., pluginfile.php/..., and on 5.x r.php/<component>/esm/... If the PHP
# location loses PATH_INFO, the site loses all CSS, JavaScript and images at once. This script fetches one URL of
# each kind plus the tricky path forms (".php" inside a file path, a trailing slash after index.php), the AJAX
# endpoint, the admin entry point, and the probes that SHOULD be answered by nginx itself after hardening.
#
# By default it talks to the origin (127.0.0.1 with the site's name via --resolve), so it tests this nginx, not a
# Cloudflare cache. GET only; no forms, no logins, nothing written.
#
# Usage: moodle-smoke.sh [--base URL] [--public] [--phase before|after] [--extra PATH=EXPECT]...
#   --base    site URL incl. sub-path (default WWWROOT from server.env)
#   --public  go through public DNS (e.g. Cloudflare) instead of 127.0.0.1
#   --phase   before: phase-dependent probes are INFO only; after (default): they must match the hardened config
#   --extra   additional check, EXPECT one of: moodle | nginx | ok (2xx/3xx from Moodle) e.g. --extra /course/admin.php=moodle
# Source column: nginx = nginx's own error page; fpm = PHP-FPM "File not found." (script unknown); moodle = a page or
# JSON produced by Moodle; empty = no body.
# Exit codes: 0 all required checks pass, 1 at least one FAIL, 2 cannot reach the site.
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

BASE="${WWWROOT:-}"; PUBLIC=0; PHASE=after; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?}"; shift 2 ;;
    --public) PUBLIC=1; shift ;;
    --phase) PHASE="${2:?}"; shift 2 ;;
    --extra) EXTRA+=("${2:?}"); shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] || { echo "no site URL: --base https://<SITE>" >&2; exit 2; }
case "$PHASE" in before|after) ;; *) echo "--phase before|after" >&2; exit 2 ;; esac
BASE="${BASE%/}"
SCHEME=$(printf '%s' "$BASE" | sed -E 's#^(https?)://.*#\1#')
HOST=$(printf '%s' "$BASE" | sed -E 's#^https?://([^/:]+).*#\1#')
ORIGIN="$SCHEME://$HOST"; PFX=${BASE#"$ORIGIN"}
PORT=443; [ "$SCHEME" = http ] && PORT=80
CURLX=(-s -k --compressed --max-time 20 -A "moodle-server-care-smoke/1.0 (read-only)")
[ "$PUBLIC" = 0 ] && CURLX+=(--resolve "$HOST:$PORT:127.0.0.1")
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FAILS=0

fetch() {  # URL OUTFILE -> "code size"
  curl "${CURLX[@]}" -o "$2" -w '%{http_code} %{size_download}' "$1" 2>/dev/null || true
}
source_of() {  # FILE -> nginx|fpm|moodle|empty|other
  local f="$1"
  [ -s "$f" ] || { echo empty; return; }
  if grep -q '<center>nginx' "$f"; then echo nginx
  elif [ "$(tr -d '\r\n' < "$f")" = "File not found." ]; then echo fpm
  elif grep -qiE 'M\.cfg|moodle|<html|^[[:space:]]*[\[{]' "$f" 2>/dev/null; then echo moodle
  else echo other; fi
}
# check LABEL URL EXPECT MODE   EXPECT: ok200 | okany | moodle | nginx ; MODE: req | info
check() {
  local label="$1" url="$2" expect="$3" mode="$4" r code size src verdict
  r=$(fetch "$url" "$WORK/body"); code=${r%% *}; size=${r##* }; src=$(source_of "$WORK/body")
  case "$expect" in
    ok200) [ "$code" = 200 ] && [ "${size:-0}" -gt 0 ] && [ "$src" != nginx ] && verdict=PASS || verdict=FAIL ;;
    okany) [[ "$code" =~ ^[23] ]] && [ "$src" != nginx ] && verdict=PASS || verdict=FAIL ;;
    moodle) [ "$src" = moodle ] && [ "$code" != 502 ] && [ "$code" != 504 ] && verdict=PASS || verdict=FAIL ;;
    nginx) [ "$src" = nginx ] && [ "$code" = 404 ] && verdict=PASS || verdict=FAIL ;;
  esac
  if [ "$mode" = info ]; then verdict="INFO"; elif [ "$verdict" = FAIL ]; then FAILS=$((FAILS + 1)); fi
  printf '%-12s %-5s %-4s %8sB %-7s expect=%-7s %s\n' "$label" "$verdict" "$code" "${size:-0}" "$src" "$expect" \
    "$(printf '%s' "$url" | sed -E 's#^https?://[^/]+##' | cut -c1-90)"
}

r=$(fetch "$BASE/login/index.php" "$WORK/login.html"); [ "${r%% *}" = 200 ] || { echo "login page: HTTP ${r%% *} - cannot run"; exit 2; }
fetch "$BASE/" "$WORK/front.html" >/dev/null
host_re=$(printf '%s' "$HOST" | sed 's/\./\\./g'); pfx_re=$(printf '%s' "$PFX" | sed 's/\./\\./g')
find_url() {
  grep -ohE "(https?:)?//${host_re}${pfx_re}/$1[^\"' <>)\\\\]*" "$WORK/login.html" "$WORK/front.html" 2>/dev/null \
    | head -n 1 | sed -E 's/&amp;/\&/g; s#^//#'"$SCHEME"'://#'
}
U_STYLES=$(find_url 'theme/styles\.php/'); U_LIBJS=$(find_url 'lib/javascript\.php/'); U_REQ=$(find_url 'lib/requirejs\.php/')
U_YUI=$(find_url 'theme/yui_combo\.php\?'); U_IMG=$(find_url 'theme/image\.php/'); U_PF=$(find_url 'pluginfile\.php/')
U_ESM=$(grep -ohE "(https?:)?//${host_re}${pfx_re}/r\.php/[a-z0-9_]+/esm/[^\"' <>)\\\\]*" "$WORK/login.html" "$WORK/front.html" 2>/dev/null \
  | grep -v '/$' | head -n 1 | sed -E 's#^//#'"$SCHEME"'://#')
case "$U_REQ" in */) U_REQ="${U_REQ}core/first.js" ;; esac
U_FONT=""
if [ -n "$U_STYLES" ]; then
  fetch "$U_STYLES" "$WORK/styles.css" >/dev/null
  U_FONT=$(grep -ohE "${pfx_re}/theme/font\.php/[^\"' <>)\\\\]*" "$WORK/styles.css" 2>/dev/null | head -n 1)
  [ -n "$U_FONT" ] && case "$U_FONT" in http*) ;; //*) U_FONT="$SCHEME:$U_FONT" ;; *) U_FONT="$ORIGIN$U_FONT" ;; esac
fi

echo "== moodle-smoke $(date '+%F %T') $BASE via $( [ "$PUBLIC" = 1 ] && echo 'public DNS' || echo 'origin 127.0.0.1') phase=$PHASE =="
echo "-- pages and slash-argument URLs (must work in every phase) --"
check login "$BASE/login/index.php" ok200 req
check front "$BASE/" okany req
for pair in "styles|$U_STYLES" "lib_js|$U_LIBJS" "requirejs|$U_REQ" "yui_combo|$U_YUI" "theme_img|$U_IMG" "font|$U_FONT" "pluginfile|$U_PF" "esm|$U_ESM"; do
  label=${pair%%|*}; url=${pair#*|}
  if [ -n "$url" ]; then check "$label" "$url" ok200 req; else printf '%-12s %-5s (no such URL on the login/front page)\n' "$label" "skip"; fi
done
check ajax "$BASE/lib/ajax/service.php" moodle req
check my "$BASE/my/" okany req                         # login redirect or dashboard; never nginx
[ -n "${DOCROOT:-}" ] && [ -f "$DOCROOT/course/admin.php" ] && check course_adm "$BASE/course/admin.php" okany req

echo "-- path forms the PHP split must hand to Moodle (Moodle's own 404 is correct; nginx's page is a FAIL) --"
PFDIR=""
[ -n "$U_PF" ] && PFDIR=$(printf '%s' "$U_PF" | sed -E 's#[?].*##; s#/[^/]*$##')
[ -z "$PFDIR" ] && PFDIR="$BASE/pluginfile.php/1/core/msc-smoke/0"
check php_name "$PFDIR/msc-smoke-lab1.php" moodle req
check php_dir "$PFDIR/msc-smoke-dir.php/msc-smoke.txt" moodle req
check trail_sl "$BASE/login/index.php/" moodle req

echo "-- probes answered by nginx after hardening (phase=$PHASE) --"
M=req; [ "$PHASE" = before ] && M=info
check nope_php "$BASE/msc-smoke-nope.php" nginx "$M"
check wp_login "$BASE/wp-login.php" nginx "$M"
check scanner "$BASE/swagger/index.html" nginx "$M"
ROUTER=unknown
if [ -n "${DOCROOT:-}" ] && [ -d "$DOCROOT" ]; then [ -f "$DOCROOT/r.php" ] && ROUTER=yes || ROUTER=no; fi
case "$ROUTER" in
  yes) check unknown "$BASE/msc-smoke-unknown-url" moodle req ;;    # try_files ... /r.php: Moodle's router answers 404
  no) check unknown "$BASE/msc-smoke-unknown-url" nginx req ;;
  *) check unknown "$BASE/msc-smoke-unknown-url" moodle info ;;
esac

if [ "${#EXTRA[@]}" -gt 0 ]; then
  echo "-- extra --"
  for e in "${EXTRA[@]}"; do
    p=${e%%=*}; x=${e#*=}; [ "$x" = ok ] && x=okany
    check extra "$BASE$p" "$x" req
  done
fi

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "RESULT: FAIL ($FAILS). If any slash-argument URL or path form failed after a change: ROLL BACK NOW."
  exit 1
fi
echo "RESULT: PASS. Also open the site in a browser as a student: styled page, images, dashboard cards (AJAX), a video."
