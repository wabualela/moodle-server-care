#!/bin/bash
# cf-discover.sh - read-only discovery for the cloudflare module: is the Moodle site behind Cloudflare, and are
# the origin-side pieces right (real client IP, Moodle IP source, upload limits, origin certificate, renewal setup,
# Cloudflare features that break Moodle)?
#
# Changes nothing. Makes a few read-only HTTPS GET requests to the public site and to the origin (127.0.0.1 with
# the site's SNI), reads the web server and certbot configuration (sudo -n when available) and runs Moodle's
# admin/cli/cfg.php read-only as the web user. Prints no secrets: from config.php it shows only the non-secret
# keys wwwroot, reverseproxy, sslproxy, getremoteaddrconf, maxbytes.
#
# Usage: cf-discover.sh            (values from ~/.config/moodle-server-care/server.env; env vars override)
# Environment overrides: SITE WWWROOT MOODLE PHP WEBUSER VHOST ORIGIN_IP NGINX_BIN APACHE_ETC LE_DIR
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win
[ -n "${SITE:-}" ] || { echo "SITE unknown: run skills/start/scripts/detect-env.sh first or export SITE=..." >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
NGINX_BIN="${NGINX_BIN:-$(command -v nginx || echo /usr/sbin/nginx)}"
APACHE_ETC="${APACHE_ETC:-/etc/apache2}"; LE_DIR="${LE_DIR:-/etc/letsencrypt}"
PHP="${PHP:-php}"; WEBUSER="${WEBUSER:-www-data}"; WWWROOT="${WWWROOT:-https://$SITE}"
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
say() { printf '%-26s %s\n' "$1" "$2"; }
run_as_web() {
  if [ "$(id -u)" = 0 ]; then runuser -u "$WEBUSER" -- "$@"
  elif [ -n "$SUDO" ]; then sudo -n -u "$WEBUSER" -- "$@"
  elif [ "$(id -un)" = "$WEBUSER" ]; then "$@"
  else return 1; fi
}

echo "== cloudflare module: discovery (read-only) $(date '+%F %T %Z') =="
say "site / wwwroot" "$SITE / $WWWROOT"
SUBPATH=$(printf '%s' "$WWWROOT" | sed -E 's#^https?://[^/]+##')
[ -n "$SUBPATH" ] && say "sub-path" "$SUBPATH  (prefix every Cloudflare rule path and nginx location with it)"

# --- public side -----------------------------------------------------------------------------------------------
H=$(curl -s -o "$WORK/login.html" -D - --max-time 15 "$WWWROOT/login/index.php" 2>/dev/null | tr -d '\r')
CODE=$(printf '%s\n' "$H" | awk 'NR==1{print $2}')
CF=no; printf '%s\n' "$H" | grep -qiE '^server: cloudflare|^cf-ray:' && CF=yes
say "public login page" "HTTP ${CODE:-?}; behind Cloudflare: $CF"
if [ "$CF" = yes ]; then
  say "edge seen from server" "$(printf '%s\n' "$H" | sed -nE 's/^cf-ray: .*-([A-Z]{3})$/\1/Ip')  (the server's nearest edge, not the students')"
  say "login cf-cache-status" "$(printf '%s\n' "$H" | sed -nE 's/^cf-cache-status: *(.*)/\1/Ip')  (expect DYNAMIC)"
  say "HTTP/3 advertised" "$(printf '%s\n' "$H" | grep -qi '^alt-svc:.*h3' && echo yes || echo no)"
  T=$(curl -s --max-time 10 "https://$SITE/cdn-cgi/trace" 2>/dev/null | grep -E '^(http|tls|colo|sni)=' | tr '\n' ' ')
  say "edge trace" "${T:-?}"
  grep -q 'rocket-loader' "$WORK/login.html" 2>/dev/null && say "ROCKET LOADER" "ON - breaks Moodle's RequireJS/AMD: owner turns it off (Speed > Optimization)"
  grep -qE '__cf_email__|email-decode\.min\.js' "$WORK/login.html" 2>/dev/null && say "EMAIL OBFUSCATION" "ON - rewrites Moodle HTML: owner turns it off (Scrape Shield)"
  printf '%s\n' "$H" | grep -qi '^cf-mitigated:' && say "CHALLENGE" "the login page was challenged (Bot Fight / Under Attack): mobile app and monitors will fail"
  HTTPCODE=$(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' --max-time 10 "http://$SITE/" 2>/dev/null)
  say "http:// redirect" "${HTTPCODE:-?}"
fi
A=$( { getent ahostsv4 "$SITE"; getent ahostsv6 "$SITE"; } 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | sort -u | tr '\n' ' ')
say "DNS answers for site" "${A:-none}$( [ -n "${ORIGIN_IP:-}" ] && [[ " $A " == *" $ORIGIN_IP "* ]] && echo '  <- the ORIGIN IP: record is DNS-only (grey) or bypassed')"

# --- web server: real IP and origin lock -------------------------------------------------------------------------
if [ -x "$NGINX_BIN" ]; then
  $SUDO "$NGINX_BIN" -T > "$WORK/nginx-T" 2>/dev/null || true
  if [ -s "$WORK/nginx-T" ]; then
    say "nginx" "$("$NGINX_BIN" -v 2>&1 | sed 's#.*/##'); realip module: $("$NGINX_BIN" -V 2>&1 | grep -q http_realip_module && echo yes || echo NO)"
    N=$(grep -cE '^[[:space:]]*set_real_ip_from[[:space:]]' "$WORK/nginx-T")
    RH=$(sed -nE 's/^[[:space:]]*real_ip_header[[:space:]]+([^;]+);.*/\1/p' "$WORK/nginx-T" | sort -u | tr '\n' ' ')
    FILES=$(awk '/^# configuration file /{f=$4} /^[[:space:]]*set_real_ip_from/{print f}' "$WORK/nginx-T" | sed 's/:$//' | sort -u | tr '\n' ' ')
    say "nginx real-IP" "set_real_ip_from lines: $N; real_ip_header: ${RH:-none}; files: ${FILES:-none}"
    # every value must be ONE address or CIDR (a glued "a.b.c.d/22" + "2400:..." line fails nginx -t)
    GLUED=$(sed -nE 's/^[[:space:]]*set_real_ip_from[[:space:]]+([^;[:space:]]+).*/\1/p' "$WORK/nginx-T" \
      | grep -vE '^(([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?|[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?|unix:)$' | head -n 3 | tr '\n' ' ')
    [ -n "$GLUED" ] && say "GLUED RANGES" "$GLUED  (two ranges on one line: regenerate with cf-ranges.sh)"
    [ -f /etc/nginx/conf.d/cloudflare-realip.conf ] && \
      say "ranges drift check" "bash $HERE/cf-ranges.sh --compare /etc/nginx/conf.d/cloudflare-realip.conf"
    LOCK=$(grep -nE 'from_cloudflare|realip_remote_addr' "$WORK/nginx-T" | grep -v '^[[:space:]]*#' | wc -l)
    say "origin lock" "$( [ "$LOCK" -gt 0 ] && echo "references found ($LOCK lines): check it uses \$realip_remote_addr" || echo 'none (expected until the lock step)')"
    TO=$(grep -hoE '(fastcgi|proxy)_read_timeout[[:space:]]+[0-9]+' "$WORK/nginx-T" | awk '{print $2}' | sort -n | tail -n 1)
    [ -n "$TO" ] && [ "$TO" -gt 100 ] && say "long timeouts" "read timeout up to ${TO}s; Cloudflare cuts proxied requests at 100 s (524) on non-Enterprise plans"
  else
    say "nginx" "cannot run nginx -T (needs root): real-IP state unknown"
  fi
fi
if [ -d "$APACHE_ETC" ]; then
  say "apache remoteip" "$(grep -RhsiE '^[[:space:]]*RemoteIP(Header|TrustedProxy)' "$APACHE_ETC" | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')$( [ -e "$APACHE_ETC/mods-enabled/remoteip.load" ] && echo ' (module enabled)' || echo ' (mod_remoteip NOT enabled)')"
fi

# --- Moodle ----------------------------------------------------------------------------------------------------
if [ -n "${MOODLE:-}" ] && [ -f "$MOODLE/admin/cli/cfg.php" ]; then
  # keep only the four non-secret keys: $CFG->dbpass and the rest of config.php never reach a temp file
  { cat "$MOODLE/config.php" 2>/dev/null || $SUDO cat "$MOODLE/config.php" 2>/dev/null; } \
    | grep -E '^[[:space:]]*\$CFG->(reverseproxy|sslproxy|getremoteaddrconf|maxbytes)[[:space:]]*=' > "$WORK/config.php" || true
  for k in reverseproxy sslproxy getremoteaddrconf maxbytes; do
    v=$(grep -E "^[[:space:]]*\\\$CFG->$k[[:space:]]*=" "$WORK/config.php" | head -n 1 | sed -E 's/^[[:space:]]*//')
    case "$k" in
      sslproxy) note="  (only right when the web server sees plain HTTP, i.e. TLS ends before it; with Full (strict) review it)" ;;
      reverseproxy) note="  (for proxies that change the host name/port; not needed for Cloudflare)" ;;
      *) note="" ;;
    esac
    [ -n "$v" ] && say "config.php forces" "$v$note"
  done
  rm -f "$WORK/config.php"
  G=$(run_as_web "$PHP" "$MOODLE/admin/cli/cfg.php" --name=getremoteaddrconf 2>/dev/null | tr -d '[:space:]')
  case "$G" in
    3) GN="3 = REMOTE_ADDR only (right once the web server sets the real IP)" ;;
    0) GN="0 = trusts client-sent X-Forwarded-For and Client-IP headers (spoofable): set 3 after real-IP" ;;
    1|2) GN="$G = trusts one client-sent header (spoofable): set 3 after real-IP" ;;
    *) GN="${G:-?} (could not run cfg.php as $WEBUSER)" ;;
  esac
  say "Moodle getremoteaddrconf" "$GN"
