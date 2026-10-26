#!/bin/bash
# hygiene-scan.sh — read-only overview of every hygiene item, so the owner gets one proposal instead of ten.
# Runs the other check scripts of this module in their default (read-only) mode and prints a short summary first.
#
# Usage: bash hygiene-scan.sh [--full] [--with-moodle]
#   --full         also print the full output of each check (default: summary + pointers)
#   --with-moodle  also run password-loop.php as the web user (copies it to /tmp with mode 644 first)
# Output may contain paths, hostnames and user IDs of THIS server: keep it on the server, do not paste it into a
# public place. It never contains secrets.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo
FULL=0; WITHM=0
for a in "$@"; do case "$a" in --full) FULL=1 ;; --with-moodle) WITHM=1 ;; -h|--help) sed -n '2,10p' "$0"; exit 0 ;; esac; done
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

echo "== moodle-server-care hygiene scan (read-only) $(date '+%F %T %Z') =="
echo "env: ${MSC_ENV_LOADED:-not found (run skills/start/scripts/detect-env.sh)}  site=${SITE:-?} moodle=${MOODLE:-?} webuser=$WEBUSER"
[ -n "${MSC_NO_ROOT:-}" ] && echo "WARNING: not root and no passwordless sudo: many checks will be incomplete."

run() { local n="$1"; shift; "$@" > "$OUT/$n.txt" 2>&1; }
as_user() { local u="$1"; shift; if [ "$(id -u)" -eq 0 ]; then runuser -u "$u" -- "$@"; else sudo -n -u "$u" "$@"; fi; }
run certs     bash "$HERE/cert-references.sh"
run logrotate bash "$HERE/logrotate-check.sh"
run cron      bash "$HERE/cron-output-check.sh"
run secrets   bash "$HERE/secrets-perms.sh"
run laravel   bash "$HERE/laravel-env-check.sh"
run f2b       bash "$HERE/fail2ban-check.sh"
run db        bash "$HERE/db-listen-check.sh"
run docker    bash "$HERE/inventory-paths.sh" --docker
run discover  bash "$HERE/inventory-paths.sh" --discover

