<?php
// tasks-apply.php — apply an OWNER-APPROVED plan of scheduled-task changes (moodle-server-care, module "tuning").
// DRY RUN by default: prints current -> target for every line and changes nothing. --execute applies.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php tasks-apply.php --moodle=DIR --plan=FILE                          dry run
//   php tasks-apply.php --moodle=DIR --plan=FILE --execute --backup=FILE  save old values to FILE, then apply
//   php tasks-apply.php --moodle=DIR --restore=FILE [--execute]           put the values saved in FILE back
//
// Plan file (one action per line; "#" starts a comment; lines starting "#? " are unapproved proposals = ignored):
//   schedule CLASS MIN HOUR DAY MONTH DOW   set a schedule (validated like the admin form), marks it customised
//   reset CLASS                             back to the default schedule and default disabled flag (like the UI)
//   disable CLASS                           disable, but ONLY while the task's plugin is still disabled (else KEEP)
//   disable-anyway CLASS                    disable even though its plugin is enabled (stops a working feature!)
//   enable CLASS                            enable
//   config NAME VALUE                       cron_keepalive, task_scheduled_concurrency_limit, task_adhoc_concurrency_limit
//
// Safety: every line is validated before anything changes; one invalid line refuses the whole plan. Tasks overridden
// in config.php ($CFG->scheduled_tasks) and sites with $CFG->preventscheduledtaskchanges are refused, because the
// database value would be ignored. Changes go through core\task\manager::configure_scheduled_task (as the admin UI).
// Exit: 0 done (or dry run OK), 1 a change did not verify, 2 refused (nothing changed).

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'plan:', 'restore:', 'backup:', 'execute', 'help']);
if (isset($opts['help']) || empty($opts['moodle']) || (empty($opts['plan']) === empty($opts['restore']))) {
    fwrite(STDERR, "usage: php tasks-apply.php --moodle=DIR (--plan=FILE [--execute --backup=FILE] | --restore=FILE [--execute])\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "tasks-apply: cannot read $moodle/config.php\n");
    exit(2);
}
$execute = isset($opts['execute']);
if ($execute && !empty($opts['plan']) && empty($opts['backup'])) {
    fwrite(STDERR, "tasks-apply: --execute with --plan needs --backup=FILE (old values are saved there first)\n");
    exit(2);
}
if (!empty($opts['backup']) && file_exists($opts['backup'])) {
    fwrite(STDERR, "tasks-apply: backup file {$opts['backup']} already exists; choose a new name\n");
    exit(2);
}
require("$moodle/config.php");

use core\task\manager;

const MSC_CONFIG_ALLOWED = [
    'cron_keepalive' => [0, 900],
    'task_scheduled_concurrency_limit' => [1, 100],
    'task_adhoc_concurrency_limit' => [1, 100],
];
const MSC_FIELDS = ['minute', 'hour', 'day', 'month', 'dayofweek'];

function msc_canon(string $c): string {
    return method_exists(manager::class, 'get_canonical_class_name')
        ? manager::get_canonical_class_name($c) : '\\' . ltrim($c, '\\');
}
function msc_state($t): array {
    return ['minute' => (string)$t->get_minute(), 'hour' => (string)$t->get_hour(), 'day' => (string)$t->get_day(),
        'month' => (string)$t->get_month(), 'dayofweek' => (string)$t->get_day_of_week(),
        'disabled' => (int)$t->get_disabled(), 'customised' => (int)$t->is_customised()];
}
function msc_fmt(array $s): string {
    return implode(' ', [$s['minute'], $s['hour'], $s['day'], $s['month'], $s['dayofweek']]) .
        ($s['disabled'] ? ' [disabled]' : ' [enabled]');
}
function msc_db_state(string $class): ?array {
    global $DB;
    $r = $DB->get_record('task_scheduled', ['classname' => $class]);
    if (!$r) {
        $r = $DB->get_record('task_scheduled', ['classname' => ltrim($class, '\\')]);
    }
    if (!$r) {
        return null;
    }
    return ['minute' => (string)$r->minute, 'hour' => (string)$r->hour, 'day' => (string)$r->day,
        'month' => (string)$r->month, 'dayofweek' => (string)$r->dayofweek, 'disabled' => (int)$r->disabled,
        'customised' => (int)$r->customised];
}
function msc_plugin_disabled($t): bool {
    // Same test as core\task\manager::get_next_scheduled_task().
    $info = core_plugin_manager::instance()->get_plugin_info($t->get_component());
    return $info && $info->is_enabled() === false && !$t->get_run_if_component_disabled();
}
function msc_valid_schedule(array $f): bool {
    if (class_exists('\tool_task\scheduled_checker_task')) {
        $c = new \tool_task\scheduled_checker_task();
        $c->set_minute($f[0]);
        $c->set_hour($f[1]);
        $c->set_day($f[2]);
        $c->set_month($f[3]);
        $c->set_day_of_week($f[4]);
        if (method_exists($c, 'is_valid')) {
            foreach (['minute', 'hour', 'day', 'month', 'dayofweek'] as $field) {
                if (!$c->is_valid($field)) {
                    return false;
                }
            }
            return true;
        }
    }
    foreach ($f as $v) {   // fallback for old versions: crontab characters only
        if (!preg_match('~^[0-9*,/R-]+$~', $v)) {
            return false;
        }
    }
    return true;
}
function msc_task_refusal(string $class) {
    global $CFG;
    $t = manager::get_scheduled_task($class);
    if (!$t) {
        return [null, "no scheduled task $class on this site"];
    }
    if (method_exists(manager::class, 'scheduled_task_has_override') && manager::scheduled_task_has_override($class)) {
        return [null, "$class is overridden in config.php (\$CFG->scheduled_tasks); change it there, not here"];
    }
    return [$t, null];
}

$errors = [];
$items = [];   // each: ['kind' => task|config, ...]
if (!empty($CFG->preventscheduledtaskchanges)) {
    $errors[] = '$CFG->preventscheduledtaskchanges is set in config.php: scheduled tasks cannot be changed here';
}

if (!empty($opts['plan'])) {
    $lines = @file($opts['plan'], FILE_IGNORE_NEW_LINES);
    if ($lines === false) {
        fwrite(STDERR, "tasks-apply: cannot read plan {$opts['plan']}\n");
        exit(2);
    }
    $seen = [];
    foreach ($lines as $no => $raw) {
        $line = trim(preg_replace('/(^|\s)#.*$/', '', $raw));
        if ($line === '') {
            continue;
        }
        $tok = preg_split('/\s+/', $line);
        $act = strtolower($tok[0]);
        $where = 'line ' . ($no + 1);
        if ($act === 'config') {
            if (count($tok) !== 3 || !isset(MSC_CONFIG_ALLOWED[$tok[1]])) {
                $errors[] = "$where: config needs NAME VALUE with NAME one of " . implode(', ', array_keys(MSC_CONFIG_ALLOWED));
                continue;
            }
            [$lo, $hi] = MSC_CONFIG_ALLOWED[$tok[1]];
            if (!ctype_digit($tok[2]) || (int)$tok[2] < $lo || (int)$tok[2] > $hi) {
                $errors[] = "$where: {$tok[1]} must be an integer $lo-$hi";
                continue;
            }
            if (array_key_exists($tok[1], $CFG->config_php_settings ?? [])) {
                $errors[] = "$where: {$tok[1]} is forced in config.php; change it there";
                continue;
            }
            $items[] = ['kind' => 'config', 'name' => $tok[1], 'value' => $tok[2], 'where' => $where];
            continue;
        }
        if (!in_array($act, ['schedule', 'reset', 'disable', 'disable-anyway', 'enable'], true) || count($tok) < 2) {
            $errors[] = "$where: unknown or incomplete action '$line'";
            continue;
        }
        $class = msc_canon($tok[1]);
        if (isset($seen[$class])) {
            $errors[] = "$where: $class already appears on {$seen[$class]}; one action per task";
            continue;
        }
        $seen[$class] = $where;
        [$t, $why] = msc_task_refusal($class);
        if ($why) {
            $errors[] = "$where: $why";
            continue;
        }
        $item = ['kind' => 'task', 'action' => $act, 'class' => $class, 'where' => $where];
        if ($act === 'schedule') {
            $f = array_slice($tok, 2);
            if (count($f) !== 5 || !msc_valid_schedule($f)) {
                $errors[] = "$where: schedule needs 5 valid crontab fields (MIN HOUR DAY MONTH DOW), got '" . implode(' ', $f) . "'";
                continue;
            }
            $item['fields'] = $f;
        } else if (count($tok) !== 2) {
            $errors[] = "$where: '$act' takes only the class name";
            continue;
        }
        $items[] = $item;
    }
} else {
    $json = @file_get_contents($opts['restore']);
    $backup = $json === false ? null : json_decode($json, true);
    if (!is_array($backup) || !isset($backup['tasks'], $backup['config'])) {
        fwrite(STDERR, "tasks-apply: {$opts['restore']} is not a backup written by this script\n");
        exit(2);
    }
    if (!empty($backup['wwwroot']) && $backup['wwwroot'] !== $CFG->wwwroot) {
        $errors[] = "backup belongs to {$backup['wwwroot']}, this site is {$CFG->wwwroot}";
    }
    foreach ($backup['tasks'] as $i => $s) {
        $class = msc_canon((string)($s['classname'] ?? ''));
        [$t, $why] = msc_task_refusal($class);
        if ($why) {
            $errors[] = "backup task $i: $why";
            continue;
        }
        $items[] = ['kind' => 'task', 'action' => 'restore', 'class' => $class, 'saved' => $s, 'where' => "task $i"];
    }
    foreach ($backup['config'] as $c) {
        if (!isset(MSC_CONFIG_ALLOWED[$c['name'] ?? ''])) {
            $errors[] = 'backup config entry not allowed: ' . ($c['name'] ?? '?');
            continue;
        }
        $items[] = ['kind' => 'config', 'name' => $c['name'], 'value' => $c['value'], 'where' => 'config'];
    }
}

if ($errors) {
    echo "REFUSED: nothing was changed\n  " . implode("\n  ", $errors) . "\n";
    exit(2);
}
if (!$items) {
    echo "nothing to do: the plan has no approved lines (proposals start with '#? ')\n";
    exit(0);
}

// Work out the target state of every item.
$planned = [];
foreach ($items as $it) {
    if ($it['kind'] === 'config') {
        $cur = get_config('core', $it['name']);
        $cur = $cur === false ? null : (string)$cur;
        $it['current'] = $cur;
        $it['status'] = ($cur === (is_null($it['value']) ? null : (string)$it['value'])) ? 'SAME' : 'CHANGE';
        $planned[] = $it;
        continue;
    }
    $t = manager::get_scheduled_task($it['class']);
    $cur = msc_state($t);
    $target = $cur;
    $note = '';
    $pattern = null;   // schedule/reset: wanted fields, where "R" (random) accepts any current value
    switch ($it['action']) {
        case 'schedule':
            $tmp = clone $t;   // expand "R" exactly once, here, so dry run and execute show the same values
            $tmp->set_minute($it['fields'][0]);
            $tmp->set_hour($it['fields'][1]);
            $tmp->set_day($it['fields'][2]);
            $tmp->set_month($it['fields'][3]);
            $tmp->set_day_of_week($it['fields'][4]);
            $target = array_merge(msc_state($tmp), ['disabled' => $cur['disabled'], 'customised' => 1]);
            $pattern = $it['fields'];
            break;
        case 'reset':
            $def = manager::get_default_scheduled_task($it['class']);
            if (!$def) {
                echo "REFUSED: no default schedule found for {$it['class']}; nothing was changed\n";
                exit(2);
            }
            $target = array_merge(msc_state($def), ['customised' => 0]);
            $raw = manager::get_default_scheduled_task($it['class'], false);
            $pattern = $raw ? [$raw->get_minute(), $raw->get_hour(), $raw->get_day(), $raw->get_month(), $raw->get_day_of_week()] : null;
            break;
        case 'disable':
            if (!msc_plugin_disabled($t)) {
                $it['status'] = 'KEEP';
                $note = 'its plugin is enabled now; use disable-anyway only with the owner\'s explicit approval';
            }
            $target['disabled'] = 1;
            $target['customised'] = 1;
            break;
        case 'disable-anyway':
            $target['disabled'] = 1;
            $target['customised'] = 1;
            break;
        case 'enable':
            $target['disabled'] = 0;
            $target['customised'] = 1;
            break;
        case 'restore':
            $s = $it['saved'];
            foreach (array_merge(MSC_FIELDS, ['disabled', 'customised']) as $k) {
                if (!array_key_exists($k, $s)) {
                    echo "REFUSED: backup entry for {$it['class']} lacks '$k'; nothing was changed\n";
                    exit(2);
                }
                $target[$k] = in_array($k, ['disabled', 'customised'], true) ? (int)$s[$k] : (string)$s[$k];
            }
            break;
    }
    $it['current'] = $cur;
    $it['target'] = $target;
    if (!isset($it['status'])) {
        $same = true;
        $keys = array_merge(MSC_FIELDS, ['disabled'], in_array($it['action'], ['reset', 'restore'], true) ? ['customised'] : []);
        foreach ($keys as $i => $k) {
            if ($pattern !== null && $i < 5 && strpos((string)$pattern[$i], 'R') !== false) {
                continue;   // re-running a plan must not re-roll a random minute or hour
            }
            $same = $same && ((string)$cur[$k] === (string)$target[$k]);
        }
        $it['status'] = $same ? 'SAME' : 'CHANGE';
        if ($same) {
            $it['target'] = $cur;
        }
    }
    $it['note'] = $note;
    $planned[] = $it;
}

echo ($execute ? 'EXECUTE' : 'DRY RUN') . ' ' . date('Y-m-d H:i:s T') . ' on ' . $CFG->wwwroot . "\n";
$n = ['CHANGE' => 0, 'SAME' => 0, 'KEEP' => 0];
foreach ($planned as $it) {
    $n[$it['status']]++;
    if ($it['kind'] === 'config') {
        printf("%-6s config %s: %s -> %s\n", $it['status'], $it['name'], $it['current'] ?? '(unset)', $it['value'] ?? '(unset)');
    } else {
        printf("%-6s %-14s %s: %s -> %s%s\n", $it['status'], $it['action'], $it['class'], msc_fmt($it['current']),
            msc_fmt($it['target']), $it['note'] ? "  ($it[note])" : '');
    }
}
printf("summary: %d to change, %d already as wanted, %d kept (plugin enabled)\n", $n['CHANGE'], $n['SAME'], $n['KEEP']);
if (!$execute) {
    echo "dry run: nothing was changed (add --execute" . (!empty($opts['plan']) ? ' --backup=FILE' : '') . ")\n";
    exit(0);
}
if ($n['CHANGE'] === 0) {
    echo "nothing to change\n";
    exit(0);
}

// Save the old values before touching anything.
if (!empty($opts['plan'])) {
    $save = ['written' => date('c'), 'wwwroot' => $CFG->wwwroot, 'release' => $CFG->release ?? '', 'tasks' => [], 'config' => []];
    foreach ($planned as $it) {
        if ($it['status'] !== 'CHANGE') {
            continue;
        }
        if ($it['kind'] === 'config') {
            $save['config'][] = ['name' => $it['name'], 'value' => $it['current']];
        } else {
            $save['tasks'][] = array_merge(['classname' => $it['class']], msc_db_state($it['class']) ?? $it['current']);
        }
    }
    $old = umask(077);
    $ok = @file_put_contents($opts['backup'], json_encode($save, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    umask($old);
    if ($ok === false) {
        echo "REFUSED: could not write the backup {$opts['backup']}; nothing was changed\n";
        exit(2);
    }
    echo "old values saved: {$opts['backup']} (restore with --restore=FILE --execute)\n";
}

$bad = 0;
foreach ($planned as $it) {
    if ($it['status'] !== 'CHANGE') {
        continue;
    }
    try {
        if ($it['kind'] === 'config') {
            if (is_null($it['value'])) {
                unset_config($it['name']);
            } else {
                set_config($it['name'], $it['value']);
            }
            $now = get_config('core', $it['name']);
            $ok = is_null($it['value']) ? ($now === false) : ((string)$now === (string)$it['value']);
            printf("%s config %s = %s\n", $ok ? 'done  ' : 'FAILED', $it['name'], $now === false ? '(unset)' : $now);
            $bad += $ok ? 0 : 1;
            continue;
        }
        $t = manager::get_scheduled_task($it['class']);
        $g = $it['target'];
        $t->set_minute($g['minute']);
        $t->set_hour($g['hour']);
        $t->set_day($g['day']);
        $t->set_month($g['month']);
        $t->set_day_of_week($g['dayofweek']);
        $t->set_disabled((bool)$g['disabled']);
        $t->set_customised((bool)$g['customised']);
        manager::configure_scheduled_task($t);
        $after = msc_db_state($it['class']);
        $ok = $after !== null;
        foreach (array_merge(MSC_FIELDS, ['disabled']) as $k) {
            $ok = $ok && ((string)$after[$k] === (string)$g[$k]);
        }
        printf("%s %s: now %s\n", $ok ? 'done  ' : 'FAILED', $it['class'], $after ? msc_fmt($after) : '(missing)');
        $bad += $ok ? 0 : 1;
    } catch (Throwable $e) {
        printf("FAILED %s: %s\n", $it['class'] ?? $it['name'], $e->getMessage());
        $bad++;
    }
}
echo $bad ? "EXECUTED with $bad failure(s): check the lines above; restore from the backup if needed\n" : "EXECUTED\n";
exit($bad ? 1 : 0);
