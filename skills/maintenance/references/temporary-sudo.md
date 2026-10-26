# Temporary passwordless sudo with a fixed-date revoke timer (pattern)

Use only when the **owner asks** that the session may execute and verify with sudo (for example for a maintenance
night). It does not widen the working rules: every change still needs approval, irreversible actions still need the
owner at that moment. Installing it is itself a change (backup, log entry).

## Why a fixed date
A transient timer (`systemd-run --on-active=24h`) looks simpler, and it was tried first on the first server. Two
problems showed up within hours: a transient timer **vanishes on a reboot** (the rule would then stay forever), and it is
**re-armed by every `systemctl daemon-reload`** (the expiry drifted by minutes with each reload). A persistent unit
pair with `OnCalendar=<date>` and `Persistent=true` survives reboots and fires at the next boot if the server was down
at that moment.

## Install (owner approval; the owner may prefer to run these himself)
Render the templates in `assets/` (`@USER@` = operator account, `@UNTIL@` = `YYYY-MM-DD HH:MM:SS` server local time):
```bash
A=<SKILL_DIR>/assets;   # <SKILL_DIR> = this skill's base directory
U=<operator>; UNTIL="<YYYY-MM-DD HH:MM:SS>"; W=$(mktemp -d)
sed "s/@USER@/$U/g; s/@UNTIL@/$UNTIL/g" $A/temp-sudo-nopasswd.in   > $W/90-$U-nopasswd
sed "s/@USER@/$U/g; s/@UNTIL@/$UNTIL/g" $A/revoke-temp-sudo.service.in > $W/revoke-$U-nopasswd-sudo.service
sed "s/@USER@/$U/g; s/@UNTIL@/$UNTIL/g" $A/revoke-temp-sudo.timer.in   > $W/revoke-$U-nopasswd-sudo.timer
sudo visudo -cf $W/90-$U-nopasswd                                         # must say "parsed OK"
sudo install -o root -g root -m 0644 $W/revoke-$U-nopasswd-sudo.service $W/revoke-$U-nopasswd-sudo.timer /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/revoke-$U-nopasswd-sudo.timer
sudo systemctl daemon-reload && sudo systemctl enable --now revoke-$U-nopasswd-sudo.timer
sudo install -o root -g root -m 0440 $W/90-$U-nopasswd /etc/sudoers.d/      # last: the revoke exists before the rule
rm -rf $W
```
Order matters: the timer first, the rule last, so there is never a rule without its expiry.

## Verify
```bash
systemctl list-timers revoke-*-sudo.timer --no-pager      # next run = UNTIL
sudo -n true && echo "passwordless sudo active"
```
Log entry: what, until when, how to revoke now, how to extend.

## Extend, revoke, clean up
- Extend (owner request): edit `OnCalendar=` in the timer, `sudo systemctl daemon-reload`, check `list-timers`.
- Revoke now: `sudo rm -f /etc/sudoers.d/90-<operator>-nopasswd`.
- After it fired: `sudo systemctl disable revoke-<operator>-nopasswd-sudo.timer` and delete both unit files; log it.
- Write the expiry into the handbook's rules section and into the night plan ("still active that night?").
