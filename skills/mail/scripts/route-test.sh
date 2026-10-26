#!/bin/bash
# route-test.sh — routing and acceptance tests that deliver NOTHING.
#   exim:    exim -bt for a local user (cron mail must stay local), an external address (must go to the
#            smarthost) and an address on the site's own mail domain (must also go to the smarthost);
#            then 'exim -bh 127.0.0.1': a simulated SMTP session from localhost (EHLO, MAIL, RCPT, QUIT) that runs
#            the real ACLs without touching the daemon, the queue or the network.
#   postfix: shows relayhost and the lookup key, then (like --live-probe) a real SMTP dialogue with the local
#            daemon that stops before DATA, so no message is created.
#
# Usage: bash route-test.sh --from <noreplyaddress> [--to <rcpt>] [--remote <addr>] [--live-probe]
#   --to          RCPT address for the session (default postmaster@example.com; -bh never delivers)
#   --remote      external address for exim -bt (default probe@example.com)
#   --live-probe  also talk to the running daemon on 127.0.0.1:25 (EHLO/MAIL/RCPT/RSET/QUIT, no DATA)
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init; msc_exim_init; msc_postfix_init

FROM=""; TO="postmaster@example.com"; REMOTE="probe@example.com"; LIVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift ;; --to) TO="${2:-}"; shift ;; --remote) REMOTE="${2:-}"; shift ;;
    --live-probe) LIVE=1 ;; -h|--help) sed -n '2,17p' "$0"; exit 0 ;; *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done
[[ "$FROM" == *@*.* ]] || { echo "--from <Moodle noreplyaddress> is required"; exit 2; }
for a in "$TO" "$REMOTE"; do [[ "$a" =~ ^[^-][^[:space:]]*@[^[:space:]]+$ ]] || { echo "invalid address: $a"; exit 2; }; done
MAILDOM=${FROM#*@}
HELO=${SITE:-$(hostname -f 2>/dev/null || hostname)}
FAILS=0
res() { if [ "$1" = ok ]; then echo "  [ok]   $2"; else echo "  [$1] $2"; FAILS=$((FAILS + 1)); fi; }

smtp_probe() {  # real dialogue with the daemon, no DATA: nothing is queued
  local h="${MSC_SMTP_HOST:-127.0.0.1}" p="${MSC_SMTP_PORT:-25}" c l codes=""
  exec 3<>"/dev/tcp/$h/$p" || { res FAIL "cannot connect to $h:$p"; return; }
  rd() { while IFS= read -r -t 10 l <&3; do l=${l%$'\r'}; echo "    $l" | msc_redact; [[ "$l" =~ ^[0-9]{3}\  ]] && { codes+="${l:0:3} "; break; }; done; }
  rd
  for c in "EHLO $HELO" "MAIL FROM:<$FROM>" "RCPT TO:<$TO>" "RSET" "QUIT"; do
    printf '%s\r\n' "$c" >&3; echo "  >> ${c%%:*}"; rd
  done
  exec 3>&- 3<&-
  set -- $codes   # greeting EHLO MAIL RCPT RSET QUIT
  [ "${3:-}" = 250 ] && res ok "MAIL FROM accepted" || res FAIL "MAIL FROM answered ${3:-none}"
  [ "${4:-}" = 250 ] && res ok "RCPT TO accepted (localhost may relay)" || res FAIL "RCPT TO answered ${4:-none}"
}

MTA=$(msc_detect_mta)
echo "== MTA: $MTA"
case "$MTA" in
exim)
  rt() { $SUDO "$EXIM_BIN" -bt "$1" 2>&1 | grep -E 'router|transport|host |Unrouteable|undeliverable|is undeliverable' | msc_redact; }
  echo "-- exim -bt $WEBUSER (local cron mail)"
  o=$(rt "$WEBUSER"); echo "$o"
  echo "$o" | grep -q 'router = smarthost' && res FAIL "local user goes to the smarthost (satellite-like config): cron mail would leave the server" \
    || { echo "$o" | grep -qE 'transport = (mail_spool|maildir_home|address_file|address_pipe)' && res ok "local mail stays local" || res WARN "local user routing unclear"; }
  echo "-- exim -bt $REMOTE (external)"
  o=$(rt "$REMOTE"); echo "$o"
  if echo "$o" | grep -q 'router = smarthost' && echo "$o" | grep -q 'transport = remote_smtp_smarthost'; then res ok "external mail -> smarthost"
  elif echo "$o" | grep -q 'Unrouteable'; then res FAIL "external mail is unrouteable (exim is not a smarthost yet?)"
  else res FAIL "external mail does not use the smarthost"; fi
  echo "-- exim -bt postmaster@$MAILDOM (the site's own mail domain)"
  o=$(rt "postmaster@$MAILDOM"); echo "$o"
  if echo "$o" | grep -q 'router = smarthost'; then res ok "$MAILDOM is not treated as local"
  elif echo "$o" | grep -q 'Unrouteable'; then res FAIL "$MAILDOM is unrouteable (exim is not a smarthost yet?)"
  else res FAIL "$MAILDOM is handled locally (in /etc/mailname or dc_other_hostnames?): mail to staff at that domain would never leave the server"; fi
  echo "-- exim -bh 127.0.0.1 (simulated session; nothing is delivered)"
  out=$(printf 'EHLO %s\r\nMAIL FROM:<%s>\r\nRCPT TO:<%s>\r\nQUIT\r\n' "$HELO" "$FROM" "$TO" | $SUDO "$EXIM_BIN" -bh 127.0.0.1 2>/dev/null)
  echo "$out" | grep -E '^[0-9]{3}[ -]' | grep -vE '^250-' | sed 's/^/    /' | msc_redact
  codes=$(echo "$out" | grep -oE '^[0-9]{3} ' | tr -d ' ' | tr '\n' ' ')
  set -- $codes
  [ "${3:-}" = 250 ] && res ok "MAIL FROM accepted" || res FAIL "MAIL FROM answered ${3:-none}"
  [ "${4:-}" = 250 ] && res ok "RCPT TO accepted from localhost" || res FAIL "RCPT TO answered ${4:-none}"
  [ "$LIVE" = 1 ] && { echo "-- live probe 127.0.0.1:25 (no DATA)"; smtp_probe; }
  ;;
postfix)
  echo "  relayhost=$("$POSTCONF_BIN" -h relayhost)  mydestination=$("$POSTCONF_BIN" -h mydestination)"
  case " $("$POSTCONF_BIN" -h mydestination | tr ',' ' ') " in *" $MAILDOM "*) res FAIL "$MAILDOM is in mydestination: mail to that domain is delivered locally" ;; *) res ok "$MAILDOM not in mydestination" ;; esac
  echo "-- live probe 127.0.0.1:25 (no DATA)"; smtp_probe
  ;;
*) echo "unsupported MTA: $MTA"; exit 2 ;;
esac
echo "== $FAILS problem(s)"
[ "$FAILS" -eq 0 ]
