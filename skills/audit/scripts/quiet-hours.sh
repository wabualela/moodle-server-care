#!/usr/bin/env bash
# quiet-hours.sh - average requests per hour for each weekday, from the site's access logs (read-only).
# Use it to pick the window for risky changes and maintenance; do not assume "night" is quiet.
#
#   bash quiet-hours.sh [--days 14] [--tz ZONE] [--php-only] [--humans] [--window 4] [--env FILE] [LOG ...]
#
#   --days N     history to use (default 14; only full days count, the first and last partial days are dropped)
#   --tz ZONE    show hours in this time zone (e.g. the students' zone, Asia/Riyadh); default: the server's zone
#   --php-only   count only requests that reached PHP (needs the 'perf' log format with urt=)
#   --humans     drop obvious bots, crawlers, scripts and the audit monitor (by user agent)
#   --window N   length of the quiet window to search for, in hours (default 4)
#   LOG ...      access log files; default: the site's access log from server.env's VHOST, with its rotations
#
# Output: aggregates only (no IP, URL or user agent is printed). The logs are usually readable by root and the
# adm group only: run with sudo (read-only) if "not readable" is reported.
set -u -o pipefail
set +x
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-env.sh
. "$HERE/lib-env.sh"
command -v gawk >/dev/null 2>&1 || { echo "quiet-hours.sh needs gawk (mawk lacks mktime/strftime); installing it is a package change: owner approval" >&2; exit 2; }
DAYS=14; TZOUT=""; PHPONLY=0; HUMANS=0; WIN=4; ENVF=$(msc_env_path)
FILES=()
while (($#)); do
    case $1 in
        --days) DAYS=$2; shift 2 ;;
        --tz) TZOUT=$2; shift 2 ;;
        --php-only) PHPONLY=1; shift ;;
        --humans) HUMANS=1; shift ;;
        --window) WIN=$2; shift 2 ;;
        --env) ENVF=$2; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[[ $DAYS =~ ^[0-9]+$ ]] && ((DAYS >= 2 && DAYS <= 60)) || { echo "--days must be 2..60" >&2; exit 2; }
[[ $WIN =~ ^[0-9]+$ ]] && ((WIN >= 1 && WIN <= 12)) || { echo "--window must be 1..12" >&2; exit 2; }
if [[ -n $TZOUT ]] && ! TZ=$TZOUT date >/dev/null 2>&1; then echo "unknown time zone: $TZOUT" >&2; exit 2; fi

