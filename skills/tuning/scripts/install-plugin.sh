#!/usr/bin/env bash
# install-plugin.sh — install or upgrade ONE Moodle plugin from a source directory, the careful way
# (moodle-server-care, module "tuning").
#
# Usage:
#   bash install-plugin.sh check   SRC_DIR [options]          read-only: stage, lint, version checks, rsync preview
#   bash install-plugin.sh install SRC_DIR --window=HH-HH [--execute] [options]
#        without --execute: everything "check" does plus the exact steps it would run
#        with --execute (only inside the quiet-hour window): back up the old plugin directory, maintenance on,
#        copy, CLI upgrade with -d max_input_vars=5000, maintenance off, verify
# Options:
#   --exclude=PATTERN   extra rsync exclude (repeatable); defaults below drop development files
#   --allow-unstable    pass --allow-unstable to the upgrade (only for a plugin the owner accepted as non-stable)
#
# Why each step: development folders (.git, CI, dev tools, vendor-patch sources, docs) must not reach the web root;
# the CLI default max_input_vars=1000 fails Moodle's environment check AFTER maintenance mode is already on (first
# server: 3 s of maintenance for nothing); files are copied by the owner of the code tree so root never writes into
# a web-user-writable tree; the old directory is archived so the files can be put back (a database downgrade is not
# possible, so the real rollback for an upgrade is a restore, or uninstall for a new plugin); the upgrade purges all
# caches, so the first page views afterwards are slow: quiet hour only.
#
# Facts (MOODLE, PHP, WEBUSER, SITE) come from ~/.config/moodle-server-care/server.env; environment variables
# override. MSC_BACKUP_BASE (default /root) is where the root-only backup folder is created. The PHP CLI must match
# the site's PHP version (from the FPM socket name or the Apache php module); when detect-env.sh had to guess it, or
# the version cannot be read, the script stops until the caller names it: PHP=php8.3 bash install-plugin.sh ...
set -euo pipefail
set +x
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
php_from_env=${PHP:-}        # an explicit PHP=phpX.Y from the caller, before server.env fills it in
# shellcheck source=lib-env.sh
. "$here/lib-env.sh"
msc_load_env

usage() { sed -n '2,27{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "install-plugin: $*" >&2; exit 2; }

cmd=${1:-}; src=${2:-}
[ -n "$cmd" ] && [ -n "$src" ] || { usage; exit 2; }
shift 2
window=""; execute=0; unstable=0
excludes=(.git/ .github/ .gitlab-ci.yml .gitignore .gitattributes .travis.yml dev/ vendor-patches/ docs/ node_modules/
          .idea/ .vscode/ '*.swp' '*~' .DS_Store .phpunit.result.cache)
for a in "$@"; do
    case "$a" in
        --window=*) window=${a#*=} ;;
        --execute) execute=1 ;;
        --allow-unstable) unstable=1 ;;
        --exclude=*) excludes+=("${a#*=}") ;;
        *) die "unknown option $a" ;;
    esac
done
case "$cmd" in check|install) ;; *) usage; exit 2 ;; esac
msc_need MOODLE PHP WEBUSER
[ -f "$MOODLE/config.php" ] || die "$MOODLE/config.php not found"
[ -f "$src/version.php" ] || die "$src/version.php not found: SRC_DIR must be the plugin's own directory"
command -v rsync >/dev/null || die "rsync is not installed"

# 0. The PHP CLI must be the version the site runs on: upgrade.php with another version would install the plugin
# against other extensions and ini settings than the web server uses. detect-env.sh guesses the newest PHP when it
# finds no FPM socket for the site (Apache, custom socket names): then the caller must name the version.
if [ "${PHP_GUESSED:-0}" = 1 ] && [ -z "$php_from_env" ]; then
    die "the PHP binary ($PHP) was GUESSED by detect-env.sh: check which PHP the site's web server uses, then run again with PHP=phpX.Y in front"
fi
php_v=$("$PHP" -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)
site_v=$(printf '%s' "${FPM_SOCK:-}" | grep -oE 'php-?[0-9]+\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+' || true)
if [ -z "$site_v" ]; then          # Apache with mod_php: the enabled module names the version
    for m in /etc/apache2/mods-enabled/php*.load; do [ -e "$m" ] && site_v=$(basename "$m" .load | grep -oE '[0-9]+\.[0-9]+' || true); done
fi
[ -n "$php_v" ] || die "$PHP does not run"
if [ -n "$site_v" ] && [ "$site_v" != "$php_v" ]; then
    die "$PHP is PHP $php_v but the site runs PHP $site_v (from ${FPM_SOCK:-the Apache module}): run with PHP=php$site_v"
