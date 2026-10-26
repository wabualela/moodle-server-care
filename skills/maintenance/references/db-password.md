# Rotating the Moodle DB password (scripts/rotate-db-password.sh)

## Contents
1. When
2. Scope of the script
3. What it does (rotate mode)
4. Usage: frozen copy, where the owner runs it, prompts
5. Exit codes and what to do
6. Rollback (scripted, by hand, interrupted or killed run)
7. How secrets are handled
8. Interplay (Redis step, backups, snapshot, other consumers)
9. Remaining risk after the rotation

## 1. When
- The password was exposed: printed into a transcript or log (for example by `mariadb-dump --print-defaults` or
  `my_print_defaults`, which print the `[client]` password from `~/.my.cnf`; a sub-agent "checking the options" is
  enough), shared in a chat, found in a world-readable file, in shell histories with inline `-p...`, in old
  `config.php.bak-*` copies, editor histories.
- Staff who knew it left, or the owner wants periodic rotation.
- Not urgent when the exposed value turns out to be stale (an old `~/.my.cnf` often holds a password the DB already
  rejects): then the rotation is hygiene and can wait for the maintenance night. Check whether an exposed value is
  live by comparing hashes inside the DB (the script's `--check` does this), never by printing it.

## 2. Scope of the script
MariaDB with `mysql_native_password`, DB server on this host (unix socket), a plain single-quoted `$CFG->dbpass` line.
It **stops and changes nothing** on: MySQL (no `mysql.global_priv`; MySQL 8 defaults to `caching_sha2_password`, whose
hash form differs; its `slow_query_log` is global only), `ed25519` or other plugins, an `auth_or` alternative, an
active password-validation plugin with `strict_password_validation` (it rejects the hash form of `ALTER USER`), a
MariaDB that cannot switch `slow_query_log` off per session, a remote/managed DB host, `pgsql`, two lines mentioning
`dbpass`, a `dbpass` value with quotes or backslashes, config.php not matching the DB, Moodle CLI already failing,
maintenance off.

When it stops:
| Case | What to do instead |
|---|---|
| MySQL 8 | adapt: `ALTER USER ... IDENTIFIED BY` with the plaintext on stdin (never argv), plugin-specific verification, and a different way to keep the statement out of the slow log; write and harness-test it first |
| Managed DB (provider console) | rotate in the provider console, then update config.php with the same atomic edit + `php -l` + FPM reload; maintenance mode in between |
| PostgreSQL | `ALTER ROLE <user> PASSWORD '<scram hash>'` from `psql` as postgres on stdin; adapt the script, test in a harness |
| dbpass line with special characters | edit by hand in maintenance mode with a backup, or set a simple alphanumeric password first |

## 3. What it does (rotate mode)
Every step is checked; the script stops at the first failure.
1. **Preflight (read-only)**: tools; config.php parsed (dbuser, dbtype, dbhost, dataroot, dbsocket); MariaDB root over
   the socket with `--no-defaults` (so an operator `~/.my.cnf` can never turn it into the Moodle user); the session
   slow-log switch works; host entries, plugins, validation plugin; the config.php password equals the live hash on
   every host entry (compared inside MariaDB, never printed); Moodle CLI DB read works (`admin/cli/cfg.php
   --name=version` as the web user; this also catches a broken config.php from a Redis step, but it does not exercise
   the Redis session handler); FPM active; operator `~/.my.cnf` status (from `SUDO_USER`'s home).
2. **New password**: generated (`openssl rand -hex 24`), shown ONCE on `/dev/tty` (a tee or redirect cannot catch it),
   screen and scrollback cleared on request, then pasted back twice hidden from the password manager (proves the saved
   entry). Or typed: `[A-Za-z0-9]{32,}`, not the current one. Empty lines and a trailing CR (password-manager paste
   tails) are ignored, so they do not use up the three attempts.
3. **Plan**, then the owner types `ROTATE` (empty lines skipped here too).
4. **Re-check, read-only, right after `ROTATE`**: the owner may have spent minutes in the password manager. Maintenance
   still ON, config.php and the DB still hold the old password, the Moodle CLI still reads the same version. Any
   difference stops it before any change (for example a Redis procedure whose last line switched maintenance off).
5. **Backup** `/root/dbpw-rotation-<YYYYmmddTHHMMSS>/` (0700): config.php.orig (0600, checked with `cmp`), meta
   (uid gid mode), hosts, dbuser, my.cnf.orig/meta, NOTE.txt and **STATUS**. STATUS records how far the run got, as
   state words only: `started`, `db`, `config`, `verified`, `complete`, `reverted`, `revert-failed`, `rolled-back`,
   `rollback-incomplete`. The folder name is the time just before the `ALTER` (the night's journal check uses it).
6. **Database**: `ALTER USER '<u>'@'<host>' IDENTIFIED BY PASSWORD '<mysql_native_password hash>'` for every host
   entry, SQL on stdin after `SET SESSION slow_query_log=0`; only the hash is sent (the plaintext never reaches the
   server or a log). Hash verified on every entry, real socket login tested with a 0600 option file on tmpfs. **Any
   failure or Ctrl-C/hang-up here sets the old hash back automatically**. The failure and signal handlers look at
   config.php itself, not only at the script's state: if the new config.php is already in place, they treat it as the
   next stage (both new), never by setting the old DB password back under a new config.php.
7. **config.php**: python3 gets the expected old hash and the new password on stdin, replaces only that line (prefix,
   suffix, CR/LF kept), writes a temp file with the same owner/group/mode, `php -l`, atomic rename (signals blocked for
   the rename and the state change). Checks: exactly one line differs, owner/mode unchanged, `php -l`.
8. **Moodle and FPM**: CLI DB read must return the same version; `systemctl reload <php>-fpm` (closes persistent
   connections that used the old login); CLI read again. A web check is not possible in maintenance mode (503 without
   touching the DB): it is a post-check. If a check fails after config.php changed, it asks "Roll back now? [Y/n]".
9. **~/.my.cnf**, the owner chooses: `r` remove the password line(s) **and the `user=<dbuser>` line** (default; Moodle
   does not use the file, analysis scripts read config.php, and a plain `mariadb` then no longer tries to log in as the
   Moodle user, so it adds no "Access denied" noise to the DB log), or `k` keep it (dead old password). There is **no
   "update" choice**: the operator's option file is readable by every session running as that user, which is how the
   password leaked in the first place. A symlinked `~/.my.cnf` is left untouched with a warning.
10. **Summary**, then the rollback recipe with the real backup folder name. If maintenance mode was switched off during
    the run, a warning says so.

`--check` runs only step 1 (maintenance may be off). Run it the day before and again at T-15. Leftover temp files of a
run that was killed before its cleanup (kill -9, power loss) can hold a password: the next run deletes them, but only
while it holds the lock, so a run refused by the lock never touches the active run's files.

## 4. Usage: frozen copy, where the owner runs it, prompts
**Freeze the script after its final review** (session, owner's go-ahead, log entry): the copy in the plugin or the
operator's home is writable by the operator account, so by every Claude session, and the script handles the new secret
as root.
```bash
sudo install -o root -g root -m 700 <SKILL_DIR>/scripts/rotate-db-password.sh /root/rotate-db-password.sh
sudo sha256sum /root/rotate-db-password.sh      # into the night plan and the log; the owner keeps a copy outside the server
```
While passwordless sudo is active a session could still change the `/root` copy; the owner's own record of the hash
catches that. Any later change to the script means install again and a new hash.

**Where the owner runs it**: a **standalone SSH client window** on his own computer (Windows Terminal / PowerShell
`ssh`, macOS Terminal, PuTTY, ...). **Not** a terminal tab inside the Claude app and **not** an editor's integrated
terminal (VS Code Remote-SSH): Claude sessions can read those screens, so the generated password would land in a
transcript again. No screen sharing or recording while the step runs. **The session must not read the owner's
terminal** (no terminal-reading tools, no screenshots); it waits for the owner's report. Test the login the day before.
tmux is optional (a hang-up is handled); if used, `tmux clear-history` after saving the password.

```bash
S=/root/rotate-db-password.sh
sudo sha256sum $S                                            # on the night: must match the hash the owner wrote down
sudo bash $S --check --moodle <MOODLE>                       # any day: "Ready: yes" (maintenance OFF is only "info")
sudo bash $S --moodle <MOODLE>                               # the night, maintenance ON
sudo bash $S --rollback /root/dbpw-rotation-<time> --moodle <MOODLE>
```
Defaults (Moodle dir, PHP binary, web user) come from the operator's `server.env` when the script runs under sudo;
`--php php8.x`, `--fpm-service`, `--web-user`, `--socket`, `--mycnf` override.

Prompts in order: generate (Enter) → the password is shown → save it in the password manager → Enter → clear the
screen (Enter) → paste it back twice (an extra empty line from the paste is ignored) → `ROTATE` → `~/.my.cnf` choice
(Enter = remove). It must end with **`ROTATION COMPLETE`**, exit 0. The owner tells the session **only the exit code
(`echo $?`) and the backup folder name**; the folder name is the only detail that goes into the log entry.

## 5. Exit codes and what to do
| Exit | Meaning | What to do |
|---|---|---|
| `0` | done | continue the night |
| `1` | failed, nothing is left changed (any automatic revert succeeded) | continue the night without the rotation; reschedule |
| `2` | the rotation is done, a follow-up step warned | read the `WARN` lines (no secret in them). A failed FPM reload is fine when a reboot follows. A `~/.my.cnf` problem is fixed in the post-checks (`night-checks.sh` reports the password-line count) |
| `3` | manual attention needed | **do not reboot**; run `--rollback <folder>` or the printed recipe until `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=version` prints the version |
| `130`, the SSH connection dropped, kill -9, power loss | interrupted (in the DB stage the old password is set back first) | section 6, "Interrupted or killed run" |

## 6. Rollback
**Scripted (preferred)**: `sudo bash /root/rotate-db-password.sh --rollback /root/dbpw-rotation-<time> --moodle
<MOODLE>`. It:
1. checks maintenance mode; if it is OFF, asks for confirmation (default: no) and warns;
2. compares the current config.php with the backup. If anything other than the dbpass line differs (for example a
   Redis step's `$CFG->session_redis_auth` line was added or deleted after the rotation), it lists those lines **by
   line number and key only** (never their content, which can be secret) and asks; they are **kept** as they are now;
3. asks for the OLD password hidden, or Enter to take it from the backup file (a typed value must match the backup);
4. asks for `ROLLBACK`; saves the current config.php as `config.php.before-rollback`;
5. sets the old hash back on every host entry, then sets **only** the `$CFG->dbpass` line back (atomic, owner and mode
   kept, `php -l`, and a check that no other line changed);
6. runs the Moodle CLI DB read, reloads FPM, and offers to restore `~/.my.cnf` (default no: that would put the old
   password back into a file every session running as its owner can read).
A rollback reactivates a password that may be known: plan a new rotation soon.

**By hand** (the script prints it with the real values): `sudo diff <backup>/config.php.orig <MOODLE>/config.php |
grep -E '^[0-9]'` shows change positions only. Only `<n>c<n>` (the dbpass line): copy the backup back with `install`
and the owner/mode from `config.php.meta`. More: config.php changed after the rotation (for example the Redis line),
and copying the backup would undo that too, so use the scripted rollback. Then `read -rs OLDPW` and
`printf "SET SESSION slow_query_log=0; ALTER USER '<u>'@'localhost' IDENTIFIED BY '%s';\n" "$OLDPW" | sudo mariadb
--no-defaults; unset OLDPW` (works when the old password has no `'` or `\`), the CLI check, FPM reload.

**Interrupted or killed run** (exit 130, dropped SSH connection, kill -9, power loss, a reboot mid-run):
1. `pgrep -af '[r]otate-db-password'` (the brackets keep pgrep from matching the calling shell): if it still runs
   (tmux), reattach and finish there;
2. `sudo ls -d /root/dbpw-rotation-*`: the newest folder is this run. No folder: it stopped before the backup, nothing
   changed;
3. `sudo cat /root/dbpw-rotation-<time>/STATUS` and `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=version`;
4. `complete` or `verified` and the version prints: the rotation is in place (reload FPM; the post-checks catch
   `~/.my.cnf`). `reverted` and the version prints: nothing changed. `config` and the version prints: in place, but the
   last checks did not run: reload FPM and remove the `~/.my.cnf` password line by hand (the script prints the `sed`
   line). **Anything else, or the version does not print: `--rollback /root/dbpw-rotation-<time>`**, then the CLI
   check again.
Leftover temp files of the killed run (they may hold a password) are deleted by the next run of the script; `/run` is
emptied by a reboot anyway.

## 7. How secrets are handled
- The new password reaches python3 on stdin only, never argv or the environment, and stays in shell memory only. The
  login test uses a 0600 option file in a 0700 `mktemp -d` folder on `/run` (tmpfs), deleted right after.
- Only the `mysql_native_password` hash is sent to MariaDB, so the plaintext never reaches the server. Every SQL batch
  starts with `SET SESSION slow_query_log=0`: with the slow log on (and `log_slow_admin_statements`), a statement
  stalled beyond `long_query_time` would otherwise write the hash into the slow log. Check that the general log and the
  binlog are off (or accept that they record the hash) during discovery.
- MariaDB error text is printed with any hash, or any long run of hex characters, masked. The rollback lists
  config.php differences by line number and `$CFG` key only.
- The only time a secret is shown: the generated password, once, on `/dev/tty`. That is why the terminal must be one
  no Claude session can read (section 4).
- The backup folder holds the OLD password (root only). Delete it with `shred -u` after about 7 good days.

## 8. Interplay
- **Redis step the same night**: run Redis first, then the DB rotation. Both rollbacks are surgical, so they can be
  undone in reverse order without copying whole files back. A Redis procedure that ends with `maintenance.php
  --disable` must skip that line on the night: maintenance stays on until the post-checks (the DB script refuses to
  start, or stops before any change, if maintenance is off). A whole-file backup of config.php taken by the Redis step
  holds the OLD DB password: restoring it after the rotation locks Moodle out of its DB. After the rotation, undo Redis
  by deleting its own lines (or roll back the DB password first, after which the old backup matches the DB again).
- **Backups**: the DB is dumped as root over the socket, so the rotation does not affect the backup. A set made before
  the rotation holds the old password in its config.php and its users dump. **Restore on the same server**: restore
  only the Moodle DB dump (and files as needed) and keep the live config.php `dbpass` and the live DB account; do not
  load that set's users dump or copy its config.php. **Rebuild on a new server**: restore the set with its own
  config.php and users dump, then rotate the password again right away if the set predates the rotation. The first
  backup run after the window is the first set with the new password.
- **Snapshot rollback** brings back the old password in both config.php and the DB (consistent).
- **Other consumers**: before the night, list everything that uses the DB user (`grep -rl` for the user name in /etc,
  /opt, /srv, /usr/local, crontabs, other vhosts, monitoring scripts) and decide for each. Analysis scripts should read
  config.php through Moodle's bootstrap, not keep their own copy of the password.
- **Stale copies** of the old password (backups of config.php, editor histories, shell histories): the owner deletes
  them after the rotation; the backup folder of the rotation itself after about 7 good days (`shred -u`).
- **Stale grants** found during discovery (for example on a schema that no longer exists): revoke in a later change,
  not on the night.

## 9. Remaining risk after the rotation
The rotation removes the leaked value, not the way it leaked. Check during discovery (`scripts/discover.sh` reports
both) and tell the owner:
- If the operator account (the one Claude sessions run as) is in the web server's group and config.php is
  group-readable (often `www-data 640`), every session can read the **new** password without sudo. Options for the
  owner: remove the operator from that group (after checking what needs it: deploys into the Moodle tree, a monitor that
  reads config.php), or keep the group and add a Claude Code hook that blocks reading config.php, `~/.my.cnf`, `.env`
  files and `--print-defaults`; and let any temporary passwordless sudo expire as planned.
- If the same password was used elsewhere (Moodle admin, Redis, another DB user, a panel or mailbox), change it there
  too.
