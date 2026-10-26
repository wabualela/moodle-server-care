#!/usr/bin/env bash
# measure-endpoints.sh - server time (urt) of selected Moodle endpoints from the access log, for one window or a
# before/after pair of windows (read-only).  Needs the 'perf' log format (rt=$request_time urt=$upstream_response_time
# at the end of each line; assets/nginx-perf-logformat.conf).
#
#   bash measure-endpoints.sh --from "YYYY-MM-DD HH:MM" --to "YYYY-MM-DD HH:MM"
#        [--from2 "..." --to2 "..."] [--tz ZONE] [--endpoint 'label | METHOD | uri-regex | status-regex'] ...
#        [--only-custom] [--prefix /SUBPATH]
#        [--env FILE] [LOG ...]
#
#   --from/--to       window A (local time of --tz, default the server's zone); --from2/--to2: window B (after)
#   --endpoint        add an endpoint: four fields separated by " | " (space, bar, space; a bare | inside a regex is
#                     fine): label | method regex | regex on the request URI (query included, only matched, never
#                     printed) | status regex.  Example, one AJAX method:
#                     'ajax get_courses | POST | ^/lib/ajax/service\.php\?.*info=core_course_get_courses | ^200$'
#   --only-custom     measure only the --endpoint entries
#   --prefix /SUB     the site lives under a sub-path (wwwroot https://host/SUB): it is removed from the request URI
#                     before matching, so the endpoint regexes stay "^/login/...". Default: the path of WWWROOT in
#                     server.env; --prefix "" turns it off.
#   LOG ...           default: the site's access log from server.env's VHOST with its rotations
#
# Output: count, p50, p90, p95, p99 of urt (seconds, nearest rank) and p95 of rt per endpoint and window, plus the
# change in p50/p95 when two windows are given.  urt is the time the server (PHP) spent; rt adds the time to send the
# response to the client.  Neither is what the student's browser shows (network, rendering).  Compare windows of the
# same weekday and hours, with enough requests (n), and say how many samples each number rests on.
# No IP address, user agent or URL is printed.  Logs are usually readable by root/adm only: run with sudo.
set -u -o pipefail
set +x
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-env.sh
. "$HERE/lib-env.sh"
command -v gawk >/dev/null 2>&1 || { echo "measure-endpoints.sh needs gawk (mawk lacks match() arrays and asort); installing it is a package change: owner approval" >&2; exit 2; }
FROM=""; TO=""; FROM2=""; TO2=""; TZW=""; ONLYC=0; EPS=(); FILES=(); PFX="-"
ENVF=$(msc_env_path)
while (($#)); do
    case $1 in
        --from) FROM=$2; shift 2 ;; --to) TO=$2; shift 2 ;;
        --from2) FROM2=$2; shift 2 ;; --to2) TO2=$2; shift 2 ;;
        --tz) TZW=$2; shift 2 ;;
        --endpoint) EPS+=("$2"); shift 2 ;;
        --only-custom) ONLYC=1; shift ;;
        --prefix) PFX=$2; shift 2 ;;
        --env) ENVF=$2; shift 2 ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[[ -n $FROM && -n $TO ]] || { sed -n '2,29p' "$0"; exit 2; }
[[ -n $TZW ]] && export TZ=$TZW
ep() { date -d "$1" +%s 2>/dev/null || { echo "cannot parse date: $1" >&2; exit 2; }; }
A0=$(ep "$FROM"); A1=$(ep "$TO"); B0=0; B1=0
if [[ -n $FROM2 || -n $TO2 ]]; then [[ -n $FROM2 && -n $TO2 ]] || { echo "--from2 and --to2 go together" >&2; exit 2; }; B0=$(ep "$FROM2"); B1=$(ep "$TO2"); fi
((A1 > A0)) || { echo "--to must be after --from" >&2; exit 2; }

chain() { local b=$1 n f
    for f in "$b"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]{,.gz}; do [[ -f $f ]] && echo "$f"; done
    for n in $(seq 60 -1 1); do for f in "$b.$n.gz" "$b.$n"; do [[ -f $f ]] && echo "$f"; done; done
    [[ -f $b ]] && echo "$b"; return 0; }
