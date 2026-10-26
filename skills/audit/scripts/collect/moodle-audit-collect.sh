#!/usr/bin/env bash
# moodle-audit-collect.sh -- one-shot, read-only evidence collector for a production Moodle server
# (moodle-server-care plugin, audit module).  Read ../../references/collector.md before running.
#
#   sudo bash moodle-audit-collect.sh [--days 14] [--split YYYY-MM-DD] [--env FILE] [--moodle DIR]
#        [--site-log FILE] [--focus-date YYYY-MM-DD] [--baseline DIR] [--with-tcpdump] [--no-moodle-cli]
#        [--load-max N] [--force] [--yes] [--dry-run] [--version]
#
# It reduces 1-60 days of server evidence (web/PHP/DB/mail/cron logs, DB statistics, process memory, network
# counters, Moodle task and plugin facts) to aggregates, masks personal data, checks the result for residual
# personal data (PRIVACY_CHECK.txt) and packs it into one tarball for analysis.
#
# Read-only guarantees:
#   - no service restart or reload, no SET GLOBAL, no FLUSH, no DB writes (DB reads are SELECT/SHOW only, with a
#     per-statement time limit; the Moodle facts script switches its session to READ ONLY)
#   - no certbot, apt, docker or ufw command; logrotate only with -d; no nstat (counters come from /proc/net)
#   - php-fpm is never run (its -tt dump would be appended to the FPM log); the FPM config files are read instead
#   - nginx -T runs after the web error logs were read (it may log its own warnings there)
#   - tcpdump (only with --with-tcpdump) runs with -p (no promiscuous mode) and pipes straight into awk
#   - the script writes nothing under /etc, /var or /tmp; output only under $OUTBASE/audit-<host>-<stamp>/ (plus
#     the lock file $OUTBASE/.collect.lock); one run at a time.  Exception you cannot switch off: `nginx -T` may
#     append its own warnings to the nginx error log (that is why it runs after the error logs were read)
#   - every step runs through `run` with a timeout, so one failing step never stops the script
#   - server.env is parsed, never sourced (it is not executed as root)
# shellcheck disable=SC2317  # step functions are called indirectly through run()
set +x
set -u -o pipefail
umask 077
VERSION="1.0.0 (moodle-server-care audit collector)"
export VERSION
export LC_ALL=C
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
HERE=$(dirname -- "$SELF")
export SELF HERE

# ------------------------------------------------------------ re-exec under nice/ionice (once)
if [[ -z "${MSC_COLLECT_NICED:-}" && "${MSC_COLLECT_LIB:-0}" != 1 ]]; then
    export MSC_COLLECT_NICED=1
    if command -v ionice >/dev/null 2>&1 && ionice -c3 true 2>/dev/null; then
        exec nice -n 19 ionice -c3 bash "$SELF" "$@"
    else
        exec nice -n 19 bash "$SELF" "$@"
    fi
fi

# ------------------------------------------------------------ logging and runner
log() {
    local line
    line="$(date '+%H:%M:%S') $*"
    echo "$line" >&2
    if [[ -d $OUT/00_meta ]]; then echo "$line" >> "$ERRLOG"; fi
}

if command -v stdbuf >/dev/null 2>&1; then HEADCAP="stdbuf -o0 head"; else HEADCAP="head"; fi
declare -A READS=()
STEP_N=0
CHILD=""
PLAN_LAST_ID=""

plan_print() { # id timeout outfile cmd...
    local id=$1 to=$2 out=$3; shift 3
    printf '%-11s %4ss  %-46s %s\n' "$id" "$to" "$out" "$*"
    if [[ $id != "$PLAN_LAST_ID" ]]; then
        printf '%-11s        reads: %s\n' "" "${READS[$id]:-(see command)}"
    fi
    PLAN_LAST_ID=$id
}

# run <id> <timeout_s> <outfile> -- <cmd...>
# Runs cmd (normally a step function) under timeout in its own process group.  Stdout goes to $OUT/<outfile>,
# capped at 5 MB with a [TRUNCATED] marker.  Stderr goes to run.log.  Adds a row to 00_meta/_index.tsv.
# Never aborts the script.
run() {
    local id=$1 to=$2 out=$3; shift 3
    [[ ${1:-} == -- ]] && shift
    STEP_N=$((STEP_N + 1))
    if ((DRY_RUN)); then plan_print "$id" "$to" "$out" "$@"; return 0; fi
    local f="$OUT/$out" t0 t1 rc secs bytes note=""
    mkdir -p -- "${f%/*}"
    log "START $id -> $out (timeout ${to}s)"
    t0=$(date +%s.%N)
    # stdbuf -o0: head would otherwise hold output in a stdio buffer, and a timed-out step would lose its
    # partial output when it is killed.
    timeout -k 10 "$to" bash -c 'set -o pipefail; "$@" | '"$HEADCAP"' -c '"$((CAP + 1))"'; exit "${PIPESTATUS[0]}"' _ "$@" \
        > "$f" 2>> "$ERRLOG" &
    CHILD=$!
    wait "$CHILD"
    rc=$?
    CHILD=""
    t1=$(date +%s.%N)
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
    bytes=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
    if ((bytes > CAP)); then
        # A .gz is never truncated here (that leaves a broken gzip); enforce_caps recompresses it.
        if [[ $f != *.gz ]]; then
            truncate -s "$CAP" -- "$f"
            printf '\n[TRUNCATED at %d bytes]\n' "$CAP" >> "$f"
            bytes=$(stat -c %s -- "$f")
        fi
        note="truncated"
    fi
    case $rc in 124|137) note="${note:+$note,}timeout" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$*" "$rc" "$secs" "$bytes" "$out" "$note" >> "$OUT/00_meta/_index.tsv"
    log "END   $id rc=$rc ${secs}s ${bytes}B ${note}"
    return 0
}

skip() { # id reason
    if ((DRY_RUN)); then printf '%-11s SKIP  %s\n' "$1" "$2"; return 0; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "-" "skipped" "0" "0" "-" "$2" >> "$OUT/00_meta/_index.tsv"
    log "SKIP  $1: $2"
}

on_signal() {
    log "interrupted; stopping current step"
    if [[ -n $CHILD ]]; then kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null; fi
    exit 130
}

cleanup() {
    rm -rf -- "$WORK" 2>/dev/null
    if [[ -d $OUT ]] && ((EUID == 0)); then
        # -h: never follow a symlink planted in the output tree
        chown -hR "$OWNER": -- "$OUT" 2>/dev/null
        [[ -f $OUT.tar.gz ]] && chown -h "$OWNER": -- "$OUT.tar.gz" 2>/dev/null
        [[ -f $OUTBASE/.collect.lock && ! -L $OUTBASE/.collect.lock ]] && chown -h "$OWNER": -- "$OUTBASE/.collect.lock" 2>/dev/null
        [[ ${CREATED_BASE:-0} == 1 ]] && chown -h "$OWNER": -- "$OUTBASE" 2>/dev/null
    fi
}

# ------------------------------------------------------------ helpers used inside steps
mask()     { sed -E -f "$MASK"; }
mask6off() { sed -E -f "$MASK6OFF"; }
awkn()     { gawk -v docroot="$DOCROOT" -v moodle_dir="$MOODLE" -f "$HERE/lib_norm.awk" "$@"; }

# Drops journal lines from sshd/sudo/login/pam and other auth sources (aggregate only) and appends a count.
drop_auth() {
    gawk '{
        if ($0 ~ /(sshd|sshd-session|sudo|su|login|systemd-logind|polkitd|unix_chkpwd|passwd|chpasswd|useradd|usermod|groupadd|CRON|cron)\[[0-9]+\]:/ ||
            $0 ~ / (sudo|su|sshd):/ ||
            $0 ~ /pam_[a-z_]+\(|authentication failure|Accepted (publickey|password|keyboard)|Failed password|Invalid user|Disconnected from|Connection closed by|session opened for user|session closed for user|New session|Removed session/) { n++; next }
        print
    } END { if (n) printf "[%d sshd/auth/session lines removed by drop_auth]\n", n }'
}

# Prints files <base>.N.gz ... <base>.1 <base>, oldest first, keeping only those modified at or after
# (cutoff - 1 h).  An older file holds no line in the window.  Also handles dated rotation (<base>-YYYYMMDD[.gz]).
log_chain() {
    local base=$1 n f m
    for f in "$base"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]{,.gz}; do
        [[ -f $f ]] || continue
        m=$(stat -c %Y -- "$f" 2>/dev/null) || continue
        ((m >= CUTOFF - 3600)) && printf '%s\n' "$f"
    done
    for n in $(seq 60 -1 1); do
        for f in "$base.$n.gz" "$base.$n"; do
            [[ -f $f ]] || continue
            m=$(stat -c %Y -- "$f" 2>/dev/null) || continue
            ((m >= CUTOFF - 3600)) && printf '%s\n' "$f"
        done
    done
    [[ -f $base ]] && printf '%s\n' "$base"
    return 0
}
# Same, with no time filter.
log_chain_all() {
    local base=$1 n f
    for f in "$base"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]{,.gz}; do [[ -f $f ]] && printf '%s\n' "$f"; done
    for n in $(seq 60 -1 1); do
        for f in "$base.$n.gz" "$base.$n"; do [[ -f $f ]] && printf '%s\n' "$f"; done
    done
    [[ -f $base ]] && printf '%s\n' "$base"
    return 0
}

# For --dry-run: the file list (metadata only), or the glob when the directory is not listable for this user.
plan_chain() { # log_chain|log_chain_all base
    local l
    [[ -z $2 ]] && { echo "(none found)"; return 0; }
    l=$("$1" "$2" 2>/dev/null | tr '\n' ' ')
    if [[ -n $l ]]; then echo "$l"; else echo "$2* (not listable as $(id -un), or absent)"; fi
}

fpm_master() { pgrep -o -f "php-fpm: master process \\(/etc/php/$1/" 2>/dev/null; }

gzip_big() { find "$1" -maxdepth 1 -type f -name '*.tsv' -size +1048576c -exec gzip -9 -- {} \; ; }

db()   { "$DBCLI" --protocol=socket -uroot --connect-timeout=5 -B "$@"; }
dbq()  { db -N -e "$DB_LIMIT $1"; }
dbqh() { db -e "$DB_LIMIT $1"; }

# ============================================================ steps
s_meta_env() {
    echo "collected_at: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "timezone: ${TZ:-system default} ($(date +%Z), offset $(date +%z))"
    echo "collector_version: $VERSION"
    echo "host: $HOST"
    echo "uname: $(uname -a)"
    echo "os: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "uptime: $(uptime)"
    echo "loadavg_start: $LOADAVG_START"
    echo "days: $DAYS"
    echo "window_start: $SINCE (epoch $CUTOFF)"
    if ((SPLIT_EPOCH > 0)); then echo "split: $SPLIT (epoch $SPLIT_EPOCH); P0 = before, P1 = from split on"
    else echo "split: none (P1 = the whole window, P0 files are empty)"; fi
    echo "flags: with_tcpdump=$WITH_TCPDUMP moodle_cli=$MOODLE_CLI force=${FORCE:-0} yes=${YES:-0}"
    echo "## site (from $ENV_SRC)"
    echo "moodle_dir: $MOODLE"; echo "docroot: $DOCROOT"; echo "site: $SITE"; echo "release: $RELEASE"
    echo "dbtype: $DBTYPE"; echo "php: $PHPBIN ($PHPV)"; echo "fpm_socket: $FPM_SOCK"; echo "web_user: $WEBUSER"
    echo "web_server: $WEB"; echo "site_access_log: ${SITE_LOG:-none} (format: $SITE_FMT; $SITE_FMT_WHY)"
    echo "site_error_log: ${SITE_ERRLOG:-none}"
    echo "fpm_log: ${FPM_LOG:-none}"; echo "fpm_slowlog: ${FPM_SLOW:-none} (request_slowlog_timeout ${FPM_SLOW_TMO:-unset})"
    echo "moodle_cron_log: ${CRON_LOG:-none}"
    echo "mta: ${MTA:-none}"
    echo "out: $OUT"
    echo "nproc: $(nproc)"
    echo "## free -m"; free -m
    echo "## df -h"; df -h -x tmpfs -x devtmpfs 2>/dev/null
    echo "## tools"; gawk --version | head -1; echo "bash $BASH_VERSION"
    echo "## sha256 of script and helpers"
    sha256sum "$SELF" "$HERE"/*.awk "$HERE"/mask.sed "$HERE"/moodle_info.php
}

# R-SYS-01
s_sys01_boots() {
    journalctl --list-boots --no-pager -q 2>&1
    echo
    echo "## journalctl --disk-usage"
    journalctl --disk-usage 2>&1
}
s_sys01_header() {
    local tmp="$WORK/journal_header.txt"
    journalctl --header 2>/dev/null | grep -E '^(Head|Tail) realtime timestamp:' > "$tmp"
    echo "## summary"
    gawk '
        /^Head realtime timestamp:/ { d = $5 " " $6; if (h == "" || d < h) h = d; nf++ }
        /^Tail realtime timestamp:/ { d = $5 " " $6; if (d > t) t = d }
        END { print "journal_files: " nf + 0; print "oldest_head: " h; print "newest_tail: " t }' "$tmp"
    echo "## per-file head/tail timestamps, sorted (first 400)"
    sort -k5,6 "$tmp" | head -n 400
    rm -f -- "$tmp"
}

# R-SYS-02
s_sys02() {
    local tmp="$WORK/kern_window.txt"
    journalctl -k --since "$SINCE" -o short-iso --no-pager -q 2>/dev/null | grep -iE "$KPAT" > "$tmp"
    printf 'day\tpattern\tcount\n'
    gawk -v pats="$KPAT" 'BEGIN { n = split(pats, P, "|") }
        { d = substr($1, 1, 10); l = tolower($0); for (i = 1; i <= n; i++) if (l ~ tolower(P[i])) C[d "\t" P[i]]++ }
        END { k = asorti(C, o); for (i = 1; i <= k; i++) print o[i] "\t" C[o[i]] }' "$tmp"
    journalctl -k -b 0 -o cat --no-pager -q 2>/dev/null | grep -iE "$KPAT" | gawk -v pats="$KPAT" '
        BEGIN { n = split(pats, P, "|") }
        { l = tolower($0); for (i = 1; i <= n; i++) if (l ~ tolower(P[i])) C[i]++ }
        END { for (i = 1; i <= n; i++) print "boot0_total\t" P[i] "\t" C[i] + 0 }'
    mask < "$tmp" | head -n 2000 > "$OUT/10_system/kernel_matches.txt"
    rm -f -- "$tmp"
}

# R-SYS-03: the tail of every earlier boot that ended inside the window (at most 4), to see how it ended
# (clean shutdown, panic, power loss).
s_sys03() {
    local idx found=0
    while read -r idx; do
        found=1
        {
            echo "##### boot $idx: last 300 lines"
            journalctl -b "$idx" -n 300 -o short-iso --no-pager -q 2>&1 | drop_auth | mask
            echo
            echo "##### boot $idx: last 200 lines with priority warning or higher"
            journalctl -b "$idx" -p warning -n 200 -o short-iso --no-pager -q 2>&1 | drop_auth | mask
        } > "$OUT/10_system/unit_logs/boot_${idx}_tail.txt"
        echo "boot $idx -> 10_system/unit_logs/boot_${idx}_tail.txt"
    done < <(journalctl --list-boots --no-pager -q 2>/dev/null | gawk -v since="${SINCE%% *}" '
        $1 ~ /^-?[0-9]+$/ && ($1 + 0) != 0 {
            last = ""
            for (i = NF; i >= 1; i--) if ($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) { last = $i; break }
            if (last >= since) print $1
        }' | tail -n 4)
    ((found)) || echo "no earlier boot ended inside the window (since $SINCE)"
}

# R-SYS-04
s_sys04() {
    printf 'ts\tunit\tevent\n'
    journalctl _PID=1 --since "$SINCE" -o short-iso --no-pager -q 2>/dev/null | gawk -v units="$UNIT_RE" '
        {
            if (!match($0, " (" units ")([A-Za-z0-9@._-]*)\\.(service|timer|socket)", u)) next
            unit = u[1] u[2] "." u[3]
            if (!match($0, /Started|Stopped|Stopping|Starting|Main process exited|Failed|Deactivated|Reloaded|Reloading|Scheduled restart job/, e)) next
            print $1 "\t" unit "\t" e[0]
        }'
}

# R-SYS-05
s_sys05_failed() { systemctl --failed --no-pager 2>&1; }
s_sys05_units() {
    local u
    for u in $UNITS; do
        journalctl -u "$u" --since "$SINCE7" -o short-iso -n 300 --no-pager -q 2>&1 | drop_auth | mask \
            > "$OUT/10_system/unit_logs/$u.txt"
        printf '%s\t%s lines\n' "$u" "$(wc -l < "$OUT/10_system/unit_logs/$u.txt")"
    done
}

# R-SYS-06
s_sys06() {
    ls -la "$UU_LOGDIR"/ 2>&1
    echo "## matches (files modified in the last 60 days)"
    find "$UU_LOGDIR" -maxdepth 1 -type f -name 'unattended-upgrades*.log*' -mtime -60 -print0 2>/dev/null \
        | sort -z | xargs -0 -r zgrep -hE 'Packages that will be upgraded|Restarting|restart' 2>&1
    echo "## timers (apt-daily, apt-daily-upgrade, logrotate, certbot)"
    systemctl list-timers --all --no-pager 2>/dev/null | grep -E 'apt-daily|logrotate|certbot|NEXT' 2>&1
    echo "## /etc/apt/apt.conf.d/50unattended-upgrades (Origins-Pattern, Package-Blacklist, Automatic-Reboot)"
    grep -vE '^[[:space:]]*//|^[[:space:]]*$' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null \
        | grep -iE 'origin|blacklist|reboot|mail' | mask
    return 0
}

