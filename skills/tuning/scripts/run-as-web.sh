#!/usr/bin/env bash
# run-as-web.sh — run one of this module's PHP CLI scripts as the site's web user (core-rules §8).
#
# Usage: bash run-as-web.sh SCRIPT.php [script options...]
#
# Why: Moodle CLI code must run as the PHP-FPM pool user, or cache and data files get the wrong owner. The web user
# usually cannot read the operator's home (mode 700), and a heredoc into /dev/stdin under sudo fails, so the script
# is copied into a fresh directory under /tmp (dir 755, file 644), run with the site's PHP binary, and removed.
# --moodle=<MOODLE> is added unless the caller passes --moodle.
#
# Facts come from ~/.config/moodle-server-care/server.env (skills/start/scripts/detect-env.sh); MOODLE, PHP and
# WEBUSER in the environment override it. Output files the PHP script writes (--plan-out, --backup) must be in a
# directory the web user can write, e.g. /tmp; move them to a root-only folder afterwards.
set -euo pipefail
set +x
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-env.sh
. "$here/lib-env.sh"
msc_load_env

[ $# -ge 1 ] || { sed -n '2,13{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 2; }
script=$1; shift
[ -f "$script" ] || script="$here/$script"
[ -f "$script" ] || { echo "run-as-web: no such script: $1" >&2; exit 2; }
msc_need MOODLE PHP WEBUSER
[ -f "$MOODLE/config.php" ] || { echo "run-as-web: $MOODLE/config.php not found" >&2; exit 2; }

has_moodle=0
for a in "$@"; do case "$a" in --moodle|--moodle=*) has_moodle=1 ;; esac; done
args=("$@")
[ "$has_moodle" = 1 ] || args+=("--moodle=$MOODLE")

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/msc-tuning.XXXXXX")
trap 'rm -rf "$tmpd"' EXIT
chmod 755 "$tmpd"
base=$(basename "$script")
install -m 644 "$script" "$tmpd/$base"
cd /   # the web user may not be allowed to enter the caller's working directory
msc_as "$WEBUSER" "$PHP" "$tmpd/$base" "${args[@]}"
