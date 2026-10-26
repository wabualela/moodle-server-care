#!/bin/bash
# exim-smarthost-setup.sh — make Debian/Ubuntu exim4 an authenticated, TLS-only smarthost client that keeps
# listening on loopback only and keeps delivering local (cron) mail locally.
#
# Default mode is PLAN (read-only): checks the preconditions and prints every change it would make.
#   --apply             backup -> change -> update-exim4.conf -> exim -bV / -bP checks. If a check fails, the backups
#                       are restored automatically. It does NOT restart exim (that is the next, separately verified
#                       step) and never touches credentials (the owner adds them with owner-add-credentials.sh).
#   --rollback FILE     restore the files listed in the manifest written by --apply (refuses while mail is queued,
#                       because queued remote mail would bounce once exim stops relaying; --force overrides).
#
# Usage: bash exim-smarthost-setup.sh --host smtp.provider.example [--port 465|587] [--helo FQDN]
#                                     [--queue-interval 5m] [--no-net] [--apply | --rollback FILE [--force]]
# Changes made (non-split config; split config uses the conf.d equivalents):
#   update-exim4.conf.conf  dc_eximconfig_configtype='smarthost', dc_smarthost='HOST::PORT'
#   exim4.conf.localmacros  REMOTE_SMTP_SMARTHOST_PROTOCOL = smtps (port 465 only),
#                           REMOTE_SMTP_SMARTHOST_HOSTS_REQUIRE_TLS = *, [REMOTE_SMTP_HELO_DATA = FQDN]
#   exim4.conf.template     transport remote_smtp_smarthost: + hosts_require_auth = *
#   /etc/default/exim4      QUEUEINTERVAL='5m'
# Env overrides: EXIM_DIR EXIM_DEFAULT EXIM_BIN UPDATE_EXIM MSC_STATE_DIR (default /root/msc-mail-YYYY-MM-DD) MSC_NO_SUDO
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init; msc_exim_init

HOST=""; PORT=465; HELO=""; QI="5m"; MODE=plan; MANIFEST=""; FORCE=0; NET=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift ;;
    --port) PORT="${2:-}"; shift ;;
    --helo) HELO="${2:-}"; shift ;;
    --queue-interval) QI="${2:-}"; shift ;;
    --apply) MODE=apply ;;
    --rollback) MODE=rollback; MANIFEST="${2:-}"; shift ;;
    --force) FORCE=1 ;;
    --no-net) NET=0 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

UPDATE_EXIM="${UPDATE_EXIM:-$(msc_which update-exim4.conf)}"
STOPS=0
ok()   { echo "  [ok]   $*"; }
stop() { echo "  [STOP] $*"; STOPS=$((STOPS + 1)); }
info() { echo "  [info] $*"; }
getdc() { sed -nE "s/^$1='([^']*)'.*/\1/p" "$EXIM_CONF" 2>/dev/null | tail -n 1; }

regen_and_check() {   # update-exim4.conf, exim -bV, exim -bP transport; returns non-zero on any failure
  local out tp
  $SUDO "$UPDATE_EXIM" || { echo "update-exim4.conf failed"; return 1; }
  out=$($SUDO "$EXIM_BIN" -bV 2>&1); echo "$out" | tail -n 2 | sed 's/^/  -bV: /'
  echo "$out" | grep -q 'Configuration file is' || { echo "exim -bV did not accept the configuration"; return 1; }
  echo "$out" | grep -qiE 'error|failed' && { echo "exim -bV reported an error"; return 1; }
  [ "${1:-}" = "--no-transport-check" ] && return 0
  tp=$($SUDO "$EXIM_BIN" -bP transport remote_smtp_smarthost 2>&1)
  echo "$tp" | grep -E '^(protocol|hosts_require_tls|hosts_require_auth|hosts_try_auth|helo_data) ' | sed 's/^/  -bP: /'
  echo "$tp" | grep -qE '^hosts_require_auth = \*' || { echo "hosts_require_auth = * missing from the transport"; return 1; }
  echo "$tp" | grep -qE '^hosts_require_tls = \*' || { echo "hosts_require_tls = * missing from the transport"; return 1; }
  if [ "$PORT" = 465 ]; then echo "$tp" | grep -qE '^protocol = smtps' || { echo "protocol = smtps missing"; return 1; }; fi
  return 0
}

