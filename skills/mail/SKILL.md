---
name: mail
description: Stops Moodle pages from waiting for the external SMTP server by handing mail to a local MTA queue (Debian exim4 smarthost over SMTPS 465 with TLS and authentication mandatory, or Postfix), switches Moodle to 127.0.0.1:25 safely in one step with a ready rollback, watches the relay for 14 days, and checks mail DNS (DKIM, the provider's bounce/Return-Path CNAME, SPF, DMARC) after a move to Cloudflare. Use it whenever signup, self-enrolment or forgot-password pages are slow, PHPMailer shows up in the PHP-FPM slow log, Moodle's outgoing mail points straight at a provider (ZeptoMail, Microsoft 365, Google, SendGrid, Mailgun, SES...), bounces or SPF/DKIM/DMARC failures appeared after a DNS move, or the owner asks for SPF/DMARC — even if they only say "emails are slow", "the enrol page hangs" or "students don't get the password mail".
---

# Mail: background delivery through a local MTA, and mail DNS

## 1. Read first
Read `../../shared/core-rules.md` before anything else (change protocol, secrets, approvals, log format). Paths below
are relative to this skill's base directory (`<SKILL_DIR>`, shown when the skill loads). Values come from `~/.config/moodle-server-care/server.env` (run
`../start/scripts/detect-env.sh` if it is missing or older than a day); every script accepts env overrides.

## 2. When to use; signs
Moodle sends mail with PHPMailer **inside the student's HTTP request**: TLS handshake, login and transfer to the
provider happen while the page waits. On the first server that cost a second or two on every enrolment, signup and
password reset, and tens of seconds when the provider was slow (PHPMailer's default timeout is 300 s and Moodle does
not lower it).
Signs:
- `smtphosts` in Moodle is a remote provider (`smtp.<provider>:465` or `:587`).
- PHP-FPM slow log stacks end in `email_to_user` → PHPMailer → `stream_socket_client`.
- High p50 on `/enrol/index.php`, `POST /login/signup.php`, `POST /login/forgot_password.php`; 499s on them.
- After a DNS move: mail lands in spam, bounces stop being processed, DMARC reports (if any) show SPF failing.

What this module changes: the local MTA's relay config, Moodle's four outgoing-mail settings, and (by the owner, in
the DNS panel) mail DNS records. What does not change: the provider, the From address, DKIM signing, anything
students see. Expected gain: those pages lose the SMTP time (first server: about a second or two per mail down to
a few milliseconds), and mail is
retried from the queue when the provider is slow or down instead of failing the page.

## 3. Discovery (read-only)
```bash
bash scripts/mail-discover.sh            # Moodle mail settings (no secrets), MTA and its config, credentials present?,
                                         # queue/frozen/paniclog, password-loop counts, slow-log evidence, hints
bash scripts/mail-dns-check.sh --domain <noreply domain> --dkim-selector <sel> --bounce <bounce name>
```
Read the `hints` block. It says APPLIES, DIFFERS (adapt), CHECK (explain before going on) or STOP (ask the owner).
Useful by hand: `sudo ss -Hltnp 'sport = :25'`, `grep ^dc_ /etc/exim4/update-exim4.conf.conf`,
`sudo exim4 -bP transport remote_smtp_smarthost`, `sudo exim4 -bpc`, `postconf -n` (Postfix).

| Discovery shows | Do |
|---|---|
| Moodle → provider directly; exim4 `local` on loopback | the case this module was built on: full procedure |
| `smtphosts` already `127.0.0.1:25` | done before: run `mail-daily-check.sh` and the DNS part only |
| `smtphosts` empty (PHP `mail()`) | pages already hand mail to the MTA: skip the switch; check MTA relay + DNS (moodle-switch.md §2) |
| Postfix on port 25 | references/postfix-relay.md for steps 1–4, the rest unchanged |
| no MTA | proposing a package install (`exim4-daemon-light` on Debian/Ubuntu) is a separate approval |
| MTA listens publicly, exim `internet`, Postfix with mailboxes, a hosting panel, `/etc/exim4/exim4.conf` | **stop and ask**: it may be a real mail server |
| `smtpauthtype=XOAUTH2`, or the provider only allows OAuth2 | **stop and ask**: exim/Postfix cannot use it |
| mail settings forced in `config.php` | the switch needs a reviewed `config.php` edit instead |
| `Unrouteable address` lines, root forwarded to an external address | something mails outside today and will start delivering: agree first |
| split exim config, port 465 blocked, old template without the PROTOCOL macro | adapt: the script handles split config; use `--port 587` |