fi
if [ -z "$site_v" ] && [ -z "$php_from_env" ]; then
    die "cannot tell which PHP version the site runs (no version in FPM_SOCK '${FPM_SOCK:-}', no Apache php module): check it, then run with PHP=phpX.Y in front"
fi
echo "== PHP: $PHP ($php_v)$( [ -n "$site_v" ] && echo ", matches the site's PHP $site_v" || echo ", given explicitly by the caller")"

# 1. Stage the source without development files, readable by the web user (it cannot read the operator's home).
stage=$(mktemp -d "${TMPDIR:-/tmp}/msc-plugin.XXXXXX"); chmod 755 "$stage"
trap 'rm -rf "$stage"' EXIT
exargs=(); for e in "${excludes[@]}"; do exargs+=(--exclude="$e"); done
rsync -a --delete "${exargs[@]}" "$src/" "$stage/plugin/"
chmod -R a+rX "$stage"
echo "== staged $(find "$stage/plugin" -type f | wc -l) files from $src (excluded: ${excludes[*]})"

# 2. PHP syntax of every file, with the site's PHP version.
bad=0
while IFS= read -r -d '' f; do
    "$PHP" -l "$f" >/dev/null 2>&1 || { echo "syntax error: ${f#"$stage"/plugin/}"; bad=1; }
done < <(find "$stage/plugin" -name '*.php' -print0)
[ "$bad" = 0 ] || die "PHP syntax errors: nothing installed"
echo "== php -l ($PHP): all files OK"

