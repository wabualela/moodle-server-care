#!/usr/bin/env bash
set +x  # first statement on purpose: never trace this script, its variables hold the Redis password
#
# set-redis-password.sh: give a Redis server that Moodle uses a password (requirepass), and give Moodle the same
# password for its Redis session handler ($CFG->session_redis_auth in config.php) and for every MUC cache store of
# plugin "redis" (moodledata/muc/config.php). Part of moodle-server-care (skills/maintenance).
#
# Why one script, inside CLI maintenance mode: the moment Redis requires a password, every client without it fails
# (sessions throw, cache calls error). Redis, config.php and the MUC file must change together, within a minute.
#
# Who and where: the OWNER runs it with sudo in his OWN SSH terminal (a generated password is shown once). The
# session may run --check (read-only) and verifies afterwards without ever seeing the password.
#
#   sudo bash set-redis-password.sh --check [--moodle DIR]           read-only preflight (any day)
#   sudo bash set-redis-password.sh [--moodle DIR] [--others-ok]     apply (interactive; needs CLI maintenance mode)
#   sudo bash set-redis-password.sh --rollback DIR [--moodle DIR]    remove the password again (backup folder DIR)
# Options: --php php8.x  --fpm-service NAME  --web-user USER  --redis-conf PATH
#   --others-ok  other (non-PHP) processes are connected to Redis and the operator confirmed they get the password too
#
# Scope: a single local Redis (TCP 127.0.0.1/::1 or a unix socket) without ACL users, sessions and/or MUC stores on
# that one instance, plain config.php. Anything else (cluster, TLS, ACL file, several instances): stop and ask.
#
# Secrets: the password is never printed (except a generated one, once, on the terminal), logged or put on a command
# line or in an environment: redis-cli gets "AUTH"/"CONFIG SET" on stdin, python3 gets the value on stdin.
# Exit codes: 0 done; 1 failed, nothing left changed; 2 done with a warning; 3 manual attention needed; 130 interrupted.

set -u -o pipefail
umask 077
ulimit -c 0 2>/dev/null || true
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" != 0 ] && [ "${RRP_TEST:-0}" = 1 ]; then TEST=1; else
  TEST=0
  for v in $(compgen -v RRP_); do unset "$v"; done
fi

MODE=apply; BK=""; OPT_MOODLE=""; OPT_PHP=""; OPT_FPM=""; OPT_WEB=""; OPT_CONF=""; OTHERS_OK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --rollback) MODE=rollback; BK=${2:-}; shift 2 || shift ;;
    --moodle) OPT_MOODLE=${2:-}; shift 2 || shift ;;
    --php) OPT_PHP=${2:-}; shift 2 || shift ;;
    --fpm-service) OPT_FPM=${2:-}; shift 2 || shift ;;
    --web-user) OPT_WEB=${2:-}; shift 2 || shift ;;
    --redis-conf) OPT_CONF=${2:-}; shift 2 || shift ;;
    --others-ok) OTHERS_OK=1; shift ;;
    -h|--help) MODE=help; shift ;;
    *) MODE=bad; shift ;;
  esac
done

OP_USER=${SUDO_USER:-}; [ "$OP_USER" = root ] && OP_USER=""
OP_HOME=""; [ -n "$OP_USER" ] && OP_HOME=$(getent passwd "$OP_USER" | cut -d: -f6)
ENV_MOODLE=""; ENV_PHP=""; ENV_WEB=""
if [ "$TEST" = 0 ] && [ -n "$OP_HOME" ] && [ -r "$OP_HOME/.config/moodle-server-care/server.env" ]; then
  envval() { sed -nE "s/^$1=(.*)$/\1/p" "$OP_HOME/.config/moodle-server-care/server.env" | head -n 1 | sed -E "s/^'(.*)'$/\1/; s/\\\\(.)/\1/g"; }
  ENV_MOODLE=$(envval MOODLE); ENV_PHP=$(envval PHP); ENV_WEB=$(envval WEBUSER)
fi
MOODLE_DIR=${RRP_MOODLE_DIR:-${OPT_MOODLE:-$ENV_MOODLE}}
CONFIG="$MOODLE_DIR/config.php"
CFG_CLI="$MOODLE_DIR/admin/cli/cfg.php"
MAINT_CLI="$MOODLE_DIR/admin/cli/maintenance.php"
WEB_USER=${RRP_WEB_USER:-${OPT_WEB:-${ENV_WEB:-www-data}}}
PHPNAME=${OPT_PHP:-${ENV_PHP:-php}}
PHP=${RRP_PHP:-$(command -v "$PHPNAME" 2>/dev/null || echo "/usr/bin/$PHPNAME")}
FPM_SERVICE=${RRP_FPM_SERVICE:-${OPT_FPM:-${PHPNAME}-fpm}}
REDIS_CLI=${RRP_REDIS_CLI:-$(command -v redis-cli 2>/dev/null || echo /usr/bin/redis-cli)}
PYTHON=${RRP_PYTHON:-/usr/bin/python3}
SYSTEMCTL=${RRP_SYSTEMCTL:-/usr/bin/systemctl}
RUNUSER=${RRP_RUNUSER:-/usr/sbin/runuser}
OPENSSL=${RRP_OPENSSL:-/usr/bin/openssl}
SS=${RRP_SS:-$(command -v ss 2>/dev/null || echo /usr/bin/ss)}
BACKUP_BASE=${RRP_BACKUP_BASE:-/root}
TMP_BASE=${RRP_TMP_BASE:-/tmp}
LOCK_FILE=${RRP_LOCK_FILE:-/run/set-redis-password.lock}
CHECK_PHP_SRC=${RRP_CHECK_PHP:-$(dirname -- "$(readlink -f -- "$0")")/redis-check.php}
SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")

