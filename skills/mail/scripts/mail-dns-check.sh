#!/bin/bash
# mail-dns-check.sh — READ-ONLY public DNS check of a sending domain, asked of two resolvers so a stale or
# half-propagated record shows up: DKIM, the provider's bounce/Return-Path record, SPF at the apex, DMARC, MX, and
# whether a wildcard record could be hiding a missing name (the trap after a move to Cloudflare).
#
# Usage: bash mail-dns-check.sh --domain example.org [--dkim-selector SEL]... [--bounce NAME]
#                               [--expect-spf-include X]... [--resolvers "1.1.1.1 8.8.8.8"]
#   --domain           the From domain (domain part of Moodle's noreplyaddress)
#   --dkim-selector    the provider's DKIM selector (from its console); without it, common selectors are tried
#   --bounce           the provider's bounce / Return-Path name, label or FQDN (from its console)
#   --expect-spf-include  include: you expect at the apex (e.g. _spf.google.com for Google Workspace mailboxes)
# Uses dig when installed, else DNS-over-HTTPS with curl + python3. Exit 1 when any [FAIL].
set -uo pipefail
set +x

DOMAIN=""; SELECTORS=(); BOUNCE=""; INCLUDES=(); RESOLVERS="1.1.1.1 8.8.8.8"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift ;;
    --dkim-selector) SELECTORS+=("${2:-}"); shift ;;
    --bounce) BOUNCE="${2:-}"; shift ;;
    --expect-spf-include) INCLUDES+=("${2:-}"); shift ;;
    --resolvers) RESOLVERS="${2:-}"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "--domain is required"; exit 2; }
GUESS=0
if [ ${#SELECTORS[@]} -eq 0 ]; then SELECTORS=(google selector1 selector2 default k1 s1 s2 mail dkim zoho); GUESS=1; fi
if [ -n "$BOUNCE" ]; then case "$BOUNCE" in *."$DOMAIN"|"$DOMAIN") ;; *) BOUNCE="$BOUNCE.$DOMAIN" ;; esac; fi

[ -n "${DIG+x}" ] || DIG=$(command -v dig || true)   # DIG= (empty) forces DNS-over-HTTPS
FAILS=0; WARNS=0
ok()   { echo "  [ok]   $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
warn() { echo "  [WARN] $*"; WARNS=$((WARNS + 1)); }
info() { echo "  [info] $*"; }
mask() { sed -E 's/mailto:[^@,; ]+@/mailto:…@/g'; }

filter_type() {
  case "$1" in
    A) grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ;;
    TXT) grep '^"' | sed -E 's/" "//g; s/^"//; s/"$//' ;;
    MX) grep -E '^[0-9]+ ' ;;
    CNAME|NS) grep -vE '^;|^$' ;;
    *) cat ;;
  esac
}
doh() {
  local t=$1 n=$2 r=$3 url
  case "$r" in 8.8.8.8|8.8.4.4) url="https://dns.google/resolve?name=$n&type=$t" ;; *) url="https://cloudflare-dns.com/dns-query?name=$n&type=$t" ;; esac
  curl -s --max-time 8 -H 'accept: application/dns-json' "$url" | python3 -I -c '
import sys, json
t = {"A": 1, "NS": 2, "CNAME": 5, "MX": 15, "TXT": 16}[sys.argv[1]]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in d.get("Answer") or []:
    if a.get("type") == t:
        print(a.get("data", ""))' "$t"
}
q() {  # q TYPE NAME RESOLVER -> data lines of exactly that type
  if [ -n "$DIG" ]; then "$DIG" +short +time=3 +tries=1 "@$3" "$1" "$2" 2>/dev/null | filter_type "$1"
  else doh "$1" "$2" "$3" | filter_type "$1"; fi
}
[ -n "$DIG" ] || { command -v curl >/dev/null && command -v python3 >/dev/null || { echo "need dig, or curl + python3"; exit 2; }; info "dig not installed: using DNS-over-HTTPS"; }

echo "== mail DNS for $DOMAIN ($(date '+%F %T %Z'))"
FIRST=${RESOLVERS%% *}
NS=$(q NS "$DOMAIN" "$FIRST" | tr '\n' ' ')
MX=$(q MX "$DOMAIN" "$FIRST" | sort -n | tr '\n' ' ')
info "NS: ${NS:-?}"
info "MX: ${MX:-none}"
CF=0; case "$NS" in *cloudflare.com*) CF=1; info "DNS is hosted on Cloudflare: every mail-related CNAME (bounce, DKIM CNAMEs, autodiscover) must be 'DNS only' (grey cloud)";; esac

