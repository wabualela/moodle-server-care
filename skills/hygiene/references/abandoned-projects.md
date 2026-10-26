# H9: abandoned projects, dev-tool leftovers and personal-data files

## Why it matters
Production boxes collect leftovers: an old Moodle copy from before an upgrade, a demo site, a static site that moved,
Docker images from a tool someone tried once, CLI caches, load-test scripts, CSV exports of students, SQL dumps made
"just before" a risky change, a full backup tar on the same disk. They cost disk space, but the real cost is risk:
personal data with no owner and no retention, code with old vulnerabilities still reachable if a vhost points at it,
and root-equivalent access through the docker group.

The method: **inventory with proof of non-use → classify → owner decides → move to a root-only archive (reversible)
→ the owner runs irreversible deletes later.**

## Discovery (read-only)
```bash
bash scripts/inventory-paths.sh --discover          # project-like directories and a reference count
bash scripts/inventory-paths.sh <PATH> [<PATH> ...] # detailed proof per candidate
bash scripts/inventory-paths.sh --personal-data     # exports, dumps, sqlite files, big archives (names, sizes, dates)
bash scripts/inventory-paths.sh --docker            # containers, images, volumes, docker group members
df -h / ; sudo du -xsh /var/lib/docker /var/lib/containerd /root /home/* 2>/dev/null
```
The detailed check proves non-use across: enabled web server config, all crontabs and `/etc/cron.d`, systemd units,
supervisor, PHP-FPM pools, logrotate, running processes (cwd/exe), symlinks pointing in, other apps' config files.
It also shows git state (remote, uncommitted entries, commits not pushed), config files (`config.php` with DB
credentials, `.env`), data-like files inside, and **siblings a glob would also match** (`/opt/moodle` vs
`/opt/moodle-maintenance`).

Look specifically for:
- **Old Moodle copies** (`/opt/moodle`, `html.old`, `moodle-4.x`): a `config.php` means credentials and a dataroot;
  check that its `dbname`/`dataroot` are not the live ones before anything else.
- **Dev-tool leftovers:** Docker images with 0 containers (for example a Supabase or similar local stack: many images
  from one registry, volumes named `<tool>_db_<project>`), CLI caches (`~/.npm/_npx/<hash>`, `~/.<tool>`), k6/load-test
  scripts, browser-automation caches.
- **Personal data:** CSV/XLSX exports, SQL dumps (`pre-delete-*.sql.gz`, table dumps), sqlite copies of app databases,
  report folders, old cron mailboxes (`cron-mailbox.md`).
- **Stale DB grants** on databases that no longer exist (`SHOW GRANTS` as root): optional cleanup, a DB change.
- **Same-disk full backups:** keep until an off-site backup is verified with a restore test (`backup` module).
- **Unused PHP versions or packages** (for example an old `php8.x-*` set with no pool in use): removal is a package
  change; propose it separately with `apt-get -s purge` output.

## Classify (show the owner a table)
| Group | What | Default action |
|---|---|---|
| A. Re-creatable, unreferenced | clean git clones already pushed, public Docker images, CLI caches, code copies without config | archive-move (or delete after OK; recoverable from the source) |
| B. Data or personal data | dumps, exports, Docker volumes, app databases of retired apps, mailboxes | owner confirms each item; archive-move root-only, or the owner deletes |
| C. Deferred | same-disk backups, rollback copies, rollback CSVs of a recent migration | keep until a stated condition (off-site backup verified, N days stable) |
| Live | anything with a reference, a running process or an enabled vhost | not part of this item |
For each item record: path, size, newest file date, references (none / list), git state, why it is safe, how to recover.

## Proposal (Arabic)
> **مشاريع متروكة وملفات بيانات شخصية:** وجدت على الخادم <N> عناصر لا يستخدمها أي موقع أو مهمة مجدولة أو خدمة، بحجم
> إجمالي <SIZE>. قسمتها ثلاث مجموعات: (أ) أشياء يمكن استعادتها من مصدرها (نسخ برمجية مرفوعة على GitHub، صور Docker
> عامة)؛ (ب) ملفات فيها بيانات أو بيانات شخصية (نسخ قواعد بيانات، ملفات تصدير طلاب) تحتاج قرارك في كل عنصر؛ (ج) أشياء
> نؤجلها حتى يتحقق شرط (مثل النسخة الاحتياطية الكاملة حتى نتأكد من النسخ الخارجي). أقترح نقل (أ) وما توافق عليه من (ب)
> إلى مجلد مؤرشف لا يقرؤه إلا المدير، والاحتفاظ به نحو 30 يوماً، ثم تحذفه أنت. الحذف النهائي لملفات البيانات الشخصية
> تنفذه أنت بأمر جاهز أعطيك إياه.

