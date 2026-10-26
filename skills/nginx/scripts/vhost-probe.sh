#!/bin/bash
# vhost-probe.sh - probe every site on this web server at the origin, by TLS SNI (443) and Host header (80), plus
# names nobody configured (a fixed unknown label under each domain), the bare IP without SNI and the public IP.
# Run it BEFORE and AFTER a default-server (or any vhost) change and diff the two outputs: only the lines you meant
# to change may differ.
#
# Read-only: GET / to 127.0.0.1 (and the public IP), certificate errors ignored (-k) because we only want to know
# who answers. Names come from `nginx -T` server_name (or `apache2ctl -S`), plus --names-file / --extra.
#
# Usage: vhost-probe.sh [--ip 127.0.0.1] [--public-ip IP] [--names-file FILE] [--extra NAME]... [--show-cert]
#                       [--out FILE] [--compare BEFORE AFTER]
#   --public-ip  also probe http://<public IP>/ with no Host override (default ORIGIN_IP from server.env)
#   --show-cert  add the subject CN of the certificate served for each name (shows which vhost answered)
#   --out        also save the output to FILE (e.g. /tmp/vhost-before.txt)
#   --compare    print only the lines that differ between two saved outputs, then exit
# Output per name: https=<status>(rc<curl exit>) http=<status>(rc<curl exit>)
#   rc0 answered; rc35 TLS handshake refused (ssl_reject_handshake); rc52 empty reply (nginx 444);
#   rc7 connection refused; rc28 timeout; rc60/51 would be certificate problems (not shown because of -k).
set -uo pipefail
set +x

if [ "${1:-}" = "--compare" ]; then
  [ -r "${2:-}" ] && [ -r "${3:-}" ] || { echo "usage: --compare BEFORE AFTER" >&2; exit 2; }
  # (pipefail would turn diff's "differences found" status into a false "no differences": capture instead)
  D=$(diff -u <(grep -v '^#' "$2") <(grep -v '^#' "$3") | grep -E '^[-+][^-+]' || true)
  if [ -n "$D" ]; then printf '%s\n' "$D"; exit 1; fi
  echo "no differences"; exit 0
fi

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
NGINX_BIN="${NGINX_BIN:-$(command -v nginx || echo /usr/sbin/nginx)}"
APACHECTL="${APACHECTL:-$(command -v apache2ctl || command -v apachectl || echo /usr/sbin/apache2ctl)}"
IP=127.0.0.1; PUBIP="${ORIGIN_IP:-}"; NAMES_FILE=""; EXTRA=(); SHOWCERT=0; OUT=""; PROBE_LABEL="msc-unknown-probe"
while [ $# -gt 0 ]; do
  case "$1" in
    --ip) IP="${2:?}"; shift 2 ;;
    --public-ip) PUBIP="${2:?}"; shift 2 ;;
    --names-file) NAMES_FILE="${2:?}"; shift 2 ;;
    --extra) EXTRA+=("${2:?}"); shift 2 ;;
    --show-cert) SHOWCERT=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
{
  if [ -x "$NGINX_BIN" ]; then
    $SUDO "$NGINX_BIN" -T 2>/dev/null | sed -E 's/#.*//' | grep -oE '(^|[;{[:space:]])server_name[[:space:]][^;]*' \
      | sed -E 's/.*server_name[[:space:]]+//' | tr ' \t' '\n\n'
  fi
  if [ -x "$APACHECTL" ]; then
    $SUDO "$APACHECTL" -S 2>/dev/null | sed -nE 's/.*(namevhost|alias)[[:space:]]+([^[:space:]]+).*/\2/p'
  fi
  [ -n "$NAMES_FILE" ] && grep -vE '^[[:space:]]*(#|$)' "$NAMES_FILE"
  printf '%s\n' "${EXTRA[@]}"
} | tr 'A-Z' 'a-z' | sed -E 's/\.$//' | grep -vE '^(|_|localhost|"")$' | grep -vE '^~' | grep -vE '^[0-9.]+$' \
  | grep -E '\.' | sort -u > "$WORK/conf-names"
[ -s "$WORK/conf-names" ] || { echo "no server names found (need root for nginx -T?); pass --names-file or --extra" >&2; exit 2; }

# Real names, then one fixed unknown label per parent domain (stable across runs, so before/after outputs diff cleanly).
: > "$WORK/names"
while IFS= read -r n; do
  case "$n" in
    \*.*) echo "$PROBE_LABEL.${n#\*.}" >> "$WORK/unknown" ;;     # wildcard server_name: probe a label under it
    .*) echo "${n#.}" >> "$WORK/names"; echo "$PROBE_LABEL.${n#.}" >> "$WORK/unknown" ;;
    *) echo "$n" >> "$WORK/names"
       p="${n#*.}"; [[ "$p" == *.* ]] && echo "$PROBE_LABEL.$p" >> "$WORK/unknown"
       echo "$PROBE_LABEL.$n" >> "$WORK/unknown" ;;
  esac
done < "$WORK/conf-names"
sort -u -o "$WORK/names" "$WORK/names"; sort -u "$WORK/unknown" 2>/dev/null | grep -vxFf "$WORK/names" > "$WORK/unknown.s"

probe() {  # NAME -> one line
  local h="$1" s e443 p e80 cn=""
  s=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$h:443:$IP" "https://$h/" 2>/dev/null); e443=$?
  p=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "http://$IP/" 2>/dev/null); e80=$?
  if [ "$SHOWCERT" = 1 ] && [ "$e443" = 0 ]; then
    cn=$(echo | openssl s_client -connect "$IP:443" -servername "$h" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
         | sed -nE 's/.*CN ?= ?([^,/]+).*/ cert=\1/p')
  fi
  printf '%-48s https=%s(rc%s) http=%s(rc%s)%s\n' "$h" "${s:-000}" "$e443" "${p:-000}" "$e80" "$cn"
}

{
  echo "# vhost-probe $(date '+%F %T %Z') at $IP"
  echo "# configured names"
  while IFS= read -r h; do probe "$h"; done < "$WORK/names"
  echo "# unknown names (should be refused once a default server exists)"
  while IFS= read -r h; do probe "$h"; done < "$WORK/unknown.s"
  echo "# bare IP"
  s=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://$IP/" 2>/dev/null); printf '%-48s https=%s(rc%s)\n' "$IP-no-SNI" "${s:-000}" $?
  s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$IP/" 2>/dev/null); printf '%-48s http=%s(rc%s)\n' "$IP-http" "${s:-000}" $?
  if [ -n "$PUBIP" ] && [ "$PUBIP" != "$IP" ]; then
    s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$PUBIP/" 2>/dev/null); printf '%-48s http=%s(rc%s)\n' "public-IP-http" "${s:-000}" $?
    s=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://$PUBIP/" 2>/dev/null); printf '%-48s https=%s(rc%s)\n' "public-IP-no-SNI" "${s:-000}" $?
  fi
} | if [ -n "$OUT" ]; then tee "$OUT"; else cat; fi
