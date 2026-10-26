<?php
// db-load-sample.php — READ-ONLY database load sampler for honest before/after numbers (moodle-server-care "tuning").
//
// MySQL/MariaDB: rates of Questions, Com_select, Com_insert+update+delete, Slow_queries from SHOW GLOBAL STATUS.
// PostgreSQL: transactions/s and rows returned/fetched/s for the site database from pg_stat_database.
// Takes N samples of S seconds each (default 5 x 60 s), prints every sample, then median, min and max, and one
// line ready for the operations log that says exactly what was measured.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php db-load-sample.php --moodle=DIR [--samples=5] [--interval=60] [--label=before]
// Uses Moodle's own DB connection (config.php is included, credentials are never printed). One status query per
// sample; the sampler's own statements are negligible (1-2 per sample).
//
// Honest-measurement rules (why): counters are server-wide (other sites on the same DB server count too); a DB
// restart resets them (a sample across a restart is dropped); cron work is bursty, so one 60-s sample is anecdotal;
// compare the same hour and weekday, before and after one change only.

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'samples:', 'interval:', 'label:', 'help']);
if (isset($opts['help']) || empty($opts['moodle'])) {
    fwrite(STDERR, "usage: php db-load-sample.php --moodle=DIR [--samples=5] [--interval=60] [--label=TEXT]\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "db-load-sample: cannot read $moodle/config.php\n");
    exit(2);
}
$samples = max(1, min(120, (int)($opts['samples'] ?? 5)));
$interval = max(5, min(3600, (int)($opts['interval'] ?? 60)));
$label = preg_replace('/[^A-Za-z0-9 _.:()-]/', '', $opts['label'] ?? 'sample');
require("$moodle/config.php");

$family = $DB->get_dbfamily();
if ($family === 'mysql') {
    $read = function () use ($DB): array {
        $want = ['Questions', 'Com_select', 'Com_insert', 'Com_update', 'Com_delete', 'Slow_queries',
            'Threads_running', 'Threads_connected', 'Uptime'];
        $rows = $DB->get_records_sql_menu("SHOW GLOBAL STATUS WHERE Variable_name IN ('" . implode("','", $want) . "')");
        $v = [];
        foreach ($rows as $k => $x) {
            $v[$k] = (float)$x;
        }
        return $v;
    };
    $cols = [
        'q/s' => fn($a, $b, $dt) => ($b['Questions'] - $a['Questions'] - 1) / $dt,   // minus our own SHOW
        'select/s' => fn($a, $b, $dt) => ($b['Com_select'] - $a['Com_select']) / $dt,
        'write/s' => fn($a, $b, $dt) => ($b['Com_insert'] + $b['Com_update'] + $b['Com_delete']
            - $a['Com_insert'] - $a['Com_update'] - $a['Com_delete']) / $dt,
        'slow/min' => fn($a, $b, $dt) => ($b['Slow_queries'] - $a['Slow_queries']) * 60 / $dt,
        'running' => fn($a, $b, $dt) => max(0, $b['Threads_running'] - 1),
    ];
    $restart = fn($a, $b) => $b['Uptime'] < $a['Uptime'];
    $main = 'q/s';
} else if ($family === 'postgres') {
    $read = function () use ($DB): array {
        $r = $DB->get_record_sql("SELECT xact_commit, xact_rollback, tup_returned, tup_fetched, tup_inserted,
                                         tup_updated, tup_deleted, numbackends, stats_reset
                                    FROM pg_stat_database WHERE datname = current_database()");
        $v = [];
        foreach ((array)$r as $k => $x) {
            $v[$k] = $k === 'stats_reset' ? (string)$x : (float)$x;
        }
        $v['now'] = microtime(true);
        return $v;
    };
    $cols = [
        'xact/s' => fn($a, $b, $dt) => ($b['xact_commit'] + $b['xact_rollback'] - $a['xact_commit'] - $a['xact_rollback']) / $dt,
        'returned/s' => fn($a, $b, $dt) => ($b['tup_returned'] - $a['tup_returned']) / $dt,
        'fetched/s' => fn($a, $b, $dt) => ($b['tup_fetched'] - $a['tup_fetched']) / $dt,
        'writes/s' => fn($a, $b, $dt) => ($b['tup_inserted'] + $b['tup_updated'] + $b['tup_deleted']
            - $a['tup_inserted'] - $a['tup_updated'] - $a['tup_deleted']) / $dt,
        'backends' => fn($a, $b, $dt) => $b['numbackends'],
    ];
    $restart = fn($a, $b) => ($a['stats_reset'] ?? '') !== ($b['stats_reset'] ?? '') || $b['xact_commit'] < $a['xact_commit'];
    $main = 'xact/s';
} else {
    fwrite(STDERR, "db-load-sample: database family '$family' is not supported (mysql/mariadb and postgres only)\n");
    exit(2);
}

$start = date('Y-m-d H:i');
echo "== DB load sample '$label' ($family) from " . date('Y-m-d H:i:s T') . ": $samples x {$interval} s ==\n";
printf("%-8s %s\n", 'time', implode(' ', array_map(fn($c) => sprintf('%10s', $c), array_keys($cols))));
$results = [];
$dropped = 0;
$prev = $read();
$t0 = microtime(true);
for ($i = 1; $i <= $samples; $i++) {
    $sleep = $t0 + $i * $interval - microtime(true);
    if ($sleep > 0) {
        usleep((int)($sleep * 1e6));
    }
    $cur = $read();
    $dt = $interval;
    if ($restart($prev, $cur)) {
        echo date('H:i:s') . "  counters reset (DB restart or stats reset): sample dropped\n";
        $dropped++;
        $prev = $cur;
        continue;
    }
    $row = [];
    foreach ($cols as $name => $f) {
        $row[$name] = $f($prev, $cur, $dt);
    }
    $results[] = $row;
    printf("%-8s %s\n", date('H:i:s'), implode(' ', array_map(fn($x) => sprintf('%10.1f', $x), $row)));
    $prev = $cur;
}
if (!$results) {
    echo "no valid sample\n";
    exit(1);
}
$stat = function (array $xs): array {
    sort($xs);
    $n = count($xs);
    $med = $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
    return [$med, $xs[0], $xs[$n - 1]];
};
echo "\n";
foreach (array_keys($cols) as $name) {
    [$med, $min, $max] = $stat(array_column($results, $name));
    printf("%-10s median %9.1f   min %9.1f   max %9.1f\n", $name, $med, $min, $max);
}
[$med, $min, $max] = $stat(array_column($results, $main));
$n = count($results);
if ($family === 'mysql') {
    $up = (int)($prev['Uptime'] ?? 0);
    $uptxt = 'DB uptime ' . ($up >= 86400 ? round($up / 86400, 1) . ' d' : round($up / 3600, 1) . ' h');
} else {
    $uptxt = 'stats since ' . (($prev['stats_reset'] ?? '') ?: 'cluster start');
}
printf("\nlog line: DB %s median %.1f (min %.1f, max %.1f), %d x %d s samples, %s-%s, label '%s', %s%s\n",
    $main, $med, $min, $max, $n, $interval, $start, date('H:i'), $label, $uptxt,
    $dropped ? ", $dropped sample(s) dropped (counter reset)" : '');
if ($n < 3) {
    echo "note: fewer than 3 samples: report this as indicative only\n";
}
echo "note: server-wide counters; compare the same hour and weekday, with no other change in between\n";
