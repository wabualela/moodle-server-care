#!/bin/bash
# fail2ban-check.sh — read-only: is fail2ban running, why not, which backend the sshd jail uses, whether the logs it
# needs exist, how many failed SSH logins happen, and whether the operator's own address has failures (lock-out risk).
#
# Usage: bash fail2ban-check.sh
# Why: on Debian 12 (and other journald-only systems) rsyslog is not installed, so /var/log/auth.log does not exist.
# The packaged sshd jail looks for that file, fails with "Have not found any log file for sshd jail", and the whole
# service stays dead after boot. The fix is backend = systemd for the jail (needs python3-systemd).
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

msc_hr "packages and service"
. /etc/os-release 2>/dev/null; echo "  os: ${PRETTY_NAME:-?}"
if ! msc_have fail2ban-client && [ ! -x /usr/bin/fail2ban-client ]; then
  echo "  fail2ban not installed (installing it is a package change: propose it, do not do it here)"
else
  echo "  version: $(fail2ban-client --version 2>/dev/null | head -n 1)"
  echo "  service: $(systemctl is-active fail2ban 2>/dev/null) / enabled: $(systemctl is-enabled fail2ban 2>/dev/null)"
  echo "  since:   $(systemctl show -p ActiveEnterTimestamp -p InactiveEnterTimestamp fail2ban 2>/dev/null | tr '\n' ' ')"
  echo "  last errors (may predate the current start shown above):"
  $SUDO journalctl -u fail2ban -n 200 --no-pager 2>/dev/null | grep -iE 'error|not found|failed|Have not found' | tail -n 5 | sed 's/^/    /'
fi
for p in rsyslog python3-systemd; do
  if dpkg -s "$p" >/dev/null 2>&1 || rpm -q "$p" >/dev/null 2>&1; then echo "  $p: installed"; else echo "  $p: NOT installed"; fi
done
for f in /var/log/auth.log /var/log/secure; do [ -e "$f" ] && echo "  $f exists ($(stat -c %s "$f" 2>/dev/null) B)"; done
[ -e /var/log/auth.log ] || [ -e /var/log/secure ] || echo "  no auth.log / secure: sshd logs only to the journal"

msc_hr "jail configuration (files and effective sshd backend)"
for f in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*; do [ -f "$f" ] && echo "  $f"; done
if msc_have fail2ban-client; then
  $SUDO fail2ban-client -d 2>/dev/null | grep -E "^\['(add|set)', 'sshd', '(backend|logpath|journalmatch|maxretry|findtime|bantime|addignoreip)?" \
    | grep -E "'add', 'sshd'|backend|logpath|journalmatch|maxretry|findtime|bantime|ignoreip" | head -n 12 | sed 's/^/  /'
  st=$($SUDO fail2ban-client status sshd 2>/dev/null) && printf '%s\n' "$st" | sed 's/^/  /'
fi

msc_hr "SSH exposure"
$SUDO sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|port) ' | sed 's/^/  /'
fails=$($SUDO journalctl --since -24h --no-pager -o cat _COMM=sshd _COMM=sshd-session 2>/dev/null \
  | grep -cE 'Invalid user|Failed password|authentication failure|Connection closed by authenticating user|Disconnected from invalid user')
echo "  failed/invalid SSH attempts in the last 24 h (journal): $fails"
me=${SSH_CLIENT:-}; me=${me%% *}
if [ -n "$me" ]; then
  mine=$($SUDO journalctl --since -24h --no-pager -o cat _COMM=sshd _COMM=sshd-session 2>/dev/null \
    | grep -E 'Invalid user|Failed password|authentication failure|Connection closed by authenticating user' | grep -cF " $me ")
  echo "  your current SSH source $me: $mine failures in 24 h (must be 0 before enabling bans; else add it to ignoreip)"
else
  echo "  not in an SSH session (SSH_CLIENT empty): ask the owner for the admin source addresses before enabling bans"
fi
echo
echo "Out-of-band access if an admin is banned: the provider's web console (not affected by fail2ban)."
