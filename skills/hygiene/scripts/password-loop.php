#!/usr/bin/env php
<?php
// password-loop.php — Moodle CLI: find accounts stuck in the new-user password loop and, only when asked, suspend them
// as the site administrator. Prints user IDs and categories only: never names, usernames or e-mail addresses.
//
// The loop: users with the preference create_password = 1 are picked up by \core\task\send_new_user_passwords_task
// (every minute by default). The task sets a NEW password and calls email_to_user(); the preference is cleared only
// when the mail succeeds. If email_to_user() returns false (address rejected by validate_email(), user over the bounce
// threshold, SMTP failure), the account gets a new password every run, forever: thousands of password-update events
// and user-table writes per day, and the person can never log in.
//
// Run as the web user from a world-readable copy (the web user usually cannot read the operator's home):
//   install -m 644 password-loop.php /tmp/password-loop.php
//   sudo -u <WEBUSER> <PHP> /tmp/password-loop.php --moodle=<MOODLE>                       # report (read-only)
//   sudo -u <WEBUSER> <PHP> /tmp/password-loop.php --moodle=<MOODLE> --suspend --ids=1,2   # dry run of a suspend
//   sudo -u <WEBUSER> <PHP> /tmp/password-loop.php --moodle=<MOODLE> --suspend --ids=1,2 --execute   # WRITE
//   sudo -u <WEBUSER> <PHP> /tmp/password-loop.php --moodle=<MOODLE> --verify --since=<unix time of the change>
// Works on Moodle 3.9 to 5.x (config.php sits in <MOODLE>; on 5.1+ $CFG->dirroot is <MOODLE>/public).

define('CLI_SCRIPT', true);

if (array_intersect($argv, ['--help', '-h'])) {   // help works without a Moodle bootstrap
    foreach (file(__FILE__) as $i => $l) {
        if (strpos($l, '//') === 0) { echo $l; } elseif ($i > 2) { break; }
    }
    exit(0);
}

$moodle = getenv('MOODLE') ?: '';
foreach ($argv as $a) {
    if (strpos($a, '--moodle=') === 0) { $moodle = substr($a, 9); }
}
if ($moodle === '' || !is_readable($moodle . '/config.php')) {
    fwrite(STDERR, "pass --moodle=<MOODLE> (the directory holding config.php, readable by this user)\n");
    exit(2);
}
require($moodle . '/config.php');
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->dirroot . '/user/lib.php');

[$options, $unrecognised] = cli_get_params([
    'moodle' => '', 'help' => false, 'suspend' => false, 'ids' => '', 'execute' => false,
    'verify' => false, 'since' => 0, 'force' => false,
], ['h' => 'help']);
if ($unrecognised) {
    cli_error('unknown options: ' . implode(' ', $unrecognised));
}

/** Category of an address that validate_email() rejects, without revealing the address. */
function msc_email_category(string $email): string {
    if (trim($email) === '') { return 'empty'; }
    if (preg_match('/\s/', $email)) { return 'whitespace'; }
    if (substr_count($email, '@') !== 1) { return 'at-count'; }
    [, $domain] = explode('@', $email);
    if (strpos($domain, '.') === false) { return 'domain-no-dot'; }
    if (strpos($domain, '..') !== false || $domain[0] === '.' || substr($domain, -1) === '.') { return 'domain-bad-dots'; }
    return 'other';
}

/** Count user_password_updated events since $since (null when the standard log store is off). */
function msc_events_since(int $since): ?int {
    global $DB;
    $stores = explode(',', (string)get_config('tool_log', 'enabled_stores'));
    if (!in_array('logstore_standard', $stores, true)) { return null; }
    return $DB->count_records_select('logstore_standard_log', 'eventname = :e AND timecreated > :t',
        ['e' => '\\core\\event\\user_password_updated', 't' => $since]);
}

/** All users holding create_password = 1, with whether the task picks them up (same filter as the task). */
function msc_candidates(): array {
    global $DB;
    $sql = "SELECT u.id, u.auth, u.suspended, u.deleted, u.email, u.timecreated, u.lastaccess
              FROM {user} u
              JOIN {user_preferences} p ON p.userid = u.id
             WHERE p.name = 'create_password' AND " . $DB->sql_compare_text('p.value', 2) . " = '1'
          ORDER BY u.id";
    $out = [];
    foreach ($DB->get_records_sql($sql) as $u) {
        $u->inloop = ($u->email !== '' && (int)$u->suspended === 0 && $u->auth !== 'nologin' && (int)$u->deleted === 0);
        $u->emailok = validate_email($u->email);
        $u->bounce = over_bounce_threshold($u);
        $u->category = $u->emailok ? ($u->bounce ? 'over-bounce-threshold' : 'valid (mail fails elsewhere? check SMTP)')
                                   : msc_email_category($u->email);
        $out[$u->id] = $u;
    }
    return $out;
}

