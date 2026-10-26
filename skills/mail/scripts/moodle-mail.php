<?php
// moodle-mail.php — Moodle side of the moodle-server-care "mail" module. Moodle 4.x and 5.x, PHP 7.4+.
//
// Run as the web user from a copy it can read (the operator's home is usually 0700):
//   install -m 644 moodle-mail.php /tmp/msc-moodle-mail.php
//   sudo -u <WEBUSER> <PHP> /tmp/msc-moodle-mail.php --config=<MOODLE>/config.php [action]
// (scripts/_common.sh does this for you: msc_moodle_php <action>.)
//
// Actions (one per run; default --show). Read-only unless marked WRITE or SEND:
//   --show                       non-secret summary of the outgoing-mail settings
//   --dump-rollback              key=value lines of the settings --execute changes, to be saved in a ROOT-ONLY file
//                                (contains the SMTP username in clear, never the password)
//   --execute [--host=H:P] [--maxbulk=N]
//                                WRITE: switch Moodle to the local relay in ONE process (default 127.0.0.1:25, 10):
//                                smtpmaxbulk, smtpsecure='', smtpuser='', then smtphosts last. smtppass is kept.
//   --restore                    WRITE: read the --dump-rollback lines on stdin and set them back (smtphosts last)
//   --connect-test [--timeout=S] connect + EHLO (+ AUTH when a username is set) with Moodle's own mailer; NO message
//   --send-test --to=ADDR --confirm-owner-permission
//                                SEND: exactly one message through Moodle's mailer (delivery and header check)
//   --loop-check                 users stuck in the new-user password loop: count, and IDs failing validate_email()
//   --clear-smtppass --confirm   WRITE: clear the old provider password (only after 14 stable days)
//
// Never prints smtppass. Every write goes through set_config() plus add_to_config_log(), so it shows in
// Site administration > Reports > Config changes, like a change made in the web UI.

$opts = [];
foreach (array_slice($argv, 1) as $arg) {
    if (preg_match('/^--([a-z-]+)(?:=(.*))?$/s', $arg, $m)) {
        $opts[$m[1]] = array_key_exists(2, $m) ? $m[2] : true;
    } else {
        fwrite(STDERR, "unknown argument: $arg\n");
        exit(2);
    }
}
if (empty($opts['config']) || $opts['config'] === true || !is_readable($opts['config'])) {
    fwrite(STDERR, "--config=<MOODLE>/config.php is required and must be readable by this user\n");
    exit(2);
}
$actions = ['show', 'dump-rollback', 'execute', 'restore', 'connect-test', 'send-test', 'loop-check', 'clear-smtppass'];
$unknown = array_diff(array_keys($opts), $actions, ['config', 'host', 'maxbulk', 'timeout', 'to', 'confirm-owner-permission', 'confirm']);
if ($unknown) {
    fwrite(STDERR, 'unknown option(s): --' . implode(', --', $unknown) . "\n");
    exit(2);
}
$chosen = array_values(array_intersect($actions, array_keys($opts)));
if (count($chosen) > 1) {
    fwrite(STDERR, 'choose one action, got: ' . implode(', ', $chosen) . "\n");
    exit(2);
}
$action = $chosen[0] ?? 'show';

define('CLI_SCRIPT', true);
require($opts['config']);

const MSC_KEYS = ['smtphosts', 'smtpsecure', 'smtpauthtype', 'smtpuser', 'smtpmaxbulk'];

function msc_get(string $name): string {
    $v = get_config('core', $name);
    return ($v === false || $v === null) ? '' : (string)$v;
}

function msc_forced(): array {
    global $CFG;
    $forced = [];
    $names = array_merge(MSC_KEYS, ['smtppass', 'noemailever', 'divertallemailsto', 'noreplyaddress']);
    foreach ($names as $n) {
        if (!empty($CFG->config_php_settings) && array_key_exists($n, $CFG->config_php_settings)) {
            $forced[] = $n;
        }
    }
    return $forced;
}

function msc_mask_user(string $u): string {
    return $u === '' ? '<empty>' : '<set, ' . strlen($u) . ' chars>';
}

function msc_show_value(string $name, string $value): string {
    return $name === 'smtpuser' ? msc_mask_user($value) : ($name === 'smtppass' ? ($value === '' ? '<empty>' : '<set>') : $value);
}

// Sets one core setting and records it in the config log. Returns true when the value changed.
function msc_set(string $name, string $value): bool {
    $old = msc_get($name);
    if ($old === $value) {
        return false;
    }
    set_config($name, $value);
    if ($name === 'smtppass') {
        add_to_config_log($name, '********', $value === '' ? '' : '********', null);
    } else {
        add_to_config_log($name, $old, $value, null);
    }
    return true;
}

function msc_mode(): string {
    $h = msc_get('smtphosts');
    if ($h === 'qmail') {
        return 'qmail';
    }
    return $h === '' ? 'php-mail' : 'smtp';
}

function msc_refuse(string $msg, int $code = 3) {
    fwrite(STDERR, "REFUSED: $msg\n");
    exit($code);
}

