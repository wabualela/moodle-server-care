<?php
// perf-settings.php — READ-ONLY list of Moodle settings that decide speed (moodle-server-care, module "tuning").
// Prints each value, whether it is forced in config.php, and "CHECK" where it differs from the usual production
// value, with the reason. Also: cache store mappings (MUC), session handler and lock settings, the size of the
// "Additional HTML" head, theme loader and H5P hub settings when present. Prints no secrets and no personal data.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php perf-settings.php --moodle=DIR

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'help']);
if (isset($opts['help']) || empty($opts['moodle'])) {
    fwrite(STDERR, "usage: php perf-settings.php --moodle=DIR\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "perf-settings: cannot read $moodle/config.php\n");
    exit(2);
}
require("$moodle/config.php");

$checks = 0;
$show = function (string $name, $value, $want, string $why, string $plugin = 'core') use (&$checks, $CFG) {
    $forced = ($plugin === 'core' && array_key_exists($name, $CFG->config_php_settings ?? [])) ? ' [config.php]' : '';
    $v = $value === null || $value === false ? '(unset: default)' : (is_scalar($value) ? (string)$value : json_encode($value));
    $flag = '';
    if ($want !== null) {
        $ok = is_callable($want) ? $want($value) : ((string)$value === (string)$want);
        if (!$ok) {
            $flag = '  CHECK: ' . $why;
            $checks++;
        }
    }
    printf("  %-44s %s%s%s\n", ($plugin === 'core' ? '' : "$plugin | ") . $name, $v, $forced, $flag);
};
$cfg = fn(string $n) => $CFG->$n ?? null;

echo '== Moodle performance settings (read-only) ' . date('Y-m-d H:i:s T') . ' ==' . "\n";
echo '  release ' . ($CFG->release ?? '?') . ', dbtype ' . ($CFG->dbtype ?? '?') . ', theme ' . ($CFG->theme ?? '?') . "\n";

echo "\n-- caching of static files and strings --\n";
$show('themedesignermode', $cfg('themedesignermode'), fn($v) => empty($v), 'on rebuilds theme CSS on every request; never on production');
$show('cachejs', $cfg('cachejs'), fn($v) => $v === null || !empty($v), 'off serves JavaScript uncached');
$show('cachetemplates', $cfg('cachetemplates'), fn($v) => $v === null || !empty($v), 'off reloads Mustache templates every request');
$show('langstringcache', $cfg('langstringcache'), fn($v) => $v === null || !empty($v), 'off reads language files every request');
$show('slasharguments', $cfg('slasharguments'), fn($v) => $v === null || !empty($v), 'off gives static URLs with "?file=" that browsers and CDNs cache badly');
$show('yuicomboloading', $cfg('yuicomboloading'), fn($v) => $v === null || !empty($v), 'off loads YUI modules one request each');
$show('xsendfile', $cfg('xsendfile'), fn($v) => !empty($v), 'unset: PHP streams every file itself; X-Accel-Redirect/X-Sendfile lets the web server do it');
$al = $cfg('xsendfilealiases');
$show('xsendfilealiases (keys)', is_array($al) ? implode(',', array_keys($al)) : null, null, '');
$show('localcachedir', $cfg('localcachedir') ? 'set' : null, null, '');
$show('alternative_component_cache', $cfg('alternative_component_cache') ? 'set' : null, null, '');

echo "\n-- debugging (costly and leaky when on) --\n";
$show('debug', $cfg('debug'), fn($v) => (int)$v <= 5, 'developer debugging adds work to every request');
$show('debugdisplay', $cfg('debugdisplay'), fn($v) => empty($v), 'shows errors to visitors');
$show('perfdebug', $cfg('perfdebug'), fn($v) => (int)$v !== 15, 'performance footer on every page');
$show('debugpageinfo', $cfg('debugpageinfo'), fn($v) => empty($v), 'page info footer');

echo "\n-- sessions --\n";
$handler = $cfg('session_handler_class') ?: '\core\session\file (default)';
$show('session_handler_class', $handler, null, '');
$show('enable_read_only_sessions', $cfg('enable_read_only_sessions'), null, '');
foreach (['session_redis_acquire_lock_timeout', 'session_redis_lock_expire', 'session_database_acquire_lock_timeout',
        'session_memcached_acquire_lock_timeout'] as $n) {
    if ($cfg($n) !== null) {
        $show($n, $cfg($n), null, '');
    }
}
$show('sessiontimeout', $cfg('sessiontimeout'), null, '');

echo "\n-- cache stores (MUC) --\n";
try {
    $cc = class_exists('\core_cache\config') ? \core_cache\config::instance() : cache_config::instance();
    $stores = $cc->get_all_stores();
    $modes = [1 => 'application', 2 => 'session', 4 => 'request'];
    foreach ($cc->get_mode_mappings() as $m) {
        $st = $stores[$m['store']] ?? [];
        printf("  default %-12s -> %s (%s)\n", $modes[$m['mode']] ?? $m['mode'], $m['store'], $st['plugin'] ?? '?');
    }
    $custom = 0;
    foreach ($stores as $name => $st) {
        if (empty($st['default'])) {
            $custom++;
            printf("  store %-30s plugin %s\n", $name, $st['plugin'] ?? '?');
        }
    }
    if (!$custom) {
        echo "  no extra cache stores: application cache is on files in the data root (fine for one server; Redis/APCu " .
            "help when disk is slow or there are several web nodes)\n";
    }
} catch (Throwable $e) {
    echo '  could not read the cache configuration: ' . $e->getMessage() . "\n";
}

echo "\n-- cron and logs --\n";
$show('cron_keepalive', get_config('core', 'cron_keepalive'), null, '');
$show('task_logmode', get_config('core', 'task_logmode'), null, '');
$show('enabled log stores', get_config('tool_log', 'enabled_stores'), null, '');
$show('loglifetime', get_config('logstore_standard', 'loglifetime'), null, '', 'logstore_standard');
$show('enablestats', $cfg('enablestats'), fn($v) => empty($v), 'site statistics run heavy nightly jobs; usually unused');
$show('enableanalytics', $cfg('enableanalytics'), null, '');

echo "\n-- front end and login --\n";
$head = (string)$cfg('additionalhtmlhead');
$show('additionalhtmlhead length / <script> tags', strlen($head) . ' chars / ' . substr_count(strtolower($head), '<script'), null, '');
$show('additionalhtmltopofbody length', strlen((string)$cfg('additionalhtmltopofbody')), null, '');
$show('additionalhtmlfooter length', strlen((string)$cfg('additionalhtmlfooter')), null, '');
$show('enablegravatar', $cfg('enablegravatar'), null, '');
$show('authloginviaemail', $cfg('authloginviaemail'), null, '');
$show('maxbytes', $cfg('maxbytes'), null, '');
$show('getremoteaddrconf', $cfg('getremoteaddrconf'), null, '');

$theme = $CFG->theme ?? '';
if ($theme === 'remui') {
    echo "\n-- theme_remui --\n";
    $show('enablesiteloader', get_config('theme_remui', 'enablesiteloader'), fn($v) => empty($v),
        'full-screen loader hides the page until all scripts ran', 'theme_remui');
    $show('enrolleduserscountvisibility', get_config('theme_remui', 'enrolleduserscountvisibility'), null, '', 'theme_remui');
}
$pm = core_plugin_manager::instance();
if ($pm->get_plugin_info('mod_hvp')) {
    echo "\n-- mod_hvp (H5P plugin) --\n";
    $show('hub_is_enabled', get_config('mod_hvp', 'hub_is_enabled'), null, '', 'mod_hvp');
    $show('h5p_search_content_hub', get_config('mod_hvp', 'h5p_search_content_hub'), fn($v) => empty($v),
        'the editor fetches content-hub metadata from h5p.org while holding the session lock', 'mod_hvp');
}
echo "\nitems marked CHECK: $checks (read-only: nothing changed)\n";
