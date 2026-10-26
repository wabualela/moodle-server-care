#!/bin/bash
# nginx-discover.sh - read-only discovery for the nginx hardening module on a Moodle server.
#
# Reports: nginx version and which hardening directives it supports; config layout (conf.d before sites-enabled,
# stray backups in sites-enabled); every server block with its listen/server_name and whether a default_server
# exists; the Moodle vhost's PHP location (path split, existence check, PATH_INFO), scanner block, rate limits,
# X-Accel internal location, favicon, upload limit, log formats; gzip settings; on the Moodle side the release,
# router (r.php), X-Accel settings, shim routes whose .php file is missing, scanner-prefix collisions, and the
# page-builder pluginfile handler.
#
# Changes nothing. Uses sudo -n (when available) for `nginx -T`; without it, concatenates the readable files.
# Prints no secrets: from config.php only xsendfile, xsendfilealiases and routerconfigured lines.
#
# Usage: nginx-discover.sh       (values from ~/.config/moodle-server-care/server.env; env vars override)
# Environment overrides: MOODLE DOCROOT SITE VHOST RELEASE NGINX_BIN NGINX_ETC
set -uo pipefail
set +x

# shellcheck source=lib-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
ENV_FILE=$(msc_env_path)
msc_parse_env "$ENV_FILE" || true      # parsed, never sourced; variables already set in the environment win

SUDO=""; [ "$(id -u)" != 0 ] && sudo -n true 2>/dev/null && SUDO="sudo -n"
NGINX_BIN="${NGINX_BIN:-$(command -v nginx || echo /usr/sbin/nginx)}"
NGINX_ETC="${NGINX_ETC:-/etc/nginx}"
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
say() { printf '%-28s %s\n' "$1" "$2"; }
hdr() { echo ""; echo "-- $* --"; }
vge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }   # vge HAVE NEED

echo "== nginx module: discovery (read-only) $(date '+%F %T %Z') =="
if [ ! -x "$NGINX_BIN" ]; then
  if command -v apache2 >/dev/null 2>&1 || [ -x /usr/sbin/apache2 ]; then
    echo "nginx not found; Apache is installed. This module's nginx steps do not apply: read references/apache.md."
  else
    echo "nginx not found (set NGINX_BIN). Stop and ask the owner which web server serves the site."
  fi
  exit 0
fi

V=$("$NGINX_BIN" -v 2>&1 | sed -nE 's#.*nginx/([0-9.]+).*#\1#p')
MODS=$("$NGINX_BIN" -V 2>&1)
say "nginx" "${V:-?}"
say "ssl_reject_handshake" "$(vge "${V:-0}" 1.19.4 && echo 'supported (>= 1.19.4)' || echo 'NOT supported: use the legacy default server with a self-signed cert')"
say "limit_req_dry_run" "$(vge "${V:-0}" 1.17.1 && echo yes || echo 'NO (>= 1.17.1 needed): no dry run possible, stop and ask')"
say "limit_conn_dry_run" "$(vge "${V:-0}" 1.17.6 && echo yes || echo 'NO (>= 1.17.6 needed)')"
say "http2 syntax" "$(vge "${V:-0}" 1.25.1 && echo '"http2 on;" available (listen ... http2 deprecated)' || echo 'listen ... http2 (pre-1.25.1)')"
M=""; MISS=""
for m in http_realip_module http_v2_module http_gzip_static_module http_stub_status_module http_ssl_module; do
  if printf '%s' "$MODS" | grep -q -- "--with-$m"; then M="$M ${m#http_}"; else MISS="$MISS ${m#http_}"; fi
done
say "built with" "${M:-?}${MISS:+ | missing:$MISS}"