chain() { # base -> rotations oldest first, then base
    local b=$1 n f
    for f in "$b"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]{,.gz}; do [[ -f $f ]] && echo "$f"; done
    for n in $(seq 60 -1 1); do for f in "$b.$n.gz" "$b.$n"; do [[ -f $f ]] && echo "$f"; done; done
    [[ -f $b ]] && echo "$b"
    return 0
}
if ((${#FILES[@]} == 0)); then
    msc_parse_env "$ENVF" VHOST || true
    vhost=${VHOST:-}
    base=""
    if [[ -n $vhost && -r $vhost ]]; then
        base=$(grep -hE '^[[:space:]]*(access_log|CustomLog)[[:space:]]+' -- "$vhost" | grep -v ' if=' \
            | sed -E 's/^[[:space:]]*(access_log|CustomLog)[[:space:]]+"?([^"[:space:];]+).*/\2/; s#\$\{APACHE_LOG_DIR\}#/var/log/apache2#' \
            | grep '^/' | head -n 1)
    fi
    [[ -n $base ]] || for b in /var/log/nginx/access.log /var/log/apache2/access.log; do [[ -e $b ]] && { base=$b; break; }; done
    [[ -n $base ]] || { echo "no access log found; pass the files as arguments" >&2; exit 2; }
    mapfile -t FILES < <(chain "$base")
fi
for f in "${FILES[@]}"; do [[ -r $f ]] || { echo "not readable: $f (run with sudo; this script only reads)" >&2; exit 2; }; done

NOW=$(date +%s); CUTOFF=$((NOW - DAYS * 86400))
SRVTZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || date +%Z)
echo "quiet-hours: ${#FILES[@]} file(s), last $DAYS days; hours shown in ${TZOUT:-$SRVTZ} (server zone: $SRVTZ, now $(date '+%F %H:%M %z'))"
echo "counting: $( ((PHPONLY)) && echo 'PHP requests only (urt present)' || echo 'all requests')$( ((HUMANS)) && echo ', bots/scripts excluded by user agent')"
echo

zcat -f -- "${FILES[@]}" | TZ="${TZOUT:-$SRVTZ}" gawk -v cutoff="$CUTOFF" -v phponly="$PHPONLY" -v humans="$HUMANS" -v win="$WIN" '
BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) MON[m[i]] = i
    split("Mon Tue Wed Thu Fri Sat Sun", WD, " ")
    BOTRE = "bot|crawl|spider|slurp|curl|wget|python|go-http|java/|okhttp|libwww|scrapy|httpclient|guzzle|uptime|pingdom|monitor|moodle-audit-monitor|headless"
}
{
    if (!match($0, /\[([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})\]/, t) || !(t[2] in MON)) { bad++; next }
    ts = mktime(t[3] " " MON[t[2]] " " t[1] " " t[4] " " t[5] " " t[6], 1)
    off = t[8] * 3600 + t[9] * 60; ts -= (t[7] == "-") ? -off : off
    if (ts < cutoff) next
    if (phponly && $0 !~ / urt=[0-9.]+/) next
    if (humans) { n = split($0, q, "\""); ua = (n >= 6) ? tolower(q[6]) : ""; if (ua == "" || ua == "-" || ua ~ BOTRE) next }
    d = strftime("%Y-%m-%d", ts); h = strftime("%H", ts) + 0
    C[d, h]++; DAYSEEN[d] = 1; tot++
    if (first == "" || ts < first) first = ts
    if (ts > last) last = ts
}
END {
    if (tot == 0) { print "no requests in the window (bad timestamps: " bad + 0 ")"; exit 1 }
    fd = strftime("%Y-%m-%d", first); ld = strftime("%Y-%m-%d", last)
    nd = asorti(DAYSEEN, ds)
    for (i = 1; i <= nd; i++) {
        d = ds[i]
        if (d == fd || d == ld) continue          # partial first/last day
        split(d, y, "-"); wd = strftime("%u", mktime(y[1] " " y[2] " " y[3] " 12 00 00")) + 0
        ND[wd]++; full++
        for (h = 0; h < 24; h++) { S[wd, h] += C[d, h]; A[h] += C[d, h] }
    }
    if (full == 0) { print "fewer than 3 calendar days of data: no full day to average"; exit 1 }
    printf "full days used: %d (%s .. %s, partial first/last days dropped)\n\n", full, fd, ld
    printf "avg requests per hour\n%-5s %4s", "day", "n"; for (h = 0; h < 24; h++) printf " %6s", sprintf("%02d", h); printf "\n"
    for (wd = 1; wd <= 7; wd++) {
        if (!ND[wd]) continue
        printf "%-5s %4d", WD[wd], ND[wd]
        for (h = 0; h < 24; h++) printf " %6.0f", S[wd, h] / ND[wd]
        printf "\n"
    }
    printf "%-5s %4d", "all", full; for (h = 0; h < 24; h++) printf " %6.0f", A[h] / full; printf "\n\n"
    # quietest window of win hours over all days (wrapping midnight), and per weekday
    best = -1
    for (s = 0; s < 24; s++) { v = 0; for (k = 0; k < win; k++) v += A[(s + k) % 24]; v /= (win * full); if (best < 0 || v < best) { best = v; bs = s } }
    pk = 0; for (h = 0; h < 24; h++) if (A[h] > A[pk]) pk = h
    printf "quietest %d-hour window (all days): %02d:00-%02d:00, avg %.0f req/h (busiest hour %02d:00, avg %.0f req/h; ratio %.1fx)\n",
        win, bs, (bs + win) % 24, best, pk, A[pk] / full, (best > 0 ? (A[pk] / full) / best : 0)
    for (wd = 1; wd <= 7; wd++) {
        if (!ND[wd]) continue
        b = -1
        for (s = 0; s < 24; s++) { v = 0; for (k = 0; k < win; k++) v += S[wd, (s + k) % 24]; v /= (win * ND[wd]); if (b < 0 || v < b) { b = v; bw = s } }
        printf "  %s: %02d:00-%02d:00 avg %.0f req/h\n", WD[wd], bw, (bw + win) % 24, b
    }
    # the first hour of the morning ramp: the first hour after the quiet window above 50 % of the busiest hour
    for (k = 0; k < 24; k++) { h = (bs + k) % 24; if (A[h] / full >= 0.5 * A[pk] / full) { printf "morning ramp: %02d:00 already reaches half of the busiest hour (do not plan work into it)\n", h; break } }
    if (bad) printf "lines skipped (no parsable timestamp): %d\n", bad
}'
