# H5: Laravel (or similar) apps in debug or local mode

## Why it matters
Moodle servers often host small side apps (a portal for certificates, an internal accounting tool, a landing page). With
`APP_DEBUG=true`, any error shows a full stack trace with source code, request data and environment values to whoever
triggered it, scanners included. `APP_ENV=local` additionally enables development behaviour in the app and its
packages. If the app is also the web server's catch-all (first vhost, no default server), every scanner hitting the
bare IP lands on it.

**The cached config wins.** When `bootstrap/cache/config.php` exists, Laravel reads that file and ignores `.env`.
Editing `.env` alone changes nothing until the cache is rebuilt (`config:cache`) or removed (`config:clear`).

## Discovery (read-only)
```bash
bash scripts/laravel-env-check.sh            # every app: APP_ENV/APP_DEBUG in .env AND in the cache, modes, hosts, debug packages
```
Read per app:
- `app.env / app.debug in cache` is what the app really runs with (when a cache exists).
- `served as` empty: no enabled vhost; the app may be abandoned (`abandoned-projects.md`) or moved (`orphaned-app.md`).
- `debug pkgs`: Telescope, Debugbar, Ignition. With debug on they expose much more; very old `facade/ignition`
  (< 2.5.2) had a remote code execution bug: report it as urgent.
- `env-dependent code lines`: review them (`grep -rnE "environment\(|isLocal\(|isProduction\(|APP_ENV" app routes bootstrap config`)
  before switching `APP_ENV`; they show what will behave differently.
- `deploy scripts calling artisan migrate`: in production, `artisan migrate` asks for confirmation; unattended
  deploys need `--force`, or they will hang or fail after the switch. Tell the app owner.
- **Adapt:** Symfony (`APP_ENV`/`APP_DEBUG` in `.env.local`, cache in `var/cache`), Django (`DEBUG = True` in
  settings), Node (`NODE_ENV`): same idea, different files; ask before touching an unknown framework.

## Decide (two separate steps)
1. `APP_DEBUG=false`: always safe to propose; it only hides error details from visitors (errors still go to
   `storage/logs/laravel.log`).
2. `APP_ENV=local` → `production`: may change behaviour (packages, forced HTTPS, mail drivers, scheduled commands,
   `migrate` confirmation). Needs the owner's explicit OK, ideally after the env-dependent code was reviewed.
   On the first server both were done together after review; when in doubt, do step 1 alone first.

## Proposal (Arabic)
> **تطبيق `<APP_HOST>` يعمل في وضع التطوير:** إعداد `APP_DEBUG=true` يجعل أي خطأ يعرض للزائر تفاصيل داخلية قد تشمل
> مفاتيح وكلمات مرور، و`APP_ENV=local` وضع تطوير لا إنتاج. أقترح: (1) إيقاف عرض الأخطاء `APP_DEBUG=false`، و(2) بعد
> موافقتك تحويل البيئة إلى `production`. سأحفظ نسخة من الإعدادات، وأعيد بناء ملف الإعدادات المخزّن الذي يقرؤه التطبيق،
> وأقارن المفاتيح التي تغيّرت (يجب أن تكون اثنين فقط)، وأتأكد أن الموقع يعمل قبل وبعد. التراجع بإرجاع الملفين.

## Procedure (per app; <APP_DIR>, <APP_HOST>, <APP_USER>/<APP_GROUP> = the app's FPM pool user/group)
1. **Backup** (root-only; the files hold secrets):
   ```bash
   sudo install -d -m 700 /root/app-mode-<DATE>
   sudo cp -a <APP_DIR>/.env /root/app-mode-<DATE>/env.bak
   sudo test -f <APP_DIR>/bootstrap/cache/config.php && sudo cp -a <APP_DIR>/bootstrap/cache/config.php /root/app-mode-<DATE>/config-cache.bak.php
   sudo bash scripts/mode-snapshot.sh save /root/app-mode-<DATE>/perms.txt <APP_DIR>/.env <APP_DIR>/bootstrap/cache/config.php
   curl -s -o /dev/null -w '%{http_code}\n' --resolve <APP_HOST>:443:127.0.0.1 https://<APP_HOST>/         # note the status
   curl -s -o /dev/null -w '%{http_code}\n' --resolve <APP_HOST>:443:127.0.0.1 https://<APP_HOST>/no-such-page-<DATE>   # note it (404 expected)
   ```
