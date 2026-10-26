---
name: cloudflare
description: Put a production Moodle site behind Cloudflare safely, or repair one that is already behind it. Covers the real client IP in nginx/Apache and Moodle (getremoteaddrconf), a cache rule for Moodle's versioned static URLs with MISS-to-HIT proof while dynamic pages stay DYNAMIC, upload limits aligned to Cloudflare's 100 MB body cap with a notice for teachers, SSL mode Full (strict) and a certbot renewal dry run from behind the proxy, names that expose the origin IP, the wildcard DNS trap, a later origin lock, the owner's dashboard steps in Arabic, and the data-location (PDPL) caveat. Use it whenever a Moodle site is or will be proxied by Cloudflare (orange cloud, a "server cloudflare" or cf-ray response header, logs full of Cloudflare addresses instead of students, uploads failing near 100 MB, 520-526 errors, slow theme CSS/JS for distant users). Also use it when the owner asks about a CDN, cache rules, SSL modes or hiding the server IP, even without naming Cloudflare.
---

# Cloudflare in front of Moodle

## 1. Read first
Read `../../shared/core-rules.md` (relative to this file) before anything else: the change protocol, the secrets
rules and the log format apply to every step below. Then read the server handbook and the tail of the operations
log. Load `~/.config/moodle-server-care/server.env` (run `../start/scripts/detect-env.sh` if it is missing or older
than a day). The scripts here read it; environment variables override it.

Placeholders: `<SITE>`, `<MOODLE>`, `<DOCROOT>`, `<PHP>`, `<WEBUSER>`, `<ORIGIN_IP>`, `<LOG>` as in core-rules §12.
`<SUBPATH>` is the path part of `$CFG->wwwroot` (usually empty). `<VHOST>` is the site's web server config file.

## 2. When to use / signs
- The owner moved (or plans to move) the site's DNS to Cloudflare and turned on the orange cloud.
- `curl -sI https://<SITE>/` shows `server: cloudflare` and `cf-ray`; the access log shows a handful of Cloudflare
  addresses (104.16.x, 172.64.x, 162.158.x, 2606:4700:...) as "clients".
- Teachers report uploads failing at around 100 MB with a Cloudflare error page (413).
- Users far from the server wait seconds for `theme/styles.php` and `lib/javascript.php`.
- 52x errors through Cloudflare (521/522 origin down or unreachable, 524 timeout, 525 handshake, 526 invalid cert).
- Someone asks "can the server IP be hidden?", "is the site cached?", "which SSL mode?".

Order matters: real client IP (step 1) must be live **before** any per-IP rate limiting (nginx module) and before
fail2ban-style web blocking, otherwise all students look like a few Cloudflare addresses and get blocked together.

## 3. Discovery (read-only)
`<SKILL_DIR>` = this skill's base directory (shown when the skill loads).
```bash
cd <SKILL_DIR>
bash scripts/cf-discover.sh          # Cloudflare in front? real-IP, Moodle IP source, upload limits, origin cert, certbot
bash scripts/origin-exposure.sh      # which DNS names reveal the origin IP; wildcard records; MX on this server
bash scripts/upload-limits.sh        # every layer that limits uploads, and the effective limit
bash scripts/cf-ranges.sh --compare /etc/nginx/conf.d/cloudflare-realip.conf   # only if real-IP already exists
```
If the site is already proxied, also run `bash scripts/cf-cache-check.sh` for a baseline (before a cache rule,
static URLs show `DYNAMIC`).

Ask the owner (Arabic): which Cloudflare plan (Free/Pro/Business/Enterprise), who controls the zone, the current
SSL/TLS mode (dashboard: SSL/TLS → Overview), which other domains share this server, and whether management has
approved a third-party proxy for personal data (section 5, step 9).

**When the server differs from the first one:**

| Finding | What to do |
|---|---|
| Apache instead of nginx | Use `cf-ranges.sh --format apache` (mod_remoteip) and the Apache notes in `references/real-ip.md` and `references/upload-limits.md`. Origin lock: `references/origin-exposure.md` §Apache |
| Not behind Cloudflare yet | Do step 1 first (harmless before the cutover), then the owner's DNS steps (`references/dashboard-steps-ar.md` §1), then steps 2-9 |
| Another proxy or CDN in front (or a load balancer) | Stop and ask. The trusted ranges and the header differ; do not copy Cloudflare's |
| SSL mode is **Flexible** | Fix this first: Cloudflare talks plain HTTP to the origin. Move to Full (strict) (step 5) before anything else |
| `$CFG->wwwroot` has a sub-path | Prefix every rule path and nginx location with `<SUBPATH>` |
| No certbot (other ACME client, panel-managed, Origin CA) | Skip the dry run; check expiry and the renewal mechanism; see `references/ssl-and-renewal.md` |
| Moodle 4.x (no `public/`) | Same URL paths; nothing changes for this module |
| nginx without `http_realip_module` | Stop and ask (distribution packages include it; a custom build may not) |
| Cloudflare for SaaS, Spectrum, Tunnel already in use | Stop and ask; the origin side differs |

