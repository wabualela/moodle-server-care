<?php
// tasks-review.php — READ-ONLY review of Moodle scheduled tasks (moodle-server-care, module "tuning").
//
// Lists what makes cron expensive without doing useful work:
//   A. enabled tasks whose plugin is disabled: cron takes a DB lock for each one on every poll, then skips it
//      without advancing its next run time, so it stays "due" forever (core\task\manager::get_next_scheduled_task);
//   B. tasks that run every minute, with the known cheaper schedules for some core ones;
//   C. tasks customised away from their default schedule;
//   D. enabled tasks that look permanently due (run tasks-verify.php --wait=600 to confirm);
//   E. the heaviest and the failing tasks of the last 24 h from the task log, and the cron settings.
// With --plan-out it writes a DRAFT plan for tasks-apply.php in which every proposal is commented out with "#? ";
// nothing is applied until a line the owner approved is un-commented.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php tasks-review.php --moodle=DIR [--plan-out=FILE] [--quiet-hour=H] [--all]
//     --moodle      Moodle code root (the directory with config.php)
//     --plan-out    write a draft plan there (directory must be writable by the web user, e.g. /tmp)
//     --quiet-hour  hour 0-23 for daily schedules in the draft (default 1; use the measured quiet hours)
//     --all         also print every scheduled task
// It never writes to the database and prints no personal data.

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'plan-out:', 'quiet-hour:', 'all', 'help']);
if (isset($opts['help']) || empty($opts['moodle'])) {
    fwrite(STDERR, "usage: php tasks-review.php --moodle=DIR [--plan-out=FILE] [--quiet-hour=H] [--all]\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "tasks-review: cannot read $moodle/config.php\n");
    exit(2);
}
$quiethour = isset($opts['quiet-hour']) ? (int)$opts['quiet-hour'] : 1;
if ($quiethour < 0 || $quiethour > 23) {
    fwrite(STDERR, "tasks-review: --quiet-hour must be 0-23\n");
    exit(2);
}
require("$moodle/config.php");

use core\task\manager;

// Core tasks we know cheaper schedules for (first-server evidence, generalised). Keys are canonical class names.
$known = [
    '\core\task\question_preview_cleanup_task' => [
        'propose' => 'daily', 'why' => 'deletes question previews older than a day; once a day is enough '
            . '(first server: a large share of DB time while deleting nothing)'],
    '\enrol_cohort\task\enrol_cohort_sync' => [
        'propose' => '*/15', 'why' => 'safety net only: cohort events enrol users immediately; default is hourly (R * * * *)'],
    '\enrol_meta\task\enrol_meta_sync' => [
        'propose' => '*/15', 'why' => 'safety net only: enrolment and role events sync meta links immediately; default hourly'],
    '\core\task\completion_regular_task' => [
        'propose' => '*/5', 'why' => 'course completion aggregation waits up to 5 min (activity ticks stay instant); '
            . 'needs business sign-off'],
];

$canon = function (string $c): string {
    return method_exists(manager::class, 'get_canonical_class_name')
        ? manager::get_canonical_class_name($c) : '\\' . ltrim($c, '\\');
};
$sched = function ($t): string {
    return implode(' ', [$t->get_minute(), $t->get_hour(), $t->get_day(), $t->get_month(), $t->get_day_of_week()]);
};
$everyminute = function (string $s): bool {
    return in_array($s, ['* * * * *', '*/1 * * * *'], true);
};
$ago = function ($ts): string {
    if (empty($ts)) {
        return 'never';
    }
    $d = time() - (int)$ts;
    if ($d < 0) {
        return 'in ' . round(-$d / 60) . ' min';
    }
    if ($d < 3600) {
        return round($d / 60) . ' min ago';
    }
    if ($d < 172800) {
        return round($d / 3600, 1) . ' h ago';
    }
    return round($d / 86400) . ' d ago';
};
$pm = core_plugin_manager::instance();
$pluginstate = function (string $component) use ($pm): string {
    if (strpos($component, 'core') === 0) {
        return 'core';
    }
    $info = $pm->get_plugin_info($component);
    if (!$info) {
        return 'missing';
    }
    $e = $info->is_enabled();
    return $e === false ? 'DISABLED' : ($e === true ? 'enabled' : 'n/a');
};

echo "== scheduled tasks review (read-only) " . date('Y-m-d H:i:s T') . " ==\n";
echo "moodle release: " . ($CFG->release ?? '?') . "\n";
$cfgline = [];
foreach (['cron_enabled', 'cron_keepalive', 'task_scheduled_concurrency_limit', 'task_adhoc_concurrency_limit',
        'task_scheduled_max_runtime', 'task_adhoc_max_runtime', 'task_logmode', 'task_logretention'] as $n) {
    $v = get_config('core', $n);
    $forced = array_key_exists($n, $CFG->config_php_settings ?? []) ? ' (forced in config.php)' : '';
    $cfgline[] = "$n=" . ($v === false ? 'default' : $v) . $forced;
}
echo implode("\n", $cfgline) . "\n";
echo 'preventscheduledtaskchanges=' . (empty($CFG->preventscheduledtaskchanges) ? 'no' : 'YES (tasks-apply will refuse)') . "\n";
echo 'config.php task overrides ($CFG->scheduled_tasks): ' . (isset($CFG->scheduled_tasks) ? count($CFG->scheduled_tasks) : 0) . "\n";
$lastcron = get_config('tool_task', 'lastcronstart');
echo 'last cron start: ' . ($lastcron ? date('Y-m-d H:i:s', (int)$lastcron) . ' (' . $ago($lastcron) . ')' : 'unknown') . "\n";
$keepalive = get_config('core', 'cron_keepalive');
$ka = $keepalive === false ? 180 : (int)$keepalive;
echo "note: cron.php is started every minute and stays alive cron_keepalive seconds, so about " . max(1, intdiv($ka, 60)) .
    '-' . (intdiv($ka, 60) + 1) . " runners overlap" . ($keepalive === false ? ' (default 180 s)' : '') .
    "; check with: pgrep -fc 'admin/cli/cron.php'\n";

$tasks = manager::get_all_scheduled_tasks();
$byclass = [];
$counts = ['total' => 0, 'enabled' => 0, 'everyminute' => 0, 'customised' => 0, 'disabled' => 0, 'overridden' => 0];
$dead = [];
$minute = [];
$custom = [];
foreach ($tasks as $t) {
    $class = $canon(get_class($t));
    $byclass[$class] = $t;
    $counts['total']++;
    $s = $sched($t);
    $overridden = method_exists($t, 'is_overridden') ? $t->is_overridden() : false;
    if ($overridden) {
        $counts['overridden']++;
    }
    if ($t->get_disabled()) {
        $counts['disabled']++;
        continue;
    }
    $counts['enabled']++;
    if ($t->is_customised()) {
        $counts['customised']++;
    }
    $comp = $t->get_component();
    $state = $pluginstate($comp);
    // Same test as core\task\manager::get_next_scheduled_task(): plugin info exists, is_enabled() === false,
    // and the task does not ask to run while its plugin is disabled.
    if ($state === 'DISABLED' && !$t->get_run_if_component_disabled()) {
        $dead[$class] = $t;
        continue;
    }
    if ($everyminute($s)) {
        $counts['everyminute']++;
        $minute[$class] = $t;
    }
    if ($t->is_customised()) {
        $def = manager::get_default_scheduled_task($class, false);
        $defs = $def ? $sched($def) : '?';
        if ($defs !== $s) {
            $custom[$class] = [$s, $defs];
        }
    }
}
printf("tasks: %d total, %d enabled, %d disabled, %d customised (enabled), %d overridden in config.php, %d enabled every minute\n",
    $counts['total'], $counts['enabled'], $counts['disabled'], $counts['customised'], $counts['overridden'],
    $counts['everyminute']);

echo "\n-- A. enabled tasks whose plugin is disabled (" . count($dead) . "): they never run; most cost a DB lock on every poll --\n";
// Cost depends on the stored next run time: once it has passed, cron skips the task after taking its lock and never
// advances it, so it stays due forever; a task whose next run time is the "never" sentinel costs nothing.
$cost = function ($t): string {
    $next = (int)$t->get_next_run_time();
    if ($next === 0 || $next < time()) {
        return 'DUE NOW: locked and skipped on every poll';
    }
    if ($next >= 7952342400 - 86400) {   // \core\task\scheduled_task::NEVER_RUN_TIME (year 2222)
        return 'never due: no cost now (hygiene only)';
    }
    return 'due ' . date('Y-m-d H:i', $next) . ': from then on locked every poll';
};
foreach ($dead as $class => $t) {
    $ov = (method_exists($t, 'is_overridden') && $t->is_overridden()) ? '  OVERRIDDEN in config.php: change it there' : '';
    printf("  %-62s %-26s %s%s\n", $class, $t->get_component(), $cost($t), $ov);
}
if ($dead) {
    echo "  -> propose: disable these tasks (re-checked at apply time; if the plugin is enabled later, enable its task again)\n";
}

echo "\n-- B. enabled tasks running every minute (" . count($minute) . ") --\n";
foreach ($minute as $class => $t) {
    $def = manager::get_default_scheduled_task($class, false);
    $defs = $def ? $sched($def) : '?';
    $hint = isset($known[$class]) ? '  <- known: ' . $known[$class]['propose'] . '; ' . $known[$class]['why'] : '';
    printf("  %-62s default %-14s %s%s\n", $class, $defs, $t->is_customised() ? 'customised' : '', $hint);
}

echo "\n-- C. enabled tasks customised away from their default (" . count($custom) . ") --\n";
foreach ($custom as $class => [$s, $defs]) {
    printf("  %-62s now %-16s default %s\n", $class, $s, $defs);
}

echo "\n-- D. enabled tasks due for more than 5 min (one reading; confirm with tasks-verify.php --wait=600) --\n";
$due = $DB->get_records_select('task_scheduled', 'disabled = 0 AND (nextruntime IS NULL OR nextruntime < ?)',
    [time() - 300], 'classname', 'id, classname, nextruntime, lastruntime');
foreach ($due as $r) {
    $c = $canon($r->classname);
    printf("  %-62s next %-12s last %s%s\n", $c, $ago($r->nextruntime), $ago($r->lastruntime),
        isset($dead[$c]) ? '  (plugin disabled: see A)' : '');
}
echo '  count: ' . count($due) . "\n";

echo "\n-- E. task log, last 24 h (scheduled tasks) --\n";
$dbman = $DB->get_manager();
if ($dbman->table_exists('task_log')) {
    $since = time() - 86400;
    $sql = "SELECT classname, COUNT(1) AS runs, SUM(COALESCE(timeend, timestart) - timestart) AS secs,
                   MAX(COALESCE(timeend, timestart) - timestart) AS maxsecs, SUM(dbreads) AS dbreads,
                   SUM(dbwrites) AS dbwrites, SUM(result) AS fails
              FROM {task_log}
             WHERE type = 0 AND timestart > ?
          GROUP BY classname
          ORDER BY secs DESC";
    $rows = $DB->get_records_sql($sql, [$since], 0, 15);
    $logmode = get_config('core', 'task_logmode');
    if ((string)$logmode === '2') {
        echo "  task_logmode=2: only FAILED runs are logged, so the times below are failures only\n";
    }
    if (!$rows) {
        echo "  no scheduled-task log rows in the last 24 h\n";
    } else {
        printf("  %-62s %6s %9s %8s %11s %9s %5s\n", 'task (top 15 by total time)', 'runs', 'total s', 'max s',
            'db reads', 'db writes', 'fail');
        foreach ($rows as $r) {
            printf("  %-62s %6d %9.1f %8.1f %11d %9d %5d\n", $canon($r->classname), $r->runs, $r->secs, $r->maxsecs,
                $r->dbreads, $r->dbwrites, $r->fails);
        }
    }
    $failing = $DB->get_records_select('task_scheduled', 'faildelay > 0', null, 'classname', 'id, classname, faildelay');
    echo '  tasks currently in fail delay: ' . count($failing) . "\n";
    foreach ($failing as $r) {
        printf("    %-62s faildelay %d s\n", $canon($r->classname), $r->faildelay);
    }
} else {
    echo "  no task_log table on this version\n";
}

if (isset($opts['all'])) {
    echo "\n-- all scheduled tasks --\n";
    foreach ($byclass as $class => $t) {
        printf("  %-62s %-16s %-9s %s%s\n", $class, $sched($t), $t->get_disabled() ? 'disabled' : 'enabled',
            $pluginstate($t->get_component()), $t->is_customised() ? ' customised' : '');
    }
}

if (!empty($opts['plan-out'])) {
    $quietminutes = [7, 13, 17, 23, 37, 43, 47, 53];   // avoids :00/:15/:30/:45 where other tasks pile up
    $m = $quietminutes[random_int(0, count($quietminutes) - 1)];
    $out = [];
    $out[] = '# DRAFT plan for tasks-apply.php, written by tasks-review.php on ' . date('Y-m-d H:i') . ' for ' . $CFG->wwwroot;
    $out[] = '# Every proposal starts with "#? " and is IGNORED. After the owner approves a line, remove its "#? ".';
    $out[] = '# Actions: schedule CLASS MIN HOUR DAY MONTH DOW | reset CLASS | disable CLASS (only while its plugin is';
    $out[] = '#          disabled) | disable-anyway CLASS | enable CLASS | config NAME VALUE (cron_keepalive and the two';
    $out[] = '#          task_*_concurrency_limit settings only)';
    $out[] = '';
    if ($dead) {
        $out[] = '# A. enabled tasks of disabled plugins (cron takes a lock for each on every poll)';
        foreach ($dead as $class => $t) {
            if (method_exists($t, 'is_overridden') && $t->is_overridden()) {
                $out[] = "# $class is overridden in config.php (\$CFG->scheduled_tasks): change it there, not in this plan";
                continue;
            }
            $out[] = "#? disable $class   # " . $cost($t);
        }
        $out[] = '';
    }
    $b = [];
    foreach ($known as $class => $k) {
        if (!isset($minute[$class])) {
            continue;
        }
        $b[] = '# ' . $class . ': ' . $k['why'];
        if ($k['propose'] === 'daily') {
            $b[] = "#? schedule $class $m $quiethour * * *";
        } else if ($k['propose'] === '*/15') {
            $b[] = "#? schedule $class */15 * * * *";
            $b[] = "#  (alternative: #? reset $class   -> back to the default, usually hourly)";
        } else {
            $b[] = "#? schedule $class " . $k['propose'] . ' * * * *';
        }
    }
    if ($b) {
        $out[] = '# B. every-minute core tasks with a known cheaper schedule';
        $out = array_merge($out, $b, ['']);
    }
    if ($keepalive !== false && (int)$keepalive > 120) {
        $out[] = "# cron_keepalive is $keepalive s: about " . intdiv((int)$keepalive, 60) . '-' . (intdiv((int)$keepalive, 60) + 1) . ' cron runners overlap and compete';
        $out[] = '# for the same locks. 120 leaves about 2. Check pgrep -fc admin/cli/cron.php first.';
        $out[] = '#? config cron_keepalive 120';
        $out[] = '';
    }
    $out[] = '# Other every-minute tasks are listed in section B of the review output; add lines only with the owner.';
    // Moodle sets the umask from $CFG->directorypermissions (0000 with the default 02777), so the file would be
    // created 0666 and stay writable by every account for a moment. Create it private, then open it for reading.
    // A symbolic link at that path (planted in /tmp by another account) is refused, not followed.
    if (is_link($opts['plan-out'])) {
        fwrite(STDERR, "tasks-review: {$opts['plan-out']} is a symbolic link; refusing to write through it\n");
        exit(1);
    }
    $oldumask = umask(077);
    $written = @file_put_contents($opts['plan-out'], implode("\n", $out) . "\n");
    umask($oldumask);
    if ($written === false) {
        fwrite(STDERR, "tasks-review: could not write {$opts['plan-out']}\n");
        exit(1);
    }
    // readable by the operator, writable only by the web user
    @chmod($opts['plan-out'], 0644);
    echo "\ndraft plan written: {$opts['plan-out']} (all proposals commented out with '#? ')\n";
}
echo "\nread-only: nothing was changed\n";
