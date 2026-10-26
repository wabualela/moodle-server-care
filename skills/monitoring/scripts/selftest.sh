#!/bin/bash
# selftest.sh — tests moodle-health and install.sh in a throwaway harness with mocks.
# Safe on a production server: it sends nothing and changes nothing outside the harness directory.
#   - the real ping URL file is never read: MOODLE_HEALTH_URLFILE points at a path that must not exist, and every
#     ping is recorded in a sink file (MOODLE_HEALTH_PING_SINK) instead of being sent;
#   - every tool the script calls (systemctl, curl, mysqladmin, exiqgrep, postqueue, fail2ban-client, openssl,
#     setpriv, php, sudo, crontab ...) is a mock found first on PATH;
#   - install.sh runs with DESTDIR inside the harness and mock web-server/cron trees.
# Usage: bash selftest.sh [HARNESS_DIR]      (default: a new directory from mktemp)
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
MH="$HERE/moodle-health"
PY=$(command -v python3) || { echo "python3 missing"; exit 2; }
BASE="${1:-}"
if [ -z "$BASE" ]; then BASE=$(mktemp -d "${TMPDIR:-/tmp}/msc-harness-monitoring.XXXXXX"); fi
mkdir -p "$BASE"; BASE=$(cd "$BASE" && pwd)
case "$BASE" in /|/etc|/etc/*|/usr|/usr/*|/var/lib|/var/lib/*|/root|/root/*) echo "refusing harness dir $BASE"; exit 2 ;; esac
R=$(mktemp -d "$BASE/run.XXXXXX")
CTL="$R/ctl"; MOCKS="$R/mocks"; MIN="$R/mocks-min"; FAKE="$R/fake"
mkdir -p "$CTL" "$MOCKS" "$MIN" "$FAKE"/{moodle/admin/cli,moodledata,log,nginx/sites-enabled,nginx/conf.d,apache2/sites-enabled,apache2/conf-enabled,cron.d,empty}
export MH_CTL="$CTL"

# ---- safety first: the harness must never use the real ping URL ----
export MOODLE_HEALTH_URLFILE="$R/no-such-url-file"
export MOODLE_HEALTH_PING_SINK="$R/sink.jsonl"
export MOODLE_HEALTH_CONF="$R/moodle-health.conf"
export MOODLE_HEALTH_STATE="$R/state"
[ -e "$MOODLE_HEALTH_URLFILE" ] && { echo "ABORT: $MOODLE_HEALTH_URLFILE exists"; exit 2; }

PASS=0; FAILN=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -n 25; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "$2" ;; *) ok "$1" ;; esac; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

# ---- static checks ----
if grep -nE "run\(\[ *'/|\[ *'/(usr|s?bin)/" "$MH" >/dev/null; then bad "script calls a tool by absolute path (mocks would be bypassed)"; else ok "no absolute tool paths in run() calls"; fi
"$PY" -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$MH" && ok "moodle-health parses" || bad "moodle-health parses"
for f in "$HERE"/*.sh; do bash -n "$f" && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"; done

# ---- mocks (bash builtins + absolute coreutils only, so PATH can be the mock dir alone) ----
mk() { printf '#!/bin/bash\nC="$MH_CTL"\necho "%s $*" >> "$C/calls"\n%s\n' "$1" "$2" > "$MOCKS/$1"; chmod 755 "$MOCKS/$1"; }
mk systemctl '
inlist() { local f="$C/$1"; [ -f "$f" ] || return 2; local l=" $(<"$f") "; [[ "$l" == *" $2 "* ]]; }
[ -f "$C/systemctl_sleep" ] && /bin/sleep "$(<"$C/systemctl_sleep")"
case "$1" in
  is-active) shift; q=0; [ "$1" = --quiet ] && { q=1; shift; }
    st=active; inlist svc_down "$1" && st=inactive
    inlist svc_up "$1"; [ $? -eq 1 ] && st=inactive
    [ $q = 0 ] && echo "$st"; [ "$st" = active ] && exit 0 || exit 3 ;;
  is-enabled) [ -f "$C/timer_enabled" ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
  list-units) for a in "$@"; do case "$a" in "php*-fpm.service") [ -f "$C/fpm_units" ] && printf "%s\n" "$(<"$C/fpm_units")";; esac; done; exit 0 ;;
  enable) : > "$C/timer_enabled"; exit 0 ;;
  disable) /bin/rm -f "$C/timer_enabled"; exit 0 ;;
  show) echo success ;;
  *) exit 0 ;;
esac'
mk curl '
url="${@: -1}"; h="${url#*://}"; h="${h%%/*}"; h="${h%%:*}"; out=""; jar=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; -c) jar="$2"; shift;; esac; shift; done
code=200; if [ -f "$C/code_$h" ]; then code=$(<"$C/code_$h"); elif [ -f "$C/code" ]; then code=$(<"$C/code"); fi
body="<form><input type=\"hidden\" name=\"logintoken\" value=\"x\"></form>"
if [ -f "$C/body_$h" ]; then body=$(<"$C/body_$h"); elif [ -f "$C/body" ]; then body=$(<"$C/body"); fi
secs=0.120; [ -f "$C/secs" ] && secs=$(<"$C/secs")
[ -n "$jar" ] && : > "$jar"
if [ "$out" = /dev/null ]; then printf "%s" "$code"; exit 0; fi
if [ "$code" = 000 ]; then printf "\n000 0.000"; exit 7; fi
printf "%s\n%s %s" "$body" "$code" "$secs"'
mk mariadb-admin 'rc=0; [ -f "$C/db_rc" ] && rc=$(<"$C/db_rc"); exit $rc'
mk pg_isready 'rc=0; [ -f "$C/pg_rc" ] && rc=$(<"$C/pg_rc"); exit $rc'
mk redis-cli 'if [ -f "$C/redis_out" ]; then printf "%s\n" "$(<"$C/redis_out")"; else echo PONG; fi'
mk exiqgrep 'n=0; f=exiq_stuck; for a in "$@"; do [ "$a" = -z ] && f=exiq_frozen; done; [ -f "$C/$f" ] && n=$(<"$C/$f"); printf "%s matches out of 40 messages\n" "$n"'
mk postqueue 'if [ "$1" = -j ]; then rc=0; [ -f "$C/pq_rc" ] && rc=$(<"$C/pq_rc"); [ $rc = 0 ] && [ -f "$C/pq_json" ] && printf "%s\n" "$(<"$C/pq_json")"; [ $rc != 0 ] && echo "postqueue: invalid option -- j"; exit $rc; fi
[ -f "$C/mailq_out" ] && printf "%s\n" "$(<"$C/mailq_out")"'
mk mailq '[ -f "$C/mailq_out" ] && printf "%s\n" "$(<"$C/mailq_out")" || echo "Mail queue is empty"'
mk fail2ban-client 'if [ $# -eq 1 ]; then printf "Status\n|- Number of jail:\t2\n\`- Jail list:\tsshd, nginx-limit\n"; else b=""; [ -f "$C/f2b_$2" ] && b=$(<"$C/f2b_$2"); printf "Status for the jail: %s\n\`- Actions\n   \`- Banned IP list:\t%s\n" "$2" "$b"; fi'
mk openssl 'case "$1" in s_client) echo "-----BEGIN CERTIFICATE-----"; echo "MOCK"; echo "-----END CERTIFICATE-----";; x509) e="Jan  1 00:00:00 2099 GMT"; [ -f "$C/cert_end" ] && e=$(<"$C/cert_end"); echo "notAfter=$e";; esac'
mk setpriv 'while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do shift; done; exec "$@"'
mk php8.4 'rc=0; [ -f "$C/checks_rc" ] && rc=$(<"$C/checks_rc"); [ -f "$C/checks_out" ] && printf "%s\n" "$(<"$C/checks_out")"; exit $rc'
mk sudo 'exit 1'
mk crontab '[ -f "$C/crontab" ] && printf "%s\n" "$(<"$C/crontab")"; exit 0'
mk systemd-analyze 'exit 0'
for t in systemctl curl setpriv php8.4 mariadb-admin; do ln -s "$MOCKS/$t" "$MIN/$t"; done

checks_ok='CRITICAL: Environment (core_environment)
    Status| Check
----------+--------------------------------------------------------------------
     ERROR| Environment (core_environment)
          |     Your server environment does not meet all requirements
          |     2 recommended extensions are missing
     ERROR| Routing configuration (core_router)
          |     The routing engine is not configured
   WARNING| Cron running (tool_task_cronrunning)
          |     Last cron started 3 mins ago'

reset_case() {   # fresh state, sink and controls; default healthy server
  /bin/rm -rf "$R/state" "$R/sink.jsonl" "$CTL"; mkdir -p "$CTL"
  printf '%s' "$checks_ok" > "$CTL/checks_out"; echo 2 > "$CTL/checks_rc"
  echo "nginx php8.4-fpm mariadb redis-server exim4 cron fail2ban" > "$CTL/svc_up"
  cat > "$MOODLE_HEALTH_CONF" <<EOF
WWWROOT=https://lms.example.org
MOODLE=$FAKE/moodle
DATAROOT=$FAKE/moodledata
PHPBIN=php8.4
WEBUSER=www-data
SERVICES="nginx php8.4-fpm mariadb redis-server exim4 cron"
DBTYPE=mariadb
REDIS_CHECK=yes
ACCESS_LOG="$FAKE/log/access.log"
FPM_LOGS="$FAKE/log/php8.4-fpm.log"
CRON_LOG=$FAKE/log/cron.log
CF_RANGES_FILE=$FAKE/nginx/conf.d/cloudflare-realip.conf
DISK_PATHS="$R"
DISK_CRIT_PCT=101   # real disk usage must not make tests flaky
MEM_CRIT_PCT=0
MOODLE_CHECKS_EVERY_MIN=0
EOF
  : > "$FAKE/log/php8.4-fpm.log"; touch "$FAKE/log/cron.log"
  gen_access "$FAKE/log/access.log" 100 0 nginx
}
setconf() { printf '%s=%s\n' "$1" "$2" >> "$MOODLE_HEALTH_CONF"; }
gen_access() {   # gen_access FILE TOTAL BAD STYLE(nginx|apache|vhost|json|old)
  "$PY" -I - "$@" <<'PY'
import datetime, sys
f, total, bad, style = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
now = datetime.datetime.now().astimezone()
with open(f, 'w') as o:
    for i in range(total):
        t = now - datetime.timedelta(seconds=(total - i) * (3600 if style == 'old' else 1))
        ts = t.strftime('%d/%b/%Y:%H:%M:%S %z'); code = 502 if i < bad else 200
        if style == 'json':
            o.write('{"time":"%s","status":%d,"uri":"/x"}\n' % (t.isoformat(), code))
        elif style == 'apache':
            o.write('203.0.113.%d - - [%s] "GET /a\\"b?x=1 HTTP/1.1" %d 512 "-" "Mozilla/5.0"\n' % (i % 250, ts, code))
        elif style == 'vhost':
            host = 'lms.example.org:443' if i % 2 == 0 else 'other.example.net:443'
            o.write('%s 203.0.113.%d - - [%s] "GET / HTTP/1.1" %d 512 "-" "UA"\n' % (host, i % 250, ts, code if i % 2 == 0 else 200))
        else:
            o.write('203.0.113.%d - - [%s] "GET /course/view.php?id=1 HTTP/2.0" %d 512 "-" "UA" rt=0.010\n' % (i % 250, ts, code))
PY
}
runmh()  { env PATH="$MOCKS" "$PY" -I "$MH" "$@" 2>&1; }
runmin() { env PATH="$MIN" "$PY" -I "$MH" "$@" 2>&1; }
sink() { "$PY" -I - "$MOODLE_HEALTH_PING_SINK" "$@" <<'PY'
import json, sys
out = []
try:
    out = [json.loads(l) for l in open(sys.argv[1])]
except FileNotFoundError:
    pass
mode = sys.argv[2]
if mode == 'count':
    print(sum(1 for e in out if e['suffix'] == sys.argv[3]))
elif mode == 'last':
    print(((out[-1]['suffix'] or 'OK') + ' | ' + out[-1]['body'].replace('\n', ' | ')) if out else 'none')
else:
    print(' '.join((e['suffix'] or 'OK') for e in out) or 'none')
PY
}
printf 'set_real_ip_from 173.245.48.0/20;\nset_real_ip_from 2400:cb00::/32;\nreal_ip_header CF-Connecting-IP;\n' > "$FAKE/nginx/conf.d/cloudflare-realip.conf"
: > "$FAKE/moodle/admin/cli/checks.php"

echo "== moodle-health scenarios (harness $R) =="
reset_case
out=$(runmh --dry-run); has "S1 before the baseline, known Moodle errors would alert" "$out" "CRITICAL: Moodle status check failing: core_environment"
[ -e "$R/state" ] && bad "S1 dry run must not create the state dir" || ok "S1 dry run leaves no state"
eq "S1 dry run sends nothing" "$(sink all)" "none"

out=$(runmh --baseline); has "S2 baseline records failing checks" "$out" "core_environment, core_router"
out=$(runmh --dry-run); has "S2 healthy dry run after the baseline says all OK" "$out" "all checks OK"
out=$(runmh); eq "S2 first real run pings success" "$(sink all)" "OK"
has "S2 cookie jar reused (curl -b/-c)" "$(<"$CTL/calls")" "-c $R/state/cookies.txt"

reset_case; runmh --baseline >/dev/null
echo "nginx" > "$CTL/svc_down"
runmh >/dev/null; has "S3 one bad run is only pending" "$(sink last)" "pending (confirming): service nginx is inactive"
runmh >/dev/null; has "S3 second bad run alerts" "$(sink last)" "/fail | "
has "S3 alert names the problem" "$(sink last)" "CRITICAL: service nginx is inactive"
: > "$CTL/svc_down"; runmh >/dev/null; has "S3 recovery pings success" "$(sink last)" "OK | "
reset_case; runmh --baseline >/dev/null
echo nginx > "$CTL/svc_down"; runmh >/dev/null; : > "$CTL/svc_down"; runmh >/dev/null; echo nginx > "$CTL/svc_down"; runmh >/dev/null
eq "S3 down-up-down confirms on the third run (2 of 3)" "$(sink all)" "OK OK /fail"

reset_case; runmh --baseline >/dev/null
echo nginx > "$CTL/svc_down"; runmh >/dev/null; runmh >/dev/null
echo "nginx redis-server" > "$CTL/svc_down"; runmh >/dev/null; runmh >/dev/null
eq "S4 new problem while failing re-arms (OK then /fail)" "$(sink all)" "OK /fail /fail OK /fail"

if [ "$(id -u)" -ne 0 ]; then
  reset_case; runmh --baseline >/dev/null; chmod 500 "$R/state"; echo nginx > "$CTL/svc_down"
  runmh >/dev/null; chmod 700 "$R/state"
  has "S5 unwritable state alerts at once" "$(sink last)" "/fail | "
  has "S5 alert says why" "$(sink last)" "state directory not writable"
else
  echo "skip S5 (running as root: chmod does not stop root)"
fi

reset_case; runmh --baseline >/dev/null
out=$(runmh --mute 99999); has "S6 mute capped at 720 min" "$out" "(720 min"
echo nginx > "$CTL/svc_down"; runmh >/dev/null; runmh >/dev/null
has "S6 muted run pings success with MUTED" "$(sink last)" "OK | "
has "S6 body says MUTED" "$(sink last)" "MUTED (planned work)"
has "S6 probes still ran while muted" "$(sink last)" "CRITICAL: service nginx"
runmh --unmute >/dev/null; runmh >/dev/null; has "S6 after unmute it alerts" "$(sink last)" "/fail | "

reset_case; runmh --baseline >/dev/null; echo 2 > "$CTL/exiq_frozen"
runmh >/dev/null; runmh >/dev/null; s=$(sink last)
has "S7 frozen bounces are a warning" "$s" "warning: 2 frozen message(s)"
has "S7 frozen bounces do not alert" "$s" "OK | "
echo 12 > "$CTL/exiq_stuck"; runmh >/dev/null; runmh >/dev/null
has "S7 stuck mail alerts" "$(sink last)" "CRITICAL: 12 messages stuck in the mail queue"

reset_case; runmh --baseline >/dev/null; setconf MTA postfix
"$PY" -I - "$CTL/pq_json" <<'PY'
import json, sys, time
old = time.time() - 3600
rows = [{"queue_name": "deferred", "queue_id": "A%d" % i, "arrival_time": int(old), "sender": "noreply@example.org"} for i in range(11)]
rows += [{"queue_name": "deferred", "queue_id": "B%d" % i, "arrival_time": int(old), "sender": ""} for i in range(3)]
rows += [{"queue_name": "hold", "queue_id": "C1", "arrival_time": int(old), "sender": "x@example.org"}]
rows += [{"queue_name": "active", "queue_id": "D1", "arrival_time": int(time.time()), "sender": "x@example.org"}]
open(sys.argv[1], 'w').write('\n'.join(json.dumps(r) for r in rows))
PY
out=$(runmh --dry-run)
has "S8 postfix -j: stuck mail critical" "$out" "CRITICAL: 11 messages stuck"
has "S8 postfix -j: bounces are warnings" "$out" "warning: 3 old bounce(s)"
has "S8 postfix -j: hold is a warning" "$out" "warning: 1 message(s) on hold"
echo 64 > "$CTL/pq_rc"
cat > "$CTL/mailq_out" <<EOF
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
4F9D195432      583 $(LC_ALL=C date -d '-2 hours' '+%a %b %e %H:%M:%S')  sender@example.org
                                         (connect to mx.example.net[192.0.2.1]:25: Connection timed out)
                                         user@example.net

5A1B2C3D4E!     900 $(LC_ALL=C date -d '-3 hours' '+%a %b %e %H:%M:%S')  MAILER-DAEMON
                                         user2@example.net

-- 2 Kbytes in 2 Requests.
EOF
out=$(runmh --dry-run)
has "S8 mailq fallback: old message is waiting" "$out" "warning: 1 message(s) waiting over 15 min"
has "S8 mailq fallback: ! means hold" "$out" "warning: 1 message(s) on hold"

reset_case; runmh --baseline >/dev/null; gen_access "$FAKE/log/access.log" 100 30 nginx
out=$(runmh --dry-run); has "S9 nginx 5xx burst is critical" "$out" "CRITICAL: 30 of 100 requests failed with 5xx"
gen_access "$FAKE/log/access.log" 100 30 apache
out=$(runmh --dry-run); has "S9 apache combined (escaped quote) parsed" "$out" "CRITICAL: 30 of 100 requests failed with 5xx"
gen_access "$FAKE/log/access.log" 100 60 vhost; setconf ACCESS_LOG_VHOST lms.example.org
out=$(runmh --dry-run); has "S9 vhost_combined filtered to the site" "$out" "30 of 50 requests failed"
reset_case; runmh --baseline >/dev/null; gen_access "$FAKE/log/access.log" 100 30 json
out=$(runmh --dry-run); has "S9 unknown log format warns" "$out" "log format not recognised"
hasnt "S9 unknown format does not alert" "$out" "CRITICAL"
gen_access "$FAKE/log/access.log" 100 90 old
out=$(runmh --dry-run); hasnt "S9 old 5xx outside the window ignored" "$out" "5xx"

reset_case; runmh --baseline >/dev/null
printf '%s' "${checks_ok/2 recommended/7 recommended}" > "$CTL/checks_out"
out=$(runmh --dry-run); hasnt "S10 digits-only change is not a new message" "$out" "Moodle status check"
printf '%s' "${checks_ok/is not configured/is broken now}" > "$CTL/checks_out"
out=$(runmh --dry-run); has "S10 changed message alerts" "$out" "core_router still failing, with a different message"
printf '%s\n     ERROR| Antivirus (core_antivirus)\n          |     scanner failed\n' "$checks_ok" > "$CTL/checks_out"
out=$(runmh --dry-run); has "S10 new failing check alerts" "$out" "Moodle status check failing: core_antivirus"
setconf MOODLE_CHECKS_IGNORE core_antivirus
out=$(runmh --dry-run); hasnt "S10 ignore list suppresses" "$out" "core_antivirus"
setconf MOODLE_WARN_AS_CRIT tool_task_cronrunning
out=$(runmh --dry-run); has "S10 WARNING counts when listed" "$out" "failing: tool_task_cronrunning"
echo 255 > "$CTL/checks_rc"; printf 'PHP Fatal error: x\n' > "$CTL/checks_out"
out=$(runmh --baseline); has "S10 baseline refuses when checks cannot run" "$out" "baseline NOT changed"

reset_case; runmh --baseline >/dev/null; echo "203.0.113.9 173.245.48.7" > "$CTL/f2b_nginx-limit"
out=$(runmh --dry-run); has "S11 fail2ban ban of a Cloudflare address is critical" "$out" "jail nginx-limit banned proxy/CDN address 173.245.48.7"
printf 'RemoteIPHeader CF-Connecting-IP\nRemoteIPTrustedProxy 173.245.48.0/20 103.21.244.0/22\n' > "$FAKE/apache2/conf-enabled/remoteip.conf"
setconf CF_RANGES_FILE "$FAKE/apache2/conf-enabled/remoteip.conf"
out=$(runmh --dry-run); has "S11 Apache RemoteIPTrustedProxy ranges understood" "$out" "banned proxy/CDN address 173.245.48.7"
echo "203.0.113.9" > "$CTL/f2b_nginx-limit"
out=$(runmh --dry-run); hasnt "S11 ordinary bans are fine" "$out" "fail2ban"

reset_case; runmh --baseline >/dev/null; setconf SERVICES nginx
out=$(runmin --self-check)
has "S12 self-check: redis skipped without redis-cli" "$out" "SKIPPED: redis-cli not installed"
has "S12 self-check: mail skipped without MTA tools" "$out" "SKIPPED: no exim (exiqgrep) or Postfix"
has "S12 self-check: fail2ban skipped without client" "$out" "SKIPPED: fail2ban not installed"
has "S12 self-check: URL file absent (never read)" "$out" "ping URL file $R/no-such-url-file: absent"
out=$(runmin --dry-run); has "S12 absent tools give no false alert" "$out" "all checks OK"

reset_case; runmh --baseline >/dev/null; echo 1.2 > "$CTL/systemctl_sleep"
out=$(env MOODLE_HEALTH_BUDGET=2 PATH="$MOCKS" "$PY" -I "$MH" --dry-run 2>&1)
has "S13 budget exhaustion is a warning" "$out" "time budget (2 s) used up"
hasnt "S13 skipped probes are not reported as failures" "$out" "CRITICAL"
/bin/rm -f "$CTL/systemctl_sleep"

reset_case; echo "fake" > "$R/fake-url"
out=$("$PY" -I - "$MH" "$R/fake-url" <<'PY' 2>&1
import importlib.machinery, importlib.util, os, sys
sys.dont_write_bytecode = True                  # no __pycache__ next to the script
for k in ('MOODLE_HEALTH_PING_SINK', 'MOODLE_HEALTH_URLFILE'):
    os.environ.pop(k, None)
loader = importlib.machinery.SourceFileLoader('mh', sys.argv[1])
spec = importlib.util.spec_from_loader('mh', loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
fake = sys.argv[2]
open(fake, 'w').write('https://invalid.example/fake-check\n')
m.DEFAULT_URLFILE = m.URLFILE = fake          # never the real file: both point at the scratch fake
calls = []
class R:
    def read(self): return b'OK'
def rec(req, timeout=0):
    calls.append(req.full_url); return R()
m.urllib.request.urlopen = rec
print('guarded:', m.ping('/fail', 'x'), '| calls', len(calls))
m.CONF, m.STATE = m.DEFAULT_CONF, m.DEFAULT_STATE
print('real path:', m.ping('/fail', 'x'), '| calls', calls)
PY
)
has "S14 test settings + real URL path: nothing sent" "$out" "guarded: not sent: test settings with the real ping URL file"
has "S14 guard made no HTTP call" "$out" "test path) | calls 0"
has "S14 production settings use the URL file (recorded, not sent)" "$out" "real path: sent | calls ['https://invalid.example/fake-check/fail']"

reset_case; : > "$R/statefile"
out=$(env MOODLE_HEALTH_STATE="$R/statefile" PATH="$MOCKS" "$PY" -I "$MH" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "S15 crash exits non-zero" || bad "S15 crash exits non-zero"
has "S15 crash alerts" "$(sink last)" "moodle-health crashed"
/bin/rm -f "$R/sink.jsonl"; env MOODLE_HEALTH_STATE="$R/statefile" PATH="$MOCKS" "$PY" -I "$MH" --dry-run >/dev/null 2>&1
eq "S15 dry run never pings, even on errors" "$(sink all)" "none"

reset_case; runmh --baseline >/dev/null
echo 503 > "$CTL/code"; echo "<h1>Site under maintenance</h1>" > "$CTL/body"
out=$(runmh --dry-run); has "S16 maintenance mode detected" "$out" "site is in maintenance mode (HTTP 503)"
echo 200 > "$CTL/code"; echo "<html>Error reading from database (dmlreadexception)</html>" > "$CTL/body"
out=$(runmh --dry-run); has "S17 DB error page detected" "$out" "login page shows a database error"
echo "<html>hello</html>" > "$CTL/body"
out=$(runmh --dry-run); has "S17 missing login form detected" "$out" "without the login form"
/bin/rm -f "$CTL/body"; echo 7.5 > "$CTL/secs"
out=$(runmh --dry-run); has "S17 slow login page is a warning" "$out" "warning: login page took 7.5 s"
/bin/rm -f "$CTL/secs"
echo "$(LC_ALL=C date -u -d '+5 days' '+%b %e %H:%M:%S %Y') GMT" > "$CTL/cert_end"
out=$(runmh --dry-run); has "S18 certificate expiring soon" "$out" "site certificate expires in"
/bin/rm -f "$CTL/cert_end"
touch -d '-25 minutes' "$FAKE/log/cron.log"
out=$(runmh --dry-run); has "S19 stale cron log" "$out" "Moodle cron log not written for 2"

reset_case; runmh --baseline >/dev/null; setconf WWWROOT https://lms.example.org:8443/moodle; : > "$CTL/calls"
runmh --dry-run >/dev/null
has "S20 sub-path and port probed" "$(<"$CTL/calls")" "https://lms.example.org:8443/moodle/login/index.php"
has "S20 resolve uses the port" "$(<"$CTL/calls")" "--resolve lms.example.org:8443:127.0.0.1"

reset_case; runmh --baseline >/dev/null; setconf EXTRA_SITES "app.example.org shop.example.org/health"
echo 404 > "$CTL/code_app.example.org"; echo 502 > "$CTL/code_shop.example.org"
out=$(runmh --dry-run); has "S21 dead extra site alerts" "$out" "shop.example.org HTTP 502"
hasnt "S21 404 extra site is alive" "$out" "app.example.org HTTP"
has "S21 extra site path used" "$(<"$CTL/calls")" "https://shop.example.org/health"

reset_case; runmh --baseline >/dev/null; setconf DBTYPE pgsql; echo 2 > "$CTL/pg_rc"
out=$(runmh --dry-run); has "S22 pgsql down detected" "$out" "PostgreSQL does not accept connections"
out=$(runmin --dry-run); hasnt "S22 no pg_isready: skipped" "$out" "PostgreSQL"
reset_case; runmh --baseline >/dev/null; echo 1 > "$CTL/db_rc"
out=$(runmh --dry-run); has "S22 mariadb ping failure detected" "$out" "database does not answer ping"
echo "NOAUTH Authentication required." > "$CTL/redis_out"
hasnt "S22 redis NOAUTH counts as alive" "$(runmh --dry-run)" "redis does not answer"
echo "Could not connect to Redis at 127.0.0.1:6379: Connection refused" > "$CTL/redis_out"
has "S22 redis down detected" "$(runmh --dry-run)" "redis does not answer"
echo "[$(date '+%d-%b-%Y %H:%M:%S')] WARNING: [pool www] server reached pm.max_children setting (20), consider raising it" > "$FAKE/log/php8.4-fpm.log"
has "S23 one max_children hit is a warning" "$(runmh --dry-run)" "warning: PHP-FPM pool www hit max_children once"
echo "[$(date '+%d-%b-%Y %H:%M:%S')] WARNING: [pool www] server reached pm.max_children setting (20), consider raising it" >> "$FAKE/log/php8.4-fpm.log"
has "S23 two hits are critical" "$(runmh --dry-run)" "CRITICAL: PHP-FPM pool www hit max_children 2 times"
setconf DISK_CRIT_PCT 1
has "S24 disk threshold" "$(runmh --dry-run)" "% full"

echo; echo "== install.sh scenarios (DESTDIR) =="
D="$R/root-fake"; ST="$R/stage"; mkdir -p "$D"
cat > "$R/server.env" <<EOF
MOODLE=$FAKE/moodle
DOCROOT=$FAKE/moodle
DATAROOT=$FAKE/moodledata
SITE=lms.example.org
WWWROOT=https://lms.example.org
RELEASE='4.5.2 (Build: 20250101)'
DBTYPE=mariadb
DBNAME=moodle
PHP=php8.4
FPM_SOCK=/run/php/php8.4-fpm.sock
WEBUSER=www-data
VHOST=$FAKE/nginx/sites-enabled/moodle.conf
ORIGIN_IP=192.0.2.10
CLOUDFLARE=yes
EOF
cat > "$FAKE/nginx/sites-enabled/moodle.conf" <<EOF
server { listen 443 ssl; server_name lms.example.org;
  access_log $FAKE/log/lms-access.log perf;
  access_log $FAKE/log/moodle-ratelimit.log combined if=\$limited;
  access_log off;
}
EOF
printf 'server { listen 443 ssl; server_name app.example.org; }\nserver { listen 443 ssl; server_name dead.example.org; }\nserver { listen 80 default_server; server_name _; }\n' > "$FAKE/nginx/sites-enabled/others.conf"
printf "<?php\n\$CFG->dbtype = 'mariadb';\n\$CFG->dbhost = 'localhost';\n\$CFG->dbpass = 'SECRET-SHOULD-NOT-APPEAR';\n\$CFG->wwwroot = 'https://lms.example.org';\n" > "$FAKE/moodle/config.php"
gen_access "$FAKE/log/lms-access.log" 50 0 nginx
inst() {
  env -u MOODLE_HEALTH_CONF -u MOODLE_HEALTH_STATE PATH="$MOCKS:/usr/bin:/bin" MSC_ENV="$R/server.env" MH_NO_SUDO=1 \
    MH_NGINX_DIR="$FAKE/nginx" MH_APACHE_DIRS="$FAKE/apache2" MH_CRON_D="$FAKE/cron.d" MH_VARLOG="$FAKE/log" \
    MH_LOG_DIR_APACHE="$FAKE/log/apache2" DESTDIR="$D" bash "$HERE/install.sh" "$@" --stage "$ST" 2>&1
}
reset_case
echo "nginx php8.4-fpm mariadb redis-server exim4 cron fail2ban" > "$CTL/svc_up"
echo "php8.4-fpm.service loaded active running The PHP 8.4 FastCGI Process Manager" > "$CTL/fpm_units"
echo "* * * * * /usr/bin/php8.4 $FAKE/moodle/admin/cli/cron.php >> $FAKE/log/moodle-cron.log 2>&1" > "$CTL/crontab"
echo 000 > "$CTL/code_dead.example.org"; touch "$FAKE/log/moodle-cron.log"
ALL=""
out=$(inst plan); ALL="$ALL$out"
c=$(cat "$ST/moodle-health.default" 2>/dev/null)
has "I1 plan renders services" "$c" 'SERVICES="nginx php8.4-fpm mariadb redis-server exim4 cron fail2ban"'
has "I1 plan finds the vhost access log" "$c" "ACCESS_LOG=\"$FAKE/log/lms-access.log\""
has "I1 plan finds the FPM log" "$c" "FPM_LOGS=\"$FAKE/log/php8.4-fpm.log\""
has "I1 plan finds the cron log" "$c" "CRON_LOG=$FAKE/log/moodle-cron.log"
has "I1 plan finds the Cloudflare ranges" "$c" "CF_RANGES_FILE=$FAKE/nginx/conf.d/cloudflare-realip.conf"
has "I1 plan keeps live vhosts" "$c" 'EXTRA_SITES="app.example.org"'
has "I1 plan reports dead vhosts" "$out" "dead.example.org(000)"
has "I1 plan sets redis check" "$c" "REDIS_CHECK=yes"
has "I1 plan sets the MTA" "$c" "MTA=exim"
if grep -qE '<[A-Z_]+>' "$ST/moodle-health.default"; then bad "I1 no placeholders left"; else ok "I1 no placeholders left"; fi
eq "I1 plan writes nothing under DESTDIR" "$(find "$D" -type f | wc -l)" "0"
has "I1 plan previews checks" "$out" "Moodle status check failing: core_environment"
out=$(inst install); ALL="$ALL$out"
has "I2 install without --yes changes nothing" "$out" "Nothing changed"
eq "I2 still nothing under DESTDIR" "$(find "$D" -type f | wc -l)" "0"
out=$(inst install --yes); ALL="$ALL$out"
eq "I2 script installed 755" "$(stat -c %a "$D/usr/local/sbin/moodle-health" 2>/dev/null)" "755"
eq "I2 config installed 644" "$(stat -c %a "$D/etc/default/moodle-health" 2>/dev/null)" "644"
has "I2 units installed" "$(ls "$D/etc/systemd/system/" 2>/dev/null | tr '\n' ' ')" "moodle-health.service moodle-health.timer"
hasnt "I2 install never enables the timer" "$(<"$CTL/calls")" "systemctl enable"
has "I2 daemon-reload done" "$(<"$CTL/calls")" "systemctl daemon-reload"
out=$(inst baseline --yes); ALL="$ALL$out"
has "I3 baseline recorded" "$out" "baseline of known failing Moodle checks: core_environment, core_router"
has "I3 dry run clean after baseline" "$out" "Dry run clean"
[ -f "$D/var/lib/moodle-health/moodle-checks.baseline" ] && ok "I3 baseline file exists" || bad "I3 baseline file exists"
out=$(inst url-command); ALL="$ALL$out"
has "I4 url-command gives the no-echo command" "$out" "read -rsp \"ping URL: \" U"
has "I4 url-command targets the URL file" "$out" "> $D/etc/default/moodle-health.url"
out=$(inst enable --yes); ALL="$ALL$out"
has "I5 enable refuses without URL file" "$out" "STOP: pre-checks failed"
hasnt "I5 refused enable did not touch the timer" "$(<"$CTL/calls")" "systemctl enable"
printf 'https://hc-ping.invalid/00000000-test-only-not-a-real-check\n' > "$D/etc/default/moodle-health.url"; chmod 644 "$D/etc/default/moodle-health.url"
out=$(inst enable --yes); ALL="$ALL$out"
has "I5 enable refuses a world-readable URL file" "$out" "mode-644-not-600"
chmod 600 "$D/etc/default/moodle-health.url"
out=$(inst enable --yes); ALL="$ALL$out"
has "I5 enable runs after the checks pass" "$(<"$CTL/calls")" "systemctl enable --now moodle-health.timer"
hasnt "I5 URL never printed" "$ALL" "test-only-not-a-real-check"
eq "I5 enable sent no ping" "$(sink all)" "none"
out=$(inst install --yes); ALL="$ALL$out"
has "I6 reinstall keeps the existing config" "$out" "is KEPT"
ls "$D"/root/moodle-health-$(date +%F)*/moodle-health >/dev/null 2>&1 && ok "I6 reinstall backed up the old script" || bad "I6 reinstall backed up the old script"
out=$(inst uninstall --yes); ALL="$ALL$out"
has "I7 uninstall warns to pause the check first" "$out" "FIRST the owner pauses"
[ -e "$D/usr/local/sbin/moodle-health" ] && bad "I7 uninstall moved the script" || ok "I7 uninstall moved the script"
[ -f "$D/root/moodle-health-removed-$(date +%F)/moodle-health.url" ] && ok "I7 URL file archived, not deleted" || bad "I7 URL file archived, not deleted"
hasnt "I7 secret from config.php never printed" "$ALL" "SECRET-SHOULD-NOT-APPEAR"

