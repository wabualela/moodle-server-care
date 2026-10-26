# netcounters.awk -- picks TCP counters out of two snapshots of
# /proc/net/netstat + /proc/net/snmp (collector step R-NET-01).
#   gawk -f netcounters.awk -v secs=20 snap_t0 snap_t20
# Each snapshot is the two files concatenated: "Prefix: names..." followed
# by "Prefix: values...".
BEGIN {
    T = "\t"
    nw = split("TcpExt:ListenDrops TcpExt:ListenOverflows TcpExt:TCPReqQFullDoCookies TcpExt:TCPReqQFullDrop TcpExt:TCPSynRetrans TcpExt:SyncookiesSent TcpExt:SyncookiesRecv TcpExt:SyncookiesFailed TcpExt:TCPTimeouts TcpExt:TCPAbortOnTimeout Tcp:PassiveOpens Tcp:ActiveOpens Tcp:AttemptFails Tcp:EstabResets Tcp:CurrEstab Tcp:InSegs Tcp:OutSegs Tcp:RetransSegs Tcp:InErrs Tcp:OutRsts", W, " ")
}
FNR == 1 { snap++; delete NAMES }
{
    pfx = $1
    if (!(pfx in NAMES)) { NAMES[pfx] = $0; next }
    nn = split(NAMES[pfx], nm, " "); split($0, vv, " ")
    for (i = 2; i <= nn; i++) V[snap, pfx nm[i]] = vv[i]
    delete NAMES[pfx]
}
END {
    print "counter" T "t0" T "t1" T "delta" T "per_s"
    for (i = 1; i <= nw; i++) {
        k = W[i]; sub(/:/, ": ", k); gsub(/ /, "", k)
        split(W[i], q, ":"); key = q[1] ":" q[2]
        a = V[1, key]; b = V[2, key]
        if (a == "" && b == "") continue
        d = b - a
        printf "%s\t%s\t%s\t%s\t%.2f\n", W[i], a, b, (W[i] ~ /CurrEstab/ ? "" : d), (W[i] ~ /CurrEstab/ || secs <= 0) ? 0 : d / secs
    }
}
