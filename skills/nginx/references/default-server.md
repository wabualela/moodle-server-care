# Default server: refuse unknown Host and SNI

## How nginx picks a server block
For each `address:port`, nginx compares the request's Host header (HTTP) or TLS SNI (HTTPS) with every
`server_name`. When nothing matches, it uses the block marked `default_server` for that address:port; when none is
marked, it uses the **first** block that listens there, in configuration order (Debian: `conf.d/*.conf` first, then
`sites-enabled/*` alphabetically). That accidental default then answers:
- the bare IP (scanners sweep IP ranges; no SNI, `Host: <ip>`),
- every name a wildcard DNS record makes resolvable,
- retired names whose DNS still points here,
- typos and invented names, with the default site's certificate (which also reveals the names it covers).

## The fix
`assets/00-default-server.conf` in `conf.d/` (the `00-` prefix makes it first; harmless and easy to spot):
- port 80: `return 444;` closes the connection without an answer; `access_log /var/log/nginx/default-reject.log`
  records who probes (the nginx logrotate glob covers it);
- port 443: `ssl_reject_handshake on;` (nginx ≥ 1.19.4) aborts the handshake for unknown SNI, so no certificate is
  needed and none is revealed. Requests never reach the HTTP layer there, so no access log.
- older nginx: `assets/00-default-server-legacy.conf` completes the handshake with the local self-signed snakeoil
  certificate and returns 444 (clients see an untrusted certificate, then a closed connection).

## Before installing
1. `nginx-discover.sh` → "default_server: NONE" and which block answers today per port.
2. `vhost-probe.sh --show-cert --out "$W/vhost-before.txt"` (`$W` = the module's private working folder, SKILL §3). In the "unknown names" section, a 200 shows which site
   is the accidental default. With `--show-cert`, the `cert=` column shows whose certificate is served.
3. List DNS names that point here but have **no** `server_name` (they worked only via the catch-all): compare
   `origin-exposure.sh` (cloudflare module) or the DNS zone with the `server_name` list, and `sudo certbot certificates`
   for certificate names with no vhost. For each, the owner decides: give it a server block (e.g. a redirect to the
   main site with its own certificate), or retire it (delete DNS record and certificate). Behind Cloudflare such a
   name returns 525 after the change.
4. IPv6: keep the `[::]:80` and `[::]:443` lines only when other servers listen on IPv6. nginx allows listen
   *options* (`ipv6only`, `backlog`, `reuseport`, `default_server`) once per address:port; an existing
   `listen [::]:443 ssl ipv6only=on;` elsewhere is compatible with `default_server` here (validated on the first
   server), but `nginx -t` is the judge. `nginx -t` does not bind sockets: a host without an IPv6 stack fails at
   reload (nginx keeps the old configuration and logs the error), so check `ip -6 addr` first.
5. Existing `default_server` somewhere else: never add a second one (nginx -t fails "duplicate default server").
   Read it; if it already refuses unknown names, skip; if it is a real site, move the flag to the new file in the
   same change.

## After installing
- `vhost-probe.sh --out "$W/vhost-after.txt"` and `--compare`: configured names identical; unknown names and bare
  IP now `https=000(rc35)` and `http=000(rc52)`.
- Public check through DNS (and Cloudflare, if used): main site 200, login 200.
- `sudo tail /var/log/nginx/default-reject.log` after a few hours: scanners and unknown names, as expected.

## Interactions
- **certbot (nginx authenticator):** a certificate for a name with its own server block renews as before. A
  certificate for a name without a server block relied on the catch-all; test with
  `sudo certbot renew --dry-run --cert-name <name>` or retire it. On the first server a dead name's certificate
  was deleted instead.
- **Cloudflare:** unknown proxied names give 525 (handshake refused at the origin); this also reveals that the zone
  is in Full mode (Cloudflare connects with HTTPS).
- **Health checks / monitors** that call the server by IP must switch to a real name (`--resolve name:443:127.0.0.1`).
- **HTTP/2:** in nginx < 1.25.1, `http2` on any `listen ... 443` applies to the whole address:port; the default
  server inherits it. Harmless.

## Rollback
`sudo rm /etc/nginx/conf.d/00-default-server.conf && sudo nginx -t && sudo systemctl reload nginx`.
