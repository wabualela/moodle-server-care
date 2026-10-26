#!/bin/bash
# cf-ranges.sh - build the "real client IP" configuration from Cloudflare's published edge ranges.
#
# Why this script exists: on the first server the ranges were pasted with `cat ips-v4 ips-v6`. Cloudflare's
# ips-v4 file has NO trailing newline, so the last IPv4 range and the first IPv6 range ended up glued on one line
# ("131.0.72.0/222400:cb00::/32") and `nginx -t` failed. This script reads every line even without a final
# newline, validates every range, refuses implausible lists, and always writes one range per line.
#
# Read-only by default: prints the configuration to stdout. With --out it writes a NEW candidate file (never the
# live one unless you point it there and pass --overwrite). It never reloads anything.
#
# Usage:
#   cf-ranges.sh [--v4 FILE|URL] [--v6 FILE|URL] [--format nginx|apache] [--geo] [--origin-ip IP]
#                [--out FILE [--overwrite]] [--compare LIVE_FILE] [--min-v4 N] [--min-v6 N]
#
#   --v4/--v6     sources (default https://www.cloudflare.com/ips-v4 and /ips-v6; local files work offline)
#   --format      nginx (set_real_ip_from + real_ip_header CF-Connecting-IP) or apache (mod_remoteip)
#   --geo         nginx only: also emit `geo $realip_remote_addr $from_cloudflare` for a later origin lock
#                 (harmless until a vhost uses $from_cloudflare). Includes 127.0.0.1, ::1 and --origin-ip.
#   --origin-ip   the server's own public IP for the geo block (default ORIGIN_IP from server.env)
#   --compare     compare the freshly built list with the ranges in an existing file; exit 0 same, 1 differ
#   --min-v4/-v6  sanity floor (default 10 / 5; Cloudflare published 15 / 7 in 2026)
#
# Exit codes: 0 ok, 1 compare found differences, 2 usage, 3 validation failed (nothing written).
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

V4_SRC="https://www.cloudflare.com/ips-v4"
V6_SRC="https://www.cloudflare.com/ips-v6"
FORMAT=nginx; GEO=0; OUT=""; OVERWRITE=0; COMPARE=""; MIN4=10; MIN6=5
ORIGIN="${ORIGIN_IP:-}"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --v4) V4_SRC="${2:?}"; shift 2 ;;
    --v6) V6_SRC="${2:?}"; shift 2 ;;
    --format) FORMAT="${2:?}"; shift 2 ;;
    --geo) GEO=1; shift ;;
    --origin-ip) ORIGIN="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --overwrite) OVERWRITE=1; shift ;;
    --compare) COMPARE="${2:?}"; shift 2 ;;
    --min-v4) MIN4="${2:?}"; shift 2 ;;
    --min-v6) MIN6="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
case "$FORMAT" in nginx|apache) ;; *) echo "--format must be nginx or apache" >&2; exit 2 ;; esac
[ "$GEO" = 1 ] && [ "$FORMAT" != nginx ] && { echo "--geo is for nginx only" >&2; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch SRC DEST
  case "$1" in
    http://*|https://*)
      curl -fsS --max-time 20 --retry 2 -o "$2" "$1" || { echo "ERROR: could not download $1" >&2; return 1; } ;;
    *) [ -r "$1" ] || { echo "ERROR: cannot read $1" >&2; return 1; }; cat -- "$1" > "$2" ;;
  esac
}

# read_ranges FILE FAMILY -> prints validated, de-duplicated ranges, one per line; returns 3 on any bad line.
read_ranges() {
  local file="$1" fam="$2" line n=0 bad=0
  declare -A seen=()
  # `|| [ -n "$line" ]` keeps the last line when the file has no trailing newline (the bug on the first server).
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line//$'\r'/}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if ! valid_cidr "$line" "$fam"; then
      echo "ERROR: $fam source line $n is not a single valid CIDR: '$line'" >&2; bad=1; continue
    fi
    [ -n "${seen[$line]:-}" ] && continue
    seen[$line]=1; printf '%s\n' "$line"
  done < "$file"
  [ "$bad" = 0 ] || return 3
}

