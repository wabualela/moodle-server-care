#!/bin/bash
# db-listen-check.sh — read-only: on which addresses do the database (and other local-only services) listen, why
# (socket activation vs bind-address/listen_addresses), whether anything legitimately connects over the network,
# and whether the firewall already blocks the port. Prints counts and addresses, never credentials.
#
# Usage: bash db-listen-check.sh
# Why: MariaDB's packaged mariadb.socket has ListenStream=3306 (all addresses). Under socket activation mariadbd
# inherits that socket and IGNORES bind-address = 127.0.0.1, so `ss` shows *:3306 even though my.cnf looks right.
# An upgrade can enable mariadb.socket silently. A firewall that blocks the port is one layer; the listener should
# still be loopback-only (defence in depth: firewall rules get changed, VPC/private networks are often open).
set -uo pipefail
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-env.sh"
msc_load_env; msc_init_sudo

PORTS='3306|33060|5432|6379|11211|9200|27017'
msc_hr "listeners on database/cache ports"
$SUDO ss -Hltnp 2>/dev/null | awk -v re=":($PORTS)\$" '$4 ~ re {
    a = $4; loop = (a ~ /^127\./ || a ~ /^\[::1\]/ || a ~ /^::1/) ? "loopback" : "NOT-LOOPBACK"
    printf "  %-13s %-28s %s\n", loop, a, $6 }'

msc_hr "MariaDB / MySQL"
for u in mariadb.socket mysql.socket mysqld.socket; do
  if systemctl cat "$u" >/dev/null 2>&1; then
    echo "  $u: enabled=$(systemctl is-enabled "$u" 2>/dev/null) active=$(systemctl is-active "$u" 2>/dev/null)"
    systemctl cat "$u" 2>/dev/null | grep -E '^(# /|ListenStream)' | sed 's/^/    /'
  fi
done
if [ -d /etc/mysql ]; then
  echo "  config lines (bind/networking/port/x-plugin):"
  $SUDO grep -rhnE '^[[:space:]]*(bind[-_]address|skip[-_]networking|port|mysqlx[-_]bind[-_]address|mysqlx)[[:space:]]*(=|$)' /etc/mysql 2>/dev/null | sed 's/^/    /'
fi
if msc_have mariadb || msc_have mysql; then
  cli=$(command -v mariadb || command -v mysql)
  n=$($SUDO "$cli" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE host NOT IN ('localhost','127.0.0.1','::1')" 2>/dev/null)
  echo "  accounts allowed from non-local hosts: ${n:-unknown (no root socket access)}"
fi
peers=$($SUDO ss -Htn state established '( sport = :3306 or sport = :33060 )' 2>/dev/null | awk '{print $4}' | sed -E 's/:[0-9]+$//' | sort | uniq -c)
echo "  established TCP clients on 3306/33060 (by peer address):"; printf '%s\n' "${peers:-    none}" | sed 's/^/    /'

msc_hr "PostgreSQL"
for f in /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/main/conf.d/*.conf /var/lib/pgsql/data/postgresql.conf; do
  [ -f "$f" ] && $SUDO grep -HnE "^[[:space:]]*listen_addresses" "$f" 2>/dev/null | sed 's/^/  /'
done
for f in /etc/postgresql/*/main/pg_hba.conf; do
  [ -f "$f" ] && echo "  $f: $($SUDO grep -cE '^[[:space:]]*host' "$f" 2>/dev/null) 'host' lines (network access rules)"
done

msc_hr "Moodle's own connection"
if [ -n "${MOODLE:-}" ]; then
  $SUDO grep -E "CFG->dbhost|'dbsocket'|'dbport'" "$MOODLE/config.php" 2>/dev/null | sed -E "s/(pass[^=]*=>?).*/\1 ***/" | sed 's/^/  /'
  echo "  (dbhost 'localhost' with mysqli uses the unix socket; '127.0.0.1' uses TCP and needs the loopback listener)"
fi

msc_hr "firewall"
if msc_have ufw; then $SUDO ufw status verbose 2>/dev/null | sed -n '1,25p' | sed 's/^/  /'
elif msc_have nft; then $SUDO nft list ruleset 2>/dev/null | grep -nE 'dport|policy' | head -n 20 | sed 's/^/  /'
elif msc_have iptables; then $SUDO iptables -S INPUT 2>/dev/null | head -n 20 | sed 's/^/  /'
else echo "  no ufw/nft/iptables tool found"; fi
echo
echo "Never restart mariadb.socket alone while mariadbd runs: systemd re-creates the unix socket file and running"
echo "clients (Moodle) lose the database. Stop service AND socket, then start socket AND service."
