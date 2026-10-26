---
name: nginx
description: Harden the nginx in front of a production Moodle site, step by step and reversibly. A default server that refuses unknown Host/SNI (return 444 plus ssl_reject_handshake) with before/after probes of every vhost; scanner paths and non-existent .php files answered by nginx before PHP (non-greedy path split, try_files existence check, PATH_INFO kept) proven with smoke tests of every Moodle URL form; per-client limit_req/limit_conn zones run in DRY RUN with a dedicated log and a review before enforcing; static caching for page-builder media, SVG/font gzip and a static favicon. Includes Apache notes. Use it whenever a Moodle server shows scanner floods, "Primary script unknown" errors, PHP-FPM max_children reached, unknown or retired domain names still answering, a missing default_server, no request limits, or slow repeat loads of page-builder images. Also use it when the owner asks to protect, harden or rate-limit the Moodle web server, even if nginx is not named.
---

# nginx hardening for Moodle

## 1. Read first
Read `../../shared/core-rules.md` (relative to this file) before anything else: change protocol, quiet hours,
secrets, log format. Read the server handbook and the operations log tail. Load
`~/.config/moodle-server-care/server.env` (run `../start/scripts/detect-env.sh` if missing or older than a day);
the scripts read it and accept environment overrides.

Placeholders: `<SITE>`, `<MOODLE>`, `<DOCROOT>`, `<DATAROOT>`, `<FPM_SOCK>`, `<ORIGIN_IP>`, `<LOG>` (core-rules §12);
`<VHOST>` = the Moodle server block file (`VHOST` in server.env; usually a symlink in `sites-enabled/` → edit the
target in `sites-available/`).

## 2. When to use / signs
- Access logs full of `/wp-login.php`, `/.env`, `/swagger/`, `/actuator/` and random `.php` probes; the error log
  has many `Primary script unknown`.
- PHP-FPM log shows `server reached max_children` during bursts from a handful of clients.
- `nginx-discover.sh` shows no `default_server`: another site (or the Moodle site) answers unknown names, wildcard
  DNS names and the bare IP; retired subdomains still answer.
- No `limit_req`/`limit_conn` anywhere.
- Page-builder images re-downloaded through PHP on every visit; SVG served uncompressed; `/favicon.ico` boots Moodle.

Prerequisite: if a CDN or proxy (Cloudflare) is in front, the real client IP must be configured first
(`cloudflare` module, step 1). Without it, per-client limits throttle the proxy, i.e. everybody.

## 3. Discovery (read-only)
`<SKILL_DIR>` = this skill's base directory (shown when the skill loads). Working files go to a private folder in
the operator's home, never to fixed names in `/tmp` (another account could create them first).
```bash
cd <SKILL_DIR>
W=~/msc-nginx-$(date +%F); install -d -m 700 "$W"     # working folder for this module's before/after files
bash scripts/nginx-discover.sh                       # version/features, server blocks, default_server, PHP location,
                                                     # limits, gzip, add_header, Moodle router/shims/X-Accel, scanners
bash scripts/vhost-probe.sh --show-cert --out "$W/vhost-before.txt"   # who answers each name, unknown names, bare IP
bash scripts/moodle-smoke.sh --phase before > "$W/smoke-before.txt"   # every Moodle URL form works today
sudo grep -c 'Primary script unknown' <error log of the vhost>        # baseline
```
The `audit` module's reports (scanner bursts, pool exhaustion times, top clients) give the evidence for the proposal.

**When the server differs from the first one:**