valid_cidr() {  # valid_cidr TEXT v4|v6
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import ipaddress, sys
t, fam = sys.argv[1], sys.argv[2]
try:
    n = ipaddress.ip_network(t, strict=True)
except ValueError:
    sys.exit(1)
sys.exit(0 if ("/" in t and n.version == (4 if fam == "v4" else 6)) else 1)' "$1" "$2"
    return
  fi
  # Fallback without python3: shape check only.
  if [ "$2" = v4 ]; then
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local i; for i in 1 2 3 4; do [ "${BASH_REMATCH[$i]}" -le 255 ] || return 1; done
    [ "${BASH_REMATCH[5]}" -le 32 ]
  else
    [[ "$1" =~ ^[0-9A-Fa-f:]+/([0-9]{1,3})$ ]] && [[ "$1" == *:* ]] && [ "${BASH_REMATCH[1]}" -le 128 ]
  fi
}

fetch "$V4_SRC" "$WORK/v4.src" || exit 3
fetch "$V6_SRC" "$WORK/v6.src" || exit 3
read_ranges "$WORK/v4.src" v4 > "$WORK/v4" || { echo "Nothing written: fix the source list first." >&2; exit 3; }
read_ranges "$WORK/v6.src" v6 > "$WORK/v6" || { echo "Nothing written: fix the source list first." >&2; exit 3; }
N4=$(wc -l < "$WORK/v4"); N6=$(wc -l < "$WORK/v6")
if [ "$N4" -lt "$MIN4" ] || [ "$N6" -lt "$MIN6" ]; then
  echo "ERROR: implausible list (v4=$N4 < $MIN4 or v6=$N6 < $MIN6). Did the download return an error page?" >&2
  exit 3
fi

if [ -n "$ORIGIN" ] && [ "$GEO" = 1 ] && ! valid_cidr "$ORIGIN/32" v4; then
  echo "ERROR: --origin-ip '$ORIGIN' is not an IPv4 address" >&2; exit 2
fi

build() {
  local stamp; stamp=$(date '+%F %T %Z')
  if [ "$FORMAT" = nginx ]; then
    echo "# Cloudflare edge ranges -> real client IP from CF-Connecting-IP (http context, e.g. /etc/nginx/conf.d/)."
    echo "# Generated by moodle-server-care cloudflare/scripts/cf-ranges.sh on $stamp"
    echo "# Sources: $V4_SRC ($N4 IPv4), $V6_SRC ($N6 IPv6). Regenerate with the script; do not hand-edit."
    echo "# Requests from these ranges get \$remote_addr from CF-Connecting-IP; any other peer keeps its own address."
    while IFS= read -r r; do printf 'set_real_ip_from %s;\n' "$r"; done < "$WORK/v4"
    while IFS= read -r r; do printf 'set_real_ip_from %s;\n' "$r"; done < "$WORK/v6"
    echo "real_ip_header CF-Connecting-IP;"
    if [ "$GEO" = 1 ]; then
      echo ""
      echo "# Origin lock helper: 1 when the TCP peer (\$realip_remote_addr, NOT the client) is a Cloudflare edge or"
      echo "# this server. Unused until a server block adds: if (\$from_cloudflare = 0) { return 444; }"
      echo "# Plain allow/deny would test the client address after real_ip and refuse every visitor."
      echo 'geo $realip_remote_addr $from_cloudflare {'
      echo '    default 0;'
      echo '    127.0.0.1/32 1;'
      echo '    ::1/128 1;'
      [ -n "$ORIGIN" ] && printf '    %s/32 1;   # this server (own monitors and curl)\n' "$ORIGIN"
      while IFS= read -r r; do printf '    %s 1;\n' "$r"; done < "$WORK/v4"
      while IFS= read -r r; do printf '    %s 1;\n' "$r"; done < "$WORK/v6"
      echo '}'
    fi
  else
    echo "# Cloudflare edge ranges -> real client IP (Apache mod_remoteip; enable with: a2enmod remoteip)."
    echo "# Generated by moodle-server-care cloudflare/scripts/cf-ranges.sh on $stamp"
    echo "# Sources: $V4_SRC ($N4 IPv4), $V6_SRC ($N6 IPv6). Regenerate with the script; do not hand-edit."
    echo "# RemoteIPTrustedProxy (not RemoteIPInternalProxy): Cloudflare ranges are public addresses."
    echo "RemoteIPHeader CF-Connecting-IP"
    while IFS= read -r r; do printf 'RemoteIPTrustedProxy %s\n' "$r"; done < "$WORK/v4"
    while IFS= read -r r; do printf 'RemoteIPTrustedProxy %s\n' "$r"; done < "$WORK/v6"
  fi
}