# Apache + Postfix variant (plan only)
printf '<VirtualHost *:443>\n  ServerName lms.example.org\n  ErrorLog ${APACHE_LOG_DIR}/lms_error.log\n  CustomLog ${APACHE_LOG_DIR}/lms_access.log combined\n</VirtualHost>\n' > "$FAKE/apache2/sites-enabled/lms.conf"
sed -i "s#^VHOST=.*#VHOST=#" "$R/server.env"
echo "apache2 php8.4-fpm mariadb postfix cron" > "$CTL/svc_up"
out=$(env -u MOODLE_HEALTH_CONF -u MOODLE_HEALTH_STATE PATH="$MOCKS:/usr/bin:/bin" MSC_ENV="$R/server.env" MH_NO_SUDO=1 \
  MH_NGINX_DIR="$FAKE/empty" MH_APACHE_DIRS="$FAKE/apache2" MH_CRON_D="$FAKE/cron.d" MH_VARLOG="$FAKE/log" \
  MH_LOG_DIR_APACHE="$FAKE/log/apache2" DESTDIR="$D" bash "$HERE/install.sh" plan --stage "$R/stage-apache" 2>&1)
c=$(cat "$R/stage-apache/moodle-health.default" 2>/dev/null)
has "I8 apache: services" "$c" 'SERVICES="apache2 php8.4-fpm mariadb postfix cron"'
has "I8 apache: CustomLog expanded" "$c" "ACCESS_LOG=\"$FAKE/log/apache2/lms_access.log\""
has "I8 apache: ErrorLog found" "$c" "APACHE_ERROR_LOG=$FAKE/log/apache2/lms_error.log"
has "I8 apache: RemoteIP ranges file found" "$c" "CF_RANGES_FILE=$FAKE/apache2/conf-enabled/remoteip.conf"
has "I8 postfix: MTA set from the active service" "$c" "MTA=postfix"