STATE=none       # none | redis (Redis has the password, files not) | files (all changed, not verified) | done | rollback
DATAROOT=""; MUC=""; REDIS_CONF=""; RHOST=""; RPORT=""; RSOCK=""
SESS_REDIS=0; N_STORES=0
NEWPW=""; TMPD=""; TMP_FILES=()
WARNINGS=0; PROBLEMS=0

read -r -d '' PY <<'PYEOF'
import os, re, sys, tempfile

def die(msg):
    sys.stderr.write('   ' + msg + '\n'); sys.exit(1)

def lines_of(p):
    with open(p, 'rb') as f:
        return f.read().split(b'\n')

def write_beside(target, data, prefix):
    st = os.stat(target)
    fd, tmp = tempfile.mkstemp(prefix=prefix, dir=os.path.dirname(os.path.abspath(target)))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.chown(tmp, st.st_uid, st.st_gid); os.chmod(tmp, st.st_mode & 0o7777)
    except OSError as e:
        try: os.unlink(tmp)
        except OSError: pass
        die('cannot write a temporary file next to %s (%s)' % (target, e.strerror))
    return tmp

PW = re.compile(rb'[A-Za-z0-9]{32,}')
AUTH = re.compile(rb"^[ \t]*\$CFG->session_redis_auth[ \t]*=")
SESSKEY = re.compile(rb"^[ \t]*\$CFG->session_redis_[a-z_]+[ \t]*=")

def cfgval(lines, key):
    rx = re.compile(rb"^[ \t]*\$CFG->" + key + rb"[ \t]*=[ \t]*['\"]?([^'\";]*)['\"]?[ \t]*;")
    v = [m.group(1) for m in map(rx.match, lines) if m]
    return v[-1].decode('utf-8', 'replace') if v else ''

def muc_stores(lines):
    """Find redis store blocks in a var_export()ed MUC config. Returns list of dicts with the line index of the
    'password' entry (or None) and the server value. Only plugin=redis blocks are touched."""
    out = []
    for i, l in enumerate(lines):
        if re.match(rb"^\s*'plugin' => 'redis',\s*$", l):
            # the configuration array follows in the same store block; stop at the store's 'class' line
            pw_i, server = None, ''
            for j in range(i + 1, min(i + 200, len(lines))):
                if re.match(rb"^\s*'class' => ", lines[j]):
                    break
                m = re.match(rb"^\s*'password' => '([^'\\]*)',\s*$", lines[j])
                if m:
                    pw_i = j
                m = re.match(rb"^\s*'server' => '([^'\\]*)',\s*$", lines[j])
                if m:
                    server = m.group(1).decode('utf-8', 'replace')
            out.append({'pw': pw_i, 'server': server})
    return out

cmd = sys.argv[1]
if cmd == 'inspect':           # config.php muc.php -> one tab-separated line (no secret values)
    c = lines_of(sys.argv[2])
    handler = cfgval(c, b'session_handler_class')
    sess = 'redis' in handler.lower()
    auth = sum(1 for l in c if AUTH.match(l))
    idx = [i for i, l in enumerate(c) if SESSKEY.match(l)]
    host = cfgval(c, b'session_redis_host') or ('127.0.0.1' if sess else '')
    port = cfgval(c, b'session_redis_port') or ('6379' if sess else '')
    dataroot = cfgval(c, b'dataroot')
    n = withpw = nonempty = 0; servers = set()
    muc = sys.argv[3] if len(sys.argv) > 3 else ''
    if not muc and dataroot:
        muc = os.path.join(dataroot, 'muc', 'config.php')
    if muc and os.path.exists(muc):
        m = lines_of(muc)
        for s in muc_stores(m):
            n += 1; servers.add(s['server'])
            if s['pw'] is not None:
                withpw += 1
                if re.match(rb"^\s*'password' => '',\s*$", m[s['pw']]) is None:
                    nonempty += 1
    print('\t'.join(str(x) for x in (1 if sess else 0, auth, (idx[-1] + 1) if idx else 0, host, port, dataroot,
                                     n, withpw, nonempty, ','.join(sorted(servers)) or '-')))
elif cmd == 'config-add':      # config.php ; stdin = password -> temp file with the session_redis_auth line added
    p = sys.argv[2]; pw = sys.stdin.buffer.read()
    if not PW.fullmatch(pw): die('password fails the [A-Za-z0-9]{32,} check')
    c = lines_of(p)
    if any(AUTH.match(l) for l in c): die('config.php already has a session_redis_auth line')
    idx = [i for i, l in enumerate(c) if SESSKEY.match(l)]
    if not idx: die('no $CFG->session_redis_* line to anchor the new line')
    cr = b'\r' if c[idx[-1]].endswith(b'\r') else b''
    c.insert(idx[-1] + 1, b"$CFG->session_redis_auth = '" + pw + b"';" + cr)
    print(write_beside(p, b'\n'.join(c), '.config.php.redis-'))