build > "$WORK/out"

# Self-check: every directive line must hold exactly one range. This is the check that would have caught the glued
# line before nginx -t did.
if [ "$FORMAT" = nginx ]; then
  BADL=$(grep -vE '^(#.*|$|set_real_ip_from [0-9A-Fa-f.:]+/[0-9]{1,3};|real_ip_header CF-Connecting-IP;|geo \$realip_remote_addr \$from_cloudflare \{|    default 0;|    [0-9A-Fa-f.:]+/[0-9]{1,3} 1;.*|\})$' "$WORK/out"); GRC=$?
else
  BADL=$(grep -vE '^(#.*|$|RemoteIPHeader CF-Connecting-IP|RemoteIPTrustedProxy [0-9A-Fa-f.:]+/[0-9]{1,3})$' "$WORK/out"); GRC=$?
fi
# grep -v exits 1 when every line is good, 0 when it printed bad lines, >1 when it could not run: fail closed.
if [ "$GRC" -gt 1 ]; then echo "ERROR: self-check could not run (grep exit $GRC); nothing written" >&2; exit 3; fi
if [ -n "$BADL" ]; then echo "ERROR: self-check failed on: $BADL" >&2; exit 3; fi

if [ -n "$COMPARE" ]; then
  [ -r "$COMPARE" ] || { echo "cannot read $COMPARE" >&2; exit 2; }
  sed -nE 's/^[[:space:]]*(set_real_ip_from|RemoteIPTrustedProxy|RemoteIPInternalProxy)[[:space:]]+([^;[:space:]]+).*/\2/p' "$COMPARE" | sort -u > "$WORK/live"
  sort -u "$WORK/v4" "$WORK/v6" > "$WORK/new"
  ADDED=$(comm -13 "$WORK/live" "$WORK/new"); REMOVED=$(comm -23 "$WORK/live" "$WORK/new")
  if [ -z "$ADDED" ] && [ -z "$REMOVED" ]; then
    echo "SAME: $COMPARE holds exactly the $((N4 + N6)) published ranges."; exit 0
  fi
  echo "DIFFERENT: $COMPARE does not match the published list."
  [ -n "$ADDED" ] && { echo "  published but missing from the live file:"; printf '    %s\n' $ADDED; }
  [ -n "$REMOVED" ] && { echo "  in the live file but no longer published:"; printf '    %s\n' $REMOVED; }
  echo "Regenerate with --out, diff, then install with the change protocol (backup, nginx -t, reload, verify)."
  exit 1
fi

if [ -n "$OUT" ]; then
  if [ -e "$OUT" ] && [ "$OVERWRITE" != 1 ]; then echo "ERROR: $OUT exists; pass --overwrite (after a backup)" >&2; exit 2; fi
  TMP="$OUT.tmp.$$"
  cat "$WORK/out" > "$TMP" && chmod 644 "$TMP" && mv -f "$TMP" "$OUT" || { rm -f "$TMP"; echo "ERROR: could not write $OUT" >&2; exit 3; }
  echo "written: $OUT ($N4 IPv4 + $N6 IPv6 ranges, format $FORMAT$( [ "$GEO" = 1 ] && echo ', with geo block'))" >&2
else
  cat "$WORK/out"
fi
