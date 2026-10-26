# Mail DNS: DKIM, bounce domain, SPF, DMARC (especially after a move to Cloudflare)

The relay changes nothing about who sends the mail: the provider still delivers it, signs it with DKIM and uses its
own bounce (Return-Path) domain. exim must **not** add a DKIM signature of its own (no `DKIM_*` macros). What can be
wrong is DNS, and a DNS move is the usual moment it breaks silently.

## Contents
1. Why each record matters
2. What goes wrong after a move to Cloudflare
3. Check (read-only)
4. What to propose; owner steps in Cloudflare
5. Verify, header check, tighten DMARC
6. Rollback

## 1. Why each record matters
- **DKIM** (`<selector>._domainkey.<domain>`, TXT, sometimes a CNAME to the provider): the provider signs with
  `d=<domain>`. A valid aligned DKIM signature alone is enough for DMARC to pass.
- **Bounce / Return-Path domain** (for example `bounce.<domain>` as a CNAME to the provider, or its own MX + SPF for
  "custom MAIL FROM" providers): the envelope sender of every message. Receivers check SPF against *this* domain, and
  bounces go to it, so the provider can stop mailing dead addresses. Because it is a subdomain of `<domain>`, a pass
  here is SPF-aligned for DMARC (relaxed alignment).
- **SPF at the apex** (`<domain>` TXT `v=spf1 …`): covers mail whose envelope sender is the apex itself, normally the
  people's mailboxes (Google Workspace: `include:_spf.google.com`; Microsoft 365: `include:spf.protection.outlook.com`).
  A transactional provider with its own bounce domain does not need to be in the apex SPF; one that sends with the
  apex as envelope sender does (its console says which). Exactly **one** `v=spf1` record: two make both invalid
  (permerror). Keep within 10 DNS lookups.
- **DMARC** (`_dmarc.<domain>` TXT): tells receivers what to do when neither aligned SPF nor aligned DKIM passes, and
  where to send reports. Start with `p=none` and a report address, read the reports, then tighten.

## 2. What goes wrong after a move to Cloudflare
When a zone is added, Cloudflare imports the records it can find, and may import web-looking CNAMEs as **proxied**
(orange cloud). A proxied name answers with Cloudflare's own addresses instead of the CNAME, so:
- SPF lookups on the bounce domain find no SPF → SPF fails for every message; bounces never reach the provider.
- A DKIM record published as a CNAME (Microsoft 365, SES, SendGrid style) stops resolving to the key.
Records that were not imported at all are worse to spot when the zone has a wildcard `*` record: the missing name
still "resolves" (to the wildcard's address), so a quick lookup looks fine. On the first server the provider's
bounce CNAME had been missing since the Cloudflare move and the wildcard hid it; SPF and DMARC records did not exist.
TXT and MX records cannot be proxied, but they can be missing or duplicated.

## 3. Check (read-only)
Get the From domain from `moodle-mail.sh --show` (`noreplyaddress`), and the DKIM selector and bounce name from the
provider's console (domain settings). Then:
```bash
bash scripts/mail-dns-check.sh --domain <domain> --dkim-selector <selector> --bounce <bounce-name> \
     [--expect-spf-include _spf.google.com]
```
It asks two public resolvers (1.1.1.1 and 8.8.8.8, so half-propagated changes show) and reports: wildcard present;
DKIM key published (TXT directly or through a CNAME); bounce name is a real CNAME (or own MX + SPF) and not
"A records only" (proxied) or "wildcard only" (missing), plus the SPF reached through it; exactly one apex SPF and no
`+all`; exactly one DMARC record, its policy and whether it has `rua=`; MX (which tells which mailbox provider the
apex SPF must cover). Report addresses are masked in its output.

## 4. What to propose; owner steps in Cloudflare
DNS lives in the owner's Cloudflare account: Claude prepares exact records, the owner enters them
(`assets/owner-steps-ar.md` §4), Claude verifies. Typical set:

| Record | Type | Name | Content | Proxy |
|---|---|---|---|---|
| bounce | CNAME | `<bounce-name>` | provider's target | **DNS only** |
| DKIM | TXT or CNAME | `<selector>._domainkey` | from the provider's console, unchanged | DNS only |
| SPF | TXT | `@` | `v=spf1 include:<mailbox provider> ~all` (one record; merge into an existing one) | n/a |
| DMARC | TXT | `_dmarc` | created by Cloudflare: Email > DMARC Management > Enable (`p=none`, Cloudflare report address) | n/a |

- Before any edit the owner exports the zone (DNS > Records > Import and Export > Export): that is the backup.
- Use `~all` (softfail) while starting; `-all` only when every legitimate sender is known from DMARC reports.
- Cloudflare DMARC Management is free, adds its own `rua=` address and shows the reports in the dashboard, so nobody
  has to parse XML. If a `_dmarc` record already exists, it adds its address to it.
- These changes are independent of the relay and can be done first; then the single test message (exim-smarthost.md
  §8) also serves as the header check.

## 5. Verify, header check, tighten DMARC
1. Rerun `mail-dns-check.sh` until both resolvers show the new records (Cloudflare usually serves them within
   a minute; resolvers holding the old answer follow within its TTL).
2. Header check on one test message, with the owner's permission (via exim: `send-one-test.sh`; or through Moodle's own
   mailer: `moodle-mail.sh --send-test --to=<owner mailbox> --confirm-owner-permission`). The owner opens it ("Show
   original" in Gmail; message details in Outlook) and reports only the results: `spf=pass` (smtp.mailfrom = the
   bounce domain), `dkim=pass` (`header.d=<domain>`), `dmarc=pass`.
3. Log the DNS change as an owner action verified by the session, with the values (no report ids or report
   addresses), and set the tightening date: after 2–4 weeks of reports in which every legitimate source passes,
   propose `p=quarantine` (optionally with `pct=`), later `p=reject`. Other senders that use the domain (staff
   mailboxes, newsletters, other apps) must pass before tightening, which is what the reports show.

## 6. Rollback
DNS rollback is the owner's re-entry of the exported old values. Removing a broken bounce CNAME or SPF record is never
needed for safety: a missing record is the failure mode, not a protection. If tightening DMARC causes legitimate mail
to be quarantined, return to `p=none` at once and read the reports for the failing source.
