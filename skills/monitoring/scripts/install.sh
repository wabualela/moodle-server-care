#!/bin/bash
# install.sh — installs the moodle-health monitor in a safe order, one step per call. Every change step first prints
# its plan and changes nothing unless --yes is given. Order matters (see ../references/install.md):
#
#   plan                 read-only: render config and units for THIS server into the staging dir, preview the checks
#   install  [--yes]     copy script/config/units into place, timer stays OFF (existing files backed up first)
#   baseline [--yes]     record the Moodle status checks that already fail as known, then a dry run (sends nothing)
#   url-command          print the no-echo command the OWNER runs to save the healthchecks.io ping URL
#   enable   [--yes]     refuse unless baseline + URL file + clean dry run; then enable the timer, show the first run
#   status               read-only: timer, last result, mute, URL file presence (never its content)
#   uninstall [--yes]    disable the timer, move every file to a root-only archive (owner pauses the check FIRST)
#
# Options: --stage DIR (default ~/.cache/moodle-server-care/monitoring-stage of the invoking user),
#          --replace-config (install: overwrite an existing /etc/default/moodle-health, after a backup),
#          --accept-critical (enable: the owner accepted the CRITICAL lines of the dry run)
# Why baseline before the URL: a Moodle site usually has status checks that already fail (environment, router...);
# without a baseline they would alert at the very first real run.
# Test harness: DESTDIR=/path installs under that root, skips the root check and systemd verification; tools
# (systemctl, curl ...) come from PATH so mocks intercept them. It never runs a non-dry check itself.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
MODULE=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CMD="${1:-plan}"; [ $# -gt 0 ] && shift
YES=0; REPLACE_CONFIG=0; ACCEPT_CRIT=0; STAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --stage) STAGE="${2:?--stage needs a directory}"; shift ;;
    --replace-config) REPLACE_CONFIG=1 ;;
    --accept-critical) ACCEPT_CRIT=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

D="${DESTDIR:-}"
BIN="$D/usr/local/sbin/moodle-health"
CONFF="$D/etc/default/moodle-health"
URLF="$D/etc/default/moodle-health.url"
UNITDIR="$D/etc/systemd/system"
STATEDIR="$D/var/lib/moodle-health"
TODAY=$(date +%F)
INVOKER="${SUDO_USER:-$(id -un)}"
IHOME=$(getent passwd "$INVOKER" 2>/dev/null | cut -d: -f6); IHOME="${IHOME:-$HOME}"
STAGE="${STAGE:-$IHOME/.cache/moodle-server-care/monitoring-stage}"

die() { echo "STOP: $*" >&2; exit 1; }
say() { printf '%-24s %s\n' "$1" "$2"; }
need_root() { [ -n "$D" ] || [ "$(id -u)" -eq 0 ] || die "this step changes the system: run it with sudo"; }
need_installed() { [ -x "$BIN" ] && [ -f "$CONFF" ] && [ -f "$UNITDIR/moodle-health.timer" ] || die "not installed yet: run 'install --yes' first"; }
no_yes() { echo; echo "Nothing changed. After the owner approves this step, run again with --yes."; exit 0; }

# Run the installed script. Under DESTDIR every path points into the fake root (and the URL file there).
mh() {
  if [ -n "$D" ]; then
    MOODLE_HEALTH_CONF="$CONFF" MOODLE_HEALTH_STATE="$STATEDIR" MOODLE_HEALTH_URLFILE="$URLF" "$BIN" "$@"
  else
    "$BIN" "$@"
  fi
}

# Run the module's script against the STAGED config, with a state dir and URL file that do not exist: read-only.
mh_staged() {
  local run=()
  [ "$(id -u)" -ne 0 ] && [ -n "${SUDO:-}" ] && run=($SUDO)
  "${run[@]}" env MOODLE_HEALTH_CONF="$STAGE/moodle-health.default" MOODLE_HEALTH_STATE="$STAGE/no-state" \
    MOODLE_HEALTH_URLFILE="$STAGE/no-such-url-file" "$HERE/moodle-health" "$@"
}

