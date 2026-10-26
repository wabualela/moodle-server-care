# H6: accounts stuck in Moodle's new-user password loop

## Why it matters
When an account is created with "generate password and notify user" (bulk upload, admin form, some auth plugins),
Moodle sets the user preference `create_password = 1`. The scheduled task `\core\task\send_new_user_passwords_task`
(every minute by default) picks these users up, **sets a new password**, and calls `email_to_user()`. The preference
is cleared only when the mail succeeds. If `email_to_user()` returns false, the next run does it again, forever:
- one `user_password_updated` event and one `user` table write per user per minute (thousands per day, filling the
  log store and the binlog, touching a hot table);
- the person can never log in: the password they might have received is replaced a minute later.

Why `email_to_user()` fails (the task query only picks users with a non-empty e-mail, not suspended, not deleted,
auth not `nologin`):
- the address fails Moodle's own `validate_email()` (two `@`, domain without a dot, bad dots, spaces): Moodle
  returns before contacting any mail server, so **fixing the mail server does not end this loop**;
- the user is over the bounce threshold (`handlebounces` on);
- SMTP itself fails (rare; then all mail fails and you would see it elsewhere).

## Discovery (read-only, Moodle CLI as the web user)
```bash
P=$(mktemp -d); chmod 755 "$P"                  # the web user cannot read the operator's home; a private dir, never a
install -m 644 scripts/password-loop.php "$P/"   # fixed /tmp name another account could create first
sudo -u <WEBUSER> <PHP> "$P/password-loop.php" --moodle=<MOODLE>
# keep $P for the steps below; remove it at the end: rm -rf -- "$P"
```
Output: the task's schedule and last run, `user_password_updated` events in the last hour/day, and one line per
user with `create_password = 1`: user ID, whether the task picks it up (`loop`), auth, `mailok` (Moodle's
`validate_email()`), creation date, never-logged-in flag and a category (`domain-no-dot`, `at-count`, …). It never
prints names, usernames or addresses. Keep the user IDs out of public tickets.

- **Adapt:** works on Moodle 3.9–5.x. If the standard log store is disabled, the event counts show `n/a`: compare
  `user.timemodified` of the listed users before and after instead. If the task is disabled or rescheduled, the loop
  runs at that schedule.
- `valid (mail fails elsewhere?)` rows: the address is valid; look at SMTP (the `mail` module) and the bounce
  counters before suspending anyone.

## Decide per user (with the owner)
| Situation | Action |
|---|---|
| Account needed (a real, current person) | correct the e-mail address in the profile (admin UI); the next run mails a password and clears the flag |
| Not needed (old bulk upload, never logged in) | suspend; the task skips suspended users; nothing is deleted |
| Unsure | suspend now (reversible), correct later if someone asks |
Deleting accounts is not part of this item.

## Proposal (Arabic)
> **حسابات عالقة في حلقة كلمة المرور:** <N> حسابات تحصل على كلمة مرور جديدة كل دقيقة منذ إنشائها، لأن بريدها الإلكتروني
> غير صالح في نظر Moodle نفسه فلا تُرسل الرسالة أبداً، فيعيد النظام المحاولة بلا نهاية (نحو <EVENTS> عملية يومياً في
> قاعدة البيانات). أصحاب هذه الحسابات لا يستطيعون الدخول أصلاً. أقترح تعليق (Suspend) الحسابات غير المستخدمة بصفتي
> مدير الموقع، دون حذف أي شيء، وتصحيح بريد أي حساب تريد إبقاءه. التراجع: إلغاء التعليق من صفحة المستخدم.

## Procedure
1. **Backup:** save the report (IDs only) to a root-only file:
   `sudo -u <WEBUSER> <PHP> "$P/password-loop.php" --moodle=<MOODLE> | sudo tee /root/password-loop-before-<DATE>.txt >/dev/null && sudo chmod 600 /root/password-loop-before-<DATE>.txt`
2. **Dry run:** `sudo -u <WEBUSER> <PHP> "$P/password-loop.php" --moodle=<MOODLE> --suspend --ids=<ID1>,<ID2>`
   (refuses IDs that are not in the loop set and site administrators).
3. **Change (approved IDs only):** add `--execute`. The script sets the site administrator as the acting user (the
   `user_updated` events show the admin, like a UI change), calls `user_update_user()` with `suspended = 1` without
   touching the password, and ends the users' sessions. It prints `before` lines (suspended flag, timemodified) and
   the change time.
   UI alternative for one or two users: Site administration → Users → (user) → Edit profile → tick "Suspended account".
4. **Test/verify:** after two task runs (2–3 minutes with the default schedule):
   ```bash
   sudo -u <WEBUSER> <PHP> "$P/password-loop.php" --moodle=<MOODLE> --verify --since=<change time printed in step 3>
   ```
   Expected: "users the task still picks up: 0" (or only the ones you decided to keep and correct) and
   `user_password_updated events since …: 0`. Exit code 0 means both are zero. Delete the copy afterwards (`rm -rf -- "$P"`).
5. **Rollback:** unsuspend in the UI (Edit profile → untick "Suspended account"), or for many users a CLI one-liner
   with `user_update_user((object)['id' => <ID>, 'suspended' => 0], false, true);` as admin. To make an account usable,
   correct its e-mail first, then unsuspend: the next run mails a password and clears the flag.

## Pitfalls
- Do not trust a regex outside Moodle to decide which addresses are "valid": Moodle's `validate_email()` is the one
  that matters (on the first server an external check called half of the addresses valid; Moodle rejected all).
- Do not just delete the `create_password` preference in the database: the account keeps an unknown password and no
  mail is ever sent; it hides the problem instead of deciding it.
- Run the script from `/tmp` with mode 644 as the web user, never as root (Moodle files created as root break
  caches), and never via a heredoc into `/dev/stdin` under sudo (it fails).
