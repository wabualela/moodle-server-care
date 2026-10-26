#!/usr/bin/env bash
set +x  # first statement on purpose: never trace this script, its variables hold the database password
#
# rotate-db-password.sh: rotate the password of the live Moodle MariaDB user and update Moodle's config.php.
# Part of moodle-server-care (skills/maintenance). Run inside CLI maintenance mode on a maintenance night.
#
# Who and where: the OWNER runs it with sudo in a STANDALONE SSH client window on his own computer: not a terminal
# tab inside the Claude app and not an editor's integrated terminal (VS Code Remote-SSH), because Claude sessions can
# read those, and with no screen sharing or recording. A generated password is shown on screen once. tmux is optional
# (a hang-up is handled: see on_signal); if tmux is used, run `tmux clear-history` after saving the password.
# The copy that runs is a frozen root-owned one: /root/rotate-db-password.sh (install -o root -g root -m 700), and the
# owner compares its sha256sum with the value he wrote down when it was installed (references/db-password.md, Usage).
#
#   sudo bash /root/rotate-db-password.sh --check [--moodle DIR]          read-only preflight, changes nothing (any day)
#   sudo bash /root/rotate-db-password.sh [--moodle DIR]                  rotate (interactive; needs CLI maintenance mode)
#   sudo bash /root/rotate-db-password.sh --rollback DIR [--moodle DIR]   undo, with the backup folder DIR printed by the rotation
# Other options: --php php8.x (PHP CLI of the site), --fpm-service NAME, --web-user USER, --socket PATH, --mycnf PATH.
# Defaults come from the operator's ~/.config/moodle-server-care/server.env (MOODLE, PHP, WEBUSER) when present.
#
# Scope: MariaDB with mysql_native_password on a DB server on this host (unix socket). It STOPS (changes nothing) on
# MySQL, other authentication plugins, a remote DB host, or an unusual config.php; those need an adapted procedure.
#
# Progress is recorded (state words only, no secret) in DIR/STATUS, so that after a dropped connection, kill -9 or a
# power loss anyone can see how far the run got: started, db, config, verified, complete, reverted, revert-failed,
# rolled-back, rollback-incomplete.
#
# Exit codes: 0 done; 1 failed and nothing is left changed (an automatic revert, if one was needed, succeeded);
# 2 done with a warning; 3 manual attention needed (the printed recipe says what to do); 130 interrupted.
#
# Secrets: nothing secret is printed (except a generated password, once, on the terminal), logged or passed on a
# command line. SQL reaches mariadb on stdin, each batch after SET SESSION slow_query_log=0; the new password reaches
# python3 on stdin; only its mysql_native_password hash is sent to the server; the login test uses a 0600 option file
# on tmpfs that is deleted right away. references/db-password.md explains every step.

set -u -o pipefail
umask 077
ulimit -c 0 2>/dev/null || true
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ---- test hooks: honoured ONLY for a non-root run with RDP_TEST=1 (the harness); a root run ignores them ---------
if [ "$(id -u)" != 0 ] && [ "${RDP_TEST:-0}" = 1 ]; then TEST=1; else
  TEST=0
  for v in $(compgen -v RDP_); do unset "$v"; done
fi
if [ "$TEST" = 1 ] && [ -n "${RDP_PATH_PREPEND:-}" ]; then PATH="$RDP_PATH_PREPEND:$PATH"; fi   # harness: mv wrapper

# ---- options ------------------------------------------------------------------------------------------------------
MODE=rotate; BK=""; OPT_MOODLE=""; OPT_PHP=""; OPT_FPM=""; OPT_WEB=""; OPT_SOCK=""; OPT_MYCNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    ""|--rotate) MODE=rotate; shift ;;
    --check) MODE=check; shift ;;
    --rollback) MODE=rollback; BK=${2:-}; shift 2 || shift ;;
    --moodle) OPT_MOODLE=${2:-}; shift 2 || shift ;;
    --php) OPT_PHP=${2:-}; shift 2 || shift ;;
    --fpm-service) OPT_FPM=${2:-}; shift 2 || shift ;;
    --web-user) OPT_WEB=${2:-}; shift 2 || shift ;;
    --socket) OPT_SOCK=${2:-}; shift 2 || shift ;;
    --mycnf) OPT_MYCNF=${2:-}; shift 2 || shift ;;
    -h|--help) MODE=help; shift ;;
    *) MODE=bad; shift ;;
  esac
done

# server.env of the operator who called sudo (non-secret facts written by detect-env.sh)
OP_USER=${SUDO_USER:-}; [ "$OP_USER" = root ] && OP_USER=""
OP_HOME=""; [ -n "$OP_USER" ] && OP_HOME=$(getent passwd "$OP_USER" | cut -d: -f6)
ENV_MOODLE=""; ENV_PHP=""; ENV_WEB=""
if [ "$TEST" = 0 ] && [ -n "$OP_HOME" ] && [ -r "$OP_HOME/.config/moodle-server-care/server.env" ]; then
  # read only the three keys, without sourcing (the file belongs to another user)
  envval() { sed -nE "s/^$1=(.*)$/\1/p" "$OP_HOME/.config/moodle-server-care/server.env" | head -n 1 | sed -E "s/^'(.*)'$/\1/; s/\\\\(.)/\1/g"; }
  ENV_MOODLE=$(envval MOODLE); ENV_PHP=$(envval PHP); ENV_WEB=$(envval WEBUSER)
fi

# ---- settings (RDP_* overrides exist for the test harness only) --------------------------------------------------
MOODLE_DIR=${RDP_MOODLE_DIR:-${OPT_MOODLE:-$ENV_MOODLE}}
CONFIG="$MOODLE_DIR/config.php"
CFG_CLI="$MOODLE_DIR/admin/cli/cfg.php"
MAINT_CLI="$MOODLE_DIR/admin/cli/maintenance.php"
WEB_USER=${RDP_WEB_USER:-${OPT_WEB:-${ENV_WEB:-www-data}}}
PHPNAME=${OPT_PHP:-${ENV_PHP:-php}}
PHP=${RDP_PHP:-$(command -v "$PHPNAME" 2>/dev/null || echo "/usr/bin/$PHPNAME")}
FPM_SERVICE=${RDP_FPM_SERVICE:-${OPT_FPM:-${PHPNAME}-fpm}}
SOCK=${RDP_SOCK:-$OPT_SOCK}
BACKUP_BASE=${RDP_BACKUP_BASE:-/root}
TMP_BASE=${RDP_TMP_BASE:-/run}
LOCK_FILE=${RDP_LOCK_FILE:-/run/rotate-db-password.lock}   # /run is root-only (not the world-writable /run/lock)
MARIADB=${RDP_MARIADB:-$(command -v mariadb 2>/dev/null || echo /usr/bin/mariadb)}
PYTHON=${RDP_PYTHON:-/usr/bin/python3}
SYSTEMCTL=${RDP_SYSTEMCTL:-/usr/bin/systemctl}
RUNUSER=${RDP_RUNUSER:-/usr/sbin/runuser}
OPENSSL=${RDP_OPENSSL:-/usr/bin/openssl}
SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
if [ -n "${RDP_MYCNF:-}" ]; then MYCNF=$RDP_MYCNF
elif [ -n "$OPT_MYCNF" ]; then MYCNF=$OPT_MYCNF
elif [ -n "$OP_HOME" ]; then MYCNF="$OP_HOME/.my.cnf"
else MYCNF=""; fi

