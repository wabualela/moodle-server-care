# Redis password for Moodle (requirepass + sessions + MUC stores)

## Why
A Redis bound to 127.0.0.1 without a password can be read and written by every local process and user: other apps,
developer tooling, docker containers, a compromised web app. Moodle keeps sessions (who is logged in) and caches there.
`requirepass` closes that. The catch: the moment Redis requires a password, every client without it fails (sessions
throw, cache calls error), so Redis, `config.php` and the MUC config must change together, inside CLI maintenance mode.

## Where Moodle keeps the Redis settings
| Use | Setting | Where |
|---|---|---|
| Sessions | `$CFG->session_handler_class = '\core\session\redis'`, `session_redis_host/port/database/prefix`, **`session_redis_auth`** | `<MOODLE>/config.php` |
| MUC cache stores | each store of plugin `redis`: `'server' => 'host:port'`, **`'password' => ''`** | `<DATAROOT>/muc/config.php` (written by the Caching admin UI) |
| (not read by core) | `$CFG->cachestore_redis_password` | some config.php files carry it; it does nothing for MUC |

## Discovery (read-only)
```bash
bash scripts/discover.sh                                   # PING without password, version, clients, MUC store count
sudo bash scripts/set-redis-password.sh --check --moodle <MOODLE>   # every precondition, prints no secret
sudo ss -Htnp state established '( dport = :6379 )'         # who is connected (process names)
sudo grep -lE '^REDIS_(HOST|PASSWORD|URL)=' /var/www/*/.env  # other apps that name Redis (key names only)
```
Decide per finding:
| Finding | Action |
|---|---|
| another app uses the same Redis | it needs the password in the same window (its `.env`, then its own cache/config rebuild and file modes), or drop the item |
| Redis already answers NOAUTH | a password exists: rotating it is a different procedure (stop and ask) |
| ACL users / `aclfile` | stop and ask |
| several Redis servers, TLS, a cluster, a remote Redis | stop and ask |
| Moodle uses Redis for nothing | nothing to do for Moodle (the box may still want a password for other reasons) |
| a MUC store without a plain `'password'` entry (old Moodle) | set the password in the Caching admin UI instead, in the same window |

## The script: scripts/set-redis-password.sh
Run by the **owner** in his own SSH terminal (it shows a generated password once); the session runs `--check` and the
verification. What it does, in order:
1. Preflight (read-only): tools, config.php and MUC parsed (counts only), one local Redis for sessions and stores,
   Redis answers PONG without a password, version, config file from `INFO server`, no active `requirepass`/`aclfile`
   lines, at most the default ACL user, other connected programs (refuses unless `--others-ok`), CLI maintenance ON,
   Moodle CLI works, Moodle's Redis settings answer PONG (`redis-check.php` as the web user), FPM active.
2. Password: generated (`openssl rand -hex 24`) and shown once on the terminal, then pasted back twice from the
   password manager (proves the saved entry); or typed (`[A-Za-z0-9]{32,}`: safe in PHP single quotes and redis.conf).
3. Backup of the three files to `/root/redis-auth-<time>/` (no password inside: the originals had none).
4. The three new files are prepared next to the originals (same owner/mode) and `php -l` checked: config.php gets
   `$CFG->session_redis_auth = '<P>';` right after the last `$CFG->session_redis_*` line; each redis MUC store gets the
   password; redis.conf gets a marked `requirepass` block at the end.
5. `CONFIG SET requirepass` live (no restart: sessions and cached data are kept), sent to `redis-cli` on **stdin**.
   Checks: PING without password → NOAUTH; AUTH + PING → OK PONG. A failure here removes the password again.
6. The files are moved into place (signals blocked for the renames), FPM reloaded (OPcache sees the new config.php at
   once), `redis-check.php` must report PONG for sessions and every store, Moodle CLI must work. A failure asks to roll
   back.
Exit: `REDIS PASSWORD SET` (0), 1 nothing changed, 2 done with a warning, 3 manual attention (recipe printed).

The password never appears in argv or environments (the first server's runbook used `sed` and `redis-cli` with the
value on the command line; acceptable on a single-admin box but avoidable, so the script avoids it).

## Verification without the password (session)
- `sudo bash scripts/night-checks.sh post`: `redis PING (no password)` = NOAUTH; `moodle redis settings` = ok.
- After maintenance is off: log in (owner), Caching → Configuration shows the Redis stores Ready; the session DB key
  count grows (`INFO keyspace` needs AUTH: the owner can run `REDISCLI_AUTH=... redis-cli INFO keyspace` himself, or
  skip it); the cron log has no Redis errors after 3 min (cron runners older than the change may log errors until they
  exit).

## Rollback
`sudo bash scripts/set-redis-password.sh --rollback /root/redis-auth-<time> --moodle <MOODLE>`: reads the current
password from the files (never printed), removes it from Redis live, deletes only the `session_redis_auth` line,
clears only the redis store passwords, removes only the marked redis.conf block, reloads FPM, checks PONG. It never
copies an old config.php back, so it is safe after a later DB password rotation (a whole-file restore would bring back
the old DB password).

## Side effects to tell the owner
- Monitoring or collector scripts calling `redis-cli` without a password now get NOAUTH: give them `REDISCLI_AUTH` from
  a root-only file, or accept empty Redis columns.
- Each backup set made after the change carries the new password inside its encrypted bundle; older sets do not.
- Remove or align a leftover `$CFG->cachestore_redis_password` line later (it is not read by core and only confuses).

## Alternative (not tested on the first server): Redis 6+ ACL, no maintenance window
`ACL SETUSER default on >P nopass` would accept clients with and without the password; then update Moodle and reload
FPM; then `ACL SETUSER default resetpass >P` removes `nopass`. It avoids the window but needs Redis >= 6, `CONFIG
REWRITE` or a redis.conf edit for persistence, and careful testing. Prefer the scripted window unless the owner asks.