# --- full configuration ---------------------------------------------------------------------------------------
if ! $SUDO "$NGINX_BIN" -T > "$WORK/T" 2>/dev/null || ! grep -q '^# configuration file' "$WORK/T"; then
  echo "(nginx -T not available without root; reading files directly, includes may be incomplete)"
  for f in "$NGINX_ETC/nginx.conf" "$NGINX_ETC"/conf.d/*.conf "$NGINX_ETC"/sites-enabled/*; do
    [ -r "$f" ] && { echo "# configuration file $f:"; cat "$f"; echo; }
  done > "$WORK/T"
fi
nginx_test=$($SUDO "$NGINX_BIN" -t 2>&1 | tail -n 1)
say "nginx -t" "${nginx_test:-? (needs root)}"

hdr "layout"
grep -nE '^[[:space:]]*include[[:space:]]' "$NGINX_ETC/nginx.conf" 2>/dev/null | sed 's/^/  nginx.conf:/'
say "conf.d files" "$(ls "$NGINX_ETC/conf.d/" 2>/dev/null | tr '\n' ' ')"
say "sites-enabled" "$(for f in "$NGINX_ETC"/sites-enabled/*; do [ -e "$f" ] || continue; b=$(basename "$f"); [ -L "$f" ] && printf '%s ' "$b" || printf '%s(REAL FILE) ' "$b"; done)"
STRAY=$(ls "$NGINX_ETC/sites-enabled/" 2>/dev/null | grep -E '\.(bak|orig|old|save|dpkg-[a-z]+)|~$|bak-' | tr '\n' ' ')
[ -n "$STRAY" ] && say "BACKUPS IN sites-enabled" "$STRAY <- Debian includes every file there: these are LIVE config"

hdr "server blocks (file | listen | server_name)"
awk '
  # nginx -T prints every included file separately, so vhost files start again at depth 0.
  /^# configuration file / { file = $4; sub(/:$/, "", file); depth = 0; insrv = 0; next }
  { line = $0; sub(/#.*/, "", line) }
  {
    if (!insrv && line ~ /^[[:space:]]*server[[:space:]]*\{/ && (depth == 0 || stack[depth] == "http")) {
      insrv = 1; L = ""; N = ""; sdepth = depth + 1; F = file
    }
    if (insrv && line ~ /^[[:space:]]*listen[[:space:]]/) { x = line; sub(/^[[:space:]]*listen[[:space:]]+/, "", x); sub(/;.*/, "", x); L = L (L ? ", " : "") x }
    if (insrv && line ~ /^[[:space:]]*server_name[[:space:]]/) { x = line; sub(/^[[:space:]]*server_name[[:space:]]+/, "", x); sub(/;.*/, "", x); N = N x }
    n = split(line, ch, "")
    for (i = 1; i <= n; i++) {
      if (ch[i] == "{") { pre = substr(line, 1, i - 1); gsub(/^.*[;}]/, "", pre); gsub(/^[[:space:]]+/, "", pre); split(pre, w, /[[:space:]]+/); depth++; stack[depth] = w[1] }
      else if (ch[i] == "}") { if (depth > 0) depth--; if (insrv && depth < sdepth) { printf "  %s | %s | %s\n", F, L, N; insrv = 0 } }
    }
  }' "$WORK/T" | tee "$WORK/servers"
DEF=$(grep -c 'default_server' "$WORK/servers")
if [ "$DEF" -gt 0 ]; then say "default_server" "present ($DEF block(s)): $(grep default_server "$WORK/servers" | cut -d'|' -f1 | tr -s ' ' | tr '\n' ' ')"
else say "default_server" "NONE: nginx answers unknown names and the bare IP with the first server block for each port:"
  awk -F'|' '{print $2 "|" $1}' "$WORK/servers" | grep -E '443|:80|[^0-9]80([^0-9]|$)' | head -n 4 | sed 's/^/    /'
fi
IPV6ONLY=$(grep -nE 'listen[[:space:]]+\[::\][^;]*ipv6only' "$WORK/T" | head -n 3)
[ -n "$IPV6ONLY" ] && say "ipv6only options" "present (options may appear on ONE server per address:port; copy-check before adding [::] listens): $(echo "$IPV6ONLY" | tr '\n' ' ')"

# --- Moodle vhost ----------------------------------------------------------------------------------------------
if [ -z "${VHOST:-}" ] && [ -n "${SITE:-}" ]; then
  VHOST=$(grep -RlE "server_name[^;]*[[:space:]]${SITE}([[:space:];]|$)" "$NGINX_ETC"/sites-enabled/ "$NGINX_ETC"/conf.d/ 2>/dev/null | head -n 1)
