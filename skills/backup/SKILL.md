---
name: backup
description: Sets up nightly encrypted off-provider backups of a production Moodle site with rclone crypt, to a SharePoint document library (Microsoft 365) or an S3-compatible bucket such as Cloudflare R2 - consistent DB dump with checks, guarded filedir mirror, config bundle, 7/4/6 retention that counts only complete sets, healthchecks.io alerting, a systemd timer inside the quiet window, and restore tests. Use it whenever a Moodle server has no off-site or off-provider backup, relies only on provider snapshots, when the owner mentions backups, disaster recovery, SharePoint/OneDrive/R2/S3 storage, restore drills, a lost file or course, a backup token or key to renew, or before a server move or risky maintenance - even if the word "backup" is not used.
---

# Backup: nightly encrypted off-provider copy of a Moodle site

## 1. Read first
Read `../../shared/core-rules.md` (change protocol, secrets, approval, testing). Then `references/design.md`: it
explains every guard below and what to do when this server differs from the first one.

## 2. When to use / signs
- No backup leaves the provider (only droplet backups or snapshots), or backups exist but nobody has restored one.
- Old full copies (`*.tar`, `*.sql.gz`) lie on the same disk as the site: same failure domain, personal data at rest.
- A server move, a big upgrade or a maintenance night is planned (a verified recent backup is a precondition).
- A healthchecks "down" mail, a renewed Microsoft password, a rotated R2 key, or a restore request.

## 3. Discovery (read-only)
```bash
bash ../start/scripts/detect-env.sh            # if ~/.config/moodle-server-care/server.env is missing or > 1 day old
bash scripts/discover.sh                       # sizes, counts, tools, DB engine mix, schedules, existing backup traces
bash scripts/discover.sh --quick               # without the slow filedir/code counts
systemctl list-timers --all --no-pager | grep -Ei 'apt|backup'
```
Also measure the quiet window (audit module, 14 days of access logs) and read the handbook/log for earlier backup
decisions. Decide per finding:

