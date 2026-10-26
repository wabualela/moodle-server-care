#!/bin/bash
# realip-check.sh - after enabling real-IP, prove that the access log shows visitors, not Cloudflare edges.
#
# Reads the last N lines of the site's access log (first field = client address, as in the combined format and
# most custom formats) and counts how many client addresses fall inside the trusted Cloudflare ranges. It prints
# counts and percentages only, never the addresses themselves (they are personal data).
#
# Read-only. Needs read access to the log (uses sudo -n when available).
#
# Usage: realip-check.sh [--log FILE] [--lines N] [--ranges FILE] [--max-pct P]
#   --log      access log (default: the first access_log of the site's nginx vhost, else /var/log/nginx/access.log)
#   --lines    how many recent lines to check (default 3000). Wait a few minutes after the reload first.
#   --ranges   file with the trusted ranges: an nginx conf (set_real_ip_from), an Apache conf
#              (RemoteIPTrustedProxy) or a plain list (default /etc/nginx/conf.d/cloudflare-realip.conf)
#   --max-pct  fail when more than P% of the lines still come from Cloudflare ranges (default 1)
# Exit codes: 0 pass, 1 too many Cloudflare addresses, 2 usage/input problem.
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
LOG=""; LINES=3000; RANGES="/etc/nginx/conf.d/cloudflare-realip.conf"; MAXPCT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:?}"; shift 2 ;;
    --lines) LINES="${2:?}"; shift 2 ;;
    --ranges) RANGES="${2:?}"; shift 2 ;;
    --max-pct) MAXPCT="${2:?}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$LOG" ] && [ -n "${VHOST:-}" ] && [ -r "$VHOST" ]; then
  LOG=$(sed -nE 's/^[[:space:]]*access_log[[:space:]]+([^[:space:];]+).*/\1/p' "$VHOST" | grep -v '^off$' | head -n 1)
fi
LOG="${LOG:-/var/log/nginx/access.log}"

readf() { if [ -r "$1" ]; then cat -- "$1"; else $SUDO cat -- "$1"; fi; }
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

readf "$RANGES" 2>/dev/null | sed -nE \
  -e 's/^[[:space:]]*(set_real_ip_from|RemoteIPTrustedProxy|RemoteIPInternalProxy)[[:space:]]+([^;[:space:]]+).*/\2/p' \
  -e 's/^[[:space:]]*([0-9A-Fa-f.:]+\/[0-9]{1,3})[[:space:]]*$/\1/p' | sort -u > "$WORK/ranges"
[ -s "$WORK/ranges" ] || { echo "no ranges found in $RANGES (pass --ranges)"; exit 2; }

if [ -r "$LOG" ]; then tail -n "$LINES" -- "$LOG"; else $SUDO tail -n "$LINES" -- "$LOG"; fi 2>/dev/null \
  | awk '{print $1}' > "$WORK/ips"
[ -s "$WORK/ips" ] || { echo "no lines read from $LOG"; exit 2; }

echo "log: $LOG (last $(wc -l < "$WORK/ips") lines); trusted ranges: $(wc -l < "$WORK/ranges") from $RANGES"

if command -v python3 >/dev/null 2>&1; then
  python3 -I - "$WORK/ranges" "$WORK/ips" "$MAXPCT" <<'PY'
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip(), strict=False) for l in open(sys.argv[1]) if l.strip()]
v4 = [n for n in nets if n.version == 4]; v6 = [n for n in nets if n.version == 6]
total = cf = bad = 0
for line in open(sys.argv[2]):
    t = line.strip()
    if not t:
        continue
    total += 1
    try:
        a = ipaddress.ip_address(t)
    except ValueError:
        bad += 1
        continue
    if any(a in n for n in (v4 if a.version == 4 else v6)):
        cf += 1
pct = 100.0 * cf / total if total else 0.0
print(f"client addresses inside Cloudflare ranges: {cf} of {total} ({pct:.2f}%); unparsable first fields: {bad}")
if bad > total / 2:
    print("WARN: the first field is often not an IP address; check the log format (is $remote_addr first?)")
if pct > float(sys.argv[3]):
    print("FAIL: the log still shows Cloudflare edges as clients. Is real_ip_header set, the file included in the")
    print("      http context, nginx reloaded, and are these lines newer than the reload?")
    sys.exit(1)
print("PASS: clients are real visitors (Moodle, rate limits and logs see the right address).")
PY
  exit $?
fi

# Fallback without python3: IPv4 only.
awk -v maxpct="$MAXPCT" '
function ip2n(s,   p) { split(s, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
NR == FNR { if ($0 ~ /^[0-9.]+\/[0-9]+$/) { split($0, c, "/"); n++; net[n] = ip2n(c[1]); len[n] = c[2] } ; next }
{ total++; if ($1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { other++; next }
  a = ip2n($1)
  for (i = 1; i <= n; i++) { d = 2 ^ (32 - len[i]); if (int(a / d) == int(net[i] / d)) { cf++; break } } }
END { pct = total ? 100 * cf / total : 0
      printf "client addresses inside Cloudflare IPv4 ranges: %d of %d (%.2f%%); non-IPv4 first fields: %d (not checked, no python3)\n", cf, total, pct, other
      if (pct > maxpct) { print "FAIL: the log still shows Cloudflare edges as clients."; exit 1 }
      print "PASS (IPv4 only)." }' "$WORK/ranges" "$WORK/ips"