# Moodle without admin/cli/checks.php (older than 3.9): baseline step is skipped, enable does not require it
mkdir -p "$FAKE/moodle-old"; cp "$FAKE/moodle/config.php" "$FAKE/moodle-old/config.php"
sed "s#^MOODLE=.*#MOODLE=$FAKE/moodle-old#; s#^DOCROOT=.*#DOCROOT=$FAKE/moodle-old#" "$R/server.env" > "$R/server-old.env"
echo "nginx php8.4-fpm mariadb cron" > "$CTL/svc_up"
inst9() {
  env -u MOODLE_HEALTH_CONF -u MOODLE_HEALTH_STATE PATH="$MOCKS:/usr/bin:/bin" MSC_ENV="$R/server-old.env" MH_NO_SUDO=1 \
    MH_NGINX_DIR="$FAKE/nginx" MH_APACHE_DIRS="$FAKE/empty" MH_CRON_D="$FAKE/cron.d" MH_VARLOG="$FAKE/log" \
    DESTDIR="$R/root-old" bash "$HERE/install.sh" "$@" --stage "$R/stage-old" 2>&1
}
inst9 plan >/dev/null; inst9 install --yes >/dev/null
out=$(inst9 baseline --yes)
has "I9 no checks.php: baseline skipped" "$out" "no baseline needed"
has "I9 no checks.php: self-check explains" "$out" "SKIPPED: admin/cli/checks.php not found"
mkdir -p "$R/root-old/etc/default"; printf 'https://hc-ping.invalid/test-only\n' > "$R/root-old/etc/default/moodle-health.url"; chmod 600 "$R/root-old/etc/default/moodle-health.url"
out=$(inst9 enable)
has "I9 enable pre-check: baseline not needed" "$out" "not needed (Moodle status checks not active"

