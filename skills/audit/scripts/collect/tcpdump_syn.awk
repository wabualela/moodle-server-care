# tcpdump_syn.awk -- aggregates `tcpdump -nn -v` output for inbound SYNs
# (collector step R-NET-02).  No address or pcap is written: only TTL histogram, option
# mix, window sizes, destination ports, the distinct-source count and the
# top 10 /16 prefixes with counts.
#
# With -v tcpdump prints two lines per packet, e.g.
#   22:00:01.123 IP (tos 0x0, ttl 52, id 0, offset 0, flags [DF], proto TCP (6), length 60)
#       198.51.100.7.40000 > 203.0.113.10.443: Flags [S], cksum 0x1 (correct), seq 1, win 64240, options [mss 1460,sackOK,TS val 1 ecr 0,nop,wscale 7], length 0
function p16(h,   o, x) {
    if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(h, o, "."); return o[1] "." o[2] ".0.0/16" }
    split(h, x, ":"); return tolower(x[1]) ":" tolower(x[2]) "::/32"
}
/ IP6? \(/ {
    ttl = ""
    if (match($0, /(ttl|hlim) ([0-9]+)/, m)) ttl = m[2]
    pend = 1
    next
}
pend && / > .*Flags \[/ {
    pend = 0
    if (!match($0, /^[ \t]*([0-9A-Fa-f:.]+)\.([0-9]+) > ([0-9A-Fa-f:.]+)\.([0-9]+):/, a)) { bad++; next }
    n++
    src = a[1]; dport = a[4]
    TTL[ttl == "" ? "?" : ttl]++
    DP[dport]++
    if (!(src in S)) { S[src] = 1; ds++ }
    P16[p16(src)]++
    if (match($0, /win ([0-9]+)/, w)) WIN[w[1]]++
    if (match($0, /options \[([^]]*)\]/, o)) {
        opt = o[1]
        withopt++
        if (opt ~ /mss/) MSS++
        if (opt ~ /sackOK/) SACK++
        if (opt ~ /TS val/) TSO++
        if (opt ~ /wscale/) WS++
        if (match(opt, /mss ([0-9]+)/, ms)) MSSV[ms[1]]++
    } else noopt++
}
function top(arr, title, lim,   ord, k, i) {
    print "## " title
    k = asorti(arr, ord, "@val_num_desc")
    for (i = 1; i <= k && i <= lim; i++) printf "%s\t%d\t%.1f%%\n", ord[i], arr[ord[i]], 100 * arr[ord[i]] / (n ? n : 1)
}
END {
    printf "packets\t%d\nunparsed\t%d\ndistinct_sources\t%d\n", n, bad, ds
    printf "with_tcp_options\t%d\nno_tcp_options\t%d\nopt_mss\t%d\nopt_sackOK\t%d\nopt_timestamps\t%d\nopt_wscale\t%d\n", withopt, noopt, MSS, SACK, TSO, WS
    top(TTL, "ttl_histogram (value, count, share)", 64)
    top(WIN, "top10_window_sizes", 10)
    top(MSSV, "top10_mss_values", 10)
    top(DP, "dst_port_split", 10)
    top(P16, "top10_src_prefix16", 10)
}
