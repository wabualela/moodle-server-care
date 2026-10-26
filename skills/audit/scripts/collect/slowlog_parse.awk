# slowlog_parse.awk -- PHP-FPM slow-log parser (collector step R-PHP-03).
#   gawk -f lib_norm.awk -f slowlog_parse.awk -v outdir=<dir> [-v cutoff=<epoch>]
#        [-v reqmap=<file from fpmlog_agg.awk mode=reqmap>] <the pool's slowlog file>
#
# An entry looks like this:
#   [15-Oct-2026 23:22:58]  [pool www] pid 12345
#   script_filename = /var/www/moodle/public/index.php
#   [0x00007f...] usleep() /var/www/moodle/public/lib/classes/session/redis.php:486
#   ...
# Frames run innermost first.  The file:line on a frame is the place where that
# function was called.
#
# Outputs: slow_daily.tsv slow_hourly.tsv slow_top_scripts.tsv
#          slow_top_innerframe.tsv slow_top_appframe.tsv
#          slow_script_x_appframe.tsv slow_wait_class.tsv
# Also: slow_entries.tsv (one row per entry: time, pool, script,
#          request, detect_sec, wait_class, first app frame, SMTP caller),
#          slow_wait_x_request.tsv, slow_lockwait_by_request.tsv, slow_meta.tsv
#
# Details:
#   - cutoff: entries older than the --days window are skipped (counted in
#     slow_meta.tsv).  FPM slow logs are often never rotated, so without
#     this the slow_*.tsv files would cover all time.
#   - SMTP wait class: an entry whose innermost 4 frames include a PHPMailer
#     file (vendor/phpmailer or lib/phpmailer) is SMTP (synchronous mail send:
#     stream_socket_client connect, fgets/fwrite on the SMTP stream, STARTTLS).
#     Without this class they show up as FILE_IO or CPU_OTHER.
#   - request join: the slow log has no request line, so each entry is joined
#     to the FPM master log's "child <pid> ... (request: ...) executing too
#     slow" warning with the same pid within +-3 s (reqmap, built by
#     fpmlog_agg.awk mode=reqmap from ALL rotated FPM master logs, not only the
#     --days window; only the slow-log entries are cut at -v cutoff, and
#     a map line outside the window simply never matches).  The request is
#     the normalised METHOD path[?info=..] (no query string).  Session-lock
#     waits are thereby keyed by the request that waited, instead of the
#     generic "start lib/setup.php" frame.

BEGIN {
    lib_init()
    if (outdir == "") { print "slowlog_parse: -v outdir= is required" > "/dev/stderr"; _noout = 1; exit 2 }
    T = "\t"
    cutoff += 0
    inentry = 0; skipping = 0
    nmap = 0
    if (reqmap != "") {
        while ((getline l < reqmap) > 0) {
            if (split(l, a, "\t") < 4) continue
            RM[a[1] SUBSEP a[2]] = a[3]; RD[a[1] SUBSEP a[2]] = a[4]; nmap++
        }
        close(reqmap)
    }
    F_ENT = outdir "/slow_entries.tsv"
    print "time" T "pool" T "script" T "request" T "detect_sec" T "wait_class" T "first_app_frame" T "smtp_caller" > F_ENT
}

function frame_str(i) { return FN[i] " " relpath(FF[i]) ":" FL[i] }