# ---- state ----------------------------------------------------------------------------------------------------
STATE=none        # none | db (DB may be changed, config.php not) | config (both changed, not yet verified) | done | rollback
DB_USER=""
TMPD=""           # private temp dir on tmpfs
TMP_CFG=""        # temp file next to config.php before the rename
TMP_MYCNF=""
NEW_PW=""
NEW_HASH=""
OLD_HASH=""
HOSTS=()
DBPASS_LINE=""
DATAROOT=""
VERSION=""
WARNINGS=0
PROBLEMS=0
MATCH_LIST=""
MYCNF_RESULT=""
LOCKED=0          # 1 once this run holds the lock (only then may it delete leftover temp files)

# ---- python helper (all secret handling: values arrive on stdin, never in argv) ----------------------------------
read -r -d '' PY <<'PYEOF'
import hashlib, os, re, sys, tempfile

def die(msg):
    sys.stderr.write('   ' + msg + '\n')
    sys.exit(1)

def native_hash(pw):
    return '*' + hashlib.sha1(hashlib.sha1(pw).digest()).hexdigest().upper()

DBPASS = re.compile(rb"^([ \t]*\$CFG->dbpass[ \t]*=[ \t]*)'([^'\\\r\n]*)'([ \t]*;[^\r\n]*)(\r?)$")
NEWPW = re.compile(rb'[A-Za-z0-9]{32,}')
MYCNF_PW = re.compile(rb'^[ \t]*pass[a-z_-]*[ \t]*(=|$)', re.I)

def read_lines(path):
    with open(path, 'rb') as f:
        return f.read().split(b'\n')

def dbpass_line(lines, path):
    hits = [i for i, l in enumerate(lines) if b'dbpass' in l]
    if len(hits) != 1:
        die('%s: expected exactly 1 line containing "dbpass", found %d' % (path, len(hits)))
    m = DBPASS.match(lines[hits[0]])
    if not m:
        die('%s line %d: not a plain single-quoted $CFG->dbpass assignment without quotes or backslashes '
            'in the value; edit it by hand' % (path, hits[0] + 1))
    return hits[0], m

def cfg_value(lines, key):
    rx = re.compile(rb"^[ \t]*\$CFG->" + key + rb"[ \t]*=[ \t]*'([^'\\]*)'[ \t]*;")
    vals = [m.group(1) for m in map(rx.match, lines) if m]
    return vals[0].decode('utf-8', 'replace') if len(vals) == 1 else ''

def dbsocket(lines):
    # 'dbsocket' => '/path' inside $CFG->dboptions (a path only; true/false/'' mean the default socket)
    rx = re.compile(rb"""['"]dbsocket['"][ \t]*=>[ \t]*['"](/[^'"]+)['"]""")
    for l in lines:
        m = rx.search(l)
        if m:
            return m.group(1).decode('utf-8', 'replace')
    return ''

def write_beside(target, data, uid, gid, mode, prefix):
    fd, tmp = tempfile.mkstemp(prefix=prefix, dir=os.path.dirname(os.path.abspath(target)))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chown(tmp, uid, gid)
        os.chmod(tmp, mode)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die('cannot write a temporary file next to %s (%s)' % (target, e.strerror))
    return tmp

cmd = sys.argv[1]
if cmd == 'inspect':
    lines = read_lines(sys.argv[2])
    i, _ = dbpass_line(lines, sys.argv[2])
    print('%d\t%s\t%s\t%s\t%s\t%s' % (i + 1, cfg_value(lines, b'dbuser'), cfg_value(lines, b'dataroot'),
                                      cfg_value(lines, b'dbtype'), cfg_value(lines, b'dbhost'), dbsocket(lines)))
elif cmd == 'hash-file':
    lines = read_lines(sys.argv[2])
    _, m = dbpass_line(lines, sys.argv[2])
    print(native_hash(m.group(2)))
elif cmd == 'hash-stdin':
    print(native_hash(sys.stdin.buffer.read()))
elif cmd == 'write-config':
    # stdin: line 1 = hash the current value must have, line 2 = the new password
    src = sys.argv[2]
    parts = sys.stdin.buffer.read().split(b'\n')
    if len(parts) != 2:
        die('internal: expected 2 lines on stdin')
    expect, new = parts[0].decode('ascii', 'replace'), parts[1]
    if not NEWPW.fullmatch(new):
        die('the new password fails the [A-Za-z0-9]{32,} check')
    lines = read_lines(src)
    i, m = dbpass_line(lines, src)
    if native_hash(m.group(2)) != expect:
        die('the dbpass value in %s changed since the preflight; nothing written' % src)
    lines[i] = m.group(1) + b"'" + new + b"'" + m.group(3) + m.group(4)
    st = os.stat(src)
    print(write_beside(src, b'\n'.join(lines), st.st_uid, st.st_gid, st.st_mode & 0o7777, '.config.php.dbpw-'))
elif cmd == 'restore-line':
    # argv: backup current; writes a temp file = CURRENT with only its dbpass line taken from BACKUP (surgical: other
    # changes made after the rotation, e.g. a Redis password line, are kept)
    bkp, cur = sys.argv[2], sys.argv[3]
    b = read_lines(bkp); c = read_lines(cur)
    _, mb = dbpass_line(b, bkp)
    i, mc = dbpass_line(c, cur)
    c[i] = mc.group(1) + b"'" + mb.group(2) + b"'" + mc.group(3) + mc.group(4)
    st = os.stat(cur)
    print(write_beside(cur, b'\n'.join(c), st.st_uid, st.st_gid, st.st_mode & 0o7777, '.config.php.restore-'))
elif cmd == 'verify-restore':
    # argv: before after orig. 'after' equals 'before' except (at most) the dbpass line, which holds orig's value.
    a, b, o = read_lines(sys.argv[2]), read_lines(sys.argv[3]), read_lines(sys.argv[4])
    if len(a) != len(b):
        die('line count changed (%d -> %d)' % (len(a), len(b)))
    i, mb = dbpass_line(b, sys.argv[3])
    _, mo = dbpass_line(o, sys.argv[4])
    diff = [k for k in range(len(a)) if a[k] != b[k]]
    if diff not in ([], [i]):
        die('unexpected changes on lines %s' % [k + 1 for k in diff])
    if mb.group(2) != mo.group(2):
        die('line %d does not hold the old password' % (i + 1))
    print(i + 1)
elif cmd == 'other-diffs':
    # argv: a b. Lines that differ between a and b, apart from the dbpass line, by line number and $CFG key ONLY:
    # never the content, because lines such as $CFG->session_redis_auth hold secrets.
    import difflib
    a, b = read_lines(sys.argv[2]), read_lines(sys.argv[3])
    KEY = re.compile(rb'^[ \t]*\$CFG->([A-Za-z0-9_]+)')
    def key(l):
        m = KEY.match(l)
        if m:
            return '$CFG->' + m.group(1).decode('ascii')
        return '(empty line)' if not l.strip() else '(line without a $CFG-> key)'
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        for k in range(i1, i2):
            if b'dbpass' not in a[k]:
                print('only in the backup:   line %d  %s' % (k + 1, key(a[k])))
        for k in range(j1, j2):
            if b'dbpass' not in b[k]:
                print('only in config.php:   line %d  %s' % (k + 1, key(b[k])))
elif cmd == 'verify-config':
    # argv: before after; stdin: new password. Exactly one line may differ: the dbpass line, now the new value.
    a, b = read_lines(sys.argv[2]), read_lines(sys.argv[3])
    new = sys.stdin.buffer.read()
    if len(a) != len(b):
        die('line count changed (%d -> %d)' % (len(a), len(b)))
    diff = [k for k in range(len(a)) if a[k] != b[k]]
    i, m = dbpass_line(b, sys.argv[3])
    if diff != [i]:
        die('unexpected changes on lines %s' % [k + 1 for k in diff])
    if m.group(2) != new:
        die('line %d does not hold the new password' % (i + 1))
    print(i + 1)
