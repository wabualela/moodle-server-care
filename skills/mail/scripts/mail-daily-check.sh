#!/bin/bash
# mail-daily-check.sh — READ-ONLY daily health check of the local relay (run it once a day for 14 days after the
# Moodle switch, then weekly). Counts only; reasons are shown with address local parts masked.
#
# Usage: bash mail-daily-check.sh [--known-frozen ID,ID] [--date YYYY-MM-DD]
#   --known-frozen  frozen message ids already explained in the operations log (e.g. bounces of a test)
#   --date          day to report (default today; exim reads mainlog + mainlog.1 + mainlog.N.gz)
# Verdict: OK | CHECK (each item must be explained) | TRIGGER (rollback trigger unless explained, see SKILL.md)
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init; msc_exim_init; msc_postfix_init

KNOWN=""; DAY=$(date +%F)
while [ $# -gt 0 ]; do
  case "$1" in --known-frozen) KNOWN="${2:-}"; shift ;; --date) DAY="${2:-}"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;; *) echo "unknown option $1"; exit 2 ;; esac; shift
done
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "invalid --date"; exit 2; }
CHECKS=(); TRIGGERS=()
HIST="${XDG_CACHE_HOME:-$HOME/.cache}/moodle-server-care/mail-queue-history"; mkdir -p "$(dirname "$HIST")"
say() { printf '%-34s %s\n' "$1" "$2"; }

MTA=$(msc_detect_mta)
echo "== mail daily check $DAY ($MTA) at $(date '+%F %T')"
case "$MTA" in
exim)
  Q=$($SUDO "$EXIM_BIN" -bpc 2>/dev/null || echo "?")
  FROZEN=$($SUDO "$EXIM_BIN" -bp 2>/dev/null | awk '/\*\*\* frozen \*\*\*/{print $3}')
  UNEXPLAINED=""
  for id in $FROZEN; do case ",$KNOWN," in *",$id,"*) ;; *) UNEXPLAINED+="$id " ;; esac; done
  LOGS=$($SUDO sh -c "ls -1 '$EXIM_LOGDIR'/mainlog '$EXIM_LOGDIR'/mainlog.1 '$EXIM_LOGDIR'/mainlog.*.gz 2>/dev/null")
  L=$(for f in $LOGS; do $SUDO zcat -f "$f"; done | grep "^$DAY ")
  cnt() { printf '%s\n' "$L" | grep -cE "$1"; }
  say "queue / frozen" "$Q / $(echo $FROZEN | wc -w) (unexplained: ${UNEXPLAINED:-none})"
  say "arrivals from local SMTP (Moodle)" "$(cnt ' <= .* \[(127\.0\.0\.1|::1)\].* P=e?smtp')"
  say "arrivals local (cron, scripts)" "$(cnt ' <= .* P=local')"
  say "delivered via smarthost (=>)" "$(cnt ' => .* R=smarthost')"
  say "delivered locally" "$(cnt ' => .* R=(local_user|system_aliases|userforward|mail4root)')"
  DEF=$(cnt ' == '); FAIL=$(cnt ' \*\* ')
  say "deferred (==) / failed (**)" "$DEF / $FAIL"
  if [ "$DEF" -gt 0 ] || [ "$FAIL" -gt 0 ]; then
    echo "  last reasons (masked):"
    printf '%s\n' "$L" | grep -E ' (==|\*\*) ' | tail -n 5 | cut -d' ' -f2,4- | cut -c1-220 | msc_redact | sed 's/^/    /'
  fi
  [ "$FAIL" -gt 0 ] && CHECKS+=("$FAIL permanent failure(s) (**): each must be explained (bad address, test), else rollback trigger")
  [ -n "$UNEXPLAINED" ] && CHECKS+=("frozen message(s) $UNEXPLAINED: explain (exim -Mvh <id> shows headers) or treat as trigger")
  AUTHF=$(printf '%s\n' "$L" | grep -E ' == ' | grep -ciE 'authentication|535|auth')
  [ "$AUTHF" -gt 0 ] && TRIGGERS+=("$AUTHF deferral(s) mention authentication: token expired/rotated? (mail is queued, not lost)")
  PS=$($SUDO stat -c %s "$EXIM_LOGDIR/paniclog" 2>/dev/null || echo 0)
  say "paniclog bytes" "$PS"
  if [ "$PS" -gt 0 ]; then TRIGGERS+=("paniclog is not empty"); $SUDO tail -n 3 "$EXIM_LOGDIR/paniclog" | msc_redact | sed 's/^/    /'; fi
  RA=$(grep -cE '^[[:space:]]*hosts_require_auth' "$EXIM_TPL" 2>/dev/null)
  say "hosts_require_auth in transport" "${RA:-0}"
  [ "${RA:-0}" -ge 1 ] || TRIGGERS+=("hosts_require_auth is gone from $EXIM_TPL (package upgrade replaced the template?): re-add it")
  [ -e "$EXIM_MACROS" ] || TRIGGERS+=("$EXIM_MACROS is missing")
  say "self-signed cert warnings (info)" "$(cnt 'No server certificate defined')"
  ;;