| Finding | What to do |
|---|---|
| Apache, not nginx | Use `references/apache.md`; most steps have an Apache form, rate limiting does not (stop and ask) |
| Control panel manages nginx (Plesk, cPanel, CloudPanel, Webmin) | Stop and ask: hand edits are overwritten; use the panel's custom-directive fields |
| nginx < 1.19.4 | Default server with `assets/00-default-server-legacy.conf` (self-signed cert, `return 444`) |
| nginx < 1.17.6 (< 1.17.1) | No `limit_conn_dry_run` (no dry run at all): skip `limit_conn` (skip step 3) and ask about an upgrade |
| A server already has `default_server` | Read it: if it already refuses unknown names, skip step 1; otherwise move the flag, do not add a second one |
| Moodle before 4.5 (no `<DOCROOT>/r.php`) | Unknown URLs are plain nginx 404s: drop the `moodle_fallback` zone and its line |
| Moodle 5.x with a shim route whose `.php` file is missing | Before step 2: `moodle-smoke.sh --phase before --extra /that/path.php=moodle`; if Moodle answers it today, stop and ask (`references/php-location.md` §Shim routes) |
| PHP location already uses `include snippets/fastcgi-php.conf` | It already has the non-greedy split, existence check and PATH_INFO: skip that part of step 2 |
| `$CFG->wwwroot` with a sub-path | Prefix the maps (`/index.php`, `/r.php`, login paths, page-builder path) with `<SUBPATH>` |
| No X-Accel (`$CFG->xsendfile` unset) | Skip the page-builder part of step 6, or propose enabling X-Accel first as its own change |
| Several Moodle sites on one nginx | One zone set per site (distinct zone and map names); never share `$rl_*` names between sites |
| Behind a proxy without real IP | Stop step 3 until the cloudflare module's step 1 is done |

## 4. What to propose to the owner (Arabic template)
```markdown
## مقترح: تقوية خادم الويب (nginx) لمنصة <SITE>

**ما وجدته (فحص للقراءة فقط، لم يتغير شيء):**
| البند | الوضع الآن | الأثر |
|---|---|---|
| الأسماء غير المعروفة وعنوان الخادم المجرد | يجيب عنها موقع <X> | أي اسم أو أداة فحص تصل إلى موقع لا علاقة له، والأسماء المحذوفة ما زالت تعمل |
| روابط ‎.php غير الموجودة ومسارات أدوات الفحص | تصل إلى PHP وتشغّل Moodle | تستهلك عمّال PHP دون فائدة (<N> طلب يومياً) |
| حد لعدد طلبات الزائر الواحد | لا يوجد | زائر أو أداة واحدة قد تملأ عمّال PHP (حدث في <التاريخ>) |
| صور منشئ الصفحات في المتصفح | تُحفظ 10 ثوانٍ فقط | تُعاد عبر PHP في كل زيارة |
| ضغط ملفات SVG والخطوط | غير مفعّل | حجم أكبر على الجوال |

**الخطوات (كل خطوة وحدها، نسخة احتياطية قبلها، إعادة تحميل دون انقطاع، وتراجع خلال دقيقة):**
1. خادم افتراضي يرفض الأسماء غير المعروفة، مع فحص كل المواقع قبل وبعد. أسماء ستتوقف: <القائمة> (قرارك لكل اسم).
2. رفض روابط ‎.php غير الموجودة ومسارات أدوات الفحص مباشرة من nginx، مع اختبار كل أنواع روابط Moodle
   (التنسيق والبرمجة والصور والملفات وطلبات الصفحة الخلفية).
3. حدود لعدد الطلبات في **وضع التجربة**: تُسجَّل فقط ولا تمنع أحداً لمدة 48 ساعة.
4. بعد 48 ساعة أعرض عليك من كان سيُمنع؛ إن كانوا أدوات وماسحات فقط نفعّل الحدود.
5. بعد 7 أيام تشمل نهاية الأسبوع: قرار في حدود إضافية (كل طلبات PHP، ونموذج الدخول) بمحاكاة على السجلات.
6. حفظ صور منشئ الصفحات يوماً في المتصفح، وضغط SVG والخطوط، وأيقونة الموقع ملف ثابت.

**تنبيه:** طلاب كثيرون قد يخرجون من عنوان IP واحد (شبكات الجوال والمدارس)، لذلك نجرّب ونقيس قبل أي منع.
**التوقيت:** الساعة الهادئة (<HH-HH>)، ولا يُتوقع انقطاع.
**ما يلزم منك:** موافقة على كل خطوة، وقرار في الأسماء التي ستتوقف في الخطوة 1.
```

