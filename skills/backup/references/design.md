# moodle-backup: design

How the nightly encrypted off-provider backup works, why each part is the way it is, and what to do when a server
differs. Read this before proposing the backup to the owner or changing any setting.

## Contents
1. Goals and layout
2. The night run, step by step
3. Backend A: SharePoint document library (Microsoft 365)
4. Backend B: S3-compatible bucket (Cloudflare R2)
5. The filedir mirror and its guards
6. Retention and "immutability"
7. Alerting
8. Timing: quiet window, hard stop, apt window
9. Secrets and what is inside the encrypted backup
10. When the server differs (adapt, skip, stop)
11. Sizing formulas
12. Review findings built into this design (two rounds)
13. Known limits

## 1. Goals and layout

- **Off-provider**: the copy lives with a different company than the server (a DigitalOcean droplet backed up to
  Microsoft 365 or Cloudflare, not to DigitalOcean Spaces). The provider's own snapshots stay as a second layer.
- **Encrypted on the server** with rclone crypt (file names and contents). The storage provider cannot read it.
  Folder names stay readable so retention scripts and bucket rules can match prefixes.
- **Self-contained sets**: each night's DB dump travels with that night's config bundle (config.php, moodledata/secret,
  muc, lang, /etc configs). A restore never mixes sets, which matters after password rotations.
- **Nothing silent**: a failed, partial, slow or missing night reaches the owner (healthchecks.io).
- **Production first**: no table locks, low CPU priority, inside the measured quiet window, hard stop before the
  unattended-upgrades window.

Remote layout under the crypt remote `<NAME>-crypt:` (raw path `<library or bucket>/<folder>/...`):

| Folder | Written | Kept by policy |
|---|---|---|
| `daily/` | every night: `<P>-db-<run>.sql.zst`, `<P>-users-<run>.sql.zst` (MariaDB), `<P>-config-<run>.tar.zst`, `<P>-manifest-<run>.txt` (last) | 7 complete sets, min age 8 days |
| `weekly/` | same set, on the weekly day if the newest weekly is >= 48 h old, or whenever it is > 180 h old | 4, min 29 days |
| `monthly/` | same set, first successful run of a month | 6, min 186 days |
| `code/` | `<P>-code-<run>.tar.zst` (code tree without .git), weekly and whenever the tree changed | 4, min 29 days |
| `filedir/` | content-addressed mirror of moodledata/filedir | current state |
| `filedir-deleted/<run>/` | files removed from moodledata, moved there by the night `<run>` | 186 days (= oldest monthly), and longer while a kept set needs it |
| `keycheck/` | `<P>-keycheck.txt`: one small encrypted object written at setup (or by the first run) | forever; never a lifecycle or lock rule |

`<P>` is `SET_PREFIX` (default `moodle`); `<run>` is `YYYYMMDD-HHMM` server local time. One folder per server:
**two servers must never write to the same folder**, each would move the other's new files into `filedir-deleted/`.

## 2. The night run, step by step

1. **Preflight**: tools, settings, rclone config (directory writable), crypt passphrases open what is already there
   (rclone silently hides names it cannot decrypt, so a wrong passphrase looks like an empty folder and would start a
   second key domain), HC_URL, filedir non-empty (mount accident), flock, free space, enough time left.
   **Passphrase proof**, cheapest first: the `keycheck/` object reads back; otherwise one name in `daily/`, `weekly/`,
   `monthly/` or `code/` decrypts to the naming pattern. Both passphrases feed the one key that encrypts names and
   contents, so one decrypted name proves both. **Never "a manifest exists"**: an interrupted first upload (objects,
   no manifest yet) would then look like wrong passphrases on every later night, and retention (which would clean the
   partial set) never runs. A run that proved the passphrases without the keycheck object writes it.
2. **DB dump**: `mariadb-dump`/`mysqldump --single-transaction --quick --hex-blob --routines --events --triggers
   --default-character-set=utf8mb4 --max-allowed-packet=1G <db> | zstd -3`. No `--databases`: the dump has no
   `CREATE DATABASE`/`USE`, so a restore must name its target and can never overwrite production by accident.
   Checks before any upload: `zstd -t`, the `-- Dump completed` trailer, `CREATE TABLE` count equals the
   information_schema count, shrink guard against the last successful run. MariaDB accounts via `--system=users`
   when the dump tool supports it.
