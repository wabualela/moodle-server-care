#!/bin/bash
# inventory-paths.sh — read-only inventory for removing abandoned projects and personal-data files.
#
# Usage:
#   bash inventory-paths.sh --discover            candidate project directories in /var/www /srv /opt /home/* + whether
#                                                 enabled web config, crontabs, systemd or processes reference them
#   bash inventory-paths.sh PATH [PATH ...]       detailed check of each path: size, git state (clean? pushed?),
#                                                 config files, every kind of reference, sibling names a glob would hit
#   bash inventory-paths.sh --personal-data       files that look like data exports or dumps (names, sizes, dates only)
#   bash inventory-paths.sh --docker              containers, images, volumes, docker-group members (no changes)
# Never prints file contents. Never deletes or moves anything (see archive-path.sh for the move, with --apply).
#
# Why: "nothing uses it" must be proven, not assumed: an enabled vhost, a crontab line, a systemd unit, a running
# process, a symlink or another app's config can depend on a directory that looks abandoned. Exact paths only:
# a glob like /opt/moodle* would also match a sibling such as /opt/moodle-maintenance.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
prep_refs() {
  [ -f "$TMP/web.txt" ] && return
  msc_webconf_dump > "$TMP/web.txt"
  # redacted when collected: the matching lines are printed below (passwords, tokens, ping keys, addresses removed)
  for u in $(msc_cron_users); do $SUDO crontab -l -u "$u" 2>/dev/null | msc_redact_cron | sed "s#^#crontab:$u: #"; done > "$TMP/cron.txt"
  $SUDO grep -rs "" /etc/crontab /etc/cron.d 2>/dev/null | msc_redact_cron | sed 's#^#cron.d:#' >> "$TMP/cron.txt"
  $SUDO grep -rs "" /etc/systemd/system /lib/systemd/system/*.service 2>/dev/null | grep -vE '\.wants/' > "$TMP/units.txt" || true
  $SUDO grep -rs "" /etc/supervisor /etc/php/*/fpm/pool.d /etc/logrotate.d 2>/dev/null > "$TMP/other_etc.txt" || true
  for p in /proc/[0-9]*; do
    c=$($SUDO readlink "$p/cwd" 2>/dev/null) && printf '%s\tcwd\t%s\n' "${p#/proc/}" "$c"
    e=$($SUDO readlink "$p/exe" 2>/dev/null) && printf '%s\texe\t%s\n' "${p#/proc/}" "$e"
  done > "$TMP/procs.tsv"
}

