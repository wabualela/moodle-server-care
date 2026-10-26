#!/bin/bash
# rl-review.sh - review nginx rate-limit dry-run (or enforcement) data before deciding to enforce or relax.
#
# Reads (including rotated .gz files):
#   - the dedicated rate-limit log written with `access_log ... moodle_rl if=$rl_hit` (assets/moodle-ratelimit.conf):
#     "<iso time> <client> "<method> <request_uri>" <status> lrs=<limit_req_status> lcs=<limit_conn_status> ua="..."
#   - the site's error log lines "limiting requests, dry run ... by zone" / "limiting connections, dry run by zone".
# Prints counts by zone and day, top clients (masked by default), top paths (query stripped, numbers normalised),
# top user agents and a browser / tool / bot / app split, then the decision rules.
# Optionally (--access-log) counts 429 answers in the main access log after enforcement.
#
# Read-only. Uses sudo -n to read root-only logs. Client addresses are personal data: they are masked (a.b.c.x)
# unless --raw is given, and must not be pasted into tickets or reports.
#
# Usage: rl-review.sh [--rl-log FILE] [--error-log FILE] [--access-log FILE] [--raw] [--top N]
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
RL="/var/log/nginx/moodle-ratelimit.log"; ERR=""; ACC=""; RAW=0; TOP=20
while [ $# -gt 0 ]; do
  case "$1" in
    --rl-log) RL="${2:?}"; shift 2 ;;
    --error-log) ERR="${2:?}"; shift 2 ;;
    --access-log) ACC="${2:?}"; shift 2 ;;
    --raw) RAW=1; shift ;;
    --top) TOP="${2:?}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$ERR" ] && [ -n "${VHOST:-}" ]; then
  ERR=$({ cat "$VHOST" 2>/dev/null || $SUDO cat "$VHOST" 2>/dev/null; } | sed -nE 's/^[[:space:]]*error_log[[:space:]]+([^[:space:];]+).*/\1/p' | head -n 1)
fi
ERR="${ERR:-/var/log/nginx/error.log}"

catall() {  # BASE -> BASE.N.gz (oldest first) ... BASE.1 BASE, decompressed; sudo only when needed
  local b="$1" f
  for f in $( { ls -1 "$b".*.gz 2>/dev/null || $SUDO sh -c 'ls -1 "$1".*.gz' sh "$b" 2>/dev/null; } \
              | sed -nE 's/^(.*\.([0-9]+)\.gz)$/\2 \1/p' | sort -rn | cut -d' ' -f2-); do
    if [ -r "$f" ]; then zcat -f -- "$f"; else $SUDO zcat -f -- "$f"; fi 2>/dev/null
  done
  for f in "$b.1" "$b"; do
    if [ -r "$f" ]; then cat -- "$f"; elif $SUDO test -f "$f" 2>/dev/null; then $SUDO cat -- "$f"; fi
  done
}
mask_awk='function mask(a,  p, n) { if (raw == 1) return a
  if (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(a, p, "."); return p[1] "." p[2] "." p[3] ".x" }
  n = split(a, p, ":"); if (n >= 3) return p[1] ":" p[2] ":" p[3] "::x"; return "?" }'
uaclass_awk='function uaclass(u,  l) { l = tolower(u)
  if (l ~ /moodlemobile/) return "moodle-app"
  if (l ~ /curl|wget|python|go-http|java\/|okhttp|libwww|httpclient|axios|node-fetch|scrapy|nikto|sqlmap|nmap|masscan|zgrab|nuclei|headless|^-?$/) return "tool"
  if (l ~ /bot|crawl|spider|slurp|preview|facebookexternalhit|monitor/) return "bot"
  if (l ~ /mozilla\/5\.0/ && l ~ /chrome|safari|firefox|edg|opr/) return "browser"
  return "other" }'

WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
catall "$ERR" | grep -E 'limiting (requests|connections)' > "$WORK/err" || true
catall "$RL" > "$WORK/rl" || true