3. **SQLite of other apps** (optional, owner decision): SQLite online-backup API through python3, `PRAGMA quick_check`.
4. **Config bundle** (tar.zst): config.php, moodledata minus `filedir cache localcache temp sessions trashdir lock`
   (keeps `secret/`, without which encrypted Moodle settings cannot be restored), the `CONFIG_PATHS` rendered for this
   server, these scripts and defaults, crontabs, handbook and log, package lists. MTA credential files and rclone
   configs are excluded, and the run fails if one appears in the listing.
5. **Upload** to `daily/`, manifest last (commit marker); weekly and monthly by age, never by calendar alone. The
   weekly/monthly/code folders are listed only after the daily upload, and a listing or upload error there fails the
   night but no longer costs the daily set or stops the filedir steps. No weekly or monthly copy starts with less
   than 15 min left (the age rules make it the next night).
6. **Code** snapshot when due (weekly, older than 7.5 days, or any file's ctime newer than the last upload: rsync -a
   keeps mtimes but cannot keep ctimes, so ctime catches plugin installs and upgrades mid-week).
7. **filedir mirror** (section 5).
8. **Retention** (section 6).
9. **Token write-back check** (SharePoint), local cleanup (keeps the newest 2 **complete** local sets; leftovers of
   failed nights never count), status file `/var/lib/<NAME>/status`, heartbeat.

A stop or timeout (systemd sends TERM to the whole unit) is reported by the script itself: the `tee` that copies the
output into the run log ignores TERM, so the script is not killed by SIGPIPE before its trap removes a partial dump
and pings `/fail` (exit 143). `<NAME>-alert.service` (`OnFailure=`) alerts as well.

The DB dump is taken before the filedir steps, so every file the dump references is either already in the mirror or
still on local disk when the mirror runs.

## 3. Backend A: SharePoint document library (Microsoft 365)

Use when the organisation already pays for Microsoft 365 (no new bill). Needs a tenant admin for consent and Purview.

- **Remote**: `[m365] type = onedrive, region = global, drive_type = documentLibrary, drive_id = b!..., token = {...}`
  and `[<NAME>-crypt] type = crypt, remote = m365:<folder>, filename_encryption = standard,
  directory_name_encryption = false, filename_encoding = base32`. Written by `owner-setup-sharepoint.sh`. The library
  lookup uses Graph `/sites/...` and `/drives/...` only: **no `GET /me`**, which needs `User.Read`, a scope rclone's
  default app does not request (Graph answers 403 and the owner is stuck at "access denied"). The signed-in account is
  decoded from the token itself.
- **Token**: a *delegated* OAuth token from `rclone authorize "onedrive"` on the owner's PC, signed in as a dedicated
  backup account with Contribute on one site only. rclone 1.60.x has no app-only (client-credentials) flow for
  OneDrive. Microsoft rolls the refresh token on every refresh and rclone writes it back into the config (temp file +
  rename in the same directory). With a read-only directory rclone only logs `Failed to save config after 10 tries`
  and **still exits 0**, so the config lives under `/var/lib/<NAME>` (a systemd `StateDirectory`, writable in the
  sandbox), never under `/root` (`ProtectHome`), and every run checks the file was rewritten within 3 h.
- **Refresh tested at setup**: the pasted access token is fresh, so nothing in a normal setup makes rclone refresh it.
  The setup script forces one refresh (expiry set to the past, one listing, the expiry must be rewritten and the file
  still 0600). Without it, a refresh that Microsoft refuses (rclone's built-in client secret no longer accepted, a
  Conditional Access policy) or that rclone cannot save would only show hours later, in the middle of the seed.
- **No full listing at night**: rclone 1.60.x has no `ListR` for OneDrive (`--fast-list` does nothing) and every
  folder costs one Graph call. filedir has up to 65,536 `ab/cd/` folders; tens of thousands of requests do not fit a
  night and invite throttling. Hence the model-based mirror with 16 slices (section 5).
