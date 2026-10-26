#!/usr/bin/env bash
# vendorpatch.sh — apply, check, pin and roll back small patches to THIRD-PARTY Moodle plugin code (themes, page
# builders, ...) safely. Generic version of the tool used on the first server (moodle-server-care, module "tuning").
#
# Usage:
#   vendorpatch.sh status  PATCH            state of each patched file; exit 0 applied, 1 not applied, 3 unknown
#   vendorpatch.sh pin     PATCH [--force]  write PATCH.sha256 from the live files (pre) and a staged patched copy
#                                           (post); read-only on the live tree; run on the exact vendor release
#   vendorpatch.sh apply   PATCH            check hashes, patch a staged copy, php -l, check hashes, back up, swap
#   vendorpatch.sh revert  PATCH            reverse the patch (patch -R) the same way, verify the original hashes
#   vendorpatch.sh restore BACKUPDIR [--force]
#                                           put back the files saved by apply/revert (when revert is impossible);
#                                           refuses if the vendor release changed since the backup, unless --force
#
# PATCH is a path to a unified diff (paths a/<path> b/<path>, relative to the web root, e.g. theme/x/classes/y.php)
# or a name resolved as $VP_PATCH_DIR/NAME.diff. Its pin file PATCH.sha256 sits next to it, lines
# "<pre-sha256> <post-sha256> <path>", optional header "# marker: TEXT" (the comment tag each patched line carries;
# default LOCAL-PATCH). Keep patches in the owner's own repository, never inside the Moodle tree.
#
# Environment (defaults from ~/.config/moodle-server-care/server.env when present):
#   VP_ROOT       web root the patch paths are relative to (default DOCROOT: <MOODLE>/public on 5.1+, else <MOODLE>)
#                 (MOODLE_PUBLIC is accepted as an alias)
#   VP_PATCH_DIR  where PATCH names are looked up (default: current directory)
#   BACKUP_ROOT   where apply/revert save the files they replace (default /var/backups/moodle-vendor-patches)
#   PHP           PHP binary for the syntax check (default: the site's PHP from server.env, else php)
#
# Why it is built this way: a patch is applied only to the exact vendor release it was written and tested for (sha256
# pins), so a vendor upgrade makes "apply" refuse instead of half-patching new code. Files are replaced by their owner
# (runuser) through a random temporary name and an atomic rename in the same directory: root never writes inside a
# web-user-writable tree, a planted symbolic link gains nothing, and PHP never reads a half-written file. Files tracked
# by a Moodle core git checkout are refused (core is never patched).
set -euo pipefail
set +x

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "vendorpatch: $*" >&2; exit 2; }