echo "== rate-limit review $(date '+%F %T %Z') =="
echo "error log: $ERR ($(wc -l < "$WORK/err") limiting lines); rate-limit log: $RL ($(wc -l < "$WORK/rl") lines)"
echo ""
echo "-- by zone (error log; 'dry run' = would have been limited) --"
sed -nE 's/.*limiting (requests|connections)(, dry run)?.* by zone "([A-Za-z0-9_]+)".*/\3 \1\2/p' "$WORK/err" \
  | sort | uniq -c | sort -rn | sed 's/^/  /'
echo "-- by day and zone --"
sed -nE 's#^([0-9]{4}/[0-9]{2}/[0-9]{2}) .* by zone "([A-Za-z0-9_]+)".*#\1 \2#p' "$WORK/err" | sort | uniq -c | sed 's/^/  /'

if [ -s "$WORK/rl" ]; then
  echo "-- top clients (rate-limit log; $( [ "$RAW" = 1 ] && echo raw || echo masked)) --"
  awk -v raw="$RAW" "$mask_awk"' { print mask($2) }' "$WORK/rl" | sort | uniq -c | sort -rn | head -n "$TOP" | sed 's/^/  /'
  echo "-- top paths (query removed, numbers as <n>) with status --"
  awk '{ p = $4; sub(/"$/, "", p); sub(/\?.*/, "", p); gsub(/[0-9]+/, "<n>", p); print $5, substr($3, 2), p }' "$WORK/rl" \
    | sort | uniq -c | sort -rn | head -n "$TOP" | sed 's/^/  /'
  echo "-- user agent classes --"
  awk "$uaclass_awk"' { i = index($0, "ua=\""); u = (i ? substr($0, i + 4) : ""); sub(/"$/, "", u); print uaclass(u) }' "$WORK/rl" \
    | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo "-- top user agents (60 chars) --"
  awk '{ i = index($0, "ua=\""); u = (i ? substr($0, i + 4) : ""); sub(/"$/, "", u); print substr(u, 1, 60) }' "$WORK/rl" \
    | sort | uniq -c | sort -rn | head -n 15 | sed 's/^/  /'
  echo "-- browser user agents by client (the ones that matter: NAT groups, labs, real students) --"
  awk -v raw="$RAW" "$mask_awk $uaclass_awk"' { i = index($0, "ua=\""); u = (i ? substr($0, i + 4) : ""); sub(/"$/, "", u)
      if (uaclass(u) == "browser") print mask($2), $6, $7 }' "$WORK/rl" | sort | uniq -c | sort -rn | head -n 10 | sed 's/^/  /'
fi

if [ -n "$ACC" ]; then
  catall "$ACC" | awk '$9 == 429' > "$WORK/429" || true
  echo "-- 429 answers in $ACC: $(wc -l < "$WORK/429") --"
  awk "$uaclass_awk"' { split($0, q, "\""); print uaclass(q[6]) }' "$WORK/429" | sort | uniq -c | sort -rn | sed 's/^/  /'
  awk '{ split($0, q, "\""); split(q[2], r, " "); p = r[2]; sub(/\?.*/, "", p); gsub(/[0-9]+/, "<n>", p); print p }' "$WORK/429" \
    | sort | uniq -c | sort -rn | head -n 10 | sed 's/^/  /'
fi

cat <<'EOF'

Decision rules (references/rate-limits.md):
- Would-be rejections only from tools, scanners, bots or flood minutes (many distinct paths, one client): enforce.
- A browser user agent with normal page views in a front-page zone (a class opening the home page together, a
  school or carrier NAT address): double that zone (burst, or the limit_conn number), dry-run another 24 h.
- moodle-app hits: never enforce a limit that hits the Moodle mobile app without raising it first.
- After enforcement: 429s to browsers or the app should be about zero; check weekly with --access-log.
EOF
