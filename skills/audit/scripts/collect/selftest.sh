#!/usr/bin/env bash
# selftest.sh - check the collector's masking and parsers with this server's own bash, GNU sed and gawk, before the
# collector is ever run as root.  No root, no network, synthetic data only (documentation IPs, example.* domains,
# made-up phone numbers and secrets).  Writes only to a temporary directory it deletes.
#
#   bash selftest.sh        -> "PASS n / FAIL m"; exit 1 when anything fails (do not run the collector then)
set -u -o pipefail
set +x
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMPD=$(mktemp -d); trap 'rm -rf -- "$TMPD"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
chk() { if eval "$2"; then ok; else bad "$1"; fi; }

# ---- syntax
for f in "$HERE"/moodle-audit-collect.sh "$HERE"/selftest.sh "$HERE"/../*.sh "$HERE"/../monitor/*.sh; do
    [[ -f $f ]] || continue
    chk "bash -n ${f##*/}" "bash -n '$f' 2>/dev/null"
done
for f in "$HERE"/*.awk; do chk "gawk parse ${f##*/}" "echo | gawk -f '$HERE/lib_norm.awk' -f '$f' -v outdir='$TMPD' >/dev/null 2>&1 || [[ \$? -le 1 ]]"; done
command -v gawk >/dev/null && gv=$(gawk --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
chk "gawk >= 4.2 (have ${gv:-none})" "awk -v v='${gv:-0}' 'BEGIN { exit !(v >= 4.2) }'"
chk "GNU sed" "sed --version 2>/dev/null | grep -q 'GNU sed'"
if command -v php >/dev/null 2>&1 || ls /usr/bin/php[0-9]* >/dev/null 2>&1; then
    PHPB=$(command -v php || ls /usr/bin/php[0-9]* | head -n 1)
    for f in "$HERE"/moodle_info.php "$HERE"/../monitor/dbstat.php; do chk "php -l ${f##*/}" "'$PHPB' -l '$f' >/dev/null 2>&1"; done
fi

# ---- the collector's run-time mask.sed with an origin address allowlisted
ORIG=203.0.113.10
sed -E "s/@ORIGIN_IP_RE@/${ORIG//./\\\\.}/; s/@ORIGIN_IP_PROT@/${ORIG//./\\\\x03}/" "$HERE/mask.sed" > "$TMPD/mask.sed"
out=$(echo "origin $ORIG peer 198.51.100.7 lo 127.0.0.1" | sed -E -f "$TMPD/mask.sed")
chk "origin address kept, others masked ($out)" "[[ '$out' == 'origin $ORIG peer <ip> lo 127.0.0.1' ]]"
out=$(sed '/@ORIGIN_IP_RE@/d' "$HERE/mask.sed" > "$TMPD/mask_noorig.sed"; echo "origin $ORIG" | sed -E -f "$TMPD/mask_noorig.sed")
chk "without an origin address every public IPv4 is masked ($out)" "[[ '$out' == 'origin <ip>' ]]"

# ---- leak corpus: every line holds personal data or a secret that must disappear
cat > "$TMPD/leaks.txt" <<'EOF'
client 192.0.2.10 requested /x and 198.51.100.200 too
user=jdoe@example.com&password=Hunter2&sesskey=abcDEF123456
call me on +966 55 123 4567 or 0551234567 or ٠٥٥١٢٣٤٥٦٧ (Arabic-Indic digits)
UK +44 20 7946 0958 and US +1 (555) 123-4567
Authorization: Bearer abcDEF123456ghiJKL
mysql -uroot -pS3cretPass moodle
https://admin:Pa55word@example.net/path
token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk
peer [2001:db8::1]:443 and fe80::1ff:fe23:4567:890a
redis-cli -a R3disPass INFO
{"password": "Sup3r", "api_key": "k-123"}
encoded email%40example.org and x%2B966551234567
glued ip/192.0.2.33 and x192.0.2.34y
fastcgi_param DB_PASSWORD hunter2xyz;
    proxy_set_header X-Api-Key s3cr3tvalue;
    SetEnv DB_PASSWORD Apach3Secret
RequestHeader set X-Auth-Token t0kenvalue
ping https://hc-ping.com/AbCdEfGhIjKlMnOpQrSt/backup-job
EOF
raw=$(gawk -f "$HERE/privacy_scan.awk" -v name=raw < "$TMPD/leaks.txt")
IFS=$'\t' read -r _ r4 re rp r6 ro <<< "$raw"
chk "privacy_scan sees the raw leaks in every column ($raw)" "(( r4 > 0 && re > 0 && rp > 0 && r6 > 0 && ro > 0 ))"
sed -E -f "$TMPD/mask.sed" < "$TMPD/leaks.txt" > "$TMPD/leaks_sed.txt"
res=$(gawk -f "$HERE/privacy_scan.awk" -v name=sed -v origin_ip=$ORIG < "$TMPD/leaks_sed.txt")
chk "mask.sed leaves no residual ($res)" "[[ '$res' == \$'sed\t0\t0\t0\t0\t0' ]]"
for s in Hunter2 abcDEF123456 S3cretPass Pa55word R3disPass Sup3r jdoe 7946 '123-4567' '551234567' \
         hunter2xyz s3cr3tvalue Apach3Secret t0kenvalue AbCdEfGhIjKlMnOpQrSt; do
    chk "mask.sed removed '$s'" "! grep -q -- '$s' '$TMPD/leaks_sed.txt'"
done
for s in 'fastcgi_param DB_PASSWORD x1y2z3;' 'SetEnv APP_SECRET x1y2z3' 'https://hc-ping.com/AbCdEfGhIjKlMnOpQrSt'; do
    r=$(printf '%s\n' "$s" | gawk -f "$HERE/privacy_scan.awk" -v name=d | cut -f6)
    chk "privacy_scan counts a raw '$s' as other ($r)" "(( r > 0 ))"
done
gawk -f "$HERE/lib_norm.awk" -e '{ print maskfree($0) }' < "$TMPD/leaks.txt" > "$TMPD/leaks_awk.txt"
res=$(gawk -f "$HERE/privacy_scan.awk" -v name=awk < "$TMPD/leaks_awk.txt")
chk "maskfree() leaves no residual ($res)" "[[ '$res' == \$'awk\t0\t0\t0\t0\t0' ]]"
for s in hunter2xyz s3cr3tvalue Apach3Secret t0kenvalue AbCdEfGhIjKlMnOpQrSt; do
    chk "maskfree() removed '$s'" "! grep -q -- '$s' '$TMPD/leaks_awk.txt'"
done

# ---- must-not-mangle corpus: harmless text that the masks must leave byte-identical
cat > "$TMPD/keep.txt" <<'EOF'
#0 /var/www/moodle/lib/dml/moodle_database.php(1234): mysqli_native_moodle_database->get_records_sql('SELECT', Array)
PHP Fatal error:  Uncaught core\exception\coding_exception: foo in /var/www/x.php:12
2026-03-13T08:37:40+03:00 host systemd[1]: Started nginx.service
Fri 2026-03-13 08:37:40 +03 next run at 23:45:00
maxstartups 10:30:100
link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff
Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
php8.4-fpm.service: Main process exited, code=exited, status=0/SUCCESS
kernel: RIP: 0010:foo_bar+0x1a2/0x3b0
Version: 1:10.11.6-0+deb12u1 offset +0300 at 2026-03-13 08:00:00 +0300
listen 127.0.0.1:8081; allow 127.0.0.1; deny all;
location ~ [^/]\.php(/|$) { fastcgi_split_path_info ^(.+?\.php)(/.*)$; }
*/5 * * * * /usr/bin/php8.4 /var/www/moodle/admin/cli/cron.php >/dev/null
LISTEN 0 511 0.0.0.0:443 0.0.0.0:*
used_memory_human:12.5M load average: 0.72, 1.21, 0.81
Threads_running 2 Questions 214.5 time 0.0551234567 s
key_count: 5 keys: 3 Basic Settings
proxy_set_header Host $host;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
add_header Cache-Control "public, max-age=31536000";
EOF
sed -E -f "$TMPD/mask.sed" < "$TMPD/keep.txt" > "$TMPD/keep_sed.txt"
chk "mask.sed leaves harmless text untouched ($(diff "$TMPD/keep.txt" "$TMPD/keep_sed.txt" | grep -c '^>') changed lines)" "cmp -s '$TMPD/keep.txt' '$TMPD/keep_sed.txt'"
diff "$TMPD/keep.txt" "$TMPD/keep_sed.txt" | grep '^>' | head -n 5 | sed 's/^/      /'
gawk -f "$HERE/lib_norm.awk" -e '{ print maskfree($0) }' < "$TMPD/keep.txt" | sed -n '1,3p;5,9p;12,13p;17,20p' > "$TMPD/keep_awk.txt"
sed -n '1,3p;5,9p;12,13p;17,20p' "$TMPD/keep.txt" > "$TMPD/keep_ref.txt"
chk "maskfree() leaves harmless text untouched (it masks every IPv4, so address lines are skipped)" "cmp -s '$TMPD/keep_ref.txt' '$TMPD/keep_awk.txt'"

# ---- access_agg on three perf lines and one combined line
now=$(date +%s); t1=$(date -d "@$((now - 3600))" '+%d/%b/%Y:%H:%M:%S %z'); t2=$(date -d "@$((now - 1800))" '+%d/%b/%Y:%H:%M:%S %z')
cat > "$TMPD/acc.log" <<EOF
192.0.2.10 - - [$t1] "GET /?redirect=0 HTTP/2.0" 200 5123 "-" "Mozilla/5.0 (Linux; Android 13) Chrome/120.0.0.0 Mobile Safari/537.36" rt=0.812 urt=0.790
192.0.2.10 - - [$t1] "POST /lib/ajax/service.php?sesskey=abc&info=core_course_get_courses HTTP/2.0" 200 99 "-" "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0.0.0 Safari/537.36" rt=0.031 urt=0.030
198.51.100.7 - - [$t2] "GET /login/index.php?username=jdoe@example.com HTTP/2.0" 200 777 "-" "moodle-audit-monitor/1.0" rt=0.070 urt=0.066
EOF
mkdir -p "$TMPD/agg"
gawk -f "$HERE/lib_norm.awk" -f "$HERE/access_agg.awk" -v fmt=perf -v cutoff=$((now - 86400)) -v surge=0 -v outdir="$TMPD/agg" -v files="$TMPD/acc.log" < "$TMPD/acc.log" >/dev/null 2>&1
chk "access_agg: 3 lines in the window" "grep -q \$'^lines_in_window\t3$' '$TMPD/agg/agg_meta.tsv'"
chk "access_agg: ajax method allowlisted" "grep -q '^core_course_get_courses' '$TMPD/agg/ajax_methods_P1.tsv'"
chk "access_agg: own monitor recognised" "(( \$(wc -l < '$TMPD/agg/monitor_requests.tsv') == 2 ))"
chk "access_agg: no raw IP, e-mail or sesskey in any output" "! cat '$TMPD'/agg/*.tsv | grep -qE '192\\.0\\.2\\.10|198\\.51\\.100\\.7|jdoe|sesskey'"

# ---- cronlog_agg: classes only, display names and task output never written
printf 'Server Time: %s\nExecute scheduled task: Nom affich\303\251 (core\\task\\question_preview_cleanup_task)\nSending email to jdoe@example.com\n... used 4 dbqueries\n... used 12.5 seconds\nScheduled task complete: x (core\\task\\question_preview_cleanup_task)\n' \
    "$(date -d "@$((now - 600))" '+%a, %d %b %Y %H:%M:%S %z')" > "$TMPD/cron.log"
gawk -f "$HERE/cronlog_agg.awk" -v cutoff=$((now - 86400)) -v outdir="$TMPD" < "$TMPD/cron.log" >/dev/null 2>&1
chk "cronlog_agg: task class, 12.5 s, 1 run >= 10 s" "grep -qP '^scheduled\tcore\\\\\\\\task\\\\\\\\question_preview_cleanup_task\t1\t0\t12.500\t12.500\t1\t4$' '$TMPD/cron_tasks.tsv' || grep -q 'question_preview_cleanup_task.1.0.12.500.12.500.1.4' '$TMPD/cron_tasks.tsv'"
chk "cronlog_agg: no display name or task output" "! grep -qE 'Nom|jdoe' '$TMPD/cron_tasks.tsv' '$TMPD/cron_daily.tsv'"

echo "selftest: PASS $PASS / FAIL $FAIL"
((FAIL == 0))