## 4. What to propose to the owner (Arabic template)
Fill the table from discovery; keep only the rows that apply. Each item is a separate approval.

```markdown
## مقترح: تشغيل المنصة خلف Cloudflare بأمان (<SITE>)

**ما وجدته (فحص للقراءة فقط، لم يتغير شيء):**
| البند | الوضع الآن | المطلوب |
|---|---|---|
| عنوان الطالب الحقيقي في سجلات الخادم وفي Moodle | يظهر عنوان Cloudflare بدل عنوان الطالب | أن يظهر عنوان الطالب |
| مصدر عنوان IP في Moodle | <القيمة> | يعتمد عنوان الاتصال فقط ولا يصدّق ما يرسله المتصفح |
| تخزين ملفات التصميم والبرمجة في Cloudflare | لا تُخزَّن (تأتي من الخادم في كل مرة) | تُخدم من مركز Cloudflare القريب |
| حد رفع الملفات | Cloudflare: <100> م.ب، الخادم: <...>، Moodle: <...> | حد واحد واضح يراه المعلم |
| شهادة الخادم ووضع SSL | <Full / غير معروف> | Full (strict) بعد اختبار تجديد الشهادة |
| نطاقات تكشف عنوان الخادم | <القائمة> | قرار لكل نطاق |

**الخطوات (كل خطوة وحدها، مع نسخة احتياطية وطريقة تراجع خلال دقيقة):**
1. ملف إعداد جديد يجعل الخادم يقرأ عنوان الطالب من Cloudflare. لا انقطاع (إعادة تحميل فقط).
2. ضبط Moodle ليعتمد هذا العنوان فقط.
3. منك في لوحة Cloudflare: قاعدة تخزين مؤقت لملفات Moodle الثابتة (أرسل لك الخطوات بالصور النصية)، ثم أتحقق أنها
   تعمل وأن صفحات الطلاب الشخصية لا تُخزَّن أبداً.
4. توحيد حد الرفع على <N> ميجابايت في الخادم وMoodle، مع رسالة جاهزة للمعلمين.
5. تجربة تجديد شهادة الخادم من خلف Cloudflare (تجربة لا تمس الشهادة الحالية)، ثم منك: تحويل وضع SSL إلى Full (strict).
6. مراجعة النطاقات التي تكشف عنوان الخادم وسجل النجمة (*)؛ أعرض عليك قراراً لكل نطاق.
7. لاحقاً (عند نقل الخادم أو بعد استقرار ما سبق): قفل الخادم بحيث لا يقبل زيارات المنصة إلا عبر Cloudflare.

**ما يلزم منك:** خطوات اللوحة (3، 5، 6)، وموافقة الإدارة على أن Cloudflare يعالج بيانات الزيارات (ملاحظة أدناه).
**التوقيت المقترح:** الخطوات 1-2 في الساعة الهادئة (<HH-HH>)، ولا يُتوقع أي انقطاع.
**ملاحظة حماية البيانات:** Cloudflare يفك تشفير الزيارات في مراكزه (قد تكون خارج المملكة) ليتمكن من حمايتها
وتخزينها مؤقتاً، بما فيها كلمات المرور عند الدخول. هذا يحتاج قراراً من الإدارة وفق نظام حماية البيانات الشخصية.
```

## 5. Procedure
One step per approval; re-read the log tail before each; log each step before reporting. Commands assume nginx on
Debian/Ubuntu; Apache variants are in the references.

### Step 1: real client IP in the web server
- **Why:** behind Cloudflare, nginx sees the edge as the client. Logs, Moodle's IP checks and every per-IP limit
  are wrong until nginx takes the address from `CF-Connecting-IP`, but only when the TCP peer is a Cloudflare edge.
