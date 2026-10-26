# H8: database (and cache) listening beyond localhost

## Why it matters
Moodle on the same box talks to the database over the unix socket (or `127.0.0.1`). A listener on all addresses is
only one firewall mistake away from exposure: firewall rules get edited, private/VPC networks are often open between
droplets, and a provider's "cloud firewall" may not be in use. Defence in depth: the database should listen only where
its clients are.

**The MariaDB trap:** Debian's MariaDB packages ship `mariadb.socket` with `ListenStream=3306` (all addresses). When
the socket unit is enabled (an upgrade can enable it), systemd owns the listening socket and passes it to mariadbd,
which then **ignores `bind-address = 127.0.0.1`**. `ss` shows `*:3306` although `my.cnf` looks right.

## Discovery (read-only)
```bash
bash scripts/db-listen-check.sh
```
Read: non-loopback listeners on 3306/33060/5432/6379/11211/…; whether `mariadb.socket` (or `mysql.socket`) is enabled
and its `ListenStream` lines; `bind-address`/`skip-networking`/`mysqlx-bind-address` in the config; accounts allowed
from non-local hosts (a count); established TCP clients and their peer addresses; PostgreSQL `listen_addresses` and
`pg_hba` host lines; Moodle's `dbhost` (and `dbsocket`); the firewall policy.

**Stop and ask** if there is any legitimate remote client: a non-local account that is used, an established
connection from another host, a replica, a backup or reporting server, an app on another droplet. Then the listener
must stay (restrict it with the firewall to that client instead) and this item is not applied.

## Decide the fix by case
| Case | Fix | Takes effect |
|---|---|---|
| MariaDB with `mariadb.socket` enabled | drop-in `assets/mariadb-socket-localhost.conf` (reset `ListenStream`, re-add the abstract and unix sockets and `127.0.0.1:3306`) | restart of socket + service |
| MariaDB/MySQL without socket activation | `bind-address = 127.0.0.1` in the `[mysqld]`/`[mariadbd]` section (Debian: `/etc/mysql/mariadb.conf.d/50-server.cnf`) | service restart |
| MySQL 8 X plugin on 33060 | `mysqlx-bind-address = 127.0.0.1` (or `mysqlx = OFF` if unused) | service restart |
| Nothing uses TCP at all (dbhost `localhost` = socket) | optional `skip-networking`; keep `127.0.0.1` if any tool or backup uses TCP | service restart |
| PostgreSQL | `listen_addresses = 'localhost'` in `postgresql.conf` | **restart** (reload is not enough) |
| Redis | `bind 127.0.0.1 -::1` in `redis.conf` (usually already) | service restart |
Keep the loopback TCP listener when Moodle's `dbhost` is `127.0.0.1` (TCP), or when tools connect over TCP.

## Proposal (Arabic)
> **قاعدة البيانات تستمع على كل العناوين:** قاعدة البيانات تقبل الاتصالات على كل واجهات الشبكة بسبب إعداد في حزمة
> النظام يتجاوز الإعداد الصحيح الموجود. الجدار الناري يمنع الوصول من الخارج حالياً، ولا يوجد أي مستخدم أو اتصال من خارج
> الخادم، لكن الأفضل ألا تعتمد الحماية على طبقة واحدة. أقترح ملف إعداد صغيراً يجعلها تستمع على الخادم نفسه فقط. يحتاج
> تطبيقه إعادة تشغيل قاعدة البيانات (انقطاع ثوانٍ معدودة)، لذلك أقترح تنفيذه في ساعة هادئة أو ضمن ليلة الصيانة.

## Procedure (MariaDB socket activation; adapt the commands for the other cases)
1. **Timing:** a quiet hour (measured, see core rules §4) or the maintenance night. The restart cuts DB connections
   for about 1–10 s; Moodle pages in flight may error.
2. **Backup:** the change is a new file; record `systemctl cat mariadb.socket` output in the log entry. For a
   `my.cnf` edit: `sudo cp -a <file> <file>.bak-<DATE>` (the config directory includes only `*.cnf`, so the backup
   is not loaded).
3. **Change:**
   ```bash
   sudo install -d -m 755 /etc/systemd/system/mariadb.socket.d
   sudo install -m 644 assets/mariadb-socket-localhost.conf /etc/systemd/system/mariadb.socket.d/10-localhost-only.conf
   sudo systemctl daemon-reload
   ```
4. **Test:** `systemctl cat mariadb.socket | grep ListenStream` shows the reset (`ListenStream=`) and the three
   intended listeners; `sudo systemd-analyze verify mariadb.socket` prints no errors for the drop-in.
5. **Apply** (both units, in this order; never restart the socket alone):
   ```bash
   date '+%F %T'; sudo systemctl stop mariadb.service mariadb.socket && sudo systemctl start mariadb.socket mariadb.service; date '+%F %T'
   ```
   **Why both:** restarting only `mariadb.socket` while mariadbd runs makes systemd re-create
   `/run/mysqld/mysqld.sock`; the running server keeps the old (now unlinked) socket and every new Moodle connection
   fails until mariadbd is restarted too.
6. **Verify:**
   - `sudo ss -Hltnp | grep -E ':3306\b'` shows only `127.0.0.1:3306`.
   - From another host (or the public address): `nc -vz <ORIGIN_IP> 3306` is refused (only if the owner allows a probe).
   - Both units `active`; the Moodle login page returns 200; `sudo tail` of the Moodle cron log shows no DB errors
     after 2 minutes; `mariadb -e 'SELECT 1'` over the socket works.
7. **Rollback:** `sudo rm /etc/systemd/system/mariadb.socket.d/10-localhost-only.conf && sudo systemctl daemon-reload`,
   then the same stop-both / start-both.
8. **After future MariaDB upgrades:** re-run `db-listen-check.sh` (the package may change its socket unit); add that to
   the maintenance checklist in the handbook.

## Pitfalls
- `bind-address` looks correct and `ss` still shows `*:3306`: that is socket activation, not a typo.
- `systemctl restart mariadb` alone does not apply a socket drop-in: the socket keeps its old listeners.
- A firewall that "already blocks it" is not a reason to skip the fix, but it is a reason to schedule it calmly
  (no urgency, no daytime restart).
