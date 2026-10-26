# exim4 as an authenticated, TLS-only smarthost client (Debian/Ubuntu)

Detailed procedure behind SKILL.md steps 1–4 and the rollback. `scripts/exim-smarthost-setup.sh` does §3–§4 and the
checks of §6; this file explains each piece so it can be reviewed, adapted or done by hand.

## Contents
1. How it works, and why each setting
2. When the server differs
3. Backup
4. Configure
5. Credentials (owner)
6. Generate, validate, restart
7. Tests that send nothing
8. One test message (owner's permission)
9. Rollback
10. Reading the mainlog; troubleshooting
11. The self-signed certificate warning and STARTTLS on loopback
12. Package upgrades and the template edit

## 1. How it works, and why each setting
1. Moodle's PHPMailer connects to `127.0.0.1:25` with no TLS and no login. exim writes the message to its spool and
   answers `250` in milliseconds; the PHP request goes on. This is the whole speed gain: the page no longer waits for
   a TLS handshake and login across the internet (a second or two per mail on the first server, tens of seconds
   when the provider was slow, because PHPMailer's default timeout is 300 s).
2. exim immediately starts a background delivery to the smarthost. With `REMOTE_SMTP_SMARTHOST_PROTOCOL = smtps` it
   speaks TLS from the first byte (port 465), verifies the certificate (Debian default
   `REMOTE_SMTP_SMARTHOST_TLS_VERIFY_HOSTS = *`), then logs in with the line from `/etc/exim4/passwd.client`.
3. On a temporary failure the Debian retry rule (`F,2h,15m; G,16h,1h,1.5; F,4d,6h`) applies and a queue runner retries
   every `QUEUEINTERVAL` (5 min instead of the default 30 min, because these are password resets and welcome mails).
4. Local mail (cron output to the web user, root) is still delivered locally: configtype `smarthost` keeps local
   domains local, unlike `satellite`.

| Setting | Why |
|---|---|
| `dc_eximconfig_configtype='smarthost'` | relay non-local mail, keep local delivery |
| `dc_smarthost='HOST::465'` | Debian's `host::port` syntax (double colon) |
| `dc_local_interfaces='127.0.0.1 ; ::1'` (unchanged) | nobody but local programs may submit; the firewall is a second layer, not the first |
| `REMOTE_SMTP_SMARTHOST_PROTOCOL = smtps` | port 465 is implicit TLS; without it exim speaks plain SMTP to 465 and hangs |
| `REMOTE_SMTP_SMARTHOST_HOSTS_REQUIRE_TLS = *` | never send the password or mail in clear, even if TLS breaks |
| `hosts_require_auth = *` (template edit) | the stock transport only *tries* auth (`hosts_try_auth`). If the login fails (wrong line, rotated token), exim sends **without** auth, the provider answers 5xx and the message bounces for good. With this line a failed login is a deferral: the mail stays queued and is retried after the owner fixes the token |
| `QUEUEINTERVAL='5m'` | retries within minutes; needs an exim restart (it is a daemon argument) |

The client authenticators `plain` and `login` in the Debian template only send passwords over TLS
(`AUTH_CLIENT_ALLOW_NOTLS_PASSWORDS` unset): leave it unset.

## 2. When the server differs
| Found in discovery | Do |
|---|---|
| configtype `local` | the normal case: nothing can depend on exim relaying today |
| configtype `smarthost` with another smarthost | something already relays through it: find out what (mainlog `R=smarthost` senders), ask the owner |
| configtype `internet` or a listener on a public address | exim may receive mail for the domain or deliver direct-to-MX for other apps: **stop and ask** |
| `satellite` | all mail, including local cron mail, goes out: propose `smarthost` instead, ask |
| `/etc/exim4/exim4.conf` exists | hand-written config that bypasses the generator: **stop and ask** |
| `dc_use_split_config='true'` | same changes, in `conf.d/main/000_localmacros` and `conf.d/transport/30_exim4-config_remote_smtp_smarthost` (the script handles it) |
| template has no `REMOTE_SMTP_SMARTHOST_PROTOCOL` (old exim4-config) | use port 587 (STARTTLS): only the `HOSTS_REQUIRE_TLS` macro |
| provider only offers 587, or 465 is blocked by the cloud | port 587; check egress first: `timeout 5 bash -c '</dev/tcp/HOST/587' && echo open` |
| provider requires OAuth2 (Moodle `smtpauthtype=XOAUTH2`, or a mailbox provider that retired password SMTP) | exim cannot do it: **stop**. Options for the owner: the provider's IP-based relay/connector, an app password, or a transactional provider |
| cPanel/Plesk/DirectAdmin manage exim | do not edit by hand: **stop and ask** |
| RHEL/Alma/Rocky | usually Postfix: references/postfix-relay.md |
| the site's mail domain is in `/etc/mailname` or `dc_other_hostnames` | mail to staff at that domain would be delivered locally: `route-test.sh` flags it. Fixing it changes how cron mail is addressed: propose separately |
| `Unrouteable address` lines in recent mainlogs | some local program mails external addresses today; after the change those mails leave the server. Identify the sender (`U=`) first |
| root forwarded to an external address in `/etc/aliases` | system mail will start leaving with `From: root@<hostname>`, which the provider rejects (frozen bounces). Agree what to do first |

## 3. Backup
`exim-smarthost-setup.sh --apply` copies each file to `<file>.bak-YYYY-MM-DD` (letter suffix for a second copy the
same day) and lists them in `/root/msc-mail-YYYY-MM-DD/exim-backups.txt` (directory mode 700):
`update-exim4.conf.conf`, the local macros file (recorded as ABSENT when new), the template or transport file,
`/etc/default/exim4`, and `passwd.client` (still without credentials at this point).
Also record the queue size before: `sudo exim4 -bpc` (expect 0).

## 4. Configure
Run the plan first, show it to the owner with the proposal, then apply:
```bash
bash scripts/exim-smarthost-setup.sh --host <SMARTHOST> --port 465            # plan, read-only
bash scripts/exim-smarthost-setup.sh --host <SMARTHOST> --port 465 --apply    # after approval
```
By hand, the same four edits:
1. `/etc/exim4/update-exim4.conf.conf`: change only `dc_eximconfig_configtype='smarthost'` and
   `dc_smarthost='<SMARTHOST>::465'`. Keep `dc_local_interfaces` and `dc_relay_nets=''` (the generator always adds
   `127.0.0.1 : ::1` to the relay networks).
2. `/etc/exim4/exim4.conf.localmacros` (mode 644): see `assets/exim4.conf.localmacros.example`.
3. Template, transport `remote_smtp_smarthost`: directly after the `hosts_try_auth = <; ${if exists{CONFDIR/passwd.client} …`
   block (it ends with a line `      }`) and before `.ifdef REMOTE_SMTP_SMARTHOST_HOSTS_AVOID_TLS`, add:
   ```
     # auth must succeed; a failed login defers (retry) instead of sending unauthenticated
     hosts_require_auth = *
   ```
   Use a small python script that asserts the anchor occurs exactly once in that transport, not `sed`.
4. `/etc/default/exim4`: `QUEUEINTERVAL='5m'`; `QUEUERUNNER` must stay `combined` (or `separate`).

## 5. Credentials (owner)
The owner runs `scripts/owner-add-credentials.sh <SMARTHOST>` in his own SSH session (owner steps in
`assets/owner-steps-ar.md`). It refuses to run without a terminal, reads both values without echo, writes
`<SMARTHOST>:<user>:<password>` to `passwd.client` (root:Debian-exim 640) and prints only field counts and lengths.
Then Claude runs `bash scripts/check-credentials.sh`:
- format (man `exim4_passwd_client`): `host:login:password`; the password may contain `:`, the login may not.
- exim looks the line up (`nwildlsearch`) by the **name it connected to after DNS resolution**, then by the IP address.
  If the provider's name is a CNAME, add a line for the canonical name (or a `*.provider-domain` wildcard line);
  `check-credentials.sh` compares the key with the host shown by `exim4 -bt` and says whether it matches.
- An IP line works as a last resort but breaks when the provider changes addresses: avoid it.
- `/etc/exim4/passwd.client.bak-*` copies made **after** the owner added credentials contain them: delete them after
  the 14 stable days (the owner runs the delete; core-rules §6).

## 6. Generate, validate, restart
```bash
sudo update-exim4.conf                       # regenerates /var/lib/exim4/config.autogenerated
sudo exim4 -bV | tail -2                     # 'Configuration file is /var/lib/exim4/config.autogenerated', no errors
sudo exim4 -bP transport remote_smtp_smarthost | grep -E 'hosts_(try|require)_auth|^protocol|hosts_require_tls'
sudo systemctl restart exim4 && systemctl is-active exim4     # restart, not reload: QUEUEINTERVAL is a daemon argument
sudo ss -Hltn 'sport = :25'                  # still only 127.0.0.1:25 and [::1]:25
sudo test -s /var/log/exim4/paniclog && echo PANIC || echo 'paniclog empty'
```
Restarting exim is safe at any hour while Moodle is not switched yet: only local cron mail passes through it, and
anything submitted during the second of the restart waits in the spool.

## 7. Tests that send nothing
`bash scripts/route-test.sh --from <noreplyaddress> --to <owner mailbox>`:
- `exim4 -bt <WEBUSER>` → `router = local_user, transport = mail_spool` (cron mail stays local).
- `exim4 -bt probe@example.com` → `router = smarthost, transport = remote_smtp_smarthost`, `host <SMARTHOST> [ip] port=465`.
- `exim4 -bt postmaster@<mail domain>` → smarthost too (the site's own domain is not treated as local).
- `exim4 -bh 127.0.0.1` with `EHLO / MAIL FROM / RCPT TO / QUIT`: a simulated SMTP session that runs the real ACLs
  without the daemon, the queue or the network. MAIL and RCPT must get `250`: that is exactly what Moodle will do.

## 8. One test message (owner's permission)
Only after the owner allowed one message to his own mailbox:
```bash
bash scripts/send-one-test.sh --from <noreplyaddress> --to <owner mailbox> --i-have-owner-permission
```
Expect, for that message id: `<=` (accepted, `P=local`), `=> … R=smarthost T=remote_smtp_smarthost H=<SMARTHOST> [ip]
X=TLS1.3… CV=yes A=plain C="250 …"`, then `Completed`; queue back to 0; paniclog empty; the owner confirms arrival.
- The From must be Moodle's `noreplyaddress` on the provider-verified domain. Any other domain is refused
  (`553 Sender is not allowed to relay`) and leaves a frozen bounce (on the first server this happened when a test
  harness reached the live exim with `noreply@example.org`).
- Never `exim -v` or `-d`: verbose traces can print the base64 AUTH exchange. The mainlog shows `A=plain:<login id>`;
  the scripts mask it, mask it yourself when quoting log lines.
- **Stop and roll back exim (§9) if** there is no `=>` line, the queue does not drain, or the paniclog is not empty.
  With `hosts_require_auth`, a login problem shows as a `==` deferral, never as an unauthenticated send.
- If DNS fixes are pending (mail-dns.md), this same message also serves the header check, so do the DNS first when
  possible: one message instead of two.

## 9. Rollback
1. **Moodle first** (references/moodle-switch.md, rollback): from then on mail bypasses exim again.
2. **Drain exim**: `sudo exim4 -qff; sleep 30; sudo exim4 -bpc` → 0. Do not revert exim while messages are queued:
   in `local` mode queued remote mail becomes unrouteable and bounces.
3. **Revert files**: `bash scripts/exim-smarthost-setup.sh --rollback /root/msc-mail-<date>/exim-backups.txt`
   (restores the oldest backups, moves the new macros file into the state directory, regenerates, validates; refuses
   while mail is queued unless `--force`). Then `sudo systemctl restart exim4`. Restoring the original `passwd.client`
   removes the credentials.

## 10. Reading the mainlog; troubleshooting
Symbols: `<=` arrival, `=>` delivery, `->` extra recipient of the same delivery, `==` deferred (will retry),
`**` failed permanently (bounce generated), `Completed` all done, `*** frozen ***` in `exim4 -bp`.
```bash
sudo exim4 -bpc                                   # queue size
sudo exim4 -bp | grep -c 'frozen'                 # frozen
sudo grep -E ' (==|\*\*) ' /var/log/exim4/mainlog | tail   # shows recipients: do not paste them into tickets
sudo exim4 -Mvh <id>                              # headers of one queued message (subject, from)
```
| Symptom | Likely cause | Fix |
|---|---|---|
| `== … 535 Authentication failed` | wrong or rotated token | owner reruns `owner-add-credentials.sh <SMARTHOST> --replace`; queued mail goes at the next run (`sudo exim4 -qf` to hurry) |
| `== … authentication required` / no `A=` | no `passwd.client` line matches the resolved name | `check-credentials.sh`; add the canonical-name line |
| `** … 553 Sender is not allowed to relay` | From domain not verified at the provider | send from `noreplyaddress`; check Moodle's "allowedemaildomains"/from settings |
| `== … TLS session: … certificate verification failed` | name mismatch or missing CA bundle | `ca-certificates` package; correct host name in `dc_smarthost` |
| `== … Connection timed out` | egress blocked (cloud firewall), wrong port/protocol | TCP test to 465/587; `protocol = smtps` only for 465 |
| `== … HELO/EHLO rejected` | provider wants a FQDN greeting | `REMOTE_SMTP_HELO_DATA = <SITE>` in local macros, regenerate, restart |
| frozen bounce `<>` to the noreply address | bounce of a rejected message; the provider refuses the null sender | Debian `ignore_bounce_errors_after = 2d` discards it; remove sooner only with approval: `sudo exim4 -Mrm <id>` |
| queue grows, no errors | provider rate limit or credits exhausted | provider console first |
| messages 11+ of a cron batch wait up to 5 min | `smtp_accept_queue_per_connection = 10` | Moodle `smtpmaxbulk = 10` |

## 11. The self-signed certificate warning and STARTTLS on loopback
At startup the mainlog shows `Warning: No server certificate defined; will use a selfsigned one. Suggested action:
either install a certificate or change tls_advertise_hosts option`. exim advertises STARTTLS on 127.0.0.1 with a
certificate it generated itself. This is harmless here: Moodle's mailer sets `SMTPAutoTLS = false`
(`lib/phpmailer/moodle_phpmailer.php`, since 2016) and Moodle's "SMTP security" is set to none, so Moodle never
starts TLS on loopback. Do not "fix" it by setting Moodle's SMTP security to TLS: verification of a self-signed
certificate would fail and every mail with it.
If discovery shows `phpmailer_smtpautotls=true` (a patched or very old mailer), PHPMailer would try STARTTLS and fail:
stop advertising TLS with an empty `MAIN_TLS_ADVERTISE_HOSTS =` line in the local macros (exim only listens on
loopback, so nobody loses anything; it also silences the warning), regenerate, restart, rerun the connect test; or
stop and ask. When `SMTPAutoTLS` is false, leave the default alone: one change less.

## 12. Package upgrades and the template edit
`/etc/exim4/exim4.conf.template` (and the conf.d files) are dpkg conffiles. When an `exim4-config` update changes
them, dpkg asks what to do; unattended-upgrades skips such packages, so the update waits for a manual
`apt-get upgrade`. Then keep the local version (or merge) and confirm the line is still there:
`grep -n hosts_require_auth /etc/exim4/exim4.conf.template` (exactly one). `mail-daily-check.sh` flags a lost line
as a TRIGGER. Record the edit in the operations log's "customised files" table.