- **Backup:** `sudo install -d -m 700 /root/cloudflare-$(date +%F) && sudo tar -C / -czf /root/cloudflare-$(date +%F)/nginx-etc.tgz etc/nginx`.
  Check no `real_ip_header` exists yet (`cf-discover.sh`); a second one in the http context fails `nginx -t`.
- **Change:** generate, read, install (the script handles the missing trailing newline that broke the first server):
  ```bash
  T=$(mktemp -d)                    # private scratch dir: a fixed /tmp name could be pre-created by another user
  bash scripts/cf-ranges.sh --out "$T/cloudflare-realip.conf" && cat "$T/cloudflare-realip.conf"
  grep -n 'include /etc/nginx/conf.d/\*.conf' /etc/nginx/nginx.conf      # conf.d must be included in http {}
  sudo install -m 644 -o root -g root "$T/cloudflare-realip.conf" /etc/nginx/conf.d/cloudflare-realip.conf
  rm -rf -- "$T"
  ```
- **Test:** `sudo nginx -t`. **Apply:** `sudo systemctl reload nginx` (safe at any hour; it only trusts the header
  from Cloudflare ranges, so it can go live before the DNS cutover).
- **Verify:** wait 2-5 minutes, then `bash scripts/realip-check.sh` (PASS = no Cloudflare addresses among recent
  clients) and `curl -s -o /dev/null -w '%{http_code}\n' https://<SITE>/login/index.php` (200).
- **Rollback:** `sudo rm /etc/nginx/conf.d/cloudflare-realip.conf && sudo nginx -t && sudo systemctl reload nginx`.
- **Maintenance:** monthly `bash scripts/cf-ranges.sh --compare /etc/nginx/conf.d/cloudflare-realip.conf`; on
  DIFFERENT regenerate and install with this same step. Details, Apache and Moodle: `references/real-ip.md`.

### Step 2: Moodle uses REMOTE_ADDR only (`getremoteaddrconf = 3`)
- **Why:** with 0 (common on old sites) Moodle believes `X-Forwarded-For`/`Client-IP` sent by any browser, so IPs
  in logs and IP-based checks can be spoofed. After step 1, `REMOTE_ADDR` is the real visitor; 3 is Moodle's default.
- **Backup:** note the current value (`cf-discover.sh` prints it) in the log entry. If `config.php` forces it, back up
  `config.php` (`<MOODLE>/config.php.bak-YYYY-MM-DD`, same owner and mode) and change it there instead.
  If `$CFG->tracksessionip` is on, changing the IP source may log users out: do it in the quiet hour and say so.
- **Change/apply:** `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=getremoteaddrconf --set=3`
- **Verify:** `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=getremoteaddrconf` prints 3; login page 200.
- **Rollback:** the same command with `--set=<old value>`.

### Step 3: cache rule for Moodle's versioned static URLs (owner, dashboard)
- **Why:** Cloudflare caches by file extension. Moodle's theme CSS, JavaScript, images and fonts are served by
  `.php` scripts with a revision in the URL and `Cache-Control: public, max-age=..., immutable`, but Cloudflare treats
  them as dynamic and fetches every one from the origin. A rule marking exactly these paths "eligible for cache"
  serves them from the edge near the student.
- **Backup:** none on the server. Baseline: `bash scripts/cf-cache-check.sh` (static shows DYNAMIC).
- **Change (owner):** `references/dashboard-steps-ar.md` §3 with the expression in `assets/cache-rule-expression.txt`
  (prefix `<SUBPATH>` if set). Design rules and optional extras (ESM, page-builder media): `references/cache-rules.md`.
- **Verify:** `bash scripts/cf-cache-check.sh` → every static kind PASS (MISS or EXPIRED, then HIT), every dynamic
  page DYNAMIC/BYPASS, and no HIT that carries `Set-Cookie`. A FAIL on a dynamic page: the owner disables the rule at
  once, then investigate.
- **Rollback:** the owner disables or deletes the rule; effective immediately. No purge is needed: the URLs are
  versioned, and a theme change or cache purge in Moodle changes them.

