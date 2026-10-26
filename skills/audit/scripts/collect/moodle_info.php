<?php
// moodle_info.php -- read-only Moodle facts for the moodle-server-care audit collector (step R-MDL-02).
//
// Run as the web user, with the script on stdin (so the web user never needs to read the operator's home):
//   sudo -u www-data php -- /path/to/moodle < moodle_info.php
//   (the collector runs: runuser -u <WEBUSER> -- <PHP> -- <MOODLE> < moodle_info.php)
//
// What it prints (tab-separated sections, "## name" headers): site facts, a fixed list of non-secret settings,
// cache store names and types, scheduled tasks (schedule, state, last/next run, fail delay), the ad hoc queue by
// class, non-standard plugins with versions, a few counts (users active in 5 min / 1 h / 24 h / 30 d, courses,
// enrolments), enabled auth/enrol plugins, the pending-upgrade flag and the current theme's colour/font settings
// (for the report's visual identity).
//
// What it never prints: config.php credentials (dbuser, dbpass, any *pass*/secret/key/token/salt setting), cache
// store configuration (it holds Redis/Memcached passwords), any user, course or message content, names or e-mail
// addresses. Counts only. The DB session is switched to READ ONLY after bootstrap where the database allows it.
// The collector still passes the output through mask.sed.

define('CLI_SCRIPT', true);

$dir = $argv[1] ?? '';
if ($dir === '' || !is_file($dir . '/config.php')) {
    fwrite(STDERR, "usage: php -- <moodle dir> < moodle_info.php\n");
    exit(2);
}
require($dir . '/config.php');

/** @var stdClass $CFG */
/** @var moodle_database $DB */
global $CFG, $DB;

function out(string $s): void {
    echo $s, "\n";
}
function clean($v): string {
    if (is_bool($v)) {
        return $v ? '1' : '0';
    }
    if ($v === null) {
        return '<unset>';
    }
    if (is_array($v) || is_object($v)) {
        $v = json_encode($v);
    }
    $v = preg_replace('/[\t\r\n]+/', ' ', (string)$v);
    return strlen($v) > 200 ? substr($v, 0, 200) . '[cut]' : $v;
}
function secretname(string $n): bool {
    if (in_array($n, ['passwordpolicy', 'smtpauthtype'], true)) {
        return false;   // policy flags, not secrets
    }
    return (bool)preg_match('/pass|secret|key|token|salt|dbuser|credential|auth_?code/i', $n);
}
function section(string $name, callable $fn): void {
    out('## ' . $name);
    try {
        $fn();
    } catch (Throwable $e) {
        out("error\t" . get_class($e) . "\t" . clean($e->getMessage()));
    }
    out('');
}

// Read-only session from here on: any accidental write fails instead of changing data.
try {
    if ($DB->get_dbfamily() === 'mysql') {
        $DB->execute('SET SESSION TRANSACTION READ ONLY');
    } else if ($DB->get_dbfamily() === 'postgres') {
        $DB->execute('SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY');
    }
    $readonly = 'yes';
} catch (Throwable $e) {
    $readonly = 'no (' . get_class($e) . ')';
}

section('site', function () use ($CFG, $DB, $readonly) {
    out("release\t" . clean($CFG->release ?? ''));
    out("version\t" . clean($CFG->version ?? ''));
    out("branch\t" . clean($CFG->branch ?? ''));
    out("php\t" . PHP_VERSION);
    out("dbfamily\t" . $DB->get_dbfamily());
    out("dbtype\t" . clean($CFG->dbtype ?? ''));
    out("db_server_version\t" . clean($DB->get_server_info()['version'] ?? ''));
    out("db_session_read_only\t" . $readonly);
    out("dirroot\t" . clean($CFG->dirroot));
    out("dataroot\t" . clean($CFG->dataroot));
    foreach (['localcachedir', 'cachedir', 'tempdir', 'localrequestdir', 'alternative_file_system_class',
              'session_handler_class', 'session_redis_host', 'session_redis_port', 'session_redis_database',
              'session_redis_acquire_lock_timeout', 'session_redis_lock_expire', 'dbsessions', 'theme', 'lang',
              'timezone', 'forcetimezone', 'slasharguments', 'reverseproxy', 'sslproxy', 'routerconfigured'] as $n) {
        out($n . "\t" . clean($CFG->$n ?? null));
    }
    out("upgrade_pending\t" . (function_exists('moodle_needs_upgrading') && moodle_needs_upgrading() ? 'yes' : 'no'));
});

