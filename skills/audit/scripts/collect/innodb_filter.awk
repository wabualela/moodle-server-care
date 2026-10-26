# innodb_filter.awk -- keeps only the safe sections of SHOW ENGINE INNODB STATUS
# (collector step R-DB-05).  The allowlist is BACKGROUND THREAD, SEMAPHORES, FILE I/O,
# INSERT BUFFER AND ADAPTIVE HASH INDEX, LOG, BUFFER POOL AND MEMORY,
# INDIVIDUAL BUFFER POOL INFO and ROW OPERATIONS.  TRANSACTIONS, LATEST
# DETECTED DEADLOCK, LATEST FOREIGN KEY ERROR and any unknown section are
# dropped.
# Fails closed: only the preamble before the first dashed
# line is kept outside an allowlisted section, and if no allowlisted section
# header is found at all (for example output with escaped \n because -r was
# missing), nothing but "[innodb status not parsed]" is printed.
BEGIN {
    split("BACKGROUND THREAD|SEMAPHORES|FILE I/O|INSERT BUFFER AND ADAPTIVE HASH INDEX|LOG|BUFFER POOL AND MEMORY|INDIVIDUAL BUFFER POOL INFO|ROW OPERATIONS", a, "|")
    for (i in a) OK[a[i]] = 1
}
{ L[NR] = $0 }
function is_header(i) {
    return L[i] ~ /^-+$/ && (i + 2) <= NR && L[i + 2] ~ /^-+$/ && L[i + 1] ~ /^[A-Z][A-Z \/]+$/
}
END {
    seen = 0
    for (i = 1; i <= NR; i++) if (is_header(i) && (L[i + 1] in OK)) { seen = 1; break }
    if (!seen) { print "[innodb status not parsed]"; exit }
    keep = 1; started = 0                      # keep = 1: the preamble
    for (i = 1; i <= NR; i++) {
        if (is_header(i)) {
            started = 1
            keep = (L[i + 1] in OK)
            if (!keep) print "[section " L[i + 1] " removed]"
        } else if (!started && L[i] ~ /^-+$/) {
            started = 1; keep = 0                  # a dashed line that opens no known header
        }
        if (L[i] ~ /END OF INNODB MONITOR OUTPUT/) keep = 1
        if (keep) print L[i]
    }
}