## Procedure (one group at a time, a log entry per group)
1. **Baseline:**
   ```bash
   bash scripts/probe-sites.sh > ~/hygiene-<DATE>-probe-before.txt
   df -B1 / > ~/hygiene-<DATE>-df-before.txt
   sudo tar -czf /root/nginx-etc-<DATE>.tgz -C / etc/nginx        # rollback for any vhost file you move
   ```
2. **Dry run:** `bash scripts/archive-path.sh --topic <TOPIC> <EXACT_PATH> [<EXACT_PATH> ...]` shows sizes, entry counts,
   and whether the archive is on the same filesystem (a cross-filesystem move copies).
3. **Change (approved paths only):** `sudo bash scripts/archive-path.sh --topic <TOPIC> --apply <EXACT_PATH> ...`
   It writes `/root/<TOPIC>-cleanup-<DATE>/<name>.tgz` (entry count checked, sha256 in `MANIFEST`) and moves the
   original into `moved/` (instant rollback). For a huge re-creatable tree the owner may prefer a plain delete;
   for files with personal data the tgz is still personal data: it stays root-only and is deleted by the owner.
   - Disabled vhost files of a removed site: move them too (they reference deleted certificates and roots).
   - Docker (group A): `sudo docker ps -aq | wc -l` must be 0 for the images' containers; then
     `sudo docker image rm <repo:tag> ...` by exact names (re-pullable). Volumes are group B: back up first
     (`sudo tar -C /var/lib/docker/volumes -czf /root/<TOPIC>-cleanup-<DATE>/volumes.tgz <volume>`), then
     `sudo docker volume rm <volume>` after the owner's OK. Uninstalling Docker or removing users from the `docker`
     group is a separate owner decision.
   - Keep directories that a disabled-but-package-provided config still names (for example `/var/www/html` used by
     the package `default` site): empty them instead of removing them.
4. **Test:** `sudo nginx -t` (if a vhost file moved); `bash scripts/inventory-paths.sh <EXACT_PATH>` says "does not exist".
5. **Apply:** nothing to reload unless an enabled vhost changed (then `nginx -t && systemctl reload nginx`).
6. **Verify:** probe diff empty; `df -B1 /` vs before; nothing in the error logs; `/root/<TOPIC>-cleanup-<DATE>` is
   mode 700 with `MANIFEST` and `MOVED.tsv`.
7. **Rollback:** `sudo mv /root/<TOPIC>-cleanup-<DATE>/moved/<name> <original path>` (paths in `MOVED.tsv`), or
   `sudo tar -xzf /root/<TOPIC>-cleanup-<DATE>/<name>.tgz -C <parent>`; Docker images: `docker pull`.
8. **Irreversible deletes** (the moved trees after the owner is satisfied, the archive after ~30 days, personal-data
   files): run every pre-check yourself, then hand the owner the exact command (`owner-run-deletions.md`). Verify and
   log afterwards ("owner ran it; checked by session …").

## Pitfalls
- **Exact paths only.** `rm -rf /opt/moodle*` would also remove `/opt/moodle-maintenance`. The archive script refuses
  globs and top-level directories; use `--one-file-system` for any manual `rm -rf` the owner runs.
- **Globs under /root:** the calling shell cannot read `/root` (mode 700), so `sudo rm /root/x-*` passes a literal `*`.
  Wrap such commands as `sudo sh -c 'rm /root/x-*'`, and prefer exact names.
- **A clean git clone can still hold untracked secrets** (`config.php`, `.env` are usually git-ignored): the script
  lists them. "Pushed to GitHub" also means the data in tracked files is on GitHub: if a repo tracks an SQL file with
  personal data, tell the owner (cleaning repo history is a separate task).
- **A live app's database file is not a leftover** even if it sits next to abandoned code: check whether it is still
  written (mtime) and by whom before classifying.
- Some deletions will be refused by the session's permission system even after approval: see `owner-run-deletions.md`.
