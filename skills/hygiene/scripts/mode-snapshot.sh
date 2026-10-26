#!/bin/bash
# mode-snapshot.sh — record and restore file modes and owners (the rollback for a permissions change).
#
# Usage:
#   bash mode-snapshot.sh save OUT_FILE PATH [PATH ...]     record mode, owner, group of each path (read-only on PATHs)
#   bash mode-snapshot.sh restore IN_FILE                   print the chown/chmod commands that restore the record
#   bash mode-snapshot.sh restore IN_FILE --apply           run them (a change: only as an agreed rollback)
# Keep OUT_FILE root-only (it lists secret file paths): e.g. /root/<topic>-perms-before-YYYY-MM-DD.txt, mode 600.
# Directories are recorded non-recursively; pass the files inside explicitly (a glob is fine here: it only reads).
set -uo pipefail
set +x
cmd="${1:-}"; shift || true
SUDO=""; [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"

case "$cmd" in
  save)
    out="${1:?OUT_FILE}"; shift
    [ $# -gt 0 ] || { echo "no paths given" >&2; exit 2; }
    { echo "# mode-snapshot $(date '+%F %T')"; for p in "$@"; do $SUDO stat -c '%a	%U	%G	%n' -- "$p"; done; } > "$out.tmp" \
      && mv "$out.tmp" "$out" && chmod 600 "$out" && echo "saved $(grep -vc '^#' "$out") entries to $out"
    ;;
  restore)
    in="${1:?IN_FILE}"; apply="${2:-}"
    grep -v '^#' "$in" | while IFS=$'\t' read -r mode u g path; do
      [ -n "$path" ] || continue
      c1=(chown "$u:$g" -- "$path"); c2=(chmod "$mode" -- "$path")
      if [ "$apply" = "--apply" ]; then $SUDO "${c1[@]}" && $SUDO "${c2[@]}" && echo "restored $mode $u:$g $path"
      else printf 'chown %q %q && chmod %s %q\n' "$u:$g" "$path" "$mode" "$path"; fi
    done
    ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
