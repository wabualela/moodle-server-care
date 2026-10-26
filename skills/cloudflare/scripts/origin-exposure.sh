#!/bin/bash
# origin-exposure.sh - which DNS names reveal this server's real IP, and is there a wildcard record?
#
# Cloudflare only protects names whose DNS answer is a Cloudflare address ("proxied", orange cloud). Any other
# name that resolves to the origin IP (another site on the same box, a DNS-only record, a wildcard, the MX host)
# tells scanners where to go around Cloudflare. A wildcard record also makes every misspelt or retired name
# resolve and land on whichever vhost the web server picks as its default.
#
# Read-only: DNS lookups through the server's resolver plus reading the web server configuration.
#
# Usage: origin-exposure.sh [--origin-ip IP] [--ranges FILE] [--names-file FILE] [--extra NAME]... [--common]
#   --origin-ip   the server's PUBLIC IPv4 (default ORIGIN_IP from server.env; behind NAT pass the public one)
#   --ranges      Cloudflare ranges (nginx/Apache conf or list; default /etc/nginx/conf.d/cloudflare-realip.conf)
#   --names-file  extra names, one per line (for example the full DNS zone export from the Cloudflare dashboard)
#   --common      also test common leak names under each zone (mail, ftp, cpanel, webmail, direct, origin, dev,
#                 staging, test, old, admin)
# Output: one line per name: DNS answers and a class: PROXIED / EXPOSES-ORIGIN / ELSEWHERE / NO-RECORD.
# Exit codes: 0 nothing exposes the origin, 1 at least one name exposes it, 2 usage problem.
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
NGINX_BIN="${NGINX_BIN:-$(command -v nginx || echo /usr/sbin/nginx)}"
APACHECTL="${APACHECTL:-$(command -v apache2ctl || command -v apachectl || echo /usr/sbin/apache2ctl)}"
ORIGIN="${ORIGIN_IP:-}"; RANGES="/etc/nginx/conf.d/cloudflare-realip.conf"; NAMES_FILE=""; COMMON=0; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --origin-ip) ORIGIN="${2:?}"; shift 2 ;;
    --ranges) RANGES="${2:?}"; shift 2 ;;
    --names-file) NAMES_FILE="${2:?}"; shift 2 ;;
    --extra) EXTRA+=("${2:?}"); shift 2 ;;
    --common) COMMON=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ORIGIN" ] || { echo "no origin IP: pass --origin-ip or run start/scripts/detect-env.sh" >&2; exit 2; }
case "$ORIGIN" in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
    echo "WARN: $ORIGIN is a private address (NAT). Pass the public IPv4 with --origin-ip for a meaningful result." ;;
esac

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
readf() { if [ -r "$1" ]; then cat -- "$1"; else $SUDO cat -- "$1"; fi; }

# --- Cloudflare ranges -----------------------------------------------------------------------------------------
readf "$RANGES" 2>/dev/null | sed -nE \
  -e 's/^[[:space:]]*(set_real_ip_from|RemoteIPTrustedProxy|RemoteIPInternalProxy)[[:space:]]+([^;[:space:]]+).*/\2/p' \
  -e 's/^[[:space:]]*([0-9A-Fa-f.:]+\/[0-9]{1,3})[[:space:]]*$/\1/p' | sort -u > "$WORK/ranges"
if [ ! -s "$WORK/ranges" ]; then
  HERE=$(cd "$(dirname "$0")" && pwd)
  echo "note: no ranges in $RANGES; fetching Cloudflare's published list with cf-ranges.sh" >&2
  bash "$HERE/cf-ranges.sh" 2>/dev/null | sed -nE 's/^set_real_ip_from ([^;]+);/\1/p' > "$WORK/ranges"
fi
[ -s "$WORK/ranges" ] || { echo "no Cloudflare ranges available (pass --ranges)"; exit 2; }

