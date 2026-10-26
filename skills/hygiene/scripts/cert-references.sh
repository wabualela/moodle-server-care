#!/bin/bash
# cert-references.sh — read-only: list every Let's Encrypt (certbot) certificate with its expiry, its domains,
# whether ENABLED web server config references it, whether a DISABLED config file references it, where DNS points,
# and how often its renewal failed. Prints a verdict per certificate. Changes nothing; certbot itself is not run.
#
# Usage: bash cert-references.sh [--no-dns] [--le-dir /etc/letsencrypt]
# Why: an expired certificate that an ENABLED vhost still references must not be deleted first (nginx -t then fails
# and the next reload or restart breaks every site); dead, unreferenced certificates make certbot.service fail on
# every run and hide the real renewal of the live site.
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

LE_DIR="$MSC_LE_DIR"; DNS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-dns) DNS=0 ;;
    --le-dir) LE_DIR="$2"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac; shift
done

if ! $SUDO test -d "$LE_DIR/renewal"; then
  echo "no $LE_DIR/renewal: certbot certificates are not used here (other ACME client or provider certificates)."
  echo "Check the web server config for ssl_certificate / SSLCertificateFile paths instead."
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
msc_webconf_dump > "$TMP/enabled.txt"
: > "$TMP/disabled.txt"
while read -r f; do [ -n "$f" ] && { printf '# configuration file %s:\n' "$f"; $SUDO cat "$f" 2>/dev/null; } >> "$TMP/disabled.txt"; done < <(msc_webconf_disabled)
LOCAL_IPS=$(msc_local_ips | tr '\n' ' ')
NOW=$(date +%s)
# certbot starts a new letsencrypt.log on every run (older runs: letsencrypt.log.1 ... .N), so read them all once
LEDIR_LOG="${MSC_LE_LOG_DIR:-/var/log/letsencrypt}"
$SUDO sh -c 'grep -h "Failed to renew certificate" "$1"/letsencrypt.log* 2>/dev/null' _ "$LEDIR_LOG" > "$TMP/lefails.txt" || true

# file names in a config dump that contain a pattern
files_with() { awk -v pat="$2" '/^# configuration file /{f=$4; sub(/:$/,"",f)} index($0,pat){print f}' "$1" | sort -u | tr '\n' ' '; }

printf '%-34s %-11s %-6s %-6s %-24s %s\n' CERT EXPIRES DAYS FAILS DNS VERDICT
# FAILS = failed renewal attempts found in the kept certbot logs (one log per run)
for conf in $($SUDO ls "$LE_DIR"/renewal/ 2>/dev/null | grep '\.conf$'); do
  name=${conf%.conf}
  pem="$LE_DIR/live/$name/cert.pem"
  end=""; days="?"; domains=""
  if $SUDO test -r "$pem"; then
    end=$($SUDO openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] && days=$(( ( $(date -d "$end" +%s) - NOW ) / 86400 ))
    domains=$($SUDO openssl x509 -in "$pem" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | sed 's/DNS://' | tr '\n' ' ')
  fi
  [ -z "$domains" ] && domains="$name"
  enabled=$(files_with "$TMP/enabled.txt" "/live/$name/")
  disabled=$(files_with "$TMP/disabled.txt" "/live/$name/")
  fails=$(grep -cF "Failed to renew certificate $name with error" "$TMP/lefails.txt")
  dns="-"
  if [ "$DNS" -eq 1 ]; then
    first=${domains%% *}
    ips=$(getent ahosts "$first" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -z "$ips" ]; then dns="NXDOMAIN"
    else
      here=no; for ip in $ips; do case " $LOCAL_IPS " in *" $ip "*) here=yes ;; esac; done
      if [ "$here" = yes ]; then dns="here"; else dns="elsewhere(${ips%% *})"; fi
    fi
  fi
  if [ "$days" = "?" ]; then verdict="CHECK: certificate file unreadable or missing"
  elif [ "$days" -lt 0 ] && [ -n "$enabled" ]; then verdict="DEAD-BUT-ENABLED: disable or fix the vhost first, then delete"
  elif [ "$days" -lt 0 ]; then verdict="DEAD-UNREFERENCED: candidate for certbot delete (owner OK)"
  elif [ -z "$enabled" ]; then verdict="VALID-UNUSED: ask the owner (retire or add a vhost before it fails to renew)"
  elif [ "$days" -lt 30 ]; then verdict="RENEWS-SOON: confirm with certbot renew --dry-run --cert-name $name"
  else verdict="OK"; fi
  case "$dns" in elsewhere*|NXDOMAIN) verdict="$verdict; DNS not here (proxy/CDN or moved?)";; esac
  printf '%-34s %-11s %-6s %-6s %-24s %s\n' "$name" "$( [ -n "$end" ] && date -d "$end" +%F || echo '?')" \
    "$days" "$fails" "$dns" "$verdict"
  printf '    domains:       %s\n    enabled refs:  %s\n    disabled refs: %s\n' "$domains" "${enabled:--}" "${disabled:--}"
done
echo
echo "Notes: 'here' means DNS resolves to an address of this server. Behind a proxy/CDN (Cloudflare) DNS shows the"
echo "proxy's addresses, so 'elsewhere' alone does not prove a domain moved: ask the owner, check the access log."
echo "DISABLED_REFS are files in sites-available that would fail 'nginx -t' if re-enabled after a delete."
