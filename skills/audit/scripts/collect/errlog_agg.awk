# errlog_agg.awk -- web server error-log aggregator (collector step R-WEB-03).
# Reads nginx error logs ("YYYY/MM/DD HH:MM:SS [level] pid#tid: ...") and
# Apache 2.4 error logs ("[Www Mmm DD HH:MM:SS.uuuuuu YYYY] [module:level] ...").
#   zcat -f <error logs oldest-first> | gawk -f lib_norm.awk -f errlog_agg.awk \
#        -v site=moodle -v cutoff=<epoch> -v outdir=<dir>/errors
# Appends to (the caller writes the header lines first):
#   error_types_daily.tsv    site day level count message   (top 100 per day)
#   error_hourly_counters.tsv site hour <counters...>
#   php_messages_top.tsv     site class count message         (top 50)
# Messages are normalised: timestamp, pid and *conn are stripped, and so is
# everything from ", client:" on (client, server, request, upstream, host,
# referrer).  PHP/FastCGI text is first scrubbed (lib_norm.awk scrub(): Moodle
# "Debug:" info dropped, quoted literals, query strings, var_export values and
# non-ASCII runs replaced).  Then the text is masked
# (maskfree), digits become N, and it is cut to 140 characters (200 for PHP
# messages).  nginx's own messages are not scrubbed, so their quoted file
# paths stay readable.  Apache lines lose their [pid ...] and [client ...]
# brackets and the ", referer: ..." tail before the same processing.

BEGIN {
    lib_init()
    T = "\t"
    cutoff += 0
    if (outdir == "") { print "errlog_agg: -v outdir= is required" > "/dev/stderr"; _noout = 1; exit 2 }
    # hourly counters (column order = the header the collector writes):
    # buffered_tmp_file upstream_timed_out fpm_connect_failed
    # resource_temp_unavailable upstream_prematurely_closed
    # primary_script_unknown fastcgi_stderr
    NC = 7
    CR[1] = "buffered to a temporary file"
    CR[2] = "upstream timed out|timeout specified has expired"
    CR[3] = "connect\\(\\) to unix:[^ ]* failed|connect\\(\\) failed .*while connecting to upstream|AH01079|AH02454"
    CR[4] = "Resource temporarily unavailable"
    CR[5] = "upstream prematurely closed|AH01067|Premature end of script headers"
    CR[6] = "Primary script unknown"
    CR[7] = "FastCGI sent in stderr|AH01071: Got error"
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", AMN, " ")
    for (i = 1; i <= 12; i++) AMON[AMN[i]] = i
    inwin = 0
}

function norm(s,    c) {
    sub(/, client: .*$/, "", s)
    # The PHP text is reported (scrubbed) in php_messages_top.tsv; the error
    # type keeps only nginx's frame and the PHP class.
    if (index(s, "FastCGI sent in stderr: ")) {
        c = php_class(s)
        if (!sub(/FastCGI sent in stderr: ".*" while /, "FastCGI sent in stderr: \"<php " c ">\" while ", s))
            sub(/FastCGI sent in stderr: .*$/, "FastCGI sent in stderr: \"<php " c ">\"", s)
    } else if (index(s, "PHP message:")) s = scrub(s)
    # nginx's own messages quote decoded request paths: drop non-ASCII runs
    gsub(/[\200-\377]+/, "<txt>", s)
    s = maskfree(s)
    gsub(/[0-9]+/, "N", s); gsub(/<ipN>/, "<ip6>", s)
    gsub(/\t/, " ", s)
    return s
}

function php_class(m) {
    if (m ~ /Cannot obtain session lock/) return "session_lock"
    if (m ~ /Default exception handler/) return "default_exception"
    if (m ~ /PHP Fatal error/) return "fatal"
    if (m ~ /PHP Warning/) return "warning"
    if (m ~ /PHP Deprecated/) return "deprecated"
    if (m ~ /PHP Notice/) return "notice"
    return "other"
}