# --- names served by this web server ---------------------------------------------------------------------------
{
  if [ -x "$NGINX_BIN" ]; then
    $SUDO "$NGINX_BIN" -T 2>/dev/null | sed -E 's/#.*//' | grep -oE '(^|[;{[:space:]])server_name[[:space:]][^;]*' \
      | sed -E 's/.*server_name[[:space:]]+//' | tr ' \t' '\n\n'
  fi
  if [ -x "$APACHECTL" ]; then
    $SUDO "$APACHECTL" -S 2>/dev/null | sed -nE 's/.*(namevhost|alias)[[:space:]]+([^[:space:]]+).*/\2/p'
  fi
  [ -n "${SITE:-}" ] && echo "$SITE"
  [ -n "$NAMES_FILE" ] && grep -vE '^[[:space:]]*(#|$)' "$NAMES_FILE"
  printf '%s\n' "${EXTRA[@]}"
} | tr 'A-Z' 'a-z' | sed -E 's/\.$//' \
  | grep -vE '^(|_|localhost|~.*|"")$' | grep -vE '^[0-9.]+$' | grep -E '\.' | sort -u > "$WORK/names.raw"

# Two-level public suffixes common for the owner's region and elsewhere (heuristic, extend when needed).
apex_of() {
  local n="$1" l2 l3
  l2=$(printf '%s' "$n" | awk -F. '{print $(NF-1) "." $NF}')
  case "$l2" in
    com.sa|net.sa|org.sa|edu.sa|gov.sa|med.sa|sch.sa|pub.sa|co.uk|org.uk|ac.uk|com.au|net.au|org.au|co.za|com.eg|edu.eg|gov.eg|com.tr|co.jp|com.br|com.my|com.kw|com.qa|com.bh|co.ae|com.jo|com.om|edu.jo)
      l3=$(printf '%s' "$n" | awk -F. 'NF >= 3 {print $(NF-2) "." $(NF-1) "." $NF}'); printf '%s\n' "${l3:-$n}" ;;
    *) printf '%s\n' "$l2" ;;
  esac
}

: > "$WORK/names"; : > "$WORK/zones"
while IFS= read -r n; do
  case "$n" in
    \*.*) z="${n#\*.}"; echo "$z" >> "$WORK/zones"; echo "msc-probe-$RANDOM$RANDOM.$z" >> "$WORK/names" ;;  # wildcard vhost
    .*) z="${n#.}"; echo "$z" >> "$WORK/names"; echo "$z" >> "$WORK/zones" ;;
    *) echo "$n" >> "$WORK/names"; apex_of "$n" >> "$WORK/zones"
       p="${n#*.}"; [ "$p" != "$(apex_of "$n")" ] && [[ "$p" == *.* ]] && echo "$p" >> "$WORK/zones" ;;
  esac
done < "$WORK/names.raw"
sort -u -o "$WORK/zones" "$WORK/zones"
while IFS= read -r z; do
  echo "$z" >> "$WORK/names"; echo "www.$z" >> "$WORK/names"
  if [ "$COMMON" = 1 ]; then
    for c in mail ftp cpanel webmail direct origin dev staging test old admin; do echo "$c.$z" >> "$WORK/names"; done
  fi
done < "$WORK/zones"
sort -u -o "$WORK/names" "$WORK/names"

# --- resolution and classification -----------------------------------------------------------------------------
HAVE_DIG=0; command -v dig >/dev/null 2>&1 && HAVE_DIG=1
resolve() {  # NAME -> IPs one per line
  if [ "$HAVE_DIG" = 1 ]; then
    { dig +short +time=3 +tries=1 A "$1"; dig +short +time=3 +tries=1 AAAA "$1"; } 2>/dev/null \
      | grep -E '^[0-9.]+$|^[0-9a-fA-F:]+:[0-9a-fA-F:]*$' | sort -u
  else
    { getent ahostsv4 "$1"; getent ahostsv6 "$1"; } 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | sort -u
  fi
}
classify() {  # IP... on stdin -> one class per line
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip(), strict=False) for l in open(sys.argv[1]) if l.strip()]
origin = sys.argv[2]
for line in sys.stdin:
    t = line.strip()
    if not t: continue
    try: a = ipaddress.ip_address(t)
    except ValueError: print("?"); continue
    if t == origin: print("ORIGIN")
    elif any(a.version == n.version and a in n for n in nets): print("CF")
    else: print("OTHER")' "$WORK/ranges" "$ORIGIN"
  else
    awk -v origin="$ORIGIN" 'NR == FNR { if ($0 ~ /^[0-9.]+\/[0-9]+$/) { split($0, c, "/"); n++; split(c[1], p, "."); net[n] = ((p[1]*256+p[2])*256+p[3])*256+p[4]; len[n] = c[2] }; next }
      { if ($1 == origin) { print "ORIGIN"; next }
        if ($1 !~ /^[0-9.]+$/) { print "?"; next }
        split($1, p, "."); a = ((p[1]*256+p[2])*256+p[3])*256+p[4]; r = "OTHER"
        for (i = 1; i <= n; i++) { d = 2 ^ (32 - len[i]); if (int(a / d) == int(net[i] / d)) { r = "CF"; break } }
        print r }' "$WORK/ranges" -
  fi
}

