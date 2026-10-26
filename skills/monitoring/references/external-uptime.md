# External uptime monitoring (layer 1): design, Cloudflare notes, diagnosis

Loaded on demand from SKILL.md. The owner creates these monitors in his own account (Claude never logs in and never
handles the account password). Owner steps in Arabic: `owner-steps-ar.md`.

## Why two layers
- The on-server check (healthchecks.io) sees the inside: services, DB, PHP, mail, cron, disk, Moodle's own checks.
  It cannot see what visitors see: DNS, Cloudflare, TLS at the edge, the route from the internet. If the server is
  down, it sees nothing at all (healthchecks.io then reports the missing ping after period + grace).
- An external monitor sees exactly what a student sees, from outside, independent of the server.
- Together they tell where the fault is (matrix below) within minutes, before students write.

## Which service
UptimeRobot's free plan was enough on the first server (at the time of writing: 50 monitors, 5-minute interval,
keyword monitors, mobile-app push alerts). **Plans and terms change**: before recommending, look at
uptimerobot.com/pricing with the owner and confirm (a) the free limits, (b) whether keyword monitors and the Telegram
integration are included, (c) whether the free plan's terms fit an organisation's site. If not, alternatives with
the same design: Better Stack (free tier with fewer monitors), or a self-hosted Uptime Kuma on a machine at a
**different provider** (a monitor on the same server or provider shares its failures).

## Monitors (per Moodle server)
| # | Type | Target | Setting | Why |
|---|---|---|---|---|
| 1 | Keyword | `https://<SITE>/login/index.php` | keyword `logintoken`, alert when the keyword is **NOT** found; 5-minute interval; case-insensitive | every Moodle login form contains the hidden `logintoken` field. "Not found" catches every failure mode: 5xx, a Cloudflare error page (52x), a challenge page, maintenance mode, a PHP error page that still returns 200, an empty page. A plain HTTP monitor would call a 200 error page "up" |
| 2 | Port | `<ORIGIN_IP>` port 443 | TCP only | only behind Cloudflare: tells "origin down" from "Cloudflare/DNS problem". TCP connect succeeds even with the nginx origin lock (it closes the connection after the handshake) |
| 3.. | HTTP(s) or keyword | each other public site on the box (the `EXTRA_SITES` list) | status / a stable word | the owner learns about those too, and a box-wide failure shows on all monitors at once |
| opt | Ping (ICMP) | `<ORIGIN_IP>` | only when NOT behind Cloudflare | tells "machine/network down" from "web/app down" (needs ICMP allowed by the firewall) |

Alert contacts: the UptimeRobot **mobile app** (push; enable critical alerts / bypass do-not-disturb if the owner
wants night alerts), e-mail as backup, Telegram if the plan includes it. Add a second person (a colleague) as a
contact if the owner agrees: one phone on silent should not be the only path.

Naming: use neutral names ("LMS login", "LMS origin 443"). Do not put the origin IP in a monitor name and do not add
the port monitor to a **public** status page: behind Cloudflare the origin address should not be published.

## Cloudflare notes
- **Firewall lock on the origin**: if a firewall (ufw/nftables/provider firewall) admits only Cloudflare ranges on 443,
  monitor 2 fails permanently. Either allow UptimeRobot's published probe addresses for TCP 443 (a change: log it),
  or skip monitor 2 and rely on healthchecks.io's missing ping for "server down". The nginx-level origin lock from
  the cloudflare module (`return 444` in the server block) does not break it.
- **Bot protection**: Bot Fight Mode, "I'm Under Attack" or a managed challenge can answer the monitor with a
  challenge page; the keyword is then missing and the monitor alerts. Under Attack mode also challenges students,
  so that alert is fair. For bot rules: a WAF custom rule with "Skip" for the monitor's user agent/addresses works
  where the plan allows skipping that feature; on the free plan Bot Fight Mode cannot be skipped by a rule, so the
  owner chooses between keeping it and keeping the keyword monitor. Check this right after creating monitor 1.
- **Caching**: the login page must never be cached at the edge (it carries a per-session token). Cloudflare does not
  cache HTML by default; a "cache everything" rule would make monitor 1 report a stale page as up. The cloudflare
  module's cache rule covers static paths only.
- **Rate limiting / WAF**: one request every 5 minutes is far below any sane limit; if a rule blocks it, the block
  page lacks the keyword and the monitor alerts, which is the desired signal.

## Diagnosis matrix (read with the owner when an alert arrives)
| Keyword monitor (outside) | Port 443 (origin) | healthchecks.io (inside) | Most likely | First look |
|---|---|---|---|---|
| down | down | missing ping ("down" after grace) | server or its network is down | provider panel / console; reboot only with the owner |
| down | up | failure with `site` / `svc:nginx` / `db` / `5xx` | origin application problem (web server, PHP, DB) | `moodle-health --status`, `journalctl -u moodle-health`, the failing service |
| down | up | OK | between visitors and origin: Cloudflare, DNS, edge TLS, WAF/challenge, or fail2ban blocking edges (inside check would normally show `f2b:`) | Cloudflare dashboard (status, Security events), `curl -sI https://<SITE>/login/index.php` from outside, fail2ban status |
| up | up | failure (`cron`, `mailq`, `disk`, `moodle:...`, `cert`) | a problem students do not see yet | follow the message; often a slower-burning issue (disk filling, cron stopped, mail stuck) |
| up | up | missing ping | the monitor itself: timer stopped, script crash, or no outbound HTTPS from the server | `systemctl status moodle-health.timer`, `journalctl -u moodle-health -n 50`, `curl -sI https://hc-ping.com` |
| down for one 5-min sample, then up | — | OK | a blip (deploy, reload, network) | note it; act only if it repeats |

## Planned work and reboots
UptimeRobot does not know about planned work: the owner pauses the affected monitors before the window (maintenance
windows exist on some plans) and resumes them afterwards. Order with the on-server layer: `operating.md` §1.