function php_messages(s,    n, parts, i, m) {
    if (index(s, "PHP message: ") == 0) return
    n = split(s, parts, /PHP message: /)
    for (i = 2; i <= n; i++) {
        m = parts[i]
        sub(/" while (reading|sending).*$/, "", m)
        sub(/, client: .*$/, "", m)
        if (APACHE) { sub(/', referer: .*$/, "", m); sub(/'$/, "", m) }
        sub(/[;" ]+$/, "", m)
        if (DOCROOT_RE != "") gsub(substr(DOCROOT_RE, 2), "", m)
        m = maskfree(scrub(m))
        gsub(/[0-9]+/, "N", m); gsub(/<ipN>/, "<ip6>", m)
        gsub(/\t/, " ", m)
        m = substr(m, 1, 200)
        PHPM[php_class(m) T m]++
    }
}

# Apache 2.4 (and 2.2) error log.
match($0, /^\[[A-Z][a-z][a-z] ([A-Z][a-z][a-z]) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)? ([0-9]{4})\] \[([a-z_0-9]+:)?([a-z0-9]+)\] /, ap) && (ap[1] in AMON) {
    APACHE = 1
    ts = mktime(ap[7] " " AMON[ap[1]] " " ap[2] " " ap[3] " " ap[4] " " ap[5])
    if (ts < cutoff) { inwin = 0; before++; next }
    inwin = 1
    day = sprintf("%04d-%02d-%02d", ap[7], AMON[ap[1]], ap[2])
    hour = day " " ap[3]
    level = ap[9]
    msg = substr($0, RLENGTH + 1)
    sub(/^(\[pid [^]]*\] )?(\[client [^]]*\] )?/, "", msg)
    sub(/, referer: .*$/, "", msg)
    if (ap[8] != "") msg = "[" substr(ap[8], 1, length(ap[8]) - 1) "] " msg
    for (i = 1; i <= NC; i++) if (msg ~ CR[i]) HC[hour][i]++
    HT[hour]++
    TYPES[day][level T substr(norm(msg), 1, 140)]++
    php_messages(msg)
    nrec++
    next
}

/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[/ {
    APACHE = 0
    ts = mktime(substr($0, 1, 4) " " substr($0, 6, 2) " " substr($0, 9, 2) " " substr($0, 12, 2) " " substr($0, 15, 2) " " substr($0, 18, 2))
    if (ts < cutoff) { inwin = 0; before++; next }
    inwin = 1
    day = substr($0, 1, 4) "-" substr($0, 6, 2) "-" substr($0, 9, 2)
    hour = day " " substr($0, 12, 2)
    level = "?"
    if (match($0, /^[^[]*\[([a-z]+)\]/, lv)) level = lv[1]
    msg = $0
    sub(/^[0-9\/]+ [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: (\*[0-9]+ )?/, "", msg)
    for (i = 1; i <= NC; i++) if (msg ~ CR[i]) HC[hour][i]++
    HT[hour]++
    TYPES[day][level T substr(norm(msg), 1, 140)]++
    php_messages(msg)
    nrec++
    next
}
# A continuation line (multi-line FastCGI stderr): only PHP messages are taken from it.
inwin { php_messages($0); cont++ }

END {
    if (_noout) exit 2     # BEGIN refused (no outdir): END must not write to "/<file>"
    nd = asorti(TYPES, dord)
    for (i = 1; i <= nd; i++) {
        d = dord[i]
        n = asorti(TYPES[d], ord, "@val_num_desc")
        for (j = 1; j <= n && j <= 100; j++) {
            split(ord[j], z, T)
            print site T d T z[1] T TYPES[d][ord[j]] T z[2] >> (outdir "/error_types_daily.tsv")
        }
    }
    nh = asorti(HT, hord)
    for (i = 1; i <= nh; i++) {
        h = hord[i]
        line = site T h T HT[h]
        for (k = 1; k <= NC; k++) line = line T (((h in HC) && (k in HC[h])) ? HC[h][k] : 0)
        print line >> (outdir "/error_hourly_counters.tsv")
    }
    n = asorti(PHPM, pord, "@val_num_desc")
    for (i = 1; i <= n && i <= 50; i++) {
        split(pord[i], z, T)
        print site T z[1] T PHPM[pord[i]] T z[2] >> (outdir "/php_messages_top.tsv")
    }
    printf "errlog_agg[%s]: records=%d continuation=%d before_cutoff=%d\n", site, nrec, cont, before
}