refs_for() {  # PATH -> lines describing references (empty = none found)
  local p="$1" n
  n=$(grep -cF "$p" "$TMP/web.txt"); [ "$n" -gt 0 ] && echo "    enabled web config: $n line(s): $(awk -v pat="$p" '/^# configuration file /{f=$4; sub(/:$/,"",f)} index($0,pat){print f}' "$TMP/web.txt" | sort -u | tr '\n' ' ')"
  grep -F "$p" "$TMP/cron.txt" | sed 's/^/    cron: /' | cut -c1-200
  awk -F: -v pat="$p" 'index($0,pat){print "    systemd: " $1}' "$TMP/units.txt" | sort -u
  awk -F: -v pat="$p" 'index($0,pat){print "    other /etc: " $1}' "$TMP/other_etc.txt" | sort -u
  awk -F'\t' -v pat="$p" '$3==pat || index($3,pat "/")==1 {print "    process " $1 " (" $2 "): " $3}' "$TMP/procs.tsv" | head -n 5
  for d in /var/www /etc /home /opt /srv; do
    $SUDO find "$d" -maxdepth 3 -type l -lname "$p*" -printf '    symlink: %p -> %l\n' 2>/dev/null
  done
  # other apps' config files naming the path (depth-limited, config-like files only)
  $SUDO find $(msc_app_roots) -maxdepth 3 -type f \( -name '.env' -o -name 'config.php' -o -name '*.conf' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' \) \
      ! -path "$p/*" 2>/dev/null | xargs -r $SUDO grep -lF "$p" 2>/dev/null | head -n 5 | sed 's/^/    other app config: /'
}

git_state() {
  local p="$1" g="git -c safe.directory=* -C $1"
  $SUDO test -d "$p/.git" || { echo "    git: not a git checkout"; return; }
  echo "    git: remote $($SUDO $g remote get-url origin 2>/dev/null || echo none), branch $($SUDO $g rev-parse --abbrev-ref HEAD 2>/dev/null), HEAD $($SUDO $g log -1 --format='%h %cs' 2>/dev/null)"
  echo "         uncommitted entries: $($SUDO $g status --porcelain 2>/dev/null | wc -l), commits not on any remote: $($SUDO $g log --oneline --branches --not --remotes 2>/dev/null | wc -l)"
  echo "         (untracked-but-ignored files, e.g. config.php or .env, are not in git: check them below)"
}

detail() {
  local p="$1"
  msc_hr "$p"
  $SUDO test -e "$p" || { echo "    does not exist"; return; }
  echo "    size: $($SUDO du -sh --one-file-system "$p" 2>/dev/null | cut -f1), entries: $($SUDO find "$p" -xdev 2>/dev/null | wc -l), newest file: $($SUDO find "$p" -xdev -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -n 1)"
  echo "    owner/mode: $($SUDO stat -c '%U:%G %a' "$p")"
  git_state "$p"
  for f in config.php .env wp-config.php docker-compose.yml compose.yaml supabase/config.toml database/database.sqlite; do
    $SUDO test -e "$p/$f" && echo "    has $f$( [ "$f" = config.php ] && $SUDO grep -q 'CFG->wwwroot' "$p/$f" 2>/dev/null && echo ' (Moodle config: holds DB credentials and a dataroot)')"
  done
  $SUDO find "$p" -maxdepth 3 -xdev -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.sqlite' -o -name '*.csv' -o -name '*.xlsx' -o -name '*.dump' \) \
    -printf '    data-like file: %p (%s B)\n' 2>/dev/null | head -n 10
  r=$(refs_for "$p")
  if [ -n "$r" ]; then echo "    REFERENCES:"; printf '%s\n' "$r"; else echo "    references: none found (web config, crontabs, systemd, other /etc, processes, symlinks, other app configs)"; fi
  sib=$(ls -d "${p%/}"?* 2>/dev/null | grep -vxF "$p" | tr '\n' ' ')
  [ -n "$sib" ] && echo "    SIBLINGS a glob '${p%/}*' would also match: $sib  -> use the exact path"
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  --discover)
    prep_refs
    msc_hr "candidate project directories (not the live Moodle code or dataroot)"
    for d in $(for r in $MSC_SCAN_ROOTS; do if [ "$r" = /home ]; then ls -d /home/*/* 2>/dev/null; else ls -d "$r"/* 2>/dev/null; fi; done); do
      [ -d "$d" ] || continue
      case "$d" in "${MOODLE:-/nonexistent}"|"${DATAROOT:-/nonexistent}"|"$(dirname "${MOODLE:-/x/y}")") continue ;; esac
      case "$(basename "$d")" in .*|snap|go|node_modules) continue ;; esac
      marker=""
      for m in .git artisan composer.json package.json index.php index.html config.php docker-compose.yml; do $SUDO test -e "$d/$m" && marker="$marker $m"; done
      [ -z "$marker" ] && [[ "$d" == /home/* ]] && continue   # home dirs: only project-like folders
      nref=$( { grep -cF "$d" "$TMP/web.txt"; grep -cF "$d" "$TMP/cron.txt"; grep -cF "$d" "$TMP/units.txt"; awk -F'\t' -v pat="$d" '$3==pat || index($3,pat "/")==1' "$TMP/procs.tsv" | wc -l; } | awk '{s+=$1} END{print s+0}')
      printf '  %-45s %8s  refs=%-3s %s\n' "$d" "$($SUDO du -sh --one-file-system "$d" 2>/dev/null | cut -f1)" "$nref" "${marker:- (no project marker)}"
    done
    echo
    echo "refs=0 is a candidate, not a verdict: run '$0 <path>' for the detailed check, then ask the owner." ;;
  --personal-data)
    msc_hr "data-like files (names, sizes, dates only)"
    $SUDO find ${MSC_PD_ROOTS:-/home /root /var/www /opt /srv /tmp} -xdev -maxdepth 4 -type f \( -iname '*.csv' -o -iname '*.tsv' -o -iname '*.xlsx' -o -iname '*.xls' \
        -o -iname '*.sql' -o -iname '*.sql.gz' -o -iname '*.sql.zst' -o -iname '*.sqlite' -o -iname '*.db' -o -iname '*.dump' -o -iname '*.mbox' \
        -o \( -iname '*.tar*' -size +50M \) -o \( -iname '*.zip' -size +50M \) -o \( -iname '*.tgz' -size +50M \) \) \
        -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path "${MSC_PD_EXCLUDE:-/tmp/claude-*}" -not -path "${DATAROOT:-/nonexistent}/*" \
        -printf '  %TY-%Tm-%Td  %12s B  %u:%g %m  %p\n' 2>/dev/null | sort -k2,2nr
    echo
    echo "Classify each file with the owner: live app database (never touch), rollback/backup copy (keep until its"
    echo "condition is met), export with personal data (owner decides; owner runs the delete). Also: /var/mail/*." ;;
  --docker)
    msc_hr "docker"
    if ! msc_have docker; then echo "  docker not installed"; exit 0; fi
    echo "  service: $(systemctl is-active docker 2>/dev/null), containerd: $(systemctl is-active containerd 2>/dev/null)"
    echo "  containers (all states): $($SUDO docker ps -aq 2>/dev/null | wc -l)"
    $SUDO docker ps -a --format '    {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null
    echo "  images:"; $SUDO docker image ls --format '    {{.Repository}}:{{.Tag}}  {{.Size}}  created {{.CreatedSince}}' 2>/dev/null
    echo "  volumes (may hold databases: owner decides each one):"
    $SUDO docker volume ls --format '    {{.Name}}' 2>/dev/null
    $SUDO docker system df 2>/dev/null | sed 's/^/    /'
    echo "  storage: $($SUDO du -sh /var/lib/docker /var/lib/containerd 2>/dev/null | tr '\n' ' ')"
    echo "  docker group members (root-equivalent): $(getent group docker | cut -d: -f4)" ;;
  *)
    prep_refs
    for p in "$@"; do detail "$(readlink -m "$p")"; done ;;
esac