function msc_check_not_forced() {
    $forced = array_intersect(msc_forced(), MSC_KEYS);
    if ($forced) {
        msc_refuse('set in config.php: ' . implode(',', $forced) . ' (a database change would have no effect; stop and ask the owner)');
    }
}

switch ($action) {
    case 'show':
        printf("moodle_release=%s\n", $CFG->release ?? '?');
        printf("mailer_mode=%s\n", msc_mode());
        foreach (['smtphosts', 'smtpsecure', 'smtpauthtype', 'smtpoauthservice', 'smtpmaxbulk', 'noreplyaddress',
                  'emailfromvia', 'handlebounces', 'allowedemaildomains'] as $n) {
            printf("%s=%s\n", $n, msc_get($n));
        }
        printf("smtpuser=%s\n", msc_mask_user(msc_get('smtpuser')));
        printf("smtppass=%s\n", msc_get('smtppass') === '' ? '<empty>' : '<set>');
        printf("noemailever=%s\n", empty($CFG->noemailever) ? 'not set' : 'SET (Moodle sends no mail at all)');
        printf("divertallemailsto=%s\n", empty($CFG->divertallemailsto) ? 'not set' : 'SET (all mail diverted)');
        printf("forced_in_config_php=%s\n", implode(',', msc_forced()) ?: 'none');
        $mailer = get_mailer();
        printf("phpmailer_smtpautotls=%s\n", property_exists($mailer, 'SMTPAutoTLS') ? var_export((bool)$mailer->SMTPAutoTLS, true) : 'unknown');
        printf("phpmailer_timeout_s=%s\n", property_exists($mailer, 'Timeout') ? (string)$mailer->Timeout : '?');
        break;

    case 'dump-rollback':
        printf("# moodle-server-care mail rollback values, %s (SMTP username in clear; never the password)\n", date('c'));
        foreach (MSC_KEYS as $n) {
            $v = msc_get($n);
            if (strpbrk($v, "\r\n") !== false) {
                msc_refuse("$n contains a line break; save it by hand");
            }
            printf("%s=%s\n", $n, $v);
        }
        break;

    case 'execute':
        msc_check_not_forced();
        $host = (isset($opts['host']) && $opts['host'] !== true) ? (string)$opts['host'] : '127.0.0.1:25';
        $bulk = (isset($opts['maxbulk']) && $opts['maxbulk'] !== true) ? (string)(int)$opts['maxbulk'] : '10';
        if (!preg_match('/^[A-Za-z0-9.\[\]:-]+$/', $host) || $host === 'qmail') {
            msc_refuse("invalid --host '$host'", 2);
        }
        if (!empty($CFG->noemailever)) {
            echo "note: \$CFG->noemailever is set in config.php, so Moodle sends nothing either way\n";
        }
        // All four changes land within milliseconds of each other in this one process. The host flips last, so
        // Moodle never talks to 127.0.0.1 with the provider's TLS or login settings.
        $new = ['smtpmaxbulk' => $bulk, 'smtpsecure' => '', 'smtpuser' => '', 'smtphosts' => $host];
        foreach ($new as $n => $v) {
            $before = msc_get($n);
            $changed = msc_set($n, $v);
            printf("%-12s %s -> %s%s\n", $n, msc_show_value($n, $before), msc_show_value($n, $v), $changed ? '' : ' (unchanged)');
        }
        printf("done at %s; smtpauthtype unchanged (%s); smtppass kept: %s\n", date('Y-m-d H:i:s'),
            msc_get('smtpauthtype'), msc_get('smtppass') === '' ? 'no (it was empty)' : 'yes');
        break;

    case 'restore':
        msc_check_not_forced();
        $vals = [];
        while (($line = fgets(STDIN)) !== false) {
            $line = rtrim($line, "\r\n");
            if ($line === '' || $line[0] === '#') {
                continue;
            }
            $p = strpos($line, '=');
            if ($p === false) {
                continue;
            }
            $k = substr($line, 0, $p);
            if (in_array($k, MSC_KEYS, true)) {
                $vals[$k] = (string)substr($line, $p + 1);
            } else {
                fwrite(STDERR, "ignored key: $k\n");
            }
        }
        if (!isset($vals['smtphosts'])) {
            msc_refuse('no smtphosts line on stdin; nothing restored');
        }
        foreach (['smtpmaxbulk', 'smtpauthtype', 'smtpsecure', 'smtpuser', 'smtphosts'] as $n) {
            if (!array_key_exists($n, $vals)) {
                continue;
            }
            $before = msc_get($n);
            $changed = msc_set($n, $vals[$n]);
            printf("%-12s %s -> %s%s\n", $n, msc_show_value($n, $before), msc_show_value($n, $vals[$n]), $changed ? '' : ' (unchanged)');
        }
        printf("restored at %s\n", date('Y-m-d H:i:s'));
        break;

    case 'connect-test':
        if (msc_mode() !== 'smtp') {
            printf("mailer_mode=%s: Moodle does not use SMTP, nothing to connect to\n", msc_mode());
            exit(0);
        }
        $mailer = get_mailer();
        $mailer->SMTPDebug = 0;   // debugsmtp would print the AUTH exchange
        $mailer->Timeout = (isset($opts['timeout']) && $opts['timeout'] !== true) ? max(1, (int)$opts['timeout']) : 15;
        $ok = false;
        $t = microtime(true);
        try {
            $ok = $mailer->smtpConnect();
        } catch (\Throwable $e) {
            $mailer->ErrorInfo = get_class($e) . ': ' . $e->getMessage();
        }
        $dt = microtime(true) - $t;
        printf("host=%s secure=[%s] auth=%s autotls=%s connect=%s in %.3fs\n", $mailer->Host, $mailer->SMTPSecure,
            $mailer->SMTPAuth ? 'yes' : 'no', var_export((bool)$mailer->SMTPAutoTLS, true), $ok ? 'OK' : 'FAIL', $dt);
        if (!$ok) {
            printf("error=%s\n", preg_replace('/\s+/', ' ', (string)$mailer->ErrorInfo));
        }
        $mailer->smtpClose();
        exit($ok ? 0 : 1);

    case 'send-test':
        if (empty($opts['confirm-owner-permission'])) {
            msc_refuse('sending needs the owner\'s permission: add --confirm-owner-permission only after the owner said yes');
        }
        $to = (isset($opts['to']) && $opts['to'] !== true) ? (string)$opts['to'] : '';
        if (!validate_email($to)) {
            msc_refuse('--to=<owner mailbox> is missing or invalid', 2);
        }
        $from = msc_get('noreplyaddress');
        if (!validate_email($from)) {
            msc_refuse('noreplyaddress is empty or invalid; the provider would reject the message');
        }
        $mailer = get_mailer();
        $mailer->SMTPDebug = 0;
        $mailer->Timeout = 30;
        $mailer->Sender = $from;
        $mailer->setFrom($from, 'Moodle mail test');
        $mailer->addAddress($to);
        $mailer->CharSet = 'UTF-8';
        $mailer->Subject = 'Moodle mail relay test ' . date('Y-m-d H:i');
        $mailer->Body = "Test message from the moodle-server-care mail module (Moodle mailer -> local relay -> provider).\n"
            . "Please check the Authentication-Results header: spf, dkim and dmarc should all say pass.\n\n"
            . "رسالة اختبار من خادم المنصة. لا يلزم أي إجراء سوى التحقق من نتائج SPF وDKIM وDMARC في ترويسة الرسالة.\n";
        $t = microtime(true);
        $ok = $mailer->send();
        printf("send=%s in %.3fs host=%s%s\n", $ok ? 'OK' : 'FAIL', microtime(true) - $t, $mailer->Host,
            $ok ? '' : ' error=' . preg_replace('/\s+/', ' ', (string)$mailer->ErrorInfo));
        get_mailer('close');
        exit($ok ? 0 : 1);

    case 'loop-check':
        // Users with create_password = 1 get a new password from send_new_user_passwords_task on every run until
        // the mail succeeds. email_to_user() returns false before SMTP when validate_email() rejects the address,
        // so no MTA can end this loop: the account needs a corrected address or suspension.
        $sql = "SELECT u.id, u.email
                  FROM {user} u
                  JOIN {user_preferences} p ON p.userid = u.id
                 WHERE p.name = :n AND p.value = :v AND u.deleted = 0 AND u.suspended = 0";
        $rs = $DB->get_recordset_sql($sql, ['n' => 'create_password', 'v' => '1']);
        $total = 0;
        $bad = [];
        foreach ($rs as $u) {
            $total++;
            if (!validate_email($u->email)) {
                $bad[] = (int)$u->id;
            }
        }
        $rs->close();
        printf("create_password_active_users=%d\nfail_validate_email=%d\n", $total, count($bad));
        if ($bad) {
            printf("user_ids_failing_validate_email=%s\n", implode(',', $bad));
        }
        try {
            $n = $DB->count_records_select('logstore_standard_log', 'eventname = ? AND timecreated > ?',
                ['\\core\\event\\user_password_updated', time() - 3600]);
            printf("user_password_updated_last_hour=%d\n", $n);
        } catch (\Throwable $e) {
            echo "user_password_updated_last_hour=unknown (standard log store not available)\n";
        }
        break;

    case 'clear-smtppass':
        if (empty($opts['confirm'])) {
            msc_refuse('add --confirm (only after 14 stable days and the owner\'s approval)');
        }
        if (in_array('smtppass', msc_forced(), true)) {
            msc_refuse('smtppass is set in config.php; remove it there instead (owner decision)');
        }
        if (msc_get('smtpuser') !== '') {
            msc_refuse('smtpuser is set again (rolled back?); keeping smtppass');
        }
        if (msc_get('smtppass') === '') {
            echo "smtppass is already empty\n";
            break;
        }
        msc_set('smtppass', '');
        printf("smtppass cleared at %s (the config log shows ********)\n", date('Y-m-d H:i:s'));
        break;
}
exit(0);