fi
hdr "Moodle vhost ${VHOST:-?}"
if [ -n "${VHOST:-}" ] && { [ -r "$VHOST" ] || $SUDO test -r "$VHOST"; }; then
  { cat "$VHOST" 2>/dev/null || $SUDO cat "$VHOST"; } > "$WORK/vhost"
  if [ -L "$VHOST" ]; then say "file" "$VHOST -> $(readlink -f "$VHOST") (edit the target; back it up in sites-available)"
  else case "$VHOST" in */sites-enabled/*) say "file" "$VHOST is a regular file in sites-enabled: back it up to /root/nginx-<date>/, never next to it (nginx loads every file there)";; esac; fi
  say "root" "$(sed -nE 's/^[[:space:]]*root[[:space:]]+([^;]+);.*/\1/p' "$WORK/vhost" | tr '\n' ' ')  (DOCROOT from env: ${DOCROOT:-?})"
  say "location / try_files" "$(awk '/location[[:space:]]+\/[[:space:]]*\{/{f=1} f && /try_files/{sub(/^[[:space:]]*/,""); print; exit}' "$WORK/vhost")"
  awk '/location[[:space:]]+~[^{]*\\\.php/ && !f { f = 1; d = 0 }
       f { print "    " $0; o = gsub(/\{/, "{"); c = gsub(/\}/, "}"); d += o - c; if (d <= 0 && o + c > 0) exit }' "$WORK/vhost" > "$WORK/phploc"
  if [ -s "$WORK/phploc" ]; then
    echo "  PHP location as configured:"; cat "$WORK/phploc"
    SPLIT=$(sed -nE 's/.*fastcgi_split_path_info[[:space:]]+([^;]+);.*/\1/p' "$WORK/phploc")
    grep -q 'snippets/fastcgi-php.conf' "$WORK/phploc" && SNIP=yes || SNIP=no
    case "$SPLIT" in
      *'.+?\.php'*) S="non-greedy (good)" ;;
      *'.+\.php'*) S="GREEDY: change to ^(.+?\\.php)(/.*)\$ together with the existence check" ;;
      '') S="$( [ "$SNIP" = yes ] && echo 'from snippets/fastcgi-php.conf (Debian, non-greedy)' || echo 'none' )" ;;
      *) S="custom: $SPLIT" ;;
    esac
    say "path split" "$S"
    grep -qE 'try_files[[:space:]]+\$fastcgi_script_name[[:space:]]+=404' "$WORK/phploc" || [ "$SNIP" = yes ] \
      && say "existence check" "present" || say "existence check" "MISSING: unknown .php URLs reach PHP-FPM ('Primary script unknown')"
    PI=$(sed -nE 's/.*fastcgi_param[[:space:]]+PATH_INFO[[:space:]]+([^;]+);.*/\1/p' "$WORK/phploc")
    say "PATH_INFO from" "${PI:-$( [ "$SNIP" = yes ] && echo '$path_info (snippet)' || echo 'NOT SET: slash arguments may break')}"
    if grep -qE 'try_files[[:space:]]+\$fastcgi_script_name' "$WORK/phploc" && [ "$PI" = '$fastcgi_path_info' ]; then
      say "DANGER" "try_files resets \$fastcgi_path_info: PATH_INFO is EMPTY (no CSS/JS/images). Use set \$path_info."
    fi
    say "fastcgi_pass" "$(sed -nE 's/.*fastcgi_pass[[:space:]]+([^;]+);.*/\1/p' "$WORK/phploc")"
    say "limit_req/limit_conn" "$(grep -cE '^[[:space:]]*limit_(req|conn)[[:space:]]' "$WORK/phploc") active line(s); dry run: $(grep -E '^[[:space:]]*limit_req_dry_run[[:space:]]+on' "$WORK/phploc" >/dev/null && echo on || echo off)"
  else
    say "PHP location" "not found by pattern 'location ~ ...\\.php' (read the vhost by hand)"
  fi
  grep -qE 'location[[:space:]]+~\*?[[:space:]]+\^/\((wp-admin|.*swagger)' "$WORK/vhost" && say "scanner block" "present" || say "scanner block" "absent"
  awk '/location[^{]*\{/{L=$0} /internal;/{print "  internal location: " L}' "$WORK/vhost"
  say "favicon location" "$(grep -qE 'location[[:space:]]+=[[:space:]]*/favicon\.ico' "$WORK/vhost" && echo present || echo absent)"
  say "client_max_body_size" "$(sed -nE 's/^[[:space:]]*client_max_body_size[[:space:]]+([^;]+);.*/\1/p' "$WORK/vhost" | tr '\n' ' ')"
  say "server-level if" "$(grep -E '^[[:space:]]*if[[:space:]]*\(' "$WORK/vhost" | sed -E 's/^[[:space:]]+//' | tr '\n' ' ')"
  AL=$(sed -nE 's/^[[:space:]]*access_log[[:space:]]+([^;]+);.*/\1/p' "$WORK/vhost"); say "access_log" "$(echo "$AL" | tr '\n' ';')"
  say "error_log" "$(sed -nE 's/^[[:space:]]*error_log[[:space:]]+([^;]+);.*/\1/p' "$WORK/vhost" | tr '\n' ' ')"
  for fmt in $(echo "$AL" | awk '{print $2}' | sort -u); do
    grep -A6 -E "log_format[[:space:]]+$fmt[[:space:]]" "$WORK/T" | grep -q 'upstream_response_time' \
      && say "log format $fmt" "has \$upstream_response_time (rl-replay mode=urt works)" \
      || say "log format $fmt" "no upstream time (use rl-replay mode=php)"
  done
