#!/bin/bash
# owner-add-credentials.sh — for the OWNER to run in his own terminal (not through Claude). Stores the SMTP relay
# username and password/token for the local MTA without showing them on screen, in argv, shell history, temp files
# outside the protected directory, or logs. Prints only field counts and lengths afterwards.
#
# Usage: sudo bash owner-add-credentials.sh <smarthost-name> [port] [--mta exim|postfix] [--replace]
#   <smarthost-name>  exactly the host name the MTA relays to (exim: the dc_smarthost name; postfix: relayhost)
#   port              default 465 (used for the Postfix key "[host]:port")
#   --replace         replace an existing line for that host (token rotation)
#
# exim:    appends "host:user:password" to /etc/exim4/passwd.client (root:Debian-exim 640)
# postfix: writes "[host]:port user:password" to /etc/postfix/sasl_passwd (root 600) and runs postmap
set +x
set -euo pipefail
umask 077

HOST=""; PORT=465; MTA=""; REPLACE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mta) MTA="${2:-}"; shift ;;
    --replace) REPLACE=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "unknown option $1"; exit 2 ;;
    *) if [ -z "$HOST" ]; then HOST="$1"; else PORT="$1"; fi ;;
  esac
  shift
done
[[ "$HOST" =~ ^[A-Za-z0-9.*-]+$ ]] || { echo "usage: sudo bash $0 <smarthost-name> [port]"; exit 2; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "port must be a number"; exit 2; }
if [ "${MSC_NO_SUDO:-0}" != 1 ] && [ "$(id -u)" != 0 ]; then echo "run it with sudo / شغّله باستخدام sudo"; exit 2; fi
if [ ! -t 0 ] && [ "${MSC_TEST_STDIN:-0}" != 1 ]; then
  echo "run this in your own terminal (it needs a keyboard) / شغّله في الطرفية الخاصة بك"; exit 2
fi

EXIM_DIR="${EXIM_DIR:-/etc/exim4}"; POSTFIX_DIR="${POSTFIX_DIR:-/etc/postfix}"
if [ -z "$MTA" ]; then
  if [ -d "$EXIM_DIR" ] && { command -v exim4 >/dev/null 2>&1 || command -v exim >/dev/null 2>&1 || [ -x /usr/sbin/exim4 ]; }; then MTA=exim
  elif [ -f "$POSTFIX_DIR/main.cf" ]; then MTA=postfix
  else echo "no exim4 or postfix configuration found; use --mta"; exit 2; fi
fi

echo "Smarthost / الخادم: $HOST  (MTA: $MTA)"
IFS= read -rsp "SMTP username (hidden) / اسم المستخدم (مخفي): " U; echo
IFS= read -rsp "SMTP password or token (hidden) / كلمة المرور أو الرمز (مخفي): " P1; echo
IFS= read -rsp "Again / مرة أخرى: " P2; echo
cleanup() { unset U P1 P2; }
trap cleanup EXIT
[ "$P1" = "$P2" ] || { echo "The two entries differ; nothing written / الإدخالان مختلفان، لم يُكتب شيء"; exit 1; }
[ -n "$U" ] && [ -n "$P1" ] || { echo "empty value; nothing written / قيمة فارغة، لم يُكتب شيء"; exit 1; }

case "$MTA" in
exim)
  case "$U" in *:*) echo "the username must not contain ':' (exim format host:user:password)"; exit 1 ;; esac
  F="$EXIM_DIR/passwd.client"
  n=0; [ -f "$F" ] && n=$(awk -F: -v h="$HOST" '$1==h' "$F" | wc -l)
  if [ "$n" -gt 0 ] && [ "$REPLACE" != 1 ]; then echo "a line for $HOST already exists; rerun with --replace to rotate it"; exit 1; fi
  TMP=$(mktemp "$EXIM_DIR/.passwd.client.XXXXXX")
  { [ -f "$F" ] && awk -F: -v h="$HOST" '$1!=h' "$F"; printf '%s:%s:%s\n' "$HOST" "$U" "$P1"; } > "$TMP"
  if [ "${MSC_NO_SUDO:-0}" != 1 ]; then chown root:Debian-exim "$TMP"; fi
  chmod 640 "$TMP"; mv -f "$TMP" "$F"
  cleanup
  echo "Written. Check (no values shown) / تمت الكتابة. فحص بلا عرض للقيم:"
  awk -F: -v h="$HOST" '$1==h{printf "  line %d: fields=%d userlen=%d passlen=%d\n", NR, NF, length($2), length($0)-length($1)-length($2)-2}' "$F"
  stat -c '  file: %n %U:%G %a' "$F"
  ;;
postfix)
  case "$U$P1" in *[[:space:]]*) echo "spaces are not allowed in the Postfix sasl_passwd format; ask Claude for another way"; exit 1 ;; esac
  F="$POSTFIX_DIR/sasl_passwd"; KEY="[$HOST]:$PORT"
  n=0; [ -f "$F" ] && n=$(awk -v k="$KEY" '$1==k' "$F" | wc -l)
  if [ "$n" -gt 0 ] && [ "$REPLACE" != 1 ]; then echo "a line for $KEY already exists; rerun with --replace to rotate it"; exit 1; fi
  TMP=$(mktemp "$POSTFIX_DIR/.sasl_passwd.XXXXXX")
  { [ -f "$F" ] && awk -v k="$KEY" '$1!=k' "$F"; printf '%s %s:%s\n' "$KEY" "$U" "$P1"; } > "$TMP"
  chmod 600 "$TMP"; mv -f "$TMP" "$F"
  cleanup
  DBT=$(postconf -h default_database_type 2>/dev/null || echo hash)
  postmap "$DBT:$F"
  for x in "$F.db" "$F.lmdb" "$F.cdb"; do [ -e "$x" ] && chmod 600 "$x"; done
  echo "Written. Check (no values shown) / تمت الكتابة. فحص بلا عرض للقيم:"
  awk -v k="$KEY" '$1==k{u=$2; i=index(u,":"); printf "  line %d: key=%s userlen=%d passlen=%d\n", NR, $1, i-1, length(u)-i}' "$F"
  stat -c '  file: %n %U:%G %a' "$F"
  ;;
*) echo "unknown --mta $MTA"; exit 2 ;;
esac
echo "Done. Tell Claude 'credentials added'. Do not paste them anywhere."
echo "تم. أخبر Claude بعبارة: أُضيفت بيانات الدخول. لا تلصقها في أي مكان."