elif cmd == 'mycnf-count':
    print(sum(1 for l in read_lines(sys.argv[2]) if MYCNF_PW.match(l)))
elif cmd == 'mycnf-remove':
    # argv: path dbuser. Drops every password line and the "user=<dbuser>" line, so that a plain `mariadb` run as the
    # file's owner neither carries a password nor tries to log in as the Moodle DB user (no log noise).
    path, dbuser = sys.argv[2], sys.argv[3].encode('ascii')
    user_rx = re.compile(rb'^[ \t]*user[ \t]*=[ \t]*["\']?' + re.escape(dbuser) + rb'["\']?[ \t]*\r?$', re.I)
    out = [l for l in read_lines(path) if not MYCNF_PW.match(l) and not user_rx.match(l)]
    st = os.stat(path)
    print(write_beside(path, b'\n'.join(out), st.st_uid, st.st_gid, 0o600, '.my.cnf.dbpw-'))
else:
    die('internal: unknown command')
PYEOF

py() { (cd / && "$PYTHON" -I -c "$PY" "$@"); }

# ---- output helpers ---------------------------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
info() { printf '   info  %s\n' "$*"; }
warn() { printf '   WARN  %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }

usage() {
  cat <<EOF
Usage (as root, in a standalone SSH client window: not a Claude app terminal tab, not an editor's integrated
terminal, no screen sharing or recording):
  sudo bash $SELF --check [--moodle DIR]           read-only preflight, changes nothing
  sudo bash $SELF [--moodle DIR]                   rotate the password of the Moodle MariaDB user (needs CLI maintenance mode)
  sudo bash $SELF --rollback DIR [--moodle DIR]    undo a rotation with its backup folder (printed at the end of the rotation)
Options: --php php8.x  --fpm-service NAME  --web-user USER  --socket PATH  --mycnf PATH
EOF
}

# Visible answer. Default IFS trims surrounding spaces.
ask() {
  local __v
  if ! read -r -p "$2" __v; then printf '\n' >&2; fail "no input (stdin closed)"; fi
  __v=${__v%$'\r'}
  printf -v "$1" '%s' "$__v"
}
# Typed confirmation word (ROTATE/ROLLBACK): empty lines (paste tails) are ignored and asked again.
ask_word() {
  local __w="" __n=0
  while :; do
    ask __w "$2"
    [ -n "$__w" ] && break
    __n=$((__n + 1)); [ "$__n" -lt 5 ] || break
  done
  printf -v "$1" '%s' "$__w"
}
# Hidden answer. An empty line (the CR/LF tail of a password-manager paste) is ignored and asked again.
ask_secret() {
  local __v __n=0
  while :; do
    if ! read -r -s -p "$2" __v; then printf '\n' >&2; fail "no input (stdin closed)"; fi
    printf '\n' >&2
    __v=${__v%$'\r'}
    [ -n "$__v" ] && break
    __n=$((__n + 1)); [ "$__n" -lt 5 ] || fail "only empty input"
  done
  printf -v "$1" '%s' "$__v"
}

# ---- database helpers ---------------------------------------------------------------------------------------------
# Root over the unix socket, ignoring every option file (so ~/.my.cnf can never turn this into the Moodle user).
mysql_root() { "$MARIADB" --no-defaults --protocol=socket --socket="$SOCK" --user=root --batch --skip-column-names; }

# SQL on stdin; result on stdout; error text on stderr with any password hash masked.
# Every batch starts with SET SESSION slow_query_log=0: with the slow log on (and log_slow_admin_statements), an
# ALTER USER stalled for longer than long_query_time would otherwise write the password hash into the slow log.
sql_root() {
  local out rc errf="$TMPD/sql.err"
  out=$( { printf 'SET SESSION slow_query_log=0;\n'; cat; } | mysql_root 2>"$errf"); rc=$?
  if [ -s "$errf" ]; then sed -E 's/\*[0-9A-Fa-f]{4,}/<hash>/g; s/[0-9A-F]{8,}/<hex>/g' "$errf" | head -5 | sed 's/^/         /' >&2; fi
  rm -f -- "$errf"
  printf '%s' "$out"
  return "$rc"
}

load_hosts() {
  local raw h
  raw=$(printf "SELECT host FROM mysql.user WHERE user='%s' ORDER BY host;\n" "$DB_USER" | sql_root) || return 1
  HOSTS=()
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [[ $h =~ ^[A-Za-z0-9._%:-]+$ ]] || { printf '   unexpected host value for %s\n' "$DB_USER" >&2; return 1; }
    HOSTS+=("$h")
  done <<< "$raw"
  [ "${#HOSTS[@]}" -gt 0 ]
}

# Every host entry must use plain mysql_native_password (the hash form below depends on it). MariaDB only.
check_plugins() {
  local raw host plugin author bad=0
  raw=$(printf '%s\n' "SELECT host, IFNULL(JSON_VALUE(priv,'\$.plugin'),'?'), JSON_EXTRACT(priv,'\$.auth_or') IS NOT NULL FROM mysql.global_priv WHERE user='$DB_USER' ORDER BY host;" | sql_root) || return 1
  while IFS=$'\t' read -r host plugin author; do
    [ -n "$host" ] || continue
    if [ "$plugin" != mysql_native_password ] || [ "$author" != 0 ]; then
      printf '   %s@%s uses plugin %s (auth_or=%s); this script handles mysql_native_password only\n' \
        "$DB_USER" "$host" "$plugin" "$author" >&2
      bad=1
    fi
  done <<< "$raw"
  return "$bad"
}

# hash_matches HASH: 0 when every host entry of DB_USER has exactly this hash. The comparison happens inside MariaDB.
hash_matches() {
  local raw host m all=0 list=""
  MATCH_LIST=""
  [[ $1 =~ ^\*[0-9A-F]{40}$ ]] || return 2
  raw=$(printf '%s\n' "SELECT host, authentication_string = '$1' FROM mysql.user WHERE user='$DB_USER' ORDER BY host;" | sql_root) || return 2
  while IFS=$'\t' read -r host m; do
    [ -n "$host" ] || continue
    if [ "$m" = 1 ]; then list+="$host=yes "; else list+="$host=no "; all=1; fi
  done <<< "$raw"
  [ -n "$list" ] || return 2
  MATCH_LIST=${list% }
  return "$all"
}

# set_db_hash HASH: ALTER USER every host entry to this mysql_native_password hash.
set_db_hash() {
  local h sql=""
  [[ $1 =~ ^\*[0-9A-F]{40}$ ]] || return 1
  for h in "${HOSTS[@]}"; do
    sql+="ALTER USER '$DB_USER'@'$h' IDENTIFIED BY PASSWORD '$1';"$'\n'
  done
  printf '%s' "$sql" | sql_root >/dev/null
}

revert_db() {
  [ -n "$OLD_HASH" ] || return 1
  set_db_hash "$OLD_HASH" || return 1
  hash_matches "$OLD_HASH"
}

# login_test PASSWORD: connect as DB_USER over the socket, as Moodle does.
login_test() {
  local cnf="$TMPD/login.cnf" out rc
  printf '[client]\nuser=%s\npassword=%s\nsocket=%s\n' "$DB_USER" "$1" "$SOCK" > "$cnf" || return 1
  out=$(printf 'SELECT CURRENT_USER();\n' | "$MARIADB" --defaults-file="$cnf" --protocol=socket --batch --skip-column-names 2>&1); rc=$?
  rm -f -- "$cnf"
  if [ "$rc" -eq 0 ] && [ "$out" = "$DB_USER@localhost" ]; then return 0; fi
  printf '%s\n' "$out" | head -3 | sed 's/^/         /' >&2
  return 1
}

# ---- Moodle / PHP helpers -----------------------------------------------------------------------------------------
php_lint() { "$PHP" -l "$1" >/dev/null 2>&1; }

# Moodle CLI DB read: admin/cli/cfg.php connects with config.php's credentials and prints the version from the DB.
cli_version() {
  local out rc last errf="$TMPD/cli.err"
  out=$(cd / && "$RUNUSER" -u "$WEB_USER" -- "$PHP" "$CFG_CLI" --name=version 2>"$errf"); rc=$?
  last=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)
  if [ "$rc" -ne 0 ] || [[ ! $last =~ ^[0-9]{10}(\.[0-9]+)?$ ]]; then
    { printf '%s\n' "$out"; cat -- "$errf" 2>/dev/null; } | sed '/^[[:space:]]*$/d' | head -6 | sed 's/^/         /' >&2
    rm -f -- "$errf"
    return 1
  fi
  rm -f -- "$errf"
  printf '%s' "$last"
}

