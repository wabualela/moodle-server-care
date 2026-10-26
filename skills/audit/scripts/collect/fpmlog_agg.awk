# fpmlog_agg.awk -- PHP-FPM master log (php8.x-fpm.log) sanitiser and aggregator
# (collector steps R-PHP-01 and R-PHP-02).
#
#   mode=sanitize : prints the log with every `(request: "METHOD URI")` rewritten
#                   to `(request: "METHOD <normalised path>[?info=..|?wsfunction=..]")`.
#                   The match is greedy, so a raw '"' inside the URI cannot end
#                   it early, and a request field that still cannot be parsed
#                   becomes (request: "<unparsed>").  Text after
#                   "said into stderr: " (catch_workers_output) is scrubbed
#                   like PHP messages (W9).  Pipe the result through mask.sed.
#   mode=agg      : writes <outdir>/fpm_events_hourly.tsv,
#                   <outdir>/fpm_tooslow_top.tsv and <outdir>/fpm_seems_busy.tsv
#                   (prefix comes from -v prefix=fpm).
#   mode=reqmap   : prints one line per "executing too slow" warning:
#                   epoch <TAB> pid <TAB> METHOD normalised-path[?info=..] <TAB> detect_sec
#                   for slowlog_parse.awk -v reqmap= (joins each slow-log
#                   entry to its request by pid and time).  Only normalised
#                   paths are printed (no query string, no IP).
#
#   zcat -f logs | gawk -f lib_norm.awk -f fpmlog_agg.awk -v mode=agg -v outdir=DIR
#
# Note: the number in "executing too slow (N sec)" is the time at which the
# master DETECTED the request as slow (request_slowlog_timeout plus up to one
# check interval), not the request's duration.  The columns are named
# *_detect_sec to say so.  "seems busy" lines now also record the idle count:
# a line with idle > 0 is FPM topping up its spare workers, not pressure.

BEGIN {
    lib_init()
    T = "\t"
    if (mode == "") mode = "agg"
    if (prefix == "") prefix = "fpm"
    if (mode == "agg" && outdir == "") { print "fpmlog_agg: -v outdir= is required" > "/dev/stderr"; _noout = 1; exit 2 }
}