else
  say "vhost" "not found or not readable (set VHOST=...)"
fi

hdr "http level"
RZ=$(sed -nE 's/^[[:space:]]*limit_req_zone[[:space:]].*zone=([A-Za-z0-9_]+):.*/\1/p' "$WORK/T" | sort -u)
CZ=$(sed -nE 's/^[[:space:]]*limit_conn_zone[[:space:]].*zone=([A-Za-z0-9_]+):.*/\1/p' "$WORK/T" | sort -u)
say "limit_req_zone" "$(printf '%s' "$RZ" | grep -c .) zone(s): $(printf '%s' "$RZ" | tr '\n' ' ')"
say "limit_conn_zone" "$(printf '%s' "$CZ" | grep -c .) zone(s): $(printf '%s' "$CZ" | tr '\n' ' ')"
say "real_ip_header" "$(sed -nE 's/^[[:space:]]*real_ip_header[[:space:]]+([^;]+);.*/\1/p' "$WORK/T" | sort -u | tr '\n' ' ')$(grep -q 'real_ip_header' "$WORK/T" || echo 'none (OK only if no proxy/CDN is in front)')"
say "gzip" "$(sed -nE 's/^[[:space:]]*gzip[[:space:]]+(on|off);.*/\1/p' "$WORK/T" | head -n 1); proxied: $(sed -nE 's/^[[:space:]]*gzip_proxied[[:space:]]+([^;]+);.*/\1/p' "$WORK/T" | head -n 1); vary: $(sed -nE 's/^[[:space:]]*gzip_vary[[:space:]]+([^;]+);.*/\1/p' "$WORK/T" | head -n 1)"
GT=$(sed -nE 's/^[[:space:]]*gzip_types[[:space:]]+([^;]+);.*/\1/p' "$WORK/T" | head -n 1)
say "gzip_types" "${GT:-text/html only (default)}"
for t in image/svg+xml font/ttf font/otf application/vnd.ms-fontobject; do [[ " $GT " == *" $t "* ]] || MT="${MT:-} $t"; done
[ -n "${MT:-}" ] && say "gzip_types missing" "$MT (never add woff/woff2: already compressed)"

