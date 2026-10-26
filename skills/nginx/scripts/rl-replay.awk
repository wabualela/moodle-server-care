# rl-replay.awk - replay nginx's limit_req algorithm (burst + nodelay) over access logs to see who WOULD have been
# rejected by limits that cannot be dry-run (limit_req_dry_run is per location, so once the front-page limits are
# enforced, a PHP-wide or login limit added to the same location would be enforced at once).
#
# Requires gawk (mktime, strftime, PROCINFO). Read-only; reads logs on stdin or as file arguments.
# Log format: combined-style ($1 client, $4 "[dd/Mon/yyyy:HH:MM:SS", request in the first quoted field, user agent
# in the third quoted field). With mode=urt it counts only lines carrying " urt=<number>" (requests that reached
# PHP-FPM, as logged by a timing format with $upstream_response_time).
#
# Variables (-v):
#   exempt="127.0.0.1 203.0.113.10"   addresses never counted (localhost, the server's own IP, office IPs)
#   php_rate=20  php_burst=400         zone for every PHP request (r/s, burst)
#   auth_rate=1  auth_burst=60         zone for POSTs to the login, signup and forgot-password forms (1 r/s = 60 r/m)
#   mode=urt|php|all                   urt (default): lines with urt=<number>; php: request path contains ".php" or
#                                      ends in "/"; all: every line (most conservative)
#   prefix=/moodle                     wwwroot sub-path, if any
#   raw=1                              print full client addresses (default: masked a.b.c.x / first 3 IPv6 groups)
# Timestamps have 1-second resolution and mark the END of the request, so the replay slightly over-counts (safe side).
# Tested on synthetic lines: 500 PHP requests from one address in one second -> 99 would-be rejections (burst 400 + 1).
#
# Example:
#   sudo sh -c 'cd /var/log/nginx && for i in $(seq 14 -1 2); do [ -f access.log.$i.gz ] && zcat access.log.$i.gz; done; cat access.log.1 access.log' \
#     | gawk -v exempt="127.0.0.1 <ORIGIN_IP>" -f rl-replay.awk
BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
    for (i = 1; i <= 12; i++) mon[m[i]] = i
    n_ex = split(exempt, e, /[ ,]+/); for (i = 1; i <= n_ex; i++) if (e[i] != "") ex[e[i]] = 1
    if (php_rate == "") php_rate = 20;  if (php_burst == "") php_burst = 400
    if (auth_rate == "") auth_rate = 1; if (auth_burst == "") auth_burst = 60
    if (mode == "") mode = "urt"
    authre = "^POST " prefix "/login/(index|signup|forgot_password)\\.php[ ?]"
}
function mask(a,   p, n) {
    if (raw == 1) return a
    if (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(a, p, "."); return p[1] "." p[2] "." p[3] ".x" }
    n = split(a, p, ":"); if (n >= 3) return p[1] ":" p[2] ":" p[3] "::x"
    return "?"
}
function hit(z, rate, burst,   k, e2, d) {
    k = z SUBSEP ip
    if (!(k in last)) { last[k] = ts; exc[k] = 0; seen[z]++; return }
    d = ts - last[k]; if (d < 0) d = 0
    e2 = exc[k] - rate * d; if (e2 < 0) e2 = 0; e2 += 1
    if (e2 > burst) { n[z]++; byip[z " " mask(ip)]++; byua[z " " ua]++; byday[z " " strftime("%F %a", ts)]++; return }
    exc[k] = e2; last[k] = ts; seen[z]++
}
{
    ip = $1; if (ip in ex) next
    if (mode == "urt" && $0 !~ / urt=[0-9]/) next
    split($0, q, "\"")
    if (mode == "php" && q[2] !~ /^[A-Z]+ [^ ]*(\.php|\/)([?\/ ]|$)/) next
    split(substr($4, 2), t, /[\/:]/)
    if (!(t[2] in mon)) next
    ts = mktime(t[3] " " mon[t[2]] " " t[1] " " t[4] " " t[5] " " t[6])
    ua = substr(q[6], 1, 50)
    lines++
    hit("moodle_php", php_rate, php_burst)
    if (q[2] ~ authre) hit("moodle_auth", auth_rate, auth_burst)
}
END {
    PROCINFO["sorted_in"] = "@val_num_desc"
    printf "lines counted: %d (mode=%s, php %s r/s burst %s, auth %s r/s burst %s)\n", lines, mode, php_rate, php_burst, auth_rate, auth_burst
    for (z in n) printf "TOTAL %s would_reject=%d\n", z, n[z]
    c = 0; for (k in byday) { print "DAY", k, byday[k]; if (++c >= 15) break }
    c = 0; for (k in byip)  { print "IP ", k, byip[k];  if (++c >= 15) break }
    c = 0; for (k in byua)  { print "UA ", k, byua[k];  if (++c >= 15) break }
    if (!length(n)) print "no would-be rejections"
}