2. **Change `.env`** (only these keys; dry run first, then `--apply`):
   ```bash
   R=../nginx/scripts/replace-once.py      # the plugin's shared exact-replacement tool
   sudo python3 -I $R --file <APP_DIR>/.env --line --in-place --old 'APP_DEBUG=true' --new 'APP_DEBUG=false'
   sudo python3 -I $R --file <APP_DIR>/.env --line --in-place --old 'APP_DEBUG=true' --new 'APP_DEBUG=false' \
       --backup /root/app-mode-<DATE>/env.bak --apply
   # with the owner's OK for step 2:
   sudo python3 -I $R --file <APP_DIR>/.env --line --in-place --old 'APP_ENV=local' --new 'APP_ENV=production' \
       --backup /root/app-mode-<DATE>/env.bak --apply
   ```
   With `--in-place`, `replace-once.py` keeps the inode, owner and mode; for a `.env` it prints only the lines you
   passed, never neighbouring lines.
3. **Rebuild the cache** if one existed (keep the app's behaviour: it was reading a cache before):
   ```bash
   # run artisan as a user that can read .env and write bootstrap/cache (usually the files' owner); never as root
   sudo -u <owner of bootstrap/cache> <PHP for this app> <APP_DIR>/artisan config:cache
   ```
   Use the PHP version of the app's pool (`php8.3`, …), not just `php`. If no cache existed, do not create one: the
   app reads `.env` per request, and the change is live already.
4. **Fix modes again** (the rebuild created a new file with default mode, often `644`):
   `sudo chgrp <APP_GROUP> <APP_DIR>/bootstrap/cache/config.php && sudo chmod 640 <APP_DIR>/bootstrap/cache/config.php`
5. **Test: diff of changed keys** (values hidden, except app.env/app.debug). Run as the app user on private copies:
   ```bash
   D=$(sudo -u <APP_USER> mktemp -d)
   sudo install -m 600 -o <APP_USER> /root/app-mode-<DATE>/config-cache.bak.php "$D/old.php"
   sudo install -m 600 -o <APP_USER> <APP_DIR>/bootstrap/cache/config.php "$D/new.php"
   sudo install -m 644 scripts/laravel-config-keydiff.php "$D/keydiff.php"
   sudo -u <APP_USER> <PHP for this app> "$D/keydiff.php" "$D/old.php" "$D/new.php"; sudo rm -rf "$D"
   ```
   Expected output: `changed app.debug: true -> false` (and `app.env` if step 2 was approved), nothing else. Any other
   changed key means `.env` or a config file was edited since the last cache build: stop, explain it to the owner,
   and decide before going on (rollback is one copy away).
6. **Apply:** the cache file is read per request; with OPcache `validate_timestamps=1` it is picked up within
   `opcache.revalidate_freq` seconds. If `validate_timestamps=0`, reload that PHP-FPM pool (reload, not restart).
7. **Verify:**
   - Same status codes as in step 1 for `/` and the login page; the unknown path returns a plain 404 page (no stack trace).
   - `sudo -u <owner> <PHP> <APP_DIR>/artisan about --only=environment` (Laravel ≥ 9.21) shows `production` / `OFF`.
   - `bash scripts/laravel-env-check.sh <APP_DIR>` and `bash scripts/secrets-perms.sh` are clean.
   - No new lines in `storage/logs/laravel.log` caused by the change.
8. **Rollback:**
   ```bash
   sudo cp -a /root/app-mode-<DATE>/env.bak <APP_DIR>/.env
   sudo cp -a /root/app-mode-<DATE>/config-cache.bak.php <APP_DIR>/bootstrap/cache/config.php
   sudo bash scripts/mode-snapshot.sh restore /root/app-mode-<DATE>/perms.txt --apply
   ```

## Pitfalls
- Running `config:cache` as root creates a root-owned cache the app may not be able to replace later; running it as
  the operator creates `644` with the operator's group. Fix mode and group after every rebuild.
- `config:clear` (instead of `config:cache`) switches the app to per-request `.env` parsing: it works, but it changes
  performance and which file holds the effective config. Keep whatever the app used before unless the owner decides.
- Do not print `.env` or the cache to "check" a value. The check script prints only APP_ENV and APP_DEBUG; the keydiff
  prints key names.
- The app's developer may redeploy the old `.env` from their machine or CI: tell them, and note it in the handbook.