# R-SYS-07 (logrotate -d makes no changes and does not update the state file)
s_sys07() {
    logrotate -d --skip-state-lock /etc/logrotate.conf 2>&1 | grep -iE 'error|duplicate|skipping|warning'
    return 0
}

# R-SYS-08: sysstat history, if any (averages per day only)
s_sys08() {
    ls -la /var/log/sysstat /var/log/sa 2>&1
    if ! command -v sar >/dev/null 2>&1; then echo "sysstat (sar) not installed"; return 0; fi
    local f
    for f in /var/log/sysstat/sa[0-9][0-9] /var/log/sa/sa[0-9][0-9]; do
        [[ -f $f ]] || continue
        (( $(stat -c %Y -- "$f") >= CUTOFF )) || continue
        echo "##### $f ($(date -d "@$(stat -c %Y -- "$f")" '+%F'))"
        { sar -u -f "$f"; sar -q -f "$f"; sar -r -f "$f"; } 2>/dev/null | grep -E '^Average|^Moyenne|%user|runq-sz|kbmemfree' | head -n 12
    done
    return 0
}

# R-SYS-09
pss_classify() { # pid ppid comm cmdline
    local p=$1 pp=$2 comm=$3 cmd=$4
    if [[ -n $M_FPM && $p == "$M_FPM" ]]; then echo fpm_master
    elif [[ -n $M_FPM && $pp == "$M_FPM" ]]; then echo fpm_children
    elif [[ $cmd == "php-fpm: master process"* ]]; then echo fpm_other_master
    elif [[ $cmd == "php-fpm: pool"* ]]; then echo fpm_other_children
    elif [[ $comm == mariadbd || $comm == mysqld ]]; then echo db_server
    elif [[ $comm == postgres* ]]; then echo postgres
    elif [[ $comm == redis-server ]]; then echo redis-server
    elif [[ $cmd == "nginx: worker process"* || $cmd == "nginx: cache"* ]]; then echo nginx_workers
    elif [[ $cmd == "nginx: master"* ]]; then echo nginx_master
    elif [[ $comm == apache2 || $comm == httpd ]]; then echo apache
    elif [[ $cmd == *admin/cli/cron.php* ]]; then echo moodle_cron_cli
    elif [[ $cmd == *admin/cli/adhoc_task.php* ]]; then echo moodle_adhoc_cli
    elif [[ $cmd == *"artisan queue:work"* || $cmd == *"artisan horizon"* ]]; then echo laravel_queue
    elif [[ $comm == claude || $cmd == *claude* ]]; then echo claude_tooling
    elif [[ $comm == node || $comm == PM2* || $cmd == PM2* ]]; then echo node_pm2
    elif [[ $comm == dockerd || $comm == containerd* ]]; then echo docker_containerd
    elif [[ $comm == exim4 || $comm == exim || $comm == master || $comm == qmgr ]]; then echo mta
    else echo other; fi
}
s_sys09() {
    local d p st rest comm cmd ppid map="$WORK/pss_map.tsv"
    : > "$map"
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        [[ -r $d/smaps_rollup ]] || continue
        { read -r st < "$d/stat" && read -r comm < "$d/comm" && cmd=$(tr '\0' ' ' < "$d/cmdline"); } 2>/dev/null || continue
        rest=${st##*) }
        read -r _ ppid _ <<< "$rest"
        printf '%s\t%s\n' "$(pss_classify "$p" "$ppid" "$comm" "$cmd")" "$d/smaps_rollup" >> "$map"
    done
    echo "# site fpm master ($PHPV) pid=${M_FPM:-none}  (MB; Pss is the proportional share)"
    gawk -F'\t' '
        {
            g = $1; f = $2; got = 0; cur = 0
            while ((getline line < f) > 0)
                if (match(line, /^(Rss|Pss|Pss_Anon|Pss_File|Pss_Shmem|Swap):[ \t]+([0-9]+) kB/, m)) {
                    tmp[m[1]] = m[2]; if (m[1] == "Pss") { cur = m[2]; got = 1 }
                }
            close(f)
            if (!got) next
            n[g]++
            for (k in tmp) v[g, k] += tmp[k]
            delete tmp
            if (cur > mx[g]) mx[g] = cur
        }
        END {
            print "group\tn\trss_mb\tpss_mb\tpss_anon_mb\tpss_file_mb\tpss_shmem_mb\tswap_mb\tavg_pss_mb\tmax_pss_mb"
            k = asorti(n, o)
            for (i = 1; i <= k; i++) {
                g = o[i]
                printf "%s\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\n", g, n[g], v[g, "Rss"] / 1024, v[g, "Pss"] / 1024,
                    v[g, "Pss_Anon"] / 1024, v[g, "Pss_File"] / 1024, v[g, "Pss_Shmem"] / 1024, v[g, "Swap"] / 1024,
                    v[g, "Pss"] / 1024 / n[g], mx[g] / 1024
            }
        }' "$map"
    rm -f -- "$map"
}

# R-SYS-10
s_sys10_limits() {
    local p
    p=$(pidof mariadbd 2>/dev/null | awk '{ print $1 }'); [[ -z $p ]] && p=$(pidof mysqld 2>/dev/null | awk '{ print $1 }')
    if [[ -n $p ]]; then echo "# /proc/$p/limits (DB server)"; cat "/proc/$p/limits"; else echo "no mariadbd/mysqld running"; fi
}
s_sys10_redis() {
    if ! command -v redis-cli >/dev/null 2>&1; then echo "redis-cli not installed (no local Redis)"; return 0; fi
    echo "## redis-cli INFO persistence (selected fields; no AUTH is sent)"
    timeout 10 redis-cli -h 127.0.0.1 -p 6379 INFO persistence 2>&1 | tr -d '\r' \
        | grep -E 'rdb_last_save_time|rdb_changes_since|aof_enabled|rdb_last_bgsave_status|NOAUTH|ERR|refused'
    echo "## redis-cli INFO server/memory (version, uptime, memory)"
    timeout 10 redis-cli -h 127.0.0.1 -p 6379 INFO server 2>&1 | tr -d '\r' | grep -E '^(redis_version|uptime_in_seconds|NOAUTH)'
    timeout 10 redis-cli -h 127.0.0.1 -p 6379 INFO memory 2>&1 | tr -d '\r' | grep -E '^(used_memory_human|maxmemory_human|maxmemory_policy|mem_fragmentation_ratio)'
    echo "## $REDIS_CONF (selected directives)"
    grep -E '^(save|appendonly|maxmemory|maxmemory-policy|bind|protected-mode)' "$REDIS_CONF" 2>&1
    echo "requirepass_lines: $(grep -c '^requirepass' "$REDIS_CONF" 2>/dev/null)"
    return 0
}

# R-SYS-11
s_sys11() {
    du -sh /var/lib/mysql /var/lib/postgresql /var/lib/docker /var/lib/containerd /var/log/journal /var/lib/nginx/fastcgi /root /var/mail 2>&1
    echo "## df of the dataroot filesystem"
    df -h -- "$DATAROOT" 2>&1
    return 0
}

# R-SYS-12: failed units and fail2ban over the whole current boot, and their unit files.
s_sys12_boot0() {
    local u
    for u in $FAILED_UNITS fail2ban.service; do
        echo "##### journalctl -b 0 -u $u (whole boot, last 300 lines)"
        journalctl -b 0 -u "$u" -o short-iso -n 300 --no-pager -q 2>&1 | drop_auth | mask
        echo
    done
}
s_sys12_unitfiles() {
    local u
    for u in $FAILED_UNITS fail2ban.service; do
        echo "##### systemctl cat $u"
        systemctl cat --no-pager "$u" 2>&1 | grep -viE '^[[:space:]]*Environment=.*(pass|secret|token|key)' | mask
        echo "##### systemctl show $u (selected properties)"
        systemctl show --no-pager -p ActiveState -p SubState -p Result -p ExecMainStatus -p ExecMainStartTimestamp \
            -p ExecMainExitTimestamp -p NRestarts "$u" 2>&1 | mask
        echo
    done
}

# R-SYS-13: timestamps of the boot-0 soft lockup / RCU stall / hung task lines.
s_sys13_stalls() {
    printf 'ts\tpattern\tmessage\n'
    journalctl -k -b 0 -o short-iso --no-pager -q 2>/dev/null \
        | grep -iE 'soft lockup|rcu.*stall|hung_task|blocked for more than|watchdog: BUG|NMI watchdog' \
        | head -n 500 | mask | gawk '{
            l = tolower($0)
            p = (l ~ /soft lockup/) ? "soft lockup" : (l ~ /rcu.*stall/) ? "rcu stall" : (l ~ /hung_task|blocked for more than/) ? "hung task" : "watchdog"
            m = $0; sub(/^[^ ]+ [^ ]+ /, "", m); gsub(/\t/, " ", m)
            print $1 "\t" p "\t" substr(m, 1, 200)
        }'
    return 0    # no stall line is the normal case (grep exits 1)
}

