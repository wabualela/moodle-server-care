#!/bin/bash
# discover.sh — read-only discovery for the monitoring module of moodle-server-care.
# Shows: existing monitoring (moodle-health or other agents), the tools each check needs, what the checks would watch
# (services, logs, MTA, proxy ranges, other vhosts), Cloudflare/origin facts for the external monitors, and outbound
# reachability of healthchecks.io (only with --net: one DNS lookup, nothing is pinged).
# It never reads the ping URL file's content and changes nothing.
#
# Usage: bash discover.sh [--net]
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
NET=0; [ "${1:-}" = "--net" ] && NET=1
mh_load_env; mh_init_sudo
say() { printf '%-26s %s\n' "$1" "$2"; }
D="${DESTDIR:-}"            # test harness: look for installed files under this root
URLF="$D/etc/default/moodle-health.url"

echo "== monitoring discovery (read-only) $(date '+%F %T %Z') =="
say "server.env" "${MH_ENV_LOADED:-NOT FOUND: run ../start/scripts/detect-env.sh first}"
say "site / wwwroot" "${SITE:-?} / ${WWWROOT:-?}"
say "moodle / release" "${MOODLE:-?} / ${RELEASE:-?}"
[ -n "${MH_NO_ROOT:-}" ] && say "note" "not root and no passwordless sudo: some facts (crontab, fail2ban, logs) are missing"

mh_hr "existing monitoring"
for f in "$D/usr/local/sbin/moodle-health" "$D/etc/default/moodle-health" "$D/etc/systemd/system/moodle-health.service" "$D/etc/systemd/system/moodle-health.timer"; do
  [ -e "$f" ] && say "installed" "$f ($(stat -c '%U %a %y' "$f" 2>/dev/null | cut -d. -f1))"
done
if $SUDO test -e "$URLF" 2>/dev/null; then
  say "ping URL file" "present ($($SUDO stat -c 'owner %U, mode %a, %s bytes' "$URLF" 2>/dev/null); content not read)"
else
  say "ping URL file" "absent"
fi
say "moodle-health.timer" "$(mh_unit_enabled moodle-health.timer) / $(systemctl is-active moodle-health.timer 2>/dev/null)"
for s in monit netdata zabbix-agent zabbix-agent2 prometheus-node-exporter nagios-nrpe-server datadog-agent newrelic-infra telegraf; do
  st=$(systemctl is-active "$s" 2>/dev/null); [ "$st" = active ] && say "agent" "$s active"
done
crons=$( { for u in $(cut -d: -f1 /etc/passwd); do $SUDO crontab -l -u "$u" 2>/dev/null; done; cat "${MH_CRONTAB:-/etc/crontab}" "$MH_CRON_D"/* 2>/dev/null; } \
  | grep -ciE 'hc-ping|healthchecks|uptimerobot|betteruptime|cronitor' )
say "cron heartbeat lines" "${crons:-0} (hc-ping / healthchecks / uptimerobot / cronitor mentions; values not shown)"
say "other hc-ping users" "$(grep -RlsE 'hc-ping\.com|HC_URL' "$D/etc/default/" "$D/usr/local/sbin/" 2>/dev/null | grep -v moodle-health | tr '\n' ' ')"

mh_hr "tools the checks need"
for t in python3 curl openssl setpriv systemctl mariadb-admin mysqladmin pg_isready redis-cli exiqgrep postqueue mailq fail2ban-client "${PHP:-php}"; do
  if mh_have "$t"; then say "$t" "yes"; else say "$t" "no"; fi
done
say "python3 version" "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) (needs >= 3.7)"
say "systemd" "$(systemctl --version 2>/dev/null | head -n 1)"
cp=""; for p in "$MOODLE/admin/cli/checks.php" "$MOODLE/public/admin/cli/checks.php"; do [ -f "$p" ] && cp="$p" && break; done
say "moodle checks.php" "${cp:-not found (Moodle older than 3.9? status-check part will be skipped)}"

mh_hr "what the checks would watch"
say "web server" "$(mh_webserver)"
say "services (active now)" "$(mh_services)"
mh_access_logs
say "access log(s)" "${MH_ACCESS_LOG:-?}${MH_ACCESS_LOG_VHOST:+ (shared log, filter vhost $MH_ACCESS_LOG_VHOST)}"
for l in $MH_ACCESS_LOG; do
  if $SUDO test -r "$l"; then
    if $SUDO tail -n 20 "$l" 2>/dev/null | grep -qE '\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9:]{8} [+-][0-9]{4}\] "'; then
      say "  $l" "combined-like ([time] \"request\" status): parsable"
    else
      say "  $l" "NOT combined-like: the 5xx check would be blind (adapt the log format or leave ACCESS_LOG empty)"
    fi
  else
    say "  $l" "not readable"
  fi
done
[ "$(mh_webserver)" != nginx ] && say "apache error log" "$(mh_apache_error_log)"
say "fpm logs" "$(mh_fpm_logs)"
say "moodle cron log" "$(mh_cron_log)"
say "db" "dbtype=${DBTYPE:-?} dbhost=$(mh_cfg dbhost 2>/dev/null)"
mta=""; mh_active exim4 && mta="exim4"; mh_active postfix && mta="$mta postfix"
mh_have exiqgrep || mh_have postqueue || mta="$mta (no exim/postfix tools: mail check skipped)"
say "mta" "${mta# }"
say "proxy ranges file" "$(mh_cf_ranges_file)"
if mh_have fail2ban-client; then
  say "fail2ban jails" "$($SUDO fail2ban-client status 2>/dev/null | sed -nE 's/.*Jail list:[[:space:]]*//p')"
fi
say "disk use" "$(df -hP / "${DATAROOT:-/}" 2>/dev/null | awk 'NR>1{print $6" "$5}' | sort -u | tr '\n' ' ')"

mh_hr "other vhosts on this machine (EXTRA_SITES candidates; local probe of /favicon.ico)"
for h in $(mh_other_vhosts); do say "$h" "HTTP $(mh_probe_code "$h")"; done

mh_hr "for the external monitors (UptimeRobot)"
say "cloudflare in front" "${CLOUDFLARE:-unknown} (from server.env)"
say "origin IPv4 (routing)" "${ORIGIN_IP:-?} (behind NAT this is private; the owner confirms the public IP in the provider panel)"
if mh_have ufw; then
  say "ufw 443 rules" "$($SUDO ufw status 2>/dev/null | grep -E '^443|443/tcp' | tr -s ' ' | tr '\n' ';' | cut -c1-200)"
fi
say "nginx origin lock" "$(grep -RlsE 'from_cloudflare|realip_remote_addr' "$MH_NGINX_DIR/" 2>/dev/null | tr '\n' ' ')"
echo "  (a firewall that admits only Cloudflare on 443 makes an origin port monitor fail: see external-uptime.md)"

if [ "$NET" = 1 ]; then
  mh_hr "outbound (DNS only)"
  say "hc-ping.com resolves" "$(getent hosts hc-ping.com >/dev/null 2>&1 && echo yes || echo NO: pings cannot leave this server)"
fi
echo
echo "Next: bash scripts/install.sh plan   (from the module directory; renders the config for review, still no change)"
