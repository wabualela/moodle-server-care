# Edwiser RemUI course-card cache bug (version-pinned reference)

Found on theme_remui **5.2.2** (2026070300). Use only on a server whose RemUI has the same code (check below);
other releases may have fixed it or changed it. This is a vendor patch: follow `vendor-patches.md` (pinned diff,
test on a copy, owner approval, ticket to Edwiser) and never apply it to production without the hit-rate test.

## Signs
- `theme_remui_get_courses` and `theme_remui_get_tags` AJAX calls (dashboard, course archive) are steadily slow
  (a quarter of a second or more at p50) at any load.
- `mdl_config_plugins` takes a constant stream of UPDATEs (several per minute), invalidating the
  config cache for every request.

## The two bugs
1. **The cache never hits.** `classes/external/get_courses.php` compares the theme setting `cache_reset_time` with
   the user preference `cache_reset_time`, which nothing writes; the code writes `course_reset_time` instead. So every
   call wipes the user's course cache and writes two preferences.
2. **Site-wide stamp churn.** `classes/controller/EventsController.php` calls
   `set_config('cache_reset_time', time(), 'theme_remui')` on many events (completion updates, role changes, course
   and module changes). Each write invalidates the theme's config cache for everyone, and after Bug 1 is fixed it
   also makes every user's cache miss again.

## Check whether a server has it (read-only)
```bash
grep -n "get_user_preferences('cache_reset_time')" <DOCROOT>/theme/remui/classes/external/get_courses.php
grep -n "set_config('cache_reset_time'" <DOCROOT>/theme/remui/classes/controller/EventsController.php
grep -E 'release|version' <DOCROOT>/theme/remui/version.php
```
No match for the first grep: the bug is not there in this form; stop.

## Fix options (developer, on a copy first)
- Bug 1 (one line): compare with `get_user_preferences('course_reset_time', 0)`.
- Bug 2, option 1 (recommended): for single-user progress events (`course_module_completion_updated`,
  `course_completed`, `mod_assign\event\assessable_submitted`) set the user preference `course_cache_reset` for that
  user (the mechanism the enrolment handler already uses) and return; keep the site-wide stamp for structural events
  (course/module create-update-delete, role, capability and group changes, and the course-level
  `course_completion_updated` / `course_started`). `assessable_submitted` sets `relateduserid` only when someone
  submits for another user: use `relateduserid ?: userid`.
- Bug 2, option 2: write the stamp at most once per 60 s and never in the future (accepts up to about a minute of
  staleness). **Do not** use a "now + 60" throttle: the stamp then sits in the future and the cache never hits.
- Options can be combined.

## Hit-rate test (required before production)
On the copy only: add temporary counters (append "CALL" at the start of `get_courses()`, "MISS" at the start of
`invalidate_course_cache()`), reload FPM, run 30 min of a realistic mix (a few test students reloading the dashboard
every 30 s, one completing an activity every minute, an enrolment every 5 min), compute 1 − MISS/CALL for each variant
(unpatched, Bug 1 only, Bug 1 + option 1, Bug 1 + option 2). Apply only a variant with ≥ 80 % hit rate and acceptable
staleness. Remove the temporary lines; they must never reach production.

## Verify and roll back
- `theme_remui_get_courses` p50/p95 (`../audit/scripts/measure-endpoints.sh --endpoint 'remui get_courses | POST | info=theme_remui_get_courses | ^200$'`),
  config_plugins UPDATE rate, course cards correct within a minute after enrolments and course renames.
- Rollback: `vendorpatch.sh revert` (or restore), as for every vendor patch.