echo; echo "== discover.sh (read-only, mocks) =="
echo "apache2 php8.4-fpm mariadb postfix cron" > "$CTL/svc_up"
out=$(env -u MOODLE_HEALTH_CONF -u MOODLE_HEALTH_STATE PATH="$MOCKS:/usr/bin:/bin" MSC_ENV="$R/server.env" MH_NO_SUDO=1 \
  MH_NGINX_DIR="$FAKE/nginx" MH_APACHE_DIRS="$FAKE/apache2" MH_CRON_D="$FAKE/cron.d" MH_CRONTAB="$FAKE/cron.d/none" \
  MH_VARLOG="$FAKE/log" MH_LOG_DIR_APACHE="$FAKE/log/apache2" DESTDIR="$D" bash "$HERE/discover.sh" 2>&1); rc=$?
eq "D1 discover exits 0" "$rc" "0"
has "D1 discover shows the site" "$out" "lms.example.org / https://lms.example.org"
has "D1 discover lists tools" "$out" "fail2ban-client            yes"
has "D1 discover finds the Apache vhost log" "$out" "lms_access.log"
has "D1 discover says the URL file is absent (DESTDIR)" "$out" "ping URL file              absent"
hasnt "D1 discover never prints config secrets" "$out" "SECRET-SHOULD-NOT-APPEAR"

echo; echo "== result: $PASS passed, $FAILN failed (harness: $R) =="
[ "$FAILN" -eq 0 ]
