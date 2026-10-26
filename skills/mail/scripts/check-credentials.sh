#!/bin/bash
# check-credentials.sh — READ-ONLY: proves the relay credentials are present and will be found, without revealing
# them: file owner/mode, per-line field count and lengths, and whether a key matches the host the MTA really
# connects to (exim looks the line up by the smarthost's resolved name, then by its IP address).
#
# Usage: bash check-credentials.sh [--mta exim|postfix]
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init; msc_exim_init; msc_postfix_init

MTA=""
[ "${1:-}" = "--mta" ] && MTA="${2:-}"
[ -n "$MTA" ] || MTA=$(msc_detect_mta)
RC=0

case "$MTA" in
exim)
  F="$EXIM_DIR/passwd.client"
  $SUDO test -e "$F" || { echo "MISSING: $F"; exit 1; }
  $SUDO stat -c 'file: %n %U:%G %a' "$F"
  [ "$($SUDO stat -c '%U:%G %a' "$F")" = "root:Debian-exim 640" ] || { echo "WARN: expected root:Debian-exim 640"; RC=1; }
  KEYS=$($SUDO awk -F: '!/^[[:space:]]*(#|$)/{
      pl = (NF >= 3) ? length($0) - length($1) - length($2) - 2 : 0
      printf "line %d: key=%s fields=%d userlen=%d passlen=%d\n", NR, $1, NF, length($2), pl }' "$F")
  if [ -z "$KEYS" ]; then echo "NO ENTRIES (only comments): the owner has not added credentials yet"; exit 1; fi
  echo "$KEYS"
  echo "$KEYS" | grep -qE 'fields=[3-9].*userlen=[1-9].*passlen=[1-9]' || { echo "WARN: no complete host:user:password line"; RC=1; }
  # The host exim will look up: from a routing test of an external address (nothing is sent).
  HL=$($SUDO "$EXIM_BIN" -bt probe@example.com 2>/dev/null | sed -nE 's/^[[:space:]]+host ([^ ]+) \[([^]]+)\].*/\1 \2/p' | head -n 1)
  NAME=${HL%% *}; IP=${HL#* }
  if [ -z "$HL" ]; then
    NAME=$(sed -nE "s/^dc_smarthost='([^':]*).*/\1/p" "$EXIM_CONF" 2>/dev/null); IP=""
    echo "routing test gave no host line; using dc_smarthost name '$NAME'"
  fi
  MATCH=no
  for k in $(echo "$KEYS" | sed -nE 's/.* key=([^ ]+) .*/\1/p'); do
    if [ "$k" = "$NAME" ] || { [ -n "$IP" ] && [ "$k" = "$IP" ]; }; then MATCH="yes ($k)"; break; fi
    case "$k" in \*.*) case "$NAME" in *"${k#\*}") MATCH="yes (wildcard $k)"; break ;; esac ;; esac
  done
  echo "smarthost exim connects to: ${NAME:-?} [${IP:-?}] -> credentials key matches: $MATCH"
  [ "${MATCH%% *}" = yes ] || { echo "WARN: add a line for '$NAME' (the name exim resolved) or its IP; see references/exim-smarthost.md §5"; RC=1; }
  ;;
postfix)
  F="$POSTFIX_DIR/sasl_passwd"
  $SUDO test -e "$F" || { echo "MISSING: $F"; exit 1; }
  $SUDO stat -c 'file: %n %U:%G %a' "$F"
  [ "$($SUDO stat -c '%a' "$F")" = "600" ] || { echo "WARN: expected mode 600"; RC=1; }
  $SUDO awk '!/^[[:space:]]*(#|$)/{u=$2; i=index(u,":"); printf "line %d: key=%s userlen=%d passlen=%d\n", NR, $1, (i ? i-1 : length(u)), (i ? length(u)-i : 0)}' "$F"
  RELAY=$("$POSTCONF_BIN" -h relayhost 2>/dev/null); MAP=$("$POSTCONF_BIN" -h smtp_sasl_password_maps 2>/dev/null)
  DBT=$("$POSTCONF_BIN" -h default_database_type 2>/dev/null || echo hash)
  echo "relayhost=$RELAY  smtp_sasl_password_maps=$MAP"
  case "$MAP" in *"$F"*) ;; *) echo "WARN: smtp_sasl_password_maps does not point to $F"; RC=1 ;; esac
  for x in "$F.db" "$F.lmdb" "$F.cdb"; do
    $SUDO test -e "$x" || continue
    if $SUDO test ! "$F" -nt "$x"; then echo "map file $x is current"; else echo "WARN: $x is older than $F: run postmap"; RC=1; fi
  done
  n=$($SUDO "$(msc_which postmap)" -q "$RELAY" "$DBT:$F" 2>/dev/null | wc -c)
  [ "$n" -gt 1 ] && echo "lookup of '$RELAY' returns a value: yes ($((n - 1)) chars, not shown)" || { echo "WARN: lookup of '$RELAY' returns nothing: Postfix would send WITHOUT auth"; RC=1; }
  ;;
*) echo "unsupported MTA: $MTA"; exit 2 ;;
esac
exit $RC
