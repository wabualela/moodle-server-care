# H0–H2: failing timers (certbot with dead certificates, logrotate with duplicate stanzas)

## Contents
1. Why a failing timer matters
2. H0: inventory of failed units
3. H1: certbot and dead certificates
4. H2: logrotate duplicates and unrotated logs
5. Confirming at the next real run

## 1. Why a failing timer matters
A unit that fails on every run teaches everyone to ignore `systemctl --failed`. The one failure that matters then
hides among the known ones: the live site's certificate renewal, or a rotation error that lets a log fill the disk.
The goal is an empty `systemctl --failed`, with every remaining entry explained in the handbook.

## 2. H0: inventory of failed units (read-only)
```bash
systemctl --failed --no-legend --plain
systemctl list-timers --all --no-pager
for u in $(systemctl --failed --no-legend --plain | awk '{print $1}'); do
  echo "== $u"; systemctl show -p Result -p ExecMainStatus -p ExecMainExitTimestamp "$u"
  sudo journalctl -u "$u" -n 20 --no-pager
done
```
certbot and logrotate are handled below; fail2ban in `fail2ban-journald.md`; a dead app worker in
`orphaned-app.md`. Any other failing unit (a provider agent, a peering helper): record it in the report as a
separate finding and investigate it on its own. Do not "fix" it here by disabling it.

## 3. H1: certbot and dead certificates

### 3.1 Discovery
```bash
bash scripts/cert-references.sh            # add --no-dns to skip DNS lookups
sudo certbot certificates                  # "INVALID: EXPIRED" lines
sudo journalctl -u certbot.service --since -7days --no-pager | grep -iE 'fail|error' | tail
```
- Timer names: Debian/Ubuntu package `certbot.timer` / `certbot.service`; snap `snap.certbot.renew.timer`.
- **Adapt or skip:** no `/etc/letsencrypt/renewal` means another ACME client (acme.sh in a crontab, lego, Caddy,
  a control panel) or bought certificates. Then find the renewal job and its log instead and apply the same logic
  (dead → unreferenced → retire). If the web server is Apache, the references come from `sites-enabled`; the
  script reads those too.

Read the verdict column:

| Verdict | Meaning | What to propose |
|---|---|---|
| `DEAD-UNREFERENCED` | expired, no enabled config uses it | `certbot delete` after the owner confirms the domain is retired or lives elsewhere |
| `DEAD-BUT-ENABLED` | expired, an ENABLED vhost still points at it | decide the vhost first: app moved → `orphaned-app.md`; app still needed → repair DNS/renewal. Never delete the certificate first |
| `VALID-UNUSED` | valid, but no vhost uses it | ask: retire it now, or add a vhost (often a redirect) before its renewal fails |
| `RENEWS-SOON` | under 30 days left | confirm with `sudo certbot renew --dry-run --cert-name <CERT_NAME>` |
| DNS "elsewhere" | behind a proxy (Cloudflare shows its own addresses) or moved | check the vhost access log date and ask the owner |

**Why the order matters:** `certbot delete` removes the files under `/etc/letsencrypt/live/<CERT_NAME>/`. If an
enabled vhost still names them, `nginx -t` fails, and the next reload or restart (for example by an unattended
upgrade at night) takes down every site on the box. A disabled file in `sites-available` that names a deleted
certificate is harmless until someone re-enables it: archive such files (`abandoned-projects.md`) or note them.