for R in $RESOLVERS; do
  echo "-- resolver $R"
  WC=$(q A "msc-nx-$RANDOM$RANDOM.$DOMAIN" "$R" | sort | tr '\n' ' ')
  [ -n "$WC" ] && warn "a wildcard record answers for any name ($WC): a MISSING record still resolves, so check record types, not 'does it resolve'"

  DKIMFOUND=0
  for s in "${SELECTORS[@]}"; do
    n="$s._domainkey.$DOMAIN"
    txt=$(q TXT "$n" "$R"); cn=$(q CNAME "$n" "$R")
    if printf '%s\n' "$txt" | grep -qiE '(^|;)[[:space:]]*p=[A-Za-z0-9+/]{20,}'; then
      DKIMFOUND=1; ok "DKIM $s: published (key length about $(printf '%s' "$txt" | sed -nE 's/.*p=([A-Za-z0-9+\/=]+).*/\1/p' | head -n1 | wc -c) chars)${cn:+ via CNAME $cn}"
    elif printf '%s\n' "$txt" | grep -qiE 'p=;|p=$'; then fail "DKIM $s: key revoked (empty p=)"
    elif [ "$GUESS" = 0 ]; then fail "DKIM $s: no DKIM key at $n${cn:+ (CNAME $cn does not lead to a key)}"
    fi
  done
  [ "$GUESS" = 1 ] && [ "$DKIMFOUND" = 0 ] && warn "DKIM: no key under common selectors; pass --dkim-selector from the provider's console"

  if [ -n "$BOUNCE" ]; then
    cn=$(q CNAME "$BOUNCE" "$R"); a=$(q A "$BOUNCE" "$R" | sort | tr '\n' ' '); bmx=$(q MX "$BOUNCE" "$R"); btxt=$(q TXT "$BOUNCE" "$R")
    bspf=$(printf '%s\n' "$btxt" | grep -i '^v=spf1' | head -n 1)
    if [ -n "$cn" ]; then
      ok "bounce $BOUNCE: CNAME -> $cn (DNS only)"
      [ -n "$bspf" ] && ok "  SPF reached through it: $bspf" || warn "  no SPF at the CNAME target (provider side?)"
    elif [ -n "$bmx" ] && [ -n "$bspf" ]; then
      ok "bounce $BOUNCE: own MX + SPF (custom MAIL FROM style): $bspf"
    elif [ -n "$a" ] && [ "$a" = "$WC" ]; then
      fail "bounce $BOUNCE: MISSING: only the wildcard answers ($a). Create the provider's CNAME, DNS only"
    elif [ -n "$a" ]; then
      fail "bounce $BOUNCE: answers with A records ($a), no CNAME: proxied (orange cloud) or wrong type. Set it to a DNS-only CNAME"
    else
      fail "bounce $BOUNCE: no record at all"
    fi
  fi

  spf=$(q TXT "$DOMAIN" "$R" | grep -i '^v=spf1')
  ns=$(printf '%s' "$spf" | grep -c '^v=spf1')
  if [ "$ns" -eq 0 ]; then fail "SPF: no v=spf1 record at $DOMAIN"
  elif [ "$ns" -gt 1 ]; then fail "SPF: $ns v=spf1 records at $DOMAIN (permerror: merge them into one)"; printf '%s\n' "$spf" | sed 's/^/         /'
  else
    ok "SPF: $spf"
    case "$spf" in *"+all"*) fail "SPF ends with +all (anyone may send)";; *"?all"*) warn "SPF ends with ?all (neutral)";; esac
    for inc in "${INCLUDES[@]}"; do case "$spf" in *"include:$inc"*) ok "  include:$inc present";; *) fail "  include:$inc missing";; esac; done
  fi

  dm=$(q TXT "_dmarc.$DOMAIN" "$R" | grep -i '^v=DMARC1')
  nd=$(printf '%s' "$dm" | grep -c '^v=DMARC1')
  if [ "$nd" -eq 0 ]; then fail "DMARC: no record at _dmarc.$DOMAIN"
  elif [ "$nd" -gt 1 ]; then fail "DMARC: $nd records (receivers ignore all of them)"
  else
    ok "DMARC: $(printf '%s' "$dm" | mask)"
    p=$(printf '%s' "$dm" | sed -nE 's/.*[; ]p=([a-z]+).*/\1/Ip' | head -n 1)
    printf '%s' "$dm" | grep -qi 'rua=' || warn "DMARC has no rua= (no reports, so you cannot know when it is safe to tighten)"
    [ "${p,,}" = none ] && info "DMARC p=none (monitoring). Tighten to quarantine after 2-4 weeks of clean reports"
  fi
done

echo "-- hints"
case "$MX" in
  *google.com*|*googlemail.com*) info "mailboxes on Google Workspace: apex SPF normally contains include:_spf.google.com" ;;
  *outlook.com*|*protection.outlook*) info "mailboxes on Microsoft 365: apex SPF normally contains include:spf.protection.outlook.com" ;;
esac
[ "$CF" = 1 ] && info "fix records in Cloudflare: DNS > Records (Proxy status: DNS only); DMARC: Email > DMARC Management"
echo "== $FAILS fail(s), $WARNS warning(s)"
[ "$FAILS" -eq 0 ]
