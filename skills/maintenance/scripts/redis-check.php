<?php
// redis-check.php (moodle-server-care, skills/maintenance): READ-ONLY check that the Redis settings Moodle uses
// actually work: the session handler ($CFG->session_redis_*) and every MUC cache store of plugin "redis"
// (moodledata/muc/config.php). For each it connects with phpredis, authenticates with the configured password (if
// any) and sends PING. It prints one line per target and NEVER prints a password.
//
// Usage (as the web user, file copied to a place that user can read, e.g. /tmp, mode 644):
//   sudo -u www-data php redis-check.php /path/to/moodle/config.php
// Exit: 0 all targets answer PONG; 1 at least one fails; 2 usage or setup problem; 3 Moodle does not use Redis.
//
// It loads config.php with ABORT_AFTER_CONFIG, so Moodle stops right after reading its settings: no DB connection,
// no session, no cache initialisation, no write anywhere.

define('CLI_SCRIPT', true);
define('ABORT_AFTER_CONFIG', true);

if ($argc < 2 || !is_readable($argv[1])) {
    fwrite(STDERR, "usage: php redis-check.php <moodle config.php> (readable by this user)\n");
    exit(2);
}
require($argv[1]);
global $CFG;
if (empty($CFG) || empty($CFG->dataroot)) {
    fwrite(STDERR, "config.php did not define \$CFG->dataroot\n");
    exit(2);
}
if (!class_exists('Redis')) {
    echo "FAIL phpredis extension not loaded in this PHP CLI (Moodle's Redis stores need it)\n";
    exit(2);
}

/**
 * Split a MUC/session server string into [host, port, tls]. Unix sockets keep the path as host and port 0.
 */
function msc_parse_server(string $server, int $defaultport = 6379): array {
    $tls = false;
    if (preg_match('#^(tls|ssl)://#i', $server)) {
        $tls = true;
        $server = preg_replace('#^(tls|ssl)://#i', '', $server);
    }
    if ($server !== '' && $server[0] === '/') {
        return [$server, 0, $tls];
    }
    if (preg_match('/^\[(.+)\]:(\d+)$/', $server, $m)) {
        return [$m[1], (int)$m[2], $tls];
    }
    if (preg_match('/^([^:]+):(\d+)$/', $server, $m)) {
        return [$m[1], (int)$m[2], $tls];
    }
    return [$server, $defaultport, $tls];
}

/**
 * Connect, AUTH if a password is configured, PING. Returns "PONG" or a short error word (NOAUTH, WRONGPASS, ...).
 */
function msc_probe(string $host, int $port, string $password, int $db): string {
    try {
        $r = new Redis();
        if ($port === 0) {
            $ok = $r->connect($host, -1, 2.0);
        } else {
            $ok = $r->connect($host, $port, 2.0);
        }
        if (!$ok) {
            return 'CONNECT-FAILED';
        }
        if ($password !== '') {
            if ($r->auth($password) === false) {
                $e = (string)$r->getLastError();
                return $e !== '' ? strtok($e, ' ') : 'AUTH-FAILED';
            }
        }
        if ($db > 0) {
            $r->select($db);
        }
        $p = $r->ping();
        $r->close();
        return ($p === true || $p === '+PONG' || $p === 'PONG') ? 'PONG' : 'UNEXPECTED';
    } catch (Throwable $e) {
        $w = strtok(trim($e->getMessage()), ' ');
        return $w === false || $w === '' ? get_class($e) : preg_replace('/[^A-Za-z_-]/', '', $w);
    }
}

$targets = [];
$handler = isset($CFG->session_handler_class) ? (string)$CFG->session_handler_class : '';
if (stripos($handler, 'redis') !== false) {
    $host = isset($CFG->session_redis_host) ? (string)$CFG->session_redis_host : '127.0.0.1';
    $port = isset($CFG->session_redis_port) ? (int)$CFG->session_redis_port : 6379;
    [$h, $p, $tls] = msc_parse_server(strpos($host, ':') !== false || $host[0] === '/' ? $host : "$host:$port", $port);
    $targets[] = ['sessions', $h, $p, $tls, isset($CFG->session_redis_auth) ? (string)$CFG->session_redis_auth : '',
        isset($CFG->session_redis_database) ? (int)$CFG->session_redis_database : 0];
}
$mucfile = $CFG->dataroot . '/muc/config.php';
if (!defined('MOODLE_INTERNAL')) {
    define('MOODLE_INTERNAL', true);   // the MUC file starts with "defined('MOODLE_INTERNAL') || die();"
}
if (is_readable($mucfile)) {
    $configuration = null;
    include($mucfile);
    if (is_array($configuration) && !empty($configuration['stores'])) {
        foreach ($configuration['stores'] as $name => $store) {
            if (($store['plugin'] ?? '') !== 'redis') {
                continue;
            }
            $c = $store['configuration'] ?? [];
            $server = (string)($c['server'] ?? '');
            if (strpos($server, ',') !== false || strpos($server, "\n") !== false) {
                $targets[] = ["store $name", $server, -1, false, '', 0];   // cluster: not probed
                continue;
            }
            [$h, $p, $tls] = msc_parse_server($server);
            $targets[] = ["store $name", $h, $p, $tls || !empty($c['encryption']), (string)($c['password'] ?? ''),
                (int)($c['database'] ?? 0)];
        }
    }
}
if (!$targets) {
    echo "INFO Moodle uses Redis neither for sessions nor for MUC stores\n";
    exit(3);
}
$bad = 0;
foreach ($targets as [$label, $h, $p, $tls, $pw, $db]) {
    $where = $p === 0 ? $h : "$h:$p";
    if ($p === -1) {
        echo "SKIP $label cluster ($where): not probed\n";
        continue;
    }
    if ($tls) {
        echo "SKIP $label $where: TLS connection, not probed by this check\n";
        continue;
    }
    $res = msc_probe($h, $p, $pw, $db);
    $auth = $pw === '' ? 'no password configured' : 'password configured';
    if ($res === 'PONG') {
        echo "OK   $label $where PONG ($auth)\n";
    } else {
        echo "FAIL $label $where $res ($auth)\n";
        $bad++;
    }
}
exit($bad ? 1 : 0);