elif cmd == 'config-remove':   # config.php -> temp file without the session_redis_auth line(s)
    p = sys.argv[2]; c = lines_of(p)
    n = sum(1 for l in c if AUTH.match(l))
    if n != 1: die('expected exactly 1 session_redis_auth line, found %d' % n)
    print(write_beside(p, b'\n'.join(l for l in c if not AUTH.match(l)), '.config.php.redis-'))
elif cmd in ('muc-set', 'muc-clear'):   # muc config ; stdin = password (set) -> temp file
    p = sys.argv[2]; m = lines_of(p)
    pw = sys.stdin.buffer.read() if cmd == 'muc-set' else b''
    if cmd == 'muc-set' and not PW.fullmatch(pw): die('password fails the [A-Za-z0-9]{32,} check')
    stores = muc_stores(m)
    if any(s['pw'] is None for s in stores): die('a redis store has no plain \'password\' entry; edit it in the Moodle UI')
    for s in stores:
        l = m[s['pw']]
        mm = re.match(rb"^(\s*'password' => ')([^'\\]*)(',\s*)$", l)
        if cmd == 'muc-set' and mm.group(2) != b'': die('a redis store already has a password')
        m[s['pw']] = mm.group(1) + pw + mm.group(3)
    print(write_beside(p, b'\n'.join(m), '.muc-config.php.redis-'))
elif cmd == 'conf-add':        # redis.conf ; stdin = password -> temp file with a marked requirepass line appended
    p = sys.argv[2]; pw = sys.stdin.buffer.read()
    if not PW.fullmatch(pw): die('password fails the [A-Za-z0-9]{32,} check')
    c = lines_of(p)
    if any(re.match(rb'^\s*requirepass\s', l) for l in c): die('redis.conf already has an active requirepass line')
    while c and c[-1] == b'': c.pop()
    c += [b'# moodle-server-care: password for Moodle sessions and MUC stores (set-redis-password.sh)',
          b'requirepass ' + pw, b'']
    print(write_beside(p, b'\n'.join(c), '.redis.conf.msc-'))
elif cmd == 'conf-remove':     # redis.conf -> temp file without the marked block
    p = sys.argv[2]; c = lines_of(p)
    out = []; skip = False; removed = 0
    for l in c:
        if l.startswith(b'# moodle-server-care: password for Moodle'):
            skip = True; continue
        if skip and re.match(rb'^\s*requirepass\s', l):
            skip = False; removed += 1; continue
        skip = False; out.append(l)
    if removed != 1: die('expected exactly 1 requirepass line written by this script, found %d' % removed)
    print(write_beside(p, b'\n'.join(out), '.redis.conf.msc-'))
elif cmd == 'conf-count':      # active requirepass lines / aclfile lines (no values)
    c = lines_of(sys.argv[2])
    print('%d\t%d' % (sum(1 for l in c if re.match(rb'^\s*requirepass\s', l)),
                      sum(1 for l in c if re.match(rb'^\s*aclfile\s', l))))
elif cmd == 'read-pw':         # config.php muc conf -> the password currently configured (for rollback), stdout only
    vals = set()
    c = lines_of(sys.argv[2])
    for l in c:
        mm = re.match(rb"^[ \t]*\$CFG->session_redis_auth[ \t]*=[ \t]*'([A-Za-z0-9]+)';", l)
        if mm: vals.add(mm.group(1))
    if os.path.exists(sys.argv[3]):
        m = lines_of(sys.argv[3])
        for s in muc_stores(m):
            if s['pw'] is not None:
                mm = re.match(rb"^\s*'password' => '([A-Za-z0-9]+)',", m[s['pw']])
                if mm: vals.add(mm.group(1))
    for l in lines_of(sys.argv[4]):
        mm = re.match(rb'^\s*requirepass\s+([A-Za-z0-9]+)\s*$', l)
        if mm: vals.add(mm.group(1))
    if len(vals) != 1: die('found %d different passwords in config.php / MUC / redis.conf; expected 1' % len(vals))
    sys.stdout.write(vals.pop().decode())
else:
    die('internal: unknown command')
