# The PHP location: existence check, path split, PATH_INFO, scanner 404s

## Why
- A PHP location without an existence check (`location ~ \.php$ { fastcgi_pass ...; }`) sends every `.php` URL to
  PHP-FPM, which answers "File not found." after logging `Primary script unknown`. Scanners send thousands.
- With the Moodle 4.5+ router (`try_files $uri $uri/ /r.php$is_args$args;`), every other unknown URL boots Moodle,
  opens a session and renders a 404 page. Scanners with a cookie jar queue on their own session lock; on the first
  server their 404s took many seconds during bursts and occupied PHP workers.
nginx can answer both classes itself in microseconds.

## Target location (assets/php-location.conf)
```nginx
location ~ [^/]\.php(/|$) {
    fastcgi_split_path_info ^(.+?\.php)(/.*)$;
    set $path_info $fastcgi_path_info;
    try_files $fastcgi_script_name =404;
    fastcgi_index index.php;
    fastcgi_pass unix:<FPM_SOCK>;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_param PATH_INFO $path_info;
}
```
This is the same logic as Debian's `snippets/fastcgi-php.conf`. If the vhost already includes that snippet, the
existence check is in place.

### Three rules
1. **Save PATH_INFO before `try_files`.** `try_files` resets `$fastcgi_path_info` (nginx trac #321). Without
   `set $path_info` and `PATH_INFO $path_info`, PATH_INFO is empty and Moodle's slash arguments break: no theme CSS,
   no JavaScript, no images, no files. (`set` runs in the rewrite phase, before `try_files`, whatever the line order.)
2. **Non-greedy split.** With the greedy `^(.+\.php)(/.+)$` plus `try_files`, two URL forms get nginx 404s that
   worked before only because PHP-FPM's `cgi.fix_pathinfo=1` walked back to the real script:
   - a `.php/` later in the path: `/pluginfile.php/<ctx>/mod_folder/content/0/dir.php/file.txt` (greedy picks
     `.../dir.php` as the script);
   - an empty path info with a trailing slash: `/login/index.php/` (greedy needs `/.+`).
   A URL that merely ends in `.php` (`.../lab1.php`) splits correctly either way. `^(.+?\.php)(/.*)$` handles all.
3. **Keep the site's own extras** (`fastcgi_read_timeout`, `fastcgi_buffers`, `fastcgi_param HTTPS on`, ...) when
   replacing the block; only the split, the `set`, the `try_files` and `PATH_INFO` lines change.

## Moodle URL forms that must keep working
| Form | Example | Notes |
|---|---|---|
| theme CSS | `/theme/styles.php/<theme>/<rev>_<rev>/all` | slash arguments |
| theme JS / jQuery | `/theme/javascript.php/...`, `/theme/jquery.php/...` | |
| icons/images | `/theme/image.php/<theme>/<component>/<rev>/<name>` | |
| fonts | `/theme/font.php/<theme>/<component>/<rev>/<file>` | linked from the CSS |
| core JS | `/lib/javascript.php/<rev>/lib/...` | |
| AMD modules | `/lib/requirejs.php/<rev>/core/first.js` | the page links the base `.../<rev>/` |
| YUI | `/theme/yui_combo.php?rollup/...` | query string, no PATH_INFO |
| files | `/pluginfile.php/<ctx>/<component>/<area>/<item>/<path>` | `.php` may appear inside `<path>` |
| ESM (5.x) | `/r.php/core/esm/<rev>/<module>` | through the router script |
| AJAX | `/lib/ajax/service.php`, `/lib/ajax/service-nologin.php` | POST from pages |
| web services | `/webservice/rest/server.php`, `/login/token.php`, `/tokenpluginfile.php/...` | mobile app |
| legacy shims (5.x) | e.g. `/course/admin.php` | a router route for an old `.php` URL |
`scripts/moodle-smoke.sh` requests one of each that the login/front page links, plus the path forms above; run it
before (`--phase before`) and after (`--phase after`).

## Shim routes (Moodle 5.x)
Moodle 5's router can serve legacy `.php` URLs through "shim" routes declared in `*/classes/route/shim/*.php`.
`nginx-discover.sh` lists every shim path and whether its `.php` file exists (core's `exampleshimroute2.php` is a
deliberate test route without a file). With a regex PHP location, a `.php` URL whose file is missing goes to PHP-FPM
and gets "File not found" even before the change, so the existence check normally changes nothing for it; but the
first server treated this as a hard pre-check, and so should you, because configurations differ:
- for each non-test shim without a file, run `moodle-smoke.sh --phase before --extra /that/path.php=moodle`;
- if it is answered by Moodle today (some other location or fallback serves it), stop and ask: the change would
  break it; an exact `location = /that/path.php` that keeps today's handling is the usual fix, tested on scratch;
- if it already fails today, note it and continue.
**Re-run `nginx-discover.sh` after every Moodle upgrade, before reloading nginx.**

## Scanner block (assets/scanner-block.conf)
A case-insensitive regex location returning 404 for common probe prefixes (WordPress, Swagger/OpenAPI, Spring
actuator, phpMyAdmin, MinIO/NiFi, Laravel Telescope/debugbar, `vendor/phpunit`, router exploits). It must sit before
the PHP location (regex locations match in file order) so that `/wp-admin/x.php` is caught too.
- `/.env` and other dotfiles are usually already 404 through `location ~ /\.`; check that it exists.
- `/wp-login.php` and `/xmlrpc.php` become nginx 404s through the existence check.
- Never add `/api/` (Moodle 5 REST routes), component names, or anything that exists in `<DOCROOT>`.
  `nginx-discover.sh` checks the list against the docroot (case-insensitively, as the regex is `~*`) and the route
  path segments. `vendor/phpunit` existing in the docroot is a finding in itself (development tool on production).

## Rollback
Restore the backup of the resolved vhost file (`V=$(readlink -f <VHOST>); sudo cp -a "$V.bak-YYYY-MM-DD" "$V"`, or
the copy in `/root/nginx-<date>/`), `sudo nginx -t`, reload. If any
slash-argument URL fails after a reload, roll back first and analyse afterwards.
