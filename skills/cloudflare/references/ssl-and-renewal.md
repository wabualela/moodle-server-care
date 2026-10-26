# SSL modes and certificate renewal behind Cloudflare

## The modes (zone setting: SSL/TLS → Overview)
| Mode | Cloudflare → origin | Origin certificate | Use |
|---|---|---|---|
| Off | HTTP | none | never |
| Flexible | **HTTP** (plain text across the internet) | none | never for Moodle: passwords and sessions travel unencrypted to the origin, and Moodle with an https wwwroot loops or needs `sslproxy` |
| Full | HTTPS | any certificate, even expired or self-signed | transitional only |
| Full (strict) | HTTPS | valid: trusted CA (e.g. Let's Encrypt) or Cloudflare Origin CA, not expired, name matches | **target** |
| Strict (SSL-only origin pull) | HTTPS for every request | as strict | Enterprise feature; not needed |

The owner can also set the mode per hostname with Configuration Rules; check them if behaviour differs between names.

## Inferring the current mode from the server side (when the owner is unsure)
- `cf-discover.sh` prints whether the origin certificate is valid for `<SITE>` (curl to 127.0.0.1 with SNI, no `-k`).
- A proxied name for which the origin presents an invalid certificate (wrong name, expired) answers:
  200 through Cloudflare → mode is Full (not strict) or Flexible; 526 → Full (strict).
- A proxied name for which the origin refuses the TLS handshake (nginx default server with `ssl_reject_handshake`)
  answers 525 → Cloudflare connects with HTTPS (Full or Full strict). Flexible would show the port-80 answer instead.
- On the first server: a retired subdomain was served with another site's certificate and returned 200 through
  Cloudflare, so the mode was Full; after the default server refused unknown SNI it returned 525.

## Strict readiness checklist
For **every** proxied hostname that reaches this origin (apex, www, others):
```bash
for h in <SITE> www.<domain>; do
  printf '%-30s ' "$h"; curl -s -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' --max-time 10 \
    --resolve "$h:443:127.0.0.1" "https://$h/" || echo "FAILED rc=$?"
done
echo | openssl s_client -connect 127.0.0.1:443 -servername <SITE> 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName
```
Every name: HTTP status (200/30x), `verify=0`, the name in the SAN list, expiry more than 30 days away or renewing.
A name without its own certificate (served by another vhost) must get one, or be removed from DNS, before strict.

## certbot renewal from behind Cloudflare
HTTP-01 challenges travel through Cloudflare like any request. On the first server Cloudflare answered the
challenge URL with a redirect to HTTPS and Let's Encrypt followed it to the origin; the dry run succeeded. Do not
assume it works elsewhere (other Cloudflare rules, other authenticators): test.

Before the dry run:
- `sudo certbot certificates` (names, expiry, paths). `cf-discover.sh` lists each renewal file's authenticator,
  installer and whether hooks are set. **pre_hook and post_hook run during `--dry-run`** (deploy hooks do not):
  read them first; a hook that restarts services or sends mail is a reason to stop and ask.
- Quiet hour: the nginx authenticator edits the configuration temporarily and reloads nginx twice.

Run, per certificate:
```bash
T=$(mktemp -d)
sudo sh -c 'find /etc/nginx -type f -exec md5sum {} + | sort -k2' > "$T/nginx-md5-before.txt"
sudo certbot renew --dry-run --cert-name <SITE>        # staging CA; live certificates are not touched
sudo sh -c 'find /etc/nginx -type f -exec md5sum {} + | sort -k2' > "$T/nginx-md5-after.txt"
diff "$T/nginx-md5-before.txt" "$T/nginx-md5-after.txt" && sudo nginx -t && curl -s -o /dev/null -w '%{http_code}\n' https://<SITE>/
rm -rf -- "$T"
```
Report as "dry run succeeded against the staging CA; the real renewal is confirmed at the next certbot run on
<date>". Check `systemctl list-timers certbot.timer` (or the cron entry) and look at the result after that date.

### If the dry run fails
1. Read `/var/log/letsencrypt/letsencrypt.log` for the challenge URL and the status Let's Encrypt saw.
2. Typical causes: a Cloudflare rule that challenges or blocks `/.well-known/acme-challenge/` (WAF, Bot Fight Mode,
   country block), a redirect to another host, the origin's port-80 server not serving the challenge.
3. Options, least change first:
   - a Cloudflare Configuration Rule or WAF skip for `/.well-known/acme-challenge/*` (owner, dashboard);
   - **Cloudflare Origin CA certificate** (Cloudflare dashboard → SSL/TLS → Origin Server): valid up to 15 years,
     trusted only by Cloudflare, which is enough for Full (strict). Direct visitors to the IP would see an untrusted
     certificate, which is fine once the origin is locked. The owner creates it; the private key is a secret: the
     owner installs it (mode 600) following the no-echo pattern in core-rules §5, Claude prepares the nginx lines;
   - **DNS-01** with the certbot Cloudflare DNS plugin (`python3-certbot-dns-cloudflare`, a package install: ask).
     The owner creates an API token limited to "Zone → DNS → Edit" for that one zone and writes it into
     `/root/.secrets/cloudflare.ini` (600) without echo; Claude never sees it.

## Switching to Full (strict)
Owner, dashboard (Arabic steps in `dashboard-steps-ar.md` §4). Then for 10 minutes:
```bash
for h in <SITE> www.<domain>; do curl -s -o /dev/null -w "$h %{http_code}\n" "https://$h/login/index.php"; done
```
526 means a name failed validation: switch back to Full, fix that name's certificate, retry.

## Apache
Same logic; the certbot authenticator is `apache` or `webroot`. The dry run command is identical. Compare
`/etc/apache2` checksums before and after instead of `/etc/nginx`, and run `apache2ctl configtest`.
