# Apache instead of nginx

None of these Apache forms were exercised on the first server (nginx). Test every change with
`sudo apache2ctl configtest` and the same read-only probes (`vhost-probe.sh` works for Apache too: it reads names
from `apache2ctl -S`; `moodle-smoke.sh` is web-server neutral). When in doubt, stop and ask.

## Step 1: default virtual host
Apache uses the **first** `<VirtualHost>` for an address:port when Host/SNI matches no `ServerName`/`ServerAlias`
(on Debian: `000-default.conf` sorts first). Make that first vhost refuse:
```apache
# /etc/apache2/sites-available/000-catchall.conf (enable with a2ensite; check it sorts first in `apache2ctl -S`)
<VirtualHost *:80>
    ServerName catchall.invalid
    CustomLog ${APACHE_LOG_DIR}/default-reject.log combined
    <Location />
        Require all denied
    </Location>
</VirtualHost>
<VirtualHost *:443>
    ServerName catchall.invalid
    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
    <Location />
        Require all denied
    </Location>
</VirtualHost>
```
Apache has no `return 444` or `ssl_reject_handshake`: unknown names get a 403 and, on 443, the self-signed
certificate. `SSLStrictSNIVHostCheck on` additionally refuses clients that send no SNI. Probe before/after with
`vhost-probe.sh`.

## Step 2: scanner paths and the existence check
- Existence: with PHP-FPM wired as `<FilesMatch "\.php$"> SetHandler "proxy:unix:<FPM_SOCK>|fcgi://localhost" </FilesMatch>`,
  Apache maps the URL to a file first, so a missing `.php` is a 404 from Apache and never reaches PHP-FPM. With
  `ProxyPassMatch ^/(.*\.php(/.*)?)$ fcgi://...`, there is **no** existence check: switching to `SetHandler` is the
  fix (a bigger change: test file downloads, slash arguments and the AJAX endpoint on the smoke tests).
- Slash arguments need `AcceptPathInfo On` for the Moodle directory (Moodle's documented Apache requirement).
- Scanner prefixes, before anything else in the vhost:
  `RedirectMatch 404 "(?i)^/(wp-admin|wp-content|wp-includes|wp-json|minio|nifi-api|swagger|swagger-ui|api-docs|actuator|cgi-bin|phpmyadmin|pma|telescope|_debugbar|vendor/phpunit|boaform|HNAP1)(/|$)"`
  (same collision checks as for nginx).
- The 4.5+ router needs `FallbackResource /r.php` (or the rewrite Moodle documents); unknown URLs then boot Moodle,
  as with nginx.

## Steps 3-5: rate limits
Apache has no core equivalent of `limit_req` with a dry run. Modules (`mod_evasive`, `mod_qos`, ModSecurity rules)
behave differently and are installs: do not improvise. Options to propose: Cloudflare's edge rate-limiting rule (if
proxied), or a reverse-proxy nginx in front (a project). The review logic (dry run first, NAT awareness) still applies.

## Step 6: static caching
- Page-builder media: Apache's X-Sendfile (`mod_xsendfile`) is a separate module; without it PHP sends the file. A
  header override keyed on the original URL is possible with mod_headers:
  ```apache
  <If "%{REQUEST_URI} =~ m#^/pluginfile\.php/1/local_edwiserpagebuilder/#">
      Header always set Cache-Control "public, max-age=86400"
      Header always unset Expires
  </If>
  ```
  Test carefully (the `<If>` must match the original URI, and course files must keep their headers).
- gzip: `AddOutputFilterByType DEFLATE image/svg+xml font/ttf font/otf application/vnd.ms-fontobject` (mod_deflate).
- favicon: `Alias /favicon.ico <STATIC_DIR>/favicon.ico` with a `<Directory>`/`<Files>` grant, plus
  `ExpiresByType image/x-icon "access plus 7 days"` (mod_expires).

## Upload limit and real IP
See the cloudflare module: `LimitRequestBody` (`../../cloudflare/references/upload-limits.md`) and mod_remoteip
(`../../cloudflare/references/real-ip.md`).
