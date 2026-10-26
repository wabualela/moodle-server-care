# Reboot for kernel and libraries; snapshot and rollback

## Why reboot at all
- A new kernel only runs after a reboot (`/var/run/reboot-required`, running `uname -r` older than the newest
  `/boot/vmlinuz-*`). Servers often drift for weeks or months with a pending kernel, because nobody owns the reboot.
- Library updates (OpenSSL, glibc, libxml2 ...) only reach processes that start after them. nginx is the classic case:
  a `reload` forks new workers from the **old** master image, so it keeps the old OpenSSL until a restart. A reboot
  restarts everything on the new libraries at once and proves that every service and every new password survives a
  start (redis.conf, config.php, enabled units).

## Discovery (read-only)
```bash
uname -r; ls /boot/vmlinuz-*; cat /var/run/reboot-required.pkgs 2>/dev/null
sudo grep -l '(deleted)' /proc/[0-9]*/maps | cut -d/ -f3 | xargs -r ps -o comm= -p | sort | uniq -c
grep -hs GRUB_TIMEOUT /etc/default/grub /etc/default/grub.d/*.cfg      # 0 = no boot menu in the console
systemctl --failed; systemctl list-unit-files --state=enabled --no-pager | grep -E 'nginx|apache|php|mariadb|mysql|redis|exim|postfix|cron'
last -x reboot | head -5
```

## Snapshot (mandatory before the reboot)
- Provider panel, live snapshot, named `pre-maintenance-<date>`, started at T-60, **complete before T0**.
- With `GRUB_TIMEOUT=0` there is no menu to pick the old kernel: the snapshot or the provider's recovery image is the way
  back. The provider's daily backup (if any) is the fallback, up to 24 h old.
- Restoring a snapshot loses everything written after it. Keep the maintenance page on until the site is checked.

## The reboot
```bash
sudo bash scripts/night-checks.sh pre                 # state before (T-15)
sudo systemctl reboot                                 # T0
# reconnect after ~1 min; no SSH after 5 min -> provider web console
sudo bash scripts/night-checks.sh post                # state after, diff against "pre"
```
Expected after: kernel = newest; reboot-required gone; the same services active; failed units no worse than before;
the DB buffer pool loading or loaded (`Innodb_buffer_pool_load_status`); nothing on replaced libraries.

## Warm-up
After any DB restart only part of the buffer pool is restored (`innodb_buffer_pool_dump_pct`, default 25 %): the first
minutes are slower; that is why the reboot happens in the quiet window and why measurements right after it are not
representative.

## Rollback
| Problem | Action |
|---|---|
| Server does not come back / kernel panic | provider console: boot the recovery image, mount the disk, set the previous kernel as default; or restore the snapshot |
| A service fails to start | read `journalctl -b -u <service>`; fix the cause (often a config changed earlier that was never restarted); the snapshot if not fixable within the window |
| New passwords break something after the reboot | the scripts' `--rollback` (DB first, then Redis), or the snapshot (brings back the old passwords consistently) |
| Window running out | keep maintenance on, tell the owner, send the delay message (announcement §7), decide: fix forward or snapshot |

## Without a reboot (when the owner declines one)
Restart what maps old libraries, one at a time, in the quiet window: `systemctl restart nginx` (under 1 s),
`systemctl reload php*-fpm` (graceful), DB and Redis restarts only with maintenance mode on. The kernel stays pending:
record that in the handbook and plan the reboot.