## 4. What to propose to the owner (Arabic)
Fill the values from discovery; keep it short. Ask for one approval per stage (DNS, exim, test message, switch).
```
## اقتراح: إرسال بريد المنصة في الخلفية

**المشكلة:** عند التسجيل أو الاشتراك في مقرر أو استعادة كلمة المرور، تنتظر الصفحة حتى يتصل Moodle بخادم البريد
(<PROVIDER>) ويسلّمه الرسالة. يستغرق ذلك نحو <X> ثانية في كل مرة، وقد يصل إلى <Y> ثانية إذا كان المزوّد بطيئاً.
الدليل: <الأرقام من سجل الخادم>.

**الحل:** يسلّم Moodle الرسالة إلى خادم بريد صغير على الخادم نفسه خلال جزء من الثانية، وهو يرسلها إلى <PROVIDER>
في الخلفية بتشفير وتسجيل دخول إلزاميين، ويعيد المحاولة تلقائياً كل 5 دقائق إذا تعطّل المزوّد.

**لا يتغير:** المزوّد، وعنوان المرسل، وتوقيع DKIM، وما يراه الطلاب.

| المرحلة | ماذا يحدث | من ينفّذ | أثر على الطلاب |
|---|---|---|---|
| 1 | فحص سجلات DNS للبريد، وتصحيحها في Cloudflare إن لزم | Claude يفحص، وأنت تعدّل | لا يوجد |
| 2 | إعداد خادم البريد المحلي (Moodle لا يتغير بعد) | Claude | لا يوجد |
| 3 | إدخال بيانات دخول SMTP بأمر لا يُظهرها | أنت | لا يوجد |
| 4 | اختبارات بلا إرسال، ثم رسالة اختبار واحدة إلى بريدك بإذنك | Claude | لا يوجد |
| 5 | تحويل Moodle إلى الخادم المحلي في ساعة هادئة (<TIME>) | Claude | صفحات أسرع |
| 6 | فحص يومي لمدة 14 يوماً، ثم حذف كلمة المرور القديمة من Moodle بموافقتك | Claude | لا يوجد |

**الرجوع:** خلال 5 دقائق بأمر واحد يعيد إعدادات Moodle السابقة، ونسخ احتياطية لكل ملف.
**المخاطر:** منخفضة. أي خلل يظهر في رسالة الاختبار قبل تحويل Moodle، وبعد التحويل تبقى الرسائل في الطابور ولا تضيع.
**نحتاج منك:** موافقتك على المراحل، وإدخال بيانات الدخول (المرحلة 3)، والإذن برسالة الاختبار إلى <OWNER_MAILBOX>.
هل توافق على البدء بالمرحلة 1؟
```
Owner instructions (credentials command, Cloudflare records, header check, close-out): fill and send
`assets/owner-steps-ar.md`.

## 5. Procedure
One stage at a time; re-read the tail of the operations log before each change; log each change before reporting.

