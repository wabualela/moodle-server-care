<?php
// dbstat.php - MariaDB/MySQL + Redis sampler for the unprivileged monitor (moodle-server-care audit module).
//
// Usage (called by run.sh once per minute):
//   php -n -d extension=mysqlnd -d extension=mysqli dbstat.php --dir=<datadir> --boot=<boot_id>
//       --config=<moodle config.php> [--run-th=N] [--no-db] [--redis=host:port | --no-redis] [--users]
//
// Per call: ONE DB connection (unix socket when Moodle uses one or the host is localhost, else TCP; no
// MYSQLI_CLIENT_COMPRESS, no retry), read-only statements only (SHOW GLOBAL STATUS, an aggregate over
// information_schema.PROCESSLIST without INFO, and every 5th minute one indexed COUNT(*) on the user table), plus
// one Redis INFO over fsockopen. The DB session is set READ ONLY with a 5 s statement limit. Credentials are
// parsed from Moodle's config.php with a regex (config.php is never included) and are never printed. If config.php is not readable by the monitor's user, the DB columns stay empty
// (do not loosen config.php's permissions for the monitor: see references/monitor.md).
//
// Output on stdout, one tagged line each (run.sh splits at the first comma):
//   B,<22 fields: my_uptime..my_aborted_clients_d, redis_used_mb..redis_uptime>
//   U,<users_5min or empty>
//   EV,<event text>             -> events.log
//   TH,<name>,<value>           -> threshold currently true
// Side files: state/db.prev (JSON counters for deltas), state/pl.cur (PROCESSLIST aggregate).

declare(strict_types=1);
error_reporting(E_ALL & ~E_DEPRECATED);
ini_set('display_errors', 'stderr');
ini_set('log_errors', '0');
// Server local time (TZ from monitor.env if set, else /etc/localtime), so the PROCESSLIST stamps match metrics.csv.
$tz = getenv('TZ') ?: '';
if ($tz === '' && is_link('/etc/localtime')) {
    $l = (string)readlink('/etc/localtime');
    $p = strpos($l, 'zoneinfo/');
    $tz = $p === false ? '' : substr($l, $p + 9);
}
if ($tz === '' || !@date_default_timezone_set($tz)) {
    date_default_timezone_set('UTC');
}
if (function_exists('pcntl_alarm')) {
    pcntl_alarm(45); // hard stop well inside cron's "timeout 55"; SIGALRM terminates the process
}

const SOCKETS = ['/run/mysqld/mysqld.sock', '/var/run/mysqld/mysqld.sock', '/var/lib/mysql/mysql.sock', '/tmp/mysql.sock'];
const RUN_SAMPLES = 6;      // Threads_running samples
const RUN_INTERVAL = 2.0;   // seconds between samples
const MAX_DT = 600;         // deltas older than this are not computed

$opt = getopt('', ['dir:', 'boot:', 'users', 'config:', 'run-th:', 'no-db', 'redis:', 'no-redis']);
$dir = rtrim((string)($opt['dir'] ?? __DIR__), '/');
$boot = (string)($opt['boot'] ?? '');
$wantUsers = isset($opt['users']);
$configPhp = (string)($opt['config'] ?? '');
$runTh = max(1, (int)($opt['run-th'] ?? 16));
$wantDb = !isset($opt['no-db']);
$redisAddr = isset($opt['no-redis']) ? '' : (string)($opt['redis'] ?? '127.0.0.1:6379');
$stateFile = "$dir/state/db.prev";
$plFile = "$dir/state/pl.cur";

$lines = [];   // EV / TH lines

$prev = [];
if (is_readable($stateFile)) {
    $j = json_decode((string)file_get_contents($stateFile), true);
    if (is_array($j)) {
        $prev = $j;
    }
}
$sameBoot = $boot !== '' && ($prev['boot'] ?? '') === $boot;
$new = ['boot' => $boot];

function fmt(?float $v, int $dec): string
{
    return $v === null ? '' : sprintf('%.' . $dec . 'F', $v);
}

// --------------------------------------------------------------------------------------------
// MariaDB
// --------------------------------------------------------------------------------------------
$MYVARS = [
    'Uptime', 'Threads_connected', 'Threads_running', 'Questions', 'Slow_queries', 'Select_full_join',
    'Created_tmp_disk_tables', 'Innodb_buffer_pool_reads', 'Innodb_buffer_pool_pages_data',
    'Innodb_buffer_pool_pages_dirty', 'Innodb_checkpoint_age', 'Innodb_row_lock_waits', 'Aborted_clients',
];
$MYCOUNTERS = ['Questions', 'Slow_queries', 'Select_full_join', 'Created_tmp_disk_tables',
    'Innodb_buffer_pool_reads', 'Innodb_row_lock_waits', 'Aborted_clients', 'Uptime'];

