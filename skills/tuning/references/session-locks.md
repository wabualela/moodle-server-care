# Session locks, read-only sessions and H5P (reference procedure)

Generalised from the first server's runbook 11.

## Signs
- Slow requests that do nothing: the innermost frame in the PHP-FPM slow log is a sleep in the session handler
  (Redis: `usleep` in `lib/classes/session/redis.php`; database sessions: `lib/classes/session/database.php`; file
  sessions: `flock`). One user's long request makes that user's other requests wait (same session).
- Teachers report a "frozen editor": the H5P editor's content-hub call (`mod/hvp/ajax.php` action
  `contenthubmetadatacache` → curl to h5p.org) can hold the session lock for 15+ seconds.
- A busy AJAX method declared `'type' => 'write'` without need (for example a rating/review block's "show" call)
  takes the lock on every call.

## Discovery (read-only)
```bash
sudo grep -c 'session/redis.php' /var/log/php*-fpm*slow*.log          # adapt to the handler; compare per week
sudo grep -B2 -A12 'session/' /var/log/php*-fpm*slow*.log | less      # which scripts wait (no personal data)
bash run-as-web.sh perf-settings.php                                   # handler, read-only sessions, lock timeout, H5P hub
grep -n "readonlysession" <DOCROOT>/lib/db/services.php | head         # which core functions declare it
```
Know the realistic gain before proposing: read-only sessions help only requests that declare them (in core, some
AJAX functions with `'readonlysession' => true` and the navigation branch loader). Most heavy endpoints
(`core_courseformat_get_state`, many plugin endpoints) do not.

## Options
1. `$CFG->enable_read_only_sessions = true;` in `config.php` (core since 3.9; supported by the Redis and DB
   handlers; requires sessions not in `cachestore_session`). Owner-approved config change, quiet hour:
   backup `config.php` to a root-only folder, add one line after the session settings, `php -l` as the web user,
   reload PHP-FPM so OPcache takes it at once. Optional for one test day: `$CFG->enable_read_only_sessions_debug =
   true;` (logs code that writes to a read-only session), removed afterwards.
2. mod_hvp: untick "Enable shared content in H5P Hub" (`mod_hvp | h5p_search_content_hub`); keep "Use H5P Hub"
   unless teachers never install content types. Teachers lose search of shared community content only.
3. Vendor ticket for write-declared read endpoints (ask for `'type' => 'read'`, `'readonlysession' => true`). Do not
   patch locally unless the vendor confirms the endpoint never writes to `$SESSION`.
4. Operating rules for staff: bulk completion changes, big course resets and large activity saves outside peak hours.
5. Optional: lower the session lock timeout (Redis `session_redis_acquire_lock_timeout`, e.g. 120 → 60): waiting
   requests fail sooner with a clear error instead of holding a PHP worker. Discuss first; some long saves wait
   legitimately.

## Verify and roll back
- Weekly count of session-wait frames in the slow log (same slow-log threshold before and after), `mod/hvp/ajax.php`
  max server time per day, teacher feedback.
- Rollback: remove the config line and reload PHP-FPM; re-tick the H5P setting.

## Pitfalls
- A plugin that wrongly declares `readonlysession` and then writes to the session loses that write: that is what the
  debug option is for.
- Other servers may use file sessions: locks are per file and the same reasoning applies, but read-only sessions need
  a handler that supports them; check the Moodle version's handler before proposing.
