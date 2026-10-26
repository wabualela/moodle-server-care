#!/bin/bash
# run.sh - lightweight UNPRIVILEGED performance monitor for a Moodle server (moodle-server-care audit module).
#
#   run.sh metrics   one metrics.csv row (cron: every minute)
#   run.sh ttfb      sequential TTFB probes -> ttfb.csv (cron: every 5 minutes)
#   run.sh stop      remove this monitor's '# MSC-MONITOR' lines from the user crontab now
#   run.sh status    show progress (read-only)
#
# The data directory is the directory this script lives in (setup.sh copies it there; tests: MON_DIR=...).
# Site facts come from monitor.env in that directory (written by setup.sh; parsed, never sourced).
# Reads only /proc, /sys/fs/cgroup, ps, ss, the Moodle cron log (if readable), the DB server status (dbstat.php: one
# connection per minute) and Redis INFO. No root, no POST, no writes outside the data directory.
# Self-expiry: metrics/ttfb first check END_EPOCH, data dir size (>100 MB) and monitor.err (>1 MB); on any of these
# the '# MSC-MONITOR' crontab lines are removed, the cookie jar is deleted and the run exits 0. If the removal keeps
# failing, it is retried (and logged) at most once per hour. setup.sh also installs an independent hourly watchdog
# line that removes the '# MSC-MONITOR' lines one hour after END_EPOCH even if this directory is gone.

set -u -o pipefail
export LC_ALL=C
umask 077
PATH="${PATH:-/usr/bin:/bin}:/usr/bin:/bin"   # keep the caller's PATH first (cron: /usr/bin:/bin)

if (( EUID == 0 )); then echo "run.sh: refusing to run as root" >&2; exit 1; fi

