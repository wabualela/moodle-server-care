#!/bin/bash
# logrotate-check.sh — read-only: why does logrotate fail, which log files are claimed by two stanzas (logrotate
# refuses duplicates and the whole run exits non-zero), and which large logs have no stanza at all.
# Runs `logrotate -d` (debug mode: no rotation, state file untouched). Changes nothing.
#
# Usage: bash logrotate-check.sh [--conf /etc/logrotate.conf] [--min-mb 20] [--logdir /var/log]
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

CONF="${MSC_LOGROTATE_CONF:-/etc/logrotate.conf}"; MINMB=20; LOGDIR="${MSC_LOGDIR:-/var/log}"
while [ $# -gt 0 ]; do
  case "$1" in
    --conf) CONF="$2"; shift ;;
    --min-mb) MINMB="$2"; shift ;;
    --logdir) LOGDIR="$2"; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac; shift
done

msc_hr "logrotate unit / schedule"
if systemctl list-unit-files logrotate.timer >/dev/null 2>&1 && systemctl cat logrotate.timer >/dev/null 2>&1; then
  systemctl show -p Result -p ExecMainStatus -p ExecMainExitTimestamp logrotate.service 2>/dev/null | sed 's/^/  /'
  systemctl list-timers logrotate.timer --no-pager 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
elif [ -e /etc/cron.daily/logrotate ]; then
  echo "  runs from /etc/cron.daily/logrotate (no systemd timer); failures are mailed to root or logged by cron"
else
  echo "  no logrotate timer or cron.daily script found"
fi

msc_hr "logrotate -d errors (debug run, nothing rotated)"
if msc_have logrotate || [ -x /usr/sbin/logrotate ]; then
  LR=$(command -v logrotate || echo /usr/sbin/logrotate)
  # --skip-state-lock (logrotate >= 3.19) so a debug run never blocks or races the real nightly run
  SKIP=""; "$LR" --help 2>&1 | grep -q -- '--skip-state-lock' && SKIP="--skip-state-lock"
  out=$($SUDO "$LR" -d $SKIP "$CONF" 2>&1); rc=$?
  echo "  exit code: $rc"
  printf '%s\n' "$out" | grep -E '^(error|warning):|duplicate log entry|skipping .* because' | grep -v 'in debug mode does nothing' | sort | uniq -c | head -n 30 | sed 's/^/  /'
else
  echo "  logrotate not installed"
fi

msc_hr "files claimed by more than one stanza (static check)"
# Collect the path patterns that open each stanza: tokens before '{' outside any block.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
files=("$CONF")
while read -r inc; do
  if [ -d "$inc" ]; then for f in "$inc"/*; do [ -f "$f" ] && files+=("$f"); done
  elif [ -f "$inc" ]; then files+=("$inc"); fi
done < <($SUDO awk '$1=="include"{print $2}' "$CONF" 2>/dev/null)
for f in "${files[@]}"; do
  # logrotate's own default taboo extensions: these files are NOT read. Everything else in the directory IS read,
  # including backup copies such as foo.bak-2026-01-01, which then duplicate the original stanza.
  case "$f" in *,v|*.cfsaved|*.disabled|*.dpkg-bak|*.dpkg-del|*.dpkg-dist|*.dpkg-new|*.dpkg-old|*.rhn-cfg-tmp-*|*.rpmnew|*.rpmorig|*.rpmsave|*.swp|*.ucf-dist|*.ucf-new|*.ucf-old|*~) continue ;; esac
  case "$f" in *.bak*|*.orig|*.old|*.save) echo "WARNING: backup-like file is READ by logrotate: $f (move it out of the directory)" >&2 ;; esac
  $SUDO cat "$f" 2>/dev/null | awk -v F="$f" '
    { sub(/#.*/, "") }
    {
      n = split($0, t, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        tok = t[i]; if (tok == "") continue
        if (tok ~ /^(postrotate|prerotate|firstaction|lastaction|preremove)$/) { inscript = 1; continue }
        if (tok == "endscript") { inscript = 0; continue }
        if (inscript) continue
        if (skipnext) { skipnext = 0; continue }
        if (depth == 0 && tok == "include") { skipnext = 1; pend = ""; continue }
        if (depth == 0 && tok ~ /^"?\//) { gsub(/"/, "", tok); pend = pend " " tok; continue }
        if (tok ~ /^\{/ || tok ~ /\{$/) {
          if (depth == 0) {
            sub(/\{.*/, "", tok); if (tok ~ /^\//) pend = pend " " tok
            m = split(pend, p, " "); for (j = 1; j <= m; j++) if (p[j] != "") print F "\t" p[j]
            pend = ""
          }
          depth++; continue
        }
        if (tok ~ /^\}/) { if (depth > 0) depth--; continue }
        if (depth == 0) pend = ""
      }
    }'
done > "$TMP/patterns.tsv"
: > "$TMP/claims.tsv"
while IFS=$'\t' read -r f pat; do
  # the pattern is passed as an argument and expanded unquoted: globbing only, never command execution
  for p in $($SUDO bash -c 'shopt -s nullglob; for x in $1; do [ -f "$x" ] && printf "%s\n" "$x"; done' _ "$pat" 2>/dev/null); do
    printf '%s\t%s\n' "$p" "$f" >> "$TMP/claims.tsv"
  done
done < "$TMP/patterns.tsv"
dups=$(sort -u "$TMP/claims.tsv" | awk -F'\t' '{c[$1]++; s[$1]=s[$1] " " $2} END{for (k in c) if (c[k]>1) print k "  <=" s[k]}' | sort)
if [ -n "$dups" ]; then printf '%s\n' "$dups" | sed 's/^/  /'
  echo "  -> keep ONE owner per file. Prefer the package's stanza (it survives upgrades); move the custom duplicate out."
else echo "  none"; fi

msc_hr "logs over ${MINMB} MB with no stanza"
$SUDO find "$LOGDIR" -xdev -type f -size +"${MINMB}"M ! -name '*.gz' ! -name '*.[0-9]' ! -name '*.xz' ! -name '*.zst' \
  ! -path "$LOGDIR/journal/*" -printf '%s\t%p\n' 2>/dev/null | sort -rn | while IFS=$'\t' read -r sz p; do
  if ! cut -f1 "$TMP/claims.tsv" | grep -qxF "$p"; then printf '  %8d MB  %s\n' $((sz/1048576)) "$p"; fi
done
echo
echo "Confirm any fix at the NEXT real run (timer above), not with -d alone: systemctl status logrotate.service."