PYEOF
py() { (cd / && "$PYTHON" -I -c "$PY" "$@"); }

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
info() { printf '   info  %s\n' "$*"; }
warn() { printf '   WARN  %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }

usage() {
  cat <<EOF
Usage (as root, in your own SSH terminal, never through a Claude session):
  sudo bash $SELF --check [--moodle DIR]           read-only preflight
  sudo bash $SELF [--moodle DIR] [--others-ok]     set the password (needs CLI maintenance mode)
  sudo bash $SELF --rollback DIR [--moodle DIR]    remove it again (DIR = backup folder printed by the run)
Options: --php php8.x  --fpm-service NAME  --web-user USER  --redis-conf PATH
EOF
}
ask() { local __v; if ! read -r -p "$2" __v; then printf '\n' >&2; fail "no input (stdin closed)"; fi; printf -v "$1" '%s' "${__v%$'\r'}"; }
ask_word() { local __w="" __n=0; while :; do ask __w "$2"; [ -n "$__w" ] && break; __n=$((__n + 1)); [ "$__n" -lt 5 ] || break; done; printf -v "$1" '%s' "$__w"; }
ask_secret() {
  local __v __n=0
  while :; do
    if ! read -r -s -p "$2" __v; then printf '\n' >&2; fail "no input (stdin closed)"; fi
    printf '\n' >&2; __v=${__v%$'\r'}
    [ -n "$__v" ] && break
    __n=$((__n + 1)); [ "$__n" -lt 5 ] || fail "only empty input"
  done
  printf -v "$1" '%s' "$__v"
}

# rcli: redis-cli with commands on stdin (so neither the password nor AUTH ever appear in argv)
rcli() {
  if [ -n "$RSOCK" ]; then "$REDIS_CLI" -s "$RSOCK"; else "$REDIS_CLI" -h "$RHOST" -p "$RPORT"; fi
}
redis_ping_noauth() { printf 'PING\n' | rcli 2>&1 | head -n 1; }
redis_auth_ping() { printf 'AUTH %s\nPING\n' "$1" | rcli 2>&1 | tr '\n' ' ' | sed 's/ $//'; }
redis_set_pass() {   # redis_set_pass CURRENT NEW  (CURRENT empty = no auth yet; NEW empty = remove the password)
  local out
  if [ -n "$1" ]; then out=$(printf 'AUTH %s\nCONFIG SET requirepass "%s"\n' "$1" "$2" | rcli 2>&1)
  else out=$(printf 'CONFIG SET requirepass "%s"\n' "$2" | rcli 2>&1); fi
  out=$(printf '%s\n' "$out" | tr '\n' ' ')
  [ "$out" = "OK " ] || [ "$out" = "OK OK " ]
}

redis_remove_pass() {   # redis_remove_pass PW: no-op when Redis already answers without a password
  [ "$(redis_ping_noauth)" = PONG ] && return 0
  redis_set_pass "$1" "" && [ "$(redis_ping_noauth)" = PONG ]
}
php_lint() { "$PHP" -l "$1" >/dev/null 2>&1; }
cli_version() {
  local out last
  out=$(cd / && "$RUNUSER" -u "$WEB_USER" -- "$PHP" "$CFG_CLI" --name=version 2>/dev/null) || return 1
  last=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)
  [[ $last =~ ^[0-9]{10}(\.[0-9]+)?$ ]]
}
# redis_check: Moodle's own settings tested with phpredis as the web user (read-only, prints no secret)
redis_check() {
  local d f out rc
  d=$(mktemp -d "$TMP_BASE/msc-redischeck.XXXXXX") || return 2
  chmod 755 "$d"; f="$d/redis-check.php"
  cp -- "$CHECK_PHP_SRC" "$f" && chmod 644 "$f" || { rm -rf -- "$d"; return 2; }
  out=$(cd / && "$RUNUSER" -u "$WEB_USER" -- "$PHP" "$f" "$CONFIG" 2>&1); rc=$?
  rm -rf -- "$d"
  printf '%s\n' "$out" | sed 's/^/         /'
  return "$rc"
}
fpm_reload() { "$SYSTEMCTL" reload "$FPM_SERVICE" && "$SYSTEMCTL" is-active --quiet "$FPM_SERVICE"; }
maint_on() { [ -n "$DATAROOT" ] && [ -f "$DATAROOT/climaintenance.html" ]; }

install_tmp() {   # install_tmp TMP TARGET: php -l for PHP files, then atomic rename
  case "$2" in *.php) php_lint "$1" || return 1 ;; esac
  mv -f -- "$1" "$2"
}

cleanup() {
  local f
  for f in "${TMP_FILES[@]}"; do [ -n "$f" ] && rm -f -- "$f"; done
  [ -n "$TMPD" ] && rm -rf -- "$TMPD"
  NEWPW=""
}

recipe() {
  cat <<EOF

Manual recipe (keep Moodle in CLI maintenance mode):
  Scripted:  sudo bash $SELF --rollback ${BK:-/root/redis-auth-<time>} --moodle $MOODLE_DIR
  By hand:   1. read -rs P   (the password; nothing shown)
                printf 'AUTH %s\nCONFIG SET requirepass ""\n' "\$P" | redis-cli $( [ -n "$RSOCK" ] && echo "-s $RSOCK" || echo "-h $RHOST -p $RPORT" ); unset P
             2. delete the \$CFG->session_redis_auth line in $CONFIG (only that line), php -l
             3. set 'password' => '' for the redis stores in $MUC (only those), php -l
             4. remove the marked requirepass block at the end of $REDIS_CONF
             5. sudo systemctl reload $FPM_SERVICE ; redis-cli PING -> PONG
EOF
}

