# moodle-backup: install, operations, rollback

Every numbered step that changes the server needs the owner's go-ahead at that moment and an operations-log entry.
`<NAME>` is the install name (default `moodle-backup`), `<P>` the set prefix (default `moodle`).

## Contents
1. Before installing
2. Install steps 0–9
3. Rollback
4. Daily and weekly operations
5. What the healthchecks messages mean
6. Mass deletion, shrunken dump, drift
7. Maintenance nights
8. Server move
9. Password and key changes

## 1. Before installing

- Discovery done (`scripts/discover.sh`), quiet window measured, apt window known, owner decisions recorded: backend,
  retention (default 7/4/6), weekly day, alerting, extra paths (other apps' SQLite and `.env`, `/etc/letsencrypt`).
- Owner steps done (Arabic): `owner-steps-sharepoint-ar.md` 0–6 or `owner-steps-s3-ar.md` 0–5. Nothing on the server
  needs the owner's secrets except his own run of the setup script.
- Render the install tree (changes nothing):
  ```bash
  bash scripts/render-install.sh --backend sharepoint --at 02:30 --hard-stop 03:40 --out /tmp/<NAME>-render
  # s3: --backend s3. Add --sqlite app=/path/db.sqlite --extra /var/www/app/.env as decided.
  ```
  Read the printed WARNINGS (apt overlap, missing handbook/log) and `/tmp/<NAME>-render/INSTALL.txt`.

## 2. Install steps

`R=/tmp/<NAME>-render` (the render output). Commands as the operator with sudo.

**0. Pre-checks (read-only)**
```bash
command -v rclone zstd python3 curl flock setpriv && rclone version | head -1
ls /usr/local/sbin/<NAME>* /etc/systemd/system/<NAME>* /etc/default/<NAME> 2>&1     # none yet
df -h /var/backups
```
Missing rclone/zstd: a package install is a change (owner approval, log entry): `sudo apt-get install rclone zstd`.

**1. Install files** (new files only, so no backup is needed; the timer stays disabled)
```bash
sudo install -o root -g root -m 0700 $R/usr/local/sbin/<NAME> $R/usr/local/sbin/<NAME>-retention /usr/local/sbin/
sudo install -d -o root -g root -m 0755 /usr/local/share/<NAME>
sudo install -o root -g root -m 0644 $R/usr/local/share/<NAME>/* /usr/local/share/<NAME>/
sudo install -o root -g root -m 0600 $R/etc/default/<NAME> /etc/default/<NAME>
sudo install -o root -g root -m 0644 $R/etc/systemd/system/<NAME>.service $R/etc/systemd/system/<NAME>.timer \
     $R/etc/systemd/system/<NAME>-alert.service /etc/systemd/system/
sudo install -d -o root -g root -m 0700 /var/backups/<NAME>
sudo bash -n /usr/local/sbin/<NAME> && sudo bash -n /usr/local/sbin/<NAME>-retention && echo syntax-ok
sudo systemd-analyze verify /etc/systemd/system/<NAME>.service /etc/systemd/system/<NAME>.timer /etc/systemd/system/<NAME>-alert.service
sudo systemctl daemon-reload
sha256sum /usr/local/share/<NAME>/owner-setup-*.sh       # give the value to the owner in the chat
```
Why the hash: the owner runs the setup script as root. It must be the root-owned copy, never a file in a folder the
operator account (and so every Claude session) can write, and the owner compares the hash before running it.

**2. Owner: rclone config.** In his own SSH session (never the terminal Claude reads):
```bash
unset HISTFILE
sha256sum /usr/local/share/<NAME>/owner-setup-sharepoint.sh                     # must match the value from step 1
sudo bash /usr/local/share/<NAME>/owner-setup-sharepoint.sh --name <NAME>     # or owner-setup-s3.sh --name <NAME>
```
Expected: `All tests passed`. On SharePoint the tests include one forced token refresh (`token refresh works`) and,
on a first install, the keycheck object. Then Claude checks only names and modes:
```bash
sudo stat -c '%U %a %n' /var/lib/<NAME>/rclone /var/lib/<NAME>/rclone/rclone.conf      # root 700, root 600
sudo rclone listremotes --config /var/lib/<NAME>/rclone/rclone.conf                   # m365: or s3:, <NAME>-crypt:
```
Never `cat` the config, never `rclone config show`.

**3. HC_URL (owner) and preflight.** The owner runs `sudoedit /etc/default/<NAME>`, removes the `#` before `HC_URL=`
and pastes the URL. Then:
```bash
sudo /usr/local/sbin/<NAME> --preflight     # OK everywhere except "no filedir mirror state"; a /log event appears in healthchecks
```

**4. Seed** (first full upload; outside the timer window once the timer is on; any hour before that)
```bash
# S = exactly the unit's sandbox (also used by the dry run, so the dry run tests the sandbox)
S=(-p Nice=10 -p CPUWeight=20 -p MemoryHigh=2G -p MemoryMax=3G -p ProtectSystem=strict -p ProtectHome=read-only
   -p PrivateTmp=yes -p StateDirectory=<NAME> -p StateDirectoryMode=0755
   -p "ReadWritePaths=-/var/backups/<NAME> -/var/spool/exim4 -/var/log/exim4 -/var/spool/postfix"
   -p NoNewPrivileges=yes -p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p ProtectControlGroups=yes
   -p RestrictSUIDSGID=yes -p LockPersonality=yes -p ProtectClock=yes -p ProtectHostname=yes -p ProtectKernelLogs=yes
   -p RestrictRealtime=yes -p SystemCallArchitectures=native -p UMask=0077)
sudo systemd-run --unit=<NAME>-seed --collect "${S[@]}" /usr/local/sbin/<NAME> --reconcile 8
sudo journalctl -fu <NAME>-seed          # stats every 10 min; ends with "reconcile complete"
```
- It first lists the mirror (one call when empty; on a full SharePoint mirror about one request per folder, tens of
  minutes), then uploads only what is missing. It stops if more than `MAX_DELETE` mirror files are missing from the
  local filedir ("finish copying filedir first"): run it only after the final filedir copy.
- Stopped by its time limit: start it again, it continues. To stop: `sudo systemctl stop <NAME>-seed` (a stopped sync
  deletes nothing).
- SharePoint: 429/503 lines with retries are throttling (rclone 1.60 waits for `Retry-After` on 429, backs off on
  503); if frequent, lower `TPSLIMIT` in the defaults file.
- Seed during the day only at low priority and if the upload does not saturate the uplink (`BWLIMIT`).

**5. Dry run at night** (a real dump, nothing uploaded)
```bash
sudo systemd-run --wait --collect --pipe --unit=<NAME>-dryrun "${S[@]}" /usr/local/sbin/<NAME> --dry-run 2>&1 \
  | grep -v 'Skipped' | tail -40
```
Expect `dump ok`, `bundle ok`, the table count, `<NAME> OK ... dry_run=1`. A dry run writes nothing remotely (not
even the keycheck object) and never mails.

**6. First real run** (owner go-ahead at that moment; at night)
```bash
sudo systemctl start --no-block <NAME>.service
systemctl show -p ActiveState,SubState,Result <NAME>.service    # poll every 1-2 min until ActiveState=inactive
systemctl show -p Result --value <NAME>.service      # success
cat /var/lib/<NAME>/status                           # last_ok = this run, warnings=0
```
Why `--no-block`: a run takes 10–30 min or more, and a Claude tool call stops waiting after 10 min; a blocking
`start` would look like a hang. healthchecks shows "start" then "success". The run log ends with
`keycheck object written` if setup had not written it.

**7. Verify (read-only)**
```bash
C="--config /var/lib/<NAME>/rclone/rclone.conf"
sudo rclone $C lsl <NAME>-crypt:daily                    # db, users (MariaDB), config, manifest of the run
sudo rclone $C lsf "$(sudo awk '/^\[<NAME>-crypt\]/{f=1;next} /^\[/{f=0} f && /^remote = /{print $3}' /var/lib/<NAME>/rclone/rclone.conf)/daily" | head -3   # encrypted names
sudo wc -l /var/backups/<NAME>/filedir-state/remote.list
```
SharePoint: never `rclone size` or `lsf -R` on `filedir` (one Graph call per folder). Then `restore-tests.md`
section A once, and the lock tests. SharePoint: the three Purview tests of owner steps 4.4 (fresh canary, old-dated
canary, emptied folder that must print `rmdir OK`), run by Claude with the owner's go-ahead; the owner checks the
Preservation Hold Library. If `rmdir` is refused, do **not** enable the timer: the slice sync removes emptied folders
and would fail every night. Watch the first nights' `/var/backups/<NAME>/logs/slice-*.log` for refused removals.
R2 lock canary:
```bash
echo x | sudo rclone $C rcat <NAME>-crypt:daily/lock-canary.txt
sudo rclone $C deletefile <NAME>-crypt:daily/lock-canary.txt; echo "exit=$? (non-zero expected on R2: locked)"
# retention ignores the name; the lifecycle rule removes it after 8 days
```

**8. Enable the timer** (only when `--preflight` shows no FAIL and, on SharePoint, the folder test printed `rmdir OK`)
```bash
sudo /usr/local/sbin/<NAME> --preflight && sudo systemctl enable --now <NAME>.timer
systemctl list-timers <NAME>.timer --no-pager
```

**9.** Operations-log entry (no secrets; the customised-files table gains the units, defaults and scripts), handbook
plan item ticked, owner told what to watch (healthchecks e-mails).

## 3. Rollback

```bash
sudo systemctl disable --now <NAME>.timer            # stops future runs; Moodle untouched
# full removal (owner go-ahead; local staging holds personal data):
sudo rm -f /etc/systemd/system/<NAME>.service /etc/systemd/system/<NAME>.timer /etc/systemd/system/<NAME>-alert.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/sbin/<NAME> /usr/local/sbin/<NAME>-retention /etc/default/<NAME>
sudo rm -rf /usr/local/share/<NAME> /var/backups/<NAME>
```
The rclone config (secrets) and the remote data stay until the owner decides. To cut the server's access at once:
SharePoint, revoke the backup account's sessions (Entra admin center); R2, delete the API token.

## 4. Daily and weekly operations

- Daily, no sudo: `cat /var/lib/<NAME>/status` (`last_ok` within 26 h, `warnings=0`, `filedir_ok=1`);
  `/var/lib/<NAME>/last-run.log`; the healthchecks dashboard.
- Weekly: `sudo /usr/local/sbin/<NAME>-retention --check` (add `--lifecycle` on R2). After the first week:
  7–8 complete daily sets and `retention: ok`.
- Monthly: `restore-tests.md` section A. Quarterly: section B (drill). Log each as a read-only check.
- Watch the storage the first months (SharePoint admin center → Active sites; R2 bucket metrics).

## 5. What the healthchecks messages mean

- "start" then "success" nightly: fine.
- "down" with a body: a failure (ERROR line: nothing or only part uploaded) or "completed with warnings" (the set is
  uploaded; read the WARN line).
- "down" without any ping: the job did not run (server down, timer disabled, unit broken).
- Token problems (SharePoint) show as `invalid_grant`, `AADSTS…`, 401/403 in the body: the owner runs
  `--renew-token` (same account only). `AccessDenied` / `InvalidAccessKeyId` on S3: the key was deleted or rotated.
- "objects in the folder but none opens with the configured passphrases": the config holds other passphrases than
  the backups were made with. Never "fix" it by starting over in the same folder; find the right passphrases.

## 6. Mass deletion, shrunken dump, drift

- More than MAX_DELETE files removed from moodledata in a day (a big course clean-up), or a dump below 70 % of the last
  good one: the run uploads the set, skips the risky steps and fails on purpose. Check what happened in Moodle first,
  then set `MAX_DELETE=` (higher) or `MIN_SHRINK_PCT=0` in `/etc/default/<NAME>` for ONE run and comment it out again.
- "uploaded again" warnings: files were missing on the remote (deleted there). Find out who/what deleted them; on
  SharePoint check the recycle bin and the account's activity.

## 7. Maintenance nights

- **Case (a)**, installed with a successful run: about two hours before the window one manual run
  (`sudo systemctl start --no-block <NAME>.service`, poll `systemctl show -p ActiveState,SubState,Result` until
  inactive), `Result=success` and `status` `last_ok` = this run. Not `success` (for example the token expired:
  `invalid_grant` in `journalctl -u <NAME>.service -n 50`): switch to case (b) tonight; the owner renews after the
  night. Not finished about 35 min before the window: `systemctl stop`, then case (b).
- **Case (b)**, not installed or no successful run yet: a local `--single-transaction` dump to a root-only file before
  the window, in addition to the provider snapshot.
- In **either** case, a timer that exists and is enabled is disabled before the window
  (`sudo systemctl disable --now <NAME>.timer`; `stop` alone comes back at boot) and enabled again afterwards.
- After the post-checks: `sudo systemctl enable --now <NAME>.timer`; check `systemctl show -p Persistent` = `no`,
  so enabling never starts a run at once. **Enabled before the slot**: tonight's run happens as usual and is the first
  set with any new passwords. **Enabled after the slot**: no run tonight, and healthchecks would send a false "down"
  after the grace time: either start one run by hand early enough to end before the apt window, or the owner pauses
  the check until the next night.
- No Moodle upgrade or plugin install inside the backup window (DDL during the dump breaks consistency).
- The maintenance module (`skills/maintenance`) carries the same steps in its night script.

## 8. Server move

1. Disable the timer on the OLD server first (two servers in one folder move each other's new files away).
2. On the new server: install, then the owner runs the setup script with the SAME passphrases (new token or key; it
   refuses other passphrases, and asks `MOVE` when the newest set comes from another host).
3. The **final** filedir copy, and only then `--reconcile` once (one mirror listing, uploads only what is missing). It
   stops when more than `MAX_DELETE` mirror files are missing locally ("finish copying filedir first"). Dry run,
   enable the timer.
4. SharePoint with Conditional Access location policies: the new server has a new IP (exclude the account or allow
   the IP before the first night).

## 9. Password and key changes

- **SharePoint backup account password.** Whether a change revokes the server's token is not certain (design §3:
  rclone's app is probably a confidential client, whose refresh tokens can survive a password change).
  - Ordinary change: afterwards Claude runs `--preflight`. Library reachable: nothing else to do. Fails
    (`invalid_grant`, AADSTS50173): the owner runs `rclone authorize "onedrive"` on his PC and
    `owner-setup-sharepoint.sh --renew-token`.
  - Suspected leak (password, token or the server): first Entra admin center → the account → **Revoke sessions**, then
    the password change, then `rclone authorize` and `--renew-token`. The password change alone may leave a stolen
    token working.
  - `--renew-token` accepts only a token of the same account; passphrases are not affected. Also needed after
    "Revoke sessions", MFA reset, 90 days unused, Conditional Access re-authentication. Moving the backup to another
    account on purpose is a new setup (owner deletes the config first) with the SAME passphrases.
- **R2 key rotation**: new Object Read & Write token for the bucket; the owner removes the old config
  (`sudo rm /var/lib/<NAME>/rclone/rclone.conf`) and re-runs `owner-setup-s3.sh` with the SAME passphrases; then delete
  the old token in the dashboard.
- **Moodle DB password / Redis password rotation**: the backup is not affected (root over the socket). Each night's
  bundle carries that night's config.php, and its users dump the matching DB password hash; sets older than the
  rotation hold the old passwords and age out (8/29/186 days). The first run after the rotation is the first set with
  the new values. When restoring after a rotation:
  - **same server** (lost data, a bad upgrade): restore only the Moodle DB dump (and files as needed) and **keep the
    live config.php `dbpass` and the live DB account**. Do not load that set's users dump or copy its config.php: a
    set older than the rotation would bring back the old (possibly leaked) password;
  - **rebuild on a new server**: restore the set with its own config.php and users dump (restore-tests.md D). After
    rebuilding from a set older than the rotation, rotate the password again right away.
- **Crypt passphrases**: never change in place (old sets open only with the old ones). If exposed: new folder, new
  passphrases, `--reconcile`; delete the old folder after 186 days.
