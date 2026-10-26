# H4: world-readable secrets and logs (Moodle cron logs, Laravel .env and cached config, ~/.my.cnf)

## Why it matters
A production box usually has more local accounts than people think: service users (`redis`, `mysql`, `nobody`),
other apps' users, deploy users, docker-group members, dev tools left behind. A file with mode `644` (or a `775`
`.env`) inside a traversable directory is readable by all of them:
- Laravel `.env` and `bootstrap/cache/config.php` hold DB passwords, `APP_KEY`, mail and API keys (the cached config
  holds the same secrets, fully resolved).
- Moodle `config.php` holds the DB password; `<DATAROOT>/muc/config.php` can hold the Redis password.
- Cron logs hold task output (names, e-mail addresses, course data).
- `~/.my.cnf`, `.pgpass`, `rclone.conf`, `.git-credentials` hold credentials.
The fix is small, but it must keep the **real reader** working: the PHP-FPM pool user of that app, the cron user,
the deploy user. Change the group first, then the mode.

## Discovery (read-only; never print contents)
```bash
bash scripts/secrets-perms.sh            # EXPOSED / BROKEN / CHECK rows with the reader and a suggested fix
bash scripts/secrets-perms.sh --all      # also the files that are fine (evidence for the report)
```
- `NOBODY=yes` is the decisive test: the script runs `test -r` as `nobody`, which accounts for every parent
  directory. A `644` file inside a `700` home directory is not exposed (but tighten it anyway: homes get opened up).
- `READER` comes from the web server config: the docroot's `fastcgi_pass` socket → the pool's `user`/`group`.
  Several apps can share one pool; a different PHP version can run another app under another user.
- `BROKEN` means the reader cannot read the file now: the app is failing or about to fail. Fix that first.
- **Adapt:** Apache with mod_php reads as the Apache user; PHP-FPM pools on TCP (`127.0.0.1:9000`) are not mapped by
  the script, so it falls back to the web user: confirm the reader by hand (`grep -E '^(user|group|listen)' /etc/php/*/fpm/pool.d/*.conf`).
  WordPress (`wp-config.php`), Node (`.env`) and other apps: same rule, reader = the process user.

## Target modes
| File | Target | Why |
|---|---|---|
| Moodle `config.php` | `640 <owner>:<WEBUSER group>` (or `440`) | FPM pool and CLI (run as the web user) read it; nobody else |
| Laravel `.env` | `640 <owner>:<APP_GROUP>` | the app's pool reads it when no cached config exists; artisan needs it |
| Laravel `bootstrap/cache/config.php` | `640 <owner>:<APP_GROUP>` | the app reads THIS file when it exists |
| Cron logs (`/var/log/moodle_cron/*`) | files `640 <WEBUSER>:<WEBUSER>`, directory `750` | cron writes as the web user; the group can read for support |
| `~/.my.cnf`, `.pgpass`, `.netrc`, `rclone.conf` | `600` | only the owner uses it |
`<APP_GROUP>` is the pool group of that app (often `www-data`). The operator can read through group membership or sudo.

## Proposal (Arabic)
> **ملفات الأسرار والسجلات المكشوفة:** وجدت <N> ملفات يستطيع أي حساب على الخادم قراءتها، منها ملفات تحتوي كلمات مرور
> قاعدة البيانات ومفاتيح التطبيقات، وسجلات مهام قد تحتوي بيانات شخصية. أقترح تقييد كل ملف بحيث يقرؤه فقط البرنامج الذي
> يحتاجه (مع تغيير المجموعة أولاً حتى لا يتوقف أي موقع)، وحفظ الصلاحيات القديمة للتراجع، والتحقق أن كل المواقع تعمل قبل
> وبعد. لا أثر على الطلاب. وأنصح بعدها بتغيير الأسرار التي كانت مكشوفة لفترة طويلة (قرارك، في ليلة صيانة).

## Procedure (one app or one file group at a time)
1. **Backup (modes, not contents):**
   ```bash
   sudo bash scripts/mode-snapshot.sh save /root/perms-before-<topic>-<DATE>.txt <file> [<file> ...]
   bash scripts/probe-sites.sh > ~/hygiene-<DATE>-probe-before.txt         # status of every site before
   ```
2. **Change (group first, then mode):**
   ```bash
   sudo chgrp <APP_GROUP> <file> && sudo chmod 640 <file>
   ```
   For the cron log directory: `sudo chmod 750 /var/log/moodle_cron && sudo chmod o-rwx /var/log/moodle_cron/*`, and in
   its logrotate stanza add `create 0640 <WEBUSER> <WEBUSER>` (backup the stanza to `/root/` first) so rotated files
   keep the mode. Without that line logrotate recreates the log with the old mode tomorrow.
   For home files: `chmod 600 ~/.my.cnf`.
3. **Test:** `sudo runuser -u <APP_USER> -- test -r <file> && echo reader-ok`; `sudo runuser -u nobody -- test -r <file> || echo nobody-denied`;
   `sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E '^error'` (empty) after a stanza edit.
4. **Apply:** modes apply immediately to every new open; no reload. **But** PHP OPcache keeps serving an already
   compiled PHP file (Moodle `config.php`, a Laravel cached config) without re-checking permissions
   (`opcache.validate_permission` is off by default), so a wrong mode may show up only at the next PHP-FPM reload or
   restart, for example at night. The `runuser … test -r` check in step 3 is the authoritative test, not the HTTP probe.
5. **Verify:** `bash scripts/secrets-perms.sh` no longer lists the files; `bash scripts/probe-sites.sh` diff empty;
   the app's own log shows no new permission errors (`storage/logs/laravel.log`, the nginx error log); for cron logs,
   the next run still appends (`stat -c %y`).
6. **Rollback:** `sudo bash scripts/mode-snapshot.sh restore /root/perms-before-<topic>-<DATE>.txt --apply`
   (print the commands first without `--apply`), and restore the logrotate stanza from `/root/`.

## After the fix
- **Rebuilds reset modes.** `php artisan config:cache`, a deploy that rewrites `.env`, or a restore from backup
  recreates files with the default umask (usually `644`, group = the user who ran it). Add to the handbook: "after
  `config:cache` or a deploy, re-run `secrets-perms.sh`", and tell the app's developer.
- **Rotate what was exposed** when the exposure lasted long or the box has untrusted accounts: DB passwords, mail and
  API keys, Redis password. A Laravel `APP_KEY` rotation invalidates sessions and anything encrypted with it: plan it
  with the app owner. Rotation is a separate, owner-approved change (often on a maintenance night).
- **Stale credentials:** a `~/.my.cnf` may hold an old password. Test it without printing anything
  (`mariadb --defaults-file=<file> -e 'SELECT 1' >/dev/null 2>&1 && echo works || echo stale`); a stale file can be
  removed by its owner. Never use `my_print_defaults` or `--print-defaults` to "check" it: they print the password.