fail() {
  trap '' INT TERM HUP
  printf '\nERROR: %s\n' "$1" >&2
  case $STATE in
    none) printf 'Nothing was changed.\n' >&2; exit 1 ;;
    redis)
      printf 'Redis already requires the new password, the files do NOT have it: removing it from Redis...\n' >&2
      if redis_remove_pass "$NEWPW"; then printf 'Redis answers without a password. Nothing is changed.\n' >&2; exit 1; fi
      printf 'AUTOMATIC REVERT FAILED.\n' >&2; recipe >&2; exit 3 ;;
    files)
      printf 'Redis and the Moodle files hold the new password, but a check failed.\n' >&2
      local a=""
      read -r -p "Roll back now (remove the password from Redis, config.php, MUC and redis.conf)? [Y/n] " a || a=y
      if [[ ! ${a:-y} =~ ^[Nn] ]]; then
        if undo_all "$NEWPW"; then printf 'Rolled back. Nothing is left changed.\n' >&2; exit 1; fi
        printf 'ROLLBACK DID NOT COMPLETE.\n' >&2
      fi
      recipe >&2; exit 3 ;;
    rollback) printf 'The rollback stopped half-way.\n' >&2; recipe >&2; exit 3 ;;
    *) printf 'The change itself completed; only a follow-up step failed.\n' >&2; exit 2 ;;
  esac
}
on_signal() {
  trap '' INT TERM HUP
  printf '\nInterrupted.\n' >&2
  case $STATE in
    redis) if redis_remove_pass "$NEWPW"; then printf 'Password removed from Redis again; files untouched.\n' >&2; exit 130; fi
           recipe >&2; exit 3 ;;
    files) printf 'Redis and the files hold the new password (consistent) but the checks did not finish.\n' >&2; recipe >&2; exit 130 ;;
    rollback) recipe >&2; exit 3 ;;
    *) printf 'Nothing was changed.\n' >&2; exit 130 ;;
  esac
}

# undo_all CURRENT_PASSWORD: surgical removal (only the lines this script added or changed)
undo_all() {
  local rc=0 t
  STATE=rollback
  if [ "$(redis_ping_noauth)" = PONG ]; then ok "Redis already answers without a password"
  elif redis_set_pass "$1" ""; then ok "password removed from Redis (live)"; else warn "could not remove the password from Redis"; rc=1; fi
  if grep -q 'session_redis_auth' "$CONFIG"; then
    if t=$(py config-remove "$CONFIG") && TMP_FILES+=("$t") && install_tmp "$t" "$CONFIG"; then ok "config.php: session_redis_auth line removed"
    else warn "config.php edit failed"; rc=1; fi
  fi
  if [ -f "$MUC" ] && [ "$N_STORES" -gt 0 ]; then
    if t=$(py muc-clear "$MUC" </dev/null) && TMP_FILES+=("$t") && install_tmp "$t" "$MUC"; then ok "MUC: redis store passwords cleared"
    else warn "MUC edit failed"; rc=1; fi
  fi
  if grep -q '^# moodle-server-care: password for Moodle' "$REDIS_CONF" 2>/dev/null; then
    if t=$(py conf-remove "$REDIS_CONF") && TMP_FILES+=("$t") && install_tmp "$t" "$REDIS_CONF"; then ok "redis.conf: requirepass block removed"
    else warn "redis.conf edit failed"; rc=1; fi
  fi
  if fpm_reload; then ok "$FPM_SERVICE reloaded"; else warn "$FPM_SERVICE reload failed"; rc=1; fi
  if redis_check >/dev/null; then ok "Moodle's Redis settings answer PONG"; else warn "redis-check still fails"; rc=1; fi
  return "$rc"
}

