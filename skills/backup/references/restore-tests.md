# moodle-backup: restore tests and real restores

A backup counts only once a restore from it has worked. Three levels, plus total loss:

| Level | When | Where | Touches production? |
|---|---|---|---|
| A. Integrity check | monthly, at night outside the backup window, about 10 min | production, scratch dir `/var/backups/<NAME>/verify` | No (downloads and reads only) |
| B. Full restore drill | once after go-live, then quarterly | a temporary server at a provider/region already in the data-protection record, destroyed afterwards | No |
| C. Partial restore | when something is actually lost | production | **Yes: owner go-ahead each time, log entry** |
| D. Total loss | server gone | new server | rebuild |

Names used below: `C="--config /var/lib/<NAME>/rclone/rclone.conf"` (add `--tpslimit 8` on SharePoint),
`X=<NAME>-crypt:` (decrypted view), `<P>` = set prefix, `<D>` = dataroot, `<M>` = Moodle code root, `<DB>` = DB name.

Rules for every level:
- **SharePoint: never list the whole mirror** (`lsf -R`, `size`, `ls` on `filedir`): one Graph call per folder.
  List one folder (`filedir/ab/cd/`) instead. On R2 listing is cheap.
- **No `CREATE DATABASE` / `USE`** in the dump: every restore names its target database, so a dump piped into a
  scratch database can never write into production.
- **Restore a set as a whole on a new server**: its config.php, users dump and DB dump belong together (after
  password rotations, older sets hold the old passwords). **On the same server** after a password rotation, restore
  only the Moodle DB dump and files, and keep the live config.php `dbpass` and the live DB account (install.md §9):
  an older set's config.php or users dump would bring back the old password.
- **Files**: the mirror plus every `filedir-deleted/<run>/` with run **>= the set's stamp, the same stamp included**
  (files removed between that night's dump and that night's sync are in the same-stamp folder).

## A. Monthly integrity check (production, read-only for Moodle)

```bash
sudo -i
C="--config /var/lib/<NAME>/rclone/rclone.conf"; X=<NAME>-crypt:; P=<P>; D=<D>; V=/var/backups/<NAME>/verify; mkdir -p -m 700 "$V"
TS=$(rclone $C lsf ${X}daily --include "$P-manifest-*" | sed -E "s/^$P-manifest-(.*)\.txt$/\1/" | sort | tail -n 1); echo "$TS"
rclone $C copy ${X}daily/ "$V" --include "$P-*-$TS.*"
cat "$V/$P-manifest-$TS.txt"                                  # release, tables, dump_sha256, rows, sqlite ... ok
sha256sum "$V/$P-db-$TS.sql.zst"                              # must equal dump_sha256 above
zstd -q -t "$V"/*.zst && echo "zstd OK"
zstdcat "$V/$P-db-$TS.sql.zst" | tail -n 1                    # -- Dump completed on ...
zstdcat "$V/$P-db-$TS.sql.zst" | grep -c '^CREATE TABLE '     # = tables= in the manifest
zstdcat "$V/$P-config-$TS.tar.zst" | tar -tf - | grep -cE "^${D#/}/secret/.|config\.php$"   # >= 2
zstdcat "$V/$P-config-$TS.tar.zst" | tar -tf - | grep -E '(^|/)(passwd\.client|sasl_passwd|rclone\.conf)'; echo "credential files listed above: must be none"
# Sample of the file mirror: 300 random files, content compared through the encryption (one lookup per file, no
# listing). OneDrive gives QuickXorHash and S3 gives MD5 for single-part uploads, so cryptcheck works.
cd <D>/filedir && find . -type f -path './[0-9a-f]*' | sed 's#^\./##' | shuf -n 300 > "$V/sample.txt"
rclone $C cryptcheck <D>/filedir ${X}filedir --files-from "$V/sample.txt" --one-way
cd / && rm -rf "$V"
```
Pass: every line as expected and `cryptcheck` reports 0 differences. Record it as a one-line read-only check in the log.
With `SLICES=16` the whole mirror is also verified piece by piece every 16 nights (`slice=` and `slice_reuploaded=`
in the status file).

## B. Full restore drill (temporary server)

Proves that the backup alone, plus the passphrases from the password manager, rebuilds the site. Never on production.

1. **Owner**: credentials for the drill.
   - SharePoint: a drill account with **Read** (Visitors) on the backup site; `rclone authorize "onedrive"` on his PC
     signed in as that account. Afterwards revoke the drill account's sessions (never the backup account's: that
     would cut off the server).
   - R2: an **Object Read** token for the bucket with a short TTL; delete it afterwards.
2. **Owner**: a temporary server with the same OS major version, RAM >= 4 GB, disk >= 2.5 × (filedir + DB size).
   Region already in the data-protection record (it holds all personal data). No DNS name.
