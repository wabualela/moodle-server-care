# Moodle side: switch to the local relay, verify, watch 14 days, roll back

Detailed procedure behind SKILL.md steps 5–7. All Moodle reads and writes go through
`scripts/moodle-mail.sh` (it runs `moodle-mail.php` as the web user from a 0644 copy in /tmp, never prints `smtppass`,
and writes through `set_config()` + `add_to_config_log()` so changes appear in Site administration > Reports >
Config changes like a change made in the web UI).

## Contents
1. What changes and why
2. When Moodle differs
3. Before the switch
4. Save the rollback values (root-only)
5. Switch in one PHP process
6. Verify without sending
7. Watch the first real messages; measure after 24 h
8. Fourteen days of daily checks, then close-out
9. Rollback
10. Failure feedback moves out of the page
11. Lesson: the new-user password loop is not an MTA problem
12. Optional stop-gap when no MTA can be set up yet

## 1. What changes and why
| Setting | From (typical) | To | Why |
|---|---|---|---|
| `smtphosts` | `<provider>:465` | `127.0.0.1:25` | hand mail to the local queue in milliseconds |
| `smtpsecure` | `ssl` | empty | no TLS on loopback; Moodle's mailer never starts TLS by itself (`SMTPAutoTLS = false`) |
| `smtpuser` | (set) | empty | without a username Moodle does not try to log in; exim offers no AUTH on loopback, so a set username would make every send fail |
| `smtpmaxbulk` | 100 (or 1) | 10 | exim queues every message after the 10th on one connection (`smtp_accept_queue_per_connection = 10`) and those wait for the next queue run (up to 5 min); 10 keeps cron batches flowing |
| `smtpauthtype` | LOGIN | unchanged | ignored when the username is empty; kept for rollback |
| `smtppass` | (set) | **unchanged** | keeps rollback a one-command job; cleared after 14 stable days |
| `noreplyaddress` | | unchanged | it must stay on the provider-verified domain (check its spelling: a misspelt address can still work, and changing it is the owner's decision) |

**Why one PHP process:** the four values must change together. With `admin/cli/cfg.php` one value per process there
are seconds where, for example, `smtphosts` is already `127.0.0.1:25` but `smtpsecure` is still `ssl`, and every mail
in that window fails. `moodle-mail.php --execute` sets all four within milliseconds, the host last.

## 2. When Moodle differs
| Found | Do |
|---|---|
| `mailer_mode=php-mail` (empty `smtphosts`) | Moodle already hands mail to the local MTA through PHP `mail()` and the sendmail binary: pages do not wait for the provider (a short fork per mail). Skip the switch; check how the MTA relays (it may deliver direct-to-MX, which fails SPF/DMARC) and do the DNS part. Switching to `127.0.0.1:25` is optional (it adds `smtpmaxbulk` connection reuse) |
| `smtphosts=qmail` | not covered: stop and ask |
| several hosts in `smtphosts` (`a;b`) | they are fallbacks for the provider; the local relay replaces them all; record them in the rollback file (done automatically) |
| `smtpauthtype=XOAUTH2` / `smtpoauthservice` set | exim/Postfix cannot reuse Moodle's OAuth2 token: stop and ask (provider relay connector, app password, or a transactional provider) |
| `forced_in_config_php` lists a mail setting | a database change has no effect: the switch needs a `config.php` edit (backup, `php -l`, owner approval) instead; `--execute` refuses |
| `noemailever` or `divertallemailsto` set | a test or staging configuration: nothing reaches students anyway. Ask before going further |
| `phpmailer_smtpautotls=true` | see exim-smarthost.md §11 before switching |
| Moodle 4.x | same settings and the same script; `config.php` lives in `<MOODLE>` in all versions |

## 3. Before the switch
- exim (or Postfix) configured, credentials present (`check-credentials.sh` all ok), routing tests passed, the one
  test message delivered and confirmed by the owner.
- The owner approved the switch and its time. It is invisible to students, but do it in a quiet hour anyway so a
  problem touches few people; re-read the tail of the operations log first.
- Baseline: `bash scripts/moodle-mail.sh --connect-test` before the switch (it connects and logs in to the provider,
  sends nothing) gives the "before" connection time (typically a second or two to a remote provider).

## 4. Save the rollback values (root-only)
```bash
D=/root/msc-mail-$(date +%F); sudo install -d -m 700 "$D"
bash scripts/moodle-mail.sh --dump-rollback | sudo sh -c "umask 077; cat > $D/moodle-smtp-rollback.txt"
sudo stat -c '%U:%G %a' "$D/moodle-smtp-rollback.txt"                       # root:root 600
sudo awk -F= '{v=$2; if ($1=="smtpuser") v="<" length($2) " chars>"; print $1"="v}' "$D/moodle-smtp-rollback.txt"
```
The file holds the SMTP username (not the password), hence root-only; the username is never echoed.

## 5. Switch in one PHP process
```bash
bash scripts/moodle-mail.sh --execute                   # defaults: --host=127.0.0.1:25 --maxbulk=10
bash scripts/moodle-mail.sh --show | grep -E '^(smtp|mailer_mode)'
```
Note the time printed (`done at …`): it is the "switch time" for the checks below and the log entry.

## 6. Verify without sending
```bash
bash scripts/moodle-mail.sh --connect-test
# expect: host=127.0.0.1:25 secure=[] auth=no autotls=false connect=OK in 0.00Xs
```
This uses Moodle's own mailer (`get_mailer()->smtpConnect()`): connect and EHLO only, no message. Moodle's "Test
outgoing mail configuration" page does send a message: use it only with the owner's permission, to his mailbox.

## 7. Watch the first real messages; measure after 24 h
```bash
T='<switch time, YYYY-MM-DD HH:MM:SS>'
sudo awk -v t="$T" '($1" "$2) >= t' /var/log/exim4/mainlog \
  | grep -E ' <= .*\[(127\.0\.0\.1|::1)\]| R=smarthost | (==|\*\*) ' \
  | sed -E 's/[^ <]+@/…@/g; s/(A=[a-z_]+):[^ ]*/\1/' | tail -20
sudo exim4 -bpc; sudo test -s /var/log/exim4/paniclog && echo PANIC || echo 'paniclog empty'
```
Expect `<= … [127.0.0.1] P=esmtp` (Moodle) followed by `=> … R=smarthost … C="250 …"`. On a busy site the first
signups or enrolments arrive within minutes; on a quiet night wait for cron (forum digests, notifications).
After a full day: `../audit/scripts/measure-endpoints.sh` with window A = the full day before the switch and window B
= the full day after (`--from/--to`, `--from2/--to2`), reading the rows of the endpoints that send mail (enrol page,
signup submit, forgot-password submit; all in its default set),
and the count of new PHPMailer frames in the PHP-FPM slow log (should be 0). State what was measured: server time
from the access log, n requests per day.

## 8. Fourteen days of daily checks, then close-out
Daily: `bash scripts/mail-daily-check.sh [--known-frozen <ids already explained in the log>]`.
- **OK**: nothing to log. **CHECK**: explain each item (a bad student address, a test bounce); log it if it teaches
  something. **TRIGGER**: roll back the Moodle part the same day (§9) unless the item is explained, then investigate.
- Rollback triggers: an unexplained `**` failure or frozen message, a queue above 50 that keeps growing, an
  authentication deferral that the owner cannot fix at once (mail is queued, not lost, so a quick token fix is
  usually better than a rollback), a non-empty paniclog.
After 14 clean days (log a summary entry), with the owner's approval:
- `bash scripts/moodle-mail.sh --clear-smtppass --confirm` (the config log shows `********`).
- The owner deletes the `passwd.client.bak-*` copies made after the credentials were added and, if no longer wanted,
  `/root/msc-mail-<date>/moodle-smtp-rollback.txt` (it holds the SMTP username). Claude prepares the exact commands.
- Update the handbook to-do, the log's customised-files table, and the DMARC tightening date (mail-dns.md).

## 9. Rollback (about 5 minutes)
```bash
sudo cat /root/msc-mail-<date>/moodle-smtp-rollback.txt | bash scripts/moodle-mail.sh --restore
bash scripts/moodle-mail.sh --connect-test     # provider host, ssl, auth=yes, ~1-2 s again
```
`smtppass` was never touched, so the provider login works again at once. Then, only if exim must go too, drain and
revert it (exim-smarthost.md §9). Log the rollback with its reason.

## 10. Failure feedback moves out of the page
Before, a provider rejection made `email_to_user()` return false inside the request (and Moodle logged
`\core\event\email_failed`). After the switch exim accepts everything, so Moodle believes every mail succeeded.
Rejections become delivery-status notifications to the envelope sender (the no-reply address); the provider often
refuses those too (null sender), so they freeze. Debian's `ignore_bounce_errors_after = 2d` removes them. This is why
the daily check counts `**` lines and frozen messages: they are now the only signal of undeliverable mail.

## 11. Lesson: the new-user password loop is not an MTA problem
Accounts with the preference `create_password = 1` get a new password from `send_new_user_passwords_task` on every
run (every minute by default) until the mail succeeds. On the first server a handful of bulk-uploaded accounts that never
logged in produced thousands of password-update events and user-table writes a day. The plan assumed the local relay would
end the loop because exim accepts the mail. It did not: `email_to_user()` calls `validate_email()` first and returns
false for malformed addresses (bad dots in the domain, a domain without a dot, two `@`), so no mail ever reached any
MTA. `bash scripts/moodle-mail.sh --loop-check` shows the count, how many fail `validate_email()`, their user IDs (no
personal data) and the password-update events in the last hour. The fix is per account and is a user-data change
that needs the owner's approval: correct the address (the next task run then mails a password and clears the flag)
or suspend the account (the task skips suspended users). It belongs to the hygiene work, not to this module.

## 12. Optional stop-gap when no MTA can be set up yet
If the relay must wait, the welcome mail on self-enrolment (the most frequent mail-sending page) can be stopped:
Site administration > General > Messaging > Notification settings, row "Course welcome message" if your version has
it: switch off its e-mail output (or the whole notification), or per enrolment instance "Send course welcome
message = No". It is user-visible (students stop getting welcome mails) and also affects manual enrolments, so it is
an owner decision; signup and password-reset mails still wait for the provider. Undo it once the relay is verified.
