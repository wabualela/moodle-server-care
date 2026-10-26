#!/usr/bin/env bash
# static-check.sh — READ-ONLY probe of how the site's pages and static files are cached and compressed.
#
# Usage: bash static-check.sh [--origin] [--max-files=N] [URL...]
#   (no URL)    fetch the front page as a guest, then probe the static URLs it references: theme CSS
#               (styles.php), JavaScript (javascript.php, requirejs.php, yui_combo.php), theme images and fonts
#               (image.php, font.php), the first few pluginfile.php files and /favicon.ico
#   --origin    connect to 127.0.0.1 with the site's name (curl --resolve), bypassing any CDN, to see what the
#               origin sends; without it the request goes through Cloudflare when the site is behind it
#   URL...      probe only these URLs
# Prints status, Cache-Control, Expires, Content-Encoding, CDN cache status, whether a Set-Cookie header is present
# (never its value), type and size; for the front page also the HTML size (raw and on the wire) and <script> count.
# Only GET requests as a logged-out visitor: nothing is changed on the site.
set -uo pipefail
set +x
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-env.sh
. "$here/lib-env.sh"
msc_load_env

origin=0; max=3; urls=()
for a in "$@"; do
    case "$a" in
        --origin) origin=1 ;;
        --max-files=*) max=${a#*=} ;;
        -h|--help) sed -n '2,15{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) urls+=("$a") ;;
    esac
done
msc_need SITE
res=()
[ "$origin" = 1 ] && res=(--resolve "$SITE:443:127.0.0.1")
ua='Mozilla/5.0 (moodle-server-care static-check)'
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

probe() {  # probe URL -> one line
    local url=$1 h st cc ex ce cf sc ct cl
    h=$(curl -s "${res[@]}" -A "$ua" -H 'Accept-Encoding: gzip, br' --max-time 20 -o /dev/null -D - "$url" | tr -d '\r')
    st=$(printf '%s\n' "$h" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')
    hv() { printf '%s\n' "$h" | grep -i "^$1:" | head -n 1 | cut -d: -f2- | sed 's/^ *//'; }
    cc=$(hv cache-control); ex=$(hv expires); ce=$(hv content-encoding); cf=$(hv cf-cache-status)
    ct=$(hv content-type | cut -d';' -f1); cl=$(hv content-length)
    sc=no; printf '%s\n' "$h" | grep -qi '^set-cookie:' && sc=yes
    printf '%-4s %-40s cc=[%s] exp=[%s] enc=%s cdn=%s cookie=%s type=%s len=%s\n' "${st:-ERR}" \
        "$(printf '%s' "$url" | sed -E "s#^https?://[^/]+##" | cut -c1-40)" "${cc:--}" "${ex:--}" "${ce:--}" \
        "${cf:--}" "$sc" "${ct:--}" "${cl:--}"
}

echo "== static caching check $(date '+%F %T %Z') site=$SITE via=$([ "$origin" = 1 ] && echo 'origin 127.0.0.1' || echo 'public DNS') =="
if [ "${#urls[@]}" -eq 0 ]; then
    w=$(curl -s "${res[@]}" -A "$ua" --compressed --max-time 30 -o "$tmp/home.html" -w '%{http_code} %{size_download} %{time_starttransfer}' "https://$SITE/")
    read -r code wire ttfb <<<"$w"
    raw=$(wc -c < "$tmp/home.html" 2>/dev/null || echo 0)
    scripts=$(grep -oi '<script' "$tmp/home.html" | wc -l)
    echo "front page: HTTP $code, HTML ${raw} B raw / ${wire} B on the wire, TTFB ${ttfb}s (one sample), <script> tags: $scripts"
    # Collect static URLs referenced by the page (absolute, protocol-relative or root-relative).
    grep -oE "(https?:)?//$SITE/[^\"' )<>]+|[\"'](/[^\"' )<>]+)" "$tmp/home.html" | tr -d "\"'" \
        | sed -E "s#^(https?:)?//$SITE##; s#&amp;#\\&#g" | sort -u > "$tmp/refs"
    for pat in '/theme/styles\.php/' '/lib/javascript\.php/' '/lib/requirejs\.php/' '/theme/yui_combo\.php' \
               '/theme/image\.php/' '/theme/font\.php/'; do
        u=$(grep -E "^$pat" "$tmp/refs" | head -n 1); [ -n "$u" ] && urls+=("https://$SITE$u")
    done
    while IFS= read -r u; do urls+=("https://$SITE$u"); done < <(grep -E '^/pluginfile\.php/' "$tmp/refs" | head -n "$max")
    urls+=("https://$SITE/favicon.ico")
fi
for u in "${urls[@]}"; do probe "$u"; done
cat <<'EOF'
reading: versioned theme/JS URLs should say public, a long max-age (Moodle sends 90 days) and immutable, gzip or br
for CSS/JS/SVG, and no Set-Cookie. "private, max-age=10" on images that every visitor sees means browsers fetch
them again through PHP on every view. A CDN only stores responses without Set-Cookie. /favicon.ico 404 means each
browser request boots Moodle. Run once with --origin and once without to tell origin from CDN behaviour.
EOF