EXPOSED=0; : > "$WORK/exposed"; declare -A WILD=()
echo "== wildcard records (a random label that resolves means '*' exists) =="
while IFS= read -r z; do
  r="msc-probe-$RANDOM$RANDOM.$z"; ips=$(resolve "$r")
  if [ -n "$ips" ]; then
    WILD[$z]=$(printf '%s' "$ips" | tr '\n' ' ')
    classes=$(printf '%s\n' "$ips" | classify | sort -u | tr '\n' ' ')
    printf '%-36s WILDCARD present -> %s(%s)\n' "*.$z" "${WILD[$z]}" "$classes"
    case "$classes" in *ORIGIN*) EXPOSED=$((EXPOSED + 1)); echo "*.$z (wildcard: every unlisted name)" >> "$WORK/exposed" ;; esac
  else
    printf '%-36s no wildcard\n' "*.$z"
  fi
done < "$WORK/zones"

echo ""
printf '%-44s %-24s %s\n' "NAME" "CLASS" "DNS ANSWERS"
while IFS= read -r n; do
  ips=$(resolve "$n"); via=""
  parent="${n#*.}"; flat=$(printf '%s' "$ips" | tr '\n' ' ')
  [ -n "$ips" ] && [ -n "${WILD[$parent]:-}" ] && [ "${WILD[$parent]}" = "$flat" ] && via=" (=wildcard)"
  if [ -z "$ips" ]; then cls="NO-RECORD"
  else
    classes=$(printf '%s\n' "$ips" | classify | sort -u | tr '\n' ' ')
    case "$classes" in
      *ORIGIN*) cls="EXPOSES-ORIGIN"
                if [ -z "$via" ]; then EXPOSED=$((EXPOSED + 1)); echo "$n" >> "$WORK/exposed"; fi ;;
      "CF ") cls="PROXIED" ;;
      *CF*) cls="MIXED" ;;
      *) cls="ELSEWHERE" ;;
    esac
  fi
  case "$n" in msc-probe-*) label="(wildcard vhost) *.${n#*.}" ;; *) label="$n" ;; esac
  printf '%-44s %-24s %s\n' "$label" "$cls$via" "$flat"
done < "$WORK/names"
echo "(=wildcard: the answer equals the zone's wildcard answer; the name may have no record of its own)"

if [ "$HAVE_DIG" = 1 ]; then
  echo ""
  echo "== mail exchangers (mail on this server reveals its IP in DNS) =="
  while IFS= read -r z; do
    dig +short +time=3 +tries=1 MX "$z" 2>/dev/null | awk '{print $2}' | sed 's/\.$//' | while read -r mx; do
      [ -z "$mx" ] && continue
      ips=$(resolve "$mx"); classes=$(printf '%s\n' "$ips" | classify | sort -u | tr '\n' ' ')
      printf '%-30s MX %-36s %s\n' "$z" "$mx" "$( [[ "$classes" == *ORIGIN* ]] && echo 'EXPOSES-ORIGIN' || echo "$classes")"
    done
  done < "$WORK/zones"
else
  echo ""; echo "(dig not installed: MX records not checked; 'apt install dnsutils' is an install, ask first)"
fi

grep -qsE "[[:space:]]${SITE:-no-site}([[:space:]]|$)" /etc/hosts && \
  echo "" && echo "NOTE: /etc/hosts has an entry for ${SITE}; local lookups of the site do not reflect public DNS."

echo ""
if [ "$EXPOSED" -gt 0 ]; then
  echo "RESULT: $EXPOSED name(s) or wildcard(s) point straight at the origin $ORIGIN:"
  sed 's/^/  - /' "$WORK/exposed" | sort -u
  echo "Anyone can reach the server without Cloudflare through these names (and the IP stays in DNS history)."
  echo "Options: proxy them (orange cloud) if they are web sites, move them, or lock the origin (references/origin-exposure.md)."
  exit 1
fi
echo "RESULT: no name in this list resolves to $ORIGIN. The IP may still be known from DNS history or mail headers."