fpm_reload() {
  "$SYSTEMCTL" reload "$FPM_SERVICE" && "$SYSTEMCTL" is-active --quiet "$FPM_SERVICE"
}

meta_of() { stat -c '%u %g %a' -- "$1"; }
maint_on() { [ -n "$DATAROOT" ] && [ -f "$DATAROOT/climaintenance.html" ]; }

# cfg_state: which password config.php holds now: old | new | other (decides what an interrupted run must undo)
cfg_state() {
  local h
  h=$(py hash-file "$CONFIG" 2>/dev/null) || { echo other; return; }
  if [ -n "$NEW_HASH" ] && [ "$h" = "$NEW_HASH" ]; then echo new
  elif [ "$h" = "$OLD_HASH" ]; then echo old
  else echo other; fi
}

# restore_dbpass_line: put the backup's dbpass value back into the CURRENT config.php (only that line), atomically,
# with the current owner/group/mode. Other lines changed since (e.g. Redis) are kept.
restore_dbpass_line() {
  TMP_CFG=$(py restore-line "$BK/config.php.orig" "$CONFIG") || { TMP_CFG=""; return 1; }
  if php_lint "$TMP_CFG" && py verify-restore "$CONFIG" "$TMP_CFG" "$BK/config.php.orig" >/dev/null \
     && mv -f -- "$TMP_CFG" "$CONFIG"; then
    TMP_CFG=""
    [ "$(py hash-file "$CONFIG")" = "$OLD_HASH" ]
    return
  fi
  rm -f -- "$TMP_CFG"; TMP_CFG=""
  return 1
}

# mark_status WORD: record how far the run got in $BK/STATUS (state words only, never a secret).
mark_status() {
  [ -n "$BK" ] && [ -d "$BK" ] || return 0
  printf '%s %s\n' "$1" "$(date '+%F %T %z')" > "$BK/STATUS" 2>/dev/null || true
}

# Temp files of an earlier run that was killed (kill -9, power loss) before its cleanup ran. Safe to delete: only
# this script creates these names, and the lock guarantees that no other run is active. They may hold a password.
remove_stale_temp() {
  [ -n "$MOODLE_DIR" ] && rm -f -- "$MOODLE_DIR"/.config.php.dbpw-* "$MOODLE_DIR"/.config.php.restore-* 2>/dev/null
  [ -n "$MYCNF" ] && rm -f -- "$(dirname -- "$MYCNF")"/.my.cnf.dbpw-* 2>/dev/null
  if [ "${1:-}" = all ]; then rm -rf -- "$TMP_BASE"/rotate-dbpw.* 2>/dev/null; fi
  return 0
}

# ---- recipes ------------------------------------------------------------------------------------------------------
manual_recipe() {
  local meta="<uid> <gid> <mode>" b=${BK:-/root/dbpw-rotation-<time>} l=${DBPASS_LINE:-<n>}
  [ -n "$BK" ] && [ -f "$BK/config.php.meta" ] && meta=$(cat -- "$BK/config.php.meta")
  set -- $meta
  cat <<EOF

Rollback recipe (Moodle stays in CLI maintenance mode while you do it):
  Scripted (preferred):  sudo bash $SELF --rollback $b --moodle $MOODLE_DIR
             (asks for the OLD password hidden, or Enter to take it from the backup file; sets only the dbpass line
              of config.php back, sets the old password back on every host entry, checks Moodle CLI, reloads $FPM_SERVICE)
  By hand:
    1. sudo diff $b/config.php.orig $CONFIG | grep -E '^[0-9]'   # change positions only, no content
       If it prints only ${l}c${l} (the dbpass line), copy the backup back as a whole:
       sudo install -o $1 -g $2 -m $3 $b/config.php.orig $CONFIG
       sudo -u $WEB_USER $PHP -l $CONFIG
       If it prints more, config.php was changed after the rotation (for example the Redis step): copying the
       backup would undo that change too. Use the scripted rollback, which sets back only the dbpass line.
    2. read -rs OLDPW            # type the OLD password; nothing is shown
       printf "SET SESSION slow_query_log=0; ALTER USER '${DB_USER:-<dbuser>}'@'localhost' IDENTIFIED BY '%s';\n" "\$OLDPW" | sudo mariadb --no-defaults; unset OLDPW
       (one ALTER per host entry: ${HOSTS[*]:-localhost}; works when the old password has no ' or \\ characters)
    3. sudo -u $WEB_USER $PHP $CFG_CLI --name=version     # prints the version = Moodle reaches the DB
       sudo systemctl reload $FPM_SERVICE
EOF
}

verify_recipe() {
  cat <<EOF
Checks to run by hand:
  sudo -u $WEB_USER $PHP $CFG_CLI --name=version            # prints the version number
  sudo systemctl reload $FPM_SERVICE && systemctl is-active $FPM_SERVICE
  The version prints: the rotation is in place. Also remove the password line from ${MYCNF:-the operator's ~/.my.cnf} by
  hand (sed -i '/^[[:space:]]*pass/Id; /^[[:space:]]*user[[:space:]]*=[[:space:]]*${DB_USER:-<dbuser>}[[:space:]]*\$/d' ${MYCNF:-~/.my.cnf})
  and continue. It does not print: roll back with the recipe below.
EOF
}

# ---- failure and signal handling -----------------------------------------------------------------------------
# STATE is set to "config" only after the `mv` of the new config.php has returned. A failure or signal that lands
# between the rename and that assignment would otherwise be handled as "config.php untouched" and set the OLD DB
# password back under a config.php that already holds the NEW one (Moodle locked out). So look at the file itself.
settle_state() {
  if [ "$STATE" = db ] && [ "$(cfg_state)" = new ]; then
    STATE=config
    mark_status config
  fi
}

fail() {
  trap '' INT TERM HUP
  printf '\nERROR: %s\n' "$1" >&2
  settle_state
  case $STATE in
    none)
      printf 'Nothing was changed.\n' >&2
      exit 1 ;;
    db)
      printf 'The DB password may already be changed, config.php is NOT: setting the old DB password back...\n' >&2
      if revert_db; then
        mark_status reverted
        printf 'Reverted (%s). Nothing is changed: config.php untouched, old DB password active.\n' "$MATCH_LIST" >&2
        exit 1
      fi
      mark_status revert-failed
      printf 'AUTOMATIC REVERT FAILED.\n' >&2
      manual_recipe >&2
      exit 3 ;;
    config)
      printf 'config.php and the DB both hold the NEW password, but a check failed.\n' >&2
      local a=""
      read -r -p "Roll back now (old dbpass line back into config.php, old DB password back)? [Y/n] " a || a=y
      if [[ ! ${a:-y} =~ ^[Nn] ]]; then
        if rollback_now; then
          mark_status reverted
          printf 'Rolled back: old password active, config.php dbpass line restored. Nothing is left changed.\n' >&2
          exit 1
        fi
        mark_status revert-failed
        printf 'ROLLBACK DID NOT COMPLETE.\n' >&2
      fi
      manual_recipe >&2
      exit 3 ;;
    rollback)
      mark_status rollback-incomplete
      printf 'The rollback stopped half-way. State: see the lines above.\n' >&2
      manual_recipe >&2
      exit 3 ;;
    *)
      printf 'The rotation itself completed; only a follow-up step failed.\n' >&2
      exit 2 ;;
  esac
}

