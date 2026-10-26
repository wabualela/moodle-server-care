# unattended-upgrades: move the window, cover third-party PHP, or hold services

## Why
Debian and Ubuntu install security updates automatically and the package scripts **restart** the services they
upgrade: the DB server (a few seconds down, cold buffer pool afterwards), nginx, Redis, PHP-FPM. The packaged schedule
(`apt-daily-upgrade.timer`: Debian 06:00 + up to 60 min random) is often a busy morning hour. On the first server one
such run restarted MariaDB at the morning ramp on a weekday (seconds down, a cold buffer pool for the busy hours
that followed). The fix is not to stop security updates but to run them in the quiet window, after the nightly backup.

## Discovery (read-only)
```bash
systemctl cat apt-daily-upgrade.timer            # OnCalendar, RandomizedDelaySec, existing drop-ins
systemctl list-timers apt-daily-upgrade.timer apt-daily.timer --no-pager
grep -vE '^\s*//' /etc/apt/apt.conf.d/50unattended-upgrades | sed -n '/Origins-Pattern/,/};/p;/Package-Blacklist/,/};/p'
cat /etc/apt/apt.conf.d/20auto-upgrades
apt-cache policy | grep -E 'o=|release' | sort -u   # which origins exist (e.g. a third-party PHP repository)
zgrep -h 'Restarting\|restart' /var/log/unattended-upgrades/unattended-upgrades-dpkg.log* | tail
```
`scripts/discover.sh` prints the same in one block.

## Option A (recommended): move the window into the quiet hours
Pick `APT_AT` = backup hard stop + 5 min (for example backup 02:30, hard stop 03:40, apt 03:45 with
`RandomizedDelaySec=15m`); it must still end inside the quiet window.
1. Backup: none needed (a new drop-in; `systemctl revert` removes it). Check no drop-in exists yet.
2. Change: render `assets/apt-daily-upgrade.override.conf.in` and install it as
   `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` (root 0644), or `sudo systemctl edit
   apt-daily-upgrade.timer` with the same three lines.
3. Test: `sudo systemd-analyze verify /lib/systemd/system/apt-daily-upgrade.timer`.
4. Apply: `sudo systemctl daemon-reload`.
5. Verify: `systemctl list-timers apt-daily-upgrade.timer` shows the next run at APT_AT + delay; the next morning,
   `journalctl -u apt-daily-upgrade --since yesterday` shows the run at the new time and no service restart in the
   busy hours.
6. Rollback: `sudo systemctl revert apt-daily-upgrade.timer && sudo systemctl daemon-reload`.

`apt-daily.timer` (downloads package lists only) can stay as it is.

## Third-party PHP repository (e.g. a PPA or sury.org)
If PHP comes from an origin not in `Unattended-Upgrade::Origins-Pattern`, **PHP never gets security updates
automatically**. Check with `apt-cache policy php<ver>-fpm`. The owner chooses:
- **A1 automatic**: add the origin to `Origins-Pattern`, for example
  `"origin=deb.sury.org,codename=${distro_codename}";`. PHP then updates in the night window; the FPM package script
  **restarts** FPM (in-flight requests are cut, at night only). It also pulls every other package of that origin.
- **A2 monthly by hand, graceful**: keep the origin out; in a monthly quiet-hour window block the package scripts'
  restart with a temporary `policy-rc.d`, upgrade, remove it, then **reload** FPM (FPM's reload re-executes the master
  with the new binary and stays graceful):
  ```bash
  sudo apt-get update; apt list --upgradable 2>/dev/null | grep -E '^php'          # review
  printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null && sudo chmod 755 /usr/sbin/policy-rc.d
  sudo apt-get install --only-upgrade $(apt list --upgradable 2>/dev/null | grep -oE '^php[0-9.]+-[^/]+')
  sudo rm -f /usr/sbin/policy-rc.d                                                  # never leave it in place
  sudo php-fpm<ver> -t && sudo systemctl reload php<ver>-fpm
  ```
  A critical PHP advisory between windows: run the same block out of band at night.

## Option B: hold the service packages, patch monthly
For owners who want no automatic service restarts at all. Security fixes for these packages then wait for the monthly
window, so someone must watch the distribution's security announcements. In `50unattended-upgrades`,
`Unattended-Upgrade::Package-Blacklist { ... };` (Python regexes): `"mariadb-"; "^mysql-"; "^redis"; "^nginx";
"^apache2"; "^php[0-9.]+-fpm$"; "^libssl3$"; "^openssl$";`. Check with
`sudo unattended-upgrade --dry-run --debug 2>&1 | grep -iE 'blacklist|Packages that will be upgraded' | head`.

## After any library update: what still runs the old code
```bash
sudo grep -l '(deleted)' /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 | xargs -r ps -o pid=,comm= -p | sort -k2 | uniq -f1
sudo grep -c 'libssl.*(deleted)\|libcrypto.*(deleted)' /proc/$(cat /run/nginx.pid)/maps
```
- nginx: a **reload** forks new workers from the old master image: it does **not** load a new OpenSSL. A restart
  (under 1 s of refused connections, quiet hour) or the reboot does. The USR2/WINCH binary-upgrade dance is not
  recommended under systemd's `Type=forking` with `KillMode=mixed` (systemd can lose track of the new master).
- PHP-FPM: `systemctl reload` is enough (graceful re-exec).
- DB server, Redis: only a restart helps: night window.
- `checkrestart` (package debian-goodies) reports without restarting. Avoid `needrestart` in automatic mode on these
  hosts.

## Other distributions
- Ubuntu: same timers and files; `Origins-Pattern` uses `origin=Ubuntu,archive=${distro_codename}-security` etc.;
  Ubuntu Pro/ESM origins may exist. Same options apply.
- RHEL family (dnf-automatic): different tooling (`dnf-automatic.timer`, `/etc/dnf/automatic.conf`): stop and ask; move
  the timer the same way (drop-in with `OnCalendar=`), but check `apply_updates` and restart behaviour first.
- `Unattended-Upgrade::Automatic-Reboot "true"` would reboot by itself: keep it false on these servers; reboots are
  announced maintenance-night items.

## Change log for manual restarts
Rule kept on the first server after a daytime FPM restart caused aborted DB connections with no record: no manual
restarts of PHP-FPM, the DB or nginx in working hours unless there is an incident; use reload where it exists; every
restart gets an operations-log entry.