section('settings', function () use ($CFG) {
    $names = ['debug', 'debugdisplay', 'perfdebug', 'debugpageinfo', 'debugsqltrace', 'cachejs', 'cachetemplates',
        'themedesignermode', 'langstringcache', 'yuicomboloading', 'getremoteaddrconf', 'cookiesecure',
        'cookiehttponly', 'sessiontimeout', 'sessioncookie', 'tracksessionip', 'enablewebservices',
        'enablemobilewebservice', 'registerauth', 'autologinguests', 'guestloginbutton', 'forcelogin',
        'forceloginforprofiles', 'maxbytes', 'noemailever', 'smtphosts', 'smtpsecure', 'smtpauthtype',
        'smtpmaxbulk', 'noreplyaddress', 'emailonlyfromnoreplyaddress', 'allowedemaildomains', 'enablestats',
        'cronclionly', 'cron_enabled', 'cron_keepalive', 'task_scheduled_concurrency_limit',
        'task_adhoc_concurrency_limit', 'task_scheduled_max_runtime', 'task_adhoc_max_runtime', 'task_logmode',
        'enablecompletion', 'enableanalytics', 'enablebadges', 'enableblogs', 'messaging', 'enablegravatar',
        'allowthemechangeonurl', 'allowuserthemes', 'allowcoursethemes', 'passwordpolicy', 'lockoutthreshold',
        'allowframembedding', 'curlsecurityblockedhosts', 'curlsecurityallowedport', 'preventexecpath',
        'pathtophp', 'enableglobalsearch', 'searchengine', 'filterall', 'navshowallcourses',
        'frontpage', 'frontpageloggedin', 'maxcategorydepth', 'coursecontact', 'enablecourserelativedates',
        'enablecustomreports', 'h5plibraryhandler', 'antiviruses', 'backup_auto_active', 'logguests',
        'loglifetime', 'tool_logstore_enabled_stores'];
    foreach ($names as $n) {
        if (secretname($n)) {
            continue;
        }
        $v = $CFG->$n ?? get_config('core', $n);
        out($n . "\t" . clean($v === false ? null : $v));
    }
    $ls = get_config('tool_log', 'enabled_stores');
    out("tool_log_enabled_stores\t" . clean($ls === false ? null : $ls));
    $ll = get_config('logstore_standard', 'loglifetime');
    out("logstore_standard_loglifetime\t" . clean($ll === false ? null : $ll));
});

section('cache_stores', function () {
    $cls = class_exists('\core_cache\config') ? '\core_cache\config' : (class_exists('cache_config') ? 'cache_config' : null);
    if ($cls === null) {
        out("note\tno cache config class");
        return;
    }
    $config = $cls::instance();
    out("store\tplugin\tmodes");
    foreach ($config->get_all_stores() as $name => $store) {
        // Only the name, the plugin type and the modes. 'configuration' holds passwords and is never printed.
        out(clean($name) . "\t" . clean($store['plugin'] ?? '') . "\t" . clean($store['modes'] ?? ''));
    }
    foreach ($config->get_mode_mappings() as $m) {
        out('mode_mapping_' . clean($m['mode'] ?? '') . "\t" . clean($m['store'] ?? '') . "\t");
    }
});

section('scheduled_tasks', function () {
    out("classname\tcomponent\tschedule\tdisabled\tcomponent_enabled\tlastrun\tnextrun\tfaildelay\tcustomised");
    foreach (\core\task\manager::get_all_scheduled_tasks() as $t) {
        $sched = $t->get_minute() . ' ' . $t->get_hour() . ' ' . $t->get_day() . ' ' . $t->get_month() . ' ' . $t->get_day_of_week();
        $compenabled = method_exists($t, 'is_component_enabled') ? ($t->is_component_enabled() ? '1' : '0') : '?';
        $custom = method_exists($t, 'is_customised') ? ($t->is_customised() ? '1' : '0') : '?';
        $last = $t->get_last_run_time();
        $next = $t->get_next_run_time();
        out(get_class($t) . "\t" . clean($t->get_component()) . "\t" . $sched . "\t" . ($t->get_disabled() ? '1' : '0') . "\t" .
            $compenabled . "\t" . ($last ? date('Y-m-d H:i', $last) : 'never') . "\t" . ($next ? date('Y-m-d H:i', $next) : '-') .
            "\t" . (int)$t->get_fail_delay() . "\t" . $custom);
    }
});

