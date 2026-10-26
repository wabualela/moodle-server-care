# Static caching: page-builder media, gzip types, favicon

## 1. Page-builder media cached for one day (X-Accel)
### The problem
Moodle serves stored files through `pluginfile.php`. The plugin decides the cache lifetime. Edwiser's page builder
(`local_edwiserpagebuilder`) calls `send_stored_file($file, 0, ...)`; a lifetime of 0 makes Moodle send
`Cache-Control: private, max-age=10` and an `Expires` date in 1970. The images on the front page are therefore
re-requested through PHP after 10 seconds, on every visit. On the first server that was hundreds of PHP requests a
day for a handful of images.

### Why it is safe for this plugin (verify on each server)
The plugin's `local_edwiserpagebuilder_pluginfile()` serves files of the **system context only** and does not call
`require_login`: the content is public by design. Context id 1 is always the system context. `nginx-discover.sh`
prints the handler's key lines; check them for the installed version. If it requires login, checks capabilities, or
serves other contexts, stop: caching it as public could leak.

### How (no vendor patch)
Moodle hands file delivery to nginx with `X-Accel-Redirect` when `config.php` has
`$CFG->xsendfile = 'X-Accel-Redirect';` and `$CFG->xsendfilealiases = ['/dataroot/' => $CFG->dataroot];` and the
vhost has an `internal` location aliasing the data root. In that internal location, `$request_uri` still holds the
original URL, and the `expires` directive replaces the `Cache-Control` and `Expires` headers copied from PHP. Two maps
(`assets/moodle-static.conf`) make the change apply to the page-builder path only:
```nginx
location /dataroot/ {
    internal;
    alias <DATAROOT>/;
    expires    $moodle_pb_expires;        # 1d for page-builder media, "off" (untouched) for everything else
    add_header Cache-Control $moodle_pb_cc;   # adds "public" for page-builder media; empty value adds nothing
    # + every add_header of the server/http level, repeated here (see below)
}
```
**add_header inheritance.** nginx inherits `add_header` from the server or http level only into locations that have
no `add_header` of their own. The line above therefore removes every outer `add_header` (HSTS,
`X-Content-Type-Options`, `Referrer-Policy`, CSP) from all X-Accel file responses, silently. `nginx-discover.sh`
prints the http- and server-level `add_header` lines (section "add_header"); copy each one into this location, with
its `always` flag, and compare `curl -sI` of a course file before and after. If there are none, nothing to copy.

Result for a page-builder image: `Cache-Control: max-age=86400` plus `Cache-Control: public`, `Expires` +1 day.
Every other file (course files, private files) keeps Moodle's headers. Tested on a scratch nginx and live on the
first server (a course overview image kept its own headers).

### Without X-Accel
PHP sends the file body itself and the internal location is never used. Options: enable X-Accel first (its own
change: `config.php` backup, two settings, an internal location, tests of file downloads and video seeking), or a
vendor patch (lifetime `DAYSECS` and `cacheability => public` in the plugin's `send_stored_file` call) through the
`tuning` module's patch tool, which is lost on plugin upgrades. Prefer X-Accel.

### Verify
```bash
U=$(curl -s https://<SITE>/ | grep -oE '/pluginfile\.php/1/local_edwiserpagebuilder/[^"]+' | head -n 1)
curl -s -o /dev/null -D - "https://<SITE>$U" | grep -iE 'cache-control|expires|set-cookie'
C=$(curl -s https://<SITE>/ | grep -oE '/pluginfile\.php/[0-9]+/course/overviewfiles/[^"]+' | head -n 1)
[ -n "$C" ] && curl -s -o /dev/null -D - "https://<SITE>$C" | grep -iE 'cache-control|expires'   # unchanged
```
Editors: an image replaced under the same file name may show the old version for up to a day; upload it under a
new name instead. Behind Cloudflare, these URLs can then be added to the cache rule (cloudflare module,
`../../cloudflare/references/cache-rules.md` §Optional additions), after checking that no `Set-Cookie` comes with them.

## 2. gzip for SVG and uncompressed fonts
Debian's default `gzip_types` lacks SVG and TTF/OTF/EOT fonts. Append to the existing line in `nginx.conf`:
`image/svg+xml font/ttf font/otf application/vnd.ms-fontobject`. Do not add `font/woff` or `font/woff2` (already
compressed) or images like PNG/JPEG. Check that `gzip_proxied any` and `gzip_vary on` are set if responses come
from FastCGI/X-Accel or pass a proxy. Verify:
`curl -s -H 'Accept-Encoding: gzip' -o /dev/null -D - "<an SVG URL from the page>" | grep -i content-encoding`.

## 3. A static `/favicon.ico`
Browsers request `/favicon.ico` by themselves. With no file in the docroot, the request falls through
`try_files ... /r.php` and boots Moodle for a 404 (pre-4.5: a cheap nginx 404, still noisy). Serve a real file:
1. `sudo install -d -m 755 <STATIC_DIR>` outside the Moodle tree (upgrades and git never touch it), then copy a
   32x32/48x48 `.ico` (from the owner's designer, or as an interim the theme's own `pix/favicon.ico` if present):
   `sudo install -m 644 <source>.ico <STATIC_DIR>/favicon.ico`.
2. Add `assets/favicon-location.conf` inside the Moodle server block, before `location /`.
3. Verify: `curl -sI https://<SITE>/favicon.ico` → 200, `image/x-icon`, `Cache-Control: max-age=604800`.

## 4. Theme favicon 404s (find before fixing)
Themes link their own favicon through pluginfile (e.g. `/pluginfile.php/1/theme_<name>/favicon.../<rev>/<file>`).
404s for such URLs each boot Moodle. Find the exact failing form first:
```bash
sudo awk '$9 == 404 && $7 ~ /favicon/ {print $7}' <access log> <access log>.1 | sed -E 's#/[0-9]{6,}/#/<rev>/#' | sort | uniq -c | sort -rn | head
```
On the first server the cause was a file name with a space that some clients double-encoded (`%2520`); renaming
the stored file without a space (same content; theme caches reset in a quiet hour) stopped dozens of 404s a day. Other
causes: an old revision hard-coded in HTML, or a missing file. Fix the source of the failing form; a Moodle setting
change is a Moodle change (log it; the `tuning` module covers Moodle-side fixes).

## Rollback
Delete `conf.d/moodle-static.conf` and the two lines in `location /dataroot/`; restore `nginx.conf.bak-YYYY-MM-DD`;
remove the favicon location; `nginx -t`; reload.