restore_manifest() {  # restore_manifest FILE: newest entries first, so the oldest backup (the original) wins
  local m="$1" orig bak keep
  keep="$(dirname "$m")/removed-$(date +%H%M%S)"
  $SUDO tac "$m" | while read -r orig bak; do
    [ -n "$orig" ] || continue
    if [ "$bak" = "ABSENT" ]; then
      if $SUDO test -e "$orig"; then $SUDO install -d -m 700 "$keep"; $SUDO mv -- "$orig" "$keep/"; echo "  moved new file $orig -> $keep/"; fi
    else
      $SUDO cp -a -- "$bak" "$orig" && echo "  restored $orig <- $bak"
    fi
  done
}

# ------------------------------------------------------------------ rollback mode
if [ "$MODE" = rollback ]; then
  [ -n "$MANIFEST" ] && $SUDO test -r "$MANIFEST" || { echo "manifest not readable: $MANIFEST" >&2; exit 2; }
  q=$($SUDO "$EXIM_BIN" -bpc 2>/dev/null || echo "?")
  if [ "$q" != "0" ] && [ "$FORCE" != 1 ]; then
    echo "REFUSED: the queue holds $q message(s). Switch Moodle back first, then 'exim4 -qff', wait for 0, rerun." >&2
    exit 3
  fi
  echo "== restoring from $MANIFEST"
  restore_manifest "$MANIFEST"
  if regen_and_check --no-transport-check; then
    echo "== restored and valid. Next: sudo systemctl restart exim4 && systemctl is-active exim4"
  else
    echo "== restored files, but the regenerated config did not validate: inspect before restarting exim" >&2; exit 1
  fi
  exit 0
fi

# ------------------------------------------------------------------ preconditions (plan and apply)
[ -n "$HOST" ] || { echo "--host is required (the provider's SMTP host name)" >&2; exit 2; }
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "invalid --host" >&2; exit 2; }
case "$PORT" in 465|587) ;; *) echo "--port must be 465 (SMTPS) or 587 (STARTTLS)" >&2; exit 2 ;; esac
[[ "$QI" =~ ^[0-9]+[smh]$ ]] || { echo "invalid --queue-interval" >&2; exit 2; }
[ -z "$HELO" ] || [[ "$HELO" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "--helo must be a fully qualified name" >&2; exit 2; }

echo "== preconditions"
[ -n "$EXIM_BIN" ] && ok "exim binary: $EXIM_BIN" || stop "exim is not installed"
[ -n "$UPDATE_EXIM" ] && ok "Debian generator: $UPDATE_EXIM" || stop "no update-exim4.conf: not the Debian exim4 packaging (references/exim-smarthost.md §2)"
[ -r "$EXIM_CONF" ] && ok "$EXIM_CONF readable" || stop "$EXIM_CONF missing"
[ -e "$EXIM_DIR/exim4.conf" ] && stop "$EXIM_DIR/exim4.conf exists: a hand-written config overrides the generator; ask the owner"
command -v python3 >/dev/null 2>&1 && ok "python3 present (exact, asserted edits)" || stop "python3 missing: edit by hand following references/exim-smarthost.md"
CT=$(getdc dc_eximconfig_configtype); SH=$(getdc dc_smarthost); LI=$(getdc dc_local_interfaces)
TARGET="$HOST::$PORT"
case "$CT" in
  local) ok "configtype 'local' -> 'smarthost' (local delivery stays as it is)" ;;
  smarthost) if [ "$SH" = "$TARGET" ]; then ok "already smarthost $TARGET"; elif [ -z "$SH" ]; then ok "configtype smarthost with no smarthost yet"
             elif [ "$FORCE" = 1 ]; then info "replacing smarthost '$SH' (--force)"; else stop "exim already relays via '$SH'; something may depend on it (ask; --force to replace)"; fi ;;
  *) stop "configtype '$CT' (internet/satellite/none): ask the owner; this script only converts 'local' or 'smarthost'" ;;
esac
LIOK=1
for i in $(echo "$LI" | tr ';' ' '); do case "$i" in 127.0.0.1|::1|::::1) ;; *) LIOK=0 ;; esac; done
[ -z "$LI" ] && LIOK=0
[ "$LIOK" = 1 ] && ok "listens on loopback only: '$LI' (unchanged)" || stop "dc_local_interfaces='$LI' is not loopback-only: restrict it first, as its own change"
[ -r "$EXIM_TPL" ] && ok "transport file: $EXIM_TPL" || stop "transport file missing: $EXIM_TPL"
if [ -r "$EXIM_TPL" ]; then
  grep -q 'REMOTE_SMTP_SMARTHOST_HOSTS_REQUIRE_TLS' "$EXIM_TPL" && ok "template supports HOSTS_REQUIRE_TLS" || stop "template lacks REMOTE_SMTP_SMARTHOST_HOSTS_REQUIRE_TLS (old exim4-config): ask"
  if [ "$PORT" = 465 ]; then
    grep -q 'REMOTE_SMTP_SMARTHOST_PROTOCOL' "$EXIM_TPL" && ok "template supports PROTOCOL (smtps on 465)" || stop "template lacks REMOTE_SMTP_SMARTHOST_PROTOCOL: use --port 587 (STARTTLS)"
  fi
  if grep -qE '^[[:space:]]*hosts_require_auth' "$EXIM_TPL"; then NEED_TPL=0; ok "hosts_require_auth already present"; else NEED_TPL=1; fi