$myCols = array_fill(0, 15, '');
$users = '';

$cfg = ($wantDb && $configPhp !== '') ? @file_get_contents($configPhp) : false;
$get = function (string $k) use ($cfg): ?string {
    if (is_string($cfg) && preg_match('/\$CFG->' . $k . '\s*=\s*([\'"])(.*?)\1\s*;/s', $cfg, $m)) {
        return stripcslashes($m[2]);
    }
    return null;
};
$dbuser = $get('dbuser');
$dbpass = $get('dbpass');
$dbname = $get('dbname');
$prefix = $get('prefix') ?? 'mdl_';
$dbhost = $get('dbhost') ?? 'localhost';
$dbtype = $get('dbtype') ?? '';
$socket = null;
$port = null;
if (is_string($cfg) && preg_match("/'dbsocket'\s*=>\s*'([^']+)'/", $cfg, $m) && $m[1] !== '1') {
    $socket = $m[1];
}
if (is_string($cfg) && preg_match("/'dbport'\s*=>\s*'?([0-9]+)'?/", $cfg, $m)) {
    $port = (int)$m[1];
}
if ($socket === null && in_array($dbhost, ['localhost', ''], true)) {
    foreach (SOCKETS as $s) {
        if (@file_exists($s)) {
            $socket = $s;
            break;
        }
    }
}
unset($cfg);

$db = null;
if (!$wantDb) {
    // DB sampling off (PostgreSQL site, or no DB access for the monitor): columns stay empty, no error line.
} elseif ($dbtype !== '' && !in_array($dbtype, ['mysqli', 'mariadb', 'auroramysql'], true)) {
    fwrite(STDERR, "dbstat: dbtype $dbtype is not MySQL/MariaDB; set DB_ENABLED=0 in monitor.env\n");
} elseif (!function_exists('mysqli_init')) {
    fwrite(STDERR, "dbstat: mysqli extension not loaded\n");
} elseif ($dbuser === null || $dbpass === null || $dbname === null) {
    fwrite(STDERR, "dbstat: could not parse DB settings from config.php\n");
} else {
    mysqli_report(MYSQLI_REPORT_OFF);
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
    if (defined('MYSQLI_OPT_READ_TIMEOUT')) {
        $db->options(MYSQLI_OPT_READ_TIMEOUT, 15);
    }
    // flags = 0: deliberately NOT MYSQLI_CLIENT_COMPRESS. Single attempt, no retry.
    $host = $socket !== null ? 'localhost' : $dbhost;
    if (!@$db->real_connect($host, $dbuser, $dbpass, $dbname, $port, $socket, 0)) {
        fwrite(STDERR, 'dbstat: mysql connect failed (errno ' . mysqli_connect_errno() . ")\n");
        $db = null;
    } else {
        // Belt and braces: this session can only read, and no statement may run longer than 5 s
        // (MariaDB: max_statement_time in seconds; MySQL: max_execution_time in ms, SELECT only).
        // Failures are ignored (older servers); every statement below is read-only anyway.
        @$db->query('SET SESSION TRANSACTION READ ONLY');
        if (!@$db->query('SET SESSION max_statement_time=5')) {
            @$db->query('SET SESSION max_execution_time=5000');
        }
    }
}
unset($dbpass);

