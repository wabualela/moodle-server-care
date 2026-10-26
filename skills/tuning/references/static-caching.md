# Static caching on the Moodle side

Scripts: `scripts/perf-settings.php` (settings), `scripts/static-check.sh` (headers as visitors get them),
`scripts/rename-theme-file.php` (file names with spaces). The nginx side belongs to the `nginx` module and the
CDN side to the `cloudflare` module; this file says what Moodle itself must do and how to check the whole chain.

## Contents
1. How Moodle serves static files
2. Moodle settings that must be right
3. Files that every visitor fetches through PHP
4. Theme files with spaces in their names (favicon case)
5. /favicon.ico
6. Verification and rollback

## 1. How Moodle serves static files
- Theme CSS, JavaScript, YUI, theme images and fonts come from versioned URLs (`/theme/styles.php/<theme>/<rev>/all`,
  `/lib/javascript.php/<rev>/...`, `/lib/requirejs.php/<rev>/...`, `/theme/image.php/...`, `/theme/font.php/...`).
  Moodle sends them `public, max-age=7776000, immutable` (90 days) when caching is on and the URLs use slash
  arguments. A new revision (theme caches purged) changes the URL, so long caching is safe.
- User and plugin files come from `/pluginfile.php/...` with the lifetime the plugin chooses. Lifetime 0 gives
  `private, max-age=10` and an Expires date in 1970, so browsers fetch the file again through PHP on every view.
- With `$CFG->xsendfile = 'X-Accel-Redirect'` (nginx) or `X-Sendfile` (Apache), PHP only decides and the web server
  sends the bytes; without it PHP streams every file.

## 2. Moodle settings that must be right
Run `bash run-as-web.sh perf-settings.php`. Items marked CHECK in the "caching" and "debugging" groups:

| Setting | Production value | If wrong |
|---|---|---|
| `themedesignermode` | off | CSS rebuilt on every request: the single most expensive misconfiguration |
| `cachejs`, `cachetemplates`, `langstringcache`, `yuicomboloading` | on | JS/templates/strings re-read on every request |
| `slasharguments` | on | `?file=` URLs that browsers and CDNs cache poorly |
| `debug` / `debugdisplay` / `perfdebug` | none or minimal / off / off | extra work and information leaks |
| `xsendfile` + `xsendfilealiases` | set when the web server supports it | PHP workers busy streaming files |

Changing one of these is a Moodle setting change: save the old value (log it), change it with
`sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=<setting> --set=<value>` (cfg.php exists in Moodle 3.6+),
verify, log. A value forced in `config.php` must be changed there (backup, `php -l`, then reload PHP-FPM if OPcache
does not revalidate). `themedesignermode` off and purging theme caches change the theme revision: quiet hour.

## 3. Files that every visitor fetches through PHP
- Find them: `bash static-check.sh` lists the pluginfile URLs of the front page with their Cache-Control. Public
  images with `private, max-age=10` are the target (first server: page-builder images, hundreds of PHP requests a
  day for images that never change).
- Moodle-side fix options, from best to worst:
  1. The plugin offers a cache-lifetime setting: use it.
  2. nginx override **in the internal X-Accel location**, matched on the original `$request_uri` so that only the
     public plugin's files change (nginx module; the first server's snippet: a `map $request_uri` that returns `1d`
     for `^/pluginfile\.php/1/<component>/` and `off` otherwise, used by `expires` and `add_header Cache-Control`
     inside `location /dataroot/ { internal; ... }`). Safe only when that plugin's pluginfile handler serves
     system-context files without `require_login` (read the plugin's `lib.php` `*_pluginfile()` first).
  3. A vendor patch of the plugin's `send_stored_file($file, 0, ...)` lifetime (see `vendor-patches.md`; lost on
     every upgrade).
- Never cache `/pluginfile.php/*` broadly: course files are private and must keep Moodle's headers.
- A pluginfile response to a first-time guest can carry `Set-Cookie` (new session). Browsers cache it anyway; a CDN
  does not store responses that set cookies. Check with `static-check.sh` (cookie=yes/no) before promising CDN hits.

## 4. Theme files with spaces in their names (favicon case)
- A stored file like `Logo final.svg` is linked as `Logo%20final.svg`; some clients or copied HTML double-encode it
  (`Logo%2520final.svg`). Each failing request boots Moodle and returns 404.
- First find the failing URL form in the access log (do not guess):
  `sudo awk '$9==404 && $7 ~ /pluginfile/ {print $7}' <access log> | sed -E 's#/[0-9]{6,}/#/<rev>/#' | sort | uniq -c | sort -rn | head`
  (`$7` is the path and `$9` the status in the common/combined and "perf" formats). If the 404s are another form
  (old revision, hard-coded URL in page-builder HTML or `additionalhtmlhead`), renaming does not help: fix the source.
- If they are a space-encoding form: `bash run-as-web.sh rename-theme-file.php --component=theme_<name>` lists files
  with unsafe names and the matching setting; then dry run and execute:
  `bash run-as-web.sh rename-theme-file.php --component=theme_<name> --filearea=<area> --from='<old name>' --to=<new-name> [--execute]`.
- Execute renames (same content), points the setting at the new name and resets theme caches (new revision; quiet
  hour). Rollback: the same command with `--from`/`--to` swapped.

## 5. /favicon.ico
Browsers request `/favicon.ico` by themselves. Without a file it falls through to Moodle's router (on 5.1+ `r.php`)
and boots Moodle for a 404. Fix on the web-server side (nginx module: an exact `location = /favicon.ico` with an
alias to a static file kept outside the Moodle tree so upgrades do not remove it). Moodle side: nothing to change;
the theme's own favicon setting stays as it is.

## 6. Verification and rollback
- `bash static-check.sh --origin` (origin) and `bash static-check.sh` (through the CDN): versioned CSS/JS public,
  long max-age, gzip/br; targeted pluginfile images now cacheable; other pluginfile URLs unchanged; `/favicon.ico` 200.
- Count PHP requests for the targeted URLs per day before and after (access log), and favicon 404s per day.
- Rollback: settings back to the logged old values (`cfg.php`), file renames reversed with the script, nginx parts per
  the nginx module.