on_signal() {
  trap '' INT TERM HUP
  printf '\nInterrupted.\n' >&2
  settle_state
  case $STATE in
    db)
      if revert_db; then
        mark_status reverted
        printf 'Old DB password set back; config.php untouched. Nothing is changed.\n' >&2
        exit 130
      fi
      mark_status revert-failed
      printf 'AUTOMATIC REVERT FAILED.\n' >&2; manual_recipe >&2; exit 3 ;;
    config)
      printf 'config.php and the DB both hold the NEW password (consistent), but the checks did not finish.\n' >&2
      verify_recipe >&2; manual_recipe >&2; exit 130 ;;
    rollback)
      mark_status rollback-incomplete
      printf 'The rollback was interrupted half-way.\n' >&2; manual_recipe >&2; exit 3 ;;
    done)
      printf 'The rotation itself had completed.\n' >&2; exit 130 ;;
    *)
      printf 'Nothing was changed.\n' >&2; exit 130 ;;
  esac
}

cleanup() {
  [ -n "$TMP_CFG" ] && rm -f -- "$TMP_CFG"
  [ -n "$TMP_MYCNF" ] && rm -f -- "$TMP_MYCNF"
  [ -n "$TMPD" ] && rm -rf -- "$TMPD"
  # e.g. python killed by Ctrl-C after creating its temp file, before bash learned the name. Only while holding the
  # lock: a second run refused by the lock must never delete the active run's files.
  [ "$LOCKED" = 1 ] && remove_stale_temp
  NEW_PW=""
}

rollback_now() {
  local rc=0
  if revert_db; then ok "old DB password active again ($MATCH_LIST)"; else warn "setting the old DB password FAILED"; rc=1; fi
  if [ "$(cfg_state)" = old ]; then ok "config.php already holds the old password"
  elif restore_dbpass_line; then ok "config.php dbpass line restored from $BK"; else warn "config.php restore FAILED"; rc=1; fi
  if cli_version >/dev/null; then ok "Moodle CLI reads the DB again"; else warn "Moodle CLI still fails"; rc=1; fi
  if fpm_reload; then ok "$FPM_SERVICE reloaded"; else warn "$FPM_SERVICE reload failed"; rc=1; fi
  return "$rc"
}

# ---- preflight (shared by all modes) ----------------------------------------------------------------------------
problem() {
  if [ "$MODE" = check ]; then printf '   FAIL  %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); else fail "$1"; fi
}

preflight() {
  local t info dbuser n dbtype dbhost dbsock ver
  step "Preflight (read-only)"
  [ -n "$MOODLE_DIR" ] || { problem "Moodle directory unknown: pass --moodle DIR (or run detect-env.sh as the operator)"; return; }
  for t in "$MARIADB" "$PYTHON" "$PHP" "$SYSTEMCTL" "$RUNUSER" "$OPENSSL"; do
    [ -x "$t" ] || { problem "missing tool: $t"; return; }
  done
  ok "tools present (PHP $PHP, FPM service $FPM_SERVICE, web user $WEB_USER)"

  if [ ! -f "$CONFIG" ] || [ -L "$CONFIG" ]; then problem "$CONFIG is not a regular file"; return; fi
  if ! info=$(py inspect "$CONFIG"); then problem "config.php dbpass line not usable (see above)"; return; fi
  IFS=$'\t' read -r DBPASS_LINE dbuser DATAROOT dbtype dbhost dbsock <<< "$info"
  [[ $dbuser =~ ^[A-Za-z0-9_]{1,80}$ ]] || { problem "config.php dbuser '$dbuser' is missing or unusual"; return; }
  DB_USER=$dbuser
  case "$dbtype" in mariadb|mysqli) ;; *) problem "config.php dbtype '$dbtype': this script handles MariaDB only (see references/db-password.md)"; return ;; esac
  case "$dbhost" in localhost|127.0.0.1|'') ;; *) problem "config.php dbhost '$dbhost' is not local: rotate through the DB provider instead (references/db-password.md)"; return ;; esac
  [ -n "$SOCK" ] || SOCK=$dbsock
  if [ -z "$SOCK" ]; then for t in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /var/lib/mysql/mysql.sock; do [ -S "$t" ] && { SOCK=$t; break; }; done; fi
  [ -n "$SOCK" ] && { [ -S "$SOCK" ] || [ "$TEST" = 1 ]; } || { problem "no MariaDB unix socket found (pass --socket PATH)"; return; }
  ok "config.php: one plain \$CFG->dbpass line (line $DBPASS_LINE), dbuser $DB_USER, dbhost ${dbhost:-default}, owner/group/mode $(meta_of "$CONFIG")"
  OLD_HASH=$(py hash-file "$CONFIG") || { problem "cannot read the current dbpass value"; return; }
  [ -n "$DATAROOT" ] || { problem "config.php has no plain \$CFG->dataroot line (needed for the maintenance check)"; return; }

  if maint_on; then
    ok "Moodle CLI maintenance mode is ON"
  elif [ "$MODE" = check ]; then
    info "Moodle CLI maintenance mode is OFF (fine for --check; the rotation itself requires it ON)"
  else
    problem "Moodle is not in CLI maintenance mode. First: sudo -u $WEB_USER $PHP $MAINT_CLI --enable"
    return
  fi

  if ! ver=$(printf 'SELECT VERSION();\n' | sql_root 2>/dev/null); then
    # tell the causes apart with the same harmless query without the slow-log switch (MySQL: slow_query_log is global)
    ver=$(printf 'SELECT VERSION();\n' | mysql_root 2>/dev/null) || { problem "cannot connect to the DB as root over $SOCK"; return; }
    [[ $ver == *MariaDB* ]] || { problem "DB server '$ver' is not MariaDB: this script handles MariaDB only (MySQL: references/db-password.md)"; return; }
    problem "SET SESSION slow_query_log=0 failed: this script keeps its statements out of the slow log (it could record the password hash); check the MariaDB version (references/db-password.md)"
    return
  fi
  [[ $ver == *MariaDB* ]] || { problem "DB server '$ver' is not MariaDB: this script handles MariaDB only (MySQL: references/db-password.md)"; return; }
  ok "MariaDB root over the unix socket ($ver); slow query log off for this script's sessions"
  load_hosts || { problem "no host entries found for DB user '$DB_USER'"; return; }
  ok "host entries of $DB_USER: ${HOSTS[*]}"
  check_plugins || { problem "unsupported authentication plugin (see above)"; return; }
  ok "all entries use mysql_native_password"
  n=$(printf '%s\n' "SELECT COUNT(*) FROM information_schema.plugins WHERE plugin_type='PASSWORD VALIDATION' AND plugin_status='ACTIVE';" | sql_root) || n="query failed"
  if [ "$n" = 0 ]; then
    ok "no password-validation plugin active (MariaDB accepts the hash form of ALTER USER)"
  else
    problem "password-validation plugin check: $n (with strict_password_validation=ON, ALTER USER ... IDENTIFIED BY PASSWORD is rejected)"
    return
  fi
  if hash_matches "$OLD_HASH"; then
    ok "config.php password is the live DB password ($MATCH_LIST)"
  else
    problem "config.php password does not match the DB for every host entry (${MATCH_LIST:-query failed}); investigate first"
    return
  fi

  if VERSION=$(cli_version); then ok "Moodle CLI DB read works: version $VERSION"
  else problem "Moodle CLI DB read fails BEFORE any change (fix that first; Redis step?)"; return; fi
  if "$SYSTEMCTL" is-active --quiet "$FPM_SERVICE"; then ok "$FPM_SERVICE active"; else problem "$FPM_SERVICE is not active (pass --fpm-service NAME)"; fi

  if [ -z "$MYCNF" ]; then
    info "no operator ~/.my.cnf to check (run with sudo from the operator account, or pass --mycnf PATH)"
  elif [ -f "$MYCNF" ]; then
    n=$(py mycnf-count "$MYCNF") || n="?"
    info "$MYCNF exists (mode $(stat -c %a -- "$MYCNF")), password lines: $n (you will be asked what to do with it)"
  else
    info "$MYCNF does not exist"
  fi
  [ -d "$BACKUP_BASE" ] && [ -w "$BACKUP_BASE" ] || problem "backup folder $BACKUP_BASE not writable"
  [ -d "$TMP_BASE" ] || problem "temp base $TMP_BASE missing"
}

