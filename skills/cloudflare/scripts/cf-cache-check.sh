#!/bin/bash
# cf-cache-check.sh - prove that Cloudflare caches Moodle's versioned static URLs (MISS -> HIT) and that dynamic
# pages stay uncached (DYNAMIC/BYPASS), through the PUBLIC hostname. Read-only GET requests only.
#
# It reads the login page (and the front page) like a browser, picks one URL of each static kind Moodle links
# (theme/styles.php, theme/javascript.php, theme/jquery.php, theme/image.php, theme/font.php from the CSS,
# theme/yui_combo.php, lib/javascript.php, lib/requirejs.php), requests each up to N times and reads
# cf-cache-status. Then it requests dynamic pages twice and checks that none is ever served from cache.
#
# Safety checks that FAIL the run:
#   - a dynamic page answered HIT (Cloudflare would serve one user's page to another), or
#   - any HIT response that carries Set-Cookie (session leak risk).
# Static URLs that never reach HIT are FAIL (the cache rule does not match or the origin forbids caching).
# ESM (r.php/<component>/esm/) and page-builder media are INFO: they are cached only if you added them to the rule.
#
# Usage: cf-cache-check.sh [--base URL] [--tries N] [--sleep S] [--dynamic PATH]... [--static URL]...
#   --base     public site URL including any sub-path (default WWWROOT from server.env)
#   --dynamic  extra dynamic path to check (relative to --base), e.g. /course/view.php?id=2
#   --static   extra absolute static URL to check
# Exit codes: 0 pass, 1 at least one FAIL, 2 not behind Cloudflare / cannot fetch.
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

BASE="${WWWROOT:-}"; TRIES=3; SLEEP=2
DYN=(/ /login/index.php /course/index.php /my/ /lib/ajax/service.php)
EXTRA_STATIC=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?}"; shift 2 ;;
    --tries) TRIES="${2:?}"; shift 2 ;;
    --sleep) SLEEP="${2:?}"; shift 2 ;;
    --dynamic) DYN+=("${2:?}"); shift 2 ;;
    --static) EXTRA_STATIC+=("${2:?}"); shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] || { echo "no site URL: pass --base https://<SITE> or run start/scripts/detect-env.sh" >&2; exit 2; }
BASE="${BASE%/}"
ORIGIN=$(printf '%s' "$BASE" | sed -E 's#^(https?://[^/]+).*#\1#')   # scheme://host
HOST=$(printf '%s' "$ORIGIN" | sed -E 's#^https?://##')
PFX=${BASE#"$ORIGIN"}                                                # "" or "/moodle"
UA="moodle-server-care-cache-check/1.0 (read-only)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FAILS=0; WARNS=0

get_body() { curl -s --compressed --max-time 30 -A "$UA" -o "$2" -w '%{http_code}' "$1"; }
get_hdr() {  # URL -> headers on stdout (lower-cased names), body discarded
  curl -s --compressed --max-time 30 -A "$UA" -o /dev/null -D - "$1" | tr -d '\r' \
    | awk 'NR==1 {print "status: " $2; next} { i = index($0, ":"); if (i) print tolower(substr($0, 1, i - 1)) substr($0, i) }'
}
hval() { awk -v k="$2" 'BEGIN{FS=": *"} $1 == k { sub(/^[^:]*: */, ""); print; exit }' <<< "$1"; }

code=$(get_body "$BASE/login/index.php" "$WORK/login.html")
[ "$code" = 200 ] || { echo "cannot fetch $BASE/login/index.php (HTTP $code)"; exit 2; }
H=$(get_hdr "$BASE/login/index.php")
if ! grep -qiE '^server: cloudflare|^cf-ray:' <<< "$H"; then
  echo "$HOST does not answer through Cloudflare (no 'server: cloudflare' / cf-ray). Nothing to check."; exit 2
fi
COLO=$(hval "$H" cf-ray | sed -nE 's/.*-([A-Z]{3})$/\1/p')
echo "site: $BASE  (Cloudflare edge seen from here: ${COLO:-?}; students may use another edge with its own cache)"
get_body "$BASE/" "$WORK/front.html" >/dev/null || true

# --- collect one URL per static kind ---------------------------------------------------------------------------
pfx_re=$(printf '%s' "$PFX" | sed 's/\./\\./g')     # host names and Moodle sub-paths only need '.' escaped
host_re=$(printf '%s' "$HOST" | sed 's/\./\\./g')
find_url() {  # find_url REGEX_AFTER_PREFIX FILE... -> first absolute URL
  grep -ohE "(https?:)?//${host_re}${pfx_re}/$1[^\"' <>)\\\\]*" "${@:2}" 2>/dev/null | head -n 1 \
    | sed -E 's/&amp;/\&/g; s#^//#https://#'
}
declare -A URL=()
URL[styles]=$(find_url 'theme/styles\.php/' "$WORK/login.html" "$WORK/front.html")
URL[theme_js]=$(find_url 'theme/javascript\.php/' "$WORK/login.html" "$WORK/front.html")
URL[jquery]=$(find_url 'theme/jquery\.php/' "$WORK/login.html" "$WORK/front.html")
URL[image]=$(find_url 'theme/image\.php/' "$WORK/login.html" "$WORK/front.html")
URL[yui_combo]=$(find_url 'theme/yui_combo\.php\?' "$WORK/login.html" "$WORK/front.html")
URL[lib_js]=$(find_url 'lib/javascript\.php/' "$WORK/login.html" "$WORK/front.html")
URL[requirejs]=$(find_url 'lib/requirejs\.php/' "$WORK/login.html" "$WORK/front.html")
case "${URL[requirejs]}" in */) URL[requirejs]="${URL[requirejs]}core/first.js" ;; esac   # base URL -> a real module
if [ -n "${URL[styles]}" ]; then
  get_body "${URL[styles]}" "$WORK/styles.css" >/dev/null || true
  URL[font]=$(grep -ohE "(https?:)?//${host_re}${pfx_re}/theme/font\.php/[^\"' <>)\\\\]*" "$WORK/styles.css" 2>/dev/null \
    | head -n 1 | sed -E 's#^//#https://#')
  [ -z "${URL[font]}" ] && URL[font]=$(grep -ohE "${pfx_re}/theme/font\.php/[^\"' <>)\\\\]*" "$WORK/styles.css" 2>/dev/null \
    | head -n 1 | sed -E "s#^#${ORIGIN}#")