## 5. Procedure
One step per approval; re-read the log tail first; log before reporting. Back up into a root-only folder once per
day: `sudo install -d -m 700 /root/nginx-$(date +%F) && sudo tar -C / -czf /root/nginx-$(date +%F)/nginx-etc.tgz etc/nginx`
(add a letter for a second archive the same day). Edit the vhost with `scripts/replace-once.py` (the plugin's shared
edit tool: asserts the old text occurs once, keeps mode/owner, edits the symlink target, refuses to apply without
the day's `.bak`; pass `--backup <file>` when the copy has another name or place). Load the values first, parsed
rather than sourced: `. scripts/lib-env.sh && msc_parse_env "$(msc_env_path)" VHOST FPM_SOCK ORIGIN_IP` (provides
`$VHOST`, `$FPM_SOCK`, `$ORIGIN_IP` used below; `$W` is the working folder from §3).

**Where vhost backups go.** `V=$(readlink -f "$VHOST")` is the real file. Normally it lives in `sites-available/`
and `sites-enabled/` holds a symlink: back up as `"$V.bak-$(date +%F)"`. If `$V` itself is in `sites-enabled/` (no
symlink), nginx loads every file there, so a `.bak` next to it becomes a second live copy of the site: back up to
`/root/nginx-$(date +%F)/` instead and pass `--backup /root/nginx-<date>/<file>` to `replace-once.py`.

### Step 1: default server that refuses unknown names
- **Why:** without `default_server`, nginx answers any Host/SNI it does not know with the first server block of that
  port: scanners, wildcard DNS names, retired subdomains and the bare IP reach a real application and see its
  certificate. Details: `references/default-server.md`.
- **Before:** `$W/vhost-before.txt` from discovery. In the "configured names" part, every name must answer as
  expected. In "unknown names", note which return 200 today. Ask the owner about every real DNS name that has no
  `server_name` of its own (it worked only through the catch-all and will stop; behind Cloudflare it becomes 525).
- **Backup:** the `/etc/nginx` tarball above (the change is a new file).
- **Change:** `sudo install -m 644 assets/00-default-server.conf /etc/nginx/conf.d/00-default-server.conf`
  (legacy asset for nginx < 1.19.4; drop the `[::]` lines if no other server listens on IPv6).
- **Test:** `sudo nginx -t`. **Apply:** `sudo systemctl reload nginx`.
- **Verify:** `bash scripts/vhost-probe.sh --out "$W/vhost-after.txt" && bash scripts/vhost-probe.sh --compare "$W/vhost-before.txt" "$W/vhost-after.txt"`:
  only unknown names and bare-IP lines may change (to `rc35` on 443, `rc52` on 80). Main site through its public
  name: 200. A certificate that only renewed through the catch-all: `certbot renew --dry-run --cert-name <name>` or retire it.
- **Rollback:** `sudo rm /etc/nginx/conf.d/00-default-server.conf && sudo nginx -t && sudo systemctl reload nginx`.

### Step 2: scanner 404s and the .php existence check
- **Why:** unknown `.php` URLs go to PHP-FPM ("Primary script unknown") and scanner paths go through
  `try_files … /r.php`, a full Moodle bootstrap with a session. nginx can answer both in microseconds. Details and
  the URL forms that must keep working: `references/php-location.md`.
- **Pre-checks:** `nginx-discover.sh` → every shim route marked `NO FILE` (other than Moodle's test routes) checked
  with `moodle-smoke.sh --extra`; no scanner prefix marked `COLLIDES`; note the current split regex and PATH_INFO source.
- **Backup:** `V=$(readlink -f "$VHOST"); sudo cp -a "$V" "$V.bak-$(date +%F)"` (the resolved file; if it lives in
  `sites-enabled/` itself, copy it to `/root/nginx-$(date +%F)/` instead: see "Where vhost backups go").
- **Change:**
  ```bash
  awk '/location[[:space:]]+~[^{]*\\\.php/ && !f {f=1; d=0} f {print; o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); d+=o-c; if (d<=0 && o+c>0) exit}' "$V" > "$W/old-php-location.txt"
  sed "s#<FPM_SOCK>#$FPM_SOCK#" assets/php-location.conf > "$W/new-php-location.txt"   # then re-add site-specific lines
  diff "$W/old-php-location.txt" "$W/new-php-location.txt"                            # (timeouts, buffers) by hand
  sudo python3 -I scripts/replace-once.py "$V" --insert-before 'location ~ [^/]\.php(/|$) {' --new-file assets/scanner-block.conf   # diff only
  sudo python3 -I scripts/replace-once.py "$V" --insert-before 'location ~ [^/]\.php(/|$) {' --new-file assets/scanner-block.conf --apply
  sudo python3 -I scripts/replace-once.py "$V" --old-file "$W/old-php-location.txt" --new-file "$W/new-php-location.txt"          # diff only
  sudo python3 -I scripts/replace-once.py "$V" --old-file "$W/old-php-location.txt" --new-file "$W/new-php-location.txt" --apply
  ```
  Adapt the `--insert-before` anchor to the PHP location's exact first line on this server.
- **Test:** `sudo nginx -t`. **Apply:** `sudo systemctl reload nginx`.
- **Verify:** `bash scripts/moodle-smoke.sh --phase after` → PASS (slash arguments, path forms, AJAX, ESM; nope.php,
  wp-login.php and scanner paths now nginx 404). Then a student-view browser check by the owner: styled page,
  images, dashboard cards, a video. `Primary script unknown` stops growing.
- **Rollback:** `sudo cp -a "$V.bak-YYYY-MM-DD" "$V" && sudo nginx -t && sudo systemctl reload nginx`. Any FAIL on a
  slash-argument URL after the reload: roll back first, investigate later.

### Step 3: rate limits in DRY RUN
- **Why:** pool exhaustion came from floods on the front page and on unknown URLs by a few clients. Per-client
  limits stop that, but carrier NAT and school labs put many students behind one address, so the limits first only
  log. Zone design and sizing: `references/rate-limits.md`.
- **Pre-checks:** real IP live if proxied (`nginx-discover.sh`: `real_ip_header`); nginx ≥ 1.17.6; router present
  (else drop the fallback zone); `<ORIGIN_IP>` is the public address (behind NAT add the private one too).
- **Backup:** `sudo cp -a "$V" "$V.bak-$(date +%F)"` (if one exists from today, use the suffix `b` and pass
  `--backup "$V.bak-$(date +%F)b"` to `replace-once.py`).
- **Change:** `sed "s#<ORIGIN_IP>#$ORIGIN_IP#" assets/moodle-ratelimit.conf > "$W/moodle-ratelimit.conf"`, review,
  `sudo install -m 644 "$W/moodle-ratelimit.conf" /etc/nginx/conf.d/moodle-ratelimit.conf`; in the Moodle 443
  server add `access_log /var/log/nginx/moodle-ratelimit.log moodle_rl if=$rl_hit;` next to the existing
  `access_log` (keep the existing one byte-identical so log parsers keep working); insert
  `assets/php-location-ratelimit.lines` into the PHP location (`replace-once.py --insert-before` the
  `fastcgi_index` line, or at the marker comment).
- **Test:** `sudo nginx -t`. **Apply:** reload.
- **Verify:** `moodle-smoke.sh --phase after` PASS; `ls -l /var/log/nginx/moodle-ratelimit.log` exists; after an
  hour `bash scripts/rl-review.sh` shows only "dry run" lines; no 429 in the access log.
- **Rollback:** restore this step's backup of `$V`, delete `conf.d/moodle-ratelimit.conf`, nginx -t, reload.

### Step 4: review after at least 48 hours, then enforce the three front-page zones
- `bash scripts/rl-review.sh` (masked addresses; never paste raw addresses into tickets). Apply the decision rules
  printed at the end; propose to the owner in Arabic with the numbers (who would have been limited, how often).
- If a browser user agent with normal page views appears: double that zone, dry-run 24 h more.
- Enforce (approved): remove the two `*_dry_run on;` lines (`replace-once.py`, backup first), nginx -t, reload.
- Verify daily for a week: `bash scripts/rl-review.sh --access-log <access log>` → 429s only for tools and
  scanners. Rollback: put the two dry-run lines back, nginx -t, reload.

### Step 5: deferred zones (`moodle_php`, `moodle_auth`) after at least 7 days incl. a weekend peak
- Dry run is per location; once step 4 enforces, these cannot be dry-run. Replay instead:
  `sudo sh -c 'cd /var/log/nginx && for i in $(seq 14 -1 2); do [ -f <log>.$i.gz ] && zcat <log>.$i.gz; done; cat <log>.1 <log>' | gawk -v exempt="127.0.0.1 $ORIGIN_IP" -f scripts/rl-replay.awk`
  (`mode=php` if the log format has no upstream time).
- Clean replay (only tools/floods) → owner approval → uncomment the line (live at once), watch 429s daily. A browser
  on a school or carrier address → raise 2×, replay again. `references/rate-limits.md` §Deferred zones.

### Step 6: static caching: page-builder media, gzip types, favicon
- **Why:** page-builder images are public by design yet sent `private, max-age=10`, so each visit re-fetches them
  through PHP; SVG and TTF/OTF fonts go uncompressed; `/favicon.ico` boots Moodle. Details: `references/static-caching.md`.
- **Pre-checks:** `nginx-discover.sh` shows the X-Accel internal location and the page-builder handler (system
  context only, no login), and lists every `add_header` at http/server level. Content editors agree that a replaced
  image may show up to 1 day late (use new file names).
- **add_header inheritance:** one `add_header` inside `location /dataroot/` switches off inheritance of EVERY
  `add_header` from the server and http levels for all X-Accel file responses (HSTS, `X-Content-Type-Options`, CSP
  would silently disappear from course files). If discovery lists any, repeat them inside that location, after the
  new line, with the same values and `always` flags.
- **Backup:** `$V.bak-$(date +%F)` (or the next letter), `sudo cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak-$(date +%F)`.
- **Change:** `assets/moodle-static.conf` → `/etc/nginx/conf.d/`; `expires $moodle_pb_expires;` and
  `add_header Cache-Control $moodle_pb_cc;` inside `location /dataroot/`; `gzip_types` += `image/svg+xml font/ttf font/otf application/vnd.ms-fontobject`
  in `nginx.conf`; `assets/favicon-location.conf` with an icon file outside the Moodle tree.
- **Test:** `sudo nginx -t`. **Apply:** reload.
- **Verify:** page-builder image → `Cache-Control: max-age=86400` and `public`, `Expires` one day ahead; a course
  file URL keeps Moodle's headers and every security header it had before (compare `curl -sI` before/after); an SVG → `content-encoding: gzip`; `/favicon.ico` → 200 `image/x-icon`.
- **Rollback:** delete `conf.d/moodle-static.conf` and the two lines, restore `nginx.conf.bak`, remove the favicon
  location; nginx -t, reload. Browsers may keep an image up to a day: harmless.

## 6. Verification checklist
- [ ] `vhost-probe.sh --compare`: configured names unchanged; unknown names and bare IP refused.
- [ ] `moodle-smoke.sh --phase after`: PASS; owner's browser check fine (CSS, images, AJAX cards, video, quiz page).
- [ ] `Primary script unknown` no longer grows; scanner paths are nginx 404s in the access log.
- [ ] Rate limits: dry run live with its own log → reviewed after ≥ 48 h → three zones enforced → 429s only for tools.
- [ ] Deferred zones decided from a ≥ 7-day replay including a weekend.
- [ ] Page-builder media cacheable 1 day; course files unchanged; SVG gzipped; favicon static.
- [ ] Log entries written; the log's customised-files table lists each new conf.d file and the edited vhost;
      handbook to-do updated (review dates, "re-check shim routes after every Moodle upgrade").

## 7. Log entry example
```
### 2026-05-14 02:40 — nginx: scanner 404s, .php existence check, rate limits in DRY RUN  (session: nginx hardening, approved by owner: yes)
- What/why: scanner bursts (hundreds of requests per minute from one tool) reached PHP; unknown .php paths hit PHP-FPM; both pool
  exhaustions were floods on the front page. Real client IPs available since <time of the cloudflare step>.
- Files/settings touched: new /etc/nginx/conf.d/moodle-ratelimit.conf (moodle_front 60r/m, moodle_fallback 30r/m,
  moodle_front_conn; moodle_php/moodle_auth defined, unused; exempt localhost and this server; moodle_rl log).
  Moodle vhost: rate-limit access_log; scanner location before the PHP location; PHP location non-greedy split,
  set $path_info + try_files $fastcgi_script_name =404, PATH_INFO $path_info, limits with *_dry_run on, status 429.
  nginx -t OK, reload 02:40:12.
- Backup / rollback: <vhost>.bak-YYYY-MM-DD, /root/nginx-YYYY-MM-DD/nginx-etc.tgz; copy back, delete the conf.d
  file, nginx -t, reload.
- Verified: moodle-smoke.sh PASS (styles/javascript/requirejs/yui_combo/font/image 200, pluginfile PATH_INFO 200,
  ESM 200, AJAX answered by Moodle, .php in path and /login/index.php/ reach Moodle; nope.php, wp-login.php,
  swagger → nginx 404; unknown URL → Moodle 404).
- Next: rl-review.sh after 48 h (≈ <date> <time>), then enforce; deferred zones after ≥ 7 days.
```

## 8. Pitfalls we hit on the first server
- **Catch-all by accident.** With no `default_server`, an unrelated application (first file alphabetically) served
  every unknown name, the bare IP and a retired subdomain with its own certificate. The default server fixed it;
  before/after probes proved every real site unchanged. Through Cloudflare the retired name then showed 525.
- **Two servers, not one.** Port 80 returns 444 and logs to `default-reject.log`; port 443 uses
  `ssl_reject_handshake`, which never reaches the request phase, so logging there is useless.
- **PATH_INFO after try_files.** `try_files` resets `$fastcgi_path_info`; without `set $path_info` every
  slash-argument URL breaks: no CSS, JavaScript or images.
- **Greedy split.** `^(.+\.php)(/.+)$` plus the existence check returns nginx 404 for `…/dir.php/file.txt` inside
  pluginfile paths and for `/login/index.php/`; Debian's non-greedy `^(.+?\.php)(/.*)$` handles all forms (tested on
  a scratch nginx, then smoke-tested live).
- **Moodle 5 shim routes.** Legacy `.php` URLs can be served by the router; a route that works today without a
  file on disk must still work after the existence check. The first server listed and checked them before the change;
  re-run `nginx-discover.sh` after every Moodle upgrade, before reloading nginx.
- **Do not block what Moodle uses.** `/api/` carries Moodle 5 REST routes; `admin/tool/installaddon` exists. The
  scanner list is checked against the docroot and route paths every time.
- **Regex order.** The scanner location must precede the PHP location; regex locations match in file order.
- **Log the real path.** The limiter log uses `$request_uri`; `$uri` shows `/r.php` or `/index.php` after
  `try_files`, which hides what was requested.
- **Dry run is per location.** Once the front-page limits are enforced, any limit added to the PHP location is live
  at once. The PHP-wide and login limits therefore stay commented out and are decided from a log replay.
- **limit_conn counts downloads.** A slot stays busy until the response is fully sent (X-Accel files, video) and each
  HTTP/2 stream counts. No site-wide connection limit; never below 150 if one is ever added.
- **NAT is real.** Busy mobile networks put dozens of students behind one address; a class opening a quiz together
  is about 1,500 PHP requests; 50 logins in a minute broke an earlier auth sizing. Hence generous bursts, dry run,
  and exemption of the server's own address (its monitors call the public name).
- **Status 429.** Not the default 503, so limiter answers are distinguishable from overload in logs.
- **Public by design, verified.** The page-builder handler serves system-context files without login; only that
  path got `public, 1 day`, through `expires` in the X-Accel internal location with maps that default to "no change".
  A course file URL was checked unchanged.
- **Favicon.** `/favicon.ico` fell through to Moodle (dozens of bootstraps a day); a theme favicon file name with a
  space produced dozens of double-encoded 404s a day. Find the failing URL form in the access log before fixing anything.
- **Backups are live config in `sites-enabled/`.** Debian includes every file there, and `nginx -t` only warns
  ("conflicting server name ... ignored"), so a stale copy can silently win. `cp -a` of a symlink copies the link:
  the "backup" then changes with the file and restoring it does nothing. Back up the resolved file (`readlink -f`)
  into `sites-available/` (or `/root/nginx-<date>/` when the real file lives in `sites-enabled/`), and name conf.d
  backups `*.conf.bak-DATE` (a `*.bak.conf` is loaded by `*.conf`).
- **A location-level `add_header` drops the server's headers.** nginx inherits `add_header` only when the inner
  level has none; adding one Cache-Control line to the X-Accel location would remove HSTS and similar headers from
  every course file. Repeat them in the location.
- **Certbot lines.** Leave `# managed by Certbot` lines alone; renewals edit and reload nginx temporarily.
- **One change per reload is easier to attribute.** On the first server three related edits went live in one reload
  with full smoke tests; when in doubt, reload them separately a few minutes apart.

## 9. Files in this module
| File | Purpose |
|---|---|
| `scripts/nginx-discover.sh` | Read-only discovery: features by version, server blocks, default_server, PHP location checks, limits, gzip, Moodle router/shim/X-Accel/page-builder checks, scanner collisions |
| `scripts/vhost-probe.sh` | Before/after probe of every configured name, unknown names, bare and public IP; `--compare` |
| `scripts/moodle-smoke.sh` | Smoke tests of every Moodle URL form (slash arguments, path forms, AJAX, ESM, admin, scanner probes) at the origin |
| `scripts/rl-review.sh` | Dry-run / enforcement review: by zone, day, masked client, path, user-agent class; 429 check |
| `scripts/rl-replay.awk` | Replays limit_req over access logs for limits that cannot be dry-run |
| `scripts/replace-once.py` | The plugin's shared edit tool (also used by cloudflare and hygiene): asserted exact replacement, whole-line edit or insertion; dry run by default; backup check; symlink-safe atomic or in-place write; no context shown for secret files |
| `scripts/lib-env.sh` | Parse-only server.env loader used by the scripts (never sources the file) |
| `references/default-server.md` | Default server design, affected names, IPv6, legacy nginx, certbot and Cloudflare effects |
| `references/php-location.md` | Path split, existence check, PATH_INFO, URL forms, shim routes, scanner list, smoke tests |
| `references/rate-limits.md` | Zones, sizing, dry run, review, enforcement, deferred zones and replay, monitoring |
| `references/static-caching.md` | Page-builder media via X-Accel, gzip types, favicon, theme favicon 404s |
| `references/apache.md` | Apache equivalents (or reasons to skip) for every step |
| `assets/00-default-server.conf` / `-legacy.conf` | Default server for nginx ≥ 1.19.4 / older |
| `assets/scanner-block.conf`, `assets/php-location.conf` | Step 2 blocks |
| `assets/moodle-ratelimit.conf`, `assets/php-location-ratelimit.lines` | Step 3 zones and location lines |
| `assets/moodle-static.conf`, `assets/favicon-location.conf` | Step 6 maps and favicon location |