# ---- new password ---------------------------------------------------------------------------------------------
choose_password() {
  local gen="" a="" b="" ans="" tries h
  # fd 7 = the terminal itself, so the generated password never lands in a redirected or tee'd stdout/stderr.
  if [ "$TEST" = 1 ] || ! { exec 7>/dev/tty; } 2>/dev/null; then exec 7>&2; fi
  step "New password"
  ask ans "Generate a new random password (openssl rand -hex 24, 48 characters)? [Y/n] "
  if [[ ! ${ans:-y} =~ ^[Nn] ]]; then
    gen=$("$OPENSSL" rand -hex 24) || fail "openssl rand failed"
    [[ $gen =~ ^[0-9a-f]{48}$ ]] || fail "openssl returned an unexpected value"
    {
      printf '\n   New password (shown ONCE, nothing else ever prints it):\n\n'
      printf '        %s\n\n' "$gen"
      printf '   Save it now in the password manager, e.g. entry "<site> DB %s".\n' "$DB_USER"
    } >&7
    ask ans "Press Enter once it is saved in the password manager... "
    ask ans "Clear the screen and scrollback now? [Y/n] "
    [[ ${ans:-y} =~ ^[Nn] ]] || printf '\033[H\033[2J\033[3J' >&7
    say "Now paste it back FROM THE PASSWORD MANAGER (this proves the saved entry is right)."
  else
    say "Type or paste the new password: letters and digits only, at least 32 characters."
  fi
  exec 7>&-
  for tries in 1 2 3; do
    ask_secret a "New password (hidden): "
    ask_secret b "Same again (hidden):   "
    if [ "$a" != "$b" ]; then
      say "   The two entries differ. ($tries/3)"
    elif [[ ! $a =~ ^[A-Za-z0-9]{32,}$ ]]; then
      say "   Rejected: use only A-Z a-z 0-9 and at least 32 characters (no spaces or symbols). ($tries/3)"
    elif [ -n "$gen" ] && [ "$a" != "$gen" ]; then
      say "   This is not the generated password: check the password manager entry. ($tries/3)"
    else
      h=$(printf '%s' "$a" | py hash-stdin) || fail "hashing failed"
      if [ "$h" = "$OLD_HASH" ]; then
        say "   That is the current password. Choose a new one. ($tries/3)"
      else
        NEW_PW=$a; NEW_HASH=$h; a=""; b=""; gen=""
        ok "new password accepted (${#NEW_PW} characters)"
        return 0
      fi
    fi
  done
  a=""; b=""; gen=""
  fail "no valid new password after 3 attempts"
}