- **Throttling**: `--tpslimit 8 --tpslimit-burst 1 --transfers 4 --checkers 4`, `--onedrive-chunk-size 20M`
  (a multiple of 320 KiB, below 250M), retries with sleep; in rclone 1.60 the OneDrive pacer honours `Retry-After` on
  429 only and retries 503 with exponential backoff. User agent
  `NONISV|<org>|moodle-backup/<version>`, the decoration Microsoft asks bulk tools to use.
- **Names**: rclone's base32 is lowercase `0-9a-v`: safe on case-insensitive SharePoint, no forbidden characters,
  never a reserved name; a 40-character content hash becomes about 77 characters, far below the 400-character limit.
- **Versions**: names never change and nothing is overwritten (unique stamps, same-minute run refused,
  content-addressed filedir), so each file has one version. Library setting "Require check out" must be off.
- **Deletes** go to the site recycle bin (93 days, counted in tenant storage). rclone 1.60.x has no hard delete for
  OneDrive; even if it had, the recycle bin is the safety net for a retention bug.
- **Token events** (a revoked or expired token ends in a failed night that healthchecks reports; the error line and
  the healthchecks body carry the Microsoft code, e.g. `invalid_grant`, `AADSTS50173`, never token text):
  "Revoke sessions", disabled account, removed licence or site access, MFA reset, Conditional Access (sign-in
  frequency, **location** policies that do not know the server's IP, which changes when the server moves, **device
  compliance** policies: the server is not a managed device), 90 days unused, consent withdrawn. Fix:
  `owner-setup-sharepoint.sh --renew-token` (passphrases untouched). It accepts only a token of the **same account**
  (the old token's `oid`, else its user name, is decoded from the config): an admin's token pasted by mistake would
  leave the server with a delegated `Files.ReadWrite.All` token for everything that admin can reach.
- **Password change: not certain to revoke the token.** rclone's built-in app sends a client secret, so Microsoft
  probably treats it as a confidential client, whose refresh tokens Microsoft's revocation rules can keep valid after a
  password change. Hence: after an ordinary change run `--preflight` and renew only if it fails; after a **suspected
  leak** the order is Entra → **Revoke sessions** (cuts every refresh token), then the password change, then
  `--renew-token`. A password change alone may leave a stolen token working.
- **Reach of the token**: everything the backup account can reach: the backup site, but also whatever is open to the
  whole organisation (public Teams / Microsoft 365 group sites, files shared with "Everyone except external users",
  which includes this account). Tell the owner; nothing sensitive should be shared with "everyone".

## 4. Backend B: S3-compatible bucket (Cloudflare R2)

Use when there is no Microsoft 365 tenant, or the owner prefers object storage with server-independent lock rules.
R2 is the design target (no egress fees, lifecycle + bucket lock rules per prefix). Other S3 providers work with
`provider = Other`, but check their lock and lifecycle semantics before relying on them (stop and ask).

- **Remote**: `[s3] type = s3, provider = Cloudflare, region = auto, endpoint = https://<account>.r2.cloudflarestorage.com`
  (`.eu.` for an EU-jurisdiction bucket), `no_check_bucket = true` (a bucket-scoped key cannot list or create
  buckets), plus the same crypt section with `remote = s3:<bucket>/<folder>`. Written by `owner-setup-s3.sh`.
- **Listing is cheap** (1000 objects per request), so `SLICES=1`: the whole filedir is synced every night with
  `--fast-list`, still guarded by the same local checks.
- **Lifecycle rules** (bucket settings, per prefix): `daily/` 8 days, `weekly/` 29, `monthly/` 186, `code/` 29,
  `filedir-deleted/` 186; abort incomplete multipart uploads after 1 day. Never a rule on `filedir/` or `keycheck/`.
- **Lock rules**: each prefix locked for one day less than its lifecycle (daily 7, weekly 28, monthly 185, code 28).
  Never lock `filedir/`, `filedir-deleted/`, `canary/`, `keycheck/` or the whole bucket: the mirror needs deletes and
  moves.
- **Retention mode `check`**: the bucket deletes by age; the script reports, and with `--lifecycle` flags sets that
  outlived their rule. Trade-off: age-based deletion would also remove the last good sets if backups stopped for
  weeks; the heartbeat is what catches a stop. `RETENTION_MODE=apply` (script deletes, no lifecycle rules) is the
  alternative; then the script's minimum ages must stay above the lock periods.
- **Lock removal**: any admin of the Cloudflare account can remove a lock rule. The real protection is the account
  login: 2FA mandatory, two admins, the server key is Object Read & Write on one bucket only (it cannot change rules).

## 5. The filedir mirror and its guards

filedir is content-addressed (file name = SHA-1 of the content, path `ab/cd/<hash>`), so a size-only compare is exact
and a file never changes in place.

- **Model**: `/var/backups/<NAME>/filedir-state/remote.list` is the sorted list of paths believed to be on the
  remote. `--reconcile` builds it: one listing of the whole mirror (on SharePoint about one request per folder, so
  tens of minutes when full), then only the missing files (`--files-from-raw --no-traverse`, nothing listed twice),
  no deletions, resumable. The model becomes **local ∪ mirror**: mirror files missing locally stay visible to the
  night guards. **More than `MAX_DELETE` of them = it stops** ("finish copying filedir first"): with a filedir copied
  only in part (a server move, an rsync still running) the model would otherwise be the partial local list, every
  guard would pass, and the slice syncs would move the missing files to `filedir-deleted/` night after night without
  an alert (review finding S2, reproduced). Fewer = a warning, and the slice syncs move them (counted against
  `MAX_DELETE`). Run it only after the **final** filedir copy.
- **6a new files**: `comm -23 local model` → `rclone copy --files-from-raw --no-traverse`, in batches of 1000, model
  updated after each batch. About 3 requests per new file, no listing. A `chown -R` triggers nothing.
- **6b full sync of a slice**: `SLICES=16` syncs the folders starting with hex digit `day number mod 16` (about
  1/16 of the listings, the whole mirror verified every 16 nights); `SLICES=1` syncs everything. `sync --include
  <slice> --size-only --backup-dir filedir-deleted/<run> --max-delete MAX_DELETE`. Files missing remotely are uploaded
  again and reported as a warning (drift: deleted there by someone or something).
- **Guards, computed locally before anything moves** (review finding B1: `--max-delete` alone moves N files and only
  then fails, so a half-empty filedir drains the mirror by N files a night):
  1. total local files < last good total − MAX_DELETE → slice sync skipped, mirror untouched;
  2. slice files < last good slice count − MAX_DELETE → skipped;
  3. expected removals (model minus local, in the slice) > MAX_DELETE → skipped;
  4. `--max-delete` stays on the sync as the last line.
  Each skip fails the night on purpose (exit 1, healthchecks). After a checked, real mass deletion: set `MAX_DELETE`
  higher for one run in `/etc/default/<NAME>`, then comment it out.
- **Shrink guard**: a dump smaller than `MIN_SHRINK_PCT` (70 %) of the last good one is still uploaded to `daily/`
  (a copy never hurts older sets), but weekly/monthly and the slice sync are skipped and the night fails. Override for
  one run with `MIN_SHRINK_PCT=0` after checking (for example after a course clean-up).
- **Restore rule**: files removed between night D's dump and night D's sync land in `filedir-deleted/<D>/`. A restore
  of set D copies every `filedir-deleted/<run>/` with run **>= D, the same stamp included**.

## 6. Retention and "immutability"

`<NAME>-retention` groups objects by run stamp. Only complete sets (db + config + manifest) count toward KEEP; an
incomplete set (failed upload) is reported and never pushes a good set out; the newest KEEP complete sets are never
deleted; older sets only after their minimum age. A listing error is a problem, never "empty".

What protects the backups if the server (root) is compromised:

| Layer | SharePoint | R2 |
|---|---|---|
| Server credential scope | backup account, Contribute on one site (plus whatever is shared with the whole organisation) | Object Read & Write on one bucket |
| Protected period | Purview retention policy on the backup site: retain 30 days from creation, then do nothing (tenant admin). A deleted or overwritten object stays **recoverable from the site's Preservation Hold Library** until it is 30 days old. Not "undeletable": the live copy can be deleted; the held copy is what remains | bucket lock rules per prefix (lifecycle − 1 day): deletes are refused |
| After deletion | site recycle bin 93 days; the second stage needs a site collection admin | none (lifecycle deletes for good) |
| Rules changeable by the server? | no (a site collection or tenant admin can change the policy; **Preservation Lock** prevents that but is irreversible, even for Microsoft support: owner decision) | no (any admin of the account can remove a lock rule) |
| Provider snapshots | yes, independent | yes, independent |

Retention keeps a `filedir-deleted/<run>/` folder past 186 days while a kept complete set is older than it (a restore
of that set needs every folder with run >= its stamp; this only happens after monthly uploads failed for a while), and
prunes none of them on a night when a set folder could not be listed. While the dump is flagged as shrunk, retention
only reports, so the dailies from before the shrink cannot age out unchecked.

**Purview: three things to verify on each tenant** (owner steps 4.4; until then assume the worse case):
1. **Which date counts as "created".** rclone 1.60 sends each file's modification time as its creation time. If
   Purview counts from that date, mirror files that were already older than 30 days when uploaded (the seed, any
   re-upload of an old Moodle file) are **not held at all**: they are covered only by the recycle bin and the
   provider snapshots. Dumps, bundles and code are always new files. Test: an old-dated canary.
2. **Emptied folders must stay removable.** rclone `sync` removes `filedir/ab/cd/` folders that became empty; if the
   policy refused that, every slice night would fail. Test: write, delete and `rmdir` a canary folder; the timer is not
   enabled before that test prints `rmdir OK`, and the first nights' slice logs are watched for refused removals.
3. A fresh canary appears in the Preservation Hold Library (the policy is active).

## 7. Alerting

- **healthchecks.io** (`HC_URL`, required before the timer is enabled): `/start` at the beginning, success with the
  log tail, `/fail` with the WARN/ERROR lines on failure **and on warnings** (a run with warnings exits 0 but still
  alerts), no ping at all when the job did not run (server down, timer disabled): healthchecks then reports "down"
  after the grace time. Check: cron schedule = the timer time, server time zone, grace 90 min. Listing errors carry
  the provider's error code (`AADSTS…`, `invalid_grant`, `AccessDenied`) into the error line, so into the body.
- The URL is passed to curl as a config file on a pipe (`-K <(...)`), never in argv (readable by every local user via
  `/proc`), so the web user cannot read it and send fake success pings.
- **Mail** (optional): `MAIL_TO` + `MAIL_FROM` through the local MTA's `sendmail`. `MAIL_FROM` must be a sender the
  relay accepts (a verified domain at a transactional mail provider), otherwise the relay rejects it and nobody sees
  it. `sendmail` is called through the fixed PATH, never by absolute path (a harness mock must always intercept it).
  A dry run never mails. The "completed with warnings" mail is sent from **inside** the sandboxed unit: with
  `ProtectSystem=strict` the MTA cannot write its spool unless the unit lists it in `ReadWritePaths=` (exim:
  `/var/spool/exim4`, `/var/log/exim4`; Postfix: `/var/spool/postfix`), and the send fails with only a journal line.
  The rendered unit lists all three (`-` = ignored when absent). Exim with these paths is the reviewed case; Postfix's
  `postdrop` path inside the sandbox is untested, so on Postfix treat the warning mail as best effort (healthchecks is
  the alert that counts).
- `<NAME>-alert.service` (`OnFailure=`) also covers timeouts and kills that the script's own trap cannot report.

## 8. Timing: quiet window, hard stop, apt window

- Measure the quiet window first (audit module, requests per hour over 14 days). Start the timer early in it
  (e.g. 30 min after it opens), `RandomizedDelaySec=5min`, `AccuracySec=1s` (the 1 min default can add a minute and
  push the unit's hard stop into the apt window), `Persistent=false` (a missed night alerts instead of dumping in
  working hours after a reboot).
- The unattended-upgrades window can restart the DB server mid-dump. Place the backup so that its hard stop
  (`HARD_STOP` + 5 min = unit timeout) ends before the apt window, and add `After=apt-daily-upgrade.service`.
  The maintenance module moves apt into the quiet window after the backup (for example: backup 02:30, hard stop
  03:40, apt 03:45 + 15 min random); render-install.sh warns when they overlap.
- No Moodle upgrade, plugin install or other DDL during the dump window: DDL breaks `--single-transaction`
  consistency (the table-count check catches added or dropped tables, not altered ones).
- Each rclone step gets `--max-duration` ending before the deadline; rclone 1.60 reports that as a fatal error
  (exit 7) and the script recognises it. A sync stopped by time or kill deletes nothing (deletions run after
  transfers).

## 9. Secrets and what is inside the encrypted backup

- The server holds: the rclone config (token or keys + the two passphrases, obscured = reversible, so the file itself
  is the secret: root 0600 in a 0700 directory). The owner writes it with the setup script; Claude never sees it.
- The owner runs the setup script **as root**, so it must come from a root-owned copy (`/usr/local/share/<NAME>/`,
  installed in step 1) and the owner compares its sha256 with the value Claude gives him in the chat. Never from a
  folder the operator account (and so every Claude session) can write.
- The encrypted bundle holds by design: config.php (DB password), the Redis password (config.php / muc config),
  moodledata/secret, other apps' `.env` if listed, `/etc/letsencrypt` private keys if chosen. They are protected only
  by the two passphrases. Moodle's own `smtppass` (if Moodle ever sent mail directly) is inside the DB dump until
  cleared, and stays in monthly copies for up to 186 days after that.
- Never in the bundle: MTA credential files (`passwd.client*`, `sasl_passwd*`, including every `.bak`/`.dpkg` copy),
  rclone configs. The run fails if one appears.
- The passphrases never change in place (older backups open only with the old ones). If they leak: new folder, new
  passphrases, `--reconcile`; keep the old ones until the old sets age out (186 days).
- Losing both passphrases makes every backup unreadable: password manager entry shared by two people, plus an
  offline copy. Losing a token or key is harmless (renew).

## 10. When the server differs (adapt, skip, stop)

| Situation | Action |
|---|---|
| Moodle 4.x / 5.0 (no `public/`) | supported: version.php is read from `<MOODLE>` or `<MOODLE>/public` automatically |
| MySQL instead of MariaDB | supported with `mysqldump`/`mysql`; no `--system=users` (DB accounts not dumped: recreate the Moodle DB user from config.php on restore). With GTID on, mysqldump may need `--set-gtid-purged=OFF`: test with `--dry-run` first |
| DB on another host / managed DB | root over the socket does not work: the owner writes a root-only option file and `DB_DEFAULTS_FILE` names it; check the dump user's grants (SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES not needed with single-transaction) |
| Non-InnoDB tables in the Moodle DB | `--single-transaction` is not consistent for them: stop and ask (convert or accept) |
| **PostgreSQL** | **stop and ask.** The script refuses `pgsql`. An adaptation needs `pg_dump -Fc --no-owner` (consistent snapshot by default), checks with `pg_restore --list` (table count vs `information_schema`), and the roles via `pg_dumpall --roles-only`. Write it as a separate reviewed change, tested in a harness, never improvised on the night |
| Apache instead of nginx, Postfix instead of exim | render-install.sh lists whatever exists (`/etc/apache2`, `/etc/postfix`); `sasl_passwd*` is excluded like exim's `passwd.client*`. The unit already lists `/var/spool/postfix` for the optional warning mail; untested there (section 7) |
| No MTA | leave `MAIL_TO` empty; healthchecks is the alert |
| Tenant with Conditional Access (location, device, sign-in frequency) | exclude the backup account, or allow the server's IP (and the new one after a move); the setup's forced refresh shows a refusal on day one |
| No systemd sandbox support (very old systemd) | remove the unsupported `Protect*` lines one by one after `systemd-analyze verify` complains; keep `ProtectSystem`, `ProtectHome`, `StateDirectory` |
| rclone older than 1.58 | `filename_encoding` does not exist: install the distribution's newer rclone or the official build (owner approval); the scripts require base32 written explicitly |
| rclone newer than 1.60 | expected to work (flags are stable); `--onedrive-delta`/ListR may exist, but the design does not depend on them. Run the harness tests and a dry run first |
| Two Moodle sites on one server | two installs with different `--name` and `--set-prefix`, different folders, timers 30+ min apart |
| Very large filedir (> 500 GB) or slow upload | seed over several days with `--reconcile HOURS`; check that a normal night's new files fit the window |
| Site not behind its own provider snapshots | the off-provider backup is then the only layer: insist on the monthly integrity check and the quarterly drill |

## 11. Sizing formulas

Fill these from `discover.sh`; do not reuse another server's numbers.

- Compressed dump ≈ 0.15–0.25 × (data + index) of the DB (zstd -3 on Moodle SQL); dump time ≈ 30–60 s per GB of DB.
- Live remote size ≈ filedir + (7 + 4 + 6 + up to 3 extra) × compressed set + 4–5 × code archive + filedir-deleted.
- SharePoint recycle bin ≈ 93 × (daily deletes per day ≈ one set + weekly/monthly share); Purview holds each item up
  to 30 days more. Budget 3–7 × the live size on SharePoint, 1.1–1.3 × on R2.
- Seed time: SharePoint is request-bound (≈ 2–3 requests per file + one per new folder at ≤ 8 requests/s); R2 is
  bandwidth-bound.
- A normal night: dump + checks + one set upload + new files + slice + retention; Fridays and the 1st add one or two
  set uploads and the code archive. It must end well before the hard stop; if not, move the timer earlier or lower
  the work (fewer slices per night is not an option below 1/16; raise TPSLIMIT only without 429s).

## 12. Review findings built into this design (two rounds)

The first server's package was reviewed in two rounds, each with a safety and a secrets review. Every finding of
both rounds is in the scripts. First round (the first draft):

| Finding | Where it lives now |
|---|---|
| B1 `--max-delete` drains the mirror N files a night | local guards (total, slice, expected removals) before any move; `--max-delete` as backstop |
| B2 backup slot collided with the apt window | hard stop + unit timeout end before the apt window; `After=apt-daily-upgrade.service`; render-install.sh warns on overlap |
| S1 failure mail without a valid sender | `MAIL_FROM`, `From:` header and `sendmail -f`; preflight warns without it |
| S2 incomplete sets counted toward "keep N" | manifest uploaded last; retention counts only db+config+manifest sets; staleness on the newest complete set |
| S3 code snapshot up to a week older than the DB | code uploaded weekly, when > 7.5 days old, or when any file's ctime is newer than the last upload |
| S4 calendar-based weekly/monthly leave gaps; listing errors read as "empty" | age-based weekly/monthly; listing errors stop the run |
| S5 shrink guard threw the night away | set still uploaded to `daily/`; risky steps skipped; exit 1; `MIN_SHRINK_PCT=0` override |
| S6 a night that never starts was not detected | HC_URL required for real runs and the timer; healthchecks "no ping" |
| S7 restore docs skipped the same-night `filedir-deleted` | restore uses every `filedir-deleted/<run>` with run >= set stamp, same stamp included |
| S8 bundle missed rebuild essentials | render-install.sh adds the scripts, defaults, apt.conf.d, sysctl.d, limits.d, sshd_config.d, sudoers.d, aliases, mailname, letsencrypt (owner choice) |
| S9 warnings never alerted | warnings → healthchecks `/fail` with the WARN lines (+ mail) |
| Secrets 1: wrong passphrases passed the setup test | setup and every run: objects in `daily/` that do not decrypt → FAIL/refuse; reconcile refuses too |
| Secrets 2: rebuild settings only on the server | crypt options written explicitly; non-secret parameters printed for the password manager; script and docs installed in `/usr/local/share/<NAME>` and inside the bundle |
| Secrets 3–5: exits between hidden prompts, `bash -x`, invisible characters | every prompt asks again (empty lines and CR ignored); `set +x` first; strict passphrase regex; `unset HISTFILE` advice |
| Secrets 6: short locks, lock removable by an admin | R2 lock = lifecycle − 1 day per prefix; 2FA mandatory, two admins; Purview + recycle bin on SharePoint |
| Secrets 7: MTA credential inside the bundle | `passwd.client*` / `sasl_passwd*` excluded including `.bak` copies; listing check fails the run |
| Nits | `HOME=/root` + unset `MYSQL_*`; same-minute set refused; dry run removes only its own set; partial dump removed; lock busy → exit 0 without a ping; `.tmp` removed on any exit; canary delete result checked; failed setup removes its config; HC URL via `-K`; git runs as the `.git` owner with a clean env; HEAD read from the file; two-server warning in setup; S3 read-only drill key checked to be read-only; over-broad key warned |
| Ops log: a harness sent real mail through an absolute `/usr/sbin/sendmail` | every tool through the fixed PATH; harness aborts if a mocked tool appears with an absolute path |

Second round (the reviewed draft; also applied here):

| Finding | Where it lives now |
|---|---|
| `GET /me` blocks the SharePoint library lookup (needs `User.Read`, not in rclone's scopes) | removed; the account comes from the token. Harness: the mock Graph answers `/me` with 403 |
| A first set without a manifest blocks every later night and blames the passphrases | passphrases proven by the `keycheck/` object or one decrypted name in daily/weekly/monthly/code, never by "a manifest exists"; same in the setup scripts; `--reconcile` checks too; also catches "daily/ empty but other folders exist" |
| `--reconcile` with a partly copied filedir lets the slice syncs drain the mirror silently | one mirror listing; stop when more than `MAX_DELETE` mirror files are missing locally; upload only what is missing; model = local ∪ mirror; docs: only after the final filedir copy |
| Warning mails cannot leave the sandbox | MTA spool/log paths in `ReadWritePaths=` (unit and the install `S` array) |
| Setup never exercised a token refresh | `t_refresh` in every SharePoint setup mode: expiry set to the past, one listing, expiry rewritten, file still 0600 |
| SIGTERM at the timeout killed the script through SIGPIPE (no `/fail` of its own, partial dump left) | the `tee` ignores TERM/INT; the exit handler appends its own lines; harness: exit 143, `/fail`, partial dump removed |
| `--renew-token` accepted another account's token | the old token's `oid` (else user name) must match; otherwise asked again |
| Purview: emptied folders and the "created" date | owner steps 4.4: old-dated canary and folder-removal test; timer only after `rmdir OK`; docs say "recoverable from the Preservation Hold Library" and that old mirror files may not be held |
| A password change may not revoke the token | ordinary change: `--preflight` first; leak: Revoke sessions → password → renew |
| Harness guard grep matched a comment, and the suite ignored a failing build step | comments stripped before the grep, PATH patch asserted, a failing build stops the suite; suites run in a no-network sandbox |
| Nits (code) | `die` to stderr; weekly/monthly/code listings after the daily upload and not fatal; no weekly/monthly copy with < 15 min left; `AccuracySec=1s`; retention only reports while the dump is shrunk; `filedir-deleted/` kept while a kept set needs it (not pruned after a listing error); a dry run never mails; provider error codes in the error line; local cleanup keeps the 2 newest **complete** sets; `setup-errors.log` removed on exit; weekly/monthly/code upload failures no longer stop the filedir steps |
| Nits (docs) | Retry-After on 429 only; "no access to other sites" corrected; Conditional Access location/device; both token paste forms (JSON and base64); setup script run from a root-owned copy with its sha256; restore docs: `tar -C /` for the code archive, `sudo -i` on its own line, folders created with the web user as owner, MTA/SMTP secrets still inside DB dumps until cleared in Moodle, code snapshots only 29 days back for old monthly restores |
| Rejected for now: server-side copy for weekly/monthly | in rclone 1.60 a OneDrive server-side copy is an asynchronous Graph job that rclone polls; its duration on SharePoint is unmeasured and untested. The re-upload costs one set size on a few nights a month; revisit once real nights show the upload speed |

## 13. Known limits

- Real SharePoint/Graph throttling and real R2 behaviour are not covered by the harness: the first seed and the
  first real night are the real test (say so in the report).
- Answered on day one per tenant, not by the harness: whether Microsoft still accepts rclone's built-in client secret
  for refresh (setup `t_refresh`), which date Purview counts from (old-dated canary), whether Purview lets an emptied
  folder be removed (folder test), and whether Conditional Access blocks the server.
- Point-in-time recovery is not provided (RPO up to 24 h). Binary logs would add it; that needs a DB restart in a
  maintenance night and its own design.
- The bundle copies `config.php` with secrets; anyone with both passphrases can read them. That is the price of a
  restore that works without the old server.