D=${MON_DIR:-}
if [[ -z $D ]]; then
  D=${BASH_SOURCE[0]}
  if [[ $D == */* ]]; then D=${D%/*}; else D=.; fi
fi
[[ $D == /* ]] || D=$PWD/$D
S=$D/state
ERR=$D/monitor.err
EVLOG=$D/events.log
MARK='# MSC-MONITOR'

# ---- configuration (monitor.env: KEY=value lines, plain values only)
declare -A CF=()
if [[ -r $D/monitor.env ]]; then
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)=([A-Za-z0-9_./:@%+,=\ -]*)$ ]] || continue
    CF[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done < "$D/monitor.env"
fi
cf() { printf '%s' "${CF[$1]:-$2}"; }
command -v gawk >/dev/null 2>&1 || { echo "run.sh: gawk is missing (setup.sh checks for it); stop the monitor: run.sh stop" >&2; [[ ${1:-} == stop || ${1:-} == status ]] || exit 1; }
[[ -n $(cf MON_TZ '') ]] && export TZ=$(cf MON_TZ '')
PHP=${MON_PHP:-$(cf PHP /usr/bin/php)}
# -n skips the conf.d ini files (PHP start-up drops from ~65 ms to ~15 ms CPU per minute); mysqli is loaded
# explicitly. zend.exception_ignore_args=1: an uncaught exception never prints argument values.
PHP_ARGS=(-n -d extension=mysqlnd -d extension=mysqli -d display_errors=stderr -d zend.exception_ignore_args=1)
CRONLOG=${MON_CRONLOG:-$(cf CRONLOG '')}
BASE_URL=$(cf BASE_URL '')
PROBE_RESOLVE=$(cf PROBE_RESOLVE '')       # e.g. 127.0.0.1: probe the origin directly (bypasses a CDN)
read -r -a P_LABELS <<< "$(cf PROBE_LABELS 'robots login home courses')"
read -r -a P_PATHS <<< "$(cf PROBE_PATHS '/robots.txt /login/index.php / /course/index.php')"
UA='moodle-audit-monitor/1.0'
PHPV=$(cf PHPV '')                          # site PHP version, e.g. 8.3
PHPV2=$(cf PHPV2 '')                        # optional second PHP-FPM version on the box (other apps)
FPM_SOCK=$(cf FPM_SOCK '')
FPM_SOCK2=$(cf FPM_SOCK2 '')
FPM_MAX=$(cf FPM_MAX 0)                     # pm.max_children of the site pool (threshold at 80 %)
DISK=$(cf DISK vda)
WEB_UNIT=$(cf WEB_UNIT nginx)
DB_UNIT=$(cf DB_UNIT mariadb)
REDIS_UNIT=$(cf REDIS_UNIT redis-server)
SYN_TH=$(cf SYN_TH 900)
DBSTAT_ARGS=(--config="$(cf MOODLE_CONFIG '')" --run-th="$(cf RUN_TH 16)")
[[ $(cf DB_ENABLED 1) == 1 ]] || DBSTAT_ARGS+=(--no-db)
if [[ -n $(cf REDIS '') ]]; then DBSTAT_ARGS+=(--redis="$(cf REDIS '')"); else DBSTAT_ARGS+=(--no-redis); fi
MAX_DIR_KB=102400          # 100 MB
MAX_ERR_BYTES=1048576      # 1 MB
MAX_AHEAD=$(( 8 * 86400 )) # END_EPOCH further ahead than this is treated as a typo
SNAP_MIN_GAP=600           # at most one snapshot per 10 min
N_METRICS=96

HDR_METRICS="ts_epoch,ts_local,boot_id8,load1,load5,load15,procs_running,procs_blocked,cpu_user,cpu_sys,cpu_iowait,cpu_softirq,cpu_steal,cpu_idle,mem_avail_mb,mem_free_mb,cached_mb,dirty_mb,swap_used_mb,pswpin_s,pswpout_s,pgmajfault_s,allocstall_s,refault_file_s,psi_cpu_some,psi_mem_some,psi_mem_full,psi_io_some,psi_io_full,disk_r_iops,disk_w_iops,disk_r_kBs,disk_w_kBs,disk_util_pct,disk_await_ms,cg_cpu_db,cg_cpu_php,cg_cpu_php2,cg_cpu_cron,cg_cpu_web,cg_cpu_redis,cg_mem_mb_db,cg_mem_mb_php,cg_mem_mb_cron,cg_mempsi_some_php,cg_mempsi_some_db,fpm_children,fpm_R,fpm_active60,fpm_rss_mb,fpm_listen_q,fpm2_children,fpm2_listen_q,db_rss_mb,my_uptime,my_conn,my_run_avg,my_run_max,my_long_ge1s,my_qps,my_slow_pm,my_fulljoin_s,my_tmpdisk_s,my_bp_reads_s,my_bp_pages_data,my_bp_dirty,my_ckpt_age_mb,my_rowlock_waits_d,my_aborted_clients_d,redis_used_mb,redis_clients,redis_ops_s,redis_hit_pct_d,redis_evicted_d,redis_db_keys,redis_uptime,tcp_estab_443,tcp_estab_80,tcp_synrecv,tcp_timewait,web_acceptq_443,client_rtt_p50,client_rtt_p90,client_rtt_n,listen_drops_d,listen_ovf_d,reqqfull_cookies_d,synretrans_d,passive_opens_d,retrans_segs_d,out_segs_d,cron_php_procs,adhoc_procs,users_5min,cron_ge10s_5m,cron_failed_5m"
HDR_TTFB="ts_epoch,ts_local,label,http_code,http_version,t_dns,t_connect,t_tls,t_ttfb,t_total,size_download,num_connects,curl_exit"

# ------------------------------------------------------------------------------------------------
# gawk collector. stdin: "##PS" ps lines, "##SS" ss -Htani lines, "##SSL" ss -Hlnxt lines.
# Reads /proc and cgroup files itself (getline, no forks). Prints:
#   A,<51 fields load1..db_rss_mb>   C,<17 fields tcp_estab_443..adhoc_procs>
#   EV,<text>   TH,<name>,<value>
# Previous counters: PREV (key value lines); new counters written to NEWF.
# Peer addresses from ss are used in memory only (to drop loopback/self RTTs) and never printed.
# ------------------------------------------------------------------------------------------------
read -r -d '' AWK_COLLECT <<'AWK'
function dl(key, cur,    x) {
  NEW[key] = cur
  if (!VALID || !(key in P)) return ""
  x = cur - P[key]
  return (x < 0) ? "" : x
}
function rate(x, mult, fmt) { return (x == "") ? "" : sprintf(fmt, x * mult / DT) }
function pct(a, b) { return (a == "" || b == "" || b <= 0) ? "" : sprintf("%.2f", 100 * a / b) }
function rd(file,    l) { l = ""; if ((getline l < file) <= 0) l = ""; close(file); return l }
function psitot(file, kind,    l, m, v) {
  v = ""
  while ((getline l < file) > 0) if (index(l, kind " ") == 1 && match(l, /total=([0-9]+)/, m)) v = m[1]
  close(file)
  return v
}
function loadnet(file,    l, n, i, j, a, b, pfx) {
  n = 0
  while ((getline l < file) > 0) LN[++n] = l
  close(file)
  for (i = 1; i < n; i++) {
    split(LN[i], a, " "); split(LN[i + 1], b, " ")
    if (a[1] == b[1] && a[2] !~ /^-?[0-9]+$/) {
      pfx = a[1]; sub(/:$/, "", pfx)
      for (j = 2; j in a; j++) NET[pfx "." a[j]] = b[j]
      i++
    }
  }
  delete LN
}
function dnet(key, name) { return (name in NET) ? dl(key, NET[name]) : "" }
# listen-queue match: a unix socket path, or "host:port" / "port" of a TCP listener
function sockmatch(want, typ, loc) {
  if (want == "") return 0
  if (substr(want, 1, 1) == "/") return (typ == "u_str" && loc == want)
  sub(/^.*:/, "", want)
  return (typ == "tcp" && loc ~ (":" want "$"))
}
BEGIN {
  while ((getline l < PREV) > 0) { if (split(l, kv, " ") >= 2) P[kv[1]] = kv[2] }
  close(PREV)
  DT = NOW - P["t"]
  VALID = (P["boot"] == BOOT && P["t"] != "" && DT > 0 && DT <= 600)
  NEW["boot"] = BOOT; NEW["t"] = NOW
  M1RE = (V1 != "") ? "^php-fpm: master process \\(/etc/php/" V1 "/" : "^php-fpm: master process"
  M2RE = "^php-fpm: master process \\(/etc/php/" V2 "/"
  sec = ""
}
$0 == "##PS"  { sec = "ps";  next }
$0 == "##SS"  { sec = "ss";  next }
$0 == "##SSL" { sec = "ssl"; next }
sec == "ps" {
  if (!match($0, /^ *[0-9]+ +[0-9]+ +[^ ]+ +[0-9]+ ?/)) next
  pid = $1; ppid = $2; st = $3; rss = $4
  args = substr($0, RLENGTH + 1)
  if (args ~ M1RE) { if (ppid == 1 && M1 == "") M1 = pid; next }
  if (V2 != "" && args ~ M2RE) { if (ppid == 1) M2 = pid; next }
  if (args ~ /^php-fpm: pool /) { CPPID[pid] = ppid; CST[pid] = st; CRSS[pid] = rss; next }
  if (ppid == 1 && (args ~ /^nginx: master process/ || args ~ /(^|\/)(apache2|httpd)( |$)/)) { WEBM = pid; next }
  a0 = args; sub(/ .*/, "", a0); sub(/.*\//, "", a0)
  if (a0 == "mariadbd" || a0 == "mysqld") { DBRSS += rss; next }
  if (a0 ~ /^php[0-9.]*$/) {            # the php binary itself, not the "sh -c" wrapper
    if (args ~ /admin\/cli\/cron\.php/) CRONP++
    else if (args ~ /admin\/cli\/adhoc_task\.php/) ADHOC++
  }
  next
}
sec == "ss" {
  if ($0 ~ /^[ \t]/) {                  # ss -i info line for the previous socket
    if (WANT && match($0, / rtt:([0-9.]+)\//, m)) RTT[++NRTT] = m[1] + 0
    WANT = 0; next
  }
  WANT = 0
  state = $1; loc = $4; peer = $5
  lp = loc; sub(/.*:/, "", lp)
  if (state == "ESTAB") {
    if (lp == "443") {
      E443++
      lh = loc; sub(/:[^:]*$/, "", lh); ph = peer; sub(/:[^:]*$/, "", ph)
      if (ph != lh && ph !~ /^(127\.|\[::1\]|\[::ffff:127\.)/) WANT = 1
    } else if (lp == "80") E80++
  } else if (state == "SYN-RECV") SYNR++
  else if (state == "TIME-WAIT") TW++
  next
}
sec == "ssl" {
  if (sockmatch(SOCK1, $1, $5)) LQ1 = $3
  else if (sockmatch(SOCK2, $1, $5)) LQ2 = $3
  else if ($1 == "tcp" && $5 ~ /:443$/) AQ443 += $3
  next
}
END {
  # --- load, procs, cpu
  split(rd("/proc/loadavg"), la, " ")
  while ((getline l < "/proc/stat") > 0) {
    split(l, a, " ")
    if (a[1] == "cpu") {
      ctot = 0; for (i = 2; i <= 9; i++) ctot += a[i]
      dtot = dl("cpu.tot", ctot)
      cu = dl("cpu.user", a[2] + a[3]); cs = dl("cpu.sys", a[4] + a[7]); ci = dl("cpu.iow", a[6])
      csi = dl("cpu.sirq", a[8]); cst = dl("cpu.steal", a[9]); cid = dl("cpu.idle", a[5])
    } else if (a[1] == "procs_running") pr = a[2]
    else if (a[1] == "procs_blocked") pb = a[2]
  }
  close("/proc/stat")
  # --- memory
  while ((getline l < "/proc/meminfo") > 0) { split(l, a, /[: ]+/); MI[a[1]] = a[2] }
  close("/proc/meminfo")
  # --- vmstat
  AS = 0
  while ((getline l < "/proc/vmstat") > 0) { split(l, a, " "); if (a[1] ~ /^allocstall_/) AS += a[2]; else VM[a[1]] = a[2] }
  close("/proc/vmstat")
  swi = rate(dl("vm.pswpin", VM["pswpin"]), 1, "%.2f")
  swo = rate(dl("vm.pswpout", VM["pswpout"]), 1, "%.2f")
  pgf = rate(dl("vm.pgmajfault", VM["pgmajfault"]), 1, "%.2f")
  ast = rate(dl("vm.allocstall", AS), 1, "%.2f")
  rff = rate(dl("vm.refault_file", VM["workingset_refault_file"]), 1, "%.2f")
  # --- PSI (total= is microseconds; % of the interval)
  pcs = psitot("/proc/pressure/cpu", "some"); pms = psitot("/proc/pressure/memory", "some")
  pmf = psitot("/proc/pressure/memory", "full"); pis = psitot("/proc/pressure/io", "some")
  pif = psitot("/proc/pressure/io", "full")
  psics = (pcs == "") ? "" : rate(dl("psi.cpu.some", pcs), 1e-4, "%.3f")
  psims = (pms == "") ? "" : rate(dl("psi.mem.some", pms), 1e-4, "%.3f")
  psimf = (pmf == "") ? "" : rate(dl("psi.mem.full", pmf), 1e-4, "%.3f")
  psiis = (pis == "") ? "" : rate(dl("psi.io.some", pis), 1e-4, "%.3f")
  psiif = (pif == "") ? "" : rate(dl("psi.io.full", pif), 1e-4, "%.3f")
  # --- disk
  dri = dwi = drk = dwk = dut = daw = ""
  while ((getline l < "/proc/diskstats") > 0) {
    split(l, a, " ")
    if (a[3] != DISK) continue
    xr = dl("dk.r", a[4]); xw = dl("dk.w", a[8]); xrs = dl("dk.rs", a[6]); xws = dl("dk.ws", a[10])
    xrm = dl("dk.rms", a[7]); xwm = dl("dk.wms", a[11]); xio = dl("dk.io", a[13])
    dri = rate(xr, 1, "%.2f"); dwi = rate(xw, 1, "%.2f")
    drk = rate(xrs, 0.5, "%.1f"); dwk = rate(xws, 0.5, "%.1f")
    dut = rate(xio, 0.1, "%.2f")
    if (xr != "" && xw != "" && xrm != "" && xwm != "" && xr + xw > 0) daw = sprintf("%.2f", (xrm + xwm) / (xr + xw))
  }
  close("/proc/diskstats")
  # --- cgroups v2 (system.slice/<unit>.service); a missing unit gives empty columns
  split("db php php2 cron web redis", CGN, " ")
  CGU["db"] = U_DB; CGU["php"] = U_PHP; CGU["php2"] = U_PHP2; CGU["cron"] = "cron"; CGU["web"] = U_WEB; CGU["redis"] = U_REDIS
  for (i = 1; i <= 6; i++) {
    k = CGN[i]; CGC[k] = CGM[k] = CGP[k] = ""
    if (CGU[k] == "") continue
    base = CGROOT "/" CGU[k] ".service/"
    u = ""
    while ((getline l < (base "cpu.stat")) > 0) if (l ~ /^usage_usec /) { split(l, a, " "); u = a[2] }
    close(base "cpu.stat")
    CGC[k] = (u == "") ? "" : rate(dl("cg.cpu." k, u), 1e-4, "%.2f")
    mc = rd(base "memory.current"); CGM[k] = (mc == "") ? "" : sprintf("%.0f", mc / 1048576)
    ps_ = psitot(base "memory.pressure", "some")
    CGP[k] = (ps_ == "") ? "" : rate(dl("cg.psi." k, ps_), 1e-4, "%.3f")
  }
  # --- FPM pools: children by PPID of the master of the site's PHP version (and of the second version)
  n1 = r1 = rss1 = act = n2 = 0
  for (pid in CPPID) {
    if (M1 != "" && CPPID[pid] == M1) {
      n1++; if (CST[pid] ~ /^R/) r1++; rss1 += CRSS[pid]
      l = rd("/proc/" pid "/stat")
      if (l != "") {
        sub(/^.*\) /, "", l); split(l, a, " ")
        tk = a[12] + a[13]                       # utime + stime (fields 14,15)
        NEW["fpmt." pid] = tk
        if (("fpmt." pid) in P) { if (tk != P["fpmt." pid]) act++ } else act++
      }
    } else if (M2 != "" && CPPID[pid] == M2) n2++
  }
  NEW["m1"] = (M1 == "") ? "none" : M1
  NEW["m2"] = (M2 == "") ? "none" : M2
  NEW["web"] = (WEBM == "") ? "none" : WEBM
  if (P["boot"] == BOOT) {
    if (("m1" in P) && P["m1"] != NEW["m1"]) print "EV,php" V1 "-fpm master pid changed " P["m1"] " -> " NEW["m1"]
    if (V2 != "" && ("m2" in P) && P["m2"] != NEW["m2"]) print "EV,php" V2 "-fpm master pid changed " P["m2"] " -> " NEW["m2"]
    if (("web" in P) && P["web"] != NEW["web"]) print "EV,web server master pid changed " P["web"] " -> " NEW["web"]
  }
  # --- network counters (/proc/net/netstat + /proc/net/snmp; not nstat, which writes a history file)
  loadnet("/proc/net/netstat"); loadnet("/proc/net/snmp")
  ldd = dnet("net.ld", "TcpExt.ListenDrops"); lod = dnet("net.lo", "TcpExt.ListenOverflows")
  rqd = dnet("net.rq", "TcpExt.TCPReqQFullDoCookies"); srd = dnet("net.sr", "TcpExt.TCPSynRetrans")
  pod = dnet("net.po", "Tcp.PassiveOpens"); rsd = dnet("net.rs", "Tcp.RetransSegs"); osd = dnet("net.os", "Tcp.OutSegs")
  # --- client RTT (values only)
  p50 = p90 = ""
  if (NRTT > 0) { asort(RTT); p50 = RTT[int((50 * NRTT + 99) / 100)]; p90 = RTT[int((90 * NRTT + 99) / 100)] }

  printf "A,%s,%s,%s,%s,%s", la[1], la[2], la[3], pr, pb
  printf ",%s,%s,%s,%s,%s,%s", pct(cu, dtot), pct(cs, dtot), pct(ci, dtot), pct(csi, dtot), pct(cst, dtot), pct(cid, dtot)
  printf ",%.0f,%.0f,%.0f,%.1f,%.0f", MI["MemAvailable"] / 1024, MI["MemFree"] / 1024, MI["Cached"] / 1024, MI["Dirty"] / 1024, (MI["SwapTotal"] - MI["SwapFree"]) / 1024
  printf ",%s,%s,%s,%s,%s", swi, swo, pgf, ast, rff
  printf ",%s,%s,%s,%s,%s", psics, psims, psimf, psiis, psiif
  printf ",%s,%s,%s,%s,%s,%s", dri, dwi, drk, dwk, dut, daw
  printf ",%s,%s,%s,%s,%s,%s", CGC["db"], CGC["php"], CGC["php2"], CGC["cron"], CGC["web"], CGC["redis"]
  printf ",%s,%s,%s,%s,%s", CGM["db"], CGM["php"], CGM["cron"], CGP["php"], CGP["db"]
  printf ",%s,%s,%s,%s,%s", (M1 == "" ? "" : n1), (M1 == "" ? "" : r1), (VALID && M1 != "" ? act : ""), (M1 == "" ? "" : sprintf("%.0f", rss1 / 1024)), LQ1
  printf ",%s,%s,%s\n", (M2 == "" ? "" : n2), LQ2, (DBRSS == "" ? "" : sprintf("%.0f", DBRSS / 1024))
  printf "C,%d,%d,%d,%d,%d,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%d,%d\n", E443, E80, SYNR, TW, AQ443, p50, p90, NRTT, ldd, lod, rqd, srd, pod, rsd, osd, CRONP, ADHOC

  if (FPMMAX + 0 > 0 && n1 >= 0.8 * FPMMAX) print "TH,fpm_children_ge80pct," n1
  if (LQ1 + 0 > 0) print "TH,fpm_listen_q," LQ1
  if (psimf != "" && psimf + 0 > 1) print "TH,psi_mem_full," psimf
  if (swo != "" && swo + 0 > 0) print "TH,pswpout_s," swo
  if (SYNR + 0 > SYNTH + 0) print "TH,tcp_synrecv," SYNR
  if (ldd != "" && ldd + 0 > 0) print "TH,listen_drops_d," ldd

  for (k in NEW) print k, NEW[k] > NEWF
  close(NEWF)
}
AWK

# ------------------------------------------------------------------------------------------------
ev() {  # append one line to events.log
  local ts; printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  printf '%s %s\n' "$ts" "$*" >> "$EVLOG"
}

blanks() {  # blanks <n> <var>: n empty CSV fields
  local s="" i; for (( i = 1; i < $1; i++ )); do s+=","; done; printf -v "$2" '%s' "$s"
}

remove_cron_now() {  # remove only our marked lines; never touch a crontab we cannot read
  local cur rc
  cur=$(crontab -l 2>/dev/null); rc=$?
  if (( rc != 0 )); then
    ev "crontab: none installed or not readable (nothing removed)"
  elif [[ $cur != *"$MARK"* ]]; then
    ev "crontab: no monitor lines present"
  elif printf '%s\n' "$cur" | { grep -vF "$MARK" || true; } | crontab -; then
    ev "crontab: monitor lines removed"
  else
    ev "crontab: removing monitor lines FAILED - retried hourly; or remove by hand: crontab -e, delete the lines ending in $MARK"
  fi
  return 0
}
remove_cron() {  # under state/cron.lock; if the lock file cannot be opened, remove without it
  { flock -w 20 9 || true; remove_cron_now; } 9>>"$S/cron.lock" \
    || { ev "crontab: cannot open state/cron.lock - removing without the lock"; remove_cron_now; }
}
drop_jar() { rm -f -- "$S/jar"; }  # the jar holds a live guest session cookie

END_EPOCH=""
guard() {  # self-expiry; called first by metrics and ttfb
  local now reason="" kb sz
  printf -v now '%(%s)T' -1
  if [[ -r $D/END_EPOCH ]] && read -r END_EPOCH < "$D/END_EPOCH" && [[ $END_EPOCH =~ ^[0-9]{9,11}$ ]]; then
    if (( now >= END_EPOCH )); then reason="END_EPOCH reached"
    elif (( END_EPOCH - now > MAX_AHEAD )); then reason="END_EPOCH implausible (more than 8 days ahead)"
    fi
  else
    reason="END_EPOCH missing or invalid"
  fi
  if [[ -z $reason ]]; then
    kb=$(du -sk "$D" 2>/dev/null); kb=${kb%%[[:space:]]*}
    [[ $kb =~ ^[0-9]+$ ]] && (( kb > MAX_DIR_KB )) && reason="data dir over 100 MB (${kb} KB)"
  fi
  if [[ -z $reason && -f $ERR ]]; then
    sz=$(stat -c %s "$ERR" 2>/dev/null)
    [[ $sz =~ ^[0-9]+$ ]] && (( sz > MAX_ERR_BYTES )) && reason="monitor.err over 1 MB (${sz} B)"
  fi
  if [[ -n $reason ]]; then
    [[ -d $S ]] || mkdir -p "$S"
    drop_jar
    # If the lines could not be removed, cron keeps starting us every minute: retry the removal (and log) at most
    # once per hour instead of adding two events.log lines a minute.
    if [[ -f $S/stopped ]] && (( now - $(stat -c %Y "$S/stopped" 2>/dev/null || echo 0) < 3600 )); then exit 0; fi
    : > "$S/stopped"
    remove_cron
    ev "stopped $reason"
    exit 0
  fi
  [[ -d $S ]] || mkdir -p "$S"
  [[ -e $S/stopped ]] && rm -f -- "$S/stopped"   # running again (END_EPOCH was extended)
  [[ -d $D/snap ]] || mkdir -p "$D/snap"
}

check_boot() {
  local b=$1 pb=""
  [[ -f $S/boot ]] && read -r pb < "$S/boot"
  if [[ -z $pb ]]; then
    ev "started (boot ${b:0:8}, END_EPOCH $END_EPOCH)"
    printf '%s\n' "$b" > "$S/boot"
  elif [[ $pb != "$b" ]]; then
    ev "boot_id changed ${pb:0:8} -> ${b:0:8} (reboot; deltas reset)"
    printf '%s\n' "$b" > "$S/boot"
  fi
}

maybe_snap() {  # snap/<ts>.txt, at most once per SNAP_MIN_GAP seconds
  local reason=$1 now last=0 ts f
  printf -v now '%(%s)T' -1
  [[ -f $S/last_snap ]] && read -r last < "$S/last_snap"
  [[ $last =~ ^[0-9]+$ ]] || last=0
  (( now - last < SNAP_MIN_GAP )) && return 0
  printf '%s\n' "$now" > "$S/last_snap"
  printf -v ts '%(%Y%m%d-%H%M%S)T' "$now"
  f=$D/snap/$ts.txt
  {
    printf '# snapshot %(%Y-%m-%d %H:%M:%S %z)T\n# reason: %s\n\n' "$now" "$reason"
    echo '## ps -eo pid,ppid,user,stat,etimes,pcpu,rss,comm --sort=-pcpu | head -25'
    ps -eo pid,ppid,user,stat,etimes,pcpu,rss,comm --sort=-pcpu | head -25
    printf '\n## ss -s\n'
    ss -s
    printf '\n## DB PROCESSLIST aggregate by COMMAND, STATE (own DB user, no INFO; from the last dbstat.php run)\n'
    cat "$S/pl.cur" 2>/dev/null || echo '(not available)'
  } > "$f" 2>&1
  ev "snapshot snap/$ts.txt ($reason)"
}

thresholds() {  # thresholds <db_ok 0|1> ["name,value" ...] - edge-triggered events + snapshot
  local dbok=$1 x name; shift
  local -A cur=() old=()
  for x in "$@"; do cur[${x%%,*}]=${x#*,}; done
  if [[ -f $S/th.active ]]; then
    while IFS= read -r name; do [[ -n $name ]] && old[$name]=1; done < "$S/th.active"
  fi
  # dbstat failed this minute: keep a DB threshold in its previous state instead of "clearing" it
  if (( ! dbok )) && [[ -n ${old[my_run_max]:-} && -z ${cur[my_run_max]:-} ]]; then cur[my_run_max]=unknown; fi
  for name in "${!cur[@]}"; do [[ -n ${old[$name]:-} ]] || ev "threshold $name crossed (value ${cur[$name]})"; done
  for name in "${!old[@]}"; do [[ -n ${cur[$name]:-} ]] || ev "threshold $name cleared"; done
  if (( ${#cur[@]} )); then printf '%s\n' "${!cur[@]}" > "$S/th.active"; else : > "$S/th.active"; fi
  if (( ${#cur[@]} )); then maybe_snap "threshold: ${!cur[*]}"; fi
}

CRONF=","
cron_log_counts() {  # sets CRONF="<n_ge10s>,<n_failed>" from bytes appended since the stored offset
  CRONF=","
  [[ -n $CRONLOG ]] || return 0
  local st ino size pino="" poff="" ost oino=0 osize=0 old=$CRONLOG.1 start=0 total useold=0 res
  st=$(stat -Lc '%i %s' "$CRONLOG" 2>/dev/null) || { echo "run.sh: cannot stat $CRONLOG" >&2; return 0; }
  set -- $st; ino=$1; size=$2
  [[ -f $S/cronlog.off ]] && read -r pino poff < "$S/cronlog.off"
  if [[ ! $pino =~ ^[0-9]+$ || ! $poff =~ ^[0-9]+$ ]]; then
    printf '%s %s\n' "$ino" "$size" > "$S/cronlog.off"      # first call: baseline only
    return 0
  fi
  if [[ $ino == "$pino" ]]; then
    (( size < poff )) && poff=0                                # truncated / shrank: start over
    start=$poff
    total=$(( size - start ))
  else                                                         # rotated: finish .1 if it is our old file
    ost=$(stat -Lc '%i %s' "$old" 2>/dev/null) && { set -- $ost; oino=$1; osize=$2; }
    if [[ $oino == "$pino" ]] && (( osize >= poff )); then useold=1; fi
    start=0
    total=$(( size + (useold ? osize - poff : 0) ))
  fi
  if (( total > 33554432 )); then
    ev "cron log: $total new bytes (>32 MB) - interval skipped, offset reset"
    printf '%s %s\n' "$ino" "$size" > "$S/cronlog.off"
    return 0
  fi
  res=$( {
      (( useold )) && tail -c +$(( poff + 1 )) "$old" | head -c $(( osize - poff ))
      tail -c +$(( start + 1 )) "$CRONLOG" | head -c $(( size - start ))
    } | gawk 'BEGIN { n10 = 0; nf = 0; part = 0 }
              RT == "" { part = length($0); next }            # incomplete last line: re-read next time
              /^\.\.\. used [0-9.Ee+-]+ seconds/ { if ($3 + 0 >= 10) n10++ }
              /Scheduled task failed/ { nf++ }
              END { print n10, nf, part }' )
  set -- $res
  if [[ ${1:-} =~ ^[0-9]+$ && ${3:-} =~ ^[0-9]+$ ]]; then
    CRONF="$1,$2"
    local newoff=$(( size - $3 ))
    (( newoff < start )) && newoff=$start
    printf '%s %s\n' "$ino" "$newoff" > "$S/cronlog.off"
  else
    echo "run.sh: cron log parse failed" >&2
  fi
}

# ------------------------------------------------------------------------------------------------
metrics() {
  guard
  # Serialise with a manual "run.sh metrics" (both write state/*.prev). This is a separate lock file: cron
  # already holds state/m.lock through flock(1), and a second open of that file would conflict with it.
  exec 8>>"$S/metrics.lock" || return 0
  flock -n 8 || return 0
  local t0=$EPOCHREALTIME now tsl min boot="" do5="" phppid f line tag rest row commas
  local A="" B="" C="" U="" dbok=1
  local -a TH=()
  now=${t0%.*}
  printf -v tsl '%(%Y-%m-%d %H:%M:%S)T' "$now"
  printf -v min '%(%M)T' "$now"
  (( 10#$min % 5 == 0 )) && do5=1
  [[ -n ${MON_TEST_ALL5:-} ]] && do5=1          # test-only knob (never set by cron)
  read -r boot < /proc/sys/kernel/random/boot_id || boot=unknown
  check_boot "$boot"

  "$PHP" "${PHP_ARGS[@]}" "$D/dbstat.php" --dir="$D" --boot="$boot" "${DBSTAT_ARGS[@]}" ${do5:+--users} > "$S/db.out" 2>>"$ERR" &
  phppid=$!

  { echo '##PS'; ps -e -ww -o pid=,ppid=,stat=,rss=,args=
    echo '##SS'; ss -Htani
    echo '##SSL'; ss -Hlnxt; } 2>>"$ERR" \
    | gawk -v NOW="$t0" -v BOOT="$boot" -v PREV="$S/sys.prev" -v NEWF="$S/sys.new" \
           -v DISK="$DISK" -v CGROOT=/sys/fs/cgroup/system.slice -v V1="$PHPV" -v V2="$PHPV2" \
           -v SOCK1="$FPM_SOCK" -v SOCK2="$FPM_SOCK2" -v FPMMAX="$FPM_MAX" -v SYNTH="$SYN_TH" \
           -v U_DB="$DB_UNIT" -v U_PHP="${PHPV:+php$PHPV-fpm}" -v U_PHP2="${PHPV2:+php$PHPV2-fpm}" \
           -v U_WEB="$WEB_UNIT" -v U_REDIS="$REDIS_UNIT" "$AWK_COLLECT" > "$S/sys.out" 2>>"$ERR"
  [[ -s $S/sys.new ]] && mv -f "$S/sys.new" "$S/sys.prev"

  [[ -n $do5 ]] && cron_log_counts 2>>"$ERR"
  wait "$phppid"

  for f in "$S/sys.out" "$S/db.out"; do
    [[ -f $f ]] || continue
    while IFS= read -r line; do
      tag=${line%%,*}; rest=${line#*,}
      case $tag in
        A) A=$rest ;; B) B=$rest ;; C) C=$rest ;; U) U=$rest ;;
        EV) ev "$rest" ;; TH) TH+=("$rest") ;;
      esac
    done < "$f"
  done
  [[ -n ${MON_TEST_TH:-} ]] && TH+=("$MON_TEST_TH")   # test-only knob, e.g. "fake,1"
  [[ -n $A ]] || { blanks 51 A; echo "run.sh: collector produced no A line" >> "$ERR"; }
  [[ -n $C ]] || { blanks 17 C; echo "run.sh: collector produced no C line" >> "$ERR"; }
  [[ -n $B ]] || blanks 22 B
  [[ -n ${B%%,*} ]] || dbok=0                       # my_uptime empty: the DB server was not sampled
  [[ -n $do5 ]] || { U=""; CRONF=","; }

  row="$now,$tsl,${boot:0:8},$A,$B,$C,$U,$CRONF"
  commas=${row//[^,]/}
  if (( ${#commas} + 1 != N_METRICS )); then
    echo "run.sh: $tsl row has $(( ${#commas} + 1 )) fields, expected $N_METRICS - row not written" >> "$ERR"
    return 0
  fi
  [[ -s $D/metrics.csv ]] || printf '%s\n' "$HDR_METRICS" > "$D/metrics.csv"
  printf '%s\n' "$row" >> "$D/metrics.csv"
  thresholds "$dbok" "${TH[@]}"
}

US=0
to_us() {  # seconds "1.234567" -> microseconds in US (-1 if not a number)
  if [[ $1 =~ ^([0-9]+)(\.([0-9]*))?$ ]]; then
    local f=${BASH_REMATCH[3]}000000
    US=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${f:0:6} ))
  else
    US=-1
  fi
}

ttfb() {
  guard
  local i ts tsl out rc slow="" hostport
  local -a F RES=()
  [[ -n $BASE_URL ]] || { echo "run.sh: BASE_URL not set in monitor.env" >> "$ERR"; return 0; }
  if [[ -n $PROBE_RESOLVE ]]; then
    hostport=${BASE_URL#*://}; hostport=${hostport%%/*}
    [[ $hostport == *:* ]] || { [[ $BASE_URL == https:* ]] && hostport=$hostport:443 || hostport=$hostport:80; }
    RES=(--resolve "$hostport:$PROBE_RESOLVE")
  fi
  [[ -s $D/ttfb.csv ]] || printf '%s\n' "$HDR_TTFB" > "$D/ttfb.csv"
  for i in "${!P_PATHS[@]}"; do
    (( i > 0 )) && sleep 3
    ts=${EPOCHREALTIME%.*}
    printf -v tsl '%(%Y-%m-%d %H:%M:%S)T' "$ts"
    out=$(curl -sS -o /dev/null --compressed -A "$UA" -b "$S/jar" -c "$S/jar" "${RES[@]}" \
      --max-time 30 -w '%{http_code},%{http_version},%{time_namelookup},%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total},%{size_download},%{num_connects}' \
      "${BASE_URL%/}${P_PATHS[i]}" 2>>"$ERR")
    rc=$?
    [[ $out =~ ^[0-9]{3},[0-9.]*,[0-9.]+,[0-9.]+,[0-9.]+,[0-9.]+,[0-9.]+,[0-9]+,[0-9]+$ ]] || out=",,,,,,,,"
    printf '%s\n' "$ts,$tsl,${P_LABELS[i]:-p$i},$out,$rc" >> "$D/ttfb.csv"
    IFS=, read -r -a F <<< "$out"
    to_us "${F[5]:-}"
    if (( rc != 0 )); then
      ev "ttfb ${P_LABELS[i]:-p$i} failed (curl_exit $rc, http_code ${F[0]:-})"
      slow+=" ${P_LABELS[i]:-p$i}"
    elif (( US > 3000000 )); then
      ev "threshold ttfb_gt3s crossed (${P_LABELS[i]:-p$i} t_ttfb ${F[5]} s, http ${F[0]})"
      slow+=" ${P_LABELS[i]:-p$i}"
    fi
  done
  [[ -n $slow ]] && maybe_snap "ttfb over 3 s or failed:$slow"
  # A stop may have happened while this cycle ran; curl -c would have recreated the jar.
  crontab -l 2>/dev/null | grep -qF "$MARK" || drop_jar
  return 0
}

status() {
  local now end left
  printf -v now '%(%s)T' -1
  echo "data dir      : $D"
  if [[ -r $D/END_EPOCH ]] && read -r end < "$D/END_EPOCH" && [[ $end =~ ^[0-9]+$ ]]; then
    if (( end > now )); then left="$(( (end - now) / 3600 ))h $(( (end - now) % 3600 / 60 ))m left"; else left="expired"; fi
    printf 'END_EPOCH     : %s (%(%Y-%m-%d %H:%M %z)T) - %s\n' "$end" "$end" "$left"
  else
    echo "END_EPOCH     : missing or invalid (runs will stop themselves)"
  fi
  echo "crontab lines : $(crontab -l 2>/dev/null | grep -cF "$MARK") with '$MARK'"
  if [[ -f $D/metrics.csv ]]; then
    echo "metrics.csv   : $(( $(wc -l < "$D/metrics.csv") - 1 )) rows, last at $(tail -n 1 "$D/metrics.csv" | cut -d, -f2)"
  else echo "metrics.csv   : none yet"; fi
  if [[ -f $D/ttfb.csv ]]; then
    echo "ttfb.csv      : $(( $(wc -l < "$D/ttfb.csv") - 1 )) rows; last cycle (label,code,t_ttfb,t_total):"
    tail -n "${#P_PATHS[@]}" "$D/ttfb.csv" | cut -d, -f2-4,9,10 | sed 's/^/                /'
  else echo "ttfb.csv      : none yet"; fi
  echo "snapshots     : $(find "$D/snap" -type f 2>/dev/null | wc -l)"
  echo "disk use      : $(du -sh "$D" 2>/dev/null | cut -f1); monitor.err $(stat -c %s "$ERR" 2>/dev/null || echo 0) bytes"
  echo "--- last events:"
  tail -n 10 "$EVLOG" 2>/dev/null || echo "(none)"
}

case ${1:-} in
  metrics) metrics ;;
  ttfb)    ttfb ;;
  stop)    [[ -d $S ]] || mkdir -p "$S"; drop_jar; remove_cron; ev "stopped manual (run.sh stop)" ;;
  status)  status ;;
  *) echo "usage: $0 metrics|ttfb|stop|status" >&2; exit 2 ;;
esac
exit 0
