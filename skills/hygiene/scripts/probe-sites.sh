#!/bin/bash
# probe-sites.sh — read-only before/after probe of every site this web server serves, at the ORIGIN (127.0.0.1), by
# SNI/Host. Prints one stable line per name, so two runs can be compared with diff. Sends only GET / requests.
#
# Usage: bash probe-sites.sh [EXTRA_HOST ...] > /path/before.txt   ... change ...   bash probe-sites.sh > after.txt
#        diff before.txt after.txt     (only the names you meant to change may differ)
# Names come from server_name (nginx) or ServerName/ServerAlias (Apache) in the enabled config; wildcards and '_'
# are skipped. A random name and the bare address show how unknown hosts are answered.
# Why: removing a vhost, a certificate or an app can silently change what OTHER names on the box answer (the first
# vhost becomes the catch-all). The diff proves that only the intended name changed.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo
T="${PROBE_TIMEOUT:-8}"

names=$(msc_webconf_dump | awk '
  { sub(/#.*/, "") }
  /(^|[[:space:]])server_name[[:space:]]/ { s = $0; sub(/.*server_name[[:space:]]+/, "", s); sub(/;.*/, "", s); print s }
  /^[[:space:]]*(ServerName|ServerAlias)[[:space:]]/ { $1 = ""; print }' | tr ' ' '\n' | grep -vE '^$|^_$|\*|^~|^localhost$|^[0-9.]+$' | sort -u)
rnd="probe-$(date +%s)-unknown.invalid"
for h in $names "$@"; do
  s=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$T" --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null); e1=$?
  p=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$T" -H "Host: $h" "http://127.0.0.1/" 2>/dev/null); e2=$?
  printf '%-40s https=%s(rc%s) http=%s(rc%s)\n' "$h" "$s" "$e1" "$p" "$e2"
done
s=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$T" --resolve "$rnd:443:127.0.0.1" "https://$rnd/" 2>/dev/null); e1=$?
p=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$T" -H "Host: $rnd" "http://127.0.0.1/" 2>/dev/null); e2=$?
printf '%-40s https=%s(rc%s) http=%s(rc%s)\n' "(unknown name)" "$s" "$e1" "$p" "$e2"
s=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$T" "https://127.0.0.1/" 2>/dev/null); e1=$?
printf '%-40s https=%s(rc%s)\n' "(bare address, no SNI)" "$s" "$e1"
# rc35 = TLS handshake refused, rc52 = empty reply (nginx 444): both mean "refused", which is right for unknown names.
