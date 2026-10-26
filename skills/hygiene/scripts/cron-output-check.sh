#!/bin/bash
# cron-output-check.sh — read-only: find cron jobs whose output is MAILED (no redirection while MAILTO is not empty)
# and local mailboxes that grow because of it. Prints job lines (passwords, tokens, ping keys and addresses
# redacted by msc_redact_cron), the MAILTO in effect, and mailbox size/mtime.
# Never reads message bodies.
#
# Usage: bash cron-output-check.sh [--sample SECONDS]   (--sample measures mailbox growth over that many seconds)
# Why: a cron line without '>> file 2>&1' mails its output on every run. With a local MTA (exim/postfix) that lands in
# /var/mail/<user>, which nobody reads; a Moodle task runner every minute grows it by gigabytes a year, and the
# bodies can hold task data (personal data at rest). With no MTA, cron logs "No MTA installed" instead (no growth).
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

SAMPLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac; shift
done

# Classify each job line read on stdin. $1 = label. 'user field' = 1 for /etc/crontab and cron.d files.
classify() {
  awk -v L="$1" -v UF="${2:-0}" '
    BEGIN { mailto = "(default: mail to the crontab owner)" }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*MAILTO[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); mailto = (v == "\"\"" || v == "" || v == "'"''"'") ? "\"\"" : v; next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next }
    {
      line = $0
      out = (line ~ /(^|[^0-9&])>{1,2}[[:space:]]*[^&]/ || line ~ /&>/ || line ~ /[[:space:]]1>/) ? 1 : 0
      err = (line ~ /2>&1/ || line ~ /2>[[:space:]]*[^&]/ || line ~ /&>/) ? 1 : 0
      if (line ~ /\|[[:space:]]*logger/) { out = 1; err = (line ~ /2>&1/) }
      mailed = (mailto != "\"\"" && (!out || !err))
      status = mailed ? "MAILS-OUTPUT" : (mailto == "\"\"" && (!out || !err) ? "discarded-by-MAILTO" : "ok")
      # package files in /etc/cron.d mail root only when a job prints something (errors): expected, lower priority
      if (mailed && UF == 1) status = "system:mails-if-output"
      printf "  [%s] %-20s MAILTO=%s\n      %s\n", L, status, mailto, line
    }'
}

msc_hr "crontabs"
for u in $(msc_cron_users); do
  c=$($SUDO crontab -l -u "$u" 2>/dev/null) || continue
  [ -n "$c" ] && printf '%s\n' "$c" | msc_redact_cron | classify "user $u"
done
for f in $(for c in $MSC_CRON_FILES; do if [ -d "$c" ]; then ls -d "$c"/* 2>/dev/null; else echo "$c"; fi; done); do
  [ -f "$f" ] || continue
  $SUDO cat "$f" 2>/dev/null | msc_redact_cron | classify "$f" 1
done
[ -n "${MSC_NO_ROOT:-}" ] && echo "  (not root and no passwordless sudo: other users' crontabs were not readable)"

msc_hr "local MTA"
for s in exim4 postfix sendmail opensmtpd nullmailer; do
  st=$(systemctl is-active "$s" 2>/dev/null); [ "$st" = active ] && echo "  $s active"
done
{ command -v sendmail || ls /usr/sbin/sendmail /usr/lib/sendmail; } >/dev/null 2>&1 || echo "  no sendmail binary: cron cannot mail (output is dropped, mailbox cannot grow)"

msc_hr "mailboxes over 1 MB"
for d in $MSC_MAIL_DIRS; do
  [ -d "$d" ] || continue
  $SUDO find "$d" -maxdepth 1 -type f -size +1M -printf '  %s B  mtime %TY-%Tm-%Td %TH:%TM  %u:%g %m  %p\n' 2>/dev/null
done
WB="${MSC_MAIL_DIRS%% *}/$WEBUSER"
if $SUDO test -f "$WB"; then
  echo "  web-user mailbox $WB: $($SUDO stat -c '%s B, changed %y' "$WB" 2>/dev/null)"
  if [ "$SAMPLE" -gt 0 ]; then
    a=$($SUDO stat -c %s "$WB"); sleep "$SAMPLE"; b=$($SUDO stat -c %s "$WB")
    echo "  growth over ${SAMPLE}s: $((b - a)) B"
  fi
  if msc_have fuser; then
    $SUDO fuser "$WB" >/dev/null 2>&1 && echo "  WARNING: a process has the mailbox open (wait before any purge)"
  fi
fi
echo
echo "Fix pattern (per job): add MAILTO=\"\" at the top as a safety net AND give every job its own '>> <log> 2>&1'"
echo "to a file that logrotate rotates, created 640 <WEBUSER>:<WEBUSER>. Check the new log path is covered:"
echo "  grep -rl '<log dir>' /etc/logrotate.d/"