function msc_task_line(): string {
    $task = \core\task\manager::get_scheduled_task('\\core\\task\\send_new_user_passwords_task');
    if (!$task) { return 'task not found'; }
    $last = $task->get_last_run_time();
    return sprintf('task send_new_user_passwords_task: %s, schedule %s %s %s %s %s, last run %s',
        $task->get_disabled() ? 'DISABLED' : 'enabled', $task->get_minute(), $task->get_hour(), $task->get_day(),
        $task->get_month(), $task->get_day_of_week(), $last ? userdate($last, '%Y-%m-%d %H:%M:%S') : 'never');
}

$cands = msc_candidates();
$loop = array_filter($cands, fn($u) => $u->inloop);

// ---------------- verify ----------------
if ($options['verify']) {
    $since = (int)$options['since'];
    if ($since <= 0) { cli_error('--verify needs --since=<unix time of the change>'); }
    $ev = msc_events_since($since);
    echo msc_task_line(), "\n";
    printf("users the task still picks up: %d\n", count($loop));
    printf("user_password_updated events since %s: %s\n", userdate($since, '%Y-%m-%d %H:%M:%S'),
        $ev === null ? 'n/a (standard log store disabled; check user.timemodified instead)' : $ev);
    exit(($ev === 0 || $ev === null) && !$loop ? 0 : 1);
}

// ---------------- suspend ----------------
if ($options['suspend']) {
    $ids = array_values(array_filter(array_map('intval', explode(',', (string)$options['ids']))));
    if (!$ids) { cli_error('--suspend needs --ids=<comma-separated user IDs from the report>'); }
    foreach ($ids as $id) {
        if (!isset($loop[$id]) && !$options['force']) {
            cli_error("user $id is not in the loop set (no create_password=1 or already excluded by the task); " .
                "refusing. Use --force only if you are sure.");
        }
        if (is_siteadmin($id)) { cli_error("user $id is a site administrator; refusing."); }
    }
    $admin = get_admin();
    if (!$admin) { cli_error('no site administrator found'); }
    if (!$options['execute']) {
        printf("DRY RUN: would suspend %d user(s) as admin id %d: %s\n", count($ids), $admin->id, implode(',', $ids));
        echo "Re-run with --execute after the owner approved it. Save this report first (IDs only) as the rollback list.\n";
        exit(0);
    }
    \core\session\manager::set_user($admin);   // events record the administrator as the actor
    $start = time();
    foreach ($ids as $id) {
        $before = $DB->get_record('user', ['id' => $id], 'id, suspended, timemodified', MUST_EXIST);
        printf("before\t%d\tsuspended=%d\ttimemodified=%d\n", $id, $before->suspended, $before->timemodified);
        user_update_user((object)['id' => $id, 'suspended' => 1], false, true);
        if (method_exists('\\core\\session\\manager', 'destroy_user_sessions')) {
            \core\session\manager::destroy_user_sessions($id);
        } else {
            \core\session\manager::kill_user_sessions($id);
        }
        printf("suspended\t%d\n", $id);
    }
    printf("done at %d (%s). Verify after two task runs:\n  ... --verify --since=%d\n", $start,
        userdate($start, '%Y-%m-%d %H:%M:%S'), $start);
    printf("Rollback per user: Site administration > Users > (user) > untick Suspended, or rerun with a PHP one-liner\n" .
        "  user_update_user((object)['id' => ID, 'suspended' => 0], false, true);\n");
    exit(0);
}

// ---------------- report (default, read-only) ----------------
echo msc_task_line(), "\n";
$h1 = msc_events_since(time() - 3600);
$h24 = msc_events_since(time() - 86400);
printf("user_password_updated events: last 1 h = %s, last 24 h = %s\n",
    $h1 === null ? 'n/a' : $h1, $h24 === null ? 'n/a (standard log store disabled)' : $h24);
printf("users with create_password=1: %d, picked up by the task (looping if mail fails): %d\n\n", count($cands), count($loop));
printf("%-8s %-6s %-10s %-6s %-11s %-12s %s\n", 'userid', 'loop', 'auth', 'mailok', 'created', 'neverlogged', 'category');
foreach ($cands as $u) {
    printf("%-8d %-6s %-10s %-6s %-11s %-12s %s\n", $u->id, $u->inloop ? 'yes' : 'no', $u->auth,
        $u->emailok ? 'yes' : 'no', userdate($u->timecreated, '%Y-%m-%d'), (int)$u->lastaccess === 0 ? 'yes' : 'no',
        $u->category);
}
echo "\nDecide per user with the owner: needed -> correct the e-mail address in the user's profile (the next run mails a\n";
echo "password and clears the flag); not needed -> suspend (the task skips suspended users). IDs only in tickets.\n";
