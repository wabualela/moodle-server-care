#!/bin/bash
# archive-path.sh — move abandoned directories or files into a root-only archive instead of deleting them.
# Default is a DRY RUN that only prints the plan. With --apply (after the owner approved the exact paths) it:
#   1. creates /root/<topic>-cleanup-YYYY-MM-DD/ (mode 700)
#   2. writes <name>.tgz (tar --one-file-system), checks the entry count against the tree, records sha256 in MANIFEST
#   3. moves the original into <archive>/moved/<name> (instant rollback: move it back)   [skip with --tar-only]
# The owner deletes moved/ when satisfied and the .tgz after the agreed retention (about 30 days).
#
# Usage: bash archive-path.sh --topic NAME [--apply] [--tar-only] PATH [PATH ...]
# Exact paths only: globs are refused, so a sibling (e.g. /opt/app vs /opt/app-tools) can never be caught.
# Why: a move is reversible and frees the live location now; deletion is the owner's later, separate decision.
set -uo pipefail
set +x
TOPIC=""; APPLY=0; TARONLY=0; PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --topic) TOPIC="$2"; shift ;;
    --apply) APPLY=1 ;;
    --tar-only) TARONLY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) PATHS+=("$1") ;;
  esac; shift
done
[ -n "$TOPIC" ] && [ ${#PATHS[@]} -gt 0 ] || { echo "usage: $0 --topic NAME [--apply] [--tar-only] PATH..." >&2; exit 2; }
case "$TOPIC" in *[!A-Za-z0-9._-]*) echo "topic: letters, digits, . _ - only" >&2; exit 2 ;; esac
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
ROOTDIR="${ARCHIVE_ROOT:-/root}"
DEST="$ROOTDIR/$TOPIC-cleanup-$(date +%F)"

for p in "${PATHS[@]}"; do
  case "$p" in *'*'*|*'?'*|*'['*) echo "refusing glob-like path: $p" >&2; exit 2 ;; esac
  case "$(readlink -m "$p")" in /|/etc|/usr|/var|/var/www|/home|/root|/opt|/srv|/boot|/bin|/sbin|/lib*) echo "refusing top-level path: $p" >&2; exit 2 ;; esac
  $SUDO test -e "$p" || { echo "does not exist: $p" >&2; exit 2; }
done

echo "archive directory: $DEST (mode 700)"
for p in "${PATHS[@]}"; do
  ap=$(readlink -m "$p"); name=$(basename "$ap"); parent=$(dirname "$ap")
  n=$($SUDO find "$ap" -xdev 2>/dev/null | wc -l)
  size=$($SUDO du -sh --one-file-system "$ap" 2>/dev/null | cut -f1)
  ref="$ROOTDIR"; while ! $SUDO test -e "$ref"; do ref=$(dirname "$ref"); done
  samefs=yes; [ "$($SUDO stat -c %d "$parent")" = "$($SUDO stat -c %d "$ref")" ] || samefs="no (move = copy + delete, slower)"
  echo "  $ap: $size, $n entries -> $name.tgz$( [ $TARONLY -eq 0 ] && echo " + moved/$name") ; same filesystem as archive: $samefs"
  if [ $APPLY -eq 1 ]; then
    $SUDO install -d -m 700 "$DEST" "$DEST/moved" || exit 1
    tgz="$DEST/$name.tgz"
    $SUDO test -e "$tgz" && tgz="$DEST/$name-$(date +%H%M%S).tgz"
    $SUDO tar --one-file-system -C "$parent" -czf "$tgz" "$name" || { echo "tar failed for $ap; nothing moved" >&2; exit 1; }
    t=$($SUDO tar -tzf "$tgz" | wc -l)
    if [ "$t" -ne "$n" ]; then echo "entry count mismatch for $ap (tree $n, tar $t); nothing moved" >&2; exit 1; fi
    $SUDO sh -c 'cd "$1" && sha256sum "$2" >> MANIFEST && chmod 600 MANIFEST "$2"' _ "$DEST" "$(basename "$tgz")"
    echo "    tar ok: $t entries, $(basename "$tgz")"
    if [ $TARONLY -eq 0 ]; then
      mv_to="$DEST/moved/$name"; $SUDO test -e "$mv_to" && mv_to="$DEST/moved/$name-$(date +%H%M%S)"
      $SUDO mv -- "$ap" "$mv_to" && echo "    moved to $mv_to  (rollback: sudo mv '$mv_to' '$ap')"
      printf '%s\t%s\n' "$ap" "$mv_to" | $SUDO tee -a "$DEST/MOVED.tsv" >/dev/null && $SUDO chmod 600 "$DEST/MOVED.tsv"
    fi
  fi
done
[ $APPLY -eq 0 ] && echo "DRY RUN: nothing changed. Re-run with --apply after the owner approved these exact paths."
exit 0