| Finding | Action |
|---|---|
| `dbtype pgsql` | **stop and ask**: the script dumps MariaDB/MySQL only (design.md §10 describes the adaptation) |
| non-InnoDB tables in the Moodle DB | stop and ask: `--single-transaction` is not consistent for them |
| root cannot query the DB over the socket | adapt: the owner writes a root-only option file, `DB_DEFAULTS_FILE` |
| rclone missing or < 1.58 | package install (owner approval), the scripts need `filename_encoding` |
| no Microsoft 365 tenant, or no admin for consent/Purview | propose R2 |
| tenant with Conditional Access (location, device, sign-in frequency) | the backup account must be excluded (or the server's IP allowed); ask before the setup |
| storage at the same provider as the server | not off-provider: propose another provider |
| apt-daily-upgrade inside the planned backup window | align with the maintenance module (apt moved after the backup) |
| an existing backup job | read it, do not duplicate; propose replacing or keeping it |
| other apps on the box (SQLite, `.env`) | ask whether they join the bundle (`--sqlite`, `--extra`) |

## 4. Proposal to the owner (Arabic template; fill from discovery, never another server's numbers)
```
**النسخ الاحتياطي الليلي المشفّر خارج مزوّد الخادم — اقتراح**

الوضع الآن: <لا توجد نسخة خارج المزوّد / توجد لقطات المزوّد فقط / نسخ قديمة على القرص نفسه>.

ما أقترحه:
| البند | الاقتراح |
|---|---|
| الوجهة | <SharePoint في حساب Microsoft 365 لمؤسستك (بلا فاتورة جديدة) / Cloudflare R2 (تكلفة شهرية صغيرة)> |
| التشفير | على الخادم قبل الرفع، بعبارتين تحفظهما أنت في مدير كلمات المرور (لا يراهما أحد غيرك) |
| ما يُنسخ | قاعدة البيانات (<الحجم>) كل ليلة، والملفات (<الحجم>، <العدد> ملف) الجديد منها فقط، والإعدادات، والكود أسبوعياً |
| الموعد | <الوقت> ليلاً داخل أهدأ ساعات المنصة، ويتوقف قبل <وقت التوقف> |
| الاحتفاظ | 7 يومية و4 أسبوعية و6 شهرية |
| الحماية من الحذف | <نسخة قابلة للاسترجاع 30 يوماً عبر Purview + سلة المحذوفات 93 يوماً / قفل R2 لكل مجلد يرفض الحذف> |
| التنبيه | healthchecks.io: بريد عند الفشل أو التحذير أو عدم التشغيل |
| الاختبار | فحص سلامة شهري، وتجربة استرجاع كاملة على خادم مؤقت خلال الشهر الأول ثم كل ربع سنة |

المطلوب منك: <قائمة الخطوات من owner-steps: حساب/موقع أو bucket، مفتاح أو token، تشغيل سكربت الإعداد، رابط healthchecks>.
قرارات: <الوجهة، يوم النسخة الأسبوعية، إضافة بيانات التطبيقات الأخرى والشهادات، بريد إضافي>.
لا يتغير شيء على الخادم قبل موافقتك على كل خطوة.
```

## 5. Procedure
Every step: backup → change → test → apply → verify → log, rollback written first. Details and exact commands:
`references/install.md`.

1. **Owner steps (no server change).** Send the filled Arabic owner steps (`references/owner-steps-sharepoint-ar.md`
   or `owner-steps-s3-ar.md`). Wait for: account/site or bucket, lock (Purview or R2 lock rules), healthchecks check.
2. **Render (no server change).** `bash scripts/render-install.sh --backend sharepoint|s3 --at HH:MM --hard-stop HH:MM
   --out <staging>` plus `--sqlite/--extra/--letsencrypt` as decided. Read its WARNINGS (apt overlap, missing docs).
   Why: the paths, DB name and timer come from server.env and existence checks, not from memory of another server.
3. **Install files.** Backup: none needed (new files only; check they do not exist). Change: `install` commands from
   INSTALL.txt step 1. Test: `bash -n`, `systemd-analyze verify`. Apply: `daemon-reload` (timer stays disabled).
   Verify: files, modes (scripts 0700, defaults 0600). Give the owner the sha256 of the root-owned setup script.
   Rollback: remove the files, `daemon-reload`. Why the hash: the owner runs that script as root.
4. **Owner runs the setup script** in his own SSH session (`unset HISTFILE`, `sha256sum` against your value, `sudo
   bash /usr/local/share/<NAME>/owner-setup-*.sh --name <NAME>`), then pastes HC_URL with `sudoedit`. SharePoint: the
   script forces one token refresh and writes the keycheck object. Verify only names and modes (`stat`, `rclone
   listremotes`). Never read the config. Rollback: the owner deletes the config.
5. **Preflight** `sudo /usr/local/sbin/<NAME> --preflight` (read-only; expect only "no filedir mirror state").
6. **Seed** with `systemd-run` and the unit's sandbox (`--reconcile HOURS`, resumable): one mirror listing, then only
   the missing files. Why outside the timer: it takes hours and must not collide with the night run. Verify:
   "reconcile complete", model line count >= local file count. On a server move only after the final filedir copy
   (it stops when more than `MAX_DELETE` mirror files are missing locally). Rollback: stop the unit (deletes nothing).
7. **Dry run at night** under the same sandbox: real dump, nothing uploaded, no mail. Verify `OK ... dry_run=1`.
8. **First real run** (owner go-ahead at that moment): `systemctl start --no-block <NAME>.service`, poll
   `systemctl show -p ActiveState,SubState,Result` (a Claude tool call stops waiting after 10 min); `Result=success`,
   status file, healthchecks start + success. Then restore test A and the lock tests: SharePoint, the three Purview
   tests of owner steps 4.4 (fresh canary, old-dated canary, emptied folder → `rmdir OK`); R2, the lock canary.
9. **Enable the timer** only when `--preflight` has no FAIL and (SharePoint) the folder test printed `rmdir OK`.
   Verify `systemctl list-timers`. Rollback: `systemctl disable --now <NAME>.timer`.
10. **Within the first month: restore drill B** on a temporary server with read-only credentials; record RPO/RTO.
11. Log, handbook (plan item, customised files), tell the owner what the healthchecks mails mean.

## 6. Verification checklist
- [ ] `--preflight`: no FAIL; "passphrases open the existing backups (keycheck)"; HC_URL /log event visible.
- [ ] SharePoint setup reported `token refresh works`; renewals refuse another account's token.
- [ ] First run: `Result=success`, `/var/lib/<NAME>/status` `last_ok` = the run, `warnings=0`, `filedir_ok=1`.
- [ ] `daily/` holds db, (users), config and manifest of the run; raw names unreadable; manifest uploaded last.
- [ ] Bundle listing: `moodledata/secret/` present; no `passwd.client*`, `sasl_passwd*`, `rclone.conf*`.
- [ ] Restore test A passed (sha256, trailer, table count, cryptcheck sample 0 differences).
- [ ] Lock works: SharePoint, fresh canary in the Preservation Hold Library, the old-dated canary result recorded
      (held or not: decides what protects old mirror files), `rmdir OK`; R2, the canary delete is refused.
- [ ] Timer enabled; next run inside the quiet window; hard stop + 5 min before the apt window.
- [ ] healthchecks: start + success; a deliberate `--alert` is NOT needed (do not send test alerts through the real MTA).
- [ ] The first nights' slice logs show no refused folder removals (SharePoint) and no 429 storms.
- [ ] Owner has: both passphrases in a shared password-manager entry + offline copy; the non-secret parameters; the
      setup script attached.
- [ ] Drill B scheduled within a month (date in the handbook plan).

## 7. Log entry example
```
### 2026-03-20 02:58 — nightly off-provider backup enabled (moodle-backup → SharePoint)  (session: <name>, approved by owner: yes)
- What/why: no copy left the provider; nightly encrypted backup to the organisation's SharePoint library, 7/4/6, healthchecks.
- Files/settings touched: new /usr/local/sbin/moodle-backup{,-retention}, /etc/default/moodle-backup (0600),
  /etc/systemd/system/moodle-backup{.service,.timer,-alert.service}, /usr/local/share/moodle-backup/; timer enabled 02:30.
  rclone config written by the owner (/var/lib/moodle-backup/rclone/rclone.conf, root 0600; not read).
- Backup / rollback: new files only; `systemctl disable --now moodle-backup.timer`; full removal in install.md §3.
- Verified: preflight no FAIL (keycheck); setup token refresh OK; seed complete (model = local file count); first run
  Result=success 02:31–02:47, warnings=0; restore test A passed; Purview: fresh canary held, old-dated canary <held /
  not held>, rmdir OK; healthchecks start+success.
- Next: restore drill B by <date>; weekly retention --check; first weekly copy on <day>.
```

## 8. Pitfalls we hit on the first server (generalised)
- **`--max-delete` is not a guard.** rclone checks it per delete, moves N files, then fails; a half-empty filedir
  (mount problem, partial rsync during a move) drained the mirror N files a night in the harness. Only locally computed
  counts before the sync protect the mirror.
- **The first backup slot collided with the apt window** that the maintenance plan moved into the quiet hours. Plan
  backup, apt window and maintenance together; the unit timeout is the hard stop.
- **Failure mail without a verified sender never arrives** (the relay rejects it): `MAIL_FROM` or healthchecks only.
- **A test harness sent two real mails** because the script called `/usr/sbin/sendmail` by absolute path, bypassing the
  mock. Scripts call tools through a fixed PATH; the harness aborts if a mocked tool appears with an absolute path.
  Never run `--alert` against the real MTA as a "test".
- **A wrong passphrase looks like an empty folder** (rclone hides undecryptable names): the setup test passed and the
  next night would have started a second key domain and re-uploaded everything. Both scripts now refuse.
- **Incomplete sets were counted as "kept"** and pushed good sets out. Manifest last + count only complete sets.
- **Rebuild facts lived only on the server.** Crypt options written explicitly (rclone's default directory-name
  encryption would make folders unreadable after a manual rebuild); non-secret parameters go to the password manager.
- **Secrets at risk during setup**: a script exiting between hidden prompts makes the next paste land in the shell
  (and history); `bash -x` prints secrets; a non-breaking space or a bracketed-paste escape becomes part of a
  passphrase. Re-ask instead of exiting, `set +x` first, strict character checks, `unset HISTFILE`.
- **MTA credential copies**: the "backup first" rule creates `passwd.client.bak-*` copies that an exact-name exclude
  misses. Exclude with a wildcard and fail the run if one slips in.
- **Tools that print option files leak passwords.** `mariadb-dump --print-defaults` (or `my_print_defaults`) prints
  the stored DB password into the transcript; a sub-agent "just checking the dump options" is enough. Never run them;
  read DB facts through information_schema as root over the socket.
- **SharePoint token write-back fails silently** (rclone exits 0 with "Failed to save config"): config must live in a
  writable `StateDirectory`, and every run checks it was rewritten.
- **Full listings on SharePoint are expensive** (no ListR in rclone 1.60): model + slices, never `lsf -R`/`size` on
  filedir there.
- **Proving the passphrases by "the newest manifest opens" was wrong.** A first upload interrupted before its manifest
  made every later night fail with "wrong passphrases", and the setup script deleted a correct config. Prove them with
  a keycheck object or one decrypted name instead.
- **`--reconcile` with a half-copied filedir** (server move) rebuilt the model from the partial list; every guard
  passed and the slice syncs would have moved the missing files away without an alert. Model = local ∪ mirror, stop
  when too many mirror files are missing locally, and reconcile only after the final copy.
- **A `GET /me` call blocked the SharePoint setup**: rclone's token has no `User.Read`. Read the account from the
  token; check every Graph call against the scopes the app really gets.
- **The setup never tested a token refresh**, so a refused refresh (client secret, Conditional Access) would only show
  hours into the seed. Force one refresh at setup.
- **`--renew-token` accepted another account's token** (an admin still signed in): compare the token's `oid`.
- **A timeout killed the script by SIGPIPE** (systemd signals the whole unit, the `tee` died first): no `/fail` of its
  own and a partial dump left. Make the log `tee` ignore TERM.
- **Warning mails could not leave the sandbox** (`ProtectSystem=strict` made the MTA spool read-only); a dry run sent
  a real warning mail. Spool paths in `ReadWritePaths=`; dry runs never mail; healthchecks is the alert that counts.
- **Purview is not "undeletable"** and may not hold old files at all (rclone sends the file's mtime as its creation
  date); a policy that refused emptied-folder removal would fail every slice night. Test both before enabling.
- **A password change may not cut off a stolen Microsoft token**: Revoke sessions first, then the password, then renew.
- **A blocking `systemctl start` of the backup inside a Claude tool call** outlives the 10-minute tool limit: start
  with `--no-block` and poll.
- **The harness safety grep matched a comment and the suite ignored the failed build step**, so the mocks could have
  been skipped silently. Strip comments, assert the PATH patch, stop on a failed build, run under a no-network sandbox.
- **Estimated times in log entries were wrong**; use `date`/`stat` timestamps.

## 9. Files in this module
| File | What it is |
|---|---|
| `scripts/discover.sh` | read-only discovery for planning (sizes, tools, DB engines, schedules, existing traces) |
| `scripts/lib-env.sh` | parse-only server.env loader for discover.sh and render-install.sh (never sourced) |
| `scripts/moodle-backup` | the night job (`--dry-run`, `--preflight`, `--reconcile [H]`, `--alert`); installed as `/usr/local/sbin/<NAME>` |
| `scripts/moodle-backup-retention` | keep-N enforcement/report (`--apply`, `--check [--lifecycle]`) |
| `scripts/render-install.sh` | builds the install tree and INSTALL.txt for this server in a staging dir (no system change) |
| `scripts/owner-setup-sharepoint.sh` | owner-only: rclone config for a SharePoint library (hidden prompts, Graph lookup without `/me`, forced refresh test, keycheck, `--renew-token` same account only, `--read-only`) |
| `scripts/owner-setup-s3.sh` | owner-only: rclone config for R2/S3 (hidden prompts, tests, keycheck, `--read-only` drill key check) |
| `assets/moodle-backup{.service,.timer,-alert.service,.default}.in` | templates rendered by render-install.sh |
| `references/design.md` | how it works, guards, retention/locks, Purview caveats, timing, secrets, adapting to other servers, both review rounds |
| `references/install.md` | install steps 0–9, rollback, operations, healthchecks messages, maintenance nights, server move, key/password changes |
| `references/restore-tests.md` | monthly integrity check, restore drill, partial restores, total loss |
| `references/owner-steps-sharepoint-ar.md` | owner steps in Arabic: Microsoft 365 account, site, consent, Purview, healthchecks, token, setup, password change |
| `references/owner-steps-s3-ar.md` | owner steps in Arabic: R2 account security, bucket, lifecycle + lock rules, key, setup |
