# Core rules for every module

Read this file before running any module. These rules come from a real production remediation; each one exists
because skipping it caused, or nearly caused, a problem. They apply to every server this plugin is used on.

## Contents
1. Who you work for and how
2. Before touching anything
3. The change protocol
4. Approval and timing
5. Secrets
6. Deleting things
7. The Moodle code tree
8. Testing
9. Accuracy and evidence
10. Coordination with other sessions
11. Reporting to the owner
12. Paths and placeholders

## 1. Who you work for and how
- The owner runs several production Moodle servers and usually works in **Arabic**. Write instructions to yourself in
  English, but talk to the owner in the owner's language (Arabic by default): short sections, tables, plain words.
- Rhythm: **analyse (read-only) → propose a plan with exact steps → wait for approval → execute one item at a time →
  verify → log → report**. A general "continue" is not approval for a change that was never proposed.
- These are live sites with real students. When unsure, choose the reversible option and ask.

## 2. Before touching anything
- Read the server handbook and the operations log (default `~/SERVER-HANDBOOK.md`, `~/SERVER-OPS-LOG.md`; an older
  server may use other names, which `CLAUDE.md` on that server points to). If they do not exist, run the `start`
  module first; it creates them.
- Run `skills/start/scripts/detect-env.sh` (read-only) when the environment file is missing or older than a day. It
  writes non-secret facts (paths, versions, services) that every module uses instead of guessing.
- Re-read the tail of the operations log right before any change: another session may have changed something.

## 3. The change protocol
Every change, however small, follows these steps. Write the rollback before making the change.
1. **Backup**: copy the file next to itself as `<file>.bak-YYYY-MM-DD` (add a letter for a second copy the same day),
   or tar a directory to a root-only folder `/root/<topic>-YYYY-MM-DD/` (mode 700). Back up the resolved file
   (`readlink -f`), and never leave a backup inside a directory that a service loads by glob (`sites-enabled/`,
   `conf.d/`, `/etc/logrotate.d/`, `/etc/sudoers.d/`): there it would be loaded as live config. Put those in
   `/root/<topic>-YYYY-MM-DD/` instead. For Moodle settings, save the old
   values first (root-only file when a value is sensitive).
2. **Change** with exact, idempotent commands. Prefer a small script or `python3` string replacement that asserts the
   old text occurs exactly once over a loose `sed`.
3. **Test** the configuration before applying it: `nginx -t`, `php -l`, `exim -bV`, `update-exim4.conf`,
   `logrotate -d`, `systemd-analyze verify`, `bash -n`.
4. **Apply** with the gentlest action: reload rather than restart; CLI rather than web; maintenance mode only when the
   change requires it and only in a quiet hour.
5. **Verify with evidence**: probe before and after (HTTP status of every site on the box, the exact feature changed,
   logs for new errors). Compare before/after output rather than eyeballing.
6. **Log** an entry in the operations log (format below) before reporting.
7. **Report** to the owner: what changed, the evidence, the rollback, what is next.

Operations log entry format (append at the end of the log section; never edit old entries, add a correction entry):
```
### YYYY-MM-DD HH:MM — short title  (session: <session name>, approved by owner: yes/no/n.a.)
- What/why:
- Files/settings touched:
- Backup / rollback:
- Verified:
- Next:
```
Also keep the log's "customised files" table current when a config file is added or changed.

## 4. Approval and timing
- Only agreed changes. Irreversible actions, reboots, user-visible changes, anything that sends mail or messages, and
  anything outside the agreed scope need the owner's explicit go-ahead at that moment.
- Do risky changes in the server's **quiet hours**. Measure them; do not assume: requests per hour from 14 days of
  access logs (`audit` module, `scripts/quiet-hours.sh`). On one server the window turned out to be 02:00–06:00 local
  time, with 06:00 already busy; another server may differ.
- Never schedule two production changes so that their effects cannot be told apart when a measurement is pending.

## 5. Secrets
- Never ask for, type, print or store passwords, tokens, API keys, SMTP credentials, DB passwords or Cloudflare/R2/
  Microsoft keys. Prepare the configuration; the owner inserts the secret with a no-echo prompt, for example:
  `sudo bash -c 'read -rsp "token: " T; echo; printf "%s\n" "$T" >> /path/file; unset T'`.
  Keep secrets out of argv (visible in `ps`), environment of children, shell history, temp files and logs.
- Verify that a secret is present without revealing it (field count, length, file mode), never by printing it.
- Never print `.env` or `config.php` values except non-secret keys (APP_ENV, APP_DEBUG, APP_URL, DB_CONNECTION,
  dbtype, dbname, wwwroot, dataroot). Never run tools that echo stored credentials (for example
  `mariadb-dump --print-defaults`, `my_print_defaults`).
- Database reads go through Moodle's own CLI bootstrap (`require config.php; $DB->...`) as the web user, read-only,
  returning counts and IDs, not personal data. Route personal-data exports to the Moodle report builder. Three other
  read paths are allowed: the audit collector and the backup dump (root over the local socket, no password), and the
  audit monitor's `dbstat.php` (read-only transaction with a 5 s statement limit, installed only with approval).