if ($db !== null) {
    $t1 = microtime(true);
    $st = [];
    $r = $db->query("SHOW GLOBAL STATUS WHERE Variable_name IN ('" . implode("','", $MYVARS) . "')");
    if ($r instanceof mysqli_result) {
        while ($row = $r->fetch_row()) {
            $st[$row[0]] = $row[1];
        }
        $r->free();
    }
    $run = [];
    if (isset($st['Threads_running'])) {
        $run[] = max(0, (int)$st['Threads_running'] - 1); // minus the monitor's own thread
    }

    // PROCESSLIST aggregate: own DB user only (no PROCESS privilege), never INFO.
    $long = null;
    $r = $db->query("SELECT COMMAND, STATE, COUNT(*), SUM(COMMAND<>'Sleep' AND TIME>=1), MAX(TIME)"
        . " FROM information_schema.PROCESSLIST WHERE ID<>CONNECTION_ID()"
        . " GROUP BY COMMAND, STATE ORDER BY 3 DESC");
    if ($r instanceof mysqli_result) {
        $long = 0;
        $pl = '# ' . date('Y-m-d H:i:s') . "\nCOMMAND\tSTATE\tn\tlong_ge1s\tmax_time_s\n";
        while ($row = $r->fetch_row()) {
            $long += (int)$row[3];
            $pl .= implode("\t", array_map(fn($v) => $v === null ? '' : (string)$v, $row)) . "\n";
        }
        $r->free();
        @file_put_contents("$plFile.tmp", $pl);
        @rename("$plFile.tmp", $plFile);
    }

    if ($wantUsers && preg_match('/^[a-z0-9_]+$/', $prefix)) {
        $r = $db->query("SELECT COUNT(*) FROM {$prefix}user WHERE deleted=0 AND lastaccess > UNIX_TIMESTAMP()-300");
        if ($r instanceof mysqli_result) {
            $users = (string)$r->fetch_row()[0];
            $r->free();
        }
    }

    for ($k = 1; $k < RUN_SAMPLES; $k++) {
        $sleep = $t1 + $k * RUN_INTERVAL - microtime(true);
        if ($sleep > 0) {
            usleep((int)($sleep * 1e6));
        }
        $r = $db->query("SHOW GLOBAL STATUS LIKE 'Threads_running'");
        if ($r instanceof mysqli_result) {
            $row = $r->fetch_row();
            $r->free();
            if ($row) {
                $run[] = max(0, (int)$row[1] - 1);
            }
        }
    }
    $db->close();

    if (isset($st['Uptime'])) {
        $pm = $prev['my'] ?? null;
        $restart = is_array($pm) && isset($pm['Uptime']) && (int)$st['Uptime'] < (int)$pm['Uptime'];
        if ($restart && $sameBoot) {
            $lines[] = "EV,database server restarted (Uptime {$pm['Uptime']} -> {$st['Uptime']})";
        }
        $dt = $t1 - (float)($prev['my_t'] ?? 0);
        $valid = $sameBoot && !$restart && is_array($pm) && $dt > 0 && $dt <= MAX_DT;
        $d = function (string $k) use ($valid, $pm, $st): ?float {
            if (!$valid || !isset($pm[$k], $st[$k])) {
                return null;
            }
            $x = (float)$st[$k] - (float)$pm[$k];
            return $x < 0 ? null : $x;
        };
        $rate = fn(?float $x, float $mult = 1.0) => $x === null ? null : $x * $mult / $dt;
        $g = fn(string $k) => isset($st[$k]) ? (float)$st[$k] : null;

        $runMax = $run ? max($run) : null;
        $myCols = [
            fmt($g('Uptime'), 0),
            fmt(isset($st['Threads_connected']) ? max(0, (float)$st['Threads_connected'] - 1) : null, 0),
            fmt($run ? array_sum($run) / count($run) : null, 1),
            fmt($runMax === null ? null : (float)$runMax, 0),
            fmt($long === null ? null : (float)$long, 0),
            fmt($rate($d('Questions')), 1),
            fmt($rate($d('Slow_queries'), 60.0), 2),
            fmt($rate($d('Select_full_join')), 2),
            fmt($rate($d('Created_tmp_disk_tables')), 3),
            fmt($rate($d('Innodb_buffer_pool_reads')), 2),
            fmt($g('Innodb_buffer_pool_pages_data'), 0),
            fmt($g('Innodb_buffer_pool_pages_dirty'), 0),
            fmt(isset($st['Innodb_checkpoint_age']) ? (float)$st['Innodb_checkpoint_age'] / 1048576 : null, 1),
            fmt($d('Innodb_row_lock_waits'), 0),
            fmt($d('Aborted_clients'), 0),
        ];
        if ($runMax !== null && $runMax >= $runTh) {
            $lines[] = "TH,my_run_max,$runMax";
        }
        $new['my_t'] = $t1;
        $new['my'] = array_intersect_key($st, array_flip($MYCOUNTERS));
    }
}
if (!isset($new['my']) && $sameBoot && isset($prev['my'])) {
    // DB unavailable this minute: carry the old counters so the next delta spans both minutes.
    $new['my'] = $prev['my'];
    $new['my_t'] = $prev['my_t'] ?? 0;
}

