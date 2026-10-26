# Postfix equivalents (and when to stop)

Use this when discovery finds Postfix listening on port 25 instead of exim. The Moodle side (moodle-switch.md) and the
DNS side (mail-dns.md) are identical; only the MTA steps change. The same scripts work: `mail-discover.sh`,
`owner-add-credentials.sh --mta postfix`, `check-credentials.sh`, `route-test.sh`, `send-one-test.sh`,
`mail-daily-check.sh` detect Postfix themselves. There is no Postfix configure script: the change is a handful of
`postconf -e` lines, done one at a time.

## 1. Stop conditions (ask the owner first)
- `inet_interfaces` is not `loopback-only`/`localhost` **and** the domain's MX points to this server, or
  `virtual_mailbox_domains`/Dovecot exist: Postfix is a real mail server for people. Changing `relayhost` changes how
  all their outgoing mail leaves. Stop.
- The server is managed by a panel (Plesk, Virtualmin, ISPConfig, cPanel): the panel rewrites `main.cf`. Stop.
- `relayhost` is already set to something else: another application relies on it. Find out what, ask.
- `libsasl2-modules` is missing (Debian/Ubuntu): Postfix cannot do AUTH PLAIN/LOGIN. Installing it is a package
  install: propose it with the plan.
- The provider requires OAuth2 only: Postfix cannot do it. Stop.
- Other MTAs: `nullmailer` (queues, but no SMTP listener: Moodle would need PHP `mail()`), `msmtp`/`ssmtp` (no queue,
  sends synchronously: no gain), OpenSMTPD, sendmail: not covered. Stop and ask; replacing the MTA is a separate,
  approved change (exim4-daemon-light is the small, well-trodden choice on Debian).

## 2. Backup
```bash
D=$(date +%F); sudo cp -a /etc/postfix/main.cf /etc/postfix/main.cf.bak-$D
sudo cp -a /etc/postfix/master.cf /etc/postfix/master.cf.bak-$D
sudo postconf -n > ~/postconf-before-$D.txt         # non-secret; compare after (operator's home, not /tmp)
sudo postqueue -p | tail -n 1                       # queue before
```

## 3. Configure
One `postconf -e` per line, values from `assets/postfix-main.cf.example`:
```bash
sudo postconf -e 'inet_interfaces = loopback-only'        # only if not already loopback (needs a restart, not a reload)
sudo postconf -e 'relayhost = [<SMARTHOST>]:465'
sudo postconf -e 'smtp_tls_wrappermode = yes'             # 465 = TLS from the first byte (Postfix >= 3.0)
sudo postconf -e 'smtp_tls_security_level = secure'       # encrypted and certificate must match the host
sudo postconf -e 'smtp_tls_CApath = /etc/ssl/certs'
sudo postconf -e 'smtp_sasl_auth_enable = yes'
sudo postconf -e "smtp_sasl_password_maps = $(postconf -h default_database_type):/etc/postfix/sasl_passwd"
sudo postconf -e 'smtp_sasl_security_options = noanonymous'
sudo postconf -e 'smtp_sasl_tls_security_options = noanonymous'
```
- Brackets in `relayhost` mean "this host, no MX lookup". The credentials key must be written exactly the same way.
- Port 587: `relayhost = [<SMARTHOST>]:587`, no `smtp_tls_wrappermode`, keep `secure`.
- Keep `mydestination` for local names only (`$myhostname, localhost…`). If it contains the site's mail domain, mail
  to staff at that domain is delivered locally (`route-test.sh` flags it): propose removing it separately.
- Queue retries: Postfix retries deferred mail from `minimal_backoff_time` (300 s) on; `queue_run_delay` is 300 s by
  default. Nothing to change.

**Requiring authentication.** Postfix has no exact `hosts_require_auth`. `smtp_sasl_auth_soft_bounce = yes` (the
default since 2.5) turns a rejected login (535) into a deferral. But if the password map has no entry for the
relayhost key, Postfix sends **without** AUTH and the provider's 5xx bounces the mail. So:
1. `check-credentials.sh` must report "lookup … returns a value: yes" before Moodle is switched.
2. Optionally set `soft_bounce = yes` for the first 24–48 hours (every 5xx becomes a 4xx and mail stays queued while
   you watch), then remove it: it also delays genuine bounces.

## 4. Credentials (owner)
`sudo bash owner-add-credentials.sh <SMARTHOST> 465 --mta postfix` in the owner's own terminal: writes
`[<SMARTHOST>]:465 <user>:<password>` to `/etc/postfix/sasl_passwd` (root 600), runs `postmap`, sets the map file to
600. Spaces in the password are not supported by this format; if the provider's token has one, stop and ask.

## 5. Test, apply, verify
```bash
sudo postfix check                         # silent when the configuration is valid
sudo systemctl reload postfix              # restart only if inet_interfaces changed
sudo ss -Hltn 'sport = :25'                # 127.0.0.1:25 / [::1]:25 only
bash scripts/check-credentials.sh          # key matches relayhost, map file current, lookup returns a value
bash scripts/route-test.sh --from <noreplyaddress> --to <owner mailbox>
```
`route-test.sh` holds a real SMTP dialogue with the local daemon that stops before DATA (EHLO, MAIL, RCPT, RSET,
QUIT): nothing is queued. Postfix has no equivalent of `exim -bh`.
Then the one test message (owner's permission): `send-one-test.sh … --i-have-owner-permission`. Expect in the mail log
for that queue id: `postfix/smtp[…]: <id>: to=<…>, relay=<SMARTHOST>[ip]:465, … status=sent (250 …)`. The TLS
session appears as a separate line (`Verified TLS connection established to <SMARTHOST>…`) when
`smtp_tls_loglevel` is 1 or higher.

## 6. Daily check and log reading
`mail-daily-check.sh` counts `status=sent`, `status=deferred`, `status=bounced` and `SASL authentication failed` for
the day (from `/var/log/mail.log`, or journald when there is no mail.log), plus the queue size.
```bash
sudo postqueue -p | tail -n 1                       # queue
sudo grep -E 'status=(deferred|bounced)' /var/log/mail.log | tail   # shows recipients: do not paste into tickets
sudo postqueue -f                                   # retry the deferred queue now (after fixing a token)
```

## 7. Rollback
1. Moodle first (moodle-switch.md §9).
2. Let Postfix drain: `sudo postqueue -f`, wait until `postqueue -p` says the queue is empty.
3. Restore `main.cf` (and `master.cf` if touched) from the `.bak-<date>` copies, `sudo postfix check`,
   `sudo systemctl reload postfix` (restart if `inet_interfaces` changed). Move `sasl_passwd*` into a root-only archive
   (they hold the credentials; the owner deletes them later).
