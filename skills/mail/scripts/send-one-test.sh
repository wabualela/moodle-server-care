#!/bin/bash
# send-one-test.sh — SENDS exactly ONE test message through the local MTA to the owner's own mailbox, then shows
# that message's log lines (authenticator ids and address local parts masked) and a verdict.
# Only with the owner's explicit permission for this message, to this mailbox. A second run the same day is
# refused unless --again (which needs a new permission).
#
# Usage: bash send-one-test.sh --from <Moodle noreplyaddress> --to <owner mailbox> --i-have-owner-permission [--again]
# The From must be on the domain the provider verified (Moodle's noreplyaddress); any other domain is rejected
# ("553 Sender is not allowed to relay") and leaves a frozen bounce behind.
# Never use 'exim -v' or '-d' for this: verbose traces can print the base64 AUTH exchange.
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init; msc_exim_init; msc_postfix_init

FROM=""; TO=""; PERM=0; AGAIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift ;; --to) TO="${2:-}"; shift ;;
    --i-have-owner-permission) PERM=1 ;; --again) AGAIN=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;; *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done
[ "$PERM" = 1 ] || { echo "REFUSED: sending needs the owner's permission for this message (--i-have-owner-permission)"; exit 3; }
for a in "$FROM" "$TO"; do [[ "$a" =~ ^[A-Za-z0-9._%+=-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "invalid address: '$a'"; exit 2; }; done
STAMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/moodle-server-care"; mkdir -p "$STAMPDIR"; chmod 700 "$STAMPDIR"
STAMP="$STAMPDIR/mail-test-sent-$(date +%F)"
if [ -e "$STAMP" ] && [ "$AGAIN" != 1 ]; then echo "REFUSED: a test message was already sent today ($(cat "$STAMP")). One message only; --again needs a new permission."; exit 3; fi

MTA=$(msc_detect_mta)
NOW=$(date '+%F %T')
msg() {
  printf 'From: Moodle mail test <%s>\nTo: <%s>\nSubject: mail relay test %s %s\nDate: %s\nMIME-Version: 1.0\n' \
    "$FROM" "$TO" "${SITE:-}" "$(date '+%F %T %z')" "$(date -R)"
  printf 'Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n'
  printf 'Test message from the moodle-server-care mail module (local MTA -> provider). No action needed.\n'
  printf 'Please check the Authentication-Results header: spf, dkim and dmarc should say pass.\n\n'
  printf 'رسالة اختبار من خادم المنصة. لا يلزم أي إجراء سوى التحقق من نتائج SPF وDKIM وDMARC.\n'
}

case "$MTA" in
exim)
  msg | $SUDO "$EXIM_BIN" -f "$FROM" "$TO"; rc=$?
  echo "submitted rc=$rc at $NOW"; [ $rc -eq 0 ] || exit 1
  echo "$NOW to=${TO#*@}" > "$STAMP"
  for i in $(seq 1 12); do sleep 5; q=$($SUDO "$EXIM_BIN" -bpc 2>/dev/null); [ "$q" = 0 ] && break; done
  ML="$EXIM_LOGDIR/mainlog"
  ID=$($SUDO awk -v s="$NOW" -v f="<= $FROM" '($1" "$2) >= s && index($0, f) {id=$3} END{print id}' "$ML")
  [ -n "$ID" ] || { echo "could not find the message in $ML (queue=$q)"; exit 1; }
  echo "== log lines for $ID"
  $SUDO grep -F " $ID " "$ML" | cut -d' ' -f2- | msc_redact
  if $SUDO grep -F " $ID " "$ML" | grep -qE ' => .*R=smarthost.*C="250'; then
    echo "VERDICT: accepted by the provider (250). Ask the owner to confirm it arrived (and check the headers)."
  elif $SUDO grep -F " $ID " "$ML" | grep -q ' == '; then
    echo "VERDICT: DEFERRED (stays queued and retries). Read the reason above; with hosts_require_auth a login problem shows here."
  elif $SUDO grep -F " $ID " "$ML" | grep -q ' \*\* '; then
    echo "VERDICT: FAILED permanently. Stop: do not switch Moodle; read the reason above."
  else echo "VERDICT: still in progress (queue=$q); rerun the grep in a minute: sudo grep -F ' $ID ' $ML"; fi
  $SUDO test -s "$EXIM_LOGDIR/paniclog" && echo "WARNING: paniclog is not empty" || echo "paniclog empty"
  ;;
postfix)
  SM=$(msc_which sendmail)
  msg | $SUDO "$SM" -f "$FROM" "$TO"; rc=$?
  echo "submitted rc=$rc at $NOW"; [ $rc -eq 0 ] || exit 1
  echo "$NOW to=${TO#*@}" > "$STAMP"
  sleep 15
  if $SUDO test -r "$MAILLOG"; then LINES=$($SUDO tail -n 2000 "$MAILLOG"); else LINES=$(journalctl --since "-10min" --no-pager 2>/dev/null | grep 'postfix/'); fi
  QID=$(echo "$LINES" | grep -F "from=<$FROM>" | sed -nE 's/.*postfix\/[a-z]+\[[0-9]+\]: ([0-9A-Za-z]+): .*/\1/p' | tail -n 1)
  [ -n "$QID" ] || { echo "could not find the message in the mail log"; exit 1; }
  echo "== log lines for $QID"; echo "$LINES" | grep -F "$QID" | msc_redact
  if echo "$LINES" | grep -F "$QID" | grep -q 'status=sent'; then echo "VERDICT: accepted by the provider. Ask the owner to confirm arrival."
  elif echo "$LINES" | grep -F "$QID" | grep -q 'status=deferred'; then echo "VERDICT: DEFERRED (retries). Read the reason."
  elif echo "$LINES" | grep -F "$QID" | grep -q 'status=bounced'; then echo "VERDICT: BOUNCED. Stop: do not switch Moodle."
  else echo "VERDICT: still in progress; check again in a minute"; fi
  ;;
*) echo "unsupported MTA: $MTA"; exit 2 ;;
esac