# add_header is inherited only by levels that have none of their own: a location that adds one header (step 6,
# X-Accel Cache-Control) silently drops every http/server-level add_header (HSTS, nosniff, CSP) for its responses.
hdr "add_header (inheritance)"
AH=$(awk '
  function trim(x) { sub(/^[[:space:]]+/, "", x); sub(/[[:space:]]+$/, "", x); return x }
  /^# configuration file / { f = $4; sub(/:$/, "", f); d = 0; next }
  { line = $0; sub(/#.*/, "", line)
    if (line ~ /^[[:space:]]*add_header[[:space:]]/) {
      lvl = (f ~ /\/nginx\.conf$/) ? d - 1 : d          # nginx.conf: inside http {}; included files: http level at 0
      if (lvl == 0) print "http   " f ": " trim(line)
    }
    o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); d += o - c }' "$WORK/T")
if [ -s "$WORK/vhost" ]; then
  AH="$AH
$(awk 'function trim(x) { sub(/^[[:space:]]+/, "", x); sub(/[[:space:]]+$/, "", x); return x }
  { line = $0; sub(/#.*/, "", line)
    if (line ~ /^[[:space:]]*add_header[[:space:]]/) { if (d == 1) print "server " trim(line); else if (d >= 2) loc++ }
    o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); d += o - c }
  END { if (loc) print "note   " loc " add_header line(s) inside locations of the Moodle vhost (those locations already drop the outer ones)" }' "$WORK/vhost")"
fi
AH=$(printf '%s\n' "$AH" | sed '/^$/d')
if [ -n "$AH" ]; then
  printf '%s\n' "$AH" | sed 's/^/  /'
  say "inheritance" "repeat every http/server line above inside any location that gets its own add_header (step 6)"
else
  say "outer add_header" "none at http or Moodle-server level: a location add_header loses nothing"
fi

# --- Moodle side -----------------------------------------------------------------------------------------------
hdr "Moodle (${RELEASE:-release ?}) docroot ${DOCROOT:-?}"
if [ -n "${DOCROOT:-}" ] && [ -d "$DOCROOT" ]; then
  [ -f "$DOCROOT/r.php" ] && say "router r.php" "present (4.5+): unknown URLs go to Moodle via try_files ... /r.php" \
                          || say "router r.php" "absent (pre-4.5): unknown URLs are plain nginx 404s; no fallback zone needed"
  { cat "${MOODLE:-$DOCROOT}/config.php" 2>/dev/null || $SUDO cat "${MOODLE:-$DOCROOT}/config.php" 2>/dev/null; } \
    | grep -E '^[[:space:]]*\$CFG->(xsendfile|xsendfilealiases|routerconfigured)[[:space:]]*=' | sed 's/^[[:space:]]*/  config.php: /'
  [ -f "$DOCROOT/favicon.ico" ] && say "favicon.ico in docroot" "yes" || say "favicon.ico in docroot" "no (requests fall through to Moodle unless nginx serves one)"

  echo "  shim routes (legacy .php URLs served by the router; a missing file would 404 after the existence check):"
  find "$DOCROOT" -path '*/classes/route/shim/*.php' -not -path '*/tests/*' 2>/dev/null | sort | while read -r f; do
    comp=${f#"$DOCROOT"/}; comp=${comp%%/classes/*}
    grep -oE "path: '[^']+'" "$f" | sed -E "s/path: '([^']+)'/\1/" | while read -r p; do
      base=$(printf '%s' "$p" | sed -E 's/\[[^]]*\]//g'); full=$(printf '%s' "$p" | sed -E 's/\[([^]]*)\]/\1/g')
      for u in "$base" "$full"; do
        case "$comp" in lib) url="$u" ;; *) url="/$comp$u" ;; esac
        case "$url" in
          *.php) if [ -f "$DOCROOT$url" ]; then st="file exists"; else st="NO FILE"; fi
                 case "$url" in *example*) st="$st (test route)" ;; esac ;;
          *) st="no .php in URL (unaffected)" ;;
        esac
        printf '    %-44s %s\n' "$url" "$st"
      done
    done
  done | sort -u
  RISK=$(find "$DOCROOT" -path '*/classes/route/shim/*.php' -not -path '*/tests/*' 2>/dev/null | wc -l)
  [ "$RISK" = 0 ] && echo "    (none: Moodle before 5.0 or no shims)"

  echo "  scanner prefixes (case-insensitive) vs docroot and route paths:"
  find "$DOCROOT" -path '*/classes/route/*' -name '*.php' -not -path '*/tests/*' 2>/dev/null -exec grep -ohE "path: '/[^/'{[]*" {} + 2>/dev/null \
    | sed -E "s#path: '/##" | grep -v '^$' | sort -u > "$WORK/routeseg"
  for p in wp-admin wp-content wp-includes wp-json minio nifi-api swagger swagger-ui api-docs actuator cgi-bin phpmyadmin pma telescope _debugbar vendor/phpunit boaform HNAP1; do
    first=${p%%/*}; hit=$(find "$DOCROOT" -maxdepth 1 -iname "$first" 2>/dev/null | head -n 1)
    if [ "$p" = vendor/phpunit ] && [ -e "$DOCROOT/vendor/phpunit" ]; then echo "    $p: EXISTS in docroot (a dev tool on production: blocking it is intended; tell the owner)"
    elif [ -n "$hit" ]; then echo "    $p: COLLIDES with $hit - remove it from the scanner list"
    elif grep -qixF "$first" "$WORK/routeseg"; then echo "    $p: COLLIDES with a route path - remove it from the scanner list"
    fi
  done
  echo "    route first segments seen: $(tr '\n' ' ' < "$WORK/routeseg")(never block these, e.g. api)"

  PB="$DOCROOT/local/edwiserpagebuilder/lib.php"
  if [ -f "$PB" ]; then
    echo "  page builder pluginfile handler ($PB):"
    awk '/function[[:space:]]+local_edwiserpagebuilder_pluginfile/{f=1} f{print "    " NR ": " $0; n++} f && /^}/{exit} n>60{exit}' "$PB" \
      | grep -nE 'function|require_login|require_course_login|contextlevel|CONTEXT_|send_stored_file|has_capability' | sed 's/^[0-9]*://'
  fi
else
  say "docroot" "not readable; run start/scripts/detect-env.sh or set DOCROOT"
fi

hdr "logs"
LR=$(grep -E '^[[:space:]]*(daily|weekly|rotate)' /etc/logrotate.d/nginx 2>/dev/null | tr -s ' \n' ' ')
say "logrotate nginx" "${LR:-?} (new files under /var/log/nginx/*.log are covered by the package glob)"
echo ""
echo "== done. Next: vhost-probe.sh --out /tmp/vhost-before.txt, then the proposal in SKILL.md section 4 =="
