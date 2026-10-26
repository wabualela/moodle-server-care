# mysqlslow.awk -- MariaDB/MySQL slow-log window filter and aggregator (collector step R-DB-06).
#   mode=filter : prints only the entries whose time is >= cutoff, so
#                 mariadb-dumpslow (or mysqldumpslow) sees just the window.  This text goes straight
#                 into mariadb-dumpslow and is never written to the output.
#   mode=agg    : writes <outdir>/slowlog_hourly.tsv and <outdir>/slowlog_flags.tsv
#                 with counts and sums only.
# An entry's time is its "SET timestamp=N;" line, falling back to the last
# "# Time:" line (YYMMDD H:MM:SS for MariaDB, or ISO 8601).

BEGIN {
    T = "\t"
    cutoff += 0
    if (mode == "") mode = "agg"
    if (mode == "agg" && outdir == "") { print "mysqlslow: -v outdir= is required" > "/dev/stderr"; _noout = 1; exit 2 }
    nb = 0; lasttime = 0
    NFL = split("Full_scan Full_join Tmp_table Tmp_table_on_disk Filesort Filesort_on_disk", FLN, " ")
}

function parse_time(line,    m) {
    if (match(line, /^# Time: ([0-9]{2})([0-9]{2})([0-9]{2}) +([0-9]{1,2}):([0-9]{2}):([0-9]{2})/, m))
        return mktime((2000 + m[1]) " " m[2] " " m[3] " " m[4] " " m[5] " " m[6])
    if (match(line, /^# Time: ([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/, m))
        return mktime(m[1] " " m[2] " " m[3] " " m[4] " " m[5] " " m[6], (line ~ /Z$/))
    return 0
}

function flush(    i, ts, qt, re, h, d, m, fl) {
    if (nb == 0) return
    ts = 0; qt = ""; re = 0
    delete fl
    for (i = 1; i <= nb; i++) {
        if (B[i] ~ /^# Time: /) { lasttime = parse_time(B[i]) }
        else if (match(B[i], /^SET timestamp=([0-9]+);/, m)) ts = m[1] + 0
        else if (match(B[i], /^# Query_time: ([0-9.]+) +Lock_time: ([0-9.]+) +Rows_sent: ([0-9]+) +Rows_examined: ([0-9]+)/, m)) { qt = m[1]; re = m[4] }
        else if (B[i] ~ /^# (QC_Hit|Full_scan|Filesort):/ || B[i] ~ /Full_scan:|Filesort:/) {
            for (k = 1; k <= NFL; k++) if (match(B[i], "(^|[ #])" FLN[k] ": (Yes|No)", m)) fl[FLN[k]] = m[2]
        }
    }
    if (ts == 0) ts = lasttime
    if (ts >= cutoff && (qt != "" || mode == "filter")) {
        if (mode == "filter") {
            for (i = 1; i <= nb; i++) print B[i]
        } else {
            h = strftime("%Y-%m-%d %H", ts)
            HC[h]++; HS[h] += qt; if (qt + 0 > HM[h] + 0) HM[h] = qt; HR[h] += re
            if (qt + 0 >= 5) H5[h]++
            if (qt + 0 >= 10) H10[h]++
            total++
            for (k = 1; k <= NFL; k++) if (fl[FLN[k]] == "Yes") FY[FLN[k]]++
            if (length(fl) > 0) withflags++
        }
    } else if (ts < cutoff) skipped++
    nb = 0
    delete B
}

# An entry starts at "# Time:" or at "# User@Host:" when no "# Time:" came
# just before it.
/^# Time: / { flush(); B[++nb] = $0; sawtime = 1; next }
/^# User@Host: / { if (!sawtime) flush(); sawtime = 0; B[++nb] = $0; next }
# mariadbd restart banner lines are dropped.
/^\/.*Version: .*started with:/ || /^Tcp port: / || /^Time[ \t]+Id[ \t]+Command/ { next }
{ sawtime = 0; B[++nb] = $0 }

END {
    if (_noout) exit 2     # BEGIN refused (no outdir): END must not write to "/<file>"
    flush()
    if (mode != "agg") exit 0
    f = outdir "/slowlog_hourly.tsv"
    print "hour" T "count" T "sum_query_time" T "max_query_time" T "sum_rows_examined" T "n_ge5s" T "n_ge10s" > f
    n = asorti(HC, o)
    for (i = 1; i <= n; i++) printf "%s\t%d\t%.3f\t%s\t%d\t%d\t%d\n", o[i], HC[o[i]], HS[o[i]], HM[o[i]], HR[o[i]], H5[o[i]], H10[o[i]] > f
    f = outdir "/slowlog_flags.tsv"
    print "flag" T "yes_count" T "entries_with_flag_lines" T "entries_total" > f
    for (k = 1; k <= NFL; k++) printf "%s\t%d\t%d\t%d\n", FLN[k], FY[FLN[k]], withflags, total > f
    printf "mysqlslow: entries_in_window=%d skipped_before_cutoff=%d\n", total, skipped
}
