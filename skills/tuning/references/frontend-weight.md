# Front-end weight (reference procedure)

Generalised from the first server's runbook 10. Scripts: `scripts/static-check.sh` (live page: HTML size, script
count, headers), `scripts/frontpage-blocks.php` (where the scripts are stored), `scripts/perf-settings.php`.

## Signs
- The front page HTML is hundreds of KB and carries hundreds of `<script>` tags; the same libraries (jQuery,
  Bootstrap, slick, AOS) and the same trackers (Hotjar, TikTok, Meta, GTM) appear many times.
- Cause on the first server: page-builder blocks had stored copies of the live DOM, including scripts injected by
  trackers, and replayed them on every view (one block alone had 128 script tags).
- A theme "site loader" (RemUI `enablesiteloader`) hides the page until every synchronous script ran, so each
  duplicate delays first paint. Gravatar makes browsers fetch external avatars.

## Discovery (read-only)
```bash
bash static-check.sh                       # HTML raw/wire size, <script> count, TTFB (one sample)
bash run-as-web.sh frontpage-blocks.php    # per block: script tags, repeated sources, tracker signatures
bash run-as-web.sh perf-settings.php       # additionalhtmlhead size and script count, site loader, gravatar
```
Baseline in the browser: PageSpeed Insights (mobile) for `/` and `/login/index.php`, 3 runs, median of LCP, TBT,
bytes, requests. Record it in the log.

## Proposal (marketing decides which tags are required)
1. Clean the stored block HTML: remove every `<script>` that is not part of the block's own design (tracker copies,
   repeated library copies). The page builder's own JS is needed once; Moodle already loads jQuery through RequireJS.
2. One tag manager: move GA4, Meta, TikTok, Hotjar into one GTM container; leave only the GTM snippet in
   Site administration → Appearance → Additional HTML (`additionalhtmlhead`), its `<noscript>` part in "When BODY
   is opened". Verify events in GTM preview and each vendor's debugger; tell marketing counts can shift slightly.
3. Site loader off (theme setting) — visible change: owner approves.
4. Gravatar off (`enablegravatar`, Site administration → Users → Permissions → User policies) — optional.
5. `loading="lazy"` on below-the-fold images in block HTML (keep the first hero image eager).

## Procedure
- Backup first: each block's HTML (site-home backup as in `frontpage-counters.md` step 1) and the current
  `additionalhtmlhead` text (copy it into a root-only file; it holds tracking ids, not secrets, but keep it private).
- Edit in the page-builder's own editor, one block at a time; check every section on mobile and desktop before
  leaving the editor (removing a script that a slider needs breaks it).
- Settings with `admin/cli/cfg.php` or the admin UI; log old and new values.
- Verify: script count and HTML size (`static-check.sh`), PSI medians, tracking events after 24 h (marketing).
- Rollback: paste the saved HTML back, restore `additionalhtmlhead`, settings back.

## Pitfalls
- The classic block "Configure" form rewrites large HTML and strips scripts: never use it for page-builder blocks.
- Theme CSS weight is a theme matter; a CDN (cloudflare module) serves it from the edge, a real reduction needs theme
  work.
- Moving tags to GTM changes who can add scripts to every page: agree with the owner who controls the container.
