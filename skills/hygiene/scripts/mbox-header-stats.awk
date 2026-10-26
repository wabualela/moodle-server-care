#!/usr/bin/awk -f
# mbox-header-stats.awk — header-only statistics for an mbox file. Prints NO message bodies.
# Usage (as root; the mailbox is usually <user>:mail 660):
#   sudo env LC_ALL=C awk -f mbox-header-stats.awk /var/mail/<WEBUSER>
# Works with gawk and mawk (no gawk-only functions).
#
# Reports: message count, first/last delivery date, messages and MB per month, the subjects that fill the mailbox
# (count and MB), the largest message (size/date/subject), and "minutes holding 2+ messages with the same subject"
# (evidence of a duplicated crontab line). Subjects of cron mails contain the command line, which is how you map the
# mailbox growth to the crontab line that causes it. Subjects are truncated to 140 characters.

function flush() {
    if (n == 0) return
    subjmsgs[subj]++
    subjbytes[subj] += msgb
    if (msgb > maxb) { maxb = msgb; maxdate = date; maxsubj = subj }
    # constant memory: compare with the previous message of the same subject only
    if ((subj in lastmin) && lastmin[subj] == minute) dupmin[subj]++
    lastmin[subj] = minute
}

BEGIN {
    prevblank = 1; n = 0
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
    for (i = 1; i <= 12; i++) mon[m[i]] = sprintf("%02d", i)
}

{
    len = length($0) + 1
    if (prevblank && substr($0, 1, 5) == "From " && NF >= 7) {
        flush()
        n++; msgb = 0; subj = "(no subject)"; inhdr = 1
        # "From sender Dow Mon DD HH:MM:SS YYYY"
        date = $3 " " $4 " " $5 " " $6 " " $7
        ym = $7 "-" mon[$4]
        minute = $4 " " $5 " " substr($6, 1, 5) " " $7
        if (n == 1) first = date
        last = date
        monmsgs[ym]++
    }
    msgb += len
    monbytes[ym] += len
    if (inhdr) {
        if ($0 == "") inhdr = 0
        else if ($0 ~ /^Subject: /) subj = substr($0, 10, 140)
    }
    prevblank = ($0 == "")
}

END {
    flush()
    printf "Messages: %d\nFirst: %s\nLast:  %s\n\n", n, first, last

    print "== Per month (month, msgs, MB) =="
    for (k in monmsgs) printf "%s  %8d  %9.1f\n", k, monmsgs[k], monbytes[k] / 1048576 | "sort"
    close("sort")

    print "\n== Per subject (msgs, MB, minutes with 2+ of the same subject, subject) =="
    for (s in subjmsgs)
        printf "%8d  %9.1f  %6d  %s\n", subjmsgs[s], subjbytes[s] / 1048576, dupmin[s] + 0, s | "sort -k2,2nr | head -n 25"
    close("sort -k2,2nr | head -n 25")

    printf "\n== Largest message ==\n%.1f MB  %s  %s\n", maxb / 1048576, maxdate, maxsubj
}