- Keep secret-bearing files at 640/600 with the right group so the web server still reads them; check after any
  `php artisan config:cache` or similar rebuild, which recreates files with default modes.

## 6. Deleting things
- Prefer **moving to a root-only archive** (`/root/<topic>-cleanup-YYYY-MM-DD/`) over deleting: it is reversible and
  frees the live location. Keep a compressed copy for about 30 days; the owner deletes it later.
- The session's permission system may refuse irreversible deletions (`rm` of data files, `truncate` of a mailbox) even
  after the owner approved them. Do not work around that. Run every read-only pre-check yourself, then give the owner
  the exact one-line command to run, and verify afterwards.
- Before deleting anything, prove nothing references it: enabled web server config, crontabs, systemd units, open
  file handles, other apps' config. Use exact paths, never a glob that could match a sibling (`/opt/moodle*` would
  also match `/opt/moodle-maintenance`).

## 7. The Moodle code tree
- Never modify Moodle core files in a git checkout; never run `git clean` or `git stash -u` there: third-party plugins
  are usually untracked and would be deleted.
- Moodle 5.1+ serves from `<MOODLE>/public/` and keeps CLI scripts in `<MOODLE>/admin/cli/`; Moodle 5.0 and older
  serve from `<MOODLE>/` itself. Read the version from `version.php` and use the right paths.
- CLI upgrades and plugin installs: `php -d max_input_vars=5000 admin/cli/upgrade.php --non-interactive`. The CLI
  default of 1000 fails Moodle's environment check after maintenance mode is already on.
- Vendor (third-party plugin) patches only through a patch tool that pins the original and patched sha256, backs up,
  replaces files as their owner, and can restore. Patches are lost on vendor upgrades: record them in the log and add a
  check that detects a lost patch.

## 8. Testing
- Never run PHPUnit or Behat on production. Never send write requests to the live site to test. Test scripts in a
  throwaway directory with mocks. Use read-only probes (`curl -I`, `--resolve host:443:127.0.0.1`).
- Moodle CLI scripts run as the web user (`sudo -u www-data php ...`). The web user usually cannot read the
  operator's home (mode 700): copy a script to `/tmp` with mode 644 first. A heredoc into `/dev/stdin` under sudo fails.

## 9. Accuracy and evidence
- Take timestamps from `date` or file change times (`stat -c %z`), never from estimates.
- A dry run, a staging test or `-d` debug mode is not "done": say "tested; confirmed at the next real run (time)".
- A CLI test with cold caches is not the page time students see; nginx `urt` is server time, not browser time. Say
  exactly what was measured, where, and how many samples.
- Report failures with their output. Do not round a partial success up to "fixed".
- When a sub-agent or reviewer reports something surprising, verify it yourself before acting or repeating it.

## 10. Coordination with other sessions
- Several Claude sessions may work on the same server. The operations log is the shared record: re-read it before
  changing anything and append after. One production change at a time across all sessions.
- Do not edit a file another session or a running workflow owns; wait, or coordinate.

## 11. Reporting to the owner
- Lead with the outcome, then a short table of evidence, then what needs the owner (decisions, Cloudflare or panel
  steps, secrets to insert), then what is next with dates.
- Offer, do not assume: "Shall I …?" for anything not yet approved.

## 12. Paths and placeholders
Modules use these names. `detect-env.sh` writes most of them to `~/.config/moodle-server-care/server.env` (marked *);
the others come from the handbook or are asked for:

| Placeholder | Meaning |
|---|---|
| `<MOODLE>` (*) | Moodle code root (directory with `config.php`) |
| `<DOCROOT>` (*) | web root (`<MOODLE>/public` on 5.1+, else `<MOODLE>`) |
| `<DATAROOT>` (*) | `$CFG->dataroot` |
| `<SITE>` (*) | host name from `$CFG->wwwroot` |
| `<PHP>` (*) | PHP CLI binary used by the site's FPM pool, e.g. `php8.4` |
| `<FPM_SOCK>` (*) | the site's PHP-FPM socket |
| `<WEBUSER>` (*) | PHP-FPM pool user (usually `www-data`) |
| `<ORIGIN_IP>` (*) | the server's public IPv4 |
| `<LOG>` / `<HANDBOOK>` | operations log / handbook paths (* as `OPS_LOG` / `HANDBOOK` when found) |
| `<SKILL_DIR>` | the base directory of the skill being run (shown when the skill loads) |
| `<PHPV>` / `<POOL>` | PHP version number (e.g. `8.4`) / the site's PHP-FPM pool name |
| `<VHOST>` | the site's web server config file (*) |
| `<SUBPATH>` | URL path prefix when Moodle is not at the web root (usually empty) |
| `<SERVER_TZ>` / `<STUDENTS_TZ>` | server time zone (*) / the students' time zone for quiet-hour reports |
| `<COUNTS_HELPER>` | the owner's optional course-card counts helper plugin, if the server uses it (see the handbook) |