fi
INFO_ESM=$(grep -ohE "(https?:)?//${host_re}${pfx_re}/r\.php/[a-z0-9_]+/esm/[^\"' <>)\\\\]*" "$WORK/login.html" "$WORK/front.html" 2>/dev/null \
  | grep -vE '/$' | head -n 1 | sed -E 's#^//#https://#')
INFO_PB=$(find_url 'pluginfile\.php/1/local_edwiserpagebuilder/' "$WORK/front.html")

check_static() {  # LABEL URL MODE(fail|info)
  local label="$1" url="$2" mode="$3" i seq="" st cc sc hit=0 cookiehit=0 h
  for ((i = 1; i <= TRIES; i++)); do
    h=$(get_hdr "$url"); st=$(hval "$h" cf-cache-status); st=${st:-none}
    [ "$i" = 1 ] && cc=$(hval "$h" cache-control)
    sc=$(hval "$h" set-cookie)
    seq="$seq${seq:+>}$st"
    if [ "$st" = HIT ]; then hit=1; [ -n "$sc" ] && cookiehit=1; break; fi
    sleep "$SLEEP"
  done
  local verdict
  if [ "$cookiehit" = 1 ]; then verdict=FAIL-cookie-cached; FAILS=$((FAILS + 1))
  elif [ "$hit" = 1 ]; then verdict=PASS
  elif [ "$mode" = info ]; then verdict=INFO-not-cached
  else verdict=FAIL; FAILS=$((FAILS + 1)); fi
  printf '%-10s %-18s %-24s cc="%s"%s\n    %s\n' "$label" "$verdict" "$seq" "${cc:-}" "$( [ -n "$sc" ] && echo ' set-cookie=yes')" \
    "$(printf '%s' "$url" | sed -E 's#^https?://[^/]+##' | cut -c1-110)"
}

echo ""
echo "== static URLs (expect MISS/EXPIRED then HIT) =="
for k in styles theme_js jquery image font yui_combo lib_js requirejs; do
  if [ -n "${URL[$k]:-}" ]; then check_static "$k" "${URL[$k]}" fail
  else printf '%-10s %-18s (no such URL on the login/front page; skipped)\n' "$k" "n/a"; fi
done
for u in "${EXTRA_STATIC[@]}"; do check_static extra "$u" fail; done
[ -n "$INFO_ESM" ] && check_static esm "$INFO_ESM" info
[ -n "$INFO_PB" ] && check_static pagebuild "$INFO_PB" info

echo ""
echo "== dynamic pages (expect DYNAMIC, BYPASS or none; never HIT) =="
for p in "${DYN[@]}"; do
  seq=""; verdict=PASS
  for i in 1 2; do
    h=$(get_hdr "$BASE$p"); st=$(hval "$h" cf-cache-status); st=${st:-none}; seq="$seq${seq:+>}$st"
    [ "$i" = 1 ] && sleep 1
  done
  case "$seq" in
    *HIT*) verdict=FAIL-dynamic-cached; FAILS=$((FAILS + 1)) ;;
    *MISS*|*EXPIRED*|*REVALIDATED*|*UPDATING*|*STALE*) verdict=WARN-eligible; WARNS=$((WARNS + 1)) ;;
  esac
  mit=$(hval "$h" cf-mitigated); [ -n "$mit" ] && verdict="$verdict(cf-mitigated:$mit)"
  printf '%-28s %-20s %s\n' "$p" "$verdict" "$seq"
done

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "RESULT: FAIL ($FAILS). A dynamic HIT or a cached Set-Cookie: disable the cache rule NOW and investigate."
  echo "        A static URL that never hits: check the rule's paths (sub-path '$PFX'?) and the origin Cache-Control."
  exit 1
fi
[ "$WARNS" -gt 0 ] && echo "RESULT: PASS with $WARNS warning(s): a dynamic page is marked eligible for cache (MISS); review the rules." && exit 0
echo "RESULT: PASS"