fi

# --- upload limits ---------------------------------------------------------------------------------------------
echo "-- upload limits --"
CLOUDFLARE="$CF" bash "$HERE/upload-limits.sh" --brief 2>/dev/null | sed 's/^/  /'

# --- origin certificate and renewal ----------------------------------------------------------------------------
echo "-- origin TLS (Full (strict) needs a valid, unexpired certificate for every proxied name) --"
V=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$SITE:443:127.0.0.1" "https://$SITE/login/index.php" 2>/dev/null); RC=$?
if [ "$RC" = 0 ]; then say "origin cert for site" "valid chain and name (HTTP $V via 127.0.0.1)"
else say "origin cert for site" "NOT valid for $SITE (curl rc $RC: 60 = untrusted/expired chain, 51 = name mismatch, 35 = handshake refused)"; fi
if command -v openssl >/dev/null 2>&1; then
  C=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$SITE" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ')
  say "origin cert details" "${C:-?}"
fi
if [ -d "$LE_DIR/renewal" ] || $SUDO test -d "$LE_DIR/renewal" 2>/dev/null; then
  for f in $($SUDO ls "$LE_DIR/renewal" 2>/dev/null | grep '\.conf$'); do
    c=$($SUDO cat "$LE_DIR/renewal/$f" 2>/dev/null | grep -E '^[[:space:]]*(authenticator|installer|pre_hook|post_hook|renew_hook|deploy_hook)[[:space:]]*=' \
        | sed -E 's/[[:space:]]*=[[:space:]]*/=/; s/^[[:space:]]*//' | sed -E 's/^(pre_hook|post_hook|renew_hook|deploy_hook)=.*/\1=(set)/' | tr '\n' ' ')
    say "certbot ${f%.conf}" "${c:-?}"
  done
  HK=$($SUDO find "$LE_DIR/renewal-hooks" -type f 2>/dev/null | tr '\n' ' ')
  say "certbot renewal-hooks" "${HK:-none}  (pre/post hooks DO run during --dry-run)"
else
  say "certbot" "no $LE_DIR/renewal (other ACME client, Cloudflare Origin CA, or not readable)"
fi
echo "== done. Next: origin-exposure.sh (names that reveal the IP), then the proposal in SKILL.md section 4 =="