# R-SYS-14: package changes in the window (from the earlier of the window start and the day before --focus-date).
s_sys14_apt() {
    local -a files=()
    mapfile -t files < <(log_chain_all "$APT_HISTORY")
    echo "window_start: $(date -d "@$PKG_SINCE_EPOCH" '+%Y-%m-%d %H:%M:%S')"
    printf 'input: %s\n' "${files[@]}"
    ((${#files[@]})) || return 0
    zcat -f -- "${files[@]}" | gawk -v since="$PKG_SINCE_EPOCH" '
        function ep(d, t,    a, b) { split(d, a, "-"); split(t, b, ":"); return mktime(a[1] " " a[2] " " a[3] " " b[1] " " b[2] " " b[3]) }
        /^Start-Date: / { inb = 1; keep = (ep($2, $3) >= since) }
        inb && keep {
            line = $0
            if (line ~ /^Requested-By: /) line = "Requested-By: <user>"
            else if (line ~ /^Commandline: /) line = substr(line, 1, 300)
            else if (length(line) > 4000) line = substr(line, 1, 4000) " [cut]"
            print line
        }
        /^End-Date: / { if (inb && keep) print ""; inb = 0 }' | mask
}
s_sys14_dpkg() {
    local -a files=()
    mapfile -t files < <(log_chain_all "$DPKG_LOG")
    printf 'dpkg input: %s\n' "${files[*]:-none}" >&2
    printf 'ts\taction\tpackage\tfrom_version\tto_version\n'
    ((${#files[@]})) || return 0
    zcat -f -- "${files[@]}" | gawk -v since="$PKG_SINCE_EPOCH" '
        $3 ~ /^(install|upgrade|remove|purge|configure|startup)$/ {
            split($1, a, "-"); split($2, b, ":")
            if (mktime(a[1] " " a[2] " " a[3] " " b[1] " " b[2] " " b[3]) < since) next
            print $1 " " $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
        }' | mask
}

# R-SYS-15: mtimes of the site's PHP ini, OPcache and pool files.  Metadata only.
s_sys15_phpconf() {
    local base=${FPM_CONF_DIR%/fpm}
    printf 'mtime\tsize\tpath\n'
    find "$FPM_CONF_DIR" "$base/mods-available" "$base/cli/php.ini" -maxdepth 2 \( -type f -o -type l \) \
        -printf '%T+\t%s\t%p\n' 2>/dev/null | sort
    return 0
}

# R-SYS-16: '(deleted)' mappings (a library replaced on disk by an upgrade while the process kept the old copy)
# in long-running masters, and web server process start times (a worker younger than its master = last reload).
proc_scan_roles() {
    local root=${PROCFS:-/proc} d cmd comm
    for d in "$root"/[0-9]*; do
        [[ -r $d/cmdline ]] || continue
        cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case $cmd in
            "nginx: master process"*) printf '%s\tnginx_master\n' "${d##*/}" ;;
            "nginx: worker process"*|"nginx: cache"*) printf '%s\tnginx_worker\n' "${d##*/}" ;;
            "php-fpm: master process (/etc/php/"*)
                local v=${cmd#"php-fpm: master process (/etc/php/"}; v=${v%%/*}
                printf '%s\tfpm%s_master\n' "${d##*/}" "${v//./}" ;;
            *)  comm=""; read -r comm < "$d/comm" 2>/dev/null
                case $comm in
                    mariadbd|mysqld) printf '%s\tdb_server\n' "${d##*/}" ;;
                    redis-server) printf '%s\tredis-server\n' "${d##*/}" ;;
                    apache2|httpd) [[ $(awk '{print $4}' "$d/stat" 2>/dev/null) == 1 ]] && printf '%s\tapache_master\n' "${d##*/}" ;;
                esac ;;
        esac
    done
    return 0
}
proc_started() { # <proc dir> -> local start time, from stat field 22 and btime
    gawk -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" -v sf="$1/stat" -v bf="${PROCFS:-/proc}/stat" 'BEGIN {
        while ((getline l < bf) > 0) if (l ~ /^btime /) { split(l, a, " "); bt = a[2] }
        if ((getline s < sf) <= 0 || !bt) exit
        sub(/^.*\) /, "", s); split(s, f, " ")
        print strftime("%Y-%m-%d %H:%M:%S", bt + int(f[20] / hz))
    }'
}
s_sys16_deleted() {
    local root=${PROCFS:-/proc} pid role maps
    printf 'process\tpid\tstarted\tdeleted_maps\tdeleted_libssl_maps\tdeleted_libcrypto_maps\tdeleted_libraries\n'
    while IFS=$'\t' read -r pid role; do
        [[ $role == nginx_worker ]] && continue
        if ! maps=$(cat -- "$root/$pid/maps" 2>/dev/null); then
            printf '%s\t%s\t%s\tunreadable\t\t\t\n' "$role" "$pid" "$(proc_started "$root/$pid")"; continue
        fi
        gawk -v role="$role" -v pid="$pid" -v st="$(proc_started "$root/$pid")" '
            / \(deleted\)$/ {
                n++; f = $(NF - 1); sub(/^.*\//, "", f)
                if (f ~ /^libssl/) s++
                if (f ~ /^libcrypto/) c++
                if (f ~ /\.so(\.|$)/) F[f] = 1
            }
            END { k = asorti(F, o); l = ""; for (i = 1; i <= k; i++) l = l (l == "" ? "" : ",") o[i]
                  printf "%s\t%s\t%s\t%d\t%d\t%d\t%s\n", role, pid, st, n, s, c, l }' <<< "$maps"
    done < <(proc_scan_roles | sort -t$'\t' -k2,2 -k1,1n)
}
s_sys16_web() {
    local root=${PROCFS:-/proc} pid role
    printf 'role\tpid\tstarted\n'
    while IFS=$'\t' read -r pid role; do
        [[ $role == nginx_* || $role == apache_* ]] || continue
        printf '%s\t%s\t%s\n' "$role" "$pid" "$(proc_started "$root/$pid")"
    done < <(proc_scan_roles | sort -t$'\t' -k2,2 -k1,1n)
}

# R-SYS-17: certbot.service run times (start, end, result).  certbot's nginx/apache plugin reloads the web server
# outside systemd, which can line up with latency or 499 spikes.  At least 7 days.
s_sys17_certbot() {
    printf 'start\tend\tduration_s\tresult\n'
    journalctl -u certbot.service --since "$CERT_SINCE" -o short-iso --no-pager -q 2>/dev/null | gawk '
        function ep(s,    m) {
            if (!match(s, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/, m)) return 0
            return mktime(m[1] " " m[2] " " m[3] " " m[4] " " m[5] " " m[6])
        }
        function fmt(s) { return substr(s, 1, 10) " " substr(s, 12, 8) }
        function close_run(res) { printf "%s\t%s\t%d\t%s\n", fmt(st), fmt($1), ep($1) - ep(st), res; st = "" }
        / systemd\[1\]: Starting certbot\.service/ { if (st != "") printf "%s\t\t\tincomplete\n", fmt(st); st = $1; next }
        / systemd\[1\]: Finished certbot\.service/ { if (st != "") close_run("success"); next }
        / systemd\[1\]: Failed to start certbot\.service/ { if (st != "") close_run("failed"); next }
        END { if (st != "") printf "%s\t\t\trunning_or_incomplete\n", fmt(st) }'
}

# R-WEB-00: full web server config.  nginx -T writes any [warn]/[emerg] it finds to the nginx error log, so it
# runs after R-WEB-03 has read the error logs.
s_web00_T() {
    if [[ $WEB == nginx ]]; then nginx -T 2>&1 | mask
    elif [[ $WEB == apache ]]; then
        { apache2ctl -S 2>&1; echo "##### apache2ctl -M"; apache2ctl -M 2>&1
          local f; for f in /etc/apache2/apache2.conf /etc/apache2/sites-enabled/*.conf /etc/apache2/conf-enabled/*.conf /etc/apache2/mods-enabled/*.conf; do
              [[ -f $f ]] || continue; echo "##### $f"; grep -vE '^[[:space:]]*(#|$)' -- "$f"; done; } | mask
    else echo "no nginx or apache found"; fi
}
s_web00_tmp() {
    [[ $WEB == nginx ]] || { echo "not nginx"; return 0; }
    echo "fastcgi_temp_files: $(find /var/lib/nginx/fastcgi -type f 2>/dev/null | wc -l)"
    du -sh /var/lib/nginx/fastcgi 2>&1
    ls -ld /var/lib/nginx/fastcgi 2>&1
    return 0
}

# R-WEB-01 / R-WEB-02: access-log aggregator
s_web_access() { # label fmt base subdir
    local label=$1 fmt=$2 base=$3 dir="$OUT/20_web/$4"
    local -a files=()
    mkdir -p -- "$dir"
    mapfile -t files < <(log_chain "$base")
    echo "log: $label  format: $fmt  window_start: $SINCE"
    printf 'input: %s\n' "${files[@]}"
    ((${#files[@]})) || { echo "no input files"; return 0; }
    zcat -f -- "${files[@]}" | awkn -f "$HERE/access_agg.awk" \
        -v fmt="$fmt" -v cutoff="$CUTOFF" -v surge="$SPLIT_EPOCH" -v outdir="$dir" -v files="${files[*]}"
    local rc=$?
    gzip_big "$dir"
    return "$rc"
}

# R-WEB-03
s_web03() {
    local dir="$OUT/20_web/errors" pair label base
    local -a files=()
    mkdir -p -- "$dir"
    printf 'log\tday\tlevel\tcount\tmessage\n' > "$dir/error_types_daily.tsv"
    printf 'log\thour\ttotal\tbuffered_tmp_file\tupstream_timed_out\tfpm_connect_failed\tresource_temp_unavailable\tupstream_prematurely_closed\tprimary_script_unknown\tfastcgi_stderr\n' \
        > "$dir/error_hourly_counters.tsv"
    printf 'log\tclass\tcount\tmessage\n' > "$dir/php_messages_top.tsv"
    for pair in $ERR_LOGS; do
        label=${pair%%=*}; base=${pair#*=}
        mapfile -t files < <(log_chain "$base")
        printf '%s input: %s\n' "$label" "${files[*]:-none}"
        ((${#files[@]})) || continue
        zcat -f -- "${files[@]}" | awkn -f "$HERE/errlog_agg.awk" -v site="$label" -v cutoff="$CUTOFF" -v outdir="$dir"
    done
    gzip_big "$dir"
}

# R-PHP-01
s_php01_sanitized() {
    local -a files=()
    mapfile -t files < <(log_chain_all "$FPM_LOG")
    ((${#files[@]})) || return 0
    zcat -f -- "${files[@]}" | awkn -f "$HERE/fpmlog_agg.awk" -v mode=sanitize | mask | gzip -9c
}
s_php01_agg() {
    local -a files=()
    mapfile -t files < <(log_chain_all "$FPM_LOG")
    printf 'input: %s\n' "${files[@]}"
    ((${#files[@]})) || return 0
    zcat -f -- "${files[@]}" | awkn -f "$HERE/fpmlog_agg.awk" -v mode=agg -v prefix=fpm -v outdir="$OUT/30_php"
}
# R-PHP-02: FPM logs of the other PHP versions that run a master on this box (other apps).
s_php02() {
    local v f
    local -a files=()
    [[ -n $OTHER_PHPV ]] || { echo "no other php-fpm master running"; return 0; }
    for v in $OTHER_PHPV; do
        f=/var/log/php$v-fpm.log
        mapfile -t files < <(log_chain "$f")
        echo "##### php$v-fpm ($f, files in the window: ${#files[@]})"
        ((${#files[@]})) || continue
        zcat -f -- "${files[@]}" | awkn -f "$HERE/fpmlog_agg.awk" -v mode=sanitize | mask | tail -n 3000
    done
}
# R-PHP-03.  IPv6 masking is off here because stack traces contain '::'.
s_php03_copy() {
    local -a files=()
    [[ -n $FPM_SLOW ]] || return 0
    mapfile -t files < <(log_chain_all "$FPM_SLOW")
    ((${#files[@]})) || return 0
    zcat -f -- "${files[@]}" | mask6off | gzip -9c
}
# Only entries inside the --days window are parsed, and each entry is joined to its request through the FPM log's
# "executing too slow" line (same pid, +-3 s).  The join map holds normalised requests only and lives in $WORK.
s_php03_parse() {
    local -a files=() ffiles=()
    local map="$WORK/fpm_tooslow_map.tsv" rc
    [[ -n $FPM_SLOW ]] || { echo "no slowlog configured for the site's pool"; return 0; }
    mapfile -t files < <(log_chain_all "$FPM_SLOW")
    mapfile -t ffiles < <(log_chain_all "$FPM_LOG")
    printf 'input: %s\n' "${files[@]}"
    printf 'join input (FPM log): %s\n' "${ffiles[*]:-none}"
    echo "window_start: $SINCE (older entries are skipped)"
    ((${#files[@]})) || return 0
    : > "$map"
    if ((${#ffiles[@]})); then
        zcat -f -- "${ffiles[@]}" | awkn -f "$HERE/fpmlog_agg.awk" -v mode=reqmap > "$map"
    fi
    zcat -f -- "${files[@]}" | awkn -f "$HERE/slowlog_parse.awk" -v outdir="$OUT/30_php" -v cutoff="$CUTOFF" -v reqmap="$map"
    rc=$?
    rm -f -- "$map"
    return "$rc"
}
# R-PHP-04: the FPM configuration, read as plain files (comment and blank lines dropped); env[] values and
# secret-looking values are redacted, then everything goes through mask.sed.
s_php04() {
    local f
    for f in "$FPM_CONF_DIR/php-fpm.conf" "$FPM_CONF_DIR"/pool.d/*.conf; do
        [[ -f $f ]] || continue
        echo "##### $f"
        grep -hvE '^[[:space:]]*(;|$)' -- "$f"
    done | sed -E 's/(env\[[^]]*\][[:space:]]*=[[:space:]]*).*/\1<redacted>/; s/((pass(word)?|secret|token|key)[^=]*=[[:space:]]*)[^[:space:]]+/\1<redacted>/Ig' \
         | mask
    echo "##### effective ini values that matter for Moodle (php.ini of the FPM SAPI, read as files)"
    grep -hE '^[[:space:]]*(memory_limit|max_execution_time|max_input_vars|post_max_size|upload_max_filesize|opcache\.(enable|memory_consumption|max_accelerated_files|validate_timestamps|revalidate_freq|interned_strings_buffer|jit|jit_buffer_size)|realpath_cache_size|session\.save_handler)[[:space:]]*=' \
        "$FPM_CONF_DIR/php.ini" "$FPM_CONF_DIR"/conf.d/*.ini 2>/dev/null | mask
    return 0
}

# R-MDL-01: Moodle's own status checks (admin/cli/checks.php, Moodle 3.9+), as the web user, read-only.
s_mdl01() {
    if [[ ! -f $MOODLE/admin/cli/checks.php ]]; then echo "admin/cli/checks.php not present (Moodle < 3.9)"; return 0; fi
    runuser -u "$WEBUSER" -- "$PHPBIN" "$MOODLE/admin/cli/checks.php" -v 2>&1 | mask
    return 0
}
# R-MDL-02: settings, cache stores, scheduled tasks, ad hoc queue, plugins, counts, theme colours (moodle_info.php).
# The script goes in on stdin, so the web user never needs read access to this directory.
s_mdl02() {
    runuser -u "$WEBUSER" -- "$PHPBIN" -d display_errors=stderr -- "$MOODLE" < "$HERE/moodle_info.php" 2>&1 | mask
    return 0
}

# R-DB-01..09 (root unix-socket auth only; skipped entirely if it fails)
s_db01() {
    local a b
    a=$(date +%s.%N)
    dbq "SHOW GLOBAL STATUS"
    b=$(date +%s.%N)
    printf '_collected_epoch\t%s\n' "${b%.*}"
    printf '_query_start_epoch\t%s\n_query_end_epoch\t%s\n' "$a" "$b"
}
# R-DB-01c (local only): per-second rates from status_t0/status_t60, divided by the real gap between the midpoints
# of the two SHOW GLOBAL STATUS calls.  Gauges get a delta but no rate.  A restart in between blanks every rate.
s_db01_delta() {
    local d="$OUT/40_db"
    [[ -s $d/status_t0.tsv && -s $d/status_t60.tsv ]] || { echo "status_t0.tsv or status_t60.tsv missing"; return 1; }
    gawk -F'\t' -v nominal="$DB_DELTA" '
        FNR == NR { A[$1] = $2; next }
        { B[$1] = $2 }
        function mid(X) { return ("_query_start_epoch" in X) ? (X["_query_start_epoch"] + X["_query_end_epoch"]) / 2 : X["_collected_epoch"] + 0 }
        END {
            t0 = mid(A); t1 = mid(B); dt = t1 - t0
            up = B["Uptime"] - A["Uptime"]
            restart = (B["Uptime"] + 0 < A["Uptime"] + 0)
            G = "^(Threads_(cached|connected|running)|Open_(files|streams|tables|table_definitions)|Innodb_buffer_pool_pages_(data|dirty|free|misc|total|old)|Innodb_buffer_pool_bytes_(data|dirty)|Innodb_row_lock_current_waits|Innodb_num_open_files|Innodb_history_list_length|Innodb_checkpoint_(age|max_age)|Innodb_(data|os_log)_pending_.*|Max_used_connections|Memory_used.*|Uptime.*|Qcache_(free_blocks|free_memory|queries_in_cache|total_blocks)|Innodb_page_size|Slaves_(connected|running)|Delayed_insert_threads|Innodb_mem_.*)$"
            print "variable\tkind\tt0\tt1\tdelta\tper_sec"
            printf "_sample_seconds\tmeta\t%.3f\t%.3f\t%.3f\t\n", t0, t1, dt
            printf "_nominal_seconds\tmeta\t\t\t%s\t\n", nominal
            printf "_uptime_delta\tmeta\t%s\t%s\t%s\t\n", A["Uptime"], B["Uptime"], up
            printf "_restart_detected\tmeta\t\t\t%d\t\n", restart
            print "_note\tmeta\t\t\tper_sec = delta / _sample_seconds; the collector adds 2 connections and 2 SHOW STATUS of its own; catalog queries run after t1\t"
            n = asorti(A, o)
            for (i = 1; i <= n; i++) {
                k = o[i]
                if (k ~ /^_/ || !(k in B)) continue
                if (A[k] !~ /^-?[0-9]+(\.[0-9]+)?$/ || B[k] !~ /^-?[0-9]+(\.[0-9]+)?$/) continue
                kind = (k ~ G) ? "gauge" : "counter"
                d = B[k] - A[k]
                r = (kind == "counter" && dt > 0 && !restart) ? sprintf("%.4f", d / dt) : ""
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", k, kind, A[k], B[k], d, r
            }
        }' "$d/status_t0.tsv" "$d/status_t60.tsv"
}
s_db02() { dbq "SHOW GLOBAL VARIABLES" | grep -viE '^(report_password|wsrep_sst_auth)([[:space:]]|$)' | mask; }
# The digest hash (DIGEST, 32 hex) and up to 1,024 characters of the normalised text (literals are already '?').
# mask.sed would turn the hash into <hex>, so only the text column is masked, with maskfree().
digest_mask() { gawk -F'\t' -v OFS='\t' -f "$HERE/lib_norm.awk" -e 'NR > 1 && NF >= 3 { $3 = maskfree($3) } { print }'; }
s_db03() { # order column
    dbqh "SELECT SCHEMA_NAME, DIGEST, LEFT(DIGEST_TEXT,1024) AS DIGEST_TEXT_1024, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e12,2) AS total_s, ROUND(AVG_TIMER_WAIT/1e9,2) AS avg_ms, ROUND(MAX_TIMER_WAIT/1e9,1) AS max_ms, SUM_ROWS_EXAMINED, SUM_ROWS_SENT, SUM_SELECT_FULL_JOIN, SUM_SELECT_SCAN, SUM_NO_INDEX_USED, SUM_CREATED_TMP_DISK_TABLES, FIRST_SEEN, LAST_SEEN FROM performance_schema.events_statements_summary_by_digest ORDER BY $1 DESC LIMIT 50" | digest_mask
}
s_db03_all() {
    dbqh "SELECT SCHEMA_NAME, DIGEST, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e12,3) AS total_s, ROUND(AVG_TIMER_WAIT/1e9,3) AS avg_ms, ROUND(MAX_TIMER_WAIT/1e9,1) AS max_ms, SUM_ROWS_EXAMINED, SUM_ROWS_SENT, SUM_ROWS_AFFECTED, SUM_NO_INDEX_USED, SUM_CREATED_TMP_DISK_TABLES, FIRST_SEEN, LAST_SEEN FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_TIMER_WAIT DESC"
}
s_db03_meta() {
    dbq "SHOW GLOBAL STATUS LIKE 'Performance_schema_digest_lost'"
    printf 'digest_rows\t%s\n' "$(dbq "SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest")"
    dbq "SHOW GLOBAL VARIABLES LIKE 'performance_schema%'"
}
s_db04_io() {
    dbqh "SELECT OBJECT_NAME, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e12,2) AS total_s, COUNT_READ, ROUND(SUM_TIMER_READ/1e12,2) AS read_s, COUNT_WRITE, ROUND(SUM_TIMER_WRITE/1e12,2) AS write_s, COUNT_FETCH, COUNT_INSERT, COUNT_UPDATE, COUNT_DELETE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA='$DBNAME' ORDER BY SUM_TIMER_WAIT DESC LIMIT 40"
}
s_db04_fullscan() {
    dbqh "SELECT OBJECT_NAME, COUNT_READ, COUNT_FETCH, ROUND(SUM_TIMER_READ/1e12,2) AS read_s FROM performance_schema.table_io_waits_summary_by_index_usage WHERE INDEX_NAME IS NULL AND OBJECT_SCHEMA='$DBNAME' ORDER BY COUNT_READ DESC LIMIT 30"
}
s_db05_bp()  { dbqh "SELECT * FROM information_schema.INNODB_BUFFER_POOL_STATS"; }
s_db05_cmp() { dbqh "SELECT * FROM information_schema.INNODB_CMP"; }
s_db05_status() { db -N -r -e "SHOW ENGINE INNODB STATUS" | gawk -f "$HERE/innodb_filter.awk" | mask; }
s_db06() {
    local f total=0 big=0 slow=${SLOW_FILE:-}
    local -a files=()
    echo "slow_query_log: ${SLOW_ON:-?}  long_query_time: ${LONG_QT:-?}  file: ${slow:-?}"
    [[ -n $slow && $slow != /* ]] && slow="$MYSQL_DATADIR/$slow"
    [[ -n $slow ]] || { echo "no slow log file configured"; return 0; }
    echo "## ls -la ${slow%/*}"
    ls -la "${slow%/*}" 2>&1
    mapfile -t files < <(log_chain "$slow")
    printf 'input: %s\n' "${files[@]}"
    ((${#files[@]})) || { echo "no slow log in window"; return 0; }
    for f in "${files[@]}"; do total=$((total + $(stat -c %s -- "$f"))); done
    if ((total > 500 * 1024 * 1024)); then big=1; echo "input is ${total} B (>500 MB): using tail -c 300M of $slow only"; fi
    slow_stream() { if ((big)); then tail -c 300M "$slow"; else zcat -f -- "${files[@]}"; fi; }
    slow_stream | gawk -f "$HERE/mysqlslow.awk" -v mode=filter -v cutoff="$CUTOFF" \
        | "$DUMPSLOW" -s t -t 40 - 2>/dev/null | mask > "$OUT/40_db/slowlog_dumpslow_time.txt"
    slow_stream | gawk -f "$HERE/mysqlslow.awk" -v mode=filter -v cutoff="$CUTOFF" \
        | "$DUMPSLOW" -s c -t 40 - 2>/dev/null | mask > "$OUT/40_db/slowlog_dumpslow_count.txt"
    slow_stream | gawk -f "$HERE/mysqlslow.awk" -v mode=agg -v cutoff="$CUTOFF" -v outdir="$OUT/40_db"
}
s_db07_pl() {
    dbqh "SELECT USER, COMMAND, STATE, COUNT(*) AS n, MAX(TIME) AS max_time_s FROM information_schema.PROCESSLIST GROUP BY USER, COMMAND, STATE ORDER BY n DESC"
}
s_db07_remote() {
    local t=mysql.global_priv
    dbq "SELECT 1 FROM mysql.global_priv LIMIT 1" >/dev/null 2>&1 || t=mysql.user
    printf 'accounts_host_not_local\t%s\n' "$(dbq "SELECT COUNT(*) FROM $t WHERE Host NOT IN ('localhost','127.0.0.1','::1')")"
    printf 'accounts_host_percent\t%s\n' "$(dbq "SELECT COUNT(*) FROM $t WHERE Host='%'")"
    echo "## listeners of the DB server (bind address)"
    ss -Htlnp 2>/dev/null | grep -E '"(mariadbd|mysqld)"' | awk '{print $4}' | mask
}
s_db07_schemas() {
    dbqh "SELECT TABLE_SCHEMA, COUNT(*) AS tables_n, ROUND(SUM(DATA_LENGTH+INDEX_LENGTH)/1048576) AS size_mb, ROUND(SUM(DATA_FREE)/1048576) AS free_mb FROM information_schema.TABLES GROUP BY TABLE_SCHEMA"
}
s_db07_tables() {
    dbqh "SELECT TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_ROWS AS rows_estimate, ROUND((DATA_LENGTH+INDEX_LENGTH)/1048576) AS size_mb, ROUND(DATA_FREE/1048576) AS free_mb FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DBNAME' ORDER BY DATA_LENGTH+INDEX_LENGTH DESC LIMIT 30"
}
s_db07_datadir() {
    echo "## ls -laS $MYSQL_DATADIR/$DBNAME | head -20 (sizes only)"
    ls -laS "$MYSQL_DATADIR/$DBNAME" 2>&1 | head -n 20
    echo "## ls -la $MYSQL_DATADIR/ib*"
    ls -la "$MYSQL_DATADIR"/ib* 2>&1
    return 0
}
# R-DB-08: web/cron attribution of DB connections by socket peer (mysqlnd sends no _pid attribute):
#   performance_schema.threads (+ statements per thread)
#   -> socket_instances.SOCKET_ID: the connection's fd inside the server (TCP: the client port)
#   -> ss -xpn: that fd -> its peer socket inode -> the client pid   (TCP: ss -tnp, client port -> pid)
#   -> $PROCFS/<pid>/cmdline and the parent's cmdline -> class
# socket_instances is filled only when the wait/io/socket instruments are on (MariaDB default: off).  Then the
# threads stay "unmapped", and conn_peers.tsv still gives the connection count per class from ss alone.
# Moodle with dbpersist keeps one connection per FPM child, so statements accumulate over many requests.
db08_classify() { # pid -> class
    local root=${PROCFS:-/proc} pid=$1 cmd pp pcmd
    [[ $pid =~ ^[0-9]+$ && -r $root/$pid/cmdline ]] || { echo gone; return 0; }
    cmd=$(tr '\0' ' ' < "$root/$pid/cmdline" 2>/dev/null)
    case $cmd in
        "php-fpm: pool "*)
            read -r _ pp _ <<< "$(sed 's/^.*) //' "$root/$pid/stat" 2>/dev/null)"
            pcmd=$(tr '\0' ' ' < "$root/$pp/cmdline" 2>/dev/null)
            case $pcmd in *"/etc/php/$PHPV/"*) echo fpm_site ;; *) echo fpm_other ;; esac ;;
        *admin/cli/cron.php*) echo cron.php ;;
        *admin/cli/adhoc_task.php*) echo adhoc_task.php ;;
        *admin/cli/*) echo moodle_cli_other ;;
        mariadb\ *|mysql\ *|*/mariadb\ *|*/mysql\ *|mariadb|mysql) echo db_client ;;
        *) echo other ;;
    esac
}
db08_sample() { # sample-number; appends "T ..." and "P ..." rows to $WORK/db08_rows.tsv
    local n=$1 ssx="$WORK/db08_ssx" sst="$WORK/db08_sst" pst="$WORK/db08_ps"
    ss -Hxpn 2>/dev/null > "$ssx"
    ss -Htnp state established '( sport = :3306 or dport = :3306 )' 2>/dev/null > "$sst"
    if ! dbq "SELECT t.THREAD_ID, t.PROCESSLIST_ID, IFNULL(t.CONNECTION_TYPE,''), IFNULL(t.PROCESSLIST_COMMAND,''), IFNULL(t.PROCESSLIST_TIME,0), IFNULL(si.SOCKET_ID,-1), IFNULL(si.PORT,0), IFNULL(st.cnt,0), IFNULL(st.secs,0) FROM performance_schema.threads t LEFT JOIN performance_schema.socket_instances si ON si.THREAD_ID = t.THREAD_ID AND si.EVENT_NAME = 'wait/io/socket/sql/client_connection' LEFT JOIN (SELECT THREAD_ID, SUM(COUNT_STAR) AS cnt, ROUND(SUM(SUM_TIMER_WAIT)/1e12,3) AS secs FROM performance_schema.events_statements_summary_by_thread_by_event_name GROUP BY THREAD_ID) st ON st.THREAD_ID = t.THREAD_ID WHERE t.TYPE = 'FOREGROUND' AND t.PROCESSLIST_ID IS NOT NULL AND t.PROCESSLIST_ID <> CONNECTION_ID()" > "$pst" 2>> "$ERRLOG"; then
        dbq "SELECT t.THREAD_ID, t.PROCESSLIST_ID, '', IFNULL(t.PROCESSLIST_COMMAND,''), IFNULL(t.PROCESSLIST_TIME,0), -1, 0, IFNULL(SUM(s.COUNT_STAR),0), IFNULL(ROUND(SUM(s.SUM_TIMER_WAIT)/1e12,3),0) FROM performance_schema.threads t LEFT JOIN performance_schema.events_statements_summary_by_thread_by_event_name s ON s.THREAD_ID = t.THREAD_ID WHERE t.TYPE = 'FOREGROUND' AND t.PROCESSLIST_ID IS NOT NULL AND t.PROCESSLIST_ID <> CONNECTION_ID() GROUP BY t.THREAD_ID, t.PROCESSLIST_ID, t.PROCESSLIST_COMMAND, t.PROCESSLIST_TIME" > "$pst" 2>> "$ERRLOG"
    fi
    # Files are told apart by name, not by counting FNR == 1: an empty file would shift the count.
    gawk -v n="$n" '
        FNR == 1 { fi = (FILENAME == ARGV[1]) ? 1 : (FILENAME == ARGV[2]) ? 2 : 3 }
        fi == 1 {                                   # ss -Hxpn
            k = split($0, f, " ")
            if (k < 9 || f[1] != "u_str" || !match($0, /pid=([0-9]+),fd=([0-9]+)/, u)) next
            I2P[f[6]] = u[1]
            if (f[5] ~ /mysqld\.sock$/ && $0 ~ /\("(mariadbd|mysqld)",/) { SRV[u[2]] = f[8]; SP[++ns] = f[8] }
            next
        }
        fi == 2 {                                   # ss -Htnp state established, port 3306
            k = split($0, f, " ")
            if (k < 5 || !match($0, /pid=([0-9]+),fd=([0-9]+)/, u)) next
            lp = f[3]; sub(/^.*:/, "", lp); pp = f[4]; sub(/^.*:/, "", pp)
            if (pp == "3306" && lp != "3306") { TC[lp] = u[1]; TP[++nt] = u[1] }
            next
        }
        fi == 3 {                                   # performance_schema threads
            split($0, f, "\t")
            pid = "-"; via = "unmapped"
            if (f[3] == "Socket" && f[6] >= 0 && (f[6] in SRV) && (SRV[f[6]] in I2P)) { pid = I2P[SRV[f[6]]]; via = "socket_peer" }
            else if (f[3] != "Socket" && f[7] > 0 && (f[7] in TC)) { pid = TC[f[7]]; via = "socket_peer" }
            print "T\t" n "\t" f[1] "\t" pid "\t" via "\t" f[8] "\t" f[9] "\t" (f[6] >= 0 ? 1 : 0)
        }
        END {
            for (i = 1; i <= ns; i++) print "P\t" n "\tunix\t" ((SP[i] in I2P) ? I2P[SP[i]] : "-")
            for (i = 1; i <= nt; i++) print "P\t" n "\ttcp\t" TP[i]
        }' "$ssx" "$sst" "$pst" >> "$WORK/db08_rows.tsv"
    rm -f -- "$ssx" "$sst" "$pst"
}
s_db08() {
    local i rows="$WORK/db08_rows.tsv" cls="$WORK/db08_class.tsv" p
    : > "$rows"; : > "$cls"
    for ((i = 1; i <= DB08_SAMPLES; i++)); do
        db08_sample "$i"
        ((i < DB08_SAMPLES)) && sleep "$DB08_SLEEP"
    done
    gawk -F'\t' '$1 == "T" && $4 != "-" { print $4 } $1 == "P" && $4 != "-" { print $4 }' "$rows" | sort -u | while read -r p; do
        printf '%s\t%s\n' "$p" "$(db08_classify "$p")"
    done > "$cls"
    printf 'class\tconnections\tstatements\tstatement_seconds\tmethod\n'
    gawk -F'\t' '
        FILENAME == ARGV[1] { C[$1] = $2; next }
        $1 == "T" { tid = $3; V[tid] = $6; S[tid] = $7; if ($8) SI[tid] = 1
                    if (!(tid in K) || K[tid] == "unmapped") K[tid] = ($4 == "-") ? "unmapped" : (($4 in C) ? C[$4] : "gone") }
        END {
            si = length(SI)
            for (t in K) { n[K[t]]++; c[K[t]] += V[t]; s[K[t]] += S[t] }
            for (k in n) printf "%s\t%d\t%d\t%.3f\tsocket_peer\n", k, n[k], c[k], s[k] | "sort"
            close("sort")
            printf "_note\tthreads seen (distinct) %d; threads with a socket_instances entry %d (0 = wait/io/socket instruments off: see conn_peers.tsv)\t\t\tsocket_peer\n", length(K), si
        }' "$cls" "$rows"
    printf '_note\tcovers only threads connected during the samples; statements are counted since each connection opened\t\t\t-\n'
    {
        printf 'sample\ttransport\tclass\tconnections\n'
        gawk -F'\t' 'FILENAME == ARGV[1] { C[$1] = $2; next } $1 == "P" { k = $2 "\t" $3 "\t" (($4 in C) ? C[$4] : "unknown"); N[k]++ }
            END { for (k in N) print k "\t" N[k] }' "$cls" "$rows" | sort
    } > "$OUT/40_db/conn_peers.tsv"
    rm -f -- "$rows" "$cls"
}
s_db08_attrs() {
    dbqh "SELECT ATTR_NAME, COUNT(DISTINCT PROCESSLIST_ID) AS connections FROM performance_schema.session_connect_attrs GROUP BY ATTR_NAME ORDER BY ATTR_NAME"
}
s_db09() { journalctl -u "$DB_UNIT" --since "$SINCE" -o short-iso --no-pager -q 2>&1 | drop_auth | mask; }

# R-CRON-01
s_cron_user() { crontab -l -u "$1" 2>&1 | mask; }
s_cron_spool() {
    local u c
    echo "## ls -la /var/spool/cron/crontabs/"
    ls -la /var/spool/cron/crontabs/ 2>&1
    echo
    echo "## counts (non-comment lines)"
    printf 'user\tadhoc_task\tartisan_schedule_run\tadmin_cli_cron_php\tMAILTO\tlines_without_redirect\n'
    for u in $CRON_USERS; do
        c=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$(grep -c adhoc_task <<< "$c")" "$(grep -c 'artisan schedule:run' <<< "$c")" \
            "$(grep -c 'admin/cli/cron.php' <<< "$c")" "$(grep -c '^MAILTO' <<< "$c")" \
            "$(grep -vE '^[A-Z_]+=' <<< "$c" | grep -v '>' | grep -c .)"
    done
    echo
    echo "## ls -la /etc/cron.d"
    ls -la /etc/cron.d 2>&1
    return 0
}
# R-CRON-02: the Moodle cron log (task classes, runs, seconds, failures; no task output)
s_cron02() {
    local -a files=()
    local total=0 f
    [[ -n $CRON_LOG ]] || { echo "no Moodle cron log found in the web user's crontab (output not redirected to a file?)"; return 0; }
    mapfile -t files < <(log_chain "$CRON_LOG")
    printf 'input: %s\n' "${files[@]}"
    ((${#files[@]})) || return 0
    for f in "${files[@]}"; do total=$((total + $(stat -c %s -- "$f"))); done
    if ((total > 1024 * 1024 * 1024)); then
        echo "input is ${total} B (>1 GB): using tail -c 500M of $CRON_LOG only"
        tail -c 500M -- "$CRON_LOG" | gawk -f "$HERE/cronlog_agg.awk" -v cutoff="$CUTOFF" -v outdir="$OUT/50_cron_mail"
    else
        zcat -f -- "${files[@]}" | gawk -f "$HERE/cronlog_agg.awk" -v cutoff="$CUTOFF" -v outdir="$OUT/50_cron_mail"
    fi
}

# R-MAIL-01
s_mail01() {
    case $MTA in
        exim)
            echo "queue_count: $($EXIMBIN -bpc 2>&1)"
            echo "frozen: $($EXIMBIN -bpr 2>/dev/null | grep -c frozen)"
            echo "## exiqsumm -c (per destination domain; first 25 lines)"
            $EXIMBIN -bp 2>/dev/null | exiqsumm -c 2>&1 | head -n 25 | mask
            echo "## routing summary (exim -bP: smarthost / configtype only)"
            grep -E '^dc_(eximconfig_configtype|smarthost|local_interfaces)=' /etc/exim4/update-exim4.conf.conf 2>/dev/null | mask ;;
        postfix)
            echo "queue_count: $(postqueue -j 2>/dev/null | grep -c . || mailq 2>/dev/null | tail -n 1)"
            echo "## postconf (relayhost, inet_interfaces, smtp_tls_security_level)"
            postconf -h relayhost inet_interfaces smtp_tls_security_level 2>&1 | mask ;;
        *) echo "no exim or postfix found" ;;
    esac
}
# R-MAIL-02: delivery counts per day and failure reasons (classes only, never addresses)
s_mail02() {
    local -a files=()
    case $MTA in
        exim)
            mapfile -t files < <(log_chain "$EXIM_MAINLOG")
            printf 'input: %s\n' "${files[@]}"
            ((${#files[@]})) || return 0
            zcat -f -- "${files[@]}" | awkn -v cutoff="$CUTOFF" -v outdir="$OUT/50_cron_mail" -e '
            BEGIN { lib_init() }
            /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
                ts = mktime(substr($0,1,4) " " substr($0,6,2) " " substr($0,9,2) " " substr($0,12,2) " " substr($0,15,2) " " substr($0,18,2))
                if (ts < cutoff) next
                d = substr($0, 1, 10); D[d] = 1
                for (i = 3; i <= 6 && i <= NF; i++) if ($i ~ /^(<=|=>|->|\*\*|==)$/) {
                    C[d, $i]++
                    if ($i == "**" || $i == "==") {
                        r = ""; for (j = i + 1; j <= NF; j++) r = r " " $j
                        r = maskfree(r)
                        if (match(r, / (R|T|H|P|F|U|S|X)=|: /)) r = " <rcpt>" substr(r, RSTART); else r = " <rcpt>"
                        if (match(r, /: [245][0-9][0-9][ -]/)) {
                            rep = tolower(substr(r, RSTART + 2))
                            cls = (rep ~ /unknown|not exist|no such|not found|invalid (recipient|mailbox|address)|disabled|inactive|rejected/) ? "user-unknown" : \
                                  (rep ~ /greylist|try again|temporar|rate|too many|deferred/) ? "temporary" : \
                                  (rep ~ /quota|full|storage|over limit/) ? "mailbox-full" : \
                                  (rep ~ /spam|block|blacklist|denylist|reputation|policy|spf|dkim|dmarc|authenticat|relay/) ? "policy" : "other"
                            r = substr(r, 1, RSTART + 1) substr(rep, 1, 3) " <" cls ">"
                        }
                        gsub(/"[^"]*"/, "\"S\"", r)
                        gsub(/[0-9]+/, "N", r); gsub(/<ipN>/, "<ip6>", r); gsub(/\t/, " ", r)
                        R[$i substr(r, 1, 140)]++
                    }
                    break
                }
            }
            END {
                f = outdir "/mail_daily.tsv"
                print "day\tarrivals(<=)\tdeliveries(=>)\tadditional(->)\tfailed(**)\tdeferred(==)" > f
                n = asorti(D, o)
                for (k = 1; k <= n; k++) printf "%s\t%d\t%d\t%d\t%d\t%d\n", o[k], C[o[k],"<="], C[o[k],"=>"], C[o[k],"->"], C[o[k],"**"], C[o[k],"=="] > f
                f = outdir "/mail_fail_reasons.tsv"
                print "count\tflag_and_reason" > f
                n = asorti(R, o, "@val_num_desc")
                for (k = 1; k <= n && k <= 20; k++) printf "%d\t%s\n", R[o[k]], o[k] > f
            }' ;;
        postfix)
            # /var/log/mail.log when rsyslog writes it, else the journal of the postfix units.
            if [[ -f $POSTFIX_LOG ]]; then
                mapfile -t files < <(log_chain "$POSTFIX_LOG"); printf 'input: %s\n' "${files[@]}"
                ((${#files[@]})) || return 0
                zcat -f -- "${files[@]}"
            else
                echo "input: journalctl -u postfix*" >&2
                journalctl -u 'postfix*' --since "$SINCE" -o short-iso --no-pager -q 2>/dev/null
            fi | awkn -v cutoff="$CUTOFF" -v outdir="$OUT/50_cron_mail" -v yr="$(date +%Y)" -e '
            BEGIN { lib_init() }
            / status=(sent|deferred|bounced|expired) / {
                if (match($0, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})/, t)) ts = mktime(t[1] " " t[2] " " t[3] " " t[4] " " t[5] " " t[6])
                else if (match($0, /^([A-Z][a-z][a-z]) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})/, t)) ts = mktime(yr " " MON[t[1]] " " t[2] " " t[3] " " t[4] " " t[5])
                else next
                if (ts < cutoff) next
                d = strftime("%Y-%m-%d", ts); D[d] = 1
                match($0, / status=([a-z]+) /, s); st = s[1]; C[d, st]++
                if (st != "sent") {
                    r = $0; sub(/^.* status=[a-z]+ /, "", r); r = tolower(maskfree(r))
                    cls = (r ~ /unknown|not exist|no such|not found|invalid (recipient|mailbox|address)|disabled|inactive/) ? "user-unknown" : \
                          (r ~ /greylist|try again|temporar|rate|too many|timed out|connection refused/) ? "temporary" : \
                          (r ~ /quota|full|storage|over limit/) ? "mailbox-full" : \
                          (r ~ /spam|block|blacklist|denylist|reputation|policy|spf|dkim|dmarc|authenticat|relay/) ? "policy" : "other"
                    R[st " <" cls ">"]++
                }
            }
            END {
                f = outdir "/mail_daily.tsv"
                print "day\tsent\tdeferred\tbounced\texpired" > f
                n = asorti(D, o)
                for (k = 1; k <= n; k++) printf "%s\t%d\t%d\t%d\t%d\n", o[k], C[o[k],"sent"], C[o[k],"deferred"], C[o[k],"bounced"], C[o[k],"expired"] > f
                f = outdir "/mail_fail_reasons.tsv"
                print "count\tstatus_and_class" > f
                n = asorti(R, o, "@val_num_desc")
                for (k = 1; k <= n; k++) printf "%d\t%s\n", R[o[k]], o[k] > f
            }' ;;
        *) echo "no exim or postfix found" ;;
    esac
}
# R-MAIL-03 (only the last 20 MB of the web user's mailbox is read).  Subjects are classified into a fixed set:
# only cron subjects (system-generated) keep their text, scrubbed; everything else is "mail delivery failure" or
# "other (not shown)", so student names in Moodle notification subjects never reach the output.
s_mail03() {
    local f=$MAILBOX
    [[ -f $f ]] || { echo "$f absent"; return 0; }
    echo "stat: $(stat -c '%s bytes, modified %y' -- "$f")"
    echo "sample: last 20000000 bytes"
    tail -c 20000000 -- "$f" | awkn -e '
        /^From / { from++; hdr = 1 }
        /^$/ { hdr = 0 }
        hdr && /^Date: / {
            d = "<unparsed>"
            if (match($0, /[0-9]{1,2} [A-Z][a-z][a-z] [0-9]{4} [0-9]{2}:[0-9]{2}(:[0-9]{2})?( [+-][0-9]{4})?/)) d = substr($0, RSTART, RLENGTH)
            if (first == "") first = d; last = d
        }
        hdr && /^Subject: / {
            s = substr($0, 10)
            gsub(/=\?[^?]+\?[BbQq]\?[^?]*\?=/, "<encoded>", s); gsub(/[\200-\377]+/, "<txt>", s)
            if (s ~ /^Cron </) { s = maskfree(s); gsub(/[0-9]+/, "N", s); c = "cron: " substr(s, 1, 60) }
            else if (s ~ /^(Mail delivery failed|Undelivered Mail|Delivery Status Notification|Returned mail|Undeliverable)/) c = "mail delivery failure"
            else c = "other (not shown)"
            S[c]++
        }
        END {
            print "messages_in_sample: " from + 0
            print "first_date: " first
            print "last_date: " last
            print "## top 20 subject classes (cron subjects scrubbed, digits -> N; other subjects are not shown)"
            n = asorti(S, o, "@val_num_desc")
            for (i = 1; i <= n && i <= 20; i++) printf "%7d %s\n", S[o[i]], o[i]
        }' | mask
}
# R-MAIL-04: stat of the local mailboxes only (size and times); content is not read here.
s_mail_stat() {
    local f
    for f in $MAILBOX /var/mail/root; do
        [[ -e $f ]] || { echo "$f absent"; continue; }
        stat --printf 'path: %n\nsize_bytes: %s\nmode: %A\nowner: %U:%G\nmtime: %y\n\n' -- "$f"
    done
    echo "collected_at: $(date '+%Y-%m-%d %H:%M:%S %z')"
}