### Step 4: one upload limit for every layer, and tell the teachers
- **Why:** Cloudflare rejects request bodies above its plan limit (Free/Pro 100 MB, Business 200 MB; verify on
  Cloudflare's site). If nginx, PHP and Moodle allow more, Moodle invites uploads that die at the edge with a raw error.
- **Discovery:** `bash scripts/upload-limits.sh`. Owner decision (Arabic): align to the cap (recommended), or keep a
  higher limit and accept failures. A DNS-only upload hostname bypasses all protection: not recommended.
- **Backup:** `V=$(readlink -f <VHOST>); sudo cp -a "$V" "$V.bak-$(date +%F)"` (the resolved file, normally in
  `sites-available/`). If the real file itself lives in `sites-enabled/` (no symlink), copy it to
  `/root/cloudflare-$(date +%F)/` instead: nginx loads every file in `sites-enabled/`, so a backup there becomes a
  second live copy of the site. Note the old `maxbytes` value.
- **Change:** in the Moodle server block set `client_max_body_size 100M;` with
  `sudo python3 -I ../nginx/scripts/replace-once.py "$V" --old 'client_max_body_size 256M;' --new 'client_max_body_size 100M;'`
  (diff first, then `--apply`; it asserts the old text occurs once). Add the line if only the http-level value exists. Then
  `sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=maxbytes --set=104857600`. Leave PHP's
  `upload_max_filesize`/`post_max_size` alone if they are already at or above the cap.
- **Test:** `sudo nginx -t`. **Apply:** `sudo systemctl reload nginx`.
- **Verify:** `upload-limits.sh` shows one effective value set consistently; the owner sees "Maximum size for new
  files: 100 MB" in a file picker. Send `assets/teacher-upload-notice-ar.md` through the owner.
- **Rollback:** copy the `.bak` back, `nginx -t`, reload; `cfg.php --name=maxbytes --set=<old>`.
- Details (course/activity limits, Apache `LimitRequestBody`, big course restores, 524 timeouts): `references/upload-limits.md`.

### Step 5: SSL mode Full (strict), after a renewal dry run
- **Why:** "Full" encrypts Cloudflare→origin but accepts any certificate, so a forged origin is not detected;
  "Full (strict)" requires a valid certificate. The certificate must keep renewing while Cloudflare sits in front.
- **Check:** `cf-discover.sh` → "origin cert for site: valid" for every proxied name (repeat with
  `SITE=www.<domain>`). Read the renewal config's hooks (pre/post hooks run during a dry run).
- **Dry run (quiet hour; the nginx authenticator reloads nginx):**
  ```bash
  T=$(mktemp -d)
  sudo sh -c 'find /etc/nginx -type f -exec md5sum {} + | sort -k2' > "$T/nginx-md5-before.txt"
  sudo certbot renew --dry-run --cert-name <SITE>            # Let's Encrypt staging; live certificates untouched
  sudo sh -c 'find /etc/nginx -type f -exec md5sum {} + | sort -k2' > "$T/nginx-md5-after.txt"
  diff "$T/nginx-md5-before.txt" "$T/nginx-md5-after.txt" && sudo nginx -t; rm -rf -- "$T"
  ```
- **Change (owner):** SSL/TLS → Overview → Full (strict) (`references/dashboard-steps-ar.md` §4).
- **Verify:** every proxied name answers 200/30x through Cloudflare for 10 minutes, no 526. Log the dry run as
  "tested; confirmed at the next real renewal (<date from certbot certificates>)".
- **Rollback:** the owner switches back to Full. If the dry run fails: `references/ssl-and-renewal.md` (Origin CA
  certificate, DNS-01 with a scoped token the owner inserts, or a rule exempting `/.well-known/acme-challenge/`).

### Step 6: origin exposure and the wildcard DNS trap
- **Why:** Cloudflare protects only proxied names. A DNS-only record, another site on the same IP, a mail host or
  a `*` record pointing at the origin lets anyone skip Cloudflare. A wildcard also makes every retired or misspelt
  name reach whatever vhost the web server uses as default, and it hides missing records.
- **Discovery:** `bash scripts/origin-exposure.sh [--common]`. For each EXPOSES-ORIGIN name propose (Arabic): proxy
  it (web sites, after their own real-IP and certificate checks), move it, or accept it with a reason (mail hosts
  cannot be proxied).
- **Wildcard order:** (1) the nginx module's default server that refuses unknown Host/SNI, with before/after probes;
  (2) every name that is needed gets its own record (www, mail-provider CNAMEs such as bounce/DKIM records);
  (3) the owner deletes `*`. Verify with `origin-exposure.sh` (no wildcard) and the mail module's DNS checks.
- **Rollback:** the owner re-creates the deleted records (keep a zone export from before: DNS → Records → Export).

### Step 7: origin lock (later; mandatory when the server moves to a new IP)
- **Why:** while the origin answers anyone, scanners and floods can hit it directly. nginx can accept the Moodle
  site only from Cloudflare edges (and the server itself), per server block, without touching other sites.
- **How, tests, rollback:** `references/origin-exposure.md` §Origin lock. Key points: match the TCP peer with
  `geo $realip_remote_addr` (plain `allow/deny` after real-IP refuses every visitor, tested on the first server);
  only the 443 server block; port 80 stays open; keep the range list current (monthly compare becomes mandatory);
  to stop using Cloudflare, **remove the lock first**, then grey-cloud.

### Step 8: Cloudflare features that break or help Moodle (owner)
Off: Rocket Loader (breaks RequireJS/AMD), Email Address Obfuscation (rewrites HTML), Auto Minify if still offered,
Always Online, 0-RTT. Careful: Bot Fight Mode and "Under Attack" challenge the Moodle mobile app, web services and
monitors (Bot Fight Mode cannot be bypassed by WAF rules on Free). On: TLS 1.3, HTTP/3, minimum TLS 1.2, Always Use
HTTPS (after step 5). The single Free rate-limiting rule may mirror the nginx front-page limit. `cf-discover.sh`
detects Rocket Loader and e-mail obfuscation from the page. Steps: `references/dashboard-steps-ar.md` §5.

### Step 9: data location and PDPL (management decision)
Cloudflare terminates TLS, so it processes cookies, passwords and page content, possibly outside the country. Give
management the Arabic note in `references/data-location.md` and record their decision in the handbook. Not legal advice.

## 6. Verification checklist
- [ ] `realip-check.sh` PASS; the access log shows visitors, not edges; `nginx -t` clean.
- [ ] Moodle `getremoteaddrconf` = 3 (and no contrary override in `config.php`).
- [ ] `cf-cache-check.sh`: all static kinds MISS→HIT; dynamic pages DYNAMIC/BYPASS; no cached `Set-Cookie`.
- [ ] `upload-limits.sh`: one effective limit, Moodle shows it; teachers informed.
- [ ] Origin certificate valid for every proxied name; renewal dry run success; mode Full (strict); no 526.
- [ ] `origin-exposure.sh` reviewed with the owner; wildcard removed or justified; zone export kept.
- [ ] Rocket Loader and e-mail obfuscation off; challenges do not hit the mobile app.
- [ ] Monthly range drift check noted in the handbook to-do list; management decision on data location recorded.
- [ ] Log entries written for each step; the log's "customised files" table lists `cloudflare-realip.conf` and the
      Moodle settings.

## 7. Log entry example
```
### 2026-05-12 02:10 — nginx takes the real client IP from Cloudflare  (session: cloudflare onboarding, approved by owner: yes)
- What/why: the site is proxied by Cloudflare since 2026-05-09; nginx logged edge addresses as clients, so logs,
  Moodle IP checks and any per-IP limit were wrong.
- Files/settings touched: new /etc/nginx/conf.d/cloudflare-realip.conf (15 IPv4 + 7 IPv6 set_real_ip_from ranges,
  generated by cf-ranges.sh from cloudflare.com/ips-v4 and /ips-v6 at 02:08; real_ip_header CF-Connecting-IP).
  nginx -t OK, reload 02:10:07.
- Backup / rollback: /root/cloudflare-2026-05-12/nginx-etc.tgz; rollback = sudo rm the file, nginx -t, reload.
- Verified: realip-check.sh 0 of <N> recent lines from Cloudflare ranges (all of them before); login page 200.
- Next: Moodle getremoteaddrconf 0 → 3 (step 2); monthly cf-ranges.sh --compare.
```
Add `/etc/nginx/conf.d/cloudflare-realip.conf` and "Moodle getremoteaddrconf = 3, maxbytes = ..." to the log's
customised-files table.

## 8. Pitfalls we hit on the first server
- **Glued ranges.** Cloudflare's `ips-v4` file has no trailing newline. `cat ips-v4 ips-v6` glued the last IPv4 and
  first IPv6 range on one line and `nginx -t` failed. It was caught because the test ran before the reload: never
  skip `nginx -t`, and generate the file with `cf-ranges.sh`.
- **Real IP first.** Without it, per-IP rate limiting would have throttled Cloudflare itself, and Moodle had been
  trusting client-sent `X-Forwarded-For` (`getremoteaddrconf = 0`) for years.
- **Extension-based caching.** For days after the cutover every theme file still came from the distant origin,
  although Moodle marked it `public, immutable`. The cache rule fixed it (MISS→HIT verified per kind).
- **Rules are not first-match.** All matching Cache Rules apply and the last one wins; a catch-all "bypass" rule in
  last place would cancel the static rule. Do not add a catch-all; Cloudflare's default already skips HTML.
- **Measure, do not infer.** One record said page-builder images were BYPASSed because of `Set-Cookie`; a later check
  showed HIT and the record was corrected. Re-run `cf-cache-check.sh` instead of reasoning from headers.
- **Upload cap.** The vhost allowed 256 MB, Cloudflare 100 MB, Moodle "no limit"; files over 100 MB already existed in
  the data directory. The owner chose 100 MB everywhere plus a teacher notice; long videos go to a video platform.
- **SSL mode was not what people thought.** A retired name answered 200 through Cloudflare while the origin served
  another site's certificate, which proved the zone was Full, not strict. After the default server refused unknown
  SNI, that name returned 525. The origin certificate was valid and renewing, so strict was possible all along.
- **Renewal behind the proxy.** The dry run succeeded (Cloudflare redirected the HTTP challenge to HTTPS and Let's
  Encrypt followed it to the origin). A dry run uses the staging CA: the real renewal is confirmed only at the next
  real run, and the log said so.
- **Wildcard record.** A proxied `*` made every name resolve; the origin's first vhost (another application) answered
  them, including a retired subdomain. It also hid a missing CNAME for the mail provider's bounce domain after the
  DNS import, which silently broke bounce handling and SPF alignment. Compare the imported zone record by record.
- **Shared or historical IP.** An origin IP that other DNS-only sites share, or that DNS history still shows, lets
  anyone bypass Cloudflare, and a scanner aimed at a neighbouring site on that IP fills the same port-443 accept
  queue as the Moodle site. Proxying the Moodle name alone does not hide the origin. The lasting fix is a new IP that
  is only ever published behind Cloudflare, plus the origin lock.
- **Origin lock traps.** `allow <ranges>; deny all;` after real-IP checks the visitor's address and refused everyone
  in a scratch test; a firewall (ufw) lock would have cut off the non-proxied sites on the same IP.
- **Edge vs student.** The `cf-ray` code seen from the server is the edge near the server. Which edge serves
  students depends on their carrier; check `/cdn-cgi/trace` (`colo=`) from phones on each carrier.
- **Exact times.** Some first-day log times were estimates and had to be corrected; take times from `date`.

## 9. Files in this module
| File | Purpose |
|---|---|
| `scripts/cf-discover.sh` | Read-only discovery: proxy status, real-IP, Moodle IP source, upload summary, origin cert, certbot setup, Rocket Loader/obfuscation detection |
| `scripts/lib-env.sh` | Parse-only server.env loader used by the scripts (the file is never sourced) |
| `scripts/cf-ranges.sh` | Builds `cloudflare-realip.conf` (nginx) or mod_remoteip config (Apache) from Cloudflare's lists; validates; optional `geo` block for the origin lock; `--compare` drift check |
| `scripts/realip-check.sh` | Counts recent access-log clients inside Cloudflare ranges (no addresses printed) |
| `scripts/cf-cache-check.sh` | MISS→HIT proof for each static kind, DYNAMIC check for dynamic pages, cached-cookie guard |
| `scripts/origin-exposure.sh` | DNS names and wildcards that resolve to the origin IP; MX check |
| `scripts/upload-limits.sh` | Cloudflare / nginx / Apache / PHP-FPM / Moodle upload limits and the effective one |
| `references/real-ip.md` | Real IP in nginx and Apache, Moodle settings, range maintenance |
| `references/cache-rules.md` | Rule design, what never to cache, optional ESM and page-builder extras, troubleshooting statuses |
| `references/upload-limits.md` | All layers, course/activity limits, big restores, 100-second timeout |
| `references/ssl-and-renewal.md` | SSL modes, how to infer the current one, strict readiness, certbot dry run, fallbacks |
| `references/origin-exposure.md` | Exposure sources, wildcard trap, origin lock (nginx, Apache), AOP and Tunnel alternatives |
| `references/dashboard-steps-ar.md` | Owner's Cloudflare dashboard steps in Arabic |
| `references/data-location.md` | PDPL / data-location caveat with an Arabic note for management |
| `assets/cache-rule-expression.txt` | Expression to paste into the Cache Rule editor |
| `assets/origin-lock.conf.snippet` | The one-line lock and its rollback note |
| `assets/teacher-upload-notice-ar.md` | Arabic notice to teachers about the upload limit |
