# Rate limits for Moodle: design, dry run, review, enforcement

## Contents
1. Design
2. Zones and starting values
3. Why not more limits at once
4. Installing in dry run
5. The 48-hour review
6. Enforcing
7. Deferred zones and the replay
8. Monitoring and rollback
9. Cloudflare's edge rate limiting

## 1. Design
- All limits live in the PHP location and use keys that are **empty unless the request belongs to the class**
  (nginx does not count empty keys). So `limit_req zone=moodle_front` in the PHP location affects only `/index.php`.
- How requests arrive there: `GET /` → index module → internal redirect to `/index.php`; an unknown URL →
  `try_files` → `/r.php` (`$uri` exactly `/r.php`); ESM URLs are `/r.php/core/esm/...` (not exactly `/r.php`).
- Keys use `$binary_remote_addr`, which is the real visitor only when real-IP is configured behind a proxy.
- `geo $rl_exempt` exempts localhost and the server's own public address (its monitors call the public name;
  through Cloudflare those requests come back with `CF-Connecting-IP` = the server's IP). Office IPs only with the
  owner's approval.
- A dedicated log (`moodle_rl` format, `if=$rl_hit`) records only requests the limiter delayed or rejected (also in
  dry run), with `$request_uri` so the real path is visible.
- Status 429 instead of the default 503.

## 2. Zones and starting values (assets/moodle-ratelimit.conf)
| Zone | Applies to | Rate | Burst (nodelay) | Starts | Rationale |
|---|---|---|---|---|---|
| `moodle_front` | `/index.php` | 60 r/m | 30 | dry run → enforced after review | flood target; a person loads `/` a few times a minute; 30 instant + 1/s covers a NAT group |
| `moodle_front_conn` (limit_conn) | `/index.php` | 6 concurrent | n/a | dry run → enforced | floods held dozens of concurrent `/` requests |
| `moodle_fallback` | `/r.php` fallback | 30 r/m | 20 | dry run → enforced | unknown URLs are mostly scanners (Moodle 4.5+ only) |
| `moodle_php` | every PHP request | 20 r/s | 400 | commented out until the 7-day replay | safety net; one page view triggers ~50 PHP sub-requests (images, files, JS) |
| `moodle_auth` | POST login / signup / forgot password | 60 r/m | 60 | commented out until the replay | side benefit against brute force; sized for a lab or registration wave behind one IP |
| site-wide `limit_conn` | — | — | — | **not used** | holds the slot until the response is fully sent (X-Accel files, video) and counts each HTTP/2 stream; would misfire on NAT. If ever added, never below 150 |

Zone memory: 1 MB ≈ 16,000 client states; 10-20 MB covers hundreds of thousands of addresses.

## 3. Why not more limits at once
Carrier NAT and schools put many students behind one address: on the first server the top /16 networks held
dozens of addresses each and the busiest single "client" was the mobile app/H5P traffic of a NAT group. Thirty students
opening a quiz together make about 1,500 PHP requests, more than `burst=400` at 20 r/s; 50 logins in one minute
exceeded an earlier auth sizing of 30 r/m + 20. Two weekdays of dry run contain no registration wave, lab session or
exam start, so the PHP-wide and login limits wait for at least 7 days that include the weekend peak.

## 4. Installing in dry run
SKILL.md step 3. Points that matter:
- `limit_req_dry_run on;` and `limit_conn_dry_run on;` apply to the **whole location**.
- Keep the existing `access_log` line unchanged; add the rate-limit log as a second `access_log`.
- Check after the reload: `moodle-smoke.sh --phase after` (the location still serves everything) and
  `sudo tail /var/log/nginx/moodle-ratelimit.log` (may stay empty for a while; that is good).

## 5. The 48-hour review (`scripts/rl-review.sh`)
Read in this order:
1. Counts by zone and day (error log "limiting ..., dry run ... by zone").
2. User-agent classes of would-be-limited requests: tools, bots, browsers, moodle-app.
3. Top paths: scanner probes (`/wp-...`, random `.php`, 404s) vs real pages.
4. Browser user agents by masked client: are they a burst of one client over many distinct paths (a tool with a
   browser UA, as seen on the first server) or a class opening the same page?

Decision rules:
- Only tools, scanners, bots or flood minutes → propose enforcement.
- A browser with normal page views in `moodle_front` or `moodle_front_conn` → double that zone (`burst=60` or
  `limit_conn ... 12`), dry run 24 h more, review again.
- Any `moodle-app` traffic limited → raise before enforcing; the app is how many students study.
Report numbers to the owner in Arabic (who would have been limited, how often, what kind of client). Never paste
unmasked addresses into reports or tickets.

## 6. Enforcing
Remove the two `*_dry_run on;` lines (backup, `replace-once.py`), `nginx -t`, reload. Only the three active lines
enforce; the commented `moodle_php`/`moodle_auth` stay off. Watch for a week: `rl-review.sh --access-log <log>`
(429s by user-agent class and path). Target: 429s to browsers and the app about zero.

## 7. Deferred zones and the replay
After ≥ 7 days that include the weekend (and ideally a registration wave or exam start):
```bash
sudo sh -c 'cd /var/log/nginx && for i in $(seq 14 -1 2); do [ -f <access>.$i.gz ] && zcat <access>.$i.gz; done; cat <access>.1 <access>' \
  | gawk -v exempt="127.0.0.1 <ORIGIN_IP>" -f scripts/rl-replay.awk
```
- `mode=urt` (default) counts requests that reached PHP-FPM, which needs `urt=$upstream_response_time` in the log
  format (the audit module's timing format has it); otherwise use `-v mode=php`.
- Timestamps have 1-second resolution and mark the end of the request: the replay slightly over-counts (safe side).
- Clean replay → owner approval → uncomment the line in the PHP location (live at once, the location is enforcing),
  `nginx -t`, reload, watch 429s daily for a week.
- A browser on a school or carrier address → raise 2× (`moodle_php burst=800`; `moodle_auth rate=120r/m` in the
  conf.d file and `burst=120`), run the replay with the new numbers (`-v php_burst=800` / `-v auth_rate=2 -v auth_burst=120`),
  re-add only when clean.
- If nginx's own count is wanted too, put the whole location back into dry run for 24-48 h (the front-page limits
  are then not enforced meanwhile).

## 8. Monitoring and rollback
- Weekly: `rl-review.sh --access-log <log>`; after Moodle upgrades re-run `moodle-smoke.sh`.
- PHP-FPM saturation: the FPM log (`server reached max_children`) or an FPM status page if the audit module set one up.
- Rollback, limits only: put `limit_req_dry_run on; limit_conn_dry_run on;` back (or comment the `limit_*` lines),
  `nginx -t`, reload. Everything: restore the vhost backup, delete `conf.d/moodle-ratelimit.conf`, `nginx -t`, reload.

## 9. Cloudflare's edge rate limiting
Free plans have one rate-limiting rule (IP-based, short windows). It can mirror the front-page limit at the edge,
but it does not replace nginx limits: requests that bypass Cloudflare (exposed origin) and per-path logic still need
nginx. fail2ban web jails behind Cloudflare would ban edge addresses unless they use Cloudflare's API: keep web
blocking in Cloudflare and nginx.