url_file_check() {  # prints problems with the URL file; never prints its content
  local p=""
  if ! [ -e "$URLF" ]; then echo "absent"; return 1; fi
  [ -z "$D" ] && [ "$(stat -c %u "$URLF")" != 0 ] && p="$p owner-not-root"
  [ "$(stat -c %a "$URLF")" = 600 ] || p="$p mode-$(stat -c %a "$URLF")-not-600"
  local sz; sz=$(stat -c %s "$URLF"); { [ "$sz" -ge 20 ] && [ "$sz" -le 400 ]; } || p="$p size-$sz-unusual"
  [ "$(grep -c '^https://' "$URLF" 2>/dev/null)" = 1 ] || p="$p not-one-https-line"
  [ "$(wc -l < "$URLF")" -le 1 ] || p="$p more-than-one-line"
  if [ -n "$p" ]; then echo "present but:$p"; return 1; fi
  echo "present, root 600, one https line (content not shown)"
}

render() {
  mh_load_env; mh_init_sudo
  [ -n "$MH_ENV_LOADED" ] || echo "WARNING: server.env not found; run ../start/scripts/detect-env.sh first (values below may be empty)"
  mkdir -p "$STAGE" && chmod 700 "$STAGE"
  local ws services fpm aerr cronlog cfr dbh redis extra="" excluded="" h code ph="yes"
  ws=$(mh_webserver); services=$(mh_services); mh_access_logs; fpm=$(mh_fpm_logs)
  aerr=""; [ -n "$ws" ] && [ "$ws" != nginx ] && aerr=$(mh_apache_error_log)
  cronlog=$(mh_cron_log); cfr=$(mh_cf_ranges_file); dbh=$(mh_cfg dbhost 2>/dev/null)
  redis=no; { mh_active redis-server || mh_active redis; } && redis=yes
  mta=none; if mh_active exim4 || mh_active exim; then mta=exim; elif mh_active postfix; then mta=postfix; fi
  for h in $(mh_other_vhosts); do
    code=$(mh_probe_code "$h")
    if [ -n "$code" ] && [ "$code" != 000 ] && [ "$code" -lt 500 ] 2>/dev/null; then extra="$extra $h"; else excluded="$excluded $h($code)"; fi
  done
  for p in "$MOODLE" "$DATAROOT" "$cronlog" $MH_ACCESS_LOG; do case "$p" in /home/*) ph="read-only" ;; esac; done

  MH_R_WWWROOT="$WWWROOT" MH_R_SITE="$SITE" MH_R_MOODLE="$MOODLE" MH_R_DATAROOT="$DATAROOT" MH_R_PHP="${PHP:-php}" \
  MH_R_WEBUSER="$WEBUSER" MH_R_SERVICES="$services" MH_R_DBTYPE="${DBTYPE:-mariadb}" MH_R_DBHOST="$dbh" \
  MH_R_REDIS_CHECK="$redis" MH_R_ACCESS_LOG="$MH_ACCESS_LOG" MH_R_FPM_LOGS="$fpm" MH_R_APACHE_ERROR_LOG="$aerr" \
  MH_R_CRON_LOG="$cronlog" MH_R_CF_RANGES_FILE="$cfr" MH_R_EXTRA_SITES="${extra# }" MH_R_MTA="$mta" \
  python3 -I - "$MODULE/assets/moodle-health.default" "$STAGE/moodle-health.default" <<'PY' || die "rendering the config failed"
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
for key in re.findall(r'<([A-Z_]+)>', s):
    v = os.environ.get('MH_R_' + key)
    if v is None:
        sys.exit(f'no value for <{key}>')
    if any(ch in v for ch in '"\n\'`$\\'):
        sys.exit(f'unsafe character in value for <{key}>')
    s = s.replace(f'<{key}>', v)
open(dst, 'w').write(s)
PY
  if [ -n "$MH_ACCESS_LOG_VHOST" ]; then
    sed -i "s|^ACCESS_LOG_VHOST=\"\"|ACCESS_LOG_VHOST=\"$MH_ACCESS_LOG_VHOST\"|" "$STAGE/moodle-health.default"
  fi
  cp "$MODULE/assets/moodle-health.timer" "$STAGE/moodle-health.timer"
  sed "s/^ProtectHome=yes$/ProtectHome=$ph/" "$MODULE/assets/moodle-health.service" > "$STAGE/moodle-health.service"
  chmod 644 "$STAGE"/moodle-health.*
  RENDER_EXCLUDED="${excluded# }"; RENDER_PH="$ph"
}

case "$CMD" in
-h|--help|help) sed -n '2,24p' "$0" ;;

plan)
  render
  echo "== moodle-health install plan (read-only so far) $(date '+%F %T') =="
  say "staging dir" "$STAGE (review and edit moodle-health.default there before 'install')"
  say "python3" "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null || echo "STOP: python3 >= 3.7 is required"
  mh_have curl || echo "STOP: curl is required for the site probe (package install = owner approval)"
  mh_have systemctl || echo "STOP: no systemd; a cron line (* * * * *) with a timeout is the fallback: ask the owner"
  mh_have setpriv || echo "WARNING: setpriv missing: Moodle status checks will be skipped"
  [ "$RENDER_PH" = read-only ] && echo "NOTE: Moodle or its logs live under /home: unit uses ProtectHome=read-only"
  [ -n "$RENDER_EXCLUDED" ] && echo "NOTE: vhosts left out of EXTRA_SITES (dead or 5xx right now; ask the owner):$RENDER_EXCLUDED" | tr -s ' '
  [ "${CLOUDFLARE:-}" = yes ] && ! grep -qE '^CF_RANGES_FILE=/' "$STAGE/moodle-health.default" && \
    echo "WARNING: behind Cloudflare but no real-IP ranges file: the fail2ban-bans-Cloudflare check is off (run the cloudflare module)"
  if [ -e "$URLF" ] || { [ -n "${SUDO:-}" ] && $SUDO test -e "$URLF" 2>/dev/null; }; then
    echo "NOTE: a ping URL file already exists. Keep the timer off until baseline + a clean dry run (enable checks it)."
  fi
  echo; echo "--- rendered $STAGE/moodle-health.default (settings only, no secrets) ---"
  grep -vE '^[[:space:]]*(#|$)' "$STAGE/moodle-health.default"
  if [ -f "$CONFF" ]; then echo; echo "--- diff against the installed $CONFF ---"; diff "$CONFF" "$STAGE/moodle-health.default" && echo "(identical)"; fi
  echo; echo "--- which checks would run (self-check on the staged config) ---"
  mh_staged --self-check 2>&1 | sed '/^ping URL file/d; /^state dir/d'
  echo; echo "--- preview dry run (probes only, sends nothing, writes no state; every problem shows as CRITICAL) ---"
  echo "  (lines 'Moodle status check failing: ...' are expected here: the baseline step records them as known)"
  mh_staged --dry-run 2>&1 | sed 's/^/  /'
  cat <<EOF

Files 'install --yes' would write (backups of existing ones go to /root/moodle-health-$TODAY/, mode 700):
  $BIN                         (mode 755, from $HERE/moodle-health)
  $CONFF                    (mode 644, from the staging dir$( [ -f "$CONFF" ] && echo '; EXISTS: kept unless --replace-config'))
  $UNITDIR/moodle-health.service  (ProtectHome=$RENDER_PH)
  $UNITDIR/moodle-health.timer    (every minute, 2 min after boot; stays DISABLED until 'enable')
Then: baseline --yes  ->  owner: healthchecks.io check + URL (url-command)  ->  enable --yes
Rollback of install: systemctl disable --now moodle-health.timer; remove the four files; daemon-reload.
EOF
  ;;

install)
  need_root
  [ -f "$STAGE/moodle-health.default" ] && [ -f "$STAGE/moodle-health.service" ] || die "no staged files in $STAGE: run 'plan' first"
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$HERE/moodle-health" || die "script does not parse"
  grep -qE '<[A-Z_]+>' "$STAGE/moodle-health.default" && die "staged config still has <PLACEHOLDERS>"
  echo "== install plan =="
  for f in "$BIN" "$CONFF" "$UNITDIR/moodle-health.service" "$UNITDIR/moodle-health.timer"; do
    if [ -e "$f" ]; then say "replace (backup first)" "$f"; else say "new" "$f"; fi
  done
  [ -f "$CONFF" ] && [ "$REPLACE_CONFIG" = 0 ] && say "config" "existing $CONFF is KEPT (use --replace-config to take the staged one)"
  say "timer" "$(mh_unit_enabled moodle-health.timer) (install never enables it)"
  [ "$YES" = 1 ] || no_yes
  BK="$D/root/moodle-health-$TODAY"
  for l in b c d e f g h; do [ -e "$BK" ] || break; BK="$D/root/moodle-health-$TODAY$l"; done   # never overwrite a backup
  for f in "$BIN" "$CONFF" "$UNITDIR/moodle-health.service" "$UNITDIR/moodle-health.timer"; do
    if [ -e "$f" ]; then mkdir -p "$BK" && chmod 700 "$BK" && cp -a "$f" "$BK/" || die "backup of $f failed"; fi
  done
  own=(); [ -z "$D" ] && own=(-o root -g root)
  mkdir -p "$(dirname "$BIN")" "$(dirname "$CONFF")" "$UNITDIR"
  install -m 755 "${own[@]}" "$HERE/moodle-health" "$BIN" || die "copy of the script failed"
  if [ ! -f "$CONFF" ] || [ "$REPLACE_CONFIG" = 1 ]; then
    install -m 644 "${own[@]}" "$STAGE/moodle-health.default" "$CONFF" || die "copy of the config failed"
  fi
  install -m 644 "${own[@]}" "$STAGE/moodle-health.service" "$UNITDIR/moodle-health.service"
  install -m 644 "${own[@]}" "$STAGE/moodle-health.timer" "$UNITDIR/moodle-health.timer"
  if [ -z "$D" ]; then
    systemd-analyze verify "$UNITDIR/moodle-health.service" "$UNITDIR/moodle-health.timer" || echo "WARNING: systemd-analyze reported problems (read them before enabling)"
  fi
  systemctl daemon-reload
  # Upgrade safety: if the timer already runs, the next minute uses the new script. Prove it runs; else roll back.
  if ! out=$(mh --dry-run 2>&1); then
    echo "$out" | tail -n 5
    if [ -f "$BK/moodle-health" ]; then cp -a "$BK/moodle-health" "$BIN"; echo "ROLLED BACK the script to $BK/moodle-health"; fi
    die "the new script failed its dry run"
  fi
  echo "installed. Timer: $(mh_unit_enabled moodle-health.timer)."
  [ -d "$BK" ] && echo "backups: $BK"
  echo "Rollback: systemctl disable --now moodle-health.timer; restore from $BK or remove the four files; systemctl daemon-reload"
  echo "Next: baseline --yes"
  ;;

baseline)
  need_root; need_installed
  echo "== baseline plan: 'moodle-health --baseline' (writes $STATEDIR/moodle-checks.baseline), then --dry-run and --self-check. Nothing is sent. =="
  [ -e "$URLF" ] && echo "NOTE: the ping URL file already exists; baseline, dry run and self-check never send, and the timer stays as it is."
  [ "$YES" = 1 ] || no_yes
  if mh --self-check | grep -qE '^moodle +active'; then
    mh --baseline || die "baseline failed (Moodle status checks could not run: see the message above)"
  else
    echo "Moodle status checks are not active on this server (see the self-check below): no baseline needed."
  fi
  echo; echo "--- dry run ---"
  out=$(mh --dry-run 2>&1); echo "$out"
  n=$(printf '%s\n' "$out" | grep -c '^CRITICAL:' || true)
  echo; echo "--- self-check ---"; mh --self-check
  echo
  if [ "$n" -gt 0 ]; then
    echo "The dry run shows $n CRITICAL line(s). Fix them, tune the config, or get the owner's explicit acceptance before 'enable'."
  else
    echo "Dry run clean. Next: the owner creates the healthchecks.io check and saves the URL ('url-command'), then 'enable --yes'."
  fi
  ;;

url-command)
  cat <<EOF
=== للمالك: حفظ رابط healthchecks.io على الخادم (لا يراه Claude ولا يُكتب في السجل) ===
1. من لوحة healthchecks.io انسخ رابط ping للفحص (يبدأ بـ https://).
2. في جلسة SSH خاصة بك على الخادم، الصق هذا الأمر كما هو واضغط Enter، ثم الصق الرابط عند السؤال واضغط Enter
   (لن يظهر الرابط على الشاشة، ولن يُحفظ في سجل الأوامر):

sudo bash -c 'umask 077; read -rsp "ping URL: " U; echo; case "\$U" in https://*) printf "%s\n" "\$U" > $URLF && chmod 600 $URLF && echo saved;; *) echo "not an https URL: nothing saved";; esac; unset U'

3. أخبر Claude بكلمة «تم». سيتحقق من وجود الملف وصلاحياته فقط (دون قراءة الرابط)، ثم يفعّل المؤقت بعد موافقتك.
EOF
  ;;

enable)
  need_root; need_installed
  echo "== enable: pre-checks =="
  fail=0
  if grep -qE '^MOODLE=/' "$CONFF" && { mh --self-check | grep -qE '^moodle +active' ; }; then
    if [ -f "$STATEDIR/moodle-checks.baseline" ]; then say "baseline" "recorded"; else say "baseline" "MISSING: run 'baseline --yes' first"; fail=1; fi
  else
    say "baseline" "not needed (Moodle status checks not active on this server)"
  fi
  if u=$(url_file_check); then say "ping URL file" "$u"; else say "ping URL file" "$u (owner: url-command)"; fail=1; fi
  out=$(mh --dry-run 2>&1); n=$(printf '%s\n' "$out" | grep -c '^CRITICAL:' || true)
  if [ "$n" -gt 0 ] && [ "$ACCEPT_CRIT" = 0 ]; then
    say "dry run" "$n CRITICAL line(s): fix them or rerun with --accept-critical after the owner accepts them"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1
  else
    say "dry run" "$( [ "$n" -gt 0 ] && echo "$n CRITICAL accepted by the owner" || echo clean)"
  fi
  say "timer now" "$(mh_unit_enabled moodle-health.timer)"
  [ "$fail" = 0 ] || die "pre-checks failed; nothing changed"
  echo "would run: systemctl enable --now moodle-health.timer (first run within a minute; healthchecks.io turns green)"
  [ "$YES" = 1 ] || no_yes
  start=$(date +%s)
  systemctl enable --now moodle-health.timer || die "enable failed"
  if [ -z "$D" ]; then
    echo "waiting for the first run (up to 100 s)..."
    for _ in $(seq 1 20); do
      m=$(stat -c %Y "$STATEDIR/last.json" 2>/dev/null || echo 0)
      [ "$m" -ge "$start" ] && break
      sleep 5
    done
  fi
  mh --status
  systemctl list-timers --no-pager moodle-health.timer 2>/dev/null | head -n 3
  echo "Verify with the owner: the check is green in healthchecks.io and its last ping body says 'all checks OK'."
  echo "Rollback: systemctl disable --now moodle-health.timer (then the owner pauses the check, or it reports 'down')."
  ;;

status)
  say "timer" "$(mh_unit_enabled moodle-health.timer) / $(systemctl is-active moodle-health.timer 2>/dev/null)"
  say "last service result" "$(systemctl show -p Result --value moodle-health.service 2>/dev/null)"
  [ -x "$BIN" ] && mh --status
  systemctl list-timers --no-pager moodle-health.timer 2>/dev/null | head -n 3
  ;;

uninstall)
  need_root
  ARCH="$D/root/moodle-health-removed-$TODAY"
  echo "== uninstall plan =="
  echo "FIRST the owner pauses (or deletes) the check in healthchecks.io and the UptimeRobot monitors that rely on it:"
  echo "otherwise the missing pings raise a 'down' alert within minutes."
  echo "Then: systemctl disable --now moodle-health.timer; move these to $ARCH (mode 700), daemon-reload:"
  for f in "$BIN" "$CONFF" "$URLF" "$UNITDIR/moodle-health.service" "$UNITDIR/moodle-health.timer" "$STATEDIR"; do
    [ -e "$f" ] && echo "  $f"
  done
  [ "$YES" = 1 ] || no_yes
  systemctl disable --now moodle-health.timer 2>/dev/null
  systemctl stop moodle-health.service 2>/dev/null
  mkdir -p "$ARCH" && chmod 700 "$ARCH" || die "cannot create $ARCH"
  for f in "$BIN" "$CONFF" "$URLF" "$UNITDIR/moodle-health.service" "$UNITDIR/moodle-health.timer" "$STATEDIR"; do
    [ -e "$f" ] && mv "$f" "$ARCH/" && echo "moved $f"
  done
  systemctl daemon-reload
  echo "Restore: move the files back from $ARCH, systemctl daemon-reload, systemctl enable --now moodle-health.timer."
  echo "The archive holds the ping URL file (a secret): the owner deletes $ARCH after ~30 days."
  ;;

*) echo "unknown step: $CMD (plan | install | baseline | url-command | enable | status | uninstall)" >&2; exit 2 ;;
esac