**Behind Cloudflare:** an HTTP-01 renewal normally still works (Cloudflare redirects the challenge to HTTPS and
Let's Encrypt follows the redirect to the origin). Prove it with `--dry-run` per certificate; if it fails, run the
`cloudflare` module's renewal section rather than changing the challenge method here.

### 3.2 Proposal (Arabic, adapt the numbers)
> **الشهادات المنتهية:** خدمة تجديد الشهادات تفشل في كل تشغيل بسبب <N> شهادات منتهية لنطاقات لم تعد على هذا الخادم.
> هذا الفشل المتكرر يخفي أي مشكلة حقيقية في تجديد شهادة المنصة. أقترح: نسخة احتياطية كاملة من مجلد الشهادات، ثم حذف
> الشهادات غير المستخدمة فقط (لا يشير إليها أي موقع مفعّل)، ثم تجربة تجديد تجريبية لكل الشهادات الباقية. لا أثر على
> الطلاب، ويمكن استرجاع كل شيء من النسخة الاحتياطية. الشهادة `<CERT_NAME>` ما زال موقع مفعّل يستخدمها: نقرر أولاً مصير
> ذلك الموقع.

### 3.3 Procedure (one certificate group at a time)
1. **Backup** (root-only):
   ```bash
   sudo install -d -m 700 /root/certs-cleanup-<DATE>
   sudo tar -czf /root/certs-cleanup-<DATE>/letsencrypt.tgz -C / etc/letsencrypt
   sudo tar -czf /root/certs-cleanup-<DATE>/nginx-etc.tgz -C / etc/nginx      # or etc/apache2
   bash scripts/probe-sites.sh > ~/hygiene-<DATE>-probe-before.txt
   ```
2. **Change:** for each `DEAD-UNREFERENCED` name the owner approved:
   `sudo certbot delete --cert-name <CERT_NAME>` (answer the prompt; it names the files it removes).
3. **Test:** `sudo nginx -t` (Apache: `sudo apachectl configtest`).
4. **Apply:** nothing to reload when the certificate was unreferenced. If you disabled a vhost first, that step had
   its own `nginx -t` and reload.
5. **Verify** (in the quiet hour: with the nginx/apache authenticator the dry run reloads the web server):
   - `sudo certbot renew --dry-run` ends with "all simulated renewals succeeded" (staging; live certificates untouched).
   - `bash scripts/cert-references.sh` shows no `DEAD-*` rows.
   - `bash scripts/probe-sites.sh > ~/hygiene-<DATE>-probe-after.txt; diff ~/hygiene-<DATE>-probe-{before,after}.txt` is empty.
6. **Rollback:** restore only the deleted lineage, never the whole archive over `/` (that would also roll back every
   certificate renewed since the backup: `live/` symlinks and renewal configs would point at old files):
   ```bash
   sudo tar -tzf /root/certs-cleanup-<DATE>/letsencrypt.tgz | grep -E "^etc/letsencrypt/(live|archive)/<CERT_NAME>/|renewal/<CERT_NAME>\.conf$"
   sudo tar -xzf /root/certs-cleanup-<DATE>/letsencrypt.tgz -C / \
       etc/letsencrypt/live/<CERT_NAME> etc/letsencrypt/archive/<CERT_NAME> etc/letsencrypt/renewal/<CERT_NAME>.conf
   sudo certbot certificates --cert-name <CERT_NAME>; sudo nginx -t
   ```
   A retired domain can also be re-issued with `certbot --nginx -d <name>`.
7. **Pending:** the unit still shows `failed` from its last run. Record "confirmed at the next real run" with the
   time from `systemctl list-timers certbot.timer` (section 5). `systemctl reset-failed certbot.service` only hides
   the old state; use it only after the dry run passed, and log it.

## 4. H2: logrotate duplicates and unrotated logs

### 4.1 Discovery
```bash
bash scripts/logrotate-check.sh            # runs logrotate -d (debug: rotates nothing) plus a static duplicate check
systemctl status logrotate.service --no-pager; sudo journalctl -u logrotate --since -3days --no-pager | tail
```
- **Typical cause:** a custom stanza (often added during an earlier tuning session, e.g. for a DB slow log) names a
  file that a package glob already covers (`/var/log/mysql/*.log` in the `mariadb` package file). logrotate reports
  `duplicate log entry`, exits 1 every night and the unit is `failed`. The package stanza still rotates the file, so
  removing the custom stanza changes only the error, not the rotation.
- **Backup copies inside `/etc/logrotate.d/` are read too.** logrotate skips only its taboo extensions
  (`.dpkg-old`, `.rpmsave`, `.disabled`, `~`, …), not `.bak-<DATE>`. A backup made "next to the file" there creates
  exactly this duplicate. The script warns about such files. Keep logrotate backups in `/root/`.
- **Logs without a stanza:** the script lists large logs no stanza claims (for example a PHP-FPM slow log). They grow
  until the disk fills.
- **Adapt:** older systems run logrotate from `/etc/cron.daily/logrotate` instead of a timer; check `/var/lib/logrotate/status`
  and root's mail for errors. On RHEL-like systems the package files live in the same directory.

### 4.2 Decide
- Keep the **package** stanza for files a package glob covers (it survives upgrades and has the right `postrotate`,
  e.g. MariaDB's `flush-slow-log`). Move the custom duplicate out.
- If the owner needs a different policy for one file (daily instead of monthly), do not edit the package file
  (dpkg conffile prompts on upgrade). Either accept the package policy (its `maxsize` usually caps growth), or move
  the log to a path outside the glob and give it its own stanza.
- For a log without a stanza, add one from `assets/logrotate-custom-log.conf`: `copytruncate` when the writer keeps
  the file open and cannot be told to reopen it (a few lines can be lost at the moment of rotation); `create` plus a
  `postrotate` signal when the writer can reopen (nginx `USR1`, PHP-FPM's `reopenlogs`).

### 4.3 Proposal (Arabic)
> **تدوير السجلات:** خدمة تدوير السجلات تفشل كل ليلة لأن ملف إعداد أضفناه سابقاً يكرر ملفاً تغطيه حزمة النظام أصلاً.
> التدوير الفعلي يعمل من إعداد الحزمة، والخطأ وحده هو المشكلة، لكنه يخفي أي خطأ حقيقي. أقترح نقل الملف المكرر إلى
> مجلد احتياطي خارج مجلد الإعدادات، والتحقق بتشغيل تجريبي، ثم التأكد عند التشغيل الحقيقي القادم (منتصف الليل).

### 4.4 Procedure
1. **Backup = the change:** `sudo mv /etc/logrotate.d/<custom> /root/logrotate.d-<custom>.bak-<DATE>` (moving it out of
   the directory is what disables it; the copy in `/root` is the rollback).
   For a new stanza: write it to `/etc/logrotate.d/<name>` (mode 644, root-owned: logrotate refuses group- or
   world-writable config files).
2. **Test:** `sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E '^error|duplicate'` prints nothing, and
   `bash scripts/logrotate-check.sh` shows "none" under duplicates.
3. **Apply:** nothing to restart; the timer picks the change up. Running `sudo systemctl start logrotate.service` now
   performs a real rotation of everything due: acceptable in a quiet hour, otherwise wait for the timer.
4. **Verify:** at the next real run, `systemctl show -p Result logrotate.service` → `Result=success`; for a new stanza,
   the first rotated file (`<log>.1`) appears after its period.
5. **Rollback:** `sudo mv /root/logrotate.d-<custom>.bak-<DATE> /etc/logrotate.d/<custom>` (the error returns) or
   remove the new stanza file.

## 5. Confirming at the next real run
A dry run (`certbot renew --dry-run`, `logrotate -d`) proves the configuration, not the scheduled run. Report
"tested; confirmed at the next real run (<time from systemctl list-timers>)", put a reminder in the handbook's to-do
list, and after that time check:
```bash
systemctl show -p Result -p ExecMainExitTimestamp certbot.service logrotate.service
sudo journalctl -u certbot.service -u logrotate.service --since "<change time>" --no-pager | tail -n 20
systemctl --failed --no-legend
```
Then append a short log entry "confirmed at the real run of <time>" (or a correction entry if it failed).