problem() { if [ "$MODE" = check ]; then printf '   FAIL  %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); else fail "$1"; fi; }

preflight() {
  local t info auth anchor host port ninfo withpw nonempty servers ver cfgfile acl counts others
  step "Preflight (read-only)"
  [ -n "$MOODLE_DIR" ] || { problem "Moodle directory unknown: pass --moodle DIR"; return; }
  for t in "$REDIS_CLI" "$PYTHON" "$PHP" "$SYSTEMCTL" "$RUNUSER" "$OPENSSL"; do [ -x "$t" ] || { problem "missing tool: $t"; return; }; done
  [ -f "$CHECK_PHP_SRC" ] || { problem "redis-check.php not found next to this script"; return; }
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || { problem "$CONFIG is not a regular file"; return; }
  info=$(py inspect "$CONFIG") || { problem "cannot inspect config.php"; return; }
  IFS=$'\t' read -r SESS_REDIS auth anchor host port DATAROOT N_STORES withpw nonempty servers <<< "$info"
  [ -n "$DATAROOT" ] || { problem "config.php has no plain \$CFG->dataroot line"; return; }
  MUC="$DATAROOT/muc/config.php"
  ok "config.php: sessions in Redis: $([ "$SESS_REDIS" = 1 ] && echo "yes ($host:$port)" || echo no); session_redis_auth lines: $auth"
  ok "MUC: $N_STORES redis store(s), $withpw with a 'password' entry, $nonempty non-empty; servers: $servers"
  if [ "$SESS_REDIS" = 0 ] && [ "$N_STORES" = 0 ]; then problem "Moodle uses Redis neither for sessions nor for MUC: nothing to do here"; return; fi
  if [ "$MODE" != rollback ]; then
    [ "$auth" = 0 ] || { problem "config.php already has a session_redis_auth line (password already set?)"; return; }
    [ "$nonempty" = 0 ] || { problem "a MUC redis store already has a password"; return; }
    [ "$withpw" = "$N_STORES" ] || { problem "a MUC redis store has no plain 'password' entry (edit it in the Moodle UI instead)"; return; }
    [ "$SESS_REDIS" = 0 ] || [ "$anchor" -gt 0 ] || { problem "no \$CFG->session_redis_* line to anchor the new line"; return; }
  fi
  # one Redis instance for everything
  local target=""
  [ "$SESS_REDIS" = 1 ] && target="$host:$port"
  if [ "$servers" != - ]; then
    case "$servers" in *,*) problem "MUC redis stores point to several servers ($servers): stop and ask"; return ;; esac
    [ -z "$target" ] || [ "$servers" = "$target" ] || [ "$servers" = "${target%:6379}" ] || { problem "sessions ($target) and MUC ($servers) use different Redis servers: stop and ask"; return; }
    target=${target:-$servers}
  fi
  case "$target" in
    /*) RSOCK=$target ;;
    tls://*|ssl://*) problem "TLS Redis: not handled by this script"; return ;;
    *) RHOST=${target%:*}; RPORT=${target##*:}; [ "$RPORT" != "$RHOST" ] || RPORT=6379 ;;
  esac
  [ -n "$RSOCK" ] || case "$RHOST" in 127.0.0.1|localhost|::1) ;; *) problem "Redis host $RHOST is not local: stop and ask"; return ;; esac
  ok "one local Redis: ${RSOCK:-$RHOST:$RPORT}"

  if [ "$MODE" = rollback ]; then return; fi
  t=$(redis_ping_noauth)
  case "$t" in
    PONG) ok "Redis answers without a password (no requirepass yet)" ;;
    NOAUTH*|*"Authentication required"*) problem "Redis already requires a password: this script does not rotate an existing one"; return ;;
    *) problem "Redis does not answer: $t"; return ;;
  esac
  ver=$(printf 'INFO server\n' | rcli 2>/dev/null | sed -nE 's/^redis_version:([0-9.]+).*/\1/p' | head -n 1)
  cfgfile=$(printf 'INFO server\n' | rcli 2>/dev/null | sed -nE 's/^config_file:(.*)\r?$/\1/p' | tr -d '\r' | head -n 1)
  REDIS_CONF=${RRP_REDIS_CONF:-${OPT_CONF:-${cfgfile:-/etc/redis/redis.conf}}}
  ok "Redis $ver, config file $REDIS_CONF"
  [ -f "$REDIS_CONF" ] || { problem "$REDIS_CONF not found (pass --redis-conf PATH)"; return; }
  counts=$(py conf-count "$REDIS_CONF") || { problem "cannot read $REDIS_CONF"; return; }
  [ "${counts%%$'\t'*}" = 0 ] || { problem "redis.conf has an active requirepass line although Redis has no password: inconsistent, stop"; return; }
  [ "${counts##*$'\t'}" = 0 ] || { problem "redis.conf uses an ACL file: stop and ask (ACL users need their own procedure)"; return; }
  if [ "${ver%%.*}" -ge 6 ] 2>/dev/null; then
    acl=$(printf 'ACL LIST\n' | rcli 2>/dev/null | grep -c '^user ' || true)
    [ "${acl:-0}" -le 1 ] || { problem "Redis has $acl ACL users: stop and ask"; return; }
  fi
  # other programs connected to Redis (names only)
  if [ -x "$SS" ] && [ -z "$RSOCK" ]; then
    others=$("$SS" -Htnp state established "( dport = :$RPORT )" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | sed 's/users:(("//; s/"$//' | sort -u | grep -vE '^php' | tr '\n' ' ')
  elif [ -x "$SS" ]; then
    others=$("$SS" -Hxp 2>/dev/null | grep -F "$RSOCK" | grep -oE 'users:\(\("[^"]+"' | sed 's/users:(("//; s/"$//' | sort -u | grep -vE '^(php|redis)' | tr '\n' ' ')
  fi
  if [ -n "${others// /}" ]; then
    if [ "$OTHERS_OK" = 1 ]; then warn "other programs use Redis ($others); confirmed with --others-ok: give them the password too"
    else problem "other programs are connected to Redis: $others. They would break. Give them the password in the same window, then rerun with --others-ok"; return; fi
  else
    ok "no non-PHP program connected to Redis right now (other PHP apps on this server: check their .env REDIS_* keys)"
  fi
  if maint_on; then ok "Moodle CLI maintenance mode is ON"
  elif [ "$MODE" = check ]; then info "Moodle CLI maintenance mode is OFF (fine for --check; the change itself requires it ON)"
  else problem "Moodle is not in CLI maintenance mode. First: sudo -u $WEB_USER $PHP $MAINT_CLI --enable"; return; fi
  if cli_version; then ok "Moodle CLI works (cfg.php)"; else problem "Moodle CLI fails BEFORE any change"; return; fi
  if redis_check >/dev/null; then ok "Moodle's Redis settings answer PONG (sessions and stores, no password yet)"
  else problem "redis-check fails BEFORE any change (see: sudo -u $WEB_USER $PHP redis-check.php $CONFIG)"; return; fi
  "$SYSTEMCTL" is-active --quiet "$FPM_SERVICE" && ok "$FPM_SERVICE active" || problem "$FPM_SERVICE not active (pass --fpm-service NAME)"
  [ -d "$BACKUP_BASE" ] && [ -w "$BACKUP_BASE" ] || problem "backup folder $BACKUP_BASE not writable"
}