fi
QR=$(sed -nE "s/^QUEUERUNNER='?([^']*)'?.*/\1/p" "$EXIM_DEFAULT" 2>/dev/null | tail -n 1)
QCUR=$(sed -nE "s/^QUEUEINTERVAL='?([^']*)'?.*/\1/p" "$EXIM_DEFAULT" 2>/dev/null | tail -n 1)
case "${QR:-combined}" in combined|separate) ok "QUEUERUNNER='${QR:-combined}'" ;; *) stop "QUEUERUNNER='$QR': no listener or no queue runs; ask" ;; esac
# Local macros wanted, and conflicts with existing definitions.
WANT=()
[ "$PORT" = 465 ] && WANT+=("REMOTE_SMTP_SMARTHOST_PROTOCOL = smtps")
WANT+=("REMOTE_SMTP_SMARTHOST_HOSTS_REQUIRE_TLS = *")
[ -n "$HELO" ] && WANT+=("REMOTE_SMTP_HELO_DATA = $HELO")
ADD=()
for w in "${WANT[@]}"; do
  name=${w%% *}
  cur=$(grep -E "^[[:space:]]*$name[[:space:]]*=" "$EXIM_MACROS" 2>/dev/null | tail -n 1 | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [ -z "$cur" ]; then ADD+=("$w")
  elif [ "$cur" = "$w" ]; then ok "macro already set: $w"
  else stop "$EXIM_MACROS already defines '$cur' (wanted '$w'): ask"; fi
done
if [ "$PORT" = 587 ] && grep -qE '^[[:space:]]*REMOTE_SMTP_SMARTHOST_PROTOCOL' "$EXIM_MACROS" 2>/dev/null; then
  stop "$EXIM_MACROS sets REMOTE_SMTP_SMARTHOST_PROTOCOL but port 587 needs STARTTLS: remove it first"
fi
if [ "$NET" = 1 ]; then
  if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$HOST" "$PORT" 2>/dev/null; then ok "egress to $HOST:$PORT open"; else stop "cannot open TCP $HOST:$PORT from this server (provider firewall/cloud egress block?)"; fi
fi

echo "== planned changes"
echo "  1. $EXIM_CONF: dc_eximconfig_configtype '$CT' -> 'smarthost'; dc_smarthost '$SH' -> '$TARGET'"
if [ ${#ADD[@]} -gt 0 ]; then echo "  2. $EXIM_MACROS: add"; printf '       %s\n' "${ADD[@]}"; else echo "  2. $EXIM_MACROS: nothing to add"; fi
[ "${NEED_TPL:-0}" = 1 ] && echo "  3. $EXIM_TPL: transport remote_smtp_smarthost + 'hosts_require_auth = *' (a failed login defers instead of sending unauthenticated)" || echo "  3. transport: nothing to add"
echo "  4. $EXIM_DEFAULT: QUEUEINTERVAL '${QCUR:-unset}' -> '$QI'"
echo "  then: update-exim4.conf, exim -bV, exim -bP transport remote_smtp_smarthost; restart exim4 is a separate step"

if [ "$STOPS" -gt 0 ]; then echo "== $STOPS blocking item(s): nothing changed"; exit 3; fi
if [ "$CT" = smarthost ] && [ "$SH" = "$TARGET" ] && [ ${#ADD[@]} -eq 0 ] && [ "${NEED_TPL:-0}" = 0 ] && [ "$QCUR" = "$QI" ]; then
  echo "== already configured: nothing to change"; exit 0
fi
if [ "$MODE" = plan ]; then echo "== plan only (read-only). Rerun with --apply after the owner approved it."; exit 0; fi

# ------------------------------------------------------------------ apply
if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ] && [ "${MSC_NO_SUDO:-0}" != 1 ]; then echo "--apply needs root or sudo" >&2; exit 2; fi
STATE="${MSC_STATE_DIR:-/root/msc-mail-$(date +%F)}"
$SUDO install -d -m 700 "$STATE"
MAN="$STATE/exim-backups.txt"
D=$(date +%F)
backup() {
  local f="$1" t s
  if $SUDO test -e "$f"; then
    for s in "" b c d e f g h; do t="$f.bak-$D$s"; $SUDO test -e "$t" || break; done
    $SUDO cp -a -- "$f" "$t" && echo "$f $t" | $SUDO tee -a "$MAN" >/dev/null && echo "  backup $t"
  else
    echo "$f ABSENT" | $SUDO tee -a "$MAN" >/dev/null && echo "  (no $f yet; rollback removes it)"
  fi
}
echo "== backups (manifest $MAN)"
for f in "$EXIM_CONF" "$EXIM_MACROS" "$EXIM_TPL" "$EXIM_DEFAULT" "$EXIM_DIR/passwd.client"; do backup "$f" || { echo "backup failed: $f"; exit 1; }; done

echo "== changes"
fail_restore() { echo "FAILED: $*; restoring backups" >&2; restore_manifest "$MAN"; $SUDO "$UPDATE_EXIM" >/dev/null 2>&1; exit 1; }
$SUDO python3 - "$EXIM_CONF" "$TARGET" <<'PY' || fail_restore "editing update-exim4.conf.conf"
import re, sys
p, target = sys.argv[1], sys.argv[2]
s = open(p).read()
for key, val in (("dc_eximconfig_configtype", "smarthost"), ("dc_smarthost", target)):
    pat = re.compile(r"(?m)^%s=.*$" % key)
    n = len(pat.findall(s))
    assert n == 1, "%s occurs %d times" % (key, n)
    s = pat.sub("%s='%s'" % (key, val), s, count=1)
open(p, "w").write(s)
print("  edited " + p)
PY
if [ ${#ADD[@]} -gt 0 ]; then
  { echo "# moodle-server-care mail module ($D): smarthost $TARGET, TLS mandatory"; printf '%s\n' "${ADD[@]}"; } \
    | $SUDO tee -a "$EXIM_MACROS" >/dev/null || fail_restore "writing $EXIM_MACROS"
  $SUDO chmod 644 "$EXIM_MACROS"; echo "  wrote $EXIM_MACROS"
fi
if [ "${NEED_TPL:-0}" = 1 ]; then
  $SUDO python3 - "$EXIM_TPL" "$D" <<'PY' || fail_restore "editing the transport"
import re, sys
p, day = sys.argv[1], sys.argv[2]
s = open(p).read()
heads = [m.start() for m in re.finditer(r"(?m)^remote_smtp_smarthost:[ \t]*$", s)]
assert len(heads) == 1, "transport header found %d times" % len(heads)
st = heads[0]
m_end = re.compile(r"(?m)^#{5,}").search(s, st)
end = m_end.start() if m_end else len(s)
block = s[st:end]
assert "hosts_try_auth" in block, "hosts_try_auth not found in the transport"
anchors = list(re.finditer(r"(?m)^\.ifdef REMOTE_SMTP_SMARTHOST_HOSTS_AVOID_TLS[ \t]*$", block))
assert len(anchors) == 1, "anchor found %d times in the transport" % len(anchors)
assert block.find("hosts_try_auth") < anchors[0].start(), "anchor is not after hosts_try_auth"
ins = ("  # moodle-server-care mail module (%s): auth must succeed; a failed login defers (retry)\n"
       "  # instead of sending unauthenticated\n  hosts_require_auth = *\n") % day
pos = st + anchors[0].start()
s = s[:pos] + ins + s[pos:]
open(p, "w").write(s)
print("  edited " + p)
PY
fi
$SUDO python3 - "$EXIM_DEFAULT" "$QI" <<'PY' || fail_restore "editing $EXIM_DEFAULT"
import re, sys
p, qi = sys.argv[1], sys.argv[2]
s = open(p).read()
pat = re.compile(r"(?m)^QUEUEINTERVAL=.*$")
n = len(pat.findall(s))
assert n <= 1, "QUEUEINTERVAL occurs %d times" % n
s = pat.sub("QUEUEINTERVAL='%s'" % qi, s, count=1) if n == 1 else s.rstrip("\n") + "\nQUEUEINTERVAL='%s'\n" % qi
open(p, "w").write(s)
print("  edited " + p)
PY

echo "== test"
regen_and_check || fail_restore "validation"
echo "== applied and valid (exim NOT restarted yet)"
echo "next:     sudo systemctl restart exim4 && systemctl is-active exim4 && sudo ss -Hltn 'sport = :25'"
echo "rollback: bash $(basename "$0") --rollback $MAN   (then restart exim4)"
