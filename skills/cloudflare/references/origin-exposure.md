# Origin exposure, the wildcard trap and the origin lock

## Contents
1. How the origin IP leaks
2. The wildcard DNS trap
3. Origin lock in nginx (geo on the TCP peer)
4. Testing the lock
5. Rollback order
6. Apache
7. Alternatives: Authenticated Origin Pulls, Cloudflare Tunnel, firewall

## 1. How the origin IP leaks
- **DNS-only records** (grey cloud) for any name on the same IP: other sites on the box, `mail.`, `ftp.`, `cpanel.`,
  `direct.`, staging names. `scripts/origin-exposure.sh` lists names from the web server config plus apex and www
  of each zone (`--common` adds typical leak names; `--names-file` takes a zone export).
- **MX on the same server**: mail records cannot be proxied, so a server that also receives mail publishes its IP.
- **DNS history**: if the IP was ever published (before Cloudflare), assume scanners know it. Only a new IP that is
  never published outside Cloudflare is truly hidden.
- **Outgoing mail headers**: mail sent directly from the server carries its IP in `Received:` headers. A relay
  (smarthost) usually records the originating IP too.
- **The site itself**: absolute URLs or links containing the IP, an old `$CFG->wwwroot` with the IP, error pages.
- **Direct-IP answers**: without a default server that refuses unknown names, `https://<ORIGIN_IP>/` shows a site
  and its certificate names (handled by the nginx module's default server).

Why it matters for Moodle even when only *other* names are exposed: scanners and floods aimed at those names share
the same nginx, accept queue and PHP-FPM capacity: a scanner hitting a neighbouring site on the same IP can overflow
the shared port-443 accept queue and slow the Moodle site with it.

## 2. The wildcard DNS trap
A `*` record makes every label resolve. Consequences:
- Retired, misspelt or invented names reach the origin. Without an nginx `default_server`, nginx answers them with
  the **first** vhost (alphabetical file order), i.e. some unrelated application, with its certificate.
- It hides missing records: a name the mail provider requires (bounce/return-path CNAME, DKIM) "resolves" via the
  wildcard to the wrong target, so mail authentication or bounce handling fails without an obvious DNS error. On the
  first server the mail provider's bounce CNAME was lost in the DNS import and the wildcard masked it.
- A DNS-only wildcard exposes the origin for every name.

Fix in this order:
1. nginx module, step "default server": unknown Host → 444, unknown SNI → handshake rejected; before/after probes of
   every vhost.
2. List every name that must exist (`origin-exposure.sh`, the web server's `server_name`s, the mail provider's
   required records, any SaaS verification records) and confirm each has its own record.
3. Export the zone (DNS → Records → Export) as the rollback, then the owner deletes `*`.
4. `origin-exposure.sh` → "no wildcard"; the mail module checks SPF/DKIM/DMARC/bounce records.

## 3. Origin lock in nginx (geo on the TCP peer)
When: after steps 1-5 of SKILL.md pass, with the owner's go-ahead (a mistake locks out every visitor). Mandatory
when the server moves to a new IP: lock before publishing the new IP behind Cloudflare.

Why `geo $realip_remote_addr` and not `allow/deny`: once `real_ip_header` runs, nginx's access module checks the
**visitor's** address, so `allow <Cloudflare ranges>; deny all;` refuses every real user. `$realip_remote_addr`
keeps the TCP peer (the edge). Tested on the first server's scratch nginx: through the "edge" → 200; direct from
another address → connection closed.

1. **Backup:** `sudo cp -a /etc/nginx/conf.d/cloudflare-realip.conf /etc/nginx/conf.d/cloudflare-realip.conf.bak-$(date +%F)`
   and the vhost the same way, resolved first (`V=$(readlink -f <VHOST>)`, normally in `sites-available/`; if the
   real file lives in `sites-enabled/`, copy it to `/root/cloudflare-<date>/` instead). The core-rules name `<file>.bak-YYYY-MM-DD` is safe in
   `conf.d/` because `*.conf` does not match it; a backup named `*.bak.conf` would be loaded and duplicate every
   directive. Never put a backup in `sites-enabled/`: Debian includes everything there.
2. **Change:** regenerate the realip file with the geo block (same ranges, one source of truth):
   ```bash
   T=$(mktemp -d)        # private scratch dir: a fixed /tmp name could be pre-created by another account
   bash scripts/cf-ranges.sh --geo --origin-ip <ORIGIN_IP> --out "$T/cloudflare-realip.conf"
   diff /etc/nginx/conf.d/cloudflare-realip.conf "$T/cloudflare-realip.conf"     # only the geo block is new
   sudo install -m 644 "$T/cloudflare-realip.conf" /etc/nginx/conf.d/cloudflare-realip.conf; rm -rf -- "$T"
   ```
   Then in the Moodle **443** server block only, near the top (see `assets/origin-lock.conf.snippet`):
   ```nginx
   if ($from_cloudflare = 0) { return 444; }   # origin lock: Moodle only through Cloudflare (and this server)
   ```
   Leave the port-80 server open (redirects, HTTP-01 challenges). Other vhosts are untouched.
   If the server's own monitoring reaches the site through another address (a private VPC address, IPv6), add it to
   the geo block by re-running with the right `--origin-ip` or a hand-reviewed extra line.
3. **Test:** `sudo nginx -t`. **Apply:** `sudo systemctl reload nginx`.
4. **Verify:** section 4.

## 4. Testing the lock
- Through Cloudflare (from the server): `curl -s -o /dev/null -w '%{http_code}\n' https://<SITE>/login/index.php` → 200.
- From the server to itself: `curl -s -o /dev/null -w '%{http_code}\n' --resolve <SITE>:443:127.0.0.1 https://<SITE>/` → 200.
- From **outside** (the owner's laptop; give the command in Arabic):
  `curl -s -o /dev/null -w '%{http_code}\n' --resolve <SITE>:443:<ORIGIN_IP> https://<SITE>/login/index.php -k`
  → `000` (connection closed). Before the lock it prints 200.
- `realip-check.sh` still PASS; error log quiet; no 444 for normal traffic: `sudo awk '$9 == 444' <access log> | wc -l`
  should only count probes.

## 5. Rollback order
- Undo the lock: delete the `if ($from_cloudflare = 0)` line, `nginx -t`, reload. The geo block may stay (unused).
- **Stopping Cloudflare** (grey-clouding the records) with the lock on would refuse every visitor once traffic comes
  directly. Always remove the lock **first**, reload, verify, and only then change DNS.
- A missing new Cloudflare range means visitors on that edge get closed connections: keep the monthly
  `cf-ranges.sh --compare`; on DIFFERENT, regenerate with `--geo` the same day.

## 6. Apache
mod_remoteip rewrites the client address, so `Require ip <ranges>` tests the visitor, not the edge (the same trap
as nginx `allow/deny`). Apache's expression parser exposes the TCP peer as `CONN_REMOTE_ADDR`, so a lock can be
written as `Require expr "%{CONN_REMOTE_ADDR} -ipmatch '173.245.48.0/20' || %{CONN_REMOTE_ADDR} -ipmatch '...'"`
(one `-ipmatch` per range, plus 127.0.0.1 and the server's IP) inside the Moodle `<VirtualHost *:443>`. This was
not exercised on the first server (nginx): test it on a scratch configuration and from outside before relying on
it, or prefer Authenticated Origin Pulls (below).

## 7. Alternatives
- **Authenticated Origin Pulls (mTLS):** Cloudflare presents a client certificate to the origin; nginx checks it
  with `ssl_client_certificate <Cloudflare origin-pull CA>; ssl_verify_client on;` in the Moodle server block. The
  zone-wide setting uses a certificate shared by all Cloudflare customers (it proves "came through Cloudflare", not
  "through our account"); per-hostname certificates are stronger. Owner enables it in SSL/TLS → Origin Server.
- **Cloudflare Tunnel (cloudflared):** the origin opens an outbound connection to Cloudflare and needs no inbound
  80/443 at all. Strongest hiding, but a new daemon and a different operating model: a project, not a step.
- **Firewall (ufw/nftables) allowing 80/443 only from Cloudflare ranges:** only when **every** site on the server is
  proxied; otherwise it cuts off the others. Keep SSH rules untouched, test from outside, and keep the ranges current
  in the firewall too.