# R-SEC-01
# ufw itself writes /run/ufw.lock even for 'status'; read its config files instead (live rules: nft_masked.txt).
s_sec_ufw() {
    if [[ ! -e /etc/ufw/ufw.conf ]]; then echo "ufw not installed (see nft_masked.txt for the live rules)"; return 0; fi
    { grep -hE '^(ENABLED|LOGLEVEL)=' /etc/ufw/ufw.conf; grep -hE '^DEFAULT_' /etc/default/ufw; grep -h '^### tuple' /etc/ufw/user.rules /etc/ufw/user6.rules; } 2>&1 | mask
    return 0
}
s_sec_nft()    { nft list ruleset 2>&1 | head -c 200000 | mask; }
s_sec_listen() { echo "## tcp"; ss -Htlnp 2>&1 | mask; echo "## udp"; ss -Hulnp 2>&1 | mask; }
s_sec_sshd()   { sshd -T 2>&1 | grep -iE '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|maxstartups|maxauthtries|pubkeyauthentication|usepam|port) '; return 0; }
s_sec_btmp() {
    printf 'day\tfailed_logins\tdistinct_sources\n'
    local f
    for f in "$BTMP_BASE"*; do [[ -f $f ]] && utmpdump -- "$f" 2>/dev/null; done | gawk -F'\\] \\[' '
        {
            if (!match($NF, /([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})[,.][0-9]+([+-])([0-9]{2}):?([0-9]{2})/, t)) next
            ts = mktime(t[1] " " t[2] " " t[3] " " t[4] " " t[5] " " t[6], 1)
            off = t[8] * 3600 + t[9] * 60; ts -= (t[7] == "-") ? -off : off
            d = strftime("%Y-%m-%d", ts)
            src = $(NF - 1); gsub(/ /, "", src)
            N[d]++
            if (!((d, src) in S)) { S[d, src] = 1; U[d]++ }
        }
        END { n = asorti(N, o); for (i = 1; i <= n; i++) printf "%s\t%d\t%d\n", o[i], N[o[i]], U[o[i]] }'
}
s_sec_f2b() {
    local f
    for f in "$F2B_DIR"/jail.local "$F2B_DIR"/jail.d/*.conf "$F2B_DIR"/jail.d/*.local; do
        [[ -f $f ]] || continue
        echo "##### $f"
        mask < "$f"
    done
    echo "## ls -la /var/log/fail2ban.log"
    ls -la /var/log/fail2ban.log 2>&1
    echo "## systemctl is-active fail2ban: $(systemctl is-active fail2ban 2>&1)"
    return 0
}
s_sec_certs() {
    local c
    for c in "$LE_DIR"/live/*/cert.pem; do
        [[ -f $c ]] || continue
        echo "## $c"
        openssl x509 -in "$c" -noout -subject -enddate 2>&1
    done
    echo "## ls -la $LE_DIR/renewal/"
    ls -la "$LE_DIR"/renewal/ 2>&1
    return 0
}
s_sec_le() { tail -n 150 "$LE_LOG" 2>&1 | mask; }
# Secret-bearing files that are readable by every account (mode only; contents are never read).
s_sec_modes() {
    printf 'mode\towner\tpath\tnote\n'
    stat -c '%a\t%U:%G\t%n\tMoodle config.php (any mode; 640 owner:webgroup is typical)' -- "$MOODLE/config.php" 2>/dev/null
    find /var/www /srv /opt -maxdepth 4 \( -name '.env' -o -path '*/bootstrap/cache/config.php' \) \
        -type f -perm -o=r -printf '%m\t%u:%g\t%p\tworld-readable\n' 2>/dev/null | grep -v '/vendor/' | head -n 100
    find /home /root -maxdepth 2 -name '.my.cnf' -type f -printf '%m\t%u:%g\t%p\tclient credentials file\n' 2>/dev/null
    return 0
}

