# H7: fail2ban dead on journald-only systems (Debian 12 without auth.log)

## Why it matters
SSH on a public address gets hundreds to thousands of failed logins a day. Key-only SSH already stops them from
succeeding, so fail2ban mostly reduces noise and load; but a fail2ban that is installed, enabled and **failed since
boot** gives a false sense of protection and keeps `systemctl --failed` red.

Debian 12 does not install rsyslog, so `/var/log/auth.log` does not exist; sshd logs only to the journal. The packaged
`sshd` jail (`jail.d/defaults-debian.conf`: `enabled = true`, backend `auto`) looks for the file, fails with
`Have not found any log file for sshd jail`, and the whole fail2ban server stops. The fix: the journal backend for
that jail.

## Discovery (read-only)
```bash
bash scripts/fail2ban-check.sh
```
It shows: service state and since when, the last errors, whether rsyslog / python3-systemd are installed, whether an
auth log exists, the jail files, the effective sshd backend (`['add', 'sshd', '<backend>']`), the SSH settings
(`passwordauthentication`, `permitrootlogin`), failed SSH attempts in 24 h, and failures from your own SSH source.

- **Adapt:**
  - Ubuntu and systems with rsyslog have `/var/log/auth.log`: the default works; if fail2ban still fails, read its error.
  - Debian 13 / newer fail2ban may already default the sshd jail to the journal: check the effective backend first.
  - On OpenSSH ≥ 9.8 the per-connection process is `sshd-session`; if `Total failed` stays 0 while the journal shows
    failures, add `journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd-session` to the jail.
  - fail2ban not installed: installing a package is a separate proposal (the owner decides); this item then becomes
    "propose fail2ban with the journal backend".
  - `python3-systemd` missing: the systemd backend cannot work; installing it is a package change (propose it).

## Proposal (Arabic)
> **حماية SSH (fail2ban):** البرنامج مثبت لكنه متوقف منذ آخر إعادة تشغيل، لأن هذا الإصدار من النظام لا يكتب ملف سجل
> الدخول الذي يبحث عنه. أقترح ملف إعداد صغيراً يجعله يقرأ سجلات النظام مباشرة، ثم إعادة تشغيله والتحقق أنه يرصد
> المحاولات الفاشلة (نحو <N> يومياً). عنوانك الحالي ليس عليه أي محاولة فاشلة، وإن حُظر أحد المديرين خطأً فالحظر مؤقت
> (<BANTIME>) ويمكن الدخول من لوحة مزود الخادم لرفعه.

## Procedure
1. **Pre-check (lock-out safety):** your current SSH source must have 0 failures in the script output; ask the owner
   for admin static addresses and add them to `ignoreip`. Confirm the out-of-band path (the provider's web console)
   works for an account with a password, or that the owner can use it.
2. **Backup:** nothing is overwritten (a new file); record `ls -la /etc/fail2ban/jail.d/` in the log entry.
3. **Change:** install the drop-in from `assets/fail2ban-sshd-systemd.local`:
   ```bash
   sudo install -m 644 assets/fail2ban-sshd-systemd.local /etc/fail2ban/jail.d/zz-sshd-systemd.local
   ```
   The `zz-` prefix makes it load after `defaults-debian.conf`; `.local` files override `.conf` files. It sets the
   backend under `[sshd]` itself, because `jail.conf`'s `[sshd]` has its own `backend = %(sshd_backend)s` and would
   not inherit a `[DEFAULT]` value.
4. **Test:** `sudo fail2ban-client -t` (configuration OK), then `sudo fail2ban-client -d | grep "'add', 'sshd'"` shows `systemd`.
5. **Apply:** `sudo systemctl restart fail2ban` (fail2ban has no reload that recovers a failed start; restarting it does
   not affect SSH sessions or the sites).
6. **Verify:** `systemctl is-active fail2ban` → `active`; `sudo fail2ban-client status sshd` shows `Journal matches`
   and `Total failed` growing within minutes; `systemctl --failed` no longer lists fail2ban; a NEW SSH session from
   the owner still works.
7. **Rollback:** `sudo rm /etc/fail2ban/jail.d/zz-sshd-systemd.local && sudo systemctl restart fail2ban` (it fails
   again as before), or stop it: `sudo systemctl stop fail2ban`.
   An admin banned by mistake: wait for `bantime`, or from the provider console
   `sudo fail2ban-client set sshd unbanip <ADMIN_IP>`.

## Pitfalls
- Do not install rsyslog just to create `auth.log`: it duplicates logging and adds a package; the journal backend is
  the intended path on journald-only systems.
- Keep defaults (`maxretry`, `findtime`, `bantime`) unless the owner asks; longer bans increase the cost of a mistake.
- Behind Cloudflare, do not point web jails at nginx logs before nginx logs the real client IP (`cloudflare` module):
  you would ban Cloudflare's addresses and cut off real users.