# Load server.env facts without letting them override the caller's environment (only when owned by us or root and
# not writable by others). The file is parsed, never sourced: this script runs as root. Self-contained on purpose
# (the script is also copied on its own), so it reads just the three keys it needs.
load_env() {
    local f home owner perm k keep_root=${VP_ROOT:-${MOODLE_PUBLIC:-}} keep_php=${PHP:-} line kk vv
    f=${MSC_ENV:-}
    if [ -z "$f" ]; then
        home=$HOME
        [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        f="$home/.config/moodle-server-care/server.env"
    fi
    if [ -f "$f" ]; then
        owner=$(stat -c %u "$f"); perm=$(stat -c %a "$f")
        if { [ "$owner" = "$(id -u)" ] || [ "$owner" = 0 ] || [ "$owner" = "$(id -u "${SUDO_USER:-root}" 2>/dev/null)" ]; } \
            && [ $(( 8#$perm & 8#022 )) -eq 0 ] && [ ! -L "$f" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                case $line in MOODLE=*|DOCROOT=*|PHP=*) ;; *) continue ;; esac
                kk=${line%%=*}; vv=${line#*=}
                case $vv in                       # plain, 'quoted', "quoted" or printf-%q values
                    \'*\') vv=${vv:1:${#vv}-2} ;;
                    \"*\") vv=${vv:1:${#vv}-2} ;;
                    *\\*) vv=$(printf '%s' "$vv" | sed 's/\\\(.\)/\1/g') ;;
                esac
                printf -v "$kk" '%s' "$vv"
            done < "$f"
        fi
    fi
    k=${DOCROOT:-}
    if [ -z "$k" ] && [ -n "${MOODLE:-}" ]; then
        if [ -f "$MOODLE/public/version.php" ]; then k="$MOODLE/public"; else k="$MOODLE"; fi
    fi
    root=${keep_root:-$k}
    php=${keep_php:-${PHP:-php}}
}

# Replace (or create) file $1 with the content of $2, as the owner of the target (or of its directory).
swap() {
    local target=$1 source=$2 owner mode ref
    [ ! -L "$target" ] || die "$target is a symbolic link; refusing"
    if [ -e "$target" ]; then ref=$target; mode=$(stat -c %a "$target"); else ref=$(dirname "$target"); mode=$(stat -c %a "$source"); fi
    owner=$(stat -c %U "$ref")
    local run=()
    # VP_TEST_RUNUSER lets test-vendorpatch.sh exercise this path without root.
    if [ "$(id -u)" -eq 0 ] || [ -n "${VP_TEST_RUNUSER:-}" ]; then
        run=("${VP_TEST_RUNUSER:-runuser}" -u "$owner" --)
    fi
    # The source is opened by this shell and passed on stdin, so a private staging directory stays private.
    "${run[@]}" sh -c 'set -e; t=$(mktemp "$1.vpnew.XXXXXX"); cat > "$t"; chmod "$2" "$t"; mv -fT "$t" "$1"' \
        sh "$target" "$mode" < "$source" || die "could not replace $target"
}

# Directory (relative to the root) of the plugin that holds a file: the nearest parent with a version.php.
component_dir() {
    local d
    d=$(dirname "$1")
    while [ "$d" != "." ] && [ "$d" != "/" ]; do
        [ -f "$root/$d/version.php" ] && { echo "$d"; return 0; }
        d=$(dirname "$d")
    done
    return 1
}

refuse_core() {  # refuse files tracked by a core git checkout (core-rules: never patch Moodle core)
    local p=$1
    command -v git >/dev/null || { echo "vendorpatch: git not installed; cannot check that $p is not a core file" >&2; return 0; }
    if git -c safe.directory='*' -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && git -c safe.directory='*' -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
        die "$p is tracked by the Moodle core git checkout: core files are never patched (report it upstream instead)"
    fi
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
case "$cmd" in -h|--help) usage; exit 0 ;; esac
load_env
backuproot=${BACKUP_ROOT:-/var/backups/moodle-vendor-patches}
[ -n "$root" ] || die "web root unknown: set VP_ROOT, or run skills/start/scripts/detect-env.sh first"
[ -d "$root" ] || die "no web root $root"

if [ "$cmd" = restore ]; then
    dir=${2:-}
    force=${3:-}
    [ -d "$dir/files" ] || die "restore needs the backup directory printed by apply or revert"
    [ -z "$force" ] || [ "$force" = --force ] || die "unknown option $force"
    [ "$(id -u)" -eq 0 ] || [ "${ALLOW_NONROOT:-0}" = 1 ] || die "run with sudo"
    # Refuse to mix releases: the vendor version.php files must be the ones saved with the backup.
    if [ -d "$dir/meta" ]; then
        while IFS= read -r v; do
            v=${v#./}
            cmp -s "$dir/meta/$v" "$root/$v" || [ "$force" = --force ] ||
                die "$v changed since the backup (vendor upgrade?); nothing done. Use --force only if you are sure."
        done < <(cd "$dir/meta" && find . -name version.php -type f -print)
    elif [ "$force" != --force ]; then
        die "the backup has no release information (meta/); nothing done. Use --force only if you are sure."
    fi
    files=()
    while IFS= read -r f; do files+=("${f#./}"); done < <(cd "$dir/files" && find . -type f -print)
    pre="$backuproot/$(date -u +%Y%m%dT%H%M%SZ)-pre-restore"
    mkdir -p "$pre/files"; chmod 700 "$backuproot" "$pre" 2>/dev/null || true
    for f in "${files[@]}"; do
        if [ -e "$root/$f" ]; then (cd "$root" && cp -a --parents "$f" "$pre/files/"); fi
    done
    [ ! -d "$dir/meta" ] || cp -a "$dir/meta" "$pre/meta"
    echo "saved the current files in $pre"
    for f in "${files[@]}"; do
        swap "$root/$f" "$dir/files/$f"
        if cmp -s "$dir/files/$f" "$root/$f"; then echo "restored $root/$f"; else die "restore of $f failed"; fi
    done
    exit 0
fi

name=${2:-}
[ -n "$name" ] || die "name the patch (a .diff path or a name in \$VP_PATCH_DIR)"
case "$name" in
    */*|*.diff) diff=${name%.diff}.diff ;;
    *) diff="${VP_PATCH_DIR:-.}/$name.diff" ;;
esac
sums=${diff%.diff}.sha256
pname=$(basename "${diff%.diff}")
[ -f "$diff" ] || die "no patch $diff"

m=""
[ ! -f "$sums" ] || m=$(sed -nE 's/^#[[:space:]]*marker:[[:space:]]*(.+[^[:space:]])[[:space:]]*$/\1/p' "$sums" | head -n 1)
# No pin yet: take VP_MARKER, else the first WORD-PATCH tag on an added line of the diff, else LOCAL-PATCH.
[ -n "$m" ] || m=${VP_MARKER:-$(grep -E '^\+[^+]' "$diff" | grep -oE '[A-Z][A-Z0-9_]*-PATCH' | head -n 1 || true)}
marker=${m:-LOCAL-PATCH}

# Paths a diff touches (from the +++ lines, a/ b/ prefixes removed).
diff_paths() { sed -nE 's#^\+\+\+ b/([^[:space:]]+).*#\1#p' "$diff" | sort -u; }

if [ "$cmd" = pin ]; then
    [ ! -f "$sums" ] || [ "${3:-}" = --force ] || die "$sums exists; use --force to overwrite it"
    command -v patch >/dev/null || die "GNU patch is not installed"
    stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
    mapfile -t paths < <(diff_paths)
    [ "${#paths[@]}" -gt 0 ] || die "no '+++ b/<path>' lines in $diff"
    for p in "${paths[@]}"; do
        [ ! -L "$root/$p" ] || die "$p is a symbolic link"
        [ -f "$root/$p" ] || die "$p does not exist under $root"
        refuse_core "$p"
        (cd "$root" && cp -a --parents "$p" "$stage/")
    done
    patch -p1 -N -F0 --dry-run -d "$stage" < "$diff" >/dev/null || die "the patch does not apply cleanly to the live files (wrong release, or already applied?)"
    patch -p1 -N -F0 --no-backup-if-mismatch -d "$stage" < "$diff" >/dev/null || die "patch failed"
    for p in "${paths[@]}"; do
        case "$p" in *.php) "$php" -l "$stage/$p" >/dev/null || die "syntax error in patched $p" ;; esac
    done
    tmp=$(mktemp)
    {
        echo "# pre-patch sha256, post-patch sha256, path relative to the Moodle web root."
        echo "# marker: $marker"
        for p in "${paths[@]}"; do
            cd_=$(component_dir "$p" || true)
            rel=""; [ -n "$cd_" ] && rel=$(sed -nE "s/^\\\$plugin->release[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$root/$cd_/version.php" | head -n 1)
            [ -z "$cd_" ] || echo "# ${cd_}: release ${rel:-?}, version $(sed -nE 's/^\$plugin->version[[:space:]]*=[[:space:]]*([0-9.]+).*/\1/p' "$root/$cd_/version.php" | head -n 1)"
        done | sort -u
        for p in "${paths[@]}"; do
            echo "$(sha256sum "$root/$p" | cut -d' ' -f1) $(sha256sum "$stage/$p" | cut -d' ' -f1) $p"
        done
    } > "$tmp"
    mv "$tmp" "$sums"; chmod 644 "$sums"
    echo "wrote $sums:"; cat "$sums"
    grep -q -F -- "$marker" "$diff" || echo "note: the diff contains no '$marker' marker; add one comment per changed block so status can show it" >&2
    exit 0
fi

[ -f "$sums" ] || die "no hash list $sums (create it with: $0 pin $diff)"

# State of one file: original, patched, or unknown (vendor changed, or edited by hand).
state() {
    local pre=$1 post=$2 path=$3 sum
    [ ! -L "$root/$path" ] || { echo unknown; return; }
    [ -f "$root/$path" ] || { echo missing; return; }
    sum=$(sha256sum "$root/$path" | cut -d' ' -f1)
    if [ "$sum" = "$pre" ]; then echo original
    elif [ "$sum" = "$post" ]; then echo patched
    else echo unknown
    fi
}
states() {
    while read -r pre post path; do
        [ -n "${path:-}" ] && [ "${pre:0:1}" != "#" ] || continue
        echo "$(state "$pre" "$post" "$path") $path"
    done < "$sums"
}

case "$cmd" in
    status)
        rc=0
        while read -r st path; do
            cd_=$(component_dir "$path" || true)
            release=""; [ -n "$cd_" ] && release=$(sed -nE "s/^\\\$plugin->release[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$root/$cd_/version.php" 2>/dev/null | head -n 1)
            markers=$(grep -c -F -- "$marker" "$root/$path" 2>/dev/null || true)
            printf '%-9s %-60s release %-10s markers %s\n' "$st" "$path" "${release:-?}" "${markers:-0}"
            case "$st" in
                patched) ;;
                original) [ "$rc" -eq 3 ] || rc=1 ;;
                *) rc=3 ;;
            esac
        done < <(states)
        case "$rc" in
            0) echo "$pname: applied" ;;
            1) echo "$pname: NOT applied (vendor files are the pinned originals)" ;;
            3) echo "$pname: UNKNOWN state (vendor upgraded or file edited): re-check before doing anything" ;;
        esac
        exit "$rc"
        ;;
    apply|revert)
        [ "$(id -u)" -eq 0 ] || [ "${ALLOW_NONROOT:-0}" = 1 ] || die "run with sudo"
        command -v patch >/dev/null || die "GNU patch is not installed"
        want=original; done_state=patched; rev=()
        if [ "$cmd" = revert ]; then want=patched; done_state=original; rev=(-R); fi
        files=()
        all_done=1
        while read -r st path; do
            files+=("$path")
            refuse_core "$path"
            if [ "$st" = "$done_state" ]; then continue; fi
            all_done=0
            [ "$st" = "$want" ] || die "$path is '$st', expected '$want': vendor release changed or file edited; nothing done"
        done < <(states)
        if [ "$all_done" = 1 ]; then echo "$pname: already $done_state, nothing to do"; exit 0; fi
        while read -r st path; do
            [ "$st" = "$want" ] || die "$path is already '$st' while others are not: fix by hand (status/restore)"
        done < <(states)
        # Patch and lint a staged copy first; the live files are only replaced once everything is verified.
        stage=$(mktemp -d)
        trap 'rm -rf "$stage"' EXIT
        for f in "${files[@]}"; do (cd "$root" && cp -a --parents "$f" "$stage/"); done
        patch "${rev[@]}" -p1 -N -F0 --dry-run -d "$stage" < "$diff" >/dev/null || die "dry run failed; nothing done"
        patch "${rev[@]}" -p1 -N -F0 --no-backup-if-mismatch -d "$stage" < "$diff" >/dev/null || die "patch failed; nothing done"
        for f in "${files[@]}"; do
            case "$f" in *.php) "$php" -l "$stage/$f" >/dev/null || die "syntax error in patched $f; nothing done" ;; esac
        done
        while read -r pre post path; do
            [ -n "${path:-}" ] && [ "${pre:0:1}" != "#" ] || continue
            sum=$(sha256sum "$stage/$path" | cut -d' ' -f1)
            if [ "$cmd" = apply ]; then wantsum=$post; else wantsum=$pre; fi
            [ "$sum" = "$wantsum" ] || die "staged $path has hash $sum, expected $wantsum; nothing done"
        done < "$sums"
        backup="$backuproot/$(date -u +%Y%m%dT%H%M%SZ)-$pname-$cmd"
        mkdir -p "$backup/files"; chmod 700 "$backuproot" 2>/dev/null || true
        for f in "${files[@]}"; do (cd "$root" && cp -a --parents "$f" "$backup/files/"); done
        # Release information, so "restore" can refuse to put these files into another vendor release.
        mkdir -p "$backup/meta"
        for f in "${files[@]}"; do
            cd_=$(component_dir "$f" || true)
            [ -z "$cd_" ] || (cd "$root" && cp -a --parents "$cd_/version.php" "$backup/meta/")
        done
        cp "$sums" "$backup/meta/"
        echo "saved the current files in $backup"
        for f in "${files[@]}"; do
            swap "$root/$f" "$stage/$f"
        done
        while read -r st path; do
            [ "$st" = "$done_state" ] || { echo "vendorpatch: $path is '$st' after $cmd; restore with: $0 restore $backup" >&2; exit 2; }
        done < <(states)
        echo "$pname: $cmd done."
        echo "PHP picks the change up after opcache.revalidate_freq seconds when opcache.validate_timestamps=1 (check"
        echo "the FPM pool's values, not the CLI's); with validate_timestamps=0 a gentle PHP-FPM reload is needed."
        echo "roll back with: $0 $([ "$cmd" = apply ] && echo revert || echo apply) $diff   (or: $0 restore $backup)"
        ;;
    *) usage; exit 2 ;;
esac