# R-NET-01 (counts only, about 20 s)
s_net01() {
    local t0="$WORK/net_t0" t1="$WORK/net_t1" s0 s1 i
    printf 'ts\tsample\tlocal_port\tcount\tdistinct_src\tdistinct_src16\n'
    cat /proc/net/netstat /proc/net/snmp > "$t0"; s0=$(date +%s.%N)
    : > "$WORK/synrecv_rows.tsv"
    for i in 1 2 3; do
        ss -Htn state syn-recv 2>/dev/null | gawk -f "$HERE/synrecv.awk" -v sample="$i" -v ts="$(date '+%Y-%m-%d %H:%M:%S')" \
            | tee -a "$WORK/synrecv_rows.tsv"
        ((i < 3)) && sleep "$NET_SLEEP"
    done
    cat /proc/net/netstat /proc/net/snmp > "$t1"; s1=$(date +%s.%N)
    gawk -f "$HERE/netcounters.awk" -v secs="$(awk -v a="$s0" -v b="$s1" 'BEGIN { printf "%.1f", b - a }')" "$t0" "$t1" \
        > "$OUT/70_network/tcp_counters_t0_t20.tsv"
    s_net01_byport "$WORK/synrecv_rows.tsv" > "$OUT/70_network/synrecv_by_port.tsv"
    rm -f -- "$t0" "$t1" "$WORK/synrecv_rows.tsv"
}
# SYN-RECV per local port over the 3 samples, next to that port's listen backlog and the SYN-queue sysctls.
s_net01_byport() { # synrecv rows file
    local lst="$WORK/listen_backlog.txt" sy=/proc/sys/net
    ss -Htln 2>/dev/null > "$lst"
    gawk -v msb="$(cat $sy/ipv4/tcp_max_syn_backlog 2>/dev/null)" -v smc="$(cat $sy/core/somaxconn 2>/dev/null)" \
         -v sar="$(cat $sy/ipv4/tcp_synack_retries 2>/dev/null)" -v cks="$(cat $sy/ipv4/tcp_syncookies 2>/dev/null)" '
        FILENAME == ARGV[1] { split($0, f, " "); k = split(f[4], p, ":"); port = p[k]
                              if (!(port in BL) || f[3] + 0 > BL[port]) BL[port] = f[3] + 0
                              if (!(port in AQ) || f[2] + 0 > AQ[port]) AQ[port] = f[2] + 0
                              next }
        { split($0, r, "\t") }
        r[3] == "ALL" { NS[r[2]] = 1; next }
        { port = r[3]; c = r[4] + 0; P[port] = 1; S[port]++; TOT[port] += c; if (!(port in MN) || c < MN[port]) MN[port] = c; if (c > MX[port] + 0) MX[port] = c }
        END {
            ns = length(NS); P["80"] = 1; P["443"] = 1
            print "local_port\tsamples\tsynrecv_min\tsynrecv_max\tsynrecv_mean\tlisten_backlog\taccept_queue_now\tmax_pct_of_backlog\ttcp_max_syn_backlog\tsomaxconn\ttcp_synack_retries\ttcp_syncookies"
            n = asorti(P, o, "@ind_num_asc")
            for (i = 1; i <= n; i++) {
                q = o[i]; mn = (S[q] + 0 < ns) ? 0 : MN[q] + 0; bl = (q in BL) ? BL[q] : ""
                printf "%s\t%d\t%d\t%d\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", q, ns, mn, MX[q] + 0, (ns ? TOT[q] / ns : 0), bl,
                    ((q in AQ) ? AQ[q] : ""), (bl > 0 ? sprintf("%.1f", 100 * MX[q] / bl) : ""), msb, smc, sar, cks
            }
        }' "$lst" "$1"
    rm -f -- "$lst"
}
# R-NET-02 (only with --with-tcpdump; the pipe goes straight into awk, no pcap)
s_net02() {
    local ifc
    ifc=$(ip route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    ifc=${ifc:-eth0}
    echo "interface: $ifc  window: 20 s  max packets: 2000"
    timeout 20 tcpdump -p -l -ni "$ifc" -nn -v -c 2000 \
        'tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn and (dst port 80 or dst port 443)' 2>/dev/null \
        | gawk -f "$HERE/tcpdump_syn.awk"
}

# R-BASE-01: an earlier audit's Markdown reports (masked copies), for before/after comparison.
s_base01() {
    local src=$BASELINE_DIR dst="$OUT/80_baseline/${BASELINE_DIR##*/}" f
    ls -la "$src" 2>&1
    [[ -d $src ]] || return 0
    mkdir -p -- "$dst"
    for f in "$src"/*.md; do
        [[ -f $f ]] || continue
        mask < "$f" | sed -E 's/((pass(word)?|secret|token|key)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1<redacted>/Ig' \
            | head -c "$CAP" > "$dst/${f##*/}"
        echo "copied (masked): ${f##*/}"
    done
}

# ------------------------------------------------------------ post-processing
# A .gz over CAP is rebuilt as a valid gzip of its first CAP bytes of text plus a marker.  A text file over
# CAP + 64 (run() already leaves CAP + marker) is truncated.
enforce_caps() {
    local f
    while IFS= read -r -d '' f; do
        if [[ $f == *.gz ]]; then
            { zcat -f -- "$f" 2>/dev/null | head -c "$CAP"; printf '\n[TRUNCATED at %d bytes of text]\n' "$CAP"; } \
                | gzip -9c > "$f.tmp" && mv -f -- "$f.tmp" "$f"
            log "CAP   ${f#"$OUT"/} recompressed from its first 5 MB of text"
        else
            truncate -s "$CAP" -- "$f"
            printf '\n[TRUNCATED at %d bytes]\n' "$CAP" >> "$f"
            log "CAP   ${f#"$OUT"/} truncated to 5 MB"
        fi
    done < <(find "$OUT" -path "$WORK" -prune -o -type f \
                \( \( -name '*.gz' -size +"$CAP"c \) -o \( ! -name '*.gz' -size +"$((CAP + 64))"c \) \) -print0)
}