# ---- backup -------------------------------------------------------------------------------------------------------
make_backup() {
  step "Backup"
  BK="$BACKUP_BASE/dbpw-rotation-$(date +%Y%m%dT%H%M%S)"
  mkdir -m 700 -- "$BK" || fail "cannot create $BK"
  cp -- "$CONFIG" "$BK/config.php.orig" && chmod 600 -- "$BK/config.php.orig" || fail "cannot copy config.php"
  cmp -s -- "$CONFIG" "$BK/config.php.orig" || fail "backup copy differs from config.php"
  meta_of "$CONFIG" > "$BK/config.php.meta" || fail "cannot record config.php owner/mode"
  printf '%s\n' "${HOSTS[@]}" > "$BK/hosts"
  printf '%s\n' "$DB_USER" > "$BK/dbuser"
  if [ -n "$MYCNF" ] && [ -f "$MYCNF" ] && [ ! -L "$MYCNF" ]; then
    cp -- "$MYCNF" "$BK/my.cnf.orig" && chmod 600 -- "$BK/my.cnf.orig" && meta_of "$MYCNF" > "$BK/my.cnf.meta" \
      || fail "cannot back up $MYCNF"
  fi
  cat > "$BK/NOTE.txt" <<EOF
Backup made by rotate-db-password.sh on $(date '+%F %T %z') before rotating the password of MariaDB user
'$DB_USER' (host entries: ${HOSTS[*]}).
config.php.orig = $CONFIG before the change (owner uid/gid/mode in config.php.meta)
my.cnf.orig     = ${MYCNF:-<none>} before the change (if present)
STATUS          = how far the run got (started, db, config, verified, complete, reverted, revert-failed, ...)
These files hold the OLD password. Keep root-only; delete (shred -u) after about 7 good days.
Rollback: sudo bash $SELF --rollback $BK --moodle $MOODLE_DIR
EOF
  chmod 600 -- "$BK"/* 2>/dev/null
  mark_status started
  ok "config.php backed up to $BK (root only)"
}

# ---- ~/.my.cnf --------------------------------------------------------------------------------------------------
# There is deliberately no "update it to the new password" choice: the operator's option file is readable by every
# Claude session running as that user, and option files are how DB passwords leak (tools that print their defaults).
# Writing the new password into it would set up the same leak again.
handle_mycnf() {
  local n ans
  [ -n "$MYCNF" ] || { MYCNF_RESULT="not checked"; return 0; }
  step "$MYCNF"
  if [ -L "$MYCNF" ]; then warn "$MYCNF is a symbolic link: left untouched, check it by hand"; MYCNF_RESULT="symlink, untouched"; return 0; fi
  if [ ! -f "$MYCNF" ]; then ok "not present, nothing to do"; MYCNF_RESULT="not present"; return 0; fi
  n=$(py mycnf-count "$MYCNF") || { warn "cannot read $MYCNF"; MYCNF_RESULT="unreadable"; return 0; }
  if [ "$n" = 0 ]; then ok "no password line, nothing to do"; MYCNF_RESULT="no password line"; return 0; fi
  say "   It holds a database password ($n line(s)). Option files with passwords are how passwords leak"
  say "   (tools that print their defaults, backups of the home directory, any session running as its owner)."
  say "   [r] remove the password line(s) and the user=$DB_USER line (recommended: Moodle does not use this file,"
  say "       analysis scripts read config.php, and a plain 'mariadb' then no longer tries to log in as $DB_USER)"
  say "   [k] keep it unchanged (it then holds a dead old password; every 'mariadb' run as its owner logs a failed login)"
  say "   (Writing the new password into this file is not offered: every session running as its owner can read it.)"
  ask ans "   Choice [r/k] (default r): "
  case ${ans:-r} in
    r|R) ;;
    k|K) ok "kept unchanged (holds the old password; mariadb as $(stat -c %U -- "$MYCNF") will fail)"; MYCNF_RESULT="kept (stale)"; return 0 ;;
    u|U) info "updating is not offered (it would put the new password back into a file sessions can read): removing" ;;
    *)   info "unrecognised answer: removing (the safe choice)" ;;
  esac
  TMP_MYCNF=$(py mycnf-remove "$MYCNF" "$DB_USER") || { warn "could not edit $MYCNF"; TMP_MYCNF=""; MYCNF_RESULT="FAILED"; return 0; }
  if mv -f -- "$TMP_MYCNF" "$MYCNF"; then
    TMP_MYCNF=""
    [ "$(py mycnf-count "$MYCNF")" = 0 ] || warn "$MYCNF content check failed"
    MYCNF_RESULT="password and user=$DB_USER lines removed, mode $(stat -c %a -- "$MYCNF")"
    ok "$MYCNF: $MYCNF_RESULT"
  else
    rm -f -- "$TMP_MYCNF"; TMP_MYCNF=""
    warn "could not replace $MYCNF"; MYCNF_RESULT="FAILED"
  fi
}

# ---- modes ------------------------------------------------------------------------------------------------------
do_check() {
  preflight
  step "Result"
  if [ "$PROBLEMS" -eq 0 ]; then
    say "Ready: yes (nothing was changed). On the night, maintenance mode must be ON before the rotation."
    exit 0
  fi
  say "Ready: NO, $PROBLEMS problem(s) above (nothing was changed)."
  exit 1
}

do_rotate() {
  local ans line v2
  preflight
  choose_password

  step "Plan"
  say "   1. back up config.php to $BACKUP_BASE/dbpw-rotation-<time>/ (root only)"
  say "   2. ALTER USER $DB_USER@{${HOSTS[*]}} to the new password (only its hash is sent)"
  say "   3. replace line $DBPASS_LINE (\$CFG->dbpass) of $CONFIG, keep owner/group/mode $(meta_of "$CONFIG"), php -l"
  say "   4. Moodle CLI DB read, reload $FPM_SERVICE"
  say "   5. ${MYCNF:-operator ~/.my.cnf} (you choose)"
  say "   A failure in 1-3 sets the old DB password back by itself; config.php is replaced only after step 2 passed."
  ask_word ans "Type ROTATE to start: "
  [ "$ans" = ROTATE ] || fail "not confirmed"

  # The owner may have spent minutes in the password manager; someone could have switched maintenance off (for example
  # the "--disable" line at the end of a Redis procedure) or changed config.php or the DB meanwhile.
  step "Re-check just before the change (read-only)"
  maint_on || fail "Moodle CLI maintenance mode was switched OFF after the preflight (switched off meanwhile). Enable it again (sudo -u $WEB_USER $PHP $MAINT_CLI --enable) and re-run; nothing changed"
  [ "$(py hash-file "$CONFIG" 2>/dev/null)" = "$OLD_HASH" ] || fail "the config.php dbpass value changed after the preflight; investigate first; nothing changed"
  hash_matches "$OLD_HASH" || fail "the DB password no longer matches config.php (${MATCH_LIST:-query failed}); investigate first; nothing changed"
  v2=$(cli_version) || fail "Moodle CLI DB read fails now (it worked in the preflight); nothing changed"
  [ "$v2" = "$VERSION" ] || fail "Moodle CLI returned version $v2, the preflight saw $VERSION; nothing changed"
  ok "maintenance mode still ON; config.php and the DB still hold the old password; Moodle CLI reads the DB"

  make_backup

  step "Database"
  STATE=db
  mark_status db
  set_db_hash "$NEW_HASH" || fail "ALTER USER failed"
  hash_matches "$NEW_HASH" || fail "the DB does not hold the new password on every host entry (${MATCH_LIST:-?})"
  ok "ALTER USER done on every host entry ($MATCH_LIST): the old password no longer works"
  if printf '%s\n' "${HOSTS[@]}" | grep -qx localhost; then
    login_test "$NEW_PW" || fail "login as $DB_USER@localhost with the new password failed"
    ok "login as $DB_USER@localhost over the socket with the new password works"
  else
    info "no localhost entry, socket login test skipped"
  fi

  step "config.php"
  TMP_CFG=$(printf '%s\n%s' "$OLD_HASH" "$NEW_PW" | py write-config "$CONFIG") || { TMP_CFG=""; fail "could not prepare the new config.php"; }
  php_lint "$TMP_CFG" || fail "php -l rejected the new config.php (config.php untouched)"
  trap '' INT TERM HUP                     # the rename and the state change belong together
  if mv -f -- "$TMP_CFG" "$CONFIG"; then TMP_CFG=""; STATE=config; mark_status config; fi
  trap on_signal INT TERM HUP
  [ "$STATE" = config ] || fail "could not move the new config.php in place"
  line=$(printf '%s' "$NEW_PW" | py verify-config "$BK/config.php.orig" "$CONFIG") || fail "config.php content check failed"
  [ "$(meta_of "$CONFIG")" = "$(cat -- "$BK/config.php.meta")" ] || fail "config.php owner/group/mode changed"
  php_lint "$CONFIG" || fail "php -l rejected config.php"
  ok "line $line replaced, nothing else changed; owner/group/mode $(meta_of "$CONFIG") kept; php -l ok"

  step "Moodle and PHP-FPM"
  v2=$(cli_version) || fail "Moodle CLI cannot read the DB with the new password"
  [ "$v2" = "$VERSION" ] || fail "Moodle CLI returned version $v2, expected $VERSION"
  ok "Moodle CLI DB read with the new password: version $v2"
  STATE=done
  mark_status verified
  if fpm_reload; then ok "$FPM_SERVICE reloaded and active (persistent DB connections reopened with the new password)"
  else warn "$FPM_SERVICE reload failed: run 'sudo systemctl reload $FPM_SERVICE' (the reboot will also restart it)"; fi
  if v2=$(cli_version); then ok "Moodle CLI DB read after the reload: version $v2"; else warn "Moodle CLI DB read failed after the reload"; fi
  info "web check is not possible yet: in maintenance mode Moodle answers 503 without touching the DB"

  MYCNF_RESULT=""
  handle_mycnf
  NEW_PW=""
  maint_on || warn "Moodle CLI maintenance mode is OFF now (someone switched it off during the run); the night's plan expects it ON until the post-checks"

  mark_status complete
  step "ROTATION COMPLETE$([ "$WARNINGS" -gt 0 ] && printf ' (with %d warning(s): read the WARN lines above)' "$WARNINGS")"
  say "   DB user     $DB_USER@{${HOSTS[*]}}: new password active, old one refused"
  say "   config.php  line $DBPASS_LINE updated, $(meta_of "$CONFIG"), php -l ok"
  say "   Moodle CLI  version $VERSION read from the DB with the new password"
  say "   ~/.my.cnf   $MYCNF_RESULT"
  say "   Backup      $BK (root only, holds the OLD password: delete after ~7 good days)"
  say "   Next: keep maintenance mode ON and continue the night's plan. Tell the session only the exit code"
  say "   (echo \$?) and the backup folder name; the log entry gets no secret."
  manual_recipe
  [ "$WARNINGS" -gt 0 ] && exit 2
  exit 0
}

do_rollback() {
  local t th ans uid gid mode rec_user info diffs cur_user
  [ -d "$BK" ] && [ -f "$BK/config.php.orig" ] && [ -f "$BK/config.php.meta" ] \
    || fail "$BK is not a backup folder made by this script"
  step "Rollback preflight (read-only)"
  [ -n "$MOODLE_DIR" ] || fail "Moodle directory unknown: pass --moodle DIR"
  for t in "$MARIADB" "$PYTHON" "$PHP" "$SYSTEMCTL" "$RUNUSER"; do [ -x "$t" ] || fail "missing tool: $t"; done
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail "$CONFIG is not a regular file"
  OLD_HASH=$(py hash-file "$BK/config.php.orig") || fail "cannot read the dbpass line of the backup"
  php_lint "$BK/config.php.orig" || fail "the backup config.php fails php -l"
  IFS=$'\t' read -r _ DB_USER DATAROOT _ _ t <<< "$(py inspect "$BK/config.php.orig")"
  [ -n "$SOCK" ] || SOCK=$t
  if [ -z "$SOCK" ]; then for t in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /var/lib/mysql/mysql.sock; do [ -S "$t" ] && { SOCK=$t; break; }; done; fi
  rec_user=$(cat -- "$BK/dbuser" 2>/dev/null || true)
  [ -z "$rec_user" ] || [ "$rec_user" = "$DB_USER" ] || fail "backup dbuser '$rec_user' differs from the backup config.php ('$DB_USER')"
  [[ $DB_USER =~ ^[A-Za-z0-9_]{1,80}$ ]] || fail "unusual dbuser in the backup"
  [ "$(printf 'SELECT 1;\n' | sql_root)" = 1 ] || fail "cannot connect to MariaDB as root over $SOCK"
  load_hosts || fail "no host entries found for $DB_USER"
  ok "host entries of $DB_USER: ${HOSTS[*]}"
  [ "$(tr '\n' ' ' < "$BK/hosts" | sed 's/ $//')" = "${HOSTS[*]}" ] || warn "host entries differ from the ones recorded in $BK/hosts"
  check_plugins || fail "unsupported authentication plugin"
  info=$(py inspect "$CONFIG") || fail "the current config.php has no usable dbpass line (see above): use the by-hand recipe"
  IFS=$'\t' read -r DBPASS_LINE cur_user _ _ _ _ <<< "$info"
  [ "$cur_user" = "$DB_USER" ] || fail "the current config.php names DB user '$cur_user', the backup '$DB_USER': investigate first"
  ok "current config.php: one plain \$CFG->dbpass line (line $DBPASS_LINE)"
  if maint_on; then ok "Moodle CLI maintenance mode is ON"
  else
    say "   Moodle is NOT in CLI maintenance mode. If the site is up, enable it first in another window:"
    say "   sudo -u $WEB_USER $PHP $MAINT_CLI --enable"
    ask ans "   Roll back WITHOUT maintenance mode anyway (e.g. Moodle is down already)? [y/N] "
    [[ ${ans:-n} =~ ^[Yy] ]] || fail "not confirmed (enable maintenance mode, then run --rollback again)"
    warn "rolling back with maintenance mode OFF (confirmed)"
  fi
  if hash_matches "$OLD_HASH"; then info "the DB already holds the old password ($MATCH_LIST)"; fi

  # Only the dbpass line goes back. Any other difference between the backup and the current config.php was made
  # after the rotation (e.g. a Redis step's $CFG->session_redis_auth added or deleted) and is KEPT as it is now.
  # Listed by line number and key only: those lines can hold secrets.
  diffs=$(py other-diffs "$BK/config.php.orig" "$CONFIG") || fail "cannot compare config.php with the backup"
  if [ -n "$diffs" ]; then
    say "   config.php was also changed after the rotation, apart from the dbpass line:"
    printf '%s\n' "$diffs" | sed 's/^/      /'
    say "   These lines are KEPT as they are now; only the dbpass line is set back."
    ask ans "   Continue on that basis? [y/N] "
    [[ ${ans:-n} =~ ^[Yy] ]] || fail "not confirmed; nothing changed"
  else
    ok "config.php differs from the backup in the dbpass line only (or not at all)"
  fi

  step "Old password"
  ask_secret_opt() { local __v; if ! read -r -s -p "$2" __v; then printf '\n' >&2; fail "no input"; fi; printf '\n' >&2; printf -v "$1" '%s' "${__v%$'\r'}"; }
  ask_secret_opt t "Type the OLD password to confirm it (or just press Enter to take it from the backup file): "
  if [ -n "$t" ]; then
    th=$(printf '%s' "$t" | py hash-stdin) || fail "hashing failed"
    t=""
    [ "$th" = "$OLD_HASH" ] || fail "that is not the password stored in $BK/config.php.orig; nothing changed"
    ok "typed password matches the backup"
  else
    ok "using the password stored in $BK/config.php.orig"
  fi
  say "   This sets the OLD password back on ${HOSTS[*]} and sets line $DBPASS_LINE (\$CFG->dbpass) of $CONFIG back"
  say "   (only that line; other changes made since, e.g. a Redis password line, are kept)."
  ask_word ans "Type ROLLBACK to start: "
  [ "$ans" = ROLLBACK ] || fail "not confirmed"

  cp -- "$CONFIG" "$BK/config.php.before-rollback" && chmod 600 -- "$BK/config.php.before-rollback" \
    || fail "cannot save the current config.php"
  STATE=rollback
  step "Rollback"
  revert_db || fail "setting the old DB password failed"
  ok "old DB password active ($MATCH_LIST)"
  if [ "$(py hash-file "$CONFIG")" = "$OLD_HASH" ]; then ok "config.php already holds the old password"
  else restore_dbpass_line || fail "restoring the dbpass line failed (the DB already has the OLD password)"
       ok "config.php dbpass line restored ($(meta_of "$CONFIG")), php -l ok"; fi
  VERSION=$(cli_version) || fail "Moodle CLI cannot read the DB after the rollback"
  ok "Moodle CLI DB read: version $VERSION"
  STATE=done
  mark_status rolled-back
  if fpm_reload; then ok "$FPM_SERVICE reloaded"; else warn "$FPM_SERVICE reload failed"; fi
  if [ -n "$MYCNF" ] && [ ! -L "$MYCNF" ] && [ -f "$BK/my.cnf.orig" ] && ! cmp -s -- "$BK/my.cnf.orig" "$MYCNF" 2>/dev/null; then
    say "   Restoring $MYCNF puts the old password back into a file every session running as its owner can read."
    ask ans "Restore $MYCNF from the backup anyway? [y/N] "
    if [[ ${ans:-n} =~ ^[Yy] ]]; then
      read -r uid gid mode < "$BK/my.cnf.meta"
      if install -o "$uid" -g "$gid" -m 600 -- "$BK/my.cnf.orig" "$MYCNF"; then ok "$MYCNF restored (mode 600)"; else warn "could not restore $MYCNF"; fi
    fi
  fi
  step "ROLLBACK COMPLETE$([ "$WARNINGS" -gt 0 ] && printf ' (with %d warning(s))' "$WARNINGS")"
  say "   The OLD password is active again. If it was rotated because it leaked, plan a new rotation soon."
  say "   Saved copy of the config.php that was in place before the rollback: $BK/config.php.before-rollback"
  [ "$WARNINGS" -gt 0 ] && exit 2
  exit 0
}

# ---- main ---------------------------------------------------------------------------------------------------------
case "$MODE" in
  help) usage; exit 0 ;;
  bad)  usage >&2; exit 1 ;;
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
LOCKED=1
remove_stale_temp all   # leftovers of a run killed before its cleanup (kill -9, power loss)
TMPD=$(mktemp -d "$TMP_BASE/rotate-dbpw.XXXXXX") || { printf 'Cannot create a temp dir in %s.\n' "$TMP_BASE" >&2; exit 1; }

say "rotate-db-password.sh  mode=$MODE  $(date '+%F %T %z')  host=$(hostname)  moodle=${MOODLE_DIR:-?}"
case $MODE in
  check)    do_check ;;
  rotate)   do_rotate ;;
  rollback) do_rollback ;;
esac
