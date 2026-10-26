# H10: an app that moved to another server but left pieces running here

## Why it matters
When an app (typically a Laravel backend) is moved to another server, the old copy often keeps running on the Moodle
box: a queue worker unit restarting every hour, a `schedule:run` cron line booting PHP every minute, an enabled vhost
with an expiring certificate (certbot then fails twice a day), a world-readable `.env` with `APP_DEBUG=true`, a deploy
SSH key that still grants access. It costs CPU and noise, and it is an unmaintained copy of an app with secrets.

## Discovery (read-only)
First the owner confirms, in words, that the app lives elsewhere now (and where). Then:
```bash
bash scripts/orphan-app-check.sh --dir <APP_DIR> --host <APP_HOST> [--host <ALIAS>] [--key-hint <WORD>]
```
It lists: DNS (does the name still point here?), the vhost access log's last write, systemd/supervisor units and
processes running in the directory (with restart counts), crontab lines, enabled and disabled vhost files, the
PHP-FPM socket and whether other sites share that pool, certificates covering the host, deploy keys in
`authorized_keys` (comment, fingerprint, last accepted login in the journal), the app's DB/queue/cache settings
(non-secret keys only), whether its database exists here, sqlite files still being written, and other apps that
reference it.

**Stop and ask** if: DNS still points here and the access log shows real traffic; another app references it; its
database here is used by something else; the sqlite file is written by something you cannot explain.

- **Adapt:** Apache vhosts (`a2dissite`), supervisor instead of systemd (`supervisorctl stop`, remove the program
  file, `supervisorctl reread && update`), PM2 (`pm2 delete <name>; pm2 save` as its user), Node/Python apps (same
  order, different worker manager).

## Proposal (Arabic)
> **بقايا تطبيق `<APP_HOST>` المنقول:** التطبيق يعمل الآن على خادم آخر، لكن نسخته القديمة هنا ما زالت تشغّل عاملاً
> يعيد التشغيل باستمرار، ومهمة مجدولة كل دقيقة، وموقعاً مفعّلاً بشهادة منتهية، ومفتاح نشر SSH ما زال يسمح بالدخول. أقترح
> إزالتها بالترتيب الآمن: إيقاف العامل، حذف سطر المهمة، تعطيل الموقع، حذف الشهادة، أرشفة مجلد التطبيق كاملاً في مجلد
> لا يقرؤه إلا المدير، ثم حذف مفتاح النشر بعد أن تتأكد أن دخولك أنت يعمل. لا أثر على Moodle ولا على المواقع الأخرى،
> وسأقارن حالة كل المواقع قبل وبعد. التراجع ممكن من الأرشيف خلال 30 يوماً. على GitHub: حدّث أسرار النشر لتشير إلى
> الخادم الجديد (من جهتك).

## Procedure (in this order; one log entry for the whole removal, with the times of each step)
Shared PHP-FPM pool, PHP version and nginx itself are **not** touched (reload only).

0. **Baseline and backups** into one root-only folder:
   ```bash
   T=/root/<TOPIC>-cleanup-<DATE>; sudo install -d -m 700 $T
   bash scripts/probe-sites.sh > ~/hygiene-<DATE>-probe-before.txt
   sudo sh -c "crontab -u <WEBUSER> -l > $T/crontab-<WEBUSER>.before"
   sudo cp -a /etc/systemd/system/<worker>.service $T/ 2>/dev/null
   sudo tar -czf $T/nginx-etc.tgz -C / etc/nginx; sudo tar -czf $T/letsencrypt.tgz -C / etc/letsencrypt
   sudo cp -a /home/<deploy user>/.ssh/authorized_keys $T/authorized_keys.before
   ```
1. **Worker:** `sudo systemctl disable --now <worker>.service` → verify `systemctl is-active <worker>` = inactive and
   no process runs in `<APP_DIR>` (`orphan-app-check.sh` "worker processes" section empty).
2. **Cron line:** remove exactly that line (save → edit a copy with `../nginx/scripts/replace-once.py` or by deleting the line → diff
   → install), as in `cron-mailbox.md` step 1. Verify `sudo crontab -u <WEBUSER> -l` lacks it and the other lines are
   unchanged (diff against the `.before` copy).
3. **Vhost:** `sudo rm /etc/nginx/sites-enabled/<site>.conf` (the symlink only) → `sudo nginx -t` →
   `sudo systemctl reload nginx`. Verify the probe: only `<APP_HOST>` changed (now refused by the default server, or
   answered by whatever is the catch-all: if that is another app, fix the default server first with the `nginx` module).
4. **Certificate** (only now, because the vhost no longer references it): `sudo certbot delete --cert-name <CERT_NAME>`
   → `sudo nginx -t` → `sudo certbot renew --dry-run`.
5. **Project tree:** `sudo bash scripts/archive-path.sh --topic <TOPIC> --apply <APP_DIR>` (tgz with entry-count
   check, original moved to `moved/`). The tgz holds the app's `.env` secrets and its data: root-only, never copied
   anywhere else.
6. **Unit file:** `sudo mv /etc/systemd/system/<worker>.service $T/<worker>.service.removed && sudo systemctl daemon-reload`
   → `systemctl status <worker>` reports "could not be found" (also remove a leftover `*.wants/` symlink if
   `disable` did not).
7. **Vhost file and logs:** move `sites-available/<site>.conf` and `/var/log/nginx/<site>-*` into `$T/` (logs can hold
   personal data and client IPs: archived root-only, deleted later by the owner).
8. **Deploy key:** remove only the matching `authorized_keys` line (by its exact comment and fingerprint):
   `sudo python3 -I ../nginx/scripts/replace-once.py --file /home/<deploy user>/.ssh/authorized_keys --line --in-place --old '<exact line>' --new '' --apply`
   (an empty `--new` with `--line` deletes the line; the day's backup `authorized_keys.bak-<DATE>` must exist)
   (it keeps owner and mode 600; the empty line left behind is ignored by sshd). Diff against the `.before` copy:
   exactly one line differs. **Before closing your session, the owner opens a NEW SSH session** and confirms access
   still works.
9. **Verify everything:** `orphan-app-check.sh` shows nothing left except the archive; `grep -rF <APP_DIR> /etc` empty;
   probe diff shows only `<APP_HOST>` changed; the shared PHP-FPM pool, nginx and Moodle are `active` and 200;
   `systemctl --failed` no longer lists the certbot/worker failures (certbot: confirm at the next real run).
10. **Rollback** (reverse order; certificate BEFORE the vhost): authorized_keys from `$T`; tree from `moved/`; unit file
    → `daemon-reload` → `enable --now`; certificate from `letsencrypt.tgz` (`tar -xzf … -C /`) → re-link the vhost →
    `nginx -t` → reload; crontab from the `.before` file.
11. **Later (owner):** delete `$T/moved/` once satisfied, the rest after ~30 days (`owner-run-deletions.md`).

## Pitfalls
- Deleting the certificate before disabling the vhost breaks `nginx -t` and the next reload.
- Restarting or removing the shared PHP-FPM pool to "clean up" takes down the other apps that use it.
- A copy of the app's database may also sit in a home directory (`~/database.sqlite`, dumps): it belongs to this
  removal (archive it with the rest), not to a separate item.
- Removing the vhost of a name that still resolves here (wildcard DNS, an old record) hands that name to the
  catch-all vhost; make sure the catch-all refuses unknown names before or together with this change.