privacy_check() {
    local f rel pc="$OUT/PRIVACY_CHECK.txt" rows="$WORK/privacy_rows.tsv"
    : > "$rows"
    while IFS= read -r -d '' f; do
        rel=${f#"$OUT"/}
        [[ $rel == PRIVACY_CHECK.txt ]] && continue
        zcat -f -- "$f" 2>/dev/null | gawk -f "$HERE/privacy_scan.awk" -v name="$rel" -v origin_ip="$ORIGIN_IP" >> "$rows"
    done < <(find "$OUT" -path "$WORK" -prune -o -type f -print0 | sort -z)
    {
        echo "PRIVACY_CHECK for $NAME ($(date '+%Y-%m-%d %H:%M:%S %z'))"
        echo "Residual matches per file after masking (gz files are scanned decompressed)."
        echo "ipv4  = dotted quads not on the allowlist (the server's own address ${ORIGIN_IP:-<unknown>}, 127/8, 0.0.0.0, 10/8, 172.16/12, 192.168/16, 169.254/16)."
        echo "email = user@domain.tld, also %40-encoded."
        echo "phone = Saudi mobile ((+|00)966 or 05x forms, ASCII or Arabic-Indic digits) and any '+'-prefixed number of 9-15 digits (not inside 32+ hex tokens such as digest hashes)."
        echo "ipv6  = IPv6 addresses (with '::' or 8 groups; ::1 and x:y::/32 aggregates excluded)."
        echo "other = secrets in clear: JWT/base64 JSON, password/token/secret values, user:pass@, -u user:pass, -pX."
        echo "Any non-zero count blocks the tarball unless the operator confirms (or --yes was given)."
        echo
        printf 'file\tipv4\temail\tphone\tipv6\tother\n'
        cat "$rows"
        gawk -F'\t' '{ a += $2; b += $3; c += $4; d += $5; e += $6; if ($2 + $3 + $4 + $5 + $6 > 0) n++ }
            END { printf "TOTAL\t%d\t%d\t%d\t%d\t%d\nFILES_WITH_RESIDUALS\t%d\n", a, b, c, d, e, n }' "$rows"
    } > "$pc"
    RESIDUAL_FILES=$(gawk -F'\t' '$2 + $3 + $4 + $5 + $6 > 0 { print $1 }' "$rows")
}

make_tarball() {
    local sz
    if [[ -e $OUT.tar.gz || -L $OUT.tar.gz ]]; then log "tarball $OUT.tar.gz already exists; not overwriting"; return 1; fi
    tar -C "$OUTBASE" --exclude="$NAME/.work" -czf "$OUT.tar.gz" -- "$NAME" || { log "tar failed"; return 1; }
    [[ -L $OUT.tar.gz ]] || chmod 0600 -- "$OUT.tar.gz"
    sz=$(stat -c %s -- "$OUT.tar.gz")
    if ((sz > TARMAX)); then
        log "WARNING: tarball is $sz bytes, over the 50 MB limit; removed. Largest files:"
        find "$OUT" -path "$WORK" -prune -o -type f -printf '%s\t%P\n' | sort -rn | head -n 10 >&2
        rm -f -- "$OUT.tar.gz"
        return 1
    fi
    log "tarball: $OUT.tar.gz ($sz bytes)"
    return 0
}

# ------------------------------------------------------------ discovery helpers (used before the steps)
# access_log / CustomLog paths of one config file: prints "path<TAB>format" (nginx) or "path<TAB>combined" (apache)
cfg_logs() { # file kind(access|error)
    local f=$1 kind=$2
    if [[ $WEB == nginx ]]; then
        if [[ $kind == access ]]; then
            grep -hE '^[[:space:]]*access_log[[:space:]]+/' -- "$f" 2>/dev/null | grep -v ' if=' \
                | sed -E 's/^[[:space:]]*access_log[[:space:]]+([^[:space:];]+)([[:space:]]+([^[:space:];]+))?.*/\1\t\3/'
        else
            grep -hE '^[[:space:]]*error_log[[:space:]]+/' -- "$f" 2>/dev/null | sed -E 's/^[[:space:]]*error_log[[:space:]]+([^[:space:];]+).*/\1\t/'
        fi
    else
        if [[ $kind == access ]]; then
            grep -hE '^[[:space:]]*CustomLog[[:space:]]' -- "$f" 2>/dev/null \
                | sed -E 's/^[[:space:]]*CustomLog[[:space:]]+"?([^"[:space:]]+)"?[[:space:]]+([^[:space:]]+).*/\1\t\2/; s#\$\{APACHE_LOG_DIR\}#/var/log/apache2#'
        else
            grep -hE '^[[:space:]]*ErrorLog[[:space:]]' -- "$f" 2>/dev/null \
                | sed -E 's/^[[:space:]]*ErrorLog[[:space:]]+"?([^"[:space:]]+)"?.*/\1\t/; s#\$\{APACHE_LOG_DIR\}#/var/log/apache2#'
        fi
    fi
}
# Format: decided from the data (the last 300 lines), so a custom log_format name does not matter.
detect_fmt() { # file -> "perf|combined|unknown<TAB>reason"
    local f=$1 n p c
    if [[ ! -r $f ]]; then printf 'combined\tlog not readable as %s\n' "$(id -un)"; return; fi
    read -r n p c < <(tail -n 300 -- "$f" 2>/dev/null | gawk '
        { n++ }
        / rt=[0-9.]+ urt=([0-9.]+|-)/ { p++ }
        /^[^ ]+ [^ ]+ [^ ]+ \[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9:]{8} [+-][0-9]{4}\] "/ { c++ }
        END { print n + 0, p + 0, c + 0 }')
    if ((n == 0)); then printf 'combined\tlog empty\n'
    elif ((p * 10 >= n * 8)); then printf 'perf\t%s of the last %s lines carry rt=/urt=\n' "$p" "$n"
    elif ((c * 10 >= n * 8)); then printf 'combined\tcombined layout, no timings (add the perf log format: references/observability.md)\n'
    else printf 'unknown\tonly %s of %s lines look like combined: custom format, the aggregator will skip lines\n' "$c" "$n"; fi
}
# ------------------------------------------------------------ library mode (tests only)
if [[ "${MSC_COLLECT_LIB:-0}" == 1 ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

usage() {
    cat <<EOF
Usage: sudo bash $SELF [options]
  --days N          history window in days (default 14, 1..60)
  --split DATE      YYYY-MM-DD: P0 = before, P1 = from DATE on (default: none, P1 = whole window)
  --env FILE        server.env from skills/start/scripts/detect-env.sh (default: the invoking user's
                    ~/.config/moodle-server-care/server.env)
  --moodle DIR      Moodle code root (overrides server.env)
  --site-log FILE   the site's access log (default: from the web server config)
  --focus-date DATE package history also covers the day before DATE (an unexplained restart, for example)
  --baseline DIR    an earlier audit's folder of .md reports, copied masked for comparison
  --with-tcpdump    also take a 20 s SYN-packet aggregate (no pcap is saved)
  --no-moodle-cli   skip the Moodle CLI steps (checks.php, moodle_info.php as the web user)
  --load-max N      load guard (default: 3/4 of the CPU count, at least 2)
  --force           run even if the 1-minute load is above the guard
  --yes             create the tarball without asking, even if PRIVACY_CHECK finds residuals
  --dry-run         print the planned steps and the files they would read; read nothing else
  --version         print the collector version and exit
Environment: OUTBASE (default ~operator/moodle-audit/collect), COLLECT_OWNER (default the sudo user), MSC_TZ.
Version: $VERSION
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Test mode points the inputs at other files and sources an override file; never as root.
if ((EUID == 0)) && [[ ${MSC_COLLECT_TEST:-0} == 1 ]]; then die "test mode (MSC_COLLECT_TEST=1) refused as root"; fi

# ------------------------------------------------------------ arguments
DAYS=14; SPLIT=""; WITH_TCPDUMP=0; FORCE=0; YES=0; DRY_RUN=0; MOODLE_CLI=1
OPT_ENV=""; OPT_MOODLE=""; OPT_SITE_LOG=""; FOCUS=""; BASELINE_DIR=""; LOAD_MAX=""
while (($#)); do
    case $1 in
        --days)          (($# >= 2)) || die "--days needs a value"; DAYS=$2; shift 2 ;;
        --days=*)        DAYS=${1#*=}; shift ;;
        --split|--surge) (($# >= 2)) || die "--split needs a value"; SPLIT=$2; shift 2 ;;
        --split=*|--surge=*) SPLIT=${1#*=}; shift ;;
        --env)           (($# >= 2)) || die "--env needs a value"; OPT_ENV=$2; shift 2 ;;
        --moodle)        (($# >= 2)) || die "--moodle needs a value"; OPT_MOODLE=$2; shift 2 ;;
        --site-log)      (($# >= 2)) || die "--site-log needs a value"; OPT_SITE_LOG=$2; shift 2 ;;
        --focus-date)    (($# >= 2)) || die "--focus-date needs a value"; FOCUS=$2; shift 2 ;;
        --baseline)      (($# >= 2)) || die "--baseline needs a value"; BASELINE_DIR=$2; shift 2 ;;
        --load-max)      (($# >= 2)) || die "--load-max needs a value"; LOAD_MAX=$2; shift 2 ;;
        --with-tcpdump)  WITH_TCPDUMP=1; shift ;;
        --no-moodle-cli) MOODLE_CLI=0; shift ;;
        --force)         FORCE=1; shift ;;
        --yes|-y)        YES=1; shift ;;
        --dry-run|-n)    DRY_RUN=1; shift ;;
        --version|-V)    echo "moodle-audit-collect.sh $VERSION"; exit 0 ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ $DAYS =~ ^[0-9]+$ ]] || die "--days must be an integer 1..60"
DAYS=$((10#$DAYS))
((DAYS >= 1 && DAYS <= 60)) || die "--days must be an integer 1..60"
SPLIT_EPOCH=0
if [[ -n $SPLIT ]]; then
    [[ $SPLIT =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--split must be YYYY-MM-DD"
    SPLIT_EPOCH=$(date -d "$SPLIT 00:00:00" +%s 2>/dev/null) || die "--split: invalid date '$SPLIT'"
fi
[[ -z $FOCUS || $FOCUS =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--focus-date must be YYYY-MM-DD"
[[ -z $LOAD_MAX || $LOAD_MAX =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--load-max must be a number"
[[ -n ${MSC_TZ:-} ]] && export TZ=$MSC_TZ

if ((!DRY_RUN)) && ((EUID != 0)) && [[ "${MSC_COLLECT_TEST:-0}" != 1 ]]; then
    echo "ERROR: moodle-audit-collect.sh must run as root, because it reads root-only logs" >&2
    echo "       (web server, php-fpm, database, mail, journal)." >&2
    echo "Run:   sudo bash $SELF --days $DAYS" >&2
    echo "Or:    bash $SELF --dry-run    (no root needed; shows the plan)" >&2
    exit 1
fi

# ------------------------------------------------------------ site facts (server.env, parsed, never sourced)
OPERATOR=${SUDO_USER:-$(id -un)}
OPHOME=$(getent passwd "$OPERATOR" 2>/dev/null | cut -d: -f6); OPHOME=${OPHOME:-$HOME}
ENV_SRC=${OPT_ENV:-$OPHOME/.config/moodle-server-care/server.env}
envget() { # key -> value from $ENV_SRC: plain, 'quoted' or printf-%q values; never sourced (we are root)
    local line v owner mode
    [[ -f $ENV_SRC && ! -L $ENV_SRC ]] || return 1
    owner=$(stat -c %u -- "$ENV_SRC" 2>/dev/null) && mode=$(stat -c %a -- "$ENV_SRC" 2>/dev/null) || return 1
    if [[ $owner != 0 && $owner != "$(id -u -- "$OPERATOR" 2>/dev/null)" ]] || (( 8#$mode & 8#022 )); then
        echo "WARNING: $ENV_SRC has an unexpected owner (uid $owner) or mode ($mode); ignored" >&2; return 1
    fi
    line=$(grep -m1 -E "^$1=" -- "$ENV_SRC" 2>/dev/null) || return 1
    v=${line#*=}
    case $v in
        \'*\') v=${v:1:${#v}-2} ;;
        *\\*) v=$(printf '%s' "$v" | sed 's/\\\(.\)/\1/g') ;;
    esac
    if [[ $v =~ ^[A-Za-z0-9_./:@%+,=()\ -]*$ ]]; then printf '%s' "$v"; return 0; fi
    echo "WARNING: $1 in $ENV_SRC has characters this script does not parse; pass it as an option" >&2
    return 1
}
cfgval() { sed -nE "s/^[[:space:]]*\\\$CFG->$2[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n 1; }

MOODLE=${OPT_MOODLE:-$(envget MOODLE)}
[[ -n $MOODLE ]] || [[ ${MSC_COLLECT_TEST:-0} == 1 ]] || die "no Moodle directory: run skills/start/scripts/detect-env.sh first, or pass --moodle DIR"
MOODLE=${MOODLE%/}
DOCROOT=$(envget DOCROOT); DATAROOT=$(envget DATAROOT); SITE=$(envget SITE); RELEASE=$(envget RELEASE)
DBTYPE=$(envget DBTYPE); DBNAME=$(envget DBNAME); PHPBIN=$(envget PHP); FPM_SOCK=$(envget FPM_SOCK)
WEBUSER=$(envget WEBUSER); VHOST=$(envget VHOST); ORIGIN_IP=$(envget ORIGIN_IP)
if [[ -n $OPT_MOODLE || -z $SITE ]]; then
    # derive the minimum from config.php (only these non-secret keys are read)
    if [[ -r $MOODLE/config.php ]]; then
        SITE=$(cfgval "$MOODLE/config.php" wwwroot | sed -E 's#^[a-z]+://##; s#/.*##')
        DBTYPE=$(cfgval "$MOODLE/config.php" dbtype); DBNAME=$(cfgval "$MOODLE/config.php" dbname)
        DATAROOT=$(cfgval "$MOODLE/config.php" dataroot)
    fi
    if [[ -f $MOODLE/public/version.php ]]; then DOCROOT=$MOODLE/public; else DOCROOT=$MOODLE; fi
    ENV_SRC="config.php of $MOODLE (no server.env used)"
fi
DOCROOT=${DOCROOT:-$MOODLE}
[[ -n $RELEASE ]] || RELEASE=$(sed -nE "s/^\\\$release[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/p" "$DOCROOT/version.php" 2>/dev/null | head -n 1)
[[ -n $PHPBIN ]] || PHPBIN=php$(ls -d /etc/php/*/fpm 2>/dev/null | cut -d/ -f4 | sort -V | tail -n 1)
PHPV=${PHPBIN#php}
WEBUSER=${WEBUSER:-www-data}
[[ $ORIGIN_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ORIGIN_IP=""

# ------------------------------------------------------------ constants
HOST=$(hostname -s 2>/dev/null || hostname)
STAMP=$(date +%Y%m%d-%H%M)
OUTBASE=${OUTBASE:-$OPHOME/moodle-audit/collect}
OUTBASE=${OUTBASE%/}
NAME="audit-${HOST}-${STAMP}"
OUT="$OUTBASE/$NAME"
WORK="$OUT/.work"
ERRLOG="$OUT/00_meta/run.log"
OWNER=${COLLECT_OWNER:-$OPERATOR}
CAP=$((5 * 1024 * 1024))
TARMAX=$((50 * 1024 * 1024))
NOW=$(date +%s)
CUTOFF=$((NOW - DAYS * 86400))
SINCE=$(date -d "@$CUTOFF" '+%Y-%m-%d %H:%M:%S')
SINCE7=$(date -d "@$((NOW - 7 * 86400))" '+%Y-%m-%d %H:%M:%S')
BTMP_BASE=/var/log/btmp
UU_LOGDIR=/var/log/unattended-upgrades
LE_LOG=/var/log/letsencrypt/letsencrypt.log
LE_DIR=/etc/letsencrypt
F2B_DIR=/etc/fail2ban
REDIS_CONF=/etc/redis/redis.conf
FPM_CONF_DIR=/etc/php/$PHPV/fpm
LOADAVG_FILE=/proc/loadavg
DB_DELTA=60          # minimum seconds between status_t0 and status_t60 (rates use the real gap)
NET_SLEEP=10         # seconds between the 3 SYN-RECV samples
DB08_SAMPLES=3       # R-DB-08 socket-peer samples
DB08_SLEEP=5         # seconds between them
APT_HISTORY=/var/log/apt/history.log
DPKG_LOG=/var/log/dpkg.log
EXIM_MAINLOG=/var/log/exim4/mainlog
POSTFIX_LOG=/var/log/mail.log
MAILBOX=/var/mail/$WEBUSER
PROCFS=/proc         # not named PROC_ROOT: iproute2's ss reads that variable and then skips netlink
MYSQL_DATADIR=/var/lib/mysql
MASK="$HERE/mask.sed"
MASK6OFF="$WORK/mask_nov6.sed"
KPAT='out of memory|oom-kill|killed process|hung_task|blocked for more than|soft lockup|rcu.*stall|I/O error|EXT4-fs error|XFS .*error|SYN flooding|conntrack: table full|segfault|general protection'
if [[ -z $LOAD_MAX ]]; then LOAD_MAX=$(( $(nproc) * 3 / 4 )); ((LOAD_MAX < 2)) && LOAD_MAX=2; fi
PKG_SINCE_EPOCH=$CUTOFF
if [[ -n $FOCUS ]]; then
    f_ep=$(date -d "$FOCUS 00:00:00 1 day ago" +%s 2>/dev/null) || die "--focus-date: invalid date"
    ((f_ep < PKG_SINCE_EPOCH)) && PKG_SINCE_EPOCH=$f_ep
fi
if ((DAYS < 7)); then CERT_SINCE=$SINCE7; else CERT_SINCE=$SINCE; fi
read -r LOAD1 _ < /proc/loadavg
LOADAVG_START=$(cat /proc/loadavg)

# ------------------------------------------------------------ discovery of logs and services (read-only)
WEB=none
if command -v nginx >/dev/null 2>&1 || [[ -x /usr/sbin/nginx ]]; then WEB=nginx
elif command -v apache2 >/dev/null 2>&1 || [[ -x /usr/sbin/apache2 ]]; then WEB=apache; fi

if [[ $WEB == nginx ]]; then CONF_FILES=$(ls /etc/nginx/nginx.conf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf 2>/dev/null)
elif [[ $WEB == apache ]]; then CONF_FILES=$(ls /etc/apache2/apache2.conf /etc/apache2/sites-enabled/* 2>/dev/null)
else CONF_FILES=""; fi
if [[ -z $VHOST && -n $SITE && -n $CONF_FILES ]]; then
    # shellcheck disable=SC2086
    VHOST=$(grep -lE "(server_name|ServerName|ServerAlias)[^;]*[[:space:]]$SITE([[:space:];]|$)" $CONF_FILES 2>/dev/null | head -n 1)
fi
SITE_LOG=""; SITE_LOG_FMTNAME=""; SITE_ERRLOG=""
if [[ -n $OPT_SITE_LOG ]]; then SITE_LOG=$OPT_SITE_LOG
elif [[ -n $VHOST ]]; then
    IFS=$'\t' read -r SITE_LOG SITE_LOG_FMTNAME < <(cfg_logs "$VHOST" access | head -n 1)
    IFS=$'\t' read -r SITE_ERRLOG _ < <(cfg_logs "$VHOST" error | head -n 1)
fi
if [[ -z $SITE_LOG ]]; then
    if [[ $WEB == nginx ]]; then SITE_LOG=/var/log/nginx/access.log; elif [[ $WEB == apache ]]; then SITE_LOG=/var/log/apache2/access.log; fi
fi
if [[ -z $SITE_ERRLOG ]]; then
    if [[ $WEB == nginx ]]; then SITE_ERRLOG=/var/log/nginx/error.log; elif [[ $WEB == apache ]]; then SITE_ERRLOG=/var/log/apache2/error.log; fi
fi
IFS=$'\t' read -r SITE_FMT SITE_FMT_WHY < <(detect_fmt "$SITE_LOG")
[[ $SITE_FMT == unknown ]] && SITE_FMT=combined
# other access logs on the box (other vhosts), at most 8, aggregated in combined mode
OTHER_LOGS=""
if [[ -n $CONF_FILES ]]; then
    while IFS=$'\t' read -r p _; do
        [[ -z $p || $p == "$SITE_LOG" || $p == off ]] && continue
        [[ " $OTHER_LOGS " == *" $p "* ]] && continue
        OTHER_LOGS="${OTHER_LOGS:+$OTHER_LOGS }$p"
    done < <(for f in $CONF_FILES; do cfg_logs "$f" access; done | head -n 40)
    OTHER_LOGS=$(tr ' ' '\n' <<< "$OTHER_LOGS" | head -n 8 | tr '\n' ' ')
fi
# error logs: "label=path" pairs
ERR_LOGS="site=$SITE_ERRLOG"
if [[ -n $CONF_FILES ]]; then
    while IFS=$'\t' read -r p _; do
        [[ -z $p || $p == "$SITE_ERRLOG" ]] && continue
        lbl=${p##*/}; lbl=${lbl%.log}
        [[ " $ERR_LOGS " == *"=$p "* || " $ERR_LOGS " == *"=$p" ]] && continue
        ERR_LOGS="$ERR_LOGS $lbl=$p"
    done < <(for f in $CONF_FILES; do cfg_logs "$f" error; done | sort -u | head -n 9)
fi

# PHP-FPM of the site
FPM_LOG=$(sed -nE 's/^[[:space:]]*error_log[[:space:]]*=[[:space:]]*(\/[^[:space:];]+).*/\1/p' "$FPM_CONF_DIR/php-fpm.conf" 2>/dev/null | head -n 1)
FPM_LOG=${FPM_LOG:-/var/log/php$PHPV-fpm.log}
FPM_POOL_FILE=""; FPM_POOL=""; FPM_SLOW=""; FPM_SLOW_TMO=""
for pf in "$FPM_CONF_DIR"/pool.d/*.conf; do
    [[ -f $pf ]] || continue
    l=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$pf" | head -n 1)
    if [[ -z $FPM_SOCK || ${l#/var} == "${FPM_SOCK#/var}" ]]; then FPM_POOL_FILE=$pf; break; fi
done
if [[ -n $FPM_POOL_FILE ]]; then
    FPM_POOL=$(sed -nE 's/^[[:space:]]*\[([A-Za-z0-9_.-]+)\].*/\1/p' "$FPM_POOL_FILE" | head -n 1)
    FPM_SLOW=$(sed -nE 's/^[[:space:]]*slowlog[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$FPM_POOL_FILE" | head -n 1)
    FPM_SLOW=${FPM_SLOW//\$pool/$FPM_POOL}
    [[ -n $FPM_SLOW && $FPM_SLOW != /* ]] && FPM_SLOW="/var/log/$FPM_SLOW"
    FPM_SLOW_TMO=$(sed -nE 's/^[[:space:]]*request_slowlog_timeout[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$FPM_POOL_FILE" | head -n 1)
fi
M_FPM=$(fpm_master "$PHPV")
OTHER_PHPV=""
for d in /etc/php/*/fpm; do
    v=$(cut -d/ -f4 <<< "$d"); [[ $v == "$PHPV" ]] && continue
    [[ -n $(fpm_master "$v") ]] && OTHER_PHPV="${OTHER_PHPV:+$OTHER_PHPV }$v"
done

# Moodle cron log, from the web user's crontab redirect
CRON_LOG=$(crontab -l -u "$WEBUSER" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep 'admin/cli/cron.php' \
    | sed -nE 's/.*>>?[[:space:]]*(\/[^[:space:]]+).*/\1/p' | head -n 1)
[[ $CRON_LOG == /dev/null ]] && CRON_LOG=""

# database family
DB_FAMILY=other; DBCLI=""; DUMPSLOW=""; DB_LIMIT=""; DB_UNIT=""
case $DBTYPE in mysqli|mariadb|auroramysql) DB_FAMILY=mysql ;; pgsql) DB_FAMILY=postgres ;; esac
if [[ $DB_FAMILY == mysql ]]; then
    DBCLI=$(command -v mariadb || command -v mysql || echo mariadb)
    DUMPSLOW=$(command -v mariadb-dumpslow || command -v mysqldumpslow || echo mysqldumpslow)
    if systemctl cat mariadb.service >/dev/null 2>&1; then DB_UNIT=mariadb; else DB_UNIT=mysql; fi
fi

# mail transfer agent
MTA=""; EXIMBIN=""
if command -v exim4 >/dev/null 2>&1; then MTA=exim; EXIMBIN=exim4
elif command -v exim >/dev/null 2>&1; then MTA=exim; EXIMBIN=exim
elif command -v postqueue >/dev/null 2>&1; then MTA=postfix; fi

# units worth watching, and crontab owners
UNITS=""
for u in nginx apache2 "php$PHPV-fpm" $(for v in $OTHER_PHPV; do echo "php$v-fpm"; done) mariadb mysql postgresql redis-server exim4 postfix cron fail2ban logrotate certbot; do
    systemctl cat "$u.service" >/dev/null 2>&1 || continue
    # mysql.service is often an alias of mariadb.service: list each real unit once
    id=$(systemctl show -p Id --value "$u.service" 2>/dev/null); id=${id%.service}
    [[ -n $id && $id != "$u" && " $UNITS " == *" $id "* ]] && continue
    UNITS="$UNITS $u"
done
UNIT_RE="nginx|apache2|php[0-9.]+-fpm|mariadb|mysql|postgresql|redis-server|exim4|postfix|cron|fail2ban|logrotate|certbot|unattended-upgrades|apt-daily"
FAILED_UNITS=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^fail2ban.service$' | head -n 5 | tr '\n' ' ')
CRON_USERS=$(printf '%s\n' root "$WEBUSER" "$OPERATOR" | awk '!s[$0]++' | tr '\n' ' ')

# Test mode (tests only): an override file points the input paths at synthetic data.
if [[ "${MSC_COLLECT_TEST:-0}" == 1 && -r "${MSC_COLLECT_TEST_ENV:-}" ]]; then
    # shellcheck source=/dev/null
    source "$MSC_COLLECT_TEST_ENV"
fi
export DAYS SPLIT SPLIT_EPOCH WITH_TCPDUMP MOODLE_CLI HOST OUTBASE NAME OUT WORK ERRLOG CAP NOW CUTOFF SINCE SINCE7 \
       MASK MASK6OFF KPAT LOADAVG_START MOODLE DOCROOT DATAROOT SITE RELEASE DBTYPE DBNAME PHPBIN PHPV FPM_SOCK WEBUSER \
       ORIGIN_IP ENV_SRC WEB SITE_LOG SITE_FMT SITE_FMT_WHY SITE_ERRLOG ERR_LOGS OTHER_LOGS FPM_LOG FPM_SLOW FPM_SLOW_TMO \
       FPM_CONF_DIR M_FPM OTHER_PHPV CRON_LOG DB_FAMILY DBCLI DUMPSLOW DB_LIMIT DB_UNIT MTA EXIMBIN UNITS UNIT_RE \
       FAILED_UNITS CRON_USERS MYSQL_DATADIR BTMP_BASE BASELINE_DIR UU_LOGDIR LE_LOG LE_DIR F2B_DIR REDIS_CONF DB_DELTA \
       NET_SLEEP LOADAVG_FILE LOAD_MAX DB08_SAMPLES DB08_SLEEP APT_HISTORY DPKG_LOG EXIM_MAINLOG POSTFIX_LOG MAILBOX \
       PKG_SINCE_EPOCH CERT_SINCE PROCFS OPERATOR

for f in mask.sed lib_norm.awk access_agg.awk slowlog_parse.awk fpmlog_agg.awk errlog_agg.awk mysqlslow.awk \
         privacy_scan.awk synrecv.awk netcounters.awk tcpdump_syn.awk innodb_filter.awk cronlog_agg.awk moodle_info.php; do
    [[ -r $HERE/$f ]] || die "helper file missing: $HERE/$f"
done
command -v gawk >/dev/null 2>&1 || die "gawk is required (apt install gawk is a change: ask the owner)"

# ------------------------------------------------------------ load guard
if awk -v l="$LOAD1" -v m="$LOAD_MAX" 'BEGIN { exit !(l > m) }'; then
    if ((FORCE)); then
        echo "WARNING: load1=$LOAD1 > $LOAD_MAX, continuing because of --force" >&2
    elif ((DRY_RUN)); then
        echo "NOTE: load1=$LOAD1 > $LOAD_MAX; a real run would abort (use --force)" >&2
    else
        die "load1=$LOAD1 > $LOAD_MAX. Run off-peak (scripts/quiet-hours.sh), or pass --force."
    fi
fi

# Time windows to avoid (warning only): within an hour before or 15 min after logrotate or apt-daily-upgrade.
# A rotation between the two passes over the access logs shifts file names and spoils per-client detail; an
# automatic upgrade may restart the DB server and break the 60 s status delta.
timer_near() { # unit -> prints a warning when the timer is near
    local nx lt nxe lte
    nx=$(systemctl show -p NextElapseUSecRealtime --value "$1" 2>/dev/null)
    lt=$(systemctl show -p LastTriggerUSec --value "$1" 2>/dev/null)
    nxe=$(date -d "$nx" +%s 2>/dev/null || echo 0); lte=$(date -d "$lt" +%s 2>/dev/null || echo 0)
    if ((nxe > NOW && nxe - NOW < 3600)) || ((lte > 0 && NOW - lte < 900)); then
        echo "WARNING: $1 is due or just ran (next: ${nx:-?}, last: ${lt:-?}). Results may be incomplete; consider a later start." >&2
    fi
}
timer_near logrotate.timer; timer_near apt-daily-upgrade.timer

if ((!DRY_RUN)) && ! id -u "$OWNER" >/dev/null 2>&1; then die "owner '$OWNER' does not exist (set COLLECT_OWNER)"; fi

# ============================================================ main
cd / || exit 1
if ((DRY_RUN)); then
    echo "moodle-audit-collect.sh $VERSION"
    echo "DRY RUN. Nothing is read beyond file metadata and nothing is written."
    echo "would write: $OUT/  then  $OUT.tar.gz (owner $OWNER, mode 0600)"
    echo "window: $DAYS days (since $SINCE); split: ${SPLIT:-none}; load1=$LOAD1 (guard $LOAD_MAX); tcpdump=$WITH_TCPDUMP"
    echo "site facts from: $ENV_SRC"
    echo "moodle=$MOODLE docroot=$DOCROOT site=${SITE:-?} release=${RELEASE:-?} db=${DBTYPE:-?} ($DB_FAMILY) php=$PHPBIN web=$WEB user=$WEBUSER"
    echo "site access log: ${SITE_LOG:-none} (format $SITE_FMT: $SITE_FMT_WHY)"
    echo "other access logs: ${OTHER_LOGS:-none}"
    echo "error logs: $ERR_LOGS"
    echo "fpm log: $FPM_LOG; pool ${FPM_POOL:-?} ($FPM_POOL_FILE); slowlog ${FPM_SLOW:-none} (timeout ${FPM_SLOW_TMO:-unset}); other php-fpm: ${OTHER_PHPV:-none}"
    echo "moodle cron log: ${CRON_LOG:-none}; MTA: ${MTA:-none}; units:$UNITS; failed: ${FAILED_UNITS:-none}"
    echo
    printf '%-11s %5s  %-46s %s\n' "STEP" "TMO" "OUTPUT (under OUT)" "COMMAND"
else
    if [[ -L $OUTBASE ]]; then die "$OUTBASE is a symlink; refusing to write through it"; fi
    CREATED_BASE=0
    if [[ ! -d $OUTBASE ]]; then mkdir -p -m 0700 -- "$OUTBASE" || die "cannot create $OUTBASE"; CREATED_BASE=1; fi
    [[ -L $OUTBASE/.collect.lock ]] && die "$OUTBASE/.collect.lock is a symlink; refusing"
    exec 8>>"$OUTBASE/.collect.lock" || die "cannot open $OUTBASE/.collect.lock"
    flock -n 8 || die "another collector run is active (lock $OUTBASE/.collect.lock)"
    [[ -e $OUT || -L $OUT ]] && die "$OUT already exists"
    mkdir -m 0700 -- "$OUT" || die "cannot create $OUT"
    trap cleanup EXIT
    trap on_signal INT TERM HUP
    for d in 00_meta 10_system/unit_logs 20_web/site 20_web/other 20_web/errors 25_moodle 30_php 40_db 50_cron_mail \
             60_security 70_network 80_baseline .work; do
        mkdir -p -m 0700 -- "$OUT/$d"
    done
    printf 'id\tcmd\texit\tseconds\tbytes\toutfile\tnote\n' > "$OUT/00_meta/_index.tsv"
    # mask.sed with the server's own address allowlisted (or the placeholder line removed)
    if [[ -n $ORIGIN_IP ]]; then
        sed -E "s/@ORIGIN_IP_RE@/${ORIGIN_IP//./\\\\.}/; s/@ORIGIN_IP_PROT@/${ORIGIN_IP//./\\\\x03}/" "$HERE/mask.sed" > "$WORK/mask.sed"
    else
        sed '/@ORIGIN_IP_RE@/d' "$HERE/mask.sed" > "$WORK/mask.sed"
    fi
    MASK="$WORK/mask.sed"
    sed '/^#BEGIN-IPV6/,/^#END-IPV6/d' "$MASK" > "$MASK6OFF"
    export MASK
    log "moodle-audit-collect $VERSION: OUT=$OUT days=$DAYS split=${SPLIT:-none} load1=$LOAD1"
fi

# Functions must be exported for `timeout ... bash -c`.
# shellcheck disable=SC2046
export -f $(compgen -A function)

READS=(
  [META-01]="uname, uptime, /proc/loadavg, free, df, sha256 of this script and its helpers"
  [R-SYS-01a]="journalctl --list-boots, --disk-usage"
  [R-SYS-01b]="journalctl --header (file headers only)"
  [R-SYS-02]="journalctl -k since window start, and -k -b 0 (kernel ring only)"
  [R-SYS-03]="journalctl -b <idx> for earlier boots that ended in the window (tail only, auth lines dropped)"
  [R-SYS-04]="journalctl _PID=1 since window start (unit start/stop/fail lines)"
  [R-SYS-05a]="systemctl --failed"
  [R-SYS-05b]="journalctl -u <$UNITS > --since -7d -n 300"
  [R-SYS-06]="$UU_LOGDIR/unattended-upgrades*.log* (mtime < 60 d); systemctl list-timers; 50unattended-upgrades (selected lines)"
  [R-SYS-07]="logrotate -d --skip-state-lock /etc/logrotate.conf (debug, no changes, no state lock)"
  [R-SYS-08]="ls /var/log/sysstat /var/log/sa; sar -u/-q/-r -f <files of the window> (averages)"
  [R-SYS-09]="/proc/*/smaps_rollup, /proc/*/stat, comm, cmdline"
  [R-SYS-10a]="/proc/<mariadbd|mysqld>/limits"
  [R-SYS-10b]="redis-cli INFO persistence/server/memory (no AUTH); grep $REDIS_CONF (requirepass counted only)"
  [R-SYS-11]="du -sh /var/lib/mysql /var/lib/postgresql /var/lib/docker /var/lib/containerd /var/log/journal /var/lib/nginx/fastcgi /root /var/mail; df of the dataroot"
  [R-SYS-12a]="journalctl -b 0 -u <failed units: ${FAILED_UNITS:-none}> fail2ban (whole current boot, last 300 lines each)"
  [R-SYS-12b]="systemctl cat / show of the same units (unit files, read-only)"
  [R-SYS-13]="journalctl -k -b 0 (soft lockup, RCU stall, hung task, watchdog lines: timestamps)"
  [R-SYS-14a]="$(plan_chain log_chain_all "$APT_HISTORY") (blocks from $(date -d "@$PKG_SINCE_EPOCH" '+%F') on; Requested-By dropped)"
  [R-SYS-14b]="$(plan_chain log_chain_all "$DPKG_LOG") (install/upgrade/remove/purge/configure lines from $(date -d "@$PKG_SINCE_EPOCH" '+%F') on)"
  [R-SYS-15]="find $FPM_CONF_DIR ${FPM_CONF_DIR%/fpm}/mods-available ${FPM_CONF_DIR%/fpm}/cli/php.ini (mtime and size only)"
  [R-SYS-16a]="$PROCFS/*/cmdline, comm; $PROCFS/<web, fpm, DB and redis masters>/maps and stat; $PROCFS/stat (btime)"
  [R-SYS-16b]="$PROCFS/<web server master and workers>/stat (start times)"
  [R-SYS-17]="journalctl -u certbot.service since $CERT_SINCE (systemd start/finish lines)"
  [R-WEB-00a]="nginx -T, or apache2ctl -S/-M and the enabled config files (runs after R-WEB-03)"
  [R-WEB-00b]="find /var/lib/nginx/fastcgi -type f | wc -l"
  [R-WEB-01]="$(plan_chain log_chain "$SITE_LOG")"
  [R-WEB-02]="$(for p in $OTHER_LOGS; do printf '%s ' "$(plan_chain log_chain "$p")"; done)"
  [R-WEB-03]="error logs within the window: $ERR_LOGS"
  [R-PHP-01a]="$(plan_chain log_chain_all "$FPM_LOG")"
  [R-PHP-01b]="$(plan_chain log_chain_all "$FPM_LOG")"
  [R-PHP-02]="$(for v in $OTHER_PHPV; do printf '%s ' "$(plan_chain log_chain "/var/log/php$v-fpm.log")"; done) (other PHP versions' FPM logs, last 3000 lines)"
  [R-PHP-03a]="$(plan_chain log_chain_all "$FPM_SLOW") (IPv6 masking off: stack traces)"
  [R-PHP-03b]="$(plan_chain log_chain_all "$FPM_SLOW") (entries since $SINCE only), joined by pid+time to the FPM log"
  [R-PHP-04]="$FPM_CONF_DIR/php-fpm.conf, pool.d/*.conf, php.ini and conf.d/*.ini read as files (php-fpm is NOT run)"
  [R-MDL-01]="runuser -u $WEBUSER -- $PHPBIN $MOODLE/admin/cli/checks.php -v (Moodle status checks, read-only)"
  [R-MDL-02]="runuser -u $WEBUSER -- $PHPBIN -- $MOODLE < moodle_info.php (settings, stores, tasks, ad hoc queue, plugins, counts, theme colours; DB session READ ONLY)"
  [R-DB-00]="$DBCLI root unix-socket auth test (SELECT 1)"
  [R-DB-01a]="SHOW GLOBAL STATUS"
  [R-DB-01b]="SHOW GLOBAL STATUS (at least $DB_DELTA s after t0; no other DB query runs in between)"
  [R-DB-01c]="local only: status_t0.tsv + status_t60.tsv -> per-second rates over the real gap"
  [R-DB-02]="SHOW GLOBAL VARIABLES"
  [R-DB-03]="performance_schema.events_statements_summary_by_digest (7 orderings, DIGEST + 1,024-char text; all rows hash-only), digest_lost"
  [R-DB-04]="performance_schema.table_io_waits_summary_by_table / _by_index_usage"
  [R-DB-05]="information_schema.INNODB_BUFFER_POOL_STATS, INNODB_CMP; SHOW ENGINE INNODB STATUS (filtered)"
  [R-DB-06]="@@slow_query_log_file and its rotations (window-filtered, read only by dumpslow and gawk)"
  [R-DB-07]="information_schema.PROCESSLIST (no INFO), account host counts, information_schema.TABLES sums and top 30 tables, ls of the datadir"
  [R-DB-08]="performance_schema.threads/socket_instances/events_statements_summary_by_thread_by_event_name, session_connect_attrs (names only); ss -Hxpn and ss -Htnp (port 3306) x$DB08_SAMPLES; $PROCFS/<client pid>/cmdline, stat"
  [R-DB-09]="journalctl -u $DB_UNIT since window start"
  [R-CRON-01]="crontab -l -u <$CRON_USERS>; ls /var/spool/cron/crontabs /etc/cron.d"
  [R-CRON-02]="$(plan_chain log_chain "$CRON_LOG") (task classes, runs, seconds, failures only)"
  [R-MAIL-01]="$MTA queue counts and routing summary"
  [R-MAIL-02]="$( [[ $MTA == exim ]] && plan_chain log_chain "$EXIM_MAINLOG"; [[ $MTA == postfix ]] && echo "$POSTFIX_LOG or journalctl -u postfix*")"
  [R-MAIL-03]="stat $MAILBOX; tail -c 20000000 $MAILBOX (headers counted only)"
  [R-MAIL-04]="stat $MAILBOX /var/mail/root (metadata only)"
  [R-SEC-01]="/etc/ufw files (ufw is not run); nft list ruleset; ss -tlnp/-ulnp; sshd -T; utmpdump /var/log/btmp*; /etc/fail2ban/jail.local, jail.d/*; $LE_DIR/live/*/cert.pem; tail -150 $LE_LOG; modes of world-readable config.php/.env files (metadata only)"
  [R-NET-01]="ss -Htn state syn-recv x3; ss -Htln (listen backlog); /proc/net/netstat + /proc/net/snmp x2; SYN-queue sysctls"
  [R-NET-02]="tcpdump -c 2000 for 20 s on the default interface (SYN only, piped to awk)"
  [R-BASE-01]="${BASELINE_DIR:-none} (ls) and *.md (masked copies)"
)

M=00_meta S=10_system X=20_web Y=25_moodle P=30_php D=40_db C=50_cron_mail Z=60_security N=70_network B=80_baseline

run META-01   30  $M/env.txt                -- s_meta_env

# ---- 10_system
run R-SYS-01a 60  $S/boots.txt              -- s_sys01_boots
run R-SYS-01b 60  $S/journal_header.txt     -- s_sys01_header
run R-SYS-02  300 $S/kernel_events_daily.tsv -- s_sys02
run R-SYS-03  120 $S/unit_logs/_boots_selected.txt -- s_sys03
run R-SYS-04  120 $S/unit_events.tsv        -- s_sys04
run R-SYS-05a 30  $S/failed_units.txt       -- s_sys05_failed
run R-SYS-05b 120 $S/unit_logs/_index.txt   -- s_sys05_units
run R-SYS-06  60  $S/unattended_upgrades.txt -- s_sys06
run R-SYS-07  60  $S/logrotate_debug.txt    -- s_sys07
run R-SYS-08  60  $S/sysstat.txt            -- s_sys08
run R-SYS-09  120 $S/pss_by_group.tsv       -- s_sys09
run R-SYS-10a 10  $S/db_limits.txt          -- s_sys10_limits
run R-SYS-10b 30  $S/redis.txt              -- s_sys10_redis
run R-SYS-11  300 $S/du.txt                 -- s_sys11
run R-SYS-12a 60  $S/unit_logs/boot0_failed_and_fail2ban.txt -- s_sys12_boot0
run R-SYS-12b 30  $S/unit_files_failed_and_fail2ban.txt -- s_sys12_unitfiles
run R-SYS-13  120 $S/kernel_boot0_stalls.tsv -- s_sys13_stalls
run R-SYS-14a 60  $S/apt_history_window.txt -- s_sys14_apt
run R-SYS-14b 60  $S/dpkg_window.tsv        -- s_sys14_dpkg
run R-SYS-15  30  $S/php_conf_mtimes.tsv    -- s_sys15_phpconf
run R-SYS-16a 60  $S/deleted_libs.tsv       -- s_sys16_deleted
run R-SYS-16b 30  $S/web_processes.tsv      -- s_sys16_web
run R-SYS-17  60  $S/certbot_runs.tsv       -- s_sys17_certbot

# ---- web server temp files (the config dump runs later, after R-WEB-03)
run R-WEB-00b 60  $X/fastcgi_temp.txt       -- s_web00_tmp

# ---- database.  t0, then only steps that do not query the DB (DB journal, slow-log file needs one variable
# read before t0, network, PHP, Moodle CLI is after t60), then t60, and only then the catalog queries, so the
# status delta does not count the collector's own reads.
DB_OK=0
if [[ $DB_FAMILY != mysql ]]; then
    skip R-DB-ALL "dbtype '${DBTYPE:-?}' is not MySQL/MariaDB (PostgreSQL: see references/collector.md, manual read-only queries)"
elif ((DRY_RUN)); then
    DB_OK=1
    printf '%-11s        (R-DB-* run only if "%s --protocol=socket -uroot -e SELECT 1" succeeds)\n' "R-DB-00" "$DBCLI"
elif timeout -k 5 20 "$DBCLI" --protocol=socket -uroot --connect-timeout=5 -NBe 'SELECT 1' > /dev/null 2>> "$ERRLOG"; then
    DB_OK=1
    if "$DBCLI" --protocol=socket -uroot -NBe 'SELECT VERSION()' 2>/dev/null | grep -qi mariadb; then DB_LIMIT="SET SESSION max_statement_time=60;"
    else DB_LIMIT="SET SESSION max_execution_time=60000;"; fi
    # read before t0, so nothing queries the DB between the two status samples
    IFS=$'\t' read -r MYSQL_DATADIR SLOW_FILE SLOW_ON LONG_QT < <("$DBCLI" --protocol=socket -uroot -NBe \
        'SELECT @@datadir, @@slow_query_log_file, @@slow_query_log, @@long_query_time' 2>/dev/null)
    MYSQL_DATADIR=${MYSQL_DATADIR%/}; MYSQL_DATADIR=${MYSQL_DATADIR:-/var/lib/mysql}
    export DB_LIMIT MYSQL_DATADIR SLOW_FILE SLOW_ON LONG_QT
else
    log "R-DB: root unix-socket authentication failed; skipping every R-DB step (no other credentials are tried)"
    skip R-DB-ALL "root socket auth failed"
fi
DB_T0=$(date +%s)
if ((DB_OK)); then
    run R-DB-01a 30  $D/status_t0.tsv          -- s_db01
    run R-DB-09   60  $D/journal_db.txt        -- s_db09
    run R-DB-06   900 $D/slowlog_ls.txt        -- s_db06
fi

# ---- network (about 20 s)
run R-NET-01  60  $N/synrecv_samples.tsv    -- s_net01
if ((WITH_TCPDUMP)); then
    run R-NET-02 40 $N/tcpdump_syn_aggregate.txt -- s_net02
else
    skip R-NET-02 "not requested (--with-tcpdump)"
fi

# ---- PHP
run R-PHP-01a 120 $P/fpm_log_sanitized.txt.gz -- s_php01_sanitized
run R-PHP-01b 120 $P/fpm_events_hourly_run.txt -- s_php01_agg
run R-PHP-02  60  $P/fpm_other_versions_log.txt -- s_php02
run R-PHP-03a 120 $P/fpm_slow.log.gz        -- s_php03_copy
run R-PHP-03b 300 $P/slow_parse_run.txt     -- s_php03_parse
run R-PHP-04  30  $P/php_fpm_conf.txt       -- s_php04

if ((DB_OK)); then
    if ((!DRY_RUN)); then
        wait_s=$((DB_T0 + DB_DELTA - $(date +%s)))
        if ((wait_s > 0)); then log "waiting ${wait_s}s for the ${DB_DELTA} s status delta"; sleep "$wait_s"; fi
    fi
    run R-DB-01b 30  $D/status_t60.tsv         -- s_db01
    run R-DB-01c 10  $D/status_delta.tsv       -- s_db01_delta
    run R-DB-02  30  $D/variables.tsv          -- s_db02
    run R-DB-03  60  $D/digest_by_time.tsv     -- s_db03 SUM_TIMER_WAIT
    run R-DB-03  60  $D/digest_by_rows.tsv     -- s_db03 SUM_ROWS_EXAMINED
    run R-DB-03  60  $D/digest_by_rows_sent.tsv -- s_db03 SUM_ROWS_SENT
    run R-DB-03  60  $D/digest_by_count.tsv    -- s_db03 COUNT_STAR
    run R-DB-03  60  $D/digest_by_fulljoin.tsv -- s_db03 SUM_SELECT_FULL_JOIN
    run R-DB-03  60  $D/digest_by_tmpdisk.tsv  -- s_db03 SUM_CREATED_TMP_DISK_TABLES
    run R-DB-03  60  $D/digest_by_noindex.tsv  -- s_db03 SUM_NO_INDEX_USED
    run R-DB-03  60  $D/digest_all_hashes.tsv  -- s_db03_all
    run R-DB-03  30  $D/digest_meta.tsv        -- s_db03_meta
    run R-DB-04  60  $D/table_io.tsv           -- s_db04_io
    run R-DB-04  60  $D/fullscan_tables.tsv    -- s_db04_fullscan
    run R-DB-05  30  $D/bp_stats.tsv           -- s_db05_bp
    run R-DB-05  30  $D/innodb_cmp.tsv         -- s_db05_cmp
    run R-DB-05  30  $D/innodb_status_filtered.txt -- s_db05_status
    run R-DB-07  30  $D/processlist_agg.tsv    -- s_db07_pl
    run R-DB-07  30  $D/remote_accounts.txt    -- s_db07_remote
    run R-DB-07  120 $D/schemas.tsv            -- s_db07_schemas
    run R-DB-07  120 $D/tables_top.tsv         -- s_db07_tables
    run R-DB-07  30  $D/datadir_sizes.txt      -- s_db07_datadir
    run R-DB-08  90  $D/conn_attribution.tsv   -- s_db08
    run R-DB-08  30  $D/conn_attr_names.tsv    -- s_db08_attrs
fi

# ---- Moodle (as the web user; after the DB status delta, since it queries the DB)
if ((MOODLE_CLI)) && [[ -f $MOODLE/config.php ]]; then
    run R-MDL-01 180 $Y/checks.txt             -- s_mdl01
    run R-MDL-02 180 $Y/moodle_info.txt        -- s_mdl02
else
    skip R-MDL-ALL "Moodle CLI steps off (--no-moodle-cli) or $MOODLE/config.php missing"
fi

# ---- web access and error logs (the heavy part).  The load is checked again here, 3-4 minutes after the start;
# above LOAD_MAX these steps are skipped unless --force.
WEB_OK=1
if ((!DRY_RUN)); then
    read -r LOAD1_NOW _ < "$LOADAVG_FILE"
    if awk -v l="$LOAD1_NOW" -v m="$LOAD_MAX" 'BEGIN { exit !(l > m) }'; then
        if ((FORCE)); then log "load1=$LOAD1_NOW > $LOAD_MAX before the access-log steps; continuing because of --force"
        else WEB_OK=0; log "load1=$LOAD1_NOW > $LOAD_MAX before the access-log steps; skipping R-WEB-01..03 (re-run off-peak, or pass --force)"; fi
    fi
else
    printf '%-11s        (R-WEB-01..03 are skipped if load1 > %s at this point, unless --force)\n' "R-WEB-CHK" "$LOAD_MAX"
fi
if ((WEB_OK)); then
    run R-WEB-01  900 $X/site/_run.txt          -- s_web_access site "$SITE_FMT" "$SITE_LOG" site
    for p in $OTHER_LOGS; do
        lbl=${p##*/}; lbl=${lbl%.log}; lbl=${lbl//[^A-Za-z0-9_.-]/_}
        run R-WEB-02 600 "$X/other/$lbl/_run.txt" -- s_web_access "$lbl" combined "$p" "other/$lbl"
    done
    run R-WEB-03  600 $X/errors/_run.txt        -- s_web03
else
    for id in R-WEB-01 R-WEB-02 R-WEB-03; do skip "$id" "load1=$LOAD1_NOW > $LOAD_MAX (no --force)"; done
fi
# nginx -T after the error logs were read (it may log its own warnings there)
run R-WEB-00a 60  $X/webserver_config.txt   -- s_web00_T

# ---- cron and mail
for u in $CRON_USERS; do
    run R-CRON-01 30 "$C/crontab_$u.txt"     -- s_cron_user "$u"
done
run R-CRON-01 30  $C/spool_ls.txt           -- s_cron_spool
run R-CRON-02 600 $C/cron_log_run.txt       -- s_cron02
run R-MAIL-01 120 $C/mail_queue.txt         -- s_mail01
run R-MAIL-02 300 $C/mail_log_run.txt       -- s_mail02
run R-MAIL-03 120 $C/mailbox_summary.txt    -- s_mail03
run R-MAIL-04 10  $C/mailbox_stat.txt       -- s_mail_stat

# ---- security
run R-SEC-01  30  $Z/ufw.txt                -- s_sec_ufw
run R-SEC-01  30  $Z/nft_masked.txt         -- s_sec_nft
run R-SEC-01  30  $Z/listeners.txt          -- s_sec_listen
run R-SEC-01  30  $Z/sshd_effective.txt     -- s_sec_sshd
run R-SEC-01  120 $Z/btmp_daily.tsv         -- s_sec_btmp
run R-SEC-01  30  $Z/fail2ban_cfg.txt       -- s_sec_f2b
run R-SEC-01  30  $Z/certs.txt              -- s_sec_certs
run R-SEC-01  30  $Z/letsencrypt_tail.txt   -- s_sec_le
run R-SEC-01  60  $Z/secret_file_modes.tsv  -- s_sec_modes

# ---- earlier audit (optional)
if [[ -n $BASELINE_DIR ]]; then
    run R-BASE-01 60 $B/ls.txt               -- s_base01
else
    skip R-BASE-01 "no --baseline given"
fi

if ((DRY_RUN)); then
    echo
    echo "Post-processing in a real run: gzip TSVs over 1 MB, cap every file at 5 MB, mask run.log,"
    echo "write PRIVACY_CHECK.txt (ipv4/email/phone/ipv6/other), then tar.gz (at most 50 MB) only if every"
    echo "count is 0 or the operator confirms, chown -hR $OWNER:, chmod 0600 on the tarball."
    echo "Planned steps: $STEP_N"
    exit 0
fi

# ============================================================ post-processing
printf 'loadavg_end: %s\nfinished_at: %s\n' "$(cat /proc/loadavg)" "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$OUT/00_meta/env.txt"
enforce_caps
sed -E -i -f "$MASK" "$ERRLOG" 2>/dev/null
privacy_check
log "PRIVACY_CHECK written: $OUT/PRIVACY_CHECK.txt"

DO_TAR=1
if [[ -n $RESIDUAL_FILES ]]; then
    {
        echo
        echo "WARNING: PRIVACY_CHECK found residual IPv4/e-mail/phone/IPv6/secret matches in:"
        sed 's/^/    /' <<< "$RESIDUAL_FILES"
        echo "Review those files (see $OUT/PRIVACY_CHECK.txt) before sharing anything."
    } >&2
    if ((YES)); then
        log "--yes given: creating the tarball despite the residuals"
    elif [[ -t 0 ]]; then
        ans=""
        read -r -p "Create the tarball anyway? [y/N] " ans
        [[ ${ans:-} =~ ^[Yy]([Ee][Ss])?$ ]] || DO_TAR=0
    else
        DO_TAR=0
    fi
fi

if ((DO_TAR)); then
    make_tarball
else
    log "tarball NOT created. After review, create it with:"
    log "  sudo tar -C '$OUTBASE' --exclude='$NAME/.work' -czf '$OUT.tar.gz' '$NAME' && sudo chown $OWNER: '$OUT.tar.gz' && sudo chmod 0600 '$OUT.tar.gz'"
fi

cleanup
trap - EXIT
log "done. Output: $OUT  (review PRIVACY_CHECK.txt; references/collector.md 'Review before sharing')"
exit 0
