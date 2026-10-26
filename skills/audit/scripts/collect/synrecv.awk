# synrecv.awk -- one `ss -Htn state syn-recv` sample -> counts only (collector step R-NET-01).
#   ss -Htn state syn-recv | gawk -f synrecv.awk -v sample=1 -v ts="2026-03-13 22:00:00"
# Output rows: ts sample local_port count distinct_src distinct_src16
# (one per port, plus an ALL row).  No address is printed.
function port(a,   n, p) { n = split(a, p, ":"); return p[n] }
function host(a) { sub(/:[0-9]+$/, "", a); gsub(/^\[|\]$/, "", a); sub(/^::ffff:/, "", a); return a }
function p16(h,   o, x) {
    if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(h, o, "."); return o[1] "." o[2] }
    split(h, x, ":"); return tolower(x[1]) ":" tolower(x[2])
}
NF >= 4 {
    lp = port($3); src = host($4)
    C[lp]++; tot++
    if (!((lp, src) in S)) { S[lp, src] = 1; DS[lp]++ }
    if (!((lp, p16(src)) in S16)) { S16[lp, p16(src)] = 1; D16[lp]++ }
    if (!(src in AS)) { AS[src] = 1; das++ }
    if (!(p16(src) in A16)) { A16[p16(src)] = 1; da16++ }
}
END {
    n = asorti(C, o, "@ind_num_asc")
    for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%d\t%d\t%d\n", ts, sample, o[i], C[o[i]], DS[o[i]], D16[o[i]]
    printf "%s\t%s\tALL\t%d\t%d\t%d\n", ts, sample, tot, das, da16
}
