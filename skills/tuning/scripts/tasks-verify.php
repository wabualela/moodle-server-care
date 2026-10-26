<?php
// tasks-verify.php — READ-ONLY check after tasks-apply.php (moodle-server-care, module "tuning").
//
// Prints, for every approved line of the plan, the state now in the database and OK/DIFF; the enabled tasks that
// stay due (with --wait, two readings and only tasks due in both count, because busy cron runners can delay a task
// by more than 5 minutes once); tasks in fail delay; and how long ago cron last started.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php tasks-verify.php --moodle=DIR [--plan=FILE] [--wait=600]
// Exit: 0 all plan lines as wanted and no enabled task permanently due of a disabled plugin; 1 otherwise.

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'plan:', 'wait:', 'help']);
if (isset($opts['help']) || empty($opts['moodle'])) {
    fwrite(STDERR, "usage: php tasks-verify.php --moodle=DIR [--plan=FILE] [--wait=SECONDS]\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "tasks-verify: cannot read $moodle/config.php\n");
    exit(2);
}
$wait = isset($opts['wait']) ? max(0, (int)$opts['wait']) : 0;
require("$moodle/config.php");

use core\task\manager;

function msc_canon(string $c): string {
    return method_exists(manager::class, 'get_canonical_class_name')
        ? manager::get_canonical_class_name($c) : '\\' . ltrim($c, '\\');
}
function msc_row(string $class) {
    global $DB;
    return $DB->get_record('task_scheduled', ['classname' => $class])
        ?: $DB->get_record('task_scheduled', ['classname' => ltrim($class, '\\')]);
}
function msc_due(): array {
    global $DB;
    $out = [];
    foreach ($DB->get_records_select('task_scheduled', 'disabled = 0 AND (nextruntime IS NULL OR nextruntime < ?)',
            [time() - 300], 'classname', 'id, classname') as $r) {
        $out[msc_canon($r->classname)] = true;
    }
    return $out;
}

$fail = 0;
echo '== scheduled tasks verify (read-only) ' . date('Y-m-d H:i:s T') . ' on ' . $CFG->wwwroot . " ==\n";

if (!empty($opts['plan'])) {
    $lines = @file($opts['plan'], FILE_IGNORE_NEW_LINES);
    if ($lines === false) {
        fwrite(STDERR, "tasks-verify: cannot read plan {$opts['plan']}\n");
        exit(2);
    }
    foreach ($lines as $raw) {
        $line = trim(preg_replace('/(^|\s)#.*$/', '', $raw));
        if ($line === '') {
            continue;
        }
        $tok = preg_split('/\s+/', $line);
        $act = strtolower($tok[0]);
        if ($act === 'config' && count($tok) === 3) {
            $v = get_config('core', $tok[1]);
            $ok = (string)$v === $tok[2];
            printf("%-4s config %s = %s (wanted %s)\n", $ok ? 'OK' : 'DIFF', $tok[1], $v === false ? '(unset)' : $v, $tok[2]);
            $fail += $ok ? 0 : 1;
            continue;
        }
        if (count($tok) < 2) {
            echo "skip unreadable line: $line\n";
            continue;
        }
        $class = msc_canon($tok[1]);
        $r = msc_row($class);
        if (!$r) {
            echo "DIFF $class: no such task\n";
            $fail++;
            continue;
        }
        $now = "$r->minute $r->hour $r->day $r->month $r->dayofweek";
        $next = $r->nextruntime ? date('Y-m-d H:i', (int)$r->nextruntime) : '-';
        switch ($act) {
            case 'schedule':
                $want = implode(' ', array_slice($tok, 2, 5));
                // "R" fields are expanded when applied, so compare only the fields that are not "R".
                $ok = true;
                $w = array_slice($tok, 2, 5);
                $h = explode(' ', $now);
                foreach ($w as $i => $f) {
                    $ok = $ok && (strpos($f, 'R') !== false || $f === ($h[$i] ?? null));
                }
                $ok = $ok && !$r->disabled;
                break;
            case 'reset':
                $def = manager::get_default_scheduled_task($class, false);
                $want = $def ? implode(' ', [$def->get_minute(), $def->get_hour(), $def->get_day(), $def->get_month(),
                    $def->get_day_of_week()]) . ' (default)' : 'default';
                $ok = !$r->customised;
                break;
            case 'disable':
            case 'disable-anyway':
                $want = 'disabled';
                $ok = (bool)$r->disabled;
                break;
            case 'enable':
                $want = 'enabled';
                $ok = !$r->disabled;
                break;
            default:
                echo "skip unknown action: $line\n";
                continue 2;
        }
        printf("%-4s %-14s %-60s now %-16s %s next %s (wanted %s)\n", $ok ? 'OK' : 'DIFF', $act, $class, $now,
            $r->disabled ? 'disabled' : 'enabled ', $next, $want);
        if (!$ok && $act === 'disable') {
            $t = manager::get_scheduled_task($class);
            $info = $t ? core_plugin_manager::instance()->get_plugin_info($t->get_component()) : null;
            if ($info && $info->is_enabled() !== false) {
                echo "     (its plugin is enabled, so tasks-apply kept it: expected if apply printed KEEP)\n";
                continue;
            }
        }
        $fail += $ok ? 0 : 1;
    }
}

$first = msc_due();
if ($wait > 0) {
    echo "\nfirst reading: " . count($first) . " enabled task(s) due for > 5 min; waiting {$wait} s for the second reading...\n";
    sleep($wait);
    $second = msc_due();
    $due = array_intersect_key($first, $second);
    echo 'second reading: ' . count($second) . "; due in both readings (permanently due): " . count($due) . "\n";
} else {
    $due = $first;
    echo "\nenabled tasks due for > 5 min (single reading; use --wait=600 to confirm): " . count($due) . "\n";
}
$deadplugins = 0;
foreach (array_keys($due) as $class) {
    $t = manager::get_scheduled_task($class);
    $info = $t ? core_plugin_manager::instance()->get_plugin_info($t->get_component()) : null;
    $dead = $t && $info && $info->is_enabled() === false && !$t->get_run_if_component_disabled();
    $deadplugins += $dead ? 1 : 0;
    printf("  %-62s %s\n", $class, $dead ? 'plugin disabled: cron locks and skips it every poll' : 'plugin enabled: slow or blocked task?');
}
if ($deadplugins) {
    $fail++;
}

$failing = $DB->get_records_select('task_scheduled', 'faildelay > 0', null, 'classname', 'id, classname, faildelay');
echo "\ntasks in fail delay: " . count($failing) . "\n";
foreach ($failing as $r) {
    printf("  %-62s faildelay %d s\n", msc_canon($r->classname), $r->faildelay);
}
$last = get_config('tool_task', 'lastcronstart');
if ($last) {
    $age = time() - (int)$last;
    echo 'last cron start: ' . date('H:i:s', (int)$last) . " ($age s ago)" . ($age > 300 ? '  WARNING: cron may not be running' : '') . "\n";
}
foreach (['cron_keepalive', 'task_scheduled_concurrency_limit', 'task_adhoc_concurrency_limit'] as $n) {
    $v = get_config('core', $n);
    echo "$n=" . ($v === false ? 'default' : $v) . "\n";
}
echo $fail ? "RESULT: $fail item(s) need attention\n" : "RESULT: OK\n";
exit($fail ? 1 : 0);