choose_password() {
  local gen="" a="" b="" ans="" tries
  if [ "$TEST" = 1 ] || ! { exec 7>/dev/tty; } 2>/dev/null; then exec 7>&2; fi
  step "New Redis password"
  ask ans "Generate a random password (openssl rand -hex 24, 48 characters)? [Y/n] "
  if [[ ! ${ans:-y} =~ ^[Nn] ]]; then
    gen=$("$OPENSSL" rand -hex 24) || fail "openssl rand failed"
    [[ $gen =~ ^[0-9a-f]{48}$ ]] || fail "openssl returned an unexpected value"
    { printf '\n   New Redis password (shown ONCE):\n\n        %s\n\n   Save it now in the password manager (entry "<site> Redis").\n' "$gen"; } >&7
    ask ans "Press Enter once it is saved in the password manager... "
    ask ans "Clear the screen and scrollback now? [Y/n] "
    [[ ${ans:-y} =~ ^[Nn] ]] || printf '\033[H\033[2J\033[3J' >&7
    say "Now paste it back FROM THE PASSWORD MANAGER (this proves the saved entry is right)."
  else
    say "Type or paste the new password: letters and digits only, at least 32 characters."
  fi
  exec 7>&-
  for tries in 1 2 3; do
    ask_secret a "Redis password (hidden): "
    ask_secret b "Same again (hidden):     "
    if [ "$a" != "$b" ]; then say "   The two entries differ. ($tries/3)"
    elif [[ ! $a =~ ^[A-Za-z0-9]{32,}$ ]]; then say "   Rejected: only A-Z a-z 0-9, at least 32 characters. ($tries/3)"
    elif [ -n "$gen" ] && [ "$a" != "$gen" ]; then say "   This is not the generated password: check the password manager entry. ($tries/3)"
    else NEWPW=$a; a=""; b=""; gen=""; ok "password accepted (${#NEWPW} characters)"; return 0; fi
  done
  fail "no valid password after 3 attempts"
}