function is_skip(i,    f, fn) {
    f = FF[i]; fn = FN[i]
    if (f ~ /\/lib\/dml\// || f ~ /\/lib\/classes\/session\// || f ~ /\/cache\/stores\//) return 1
    if (fn ~ /^mysqli/ || fn ~ /^curl_exec/ || fn ~ /^u?sleep$/ || fn ~ /^Redis->/ || fn ~ /^fread$/ || fn ~ /^stream_/) return 1
    return 0
}

function is_mailer(i) { return (FF[i] ~ /\/phpmailer\//) }

# Wait class from the innermost frame.  FPM prints only the function name
# (no class), and the file:line is the call site, so the class is decided
# mostly from the call-site file.
function wait_class(    fn, f, i, lim) {
    if (NFR == 0) return "NO_FRAMES"
    fn = FN[1]; f = FF[1]
    if (fn ~ /core\\session\\redis/) return "SESSION_LOCK"
    if (fn ~ /^u?sleep$/) {
        lim = (NFR < 3) ? NFR : 3
        for (i = 1; i <= lim; i++) if (FF[i] ~ /\/lib\/classes\/session\//) return "SESSION_LOCK"
    }
    if (f ~ /\/lib\/classes\/session\// && fn ~ /lock/) return "SESSION_LOCK"
    lim = (NFR < 4) ? NFR : 4
    for (i = 1; i <= lim; i++) if (is_mailer(i)) return "SMTP"
    if (fn ~ /^mysqli/ || f ~ /\/lib\/dml\//) return "DB"
    if (fn ~ /^curl_(exec|multi_exec|multi_select)$/) return "HTTP_OUT"
    if (fn ~ /^Redis->/ || f ~ /\/cache\/stores\/redis\// || f ~ /\/lib\/classes\/session\/redis\.php$/) return "REDIS"
    if (fn ~ /^(fread|fwrite|fopen|fclose|fgets|fgetcsv|fpassthru|readfile|file_get_contents|file_put_contents|file|flock|stream_.*|unlink|rename|copy|opendir|readdir|scandir|glob|is_file|is_dir|is_readable|is_writable|file_exists|filemtime|filesize|mkdir|rmdir|touch|gzread|gzopen|move_uploaded_file|realpath|stat|lstat|clearstatcache)$/) return "FILE_IO"
    return "CPU_OTHER"
}

# For SMTP entries: the code that asked for the mail.  Starts at the caller
# of the innermost email_to_user() and skips the generic message/hook/mailer
# layers, so a signup shows send_confirmation_email and a self-enrol shows the
# enrol plugin frame.
function smtp_caller(    i, j, start) {
    start = 0
    for (i = 1; i <= NFR; i++) if (FN[i] == "email_to_user") { start = i + 1; break }
    if (!start) start = 1
    for (j = start; j <= NFR; j++) {
        if (is_mailer(j)) continue
        if (FF[j] ~ /\/lib\/classes\/message\/|\/lib\/messagelib\.php|\/message\/output\/|\/lib\/classes\/hook\/|\/lib\/moodlelib\.php/) continue
        return frame_str(j)
    }
    return "<none>"
}

function join_req(    k, d, key) {
    JREQ = "<unjoined>"; JDET = ""
    if (!nmap || epid == "") return 0
    for (k = 0; k <= 6; k++) {
        d = (k % 2) ? -int((k + 1) / 2) : int(k / 2)   # 0, -1, +1, -2, +2, -3, +3
        key = (eep + d) SUBSEP epid
        if (key in RM) { JREQ = RM[key]; JDET = RD[key]; return 1 }
    }
    return 0
}

function finish(    i, app, wc, sc, req, sm) {
    if (!inentry) return
    inentry = 0
    nent++
    DAY[eday]++
    HOUR[ehour]++
    sc = (escript == "") ? "<none>" : relpath(escript)
    SCR[sc]++
    if (NFR > 0) INNER[frame_str(1)]++
    app = "<none>"
    for (i = 1; i <= NFR; i++) if (!is_skip(i)) { app = frame_str(i); break }
    APP[app]++
    SXA[sc T app]++
    wc = wait_class()
    WC[eday T wc]++
    WCT[wc]++
    if (join_req()) joined++; else unjoined++
    req = JREQ
    sm = (wc == "SMTP") ? smtp_caller() : ""
    gsub(/\t/, " ", app); gsub(/\t/, " ", sm)
    print etime T epool T sc T req T JDET T wc T app T sm > F_ENT
    WXR[wc T req]++
    if (wc == "SESSION_LOCK") {
        LW[req]++
        if (!(req in LWF)) LWF[req] = etime
        LWL[req] = etime
        if (JDET != "" && JDET + 0 > LWM[req] + 0) LWM[req] = JDET
    }
}

/^\[[0-9]{2}-[A-Za-z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\][ ]+\[pool / {
    finish()
    skipping = 0
    if (!match($0, /^\[([0-9]{2})-([A-Za-z]{3})-([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2})\]/, t) || !(t[2] in MON)) { bad++; next }
    eep = mktime(t[3] " " MON[t[2]] " " t[1] " " t[4] " " t[5] " " t[6])
    if (cutoff && eep < cutoff) { skipped++; skipping = 1; next }
    eday = sprintf("%04d-%02d-%02d", t[3], MON[t[2]], t[1])
    ehour = eday " " t[4]
    etime = eday " " t[4] ":" t[5] ":" t[6]
    epool = "-"; epid = ""
    if (match($0, /\[pool ([A-Za-z0-9_.-]+)\]/, pm)) epool = pm[1]
    if (match($0, / pid ([0-9]+)/, pp)) epid = pp[1]
    escript = ""; NFR = 0; delete FN; delete FF; delete FL
    inentry = 1
    next
}
skipping && (/^script_filename = / || /^\[0x[0-9a-fA-F]+\] /) { next }
inentry && /^script_filename = / { escript = substr($0, 19); next }
inentry && /^\[0x[0-9a-fA-F]+\] / {
    line = $0
    sub(/^\[0x[0-9a-fA-F]+\] /, "", line)
    if (match(line, /^(.*) ([^ ]+):([0-9]+)$/, m)) {
        NFR++
        fn = m[1]; sub(/\(\)$/, "", fn)
        FN[NFR] = fn; FF[NFR] = m[2]; FL[NFR] = m[3]
    } else badframe++
    next
}
/^[[:space:]]*$/ { next }
{ other++ }

function dump(arr, file, hdr, limit,    ord, n, i) {
    print hdr > file
    n = asorti(arr, ord, "@val_num_desc")
    for (i = 1; i <= n && (limit == 0 || i <= limit); i++) print ord[i] T arr[ord[i]] > file
}

END {
    if (_noout) exit 2     # BEGIN refused (no outdir): END must not write to "/<file>"
    finish()
    print "day" T "entries" > (outdir "/slow_daily.tsv")
    n = asorti(DAY, o); for (i = 1; i <= n; i++) print o[i] T DAY[o[i]] > (outdir "/slow_daily.tsv")
    print "hour" T "entries" > (outdir "/slow_hourly.tsv")
    n = asorti(HOUR, o); for (i = 1; i <= n; i++) print o[i] T HOUR[o[i]] > (outdir "/slow_hourly.tsv")
    dump(SCR,   outdir "/slow_top_scripts.tsv",    "script" T "entries", 30)
    dump(INNER, outdir "/slow_top_innerframe.tsv", "innermost_frame" T "entries", 40)
    dump(APP,   outdir "/slow_top_appframe.tsv",   "first_app_frame" T "entries", 40)
    dump(SXA,   outdir "/slow_script_x_appframe.tsv", "script" T "first_app_frame" T "entries", 40)
    f = outdir "/slow_wait_class.tsv"
    print "day" T "wait_class" T "entries" > f
    n = asorti(WC, o); for (i = 1; i <= n; i++) print o[i] T WC[o[i]] > f
    n = asorti(WCT, o); for (i = 1; i <= n; i++) print "ALL" T o[i] T WCT[o[i]] > f
    dump(WXR, outdir "/slow_wait_x_request.tsv", "wait_class" T "request" T "entries", 0)
    f = outdir "/slow_lockwait_by_request.tsv"
    print "request" T "entries" T "first_time" T "last_time" T "max_detect_sec" > f
    n = asorti(LW, o, "@val_num_desc")
    for (i = 1; i <= n; i++) print o[i] T LW[o[i]] T LWF[o[i]] T LWL[o[i]] T LWM[o[i]] > f
    f = outdir "/slow_meta.tsv"
    print "key" T "value" > f
    print "cutoff_epoch" T cutoff T (cutoff ? strftime("%Y-%m-%d %H:%M:%S %z", cutoff) : "none (all entries)") > f
    print "entries_in_window" T nent + 0 > f
    print "entries_skipped_before_cutoff" T skipped + 0 > f
    print "reqmap_lines" T nmap > f
    print "entries_joined_to_request" T joined + 0 > f
    print "entries_unjoined" T unjoined + 0 > f
    printf "slowlog_parse: entries=%d bad_header=%d bad_frame=%d other_lines=%d skipped_before_cutoff=%d joined=%d unjoined=%d\n",
        nent, bad, badframe, other, skipped, joined, unjoined
}
