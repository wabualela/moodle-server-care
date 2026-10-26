# cronlog_agg.awk -- Moodle cron log aggregator (collector step R-CRON-02).
#
#   zcat -f <cron logs oldest-first> | gawk -f lib_norm.awk -f cronlog_agg.awk \
#        -v cutoff=<epoch> -v outdir=<dir>
#
# Input: the output of admin/cli/cron.php (and admin/cli/adhoc_task.php) that
# the web user's crontab redirects to a file.  Moodle 3.x-5.x print, per task:
#   Server Time: Sun, 25 Oct 2026 03:49:01 +0300
#   Execute scheduled task: <display name> (core\task\question_preview_cleanup_task)
#   ... started 03:49:01. Current memory use 23.5 MB.
#   ... used 12 dbqueries
#   ... used 0.4567 seconds
#   Scheduled task complete: <display name> (core\task\question_preview_cleanup_task)
# or "Scheduled task failed: ...", and for ad hoc tasks
#   Execute adhoc task: core\task\send_user_notifications_task
#   ... "Adhoc task complete: ..." / "Adhoc task failed: ..."
#
# Privacy: only task CLASS names (core\task\..., mod_x\task\...), counts and
# seconds are written.  Display names (often translated) and every line of task
# output (which can name users, courses or e-mail addresses) are never written.
#
# Outputs:
#   cron_tasks.tsv  kind, task_class, runs, failed, sum_seconds, max_seconds,
#                   n_ge10s, sum_dbqueries   (sorted by sum_seconds)
#   cron_daily.tsv  day, scheduled_runs, adhoc_runs, failed, sum_task_seconds,
#                   cron_runs_seen
#   cron_meta.tsv   counters (lines, window, unparsed)
#
# Time: each "Server Time:" line (printed at the start of every cron run) sets
# the clock; a task's "... started HH:MM:SS" refines it within that run.  Runs
# whose Server Time is before cutoff are skipped.  Without any "Server Time:"
# line (older or customised logs) no task can be placed in time: everything is
# counted and cron_meta.tsv says "window: not applied".

BEGIN {
    T = "\t"
    cutoff += 0
    if (outdir == "") { print "cronlog_agg: -v outdir= is required" > "/dev/stderr"; _noout = 1; exit 2 }
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= 12; i++) CM[mn[i]] = i
    inwin = 1; sawtime = 0; day = "unknown"
    cur = ""; curkind = ""
}

function clsname(s,    m) {
    # the class is the last parenthesised token made only of class characters
    if (match(s, /\(([A-Za-z0-9_]+(\\[A-Za-z0-9_]+)+)\)[[:space:]]*$/, m)) return m[1]
    if (match(s, /([A-Za-z0-9_]+(\\[A-Za-z0-9_]+)+)/, m)) return m[1]
    return "<unparsed>"
}

function finish(failed) {
    if (cur == "") return
    K = curkind T cur
    RUNS[K]++
    if (failed) { FAIL[K]++; DF[day]++ }
    if (cursec != "") {
        SUM[K] += cursec
        if (cursec + 0 > MAX[K] + 0) MAX[K] = cursec
        if (cursec + 0 >= 10) GE10[K]++
        DS[day] += cursec
    }
    if (curdbq != "") DBQ[K] += curdbq
    if (curkind == "scheduled") DSR[day]++; else DAR[day]++
    DAYS[day] = 1
    cur = ""; curkind = ""; cursec = ""; curdbq = ""
}

{ nlines++ }

/^Server Time: / {
    # Server Time: Sun, 25 Oct 2026 03:49:01 +0300
    if (match($0, /([0-9]{1,2}) ([A-Z][a-z][a-z]) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2})/, t) && (t[2] in CM)) {
        sawtime = 1
        ts = mktime(t[3] " " CM[t[2]] " " t[1] " " t[4] " " t[5] " " t[6])
        inwin = (ts >= cutoff)
        day = sprintf("%04d-%02d-%02d", t[3], CM[t[2]], t[1])
        if (inwin) { DAYS[day] = 1; RUNSEEN[day]++; nruns++ } else skippedruns++
    } else badtime++
    next
}

!inwin { next }

/^Execute scheduled task: / { finish(0); cur = clsname($0); curkind = "scheduled"; ntask++; next }
/^Execute adhoc task: / {
    finish(0)
    s = substr($0, 21); sub(/[[:space:]].*$/, "", s)
    cur = (s ~ /^[A-Za-z0-9_]+(\\[A-Za-z0-9_]+)+$/) ? s : clsname($0)
    curkind = "adhoc"; ntask++; next
}
/^\.\.\. used [0-9]+ dbqueries/ { if (cur != "") curdbq = $3 + 0; next }
/^\.\.\. used [0-9.Ee+-]+ seconds/ { if (cur != "") cursec = $3 + 0; next }
/^(Scheduled|Adhoc) task complete: / { finish(0); next }
/^(Scheduled|Adhoc) task failed: / {
    if (cur == "") { cur = clsname($0); curkind = ($0 ~ /^Scheduled/) ? "scheduled" : "adhoc" }
    finish(1); nfail++; next
}

END {
    if (_noout) exit 2     # BEGIN refused (no outdir): END must not write to "/<file>"
    finish(0)
    f = outdir "/cron_tasks.tsv"
    print "kind" T "task_class" T "runs" T "failed" T "sum_seconds" T "max_seconds" T "n_ge10s" T "sum_dbqueries" > f
    n = asorti(RUNS, o)
    for (i = 1; i <= n; i++) ORD[i] = sprintf("%015.3f", SUM[o[i]] + 0) SUBSEP o[i]
    m = asort(ORD, srt)
    for (i = m; i >= 1; i--) {
        split(srt[i], z, SUBSEP); k = z[2]
        printf "%s\t%d\t%d\t%.3f\t%.3f\t%d\t%d\n", k, RUNS[k], FAIL[k] + 0, SUM[k] + 0, MAX[k] + 0, GE10[k] + 0, DBQ[k] + 0 > f
    }
    f = outdir "/cron_daily.tsv"
    print "day" T "scheduled_runs" T "adhoc_runs" T "failed" T "sum_task_seconds" T "cron_runs_seen" > f
    n = asorti(DAYS, o)
    for (i = 1; i <= n; i++) printf "%s\t%d\t%d\t%d\t%.1f\t%d\n", o[i], DSR[o[i]] + 0, DAR[o[i]] + 0, DF[o[i]] + 0, DS[o[i]] + 0, RUNSEEN[o[i]] + 0 > f
    f = outdir "/cron_meta.tsv"
    print "key" T "value" > f
    print "lines_read" T nlines + 0 > f
    print "window" T (sawtime ? "applied (Server Time lines)" : "not applied (no Server Time lines)") > f
    print "cutoff_epoch" T cutoff T strftime("%Y-%m-%d %H:%M:%S %z", cutoff) > f
    print "cron_runs_in_window" T nruns + 0 > f
    print "cron_runs_before_cutoff" T skippedruns + 0 > f
    print "tasks_seen" T ntask + 0 > f
    print "tasks_failed" T nfail + 0 > f
    print "server_time_unparsed" T badtime + 0 > f
    printf "cronlog_agg: lines=%d runs=%d tasks=%d failed=%d\n", nlines, nruns, ntask, nfail
}