// --------------------------------------------------------------------------------------------
// Redis INFO (host:port from --redis; INFO is refused with NOAUTH when Redis requires a password, and the monitor
// never handles that password: the Redis columns then stay empty)
// --------------------------------------------------------------------------------------------
$redisCols = array_fill(0, 7, '');
$info = [];
$rs = false;
if ($redisAddr !== '') {
    $rp = strrpos($redisAddr, ':');
    $rhost = $rp === false ? $redisAddr : substr($redisAddr, 0, $rp);
    $rport = $rp === false ? 6379 : (int)substr($redisAddr, $rp + 1);
    $rs = @fsockopen($rhost, $rport, $errno, $errstr, 2.0);
}
if ($redisAddr === '') {
    // Redis sampling off
} elseif ($rs === false) {
    fwrite(STDERR, "dbstat: redis connect failed ($errno)\n");
} else {
    stream_set_timeout($rs, 2);
    fwrite($rs, "INFO\r\n");
    $hdr = fgets($rs);
    if (is_string($hdr) && $hdr !== '' && $hdr[0] === '$') {
        $n = min((int)substr($hdr, 1), 1048576);
        $buf = '';
        while (strlen($buf) < $n + 2 && !feof($rs)) {
            $chunk = fread($rs, $n + 2 - strlen($buf));
            if ($chunk === false || $chunk === '') {
                break;
            }
            $buf .= $chunk;
        }
        foreach (explode("\r\n", $buf) as $l) {
            $p = strpos($l, ':');
            if ($p !== false && $l[0] !== '#') {
                $info[substr($l, 0, $p)] = substr($l, $p + 1);
            }
        }
    } else {
        fwrite(STDERR, "dbstat: unexpected redis reply\n");
    }
    fclose($rs);
}
if (isset($info['uptime_in_seconds'])) {
    $tr = microtime(true);
    $pr = $prev['redis'] ?? null;
    $restart = is_array($pr) && isset($pr['uptime_in_seconds'])
        && (int)$info['uptime_in_seconds'] < (int)$pr['uptime_in_seconds'];
    if ($restart && $sameBoot) {
        $lines[] = "EV,redis restarted (uptime {$pr['uptime_in_seconds']} -> {$info['uptime_in_seconds']})";
    }
    $dt = $tr - (float)($prev['redis_t'] ?? 0);
    $valid = $sameBoot && !$restart && is_array($pr) && $dt > 0 && $dt <= MAX_DT;
    $d = function (string $k) use ($valid, $pr, $info): ?float {
        if (!$valid || !isset($pr[$k], $info[$k])) {
            return null;
        }
        $x = (float)$info[$k] - (float)$pr[$k];
        return $x < 0 ? null : $x;
    };
    $dh = $d('keyspace_hits');
    $dm = $d('keyspace_misses');
    $dc = $d('total_commands_processed');
    $db1 = 0.0;   // keys over all logical databases (sessions and caches)
    foreach ($info as $k => $v) {
        if (preg_match('/^db\d+$/', $k) && preg_match('/keys=(\d+)/', $v, $m)) {
            $db1 += (float)$m[1];
        }
    }
    $redisCols = [
        fmt(isset($info['used_memory']) ? (float)$info['used_memory'] / 1048576 : null, 1),
        fmt(isset($info['connected_clients']) ? max(0, (float)$info['connected_clients'] - 1) : null, 0),
        fmt($dc === null ? null : $dc / $dt, 1),
        fmt(($dh !== null && $dm !== null && $dh + $dm > 0) ? 100 * $dh / ($dh + $dm) : null, 2),
        fmt($d('evicted_keys'), 0),
        fmt($db1, 0),
        fmt((float)$info['uptime_in_seconds'], 0),
    ];
    $new['redis_t'] = $tr;
    $new['redis'] = array_intersect_key($info, array_flip(
        ['uptime_in_seconds', 'total_commands_processed', 'keyspace_hits', 'keyspace_misses', 'evicted_keys']));
} elseif ($sameBoot && isset($prev['redis'])) {
    $new['redis'] = $prev['redis'];
    $new['redis_t'] = $prev['redis_t'] ?? 0;
}

// Edge-triggered reachability events (one line when a service goes away, one when it is back).
$myUp = isset($new['my_t']) && ($new['my_t'] !== ($prev['my_t'] ?? null));
$rUp = isset($info['uptime_in_seconds']);
$svcs = [];
if ($wantDb) {
    $svcs[] = ['database', $myUp, 'my_down'];
}
if ($redisAddr !== '') {
    $svcs[] = ['redis', $rUp, 'redis_down'];
}
foreach ($svcs as [$svc, $up, $key]) {
    $wasDown = !empty($prev[$key]);
    if (!$up && !$wasDown) {
        $lines[] = "EV,$svc not reachable by the monitor (see monitor.err)";
    } elseif ($up && $wasDown) {
        $lines[] = "EV,$svc reachable again";
    }
    $new[$key] = $up ? 0 : 1;
}

@file_put_contents("$stateFile.tmp", json_encode($new));
@rename("$stateFile.tmp", $stateFile);

echo 'B,' . implode(',', array_merge($myCols, $redisCols)) . "\n";
echo 'U,' . $users . "\n";
foreach ($lines as $l) {
    echo $l, "\n";
}