3. On the drill server, as root:
   ```bash
   apt-get update && apt-get install -y mariadb-server rclone zstd python3     # or the MySQL server the site uses
   printf '[mariadbd]\nmax_allowed_packet=1G\ninnodb_buffer_pool_size=2G\n' > /etc/mysql/mariadb.conf.d/90-restore.cnf
   systemctl restart mariadb
   # Owner, typing the SAME passphrases (this proves the escrow works); copy the setup script over first (no secrets):
   unset HISTFILE; bash owner-setup-sharepoint.sh --read-only --name <NAME>   # or owner-setup-s3.sh --read-only
   #   must report "passphrases open the existing backups" (and on S3 "writes are refused")
   C="--config /var/lib/<NAME>/rclone/rclone.conf"; X=<NAME>-crypt:; P=<P>; R=/restore; mkdir -p $R; T0=$(date +%s)
   TS=$(rclone $C lsf ${X}daily --include "$P-manifest-*" | sed -E "s/^$P-manifest-(.*)\.txt$/\1/" | sort | tail -n 1)
   rclone $C copy ${X}daily/ $R/set --include "$P-*-$TS.*"
   mariadb -e "CREATE DATABASE <DB> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
   zstdcat $R/set/$P-db-$TS.sql.zst | mariadb --max-allowed-packet=1G <DB>
   mariadb -N <DB> -e "SELECT CONCAT('users=',(SELECT COUNT(*) FROM mdl_user),' courses=',(SELECT COUNT(*) FROM mdl_course),' files=',(SELECT COUNT(*) FROM mdl_files))"
   grep rows_after_dump $R/set/$P-manifest-$TS.txt      # should match (taken seconds after the dump); prefix may differ from mdl_
   rclone $C copy ${X}filedir $R/moodledata/filedir --transfers 4 --checkers 4      # the one unavoidable full listing
   for d in $(rclone $C lsf --dirs-only ${X}filedir-deleted/ | tr -d /); do
     [[ "$d" > "$TS" || "$d" == "$TS" ]] && rclone $C copy "${X}filedir-deleted/$d" $R/moodledata/filedir --ignore-existing
   done
   mkdir -p $R/bundle && zstdcat $R/set/$P-config-$TS.tar.zst | tar -xf - -C $R/bundle
   cp -a $R/bundle/<D without leading slash>/. $R/moodledata/        # secret/, muc/, lang/, ...
   mariadb -N <DB> -e "SELECT contenthash FROM mdl_files WHERE filesize>0 ORDER BY RAND() LIMIT 200" \
     | while read -r h; do f=$R/moodledata/filedir/${h:0:2}/${h:2:2}/$h; [ -f "$f" ] && echo OK || echo "MISSING $h"; done | sort | uniq -c
   for s in $R/bundle/sqlite/*.sqlite; do [ -e "$s" ] && python3 -I -c "import sqlite3,sys; print(sys.argv[1], sqlite3.connect(sys.argv[1]).execute('PRAGMA integrity_check').fetchone()[0])" "$s"; done
   echo "RTO seconds: $(( $(date +%s) - T0 ))"
   ```
4. Optional application test: download the newest `code/` archive (`rclone $C lsf ${X}code/`, then
   `rclone $C copy ${X}code/ $R --include "$P-code-<stamp>.tar.zst"`) and extract it with
   `zstdcat $R/$P-code-<stamp>.tar.zst | tar -xf - -C /` (its members are the full code path without the leading
   `/`). For an old monthly set see D5: code snapshots go back only 29 days. config.php from the bundle with
   `$CFG->wwwroot` set to a test name (hosts-file entry), `$CFG->dataroot` to the restored moodledata, and
   **`$CFG->noemailever = true;`**; the DB user with the password from **this set's** config.php; web server and PHP
   from the bundle's configs; **no cron lines**. Log in as admin, open one course.
5. Write down: date, set used (RPO = its age), RTO, problems. Log entry on production (read-only drill).
6. **Owner**: destroy the drill server **and its volumes**; revoke the drill credentials.

If files are missing, the mirror lost something: check `filedir-deleted/` (C3) and the slice warnings before anything else.

## C. Partial restores on production (owner go-ahead each time; these are changes, log them)

C1. **One config file** (example: the web server vhost):
```bash
sudo -i
C="--config /var/lib/<NAME>/rclone/rclone.conf"; X=<NAME>-crypt:; W=$(mktemp -d /var/backups/<NAME>/restore.XXXX)
rclone $C copy ${X}daily/ $W --include '<P>-config-<run>.tar.zst'
zstdcat $W/<P>-config-*.tar.zst | tar -xf - -C $W etc/nginx/sites-available/<vhost>
diff -u /etc/nginx/sites-available/<vhost> $W/etc/nginx/sites-available/<vhost>
# then the change protocol: back up the live file, copy, nginx -t, reload, verify; rm -rf $W
```
Another app's SQLite works the same way (`sqlite/<app>.sqlite`): stop that app's writers first, keep the current file.