**Step 0. Mail DNS (the check is read-only; the owner's fixes can come before the relay work)** — references/mail-dns.md
- Backup: the owner exports the Cloudflare zone before editing (DNS > Records > Import and Export).
- Change: the owner enters the records Claude prepared (bounce CNAME **DNS only**, DKIM, one SPF, DMARC `p=none` via
  Cloudflare DMARC Management).
- Test/verify: `mail-dns-check.sh` on both resolvers until clean.
- Rollback: re-enter the exported values. Header check comes with the step 4 message.

**Step 1. Configure the MTA (Moodle unchanged)** — references/exim-smarthost.md §3–§6
- Backup + change: `bash scripts/exim-smarthost-setup.sh --host <SMARTHOST> --port 465` (plan, show the owner), then
  `--apply` (backs up five files with a manifest in `/root/msc-mail-<date>/`, sets configtype `smarthost`,
  `dc_smarthost`, local macros `smtps` + TLS required, `hosts_require_auth = *` in the transport, `QUEUEINTERVAL 5m`).
- Test: the script runs `update-exim4.conf`, `exim4 -bV`, `exim4 -bP transport remote_smtp_smarthost` and restores
  the backups by itself if any check fails.
- Apply: `sudo systemctl restart exim4 && systemctl is-active exim4` (restart: the queue interval is a daemon argument).
- Verify: `sudo ss -Hltn 'sport = :25'` shows loopback only; paniclog empty; `route-test.sh` local mail stays local.
  Until credentials exist, remote mail would defer (not leak): say so in the log.
- Rollback: `bash scripts/exim-smarthost-setup.sh --rollback /root/msc-mail-<date>/exim-backups.txt`, restart exim.
- Postfix: references/postfix-relay.md §2–§3.

**Step 2. Credentials (owner)**
- The owner runs `sudo bash <SKILL_DIR>/scripts/owner-add-credentials.sh <SMARTHOST>` in **his own** SSH session (it
  refuses to run without a keyboard, reads without echo, sets `root:Debian-exim 640`). Claude never sees the values.
- Verify: `bash scripts/check-credentials.sh`: entries with 3+ fields and non-zero lengths, mode right, and the key
  matches the host name exim actually resolves (CNAME trap).
- Rollback: restoring the step 1 backup of `passwd.client` removes them.

**Step 3. Tests that send nothing**
- `bash scripts/route-test.sh --from <noreplyaddress> --to <owner mailbox>`: `exim4 -bt` for the web user (local),
  an external address and the site's own domain (both smarthost), then `exim4 -bh 127.0.0.1` simulating Moodle's
  session (MAIL/RCPT 250). Nothing is delivered. Any FAIL: fix before step 4.

**Step 4. One test message, with the owner's permission** — exim-smarthost.md §8
- `bash scripts/send-one-test.sh --from <noreplyaddress> --to <owner mailbox> --i-have-owner-permission` (refuses a
  second send the same day). Expect `=> … R=smarthost … X=TLS… CV=yes A=… C="250 …"`, queue 0, paniclog empty.
  The owner confirms arrival and, if step 0 is done, reports spf/dkim/dmarc = pass from the headers.
- Stop here and roll back step 1 if there is no `=>`, the queue does not drain, or the paniclog is not empty.

**Step 5. Switch Moodle (quiet hour, owner's go-ahead)** — references/moodle-switch.md §3–§6
- Backup: `bash scripts/moodle-mail.sh --dump-rollback | sudo sh -c "umask 077; cat > /root/msc-mail-<date>/moodle-smtp-rollback.txt"`
  (root 600; holds the SMTP username, never the password). Baseline: `moodle-mail.sh --connect-test` before.
- Change (one PHP process, host last): `bash scripts/moodle-mail.sh --execute` → `smtphosts 127.0.0.1:25`,
  `smtpsecure` empty, `smtpuser` empty, `smtpmaxbulk 10`; `smtppass` kept for rollback. Note the printed time.
- Test/verify without sending: `bash scripts/moodle-mail.sh --connect-test` → `host=127.0.0.1:25 secure=[] auth=no
  connect=OK in 0.00Xs`.
- Rollback: `sudo cat /root/msc-mail-<date>/moodle-smtp-rollback.txt | bash scripts/moodle-mail.sh --restore`.

**Step 6. Watch the first real messages; measure after 24 h** — moodle-switch.md §7
- mainlog since the switch time: `<= … [127.0.0.1] P=esmtp` then `=> … R=smarthost … C="250`. Queue near 0.
- After a full day: `sudo bash ../audit/scripts/measure-endpoints.sh --from "<day before 00:00>" --to "<day before
  24:00>" --from2 "<day after 00:00>" --to2 "<day after 24:00>"` (its default endpoints include the enrol page and
  the signup and forgot-password submits; read those rows); new PHPMailer frames in the FPM slow log should be 0.
  Report exactly what was measured.

**Step 7. Fourteen days of daily checks, then close-out** — moodle-switch.md §8
- Daily `bash scripts/mail-daily-check.sh` → OK / CHECK (explain each item) / TRIGGER (roll back the Moodle part the
  same day unless explained). Triggers: unexplained `**` or frozen message, queue > 50 and growing, paniclog not empty,
  `hosts_require_auth` lost after a package upgrade, auth deferrals the owner cannot fix at once.
- After 14 clean days, with approval: `moodle-mail.sh --clear-smtppass --confirm`; the owner deletes
  `passwd.client.bak-*` copies made after credentials were added; set the DMARC tightening date (2–4 weeks of clean
  reports → `p=quarantine`).

## 6. Verification checklist
- [ ] MTA active, listening on `127.0.0.1:25` / `[::1]:25` only
- [ ] `exim4 -bP transport remote_smtp_smarthost`: `protocol = smtps` (465), `hosts_require_tls = *`, `hosts_require_auth = *`
- [ ] `QUEUEINTERVAL='5m'`, exim restarted after the change
- [ ] credentials present (`check-credentials.sh` ok), file `root:Debian-exim 640`, key matches the resolved host
- [ ] route tests: local user local; external and own domain via smarthost; `-bh` MAIL/RCPT 250
- [ ] one test message: `=>` with TLS, `CV=yes`, `A=`, `250`; queue 0; paniclog empty; owner confirmed arrival
- [ ] Moodle values read back; nothing forced in `config.php`; `smtppass` kept; rollback file root 600
- [ ] connect test: `127.0.0.1:25`, no TLS, no auth, milliseconds
- [ ] first real Moodle messages delivered via the smarthost
- [ ] 24 h latency before/after recorded with n and source
- [ ] DNS: DKIM present; bounce CNAME real and DNS-only on both resolvers; one SPF; DMARC `p=none` with `rua`
- [ ] header check: spf, dkim, dmarc = pass
- [ ] 14 daily checks clean; `smtppass` cleared; credential backups deleted by the owner; DMARC date set
- [ ] log entries written; customised-files table row added (four exim files + Moodle settings); handbook to-do updated

## 7. Log entry examples (format from core-rules §3)
```
### YYYY-MM-DD HH:MM — exim4 configured as smarthost for <provider> (Moodle not switched yet)  (session: <name>, approved by owner: yes)
- What/why: first half of background mail; Moodle's direct SMTP costs <X> s per mail-sending page.
- Files/settings touched: update-exim4.conf.conf configtype local → smarthost, dc_smarthost '' → <SMARTHOST>::465;
  new exim4.conf.localmacros (PROTOCOL smtps, HOSTS_REQUIRE_TLS *); template remote_smtp_smarthost + hosts_require_auth *;
  /etc/default/exim4 QUEUEINTERVAL 30m → 5m. update-exim4.conf, -bV OK, restart HH:MM.
- Backup / rollback: *.bak-YYYY-MM-DD, manifest /root/msc-mail-YYYY-MM-DD/exim-backups.txt; exim-smarthost-setup.sh --rollback.
- Verified: active, loopback only; -bP protocol smtps, hosts_require_tls *, hosts_require_auth *; -bt local → mail_spool,
  external → smarthost port 465; queue 0; paniclog empty.
- Next: owner adds credentials; routing tests; one test message (permission); Moodle switch.

### YYYY-MM-DD HH:MM — Moodle outgoing mail switched to the local relay  (session: <name>, approved by owner: yes)
- What/why: pages hand mail to exim in milliseconds instead of waiting for <provider>.
- Files/settings touched (one PHP process, HH:MM:SS, config log): smtphosts <provider>:465 → 127.0.0.1:25; smtpsecure
  ssl → empty; smtpuser (<n> chars) → empty; smtpmaxbulk 100 → 10. Unchanged: smtpauthtype, smtppass (clear after 14 days).
- Backup / rollback: /root/msc-mail-YYYY-MM-DD/moodle-smtp-rollback.txt (root 600, username only);
  `sudo cat … | moodle-mail.sh --restore`.
- Verified: connect test 127.0.0.1:25 no TLS no auth in <N> s (was <X> s); test message HH:MM delivered (TLS1.3, auth, 250).
- Next: first real messages; latency after 24 h; daily checks until YYYY-MM-DD.
```
The owner's credential insertion and DNS edits get their own short entries ("owner; verified by session …"), with
values only where they are not secret (no tokens, report ids or report addresses).

## 8. Pitfalls we hit on the first server
- **The stock Debian transport only tries to authenticate.** A wrong or rotated token would have sent mail
  unauthenticated and bounced it for good. `hosts_require_auth = *` makes it a deferral; keep it, and re-check it
  after any `exim4-config` upgrade (the template is a conffile).
- **Port 465 needs `protocol = smtps`.** Without the macro exim speaks plain SMTP to an implicit-TLS port and hangs.
- **Do not switch Moodle before exim has delivered one real message**, and do not revert exim while mail is queued
  (in `local` mode queued remote mail becomes unrouteable and bounces). Order: Moodle first on the way back.
- **Verbose exim output leaks credentials.** `exim -v`/`-d` can print the base64 AUTH exchange; the mainlog shows
  `A=plain:<login id>`. Never use the flags; mask log quotes.
- **Wrong From = rejection + frozen bounce.** The provider accepts only its verified domain (`noreplyaddress`). A test
  with another domain got `553 Sender is not allowed to relay` and two frozen bounces.
- **A test harness reached the live relay.** A backup script under test called `/usr/sbin/sendmail` by absolute path,
  bypassed the harness mock and submitted two mails to production exim. Once the relay works, anything that calls
  sendmail reaches the internet: tests must find the MTA through `PATH` so mocks win (these scripts do).
- **Failure feedback moves out of the page.** exim accepts everything, so Moodle stops seeing provider rejections;
  undeliverable mail shows only as `**` lines and frozen bounces (removed after 2 days by Debian's default). Hence the
  daily check.
- **`validate_email()` runs before SMTP.** The new-user password loop (accounts regenerated every minute) was expected
  to end once exim accepted mail; it did not, because Moodle rejected the malformed addresses before any MTA saw them.
  Fix those accounts (correct or suspend, owner approval); `moodle-mail.sh --loop-check` finds them.
- **`smtpmaxbulk` 100 delays cron batches.** exim queues messages 11+ on one connection until the next queue run; 10
  keeps them immediate.
- **The self-signed certificate warning is harmless.** exim logs "No server certificate defined; will use a
  selfsigned one" at startup; Moodle never starts TLS on loopback (`SMTPAutoTLS = false`, SMTP security none). Do not
  set Moodle's SMTP security to TLS to "fix" it.
- **After the Cloudflare move, the bounce CNAME had silently disappeared.** A wildcard `*` record made the missing name
  resolve, so SPF for the Return-Path and bounce handling had been broken for days; SPF and DMARC did not exist at all.
  Check record *types* on two resolvers, and keep every mail CNAME DNS-only.
- **Estimated times in the log were wrong later.** Take change times from `date` printed by the scripts, not memory.

## 9. Files in this module
| File | Purpose |
|---|---|
| `scripts/mail-discover.sh` | read-only discovery and hints (applies / differs / check / stop) |
| `scripts/mail-dns-check.sh` | read-only DKIM / bounce / SPF / DMARC / wildcard check on two resolvers |
| `scripts/exim-smarthost-setup.sh` | plan (default) / `--apply` with backups, validation and auto-restore / `--rollback` |
| `scripts/owner-add-credentials.sh` | owner-only, no-echo credential insertion (exim or Postfix), `--replace` to rotate |
| `scripts/check-credentials.sh` | presence by field count and length, mode, key matches the resolved host |
| `scripts/route-test.sh` | `exim -bt` routing and `exim -bh` simulated session; live probe without DATA |
| `scripts/send-one-test.sh` | exactly one test message with the owner's permission; masked log lines and verdict |
| `scripts/moodle-mail.sh` + `moodle-mail.php` | Moodle side: show, dump-rollback, execute, restore, connect-test, send-test, loop-check, clear-smtppass |
| `scripts/mail-daily-check.sh` | daily OK / CHECK / TRIGGER for exim or Postfix |
| `scripts/_common.sh` | env loading, sudo, MTA detection, redaction, run-as-web-user helper |
| `references/exim-smarthost.md` | exim procedure, differences, mainlog reading, troubleshooting, TLS warning, upgrades |
| `references/postfix-relay.md` | Postfix equivalents and stop conditions |
| `references/moodle-switch.md` | Moodle settings, switch, watch, 14 days, rollback, password-loop lesson, stop-gap |
| `references/mail-dns.md` | DNS records, the Cloudflare traps, checks, owner steps, header check, DMARC tightening |
| `assets/owner-steps-ar.md` | Arabic owner instructions (credentials, Cloudflare records, header check, close-out) |
| `assets/exim4.conf.localmacros.example`, `assets/postfix-main.cf.example` | reviewed configuration templates |