# 3. Versions, target directory, dependencies (read-only, as the web user).
install -m 644 "$here/plugin-info.php" "$stage/plugin-info.php"
set +e
info=$(cd / && msc_as "$WEBUSER" "$PHP" "$stage/plugin-info.php" --moodle="$MOODLE" --source="$stage/plugin")
irc=$?
set -e
echo "$info" | sed 's/^/   /'
[ "$irc" -eq 0 ] || die "pre-flight found errors: nothing installed"
val() { echo "$info" | sed -n "s/^$1=//p" | head -n 1; }
component=$(val COMPONENT); target=$(val TARGET); action=$(val ACTION); newv=$(val NEW); oldv=$(val INSTALLED)
[ -n "$target" ] || die "no target directory"
case "$target" in "$MOODLE"/*) ;; *) die "target $target is outside $MOODLE" ;; esac
parent=$(dirname "$target")
[ -d "$parent" ] || die "plugin type directory $parent does not exist"

# 4. Nothing else may be pending: the CLI upgrade would install it too.
upgrade=("$PHP" -d max_input_vars=5000 "$MOODLE/admin/cli/upgrade.php")
set +e
(cd / && msc_as "$WEBUSER" "${upgrade[@]}" --is-pending >/dev/null 2>&1); prc=$?
set -e
case "$prc" in
    0) echo "== no upgrade pending before the copy (good)" ;;
    2) die "an upgrade is ALREADY pending (another plugin or core files changed): resolve that first; nothing installed" ;;
    *) die "upgrade.php --is-pending failed (exit $prc); nothing installed" ;;
esac

# 5. Ownership and modes follow the existing tree.
owner=$(stat -c %U "$parent"); group=$(stat -c %G "$parent")
sib=$(find "$parent" -mindepth 2 -maxdepth 2 -name version.php -type f 2>/dev/null | grep -v "^$target/" | head -n 1 || true)
fmode=644; dmode=755
if [ -n "$sib" ]; then fmode=$(stat -c %a "$sib"); dmode=$(stat -c %a "$(dirname "$sib")"); fi
echo "== target $target ($action: installed ${oldv:-none} -> new $newv); copy as $owner, dirs $dmode, files $fmode (like ${sib:-default})"
echo "== rsync preview (deletions included: files the new version no longer has are removed):"
(cd / && msc_as "$owner" rsync -rlptn --delete --itemize-changes --chmod="D$dmode,F$fmode" "$stage/plugin/" "$target/" 2>&1 | head -n 40) || true

if [ "$cmd" = check ]; then
    echo "check only: nothing changed. Next: install with --window=HH-HH (quiet hours) and --execute, after the owner agrees."
    exit 0
fi

# install
[[ "$window" =~ ^([01][0-9]|2[0-3])-([01][0-9]|2[0-4])$ ]] || die "--window=HH-HH is required (the measured quiet hours, e.g. 02-05)"
from=${BASH_REMATCH[1]#0}; to=${BASH_REMATCH[2]#0}; now=$(date +%H); now=${now#0}
[ "${from:-0}" != "${to:-0}" ] || die "--window start and end must differ"
inwin=0
if [ "${from:-0}" -lt "${to:-0}" ]; then [ "${now:-0}" -ge "${from:-0}" ] && [ "${now:-0}" -lt "${to:-0}" ] && inwin=1
else { [ "${now:-0}" -ge "${from:-0}" ] || [ "${now:-0}" -lt "${to:-0}" ]; } && inwin=1; fi
ts=$(date +%F); bdir="${MSC_BACKUP_BASE:-/root}/tuning-plugin-$component-$ts"
upargs=(--non-interactive); [ "$unstable" = 1 ] && upargs+=(--allow-unstable)
cat <<EOF
== steps $( [ "$execute" = 1 ] && echo "to run now" || echo "(dry run: add --execute)" ):
 1. backup: tar of $target -> $bdir/ (root-only)$( [ -d "$target" ] || echo " [new plugin: nothing to back up]")
 2. maintenance on:  $PHP $MOODLE/admin/cli/maintenance.php --enable   (as $WEBUSER)
 3. copy: rsync --delete as $owner into $target
 4. upgrade:         ${upgrade[*]} ${upargs[*]}   (as $WEBUSER)
 5. maintenance off: $PHP $MOODLE/admin/cli/maintenance.php --disable
 6. verify: nothing pending, version $newv installed, login page answers
EOF
[ "$execute" = 1 ] || exit 0
[ "$inwin" = 1 ] || die "now is $(date +%H:%M), outside the window $window: nothing changed"

if [ -d "$target" ]; then
    msc_root install -d -m 700 "$bdir"
    msc_root tar -C "$parent" -czf "$bdir/$(basename "$target")-$(date +%H%M%S).tgz" "$(basename "$target")"
    echo "backup: $bdir (installed version ${oldv:-?})"
fi
t0=$(date +%T)
(cd / && msc_as "$WEBUSER" "$PHP" "$MOODLE/admin/cli/maintenance.php" --enable)
echo "maintenance ON at $t0"
# From here on a failure must never exit silently: the site is in maintenance mode and the plugin may be half-copied.
if ! (cd / && msc_as "$owner" rsync -rlpt --delete --chmod="D$dmode,F$fmode" "$stage/plugin/" "$target/"); then
    cat >&2 <<EOF
install-plugin: the COPY FAILED (rsync as $owner into $target). Maintenance mode is still ON (since $t0): the plugin
directory may be half-copied, and no upgrade ran. Choose with the owner:
  a) fix the cause (disk space, permissions) and run the same install command again
  b) roll back the files: move $target aside, restore the tar from $bdir (if it existed), then
     (as $WEBUSER) $PHP $MOODLE/admin/cli/maintenance.php --disable
EOF
    exit 1
fi
set +e
(cd / && msc_as "$WEBUSER" "${upgrade[@]}" "${upargs[@]}"); urc=$?
set -e
if [ "$urc" -ne 0 ]; then
    cat >&2 <<EOF
install-plugin: the upgrade FAILED (exit $urc). Maintenance mode is still ON on purpose: the new files may not match
the database. Choose with the owner:
  a) fix the cause and run again: (as $WEBUSER) ${upgrade[*]} ${upargs[*]}
  b) roll back the files: move $target aside, restore the tar from $bdir (if it existed), then
     (as $WEBUSER) $PHP $MOODLE/admin/cli/maintenance.php --disable
EOF
    exit 1
fi
(cd / && msc_as "$WEBUSER" "$PHP" "$MOODLE/admin/cli/maintenance.php" --disable)
t1=$(date +%T)
echo "maintenance OFF at $t1 (on since $t0)"
set +e
(cd / && msc_as "$WEBUSER" "${upgrade[@]}" --is-pending >/dev/null 2>&1); prc=$?
info2=$(cd / && msc_as "$WEBUSER" "$PHP" "$stage/plugin-info.php" --moodle="$MOODLE" --source="$stage/plugin")
set -e
now_inst=$(echo "$info2" | sed -n 's/^INSTALLED=//p')
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 ${SITE:+--resolve "$SITE:443:127.0.0.1"} "https://${SITE:-localhost}/login/index.php" || true)
echo "verify: pending=$([ "$prc" = 0 ] && echo no || echo "YES (exit $prc)"), installed=$now_inst (want $newv), login page HTTP $code"
[ "$prc" = 0 ] && [ "$now_inst" = "$newv" ] || { echo "install-plugin: verification failed: check the output above" >&2; exit 1; }
echo "done. All caches were purged by the upgrade: expect slower first page views for a few minutes. Log the change."
