# Real client IP behind Cloudflare (nginx, Apache, Moodle)

## Why it matters
Behind a reverse proxy the TCP peer is the proxy. Until the web server is told which peers are trusted proxies and
which header carries the visitor's address:
- access logs and audits count a handful of Cloudflare addresses as "clients";
- per-IP limits (`limit_req`, `limit_conn`, fail2ban web jails) throttle or ban Cloudflare itself, i.e. everyone;
- Moodle logs, login reports and any IP-restricted feature (IP blockers, quiz subnet restrictions, `tracksessionip`)
  see the wrong address, or trust a header the browser can forge.

`CF-Connecting-IP` holds exactly one address (the visitor as seen by Cloudflare), so no recursion or
`X-Forwarded-For` chain parsing is needed. Trust it only from Cloudflare's published ranges; from any other peer
the header is attacker-controlled.

## nginx
The `ngx_http_realip_module` is in Debian/Ubuntu/RHEL packages (`nginx -V 2>&1 | grep -o http_realip_module`).
`T=$(mktemp -d); bash scripts/cf-ranges.sh --out "$T/cloudflare-realip.conf"` produces, in the http context:
```nginx
set_real_ip_from <each Cloudflare IPv4 and IPv6 range>;   # one per line
real_ip_header CF-Connecting-IP;
```
Effects after reload: `$remote_addr` and `$binary_remote_addr` are the visitor for requests from Cloudflare peers;
`$realip_remote_addr` keeps the TCP peer (used by the origin lock). FastCGI gets `REMOTE_ADDR = $remote_addr`
through `fastcgi_params`, so Moodle sees the visitor without any Moodle change.

Notes:
- Place the file in a directory included **inside** `http {}` (Debian: `/etc/nginx/conf.d/*.conf`). Check with
  `grep -n include /etc/nginx/nginx.conf`. A distribution that includes `conf.d` elsewhere needs another place.
- One `real_ip_header` per context. If a vhost already sets its own (`real_ip_header X-Forwarded-For;` from an old
  load balancer), find out why before replacing it.
- `set_real_ip_from` in the http context applies to every vhost. That is harmless for sites not behind
  Cloudflare: their peers are not in the trusted ranges, so nothing changes for them.
- IPv6 ranges are needed even when the origin has no IPv6: Cloudflare may still use an IPv6 edge address towards
  dual-stack origins, and listing them costs nothing.

## Apache (2.4)
```bash
T=$(mktemp -d)        # private scratch dir, never a fixed name in /tmp
bash scripts/cf-ranges.sh --format apache --out "$T/cloudflare-remoteip.conf"
sudo install -m 644 "$T/cloudflare-remoteip.conf" /etc/apache2/conf-available/cloudflare-remoteip.conf; rm -rf -- "$T"
sudo a2enmod remoteip && sudo a2enconf cloudflare-remoteip      # a2enmod/a2enconf only create symlinks
sudo apache2ctl configtest && sudo systemctl reload apache2
```
- `RemoteIPTrustedProxy`, not `RemoteIPInternalProxy` (Cloudflare ranges are public addresses).
- The default `LogFormat` uses `%h`, which becomes the visitor once mod_remoteip runs; formats using `%{c}a` show
  the peer. Check the site's `CustomLog` format.
- PHP-FPM through `mod_proxy_fcgi` receives the rewritten `REMOTE_ADDR`.
- Rollback: `sudo a2disconf cloudflare-remoteip && sudo apache2ctl configtest && sudo systemctl reload apache2`.

## Moodle settings
| Setting | Where | Behind Cloudflare with real-IP |
|---|---|---|
| `getremoteaddrconf` | Site administration → Server → HTTP → "Logged IP address source" | **3** (REMOTE_ADDR only). 0 trusts `HTTP_CLIENT_IP` and `X-Forwarded-For` from any client; 1 and 2 trust one of them |
| `reverseproxyignore` | same page | not needed with 3 |
| `$CFG->reverseproxy` | `config.php` | **do not set**: it is for a proxy that changes the host name or port the site is reached by |
| `$CFG->sslproxy` | `config.php` | **do not set** with Full/Full (strict): the origin speaks HTTPS itself. Only Flexible mode would need it, and Flexible is not acceptable |

Read and set with the CLI as the web user (`<MOODLE>/admin/cli/cfg.php` on 4.x and 5.x alike):
```bash
sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=getremoteaddrconf          # read
sudo -u <WEBUSER> <PHP> <MOODLE>/admin/cli/cfg.php --name=getremoteaddrconf --set=3  # set
```
A value forced in `config.php` (`$CFG->getremoteaddrconf = ...;`) wins over the database; change it there (backup
first) or remove it.

## Verifying
- `bash scripts/realip-check.sh` (counts only; no addresses printed). Lines older than the reload still show edges:
  wait a few minutes or raise `--lines` after traffic.
- The owner can see his own address in Moodle: Preferences → Browser sessions (the "Last IP" column).

## Keeping the ranges current
Cloudflare changes its list rarely but does change it. A new edge range missing from the file means requests from
that edge are logged and limited by the edge address again; with the origin lock on, they are refused. Monthly:
```bash
bash scripts/cf-ranges.sh --compare /etc/nginx/conf.d/cloudflare-realip.conf    # exit 1 = different
```
On DIFFERENT: regenerate with `--out` (add `--geo` if the lock is on), diff against the live file, install with the
change protocol, log it. Put the monthly check in the handbook's to-do list (the `hygiene` module may automate it).