line() { printf '%-4s %-38s %-9s %s\n' "$1" "$2" "$3" "$4"; }
echo
line "ID" "item" "status" "evidence / next"
line "--" "----" "------" "---------------"
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
line "H0" "failed systemd units" "$( [ -n "$failed" ] && echo FINDING || echo ok)" "${failed:-none}"
dead=$(grep -cE 'DEAD-(BUT-ENABLED|UNREFERENCED)' "$OUT/certs.txt"); deadref=$(grep -c 'DEAD-BUT-ENABLED' "$OUT/certs.txt")
line "H1" "certbot: dead certificates" "$( [ "$dead" -gt 0 ] && echo FINDING || echo ok)" "$dead dead ($deadref still referenced by an enabled vhost) -> references/timers-certbot-logrotate.md"
lr=$(grep -A3 'logrotate -d errors' "$OUT/logrotate.txt" | grep -m1 -o 'exit code: [0-9]*'); dup=$(sed -n '/more than one stanza/,/^== /p' "$OUT/logrotate.txt" | grep -c '<=')
lrs=ok; [ -z "$lr" ] && lrs="n/a"; { [ -n "$lr" ] && [ "${lr##* }" != 0 ]; } || [ "$dup" -gt 0 ] && lrs=FINDING
line "H2" "logrotate errors / duplicate stanzas" "$lrs" "${lr:-?}, $dup file(s) in two stanzas -> references/timers-certbot-logrotate.md"
mailed=$(grep -c 'MAILS-OUTPUT' "$OUT/cron.txt"); mbox=$(grep -c ' B  mtime ' "$OUT/cron.txt")
line "H3" "cron output mailed / mailboxes" "$( [ "$mailed" -gt 0 ] || [ "$mbox" -gt 0 ] && echo FINDING || echo ok)" "$mailed job line(s) mail output, $mbox mailbox(es) > 1 MB -> references/cron-mailbox.md"
exp=$(grep -cE '^(EXPOSED|CHECK) ' "$OUT/secrets.txt"); brk=$(grep -c '^BROKEN ' "$OUT/secrets.txt")
line "H4" "world-readable secrets and logs" "$( [ "$exp" -gt 0 ] || [ "$brk" -gt 0 ] && echo FINDING || echo ok)" "$exp exposed, $brk unreadable by their reader -> references/secrets-and-log-modes.md"
dbg=$(grep -cE 'APP_DEBUG=true|APP_ENV=(local|development|dev) |in cache = (local|development|dev) | true +<-' "$OUT/laravel.txt"); napps=$(grep -c '^== /' "$OUT/laravel.txt")
line "H5" "Laravel apps in debug/local mode" "$( [ "$dbg" -gt 0 ] && echo FINDING || echo ok)" "$napps app(s), $dbg debug/local indicator(s) -> references/laravel-debug.md"
if [ "$WITHM" -eq 1 ] && [ -n "${MOODLE:-}" ]; then
  # the web user usually cannot read the operator's home: run a world-readable copy from /tmp (core rules, testing)
  T="${MSC_TMPDIR:-/tmp}/msc-password-loop.$$.php"
  install -m 644 "$HERE/password-loop.php" "$T"
  as_user "$WEBUSER" "${PHP:-php}" "$T" --moodle="$MOODLE" > "$OUT/loop.txt" 2>&1
  rm -f "$T"
  pl=$(grep -oE 'picked up by the task \(looping if mail fails\): [0-9]+' "$OUT/loop.txt" | grep -oE '[0-9]+$')
  if [ -z "$pl" ]; then
    line "H6" "accounts in the password loop" "ERROR" "Moodle CLI failed: $(tail -n 1 "$OUT/loop.txt" | cut -c1-120)"
  else
    line "H6" "accounts in the password loop" "$( [ "$pl" -gt 0 ] && echo FINDING || echo ok)" "$pl looping user(s); $(grep -m1 'events:' "$OUT/loop.txt" | sed 's/user_password_updated //') -> references/password-loop.md"
  fi
else
  line "H6" "accounts in the password loop" "not run" "rerun with --with-moodle (read-only Moodle CLI) -> references/password-loop.md"
fi
f2=$(grep -m1 'service:' "$OUT/f2b.txt" | sed 's/^ *//')
line "H7" "fail2ban" "$(echo "$f2" | grep -q 'service: active' && echo ok || echo FINDING)" "${f2:-not installed} -> references/fail2ban-journald.md"
nl=$(grep -c 'NOT-LOOPBACK' "$OUT/db.txt")
line "H8" "DB/cache listening beyond loopback" "$( [ "$nl" -gt 0 ] && echo FINDING || echo ok)" "$nl non-loopback listener(s) -> references/db-localhost.md"
cand=$(grep -cE 'refs=0 ' "$OUT/discover.txt"); imgs=$(sed -n '/images:/,/volumes/p' "$OUT/docker.txt" | grep -c 'created')
line "H9" "abandoned projects / leftovers" "$( [ "$cand" -gt 0 ] || [ "$imgs" -gt 0 ] && echo CHECK || echo ok)" "$cand unreferenced project dir(s), $imgs docker image(s) -> references/abandoned-projects.md"
line "H10" "orphaned app moved elsewhere" "ask" "owner names the app; then orphan-app-check.sh -> references/orphaned-app.md"
echo
if [ "$FULL" -eq 1 ]; then
  for n in certs logrotate cron secrets laravel loop f2b db docker discover; do
    [ -f "$OUT/$n.txt" ] || continue
    printf '\n################ %s ################\n' "$n"; cat "$OUT/$n.txt"
  done
else
  echo "Run with --full for the details, or run a single check script (see SKILL.md, 'Files in this module')."
fi