make_backup() {
  step "Backup"
  BK="$BACKUP_BASE/redis-auth-$(date +%Y%m%dT%H%M%S)"
  mkdir -m 700 -- "$BK" || fail "cannot create $BK"
  cp -p -- "$CONFIG" "$BK/config.php.orig" && cp -p -- "$REDIS_CONF" "$BK/redis.conf.orig" || fail "backup copy failed"
  [ ! -f "$MUC" ] || cp -p -- "$MUC" "$BK/muc-config.php.orig" || fail "backup copy of the MUC config failed"
  printf 'moodle=%s\nredis_conf=%s\nmuc=%s\ntarget=%s\n' "$MOODLE_DIR" "$REDIS_CONF" "$MUC" "${RSOCK:-$RHOST:$RPORT}" > "$BK/paths"
  printf 'Backup made by set-redis-password.sh on %s (no password inside: the originals had none).\nRollback: sudo bash %s --rollback %s --moodle %s\n' \
    "$(date '+%F %T %z')" "$SELF" "$BK" "$MOODLE_DIR" > "$BK/NOTE.txt"
  chmod 600 -- "$BK"/*
  ok "originals saved in $BK (root only)"
}

do_check() {
  preflight
  step "Result"
  if [ "$PROBLEMS" -eq 0 ]; then say "Ready: yes (nothing was changed). On the night, maintenance mode must be ON."; exit 0; fi
  say "Ready: NO, $PROBLEMS problem(s) above (nothing was changed)."; exit 1
}

do_apply() {
  local ans t_cfg="" t_muc="" t_conf="" res
  preflight
  choose_password
  step "Plan"
  say "   1. save config.php, the MUC config and redis.conf to $BACKUP_BASE/redis-auth-<time>/"
  say "   2. prepare the three new files (php -l), then set the password in Redis live (CONFIG SET, no restart)"
  say "   3. put the files in place, reload $FPM_SERVICE, check: Redis refuses PING without the password, Moodle's"
  say "      sessions and stores answer PONG with it, Moodle CLI works"
  say "   A failure before step 3 removes the password from Redis again; nothing else changes."
  ask_word ans "Type REDIS to start: "
  [ "$ans" = REDIS ] || fail "not confirmed"
  maint_on || fail "CLI maintenance mode was switched off meanwhile; nothing changed"
  make_backup

  step "Prepare files"
  if [ "$SESS_REDIS" = 1 ]; then
    t_cfg=$(printf '%s' "$NEWPW" | py config-add "$CONFIG") || fail "could not prepare config.php"; TMP_FILES+=("$t_cfg")
    php_lint "$t_cfg" || fail "php -l rejected the new config.php"
  fi
  if [ "$N_STORES" -gt 0 ]; then
    t_muc=$(printf '%s' "$NEWPW" | py muc-set "$MUC") || fail "could not prepare the MUC config"; TMP_FILES+=("$t_muc")
    php_lint "$t_muc" || fail "php -l rejected the new MUC config"
  fi
  t_conf=$(printf '%s' "$NEWPW" | py conf-add "$REDIS_CONF") || fail "could not prepare redis.conf"; TMP_FILES+=("$t_conf")
  ok "new files prepared and linted"

  step "Redis"
  STATE=redis
  redis_set_pass "" "$NEWPW" || fail "CONFIG SET requirepass failed"
  [[ $(redis_ping_noauth) == NOAUTH* ]] || fail "Redis still answers without a password"
  [ "$(redis_auth_ping "$NEWPW")" = "OK PONG" ] || fail "AUTH with the new password did not work"
  ok "Redis now requires the password (live; data and connections kept)"

  step "Files"
  trap '' INT TERM HUP
  res=0
  { [ -z "$t_cfg" ] || mv -f -- "$t_cfg" "$CONFIG"; } && { [ -z "$t_muc" ] || mv -f -- "$t_muc" "$MUC"; } && mv -f -- "$t_conf" "$REDIS_CONF" || res=1
  STATE=files
  trap on_signal INT TERM HUP
  [ "$res" = 0 ] || fail "could not move a new file into place"
  TMP_FILES=()
  [ "$SESS_REDIS" = 0 ] || php_lint "$CONFIG" || fail "php -l rejected config.php"
  [ "$N_STORES" = 0 ] || php_lint "$MUC" || fail "php -l rejected the MUC config"
  ok "config.php, MUC config and redis.conf updated (owners and modes kept)"

  step "Checks"
  fpm_reload || fail "$FPM_SERVICE reload failed"
  ok "$FPM_SERVICE reloaded (OPcache sees the new config.php at once)"
  redis_check || fail "Moodle's Redis settings do not answer PONG with the new password"
  ok "Moodle's sessions and MUC stores answer PONG with the password"
  cli_version || fail "Moodle CLI fails after the change"
  ok "Moodle CLI works"
  STATE=done
  NEWPW=""
  step "REDIS PASSWORD SET$([ "$WARNINGS" -gt 0 ] && printf ' (with %d warning(s))' "$WARNINGS")"
  say "   Redis       ${RSOCK:-$RHOST:$RPORT} requires the password (live + $REDIS_CONF for restarts)"
  say "   Moodle      sessions: $([ "$SESS_REDIS" = 1 ] && echo 'session_redis_auth added' || echo 'not in Redis'); MUC stores: $N_STORES updated"
  say "   Backup      $BK (originals, no password inside)"
  say "   Next: keep maintenance on and continue the night's script. Tools that call redis-cli without a password"
  say "   (monitors, collectors) now get NOAUTH. Log entry: no secrets, backup folder name only."
  recipe
  [ "$WARNINGS" -gt 0 ] && exit 2
  exit 0
}

do_rollback() {
  local ans cur
  [ -d "$BK" ] && [ -f "$BK/config.php.orig" ] && [ -f "$BK/redis.conf.orig" ] || fail "$BK is not a backup folder made by this script"
  [ -n "$MOODLE_DIR" ] || MOODLE_DIR=$(sed -nE 's/^moodle=(.*)$/\1/p' "$BK/paths"); CONFIG="$MOODLE_DIR/config.php"; CFG_CLI="$MOODLE_DIR/admin/cli/cfg.php"
  preflight
  REDIS_CONF=${OPT_CONF:-$(sed -nE 's/^redis_conf=(.*)$/\1/p' "$BK/paths")}
  [ -f "$REDIS_CONF" ] || fail "$REDIS_CONF not found"
  cur=$(py read-pw "$CONFIG" "$MUC" "$REDIS_CONF") || fail "cannot determine the current password from the files"
  step "Rollback"
  say "   This removes the Redis password (live), the session_redis_auth line, the MUC store passwords and the"
  say "   marked requirepass block. Other lines are not touched."
  ask_word ans "Type ROLLBACK to start: "
  [ "$ans" = ROLLBACK ] || fail "not confirmed"
  maint_on || warn "Moodle is NOT in CLI maintenance mode"
  if undo_all "$cur"; then cur=""; STATE=done; step "ROLLBACK COMPLETE"; say "   Redis answers without a password again."; exit 0; fi
  cur=""; recipe; exit 3
}

case "$MODE" in
  help) usage; exit 0 ;;
  bad) usage >&2; exit 1 ;;
  rollback) [ -n "$BK" ] || { usage >&2; exit 1; }; BK=$(readlink -f -- "$BK") ;;
esac
trap cleanup EXIT
trap on_signal INT TERM HUP
if [ "$TEST" != 1 ]; then
  [ "$(id -u)" -eq 0 ] || { printf 'Run it with sudo (as root).\n' >&2; exit 1; }
  if [ "$MODE" != check ] && [ ! -t 0 ]; then printf 'Run it in an interactive terminal.\n' >&2; exit 1; fi
fi
exec 9>"$LOCK_FILE" || { printf 'Cannot open lock file %s.\n' "$LOCK_FILE" >&2; exit 1; }
flock -n 9 || { printf 'Another run of this script is active.\n' >&2; exit 1; }
say "set-redis-password.sh  mode=$MODE  $(date '+%F %T %z')  host=$(hostname)  moodle=${MOODLE_DIR:-?}"
case $MODE in
  check) do_check ;;
  apply) do_apply ;;
  rollback) do_rollback ;;
esac