if ((${#FILES[@]} == 0)); then
    msc_parse_env "$ENVF" VHOST || true
    vhost=${VHOST:-}; base=""
    [[ -n $vhost && -r $vhost ]] && base=$(grep -hE '^[[:space:]]*access_log[[:space:]]+/' -- "$vhost" | grep -v ' if=' \
        | sed -E 's/^[[:space:]]*access_log[[:space:]]+([^[:space:];]+).*/\1/' | head -n 1)
    [[ -n $base ]] || base=/var/log/nginx/access.log
    mapfile -t FILES < <(chain "$base")
fi
((${#FILES[@]})) || { echo "no log files" >&2; exit 2; }
for f in "${FILES[@]}"; do [[ -r $f ]] || { echo "cannot read $f (run with sudo?)" >&2; exit 2; }; done

if [[ $PFX == - ]]; then
    msc_parse_env "$ENVF" WWWROOT || true
    PFX=$(printf '%s' "${WWWROOT:-}" | sed -E 's#^[a-z]+://[^/]+##; s#/+$##')
fi
[[ -z $PFX || $PFX =~ ^/[A-Za-z0-9._~/-]+$ ]] || { echo "--prefix must look like /moodle" >&2; exit 2; }
PFX=${PFX%/}

DEFAULT_EPS=(
  'front page | GET | ^/(index\.php)?(\?|$) | ^200$'
  'login page | GET | ^/login/index\.php(\?|$) | ^200$'
  'login submit | POST | ^/login/index\.php(\?|$) | ^(200|303)$'
  'dashboard /my/ | GET | ^/my/(index\.php|courses\.php)?(\?|$) | ^200$'
  'course view | GET | ^/course/view\.php\? | ^200$'
  'enrol page | GET | ^/enrol/index\.php\? | ^200$'
  'signup submit | POST | ^/login/signup\.php | ^(200|303)$'
  'forgot password submit | POST | ^/login/forgot_password\.php | ^(200|303)$'
  'AJAX service (all) | POST | ^/lib/ajax/service\.php | ^200$'
  'quiz attempt pages | GET | ^/mod/quiz/(attempt|summary|review)\.php | ^200$'
  'quiz submit | POST | ^/mod/quiz/processattempt\.php | ^(200|303)$'
  'pluginfile | GET | ^/(webservice/)?pluginfile\.php/ | ^200$'
  'mobile app web service | POST | ^/webservice/rest/server\.php | ^200$'
)
if ((ONLYC)); then ALL=("${EPS[@]}"); else ALL=("${DEFAULT_EPS[@]}" "${EPS[@]}"); fi
((${#ALL[@]})) || { echo "no endpoints" >&2; exit 2; }
SPEC=$(printf '%s\n' "${ALL[@]}")

# The endpoint spec goes in through the environment: gawk -v would turn "\." into "." and loosen every regex.
zcat -f -- "${FILES[@]}" | MSC_SPEC="$SPEC" gawk -v a0="$A0" -v a1="$A1" -v b0="$B0" -v b1="$B1" -v pfx="$PFX" '
BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) MON[m[i]] = i
    ne = split(ENVIRON["MSC_SPEC"], L, "\n")
    for (i = 1; i <= ne; i++) {
        if (split(L[i], f, / \| /) != 4) { printf "bad endpoint spec (need 4 fields separated by \" | \"): %s\n", L[i] > "/dev/stderr"; BAD = 1; exit 2 }
        LAB[i] = f[1]; MET[i] = "^(" f[2] ")$"; URI[i] = f[3]; ST[i] = f[4]
    }
}
{
    if (!match($0, /\[([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})\]/, t)) next
    ts = mktime(t[3] " " MON[t[2]] " " t[1] " " t[4] " " t[5] " " t[6], 1)
    off = t[8] * 3600 + t[9] * 60; ts -= (t[7] == "-") ? -off : off
    w = (ts >= a0 && ts < a1) ? "A" : ((b0 && ts >= b0 && ts < b1) ? "B" : "")
    if (w == "") next
    if (!match($0, /"([A-Z]+) ([^ "]*) [^"]*" ([0-9]{3}) /, r)) next
    if (pfx != "" && (r[2] == pfx || index(r[2], pfx "/") == 1 || index(r[2], pfx "?") == 1)) { r[2] = substr(r[2], length(pfx) + 1); if (r[2] == "" || r[2] ~ /^\?/) r[2] = "/" r[2] }
    # rt/urt are the last fields of the perf format; anchoring after the last quote means a URL, referer or user agent
    # containing "urt=" is never read as a latency.
    if (!match($0, / rt=([0-9.]+) urt=([0-9.]+)[^"]*$/, u)) { notiming[w]++; next }
    for (i = 1; i <= ne; i++) {
        if (r[1] !~ MET[i] || r[2] !~ URI[i] || r[3] !~ ST[i]) continue
        k = i SUBSEP w; N[k]++; V[k, N[k]] = u[2] + 0; R[k, N[k]] = u[1] + 0
    }
}
function pct(k, p, arr,    n, a, i) {
    n = N[k]; if (!n) return ""
    for (i = 1; i <= n; i++) a[i] = (arr == "u") ? V[k, i] : R[k, i]
    asort(a); i = int(p * n); if (i < p * n) i++; if (i < 1) i = 1
    return sprintf("%.3f", a[i])
}
END {
    if (BAD) exit 2
    printf "%-26s %-3s %7s %7s %7s %7s %7s %8s", "endpoint (seconds)", "win", "n", "p50", "p90", "p95", "p99", "rt_p95"
    if (b0) printf "  %8s %8s", "d_p50", "d_p95"
    printf "\n"
    for (i = 1; i <= ne; i++) {
        for (wi = 1; wi <= (b0 ? 2 : 1); wi++) {
            w = (wi == 1) ? "A" : "B"; k = i SUBSEP w
            printf "%-26s %-3s %7d %7s %7s %7s %7s %8s", substr(LAB[i], 1, 26), w, N[k], pct(k, .5, "u"), pct(k, .9, "u"), pct(k, .95, "u"), pct(k, .99, "u"), pct(k, .95, "r")
            if (b0 && w == "B" && N[i SUBSEP "A"] && N[k]) printf "  %+8.3f %+8.3f", pct(k, .5, "u") - pct(i SUBSEP "A", .5, "u"), pct(k, .95, "u") - pct(i SUBSEP "A", .95, "u")
            printf "\n"
        }
    }
    if (notiming["A"] + notiming["B"]) printf "lines in the window(s) without rt=/urt= (not the perf format, or no upstream): A %d, B %d\n", notiming["A"], notiming["B"]
    if (pfx != "") print "sub-path " pfx " removed from request URIs before matching"
    print "window A: " strftime("%F %H:%M %z", a0) " .. " strftime("%F %H:%M %z", a1) (b0 ? "; window B: " strftime("%F %H:%M %z", b0) " .. " strftime("%F %H:%M %z", b1) : "")
    print "urt = server (PHP) time; rt = urt + sending the response. Small n (under ~50) gives unstable p95/p99."
}'
