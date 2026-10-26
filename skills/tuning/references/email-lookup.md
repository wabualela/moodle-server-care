# Login by e-mail: LOWER(email) full scan (reference)

Generalised from the first server's runbook 13. Low priority; usually "accept and report upstream".

## Signs
- A digest like `... WHERE mnethostid = ? AND LOWER(email) = LOWER(?) AND deleted = 0` with rows examined close to the
  number of non-deleted users, a few hundred ms per call.
- `authloginviaemail = 1` and many users whose username is not their e-mail address.

## Attribution (check before blaming signup)
- The likely caller is `authenticate_user_login()` in `lib/moodlelib.php` (login by e-mail when the typed identifier
  is not a username). The signup and forgot-password checks in core already use an indexable, accent-insensitive
  pre-filter (`lib/authlib.php`, `login/lib.php`), so they rarely cause it.
- Confirm with the full digest text from the audit's DB collection, not from the first lines alone.

## Options
1. **Accept (default).** The cost is limited to e-mail logins (a fraction of a second on each e-mail login, a modest number a
   day). Report it upstream (Moodle tracker) with the evidence so a core fix arrives with an upgrade.
2. **Core patch: not on these servers.** core-rules §7 forbids changing core files in a git checkout. The pattern the
   upstream fix would follow (an indexable `email = :email` pre-filter in a subquery, then the exact
   case-insensitive match) belongs in the tracker report.
3. **Turning off `authloginviaemail`**: not recommended; it locks out users who log in with their e-mail address.
4. PostgreSQL only, owner decision: a functional index on `lower(email)` is possible but sits outside Moodle's schema
   (the schema check may report it; drop and recreate around upgrades). Not used on the first server.

## Verify
After an upstream fix or any change: the digest's average time and rows examined drop to near 1; the POST
`/login/index.php` p95 drops slightly.