function sanitize_request(line,    pre, post, m, req, sp, meth, uri, np, extra) {
    while (match(line, /\(request: ".*"\)/)) {
        pre = substr(line, 1, RSTART - 1)
        post = substr(line, RSTART + RLENGTH)
        req = substr(line, RSTART + 11, RLENGTH - 13)
        sp = index(req, " ")
        if (sp) { meth = substr(req, 1, sp - 1); uri = substr(req, sp + 1) } else { meth = req; uri = "" }
        if (meth !~ /^[A-Z]+$/) meth = "-"
        np = normpath(uri)
        extra = (NP_AJ != "") ? "?info=" NP_AJ : ((NP_WS != "") ? "?wsfunction=" NP_WS : "")
        OUT = OUT pre "(request<: \"" meth " " np extra "\")"
        line = post
    }
    if (index(line, "(request: \"")) sub(/\(request: ".*$/, "(request: \"<unparsed>\")", line)
    OUT = OUT line
    gsub(/\(request<: /, "(request: ", OUT)
    return OUT
}

# W9: worker stderr (only logged when catch_workers_output is on).
function scrub_stderr(line,    p, msg, q) {
    p = index(line, "said into stderr: ")
    if (!p) return line
    msg = substr(line, p + 18)
    q = sub(/^"/, "", msg)
    if (q) q = sub(/"$/, "", msg)
    return substr(line, 1, p + 17) (q ? "\"" : "") scrub(msg) (q ? "\"" : "")
}

mode == "sanitize" {
    OUT = ""
    print scrub_stderr(sanitize_request($0))
    next
}

mode == "reqmap" {
    if (!match($0, /^\[([0-9]{2})-([A-Za-z]{3})-([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2})\]/, t) || !(t[2] in MON)) next
    if (!match($0, /child ([0-9]+), script '[^']*' \(request: "([A-Z]+) (.*)"\) executing too slow \(([0-9.]+) sec\)/, m)) next
    ep = mktime(t[3] " " MON[t[2]] " " t[1] " " t[4] " " t[5] " " t[6])
    rk = m[2] " " normpath(m[3]) ((NP_AJ != "") ? "?info=" NP_AJ : ((NP_WS != "") ? "?wsfunction=" NP_WS : ""))
    gsub(/\t/, " ", rk)
    print ep T m[1] T rk T m[4]
    next
}

# ---- aggregation
{
    if (!match($0, /^\[([0-9]{2})-([A-Za-z]{3})-([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2})\]/, t) || !(t[2] in MON)) { nodate++; next }
    h = sprintf("%04d-%02d-%02d %s", t[3], MON[t[2]], t[1], t[4])
    HOURS[h] = 1
    if (match($0, /spawning ([0-9]+) children, there are ([0-9]+) idle, and ([0-9]+) total children/, m)) {
        BUSY[h]++
        if (m[3] + 0 > BUSYMAX[h] + 0) BUSYMAX[h] = m[3]
        if (m[1] + 0 > SPAWNMAX[h] + 0) SPAWNMAX[h] = m[1]
        if (!(h in BUSYMINIDLE) || m[2] + 0 < BUSYMINIDLE[h] + 0) BUSYMINIDLE[h] = m[2]
        if (m[2] + 0 == 0) BUSYIDLE0[h]++
        pool = "-"
        if (match($0, /\[pool ([A-Za-z0-9_.-]+)\]/, pm)) pool = pm[1]
        nsb++
        SB[nsb] = sprintf("%04d-%02d-%02d %s:%s:%s", t[3], MON[t[2]], t[1], t[4], t[5], t[6]) T pool T m[1] T m[2] T m[3] T \
                  ((m[2] + 0 == 0) ? "yes" : "no (idle>0: spare top-up)")
    }
    if (match($0, /server reached (pm\.)?max_children setting \(([0-9]+)\)/, m)) { MAXC[h]++; MAXCV[h] = m[2] }
    if (match($0, /executing too slow \(([0-9.]+) sec\)/, m)) {
        SLOW[h]++
        if (m[1] + 0 > SLOWMAX[h] + 0) SLOWMAX[h] = m[1]
        scr = "<none>"
        if (match($0, /script '([^']*)'/, s)) scr = relpath(s[1])
        TS_C[scr]++; TS_S[scr] += m[1]; if (m[1] + 0 > TS_M[scr] + 0) TS_M[scr] = m[1]
        if (match($0, /\(request: "([A-Z]+) (.*)"\)/, rq)) {
            rk = rq[1] " " normpath(rq[2]) ((NP_AJ != "") ? "?info=" NP_AJ : ((NP_WS != "") ? "?wsfunction=" NP_WS : ""))
            TR_C[rk]++; TR_S[rk] += m[1]; if (m[1] + 0 > TR_M[rk] + 0) TR_M[rk] = m[1]
        }
    }
    if ($0 ~ /execution timed out/) TOUT[h]++
    if (match($0, /exited on signal ([0-9]+)/, m)) { SIG[h][m[1]]++ }
    if ($0 ~ /exited with code/) EXC[h]++
    if ($0 ~ /child [0-9]+ started/) SPAWN[h]++
    if ($0 ~ /ready to handle connections/) READY[h]++
    if ($0 ~ /has been killed by the process management/) KILLED[h]++
}

function v0(x) { return x == "" ? 0 : x }

function dumptop(kind, C, S, M, f,    ord, n, i) {
    n = asorti(C, ord, "@val_num_desc")
    for (i = 1; i <= n && i <= 30; i++)
        printf "%s\t%s\t%d\t%s\t%.3f\n", kind, ord[i], C[ord[i]], M[ord[i]], S[ord[i]] > f
}

END {
    if (_noout) exit 2     # BEGIN refused (no outdir): END must not write to "/<file>"
    if (mode != "agg") exit 0
    f = outdir "/" prefix "_events_hourly.tsv"
    print "hour" T "seems_busy" T "seems_busy_max_total_children" T "seems_busy_max_spawning" T "max_children_reached" T \
          "max_children_value" T "too_slow" T "too_slow_max_detect_sec" T "timed_out" T "exited_on_signal" T "exited_with_code" T \
          "spawned" T "killed_by_pm" T "master_ready" T "seems_busy_min_idle" T "seems_busy_idle0" > f
    n = asorti(HOURS, o)
    for (i = 1; i <= n; i++) {
        h = o[i]
        sigs = ""
        if (h in SIG) { ns = asorti(SIG[h], so); for (j = 1; j <= ns; j++) sigs = sigs (sigs == "" ? "" : ",") "sig" so[j] ":" SIG[h][so[j]] }
        print h T v0(BUSY[h]) T v0(BUSYMAX[h]) T v0(SPAWNMAX[h]) T v0(MAXC[h]) T MAXCV[h] T v0(SLOW[h]) T SLOWMAX[h] T \
              v0(TOUT[h]) T sigs T v0(EXC[h]) T v0(SPAWN[h]) T v0(KILLED[h]) T v0(READY[h]) T BUSYMINIDLE[h] T v0(BUSYIDLE0[h]) > f
    }
    f2 = outdir "/" prefix "_tooslow_top.tsv"
    # max/sum of the DETECTION times printed by FPM, not request durations
    print "kind" T "key" T "count" T "max_detect_sec" T "sum_detect_sec" > f2
    dumptop("script", TS_C, TS_S, TS_M, f2)
    dumptop("request", TR_C, TR_S, TR_M, f2)
    f3 = outdir "/" prefix "_seems_busy.tsv"
    print "time" T "pool" T "spawning" T "idle" T "total_children" T "pressure" > f3
    for (i = 1; i <= nsb; i++) print SB[i] > f3
    printf "fpmlog_agg: hours=%d lines_without_date=%d seems_busy=%d\n", n, nodate, nsb
}
