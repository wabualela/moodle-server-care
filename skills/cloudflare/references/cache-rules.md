# Cloudflare cache rules for Moodle

## What Cloudflare caches by default
Only responses whose URL ends in a static file extension (css, js, png, svg, woff2, ...) and whose headers allow it.
HTML and anything ending in `.php` is not cached. Moodle serves its theme and JavaScript through PHP scripts with a
revision number in the path, so by default **none** of it is cached, although Moodle sends
`Cache-Control: public, max-age=<months>, immutable` and no cookie for these responses.

## The rule (one rule, "Eligible for cache")
Paths (prefix `<SUBPATH>` when `$CFG->wwwroot` has one):

| Path | What it serves | Versioned by |
|---|---|---|
| starts with `/theme/styles.php/` | compiled theme CSS | theme revision in the path |
| starts with `/theme/javascript.php/` | theme JavaScript | theme revision |
| starts with `/theme/jquery.php/` | jQuery plugins of themes | revision |
| starts with `/theme/image.php/` | theme and plugin icons/images | theme revision |
| starts with `/theme/font.php/` | theme fonts | theme revision |
| starts with `/lib/javascript.php/` | core JavaScript files | JS revision |
| starts with `/lib/requirejs.php/` | AMD modules | JS revision |
| equals `/theme/yui_combo.php` | combined YUI files; the file list is in the **query string** | YUI version + revision |

Settings: Cache eligibility "Eligible for cache"; Edge TTL "Use cache-control header if present, bypass cache if
not"; Browser TTL "Respect origin TTL". Keep the default cache key (query string included: `yui_combo.php` depends
on it). The expression for the editor is in `assets/cache-rule-expression.txt`.

Why it is safe: these URLs change whenever the theme or JavaScript revision changes (theme change, plugin upgrade,
"Purge caches" in Moodle), so a cached copy is never stale and no purge is needed.

## Never
- "Cache Everything" for the whole site or for `/pluginfile.php/*`: course files and private files are protected by
  login and would leak between users.
- "Ignore query string" or a custom cache key without the query string.
- "Ignore origin Cache-Control" / "Override origin": it would cache responses Moodle marked `private` or `no-store`.
- A catch-all "Bypass cache" rule in the **last** position. Cache Rules are not first-match: every matching rule
  applies and, for the same setting, the last matching rule wins. A trailing bypass cancels the static rule. If an
  explicit bypass is wanted, put it first and write it as "path does not start with any of the static prefixes".
- Caching `/login/*`, `/lib/ajax/*`, `/webservice/*`, `/admin/*`, `/draftfile.php/*`, `/tokenpluginfile.php/*`,
  `/r.php` (except the ESM path below), `/course/*`, `/my/*`, `/user/*`.

## Optional additions (only after checking headers)
1. **ESM modules (Moodle 5.x):** URLs look like `/r.php/core/esm/<revision>/...`. Moodle's ESM controller sends
   `public, max-age=<1 year>, immutable` when a revision is present. Add `starts with /r.php/core/esm/` only after
   `curl -sI "<one ESM URL from the page source>" | grep -iE 'cache-control|set-cookie'` shows `public` and no cookie.
   Also check the URL form on this version (`grep -o '/r.php/[a-z_]*/esm/' <saved page>`): it may differ.
2. **Public plugin media:** e.g. Edwiser page builder images under `/pluginfile.php/1/local_edwiserpagebuilder/`
   (context 1 = system; the plugin serves them without login). Moodle sends `private, max-age=10` for them until the
   nginx module's static-caching step makes them `public` for one day. Add the path only after that, and only if
   `curl -sI` shows `public` and no `Set-Cookie`. Read the plugin's `*_pluginfile()` function for the installed
   version first: if it ever calls `require_login` or serves non-system contexts, do not add it.
3. **Course images and other pluginfile areas:** no. They may require login or enrolment.

## Reading `cf-cache-status`
| Value | Meaning | Action |
|---|---|---|
| `HIT` | served from this edge's cache | good for static |
| `MISS` / `EXPIRED` | eligible, fetched from origin this time | request again; expect HIT |
| `DYNAMIC` | not eligible (no rule matched, or default behaviour) | expected for pages; for static: the rule does not match (sub-path? typo?) |
| `BYPASS` | eligible by rule, but the origin said no (`private`, `no-cache`, `Set-Cookie`, `Authorization`) | expected for pages; for static: read the origin headers |
| `REVALIDATED` / `UPDATING` / `STALE` | cache served after checking or while refreshing | fine for static; for pages: investigate |
| header absent | the response did not pass the cache layer (e.g. 5xx from origin, challenge page) | look at the status |

`scripts/cf-cache-check.sh` automates this: static kinds must reach HIT; dynamic pages must never be HIT, and a HIT
carrying `Set-Cookie` is a FAIL (a session cookie could be replayed to other users).

## Caveats
- The cache is per edge location. A HIT from the server proves the rule; students' edges warm up on their first
  requests.
- Cloudflare may evict rarely used objects early (Free/Pro); some MISS later is normal.
- Moodle's "theme designer mode" disables long-lived caching of the theme CSS in Moodle itself: turn it off on
  production; with it on, the rule has nothing to cache.
- Development Mode in the dashboard bypasses the cache for 3 hours: useful while debugging, remember it switches off
  by itself.