postfix)
  QL=$($SUDO postqueue -p 2>/dev/null | tail -n 1)
  Q=$(echo "$QL" | sed -nE 's/.* in ([0-9]+) Requests?\./\1/p'); [ -n "$Q" ] || Q=0
  say "queue" "$Q ($QL)"
  if $SUDO test -r "$MAILLOG"; then L=$($SUDO zcat -f "$MAILLOG" | grep -E "^$DAY|^$(LC_ALL=C date -d "$DAY" '+%b %e')")
  else L=$(journalctl --since "$DAY 00:00:00" --until "$DAY 23:59:59" --no-pager 2>/dev/null | grep 'postfix/'); fi
  cnt() { printf '%s\n' "$L" | grep -cE "$1"; }
  say "sent via relay" "$(cnt 'postfix/smtp\[.*status=sent')"
  DEF=$(cnt 'status=deferred'); FAIL=$(cnt 'status=bounced')
  say "deferred / bounced" "$DEF / $FAIL"
  if [ "$DEF" -gt 0 ] || [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$L" | grep -E 'status=(deferred|bounced)' | tail -n 5 | cut -c1-220 | msc_redact | sed 's/^/    /'
  fi
  [ "$FAIL" -gt 0 ] && CHECKS+=("$FAIL bounce(s): each must be explained, else rollback trigger")
  AUTHF=$(cnt 'SASL authentication failed')
  [ "$AUTHF" -gt 0 ] && TRIGGERS+=("$AUTHF SASL authentication failure(s)")
  ;;
*) echo "unsupported MTA: $MTA"; exit 2 ;;
esac

PREV=$(tail -n 1 "$HIST" 2>/dev/null | awk '{print $3}')
[[ "$Q" =~ ^[0-9]+$ ]] && echo "$(date '+%F %T') $Q" >> "$HIST"
if [[ "$Q" =~ ^[0-9]+$ ]] && [ "$Q" -gt 50 ]; then
  if [[ "${PREV:-}" =~ ^[0-9]+$ ]] && [ "$Q" -gt "$PREV" ]; then TRIGGERS+=("queue $Q > 50 and growing (was $PREV)"); else CHECKS+=("queue $Q > 50"); fi
fi

if [ ${#TRIGGERS[@]} -gt 0 ]; then echo "VERDICT: TRIGGER"; printf '  - %s\n' "${TRIGGERS[@]}" "${CHECKS[@]}"
elif [ ${#CHECKS[@]} -gt 0 ]; then echo "VERDICT: CHECK"; printf '  - %s\n' "${CHECKS[@]}"
else echo "VERDICT: OK"; fi