C2. **One table** into a scratch database (never into production directly):
```bash
TS=<run>; T=mdl_course_sections; DBR=restore_$(date +%Y%m%d)
rclone $C copy ${X}daily/ $W --include "<P>-db-$TS.sql.zst"
mariadb -e "CREATE DATABASE $DBR CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
zstdcat $W/<P>-db-$TS.sql.zst | sed -n "/^-- Table structure for table \`$T\`/,/^-- Table structure for table \`/p" \
  | mariadb --default-character-set=utf8mb4 --max-allowed-packet=1G $DBR
# compare / copy the needed rows into production with a reviewed SQL statement (owner approval), then:
mariadb -e "DROP DATABASE $DBR"; rm -rf $W
```

C3. **A deleted file** (content hash from the `files` table, e.g. from the scratch table in C2):
```bash
H=<40-hex contenthash>
rclone $C lsf "${X}filedir/${H:0:2}/${H:2:2}/" --include "$H"                      # still mirrored?
for d in $(rclone $C lsf --dirs-only ${X}filedir-deleted/ | tr -d /); do           # moved on which night?
  rclone $C lsf "${X}filedir-deleted/$d/${H:0:2}/${H:2:2}/" --include "$H" 2>/dev/null | sed "s#^#$d: #"
done
rclone $C copy "${X}filedir-deleted/<run>/${H:0:2}/${H:2:2}/" $W --include "$H"
F=<D>/filedir      # folder and file modes as the site uses (handbook); folders owned by the web user, not root
install -d -o <WEBUSER> -g <WEBUSER> -m 2770 "$F/${H:0:2}" "$F/${H:0:2}/${H:2:2}"
install -o <WEBUSER> -g <WEBUSER> -m 0660 $W/$H "$F/${H:0:2}/${H:2:2}/$H"
```
(`install -D` alone would create root-owned folders that Moodle cannot write.) Not in either place: SharePoint
recycle bin (site owner, 93 days; names are the encrypted ones) or the Purview Preservation Hold Library (site
collection admin, while the file is less than 30 days old). If the owner steps 4.4 test showed that Purview counts
from the file's own date, mirror files that were already old when uploaded are not there at all: then only the
recycle bin and the provider snapshots remain.

C4. **Backups deleted on the remote**: SharePoint, restore from the recycle bin (owner) or second stage (site
collection admin); filedir files come back by themselves at the slice's next turn ("uploaded again"); many missing:
`<NAME> --reconcile` once.

## D. Total loss (new server), outline

1. New server, same OS major. Web server, PHP version and modules (from `packages.txt` / `apt-manual.txt` in the
   bundle), the same DB server major, Redis if used, the MTA, rclone (same series), zstd, python3.
2. **Disable the timer on the old server** if it still runs. The owner recreates the rclone config with the setup
   script (new token or key, the SAME passphrases; the non-secret parameters are in the password-manager entry).
3. DB as in B3 (newest daily, or an older weekly/monthly). Create the Moodle DB user with the password from that set's
   config.php (MariaDB: the set's users dump holds the matching hash).
4. filedir from the mirror plus every `filedir-deleted/<run>/` with run **>= the set's stamp (same stamp included)**.
5. From the bundle: moodledata rest (secret/, muc/, lang/), `/etc` configs, crontabs, our plugin repos, other apps'
   `.env` and SQLite, `/etc/letsencrypt` if included (otherwise issue certificates again before `nginx -t` passes).
   Code from `code/`, or core from the git tag plus plugins (the manifest records release and git head).
   **Older sets:** `code/` keeps only the newest 4 snapshots (29 days), monthly sets 186 days. For an older monthly
   set use the newest code snapshot and then `admin/cli/upgrade.php` (Moodle upgrades an older DB; it never
   downgrades), or check out the git tag recorded in that set's manifest and add the plugins at their versions then.
6. Ownership and modes as the handbook records (`chown -R <WEBUSER>`, the site's directory/file permissions).
7. MTA credential: the owner enters it again (the MTA's credential file is never in the bundle). If Moodle ever sent
   mail directly, its `smtppass` setting is inside the DB dumps until it is cleared in Moodle (and in monthly sets
   for up to 186 days after that).
8. DNS / CDN to the new IP (owner). Purge Moodle caches, run cron once, check the site.
9. Install moodle-backup again, `--reconcile` once (after the final filedir copy; it uploads only what is missing),
   enable the timer when `--preflight` is clean. If the set predates a DB password rotation, rotate again now.