section('adhoc_queue', function () use ($DB) {
    out("classname\tqueued\tfailing\toldest_nextrun_age_min\trunning");
    $now = time();
    // timestarted exists from Moodle 3.10/4.x on; older sites get 0 in the running column.
    $running = $DB->get_manager()->field_exists('task_adhoc', 'timestarted')
        ? "SUM(CASE WHEN timestarted IS NOT NULL AND timestarted > 0 THEN 1 ELSE 0 END)" : "0";
    $rows = $DB->get_records_sql("SELECT classname, COUNT(1) AS n,
                                         SUM(CASE WHEN faildelay > 0 THEN 1 ELSE 0 END) AS f,
                                         MIN(nextruntime) AS oldest,
                                         $running AS r
                                    FROM {task_adhoc} GROUP BY classname ORDER BY COUNT(1) DESC");
    foreach ($rows as $r) {
        out(clean($r->classname) . "\t" . (int)$r->n . "\t" . (int)$r->f . "\t" .
            ($r->oldest ? (int)floor(($now - $r->oldest) / 60) : '') . "\t" . (int)$r->r);
    }
});

section('plugins_nonstandard', function () {
    out("plugin\tversion_disk\tversion_db\trelease\tstatus");
    $pm = core_plugin_manager::instance();
    $std = 0;
    foreach ($pm->get_plugins() as $type => $list) {
        foreach ($list as $name => $pi) {
            if ($pi->is_standard()) {
                $std++;
                continue;
            }
            out($type . '_' . $name . "\t" . clean($pi->versiondisk ?? '') . "\t" . clean($pi->versiondb ?? '') . "\t" .
                clean($pi->release ?? '') . "\t" . clean($pi->get_status()));
        }
    }
    out("standard_plugins_count\t" . $std . "\t\t\t");
});

section('counts', function () use ($DB) {
    $now = time();
    out("users_total_not_deleted\t" . $DB->count_records('user', ['deleted' => 0]));
    foreach (['5min' => 300, '1h' => 3600, '24h' => 86400, '30d' => 2592000] as $label => $secs) {
        out("users_active_$label\t" . $DB->count_records_select('user', 'deleted = 0 AND lastaccess > ?', [$now - $secs]));
    }
    out("users_suspended\t" . $DB->count_records('user', ['deleted' => 0, 'suspended' => 1]));
    out("courses\t" . ($DB->count_records('course') - 1));
    out("user_enrolments\t" . $DB->count_records('user_enrolments'));
    out("enrol_instances_enabled\t" . $DB->count_records('enrol', ['status' => 0]));
    out("task_adhoc_rows\t" . $DB->count_records('task_adhoc'));
    // No COUNT(*) on very large tables (files, logstore): their sizes come from the DB step (40_db/tables_top.tsv).
});

section('auth_enrol', function () use ($CFG) {
    out("auth\t" . clean($CFG->auth ?? ''));
    out("enrol_plugins_enabled\t" . clean($CFG->enrol_plugins_enabled ?? ''));
    out("registerauth\t" . clean($CFG->registerauth ?? ''));
});

section('theme_identity', function () use ($CFG) {
    // Colour and font settings of the current theme (and of boost, the usual parent), for the report's look.
    $themes = array_unique(array_filter([$CFG->theme ?? '', 'boost']));
    out("theme\tsetting\tvalue");
    foreach ($themes as $th) {
        $conf = get_config('theme_' . $th);
        if (!$conf) {
            continue;
        }
        foreach ((array)$conf as $k => $v) {
            if (secretname($k) || !is_scalar($v) || strlen((string)$v) > 100) {
                continue;
            }
            if (preg_match('/colou?r|brand|primary|secondary|accent|font|navbar|header|footer|link/i', $k)) {
                out($th . "\t" . clean($k) . "\t" . clean($v));
            }
        }
    }
});
