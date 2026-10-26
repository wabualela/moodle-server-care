# Installing or upgrading a plugin safely

Script: `scripts/install-plugin.sh` (uses `scripts/plugin-info.php`). This is for one plugin at a time, from a
source directory the owner trusts (the owner's own repository at a release tag, or a vendor release unpacked into a
fresh directory). It is not for Moodle core upgrades.

## Why so careful
- A plugin upgrade runs database steps. Moodle cannot downgrade, so the rollback after a successful upgrade is a
  restore (DB backup + old files), not "copy the old files back". A failed upgrade leaves new code on an old schema.
- The CLI's default `max_input_vars` (1000) fails Moodle's environment check (it wants 5000) **after** maintenance
  mode is on. The first server lost a first attempt to this (seconds of maintenance, nothing installed). Always run
  `php -d max_input_vars=5000 admin/cli/upgrade.php --non-interactive` (or raise it in the CLI php.ini with a log entry).
- The upgrade purges all caches: the next page views rebuild them and are slow for a few minutes.
- Development folders (`.git`, CI config, `dev/`, vendor-patch sources, docs) must not reach the web root: they leak
  internals and some are executable.

## Before (read-only)
1. Read the plugin's README/CHANGES for the target version: requirements, upgrade notes, new scheduled tasks or
   settings, whether it needs an admin to visit a settings page afterwards.
2. `bash install-plugin.sh check <SRC_DIR>`: stages the files without dev folders, runs `php -l` with the site's PHP,
   reads the new `version.php` as text (never executes it), finds the target directory from Moodle's own plugin-type
   map (on 5.1+ under `public/`), compares installed and new versions, checks `requires`, `supported`, maturity and
   dependencies, refuses when another upgrade is already pending (the CLI upgrade would install that too), and
   shows an rsync preview including deletions.
3. A fresh database backup must exist (the `backup` module's last nightly run, or a manual dump by the owner's
   procedure) when the action is `upgrade`; note its time in the proposal.
4. Agree the window with the owner: measured quiet hours, about 1 minute of maintenance (typically under a minute).

## Install (quiet hour, owner approved)
```bash
bash install-plugin.sh install <SRC_DIR> --window=<HH-HH>             # prints the exact steps (dry run)
bash install-plugin.sh install <SRC_DIR> --window=<HH-HH> --execute   # runs them, only inside the window
```
Steps it runs: tar of the old plugin directory to `/root/tuning-plugin-<component>-<date>/` (mode 700) →
`admin/cli/maintenance.php --enable` → rsync `--delete` as the owner of the code tree (ownership and modes copied
from a sibling plugin) → upgrade with `-d max_input_vars=5000` → `maintenance.php --disable` → verify (nothing
pending, new version installed, login page answers through `--resolve <SITE>:443:127.0.0.1`).

If the upgrade fails, maintenance stays ON deliberately and the script prints the two choices (fix and rerun, or put
the old files back and switch maintenance off). Decide with the owner; do not improvise.

## After
- Purged caches: check the front page and login page timings once caches are warm again.
- Plugin settings page: some plugins add settings that default to on/off unexpectedly; review them with the owner.
- New scheduled tasks: run `tasks-review.php` again to see their schedules.
- Log entry: version from → to, source (tag/commit), maintenance start/end times from the script output, backup
  path, verification.

## Moodle 4.3+ options (optional)
`upgrade.php --is-maintenance-required` returns 2 (maintenance needed) or 3 (not needed) once the new files are in
place; with 3, `upgrade.php --non-interactive --maintenance=false` upgrades without maintenance mode. The script
keeps the simple, always-maintenance path; use the option only after discussing it with the owner.

## Removing a plugin
`admin/cli/uninstall_plugins.php --plugins=<component> --run` (as the web user) deletes its data and tables. That is
irreversible: owner's explicit go-ahead, a DB backup first, quiet hour. Disabling (where the plugin type supports it)
is the reversible alternative; remember to review its scheduled tasks (`references/scheduled-tasks.md`).
