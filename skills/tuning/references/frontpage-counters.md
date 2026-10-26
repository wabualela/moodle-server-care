# Front page: live enrolment counters (reference procedure)

Generalised from the first server's runbook 02. Script: `scripts/frontpage-blocks.php` (inventory),
`../audit/scripts/measure-endpoints.sh` and `scripts/static-check.sh` (measure).

## Signs
- The front page `/` is slow even when the site is idle (server time well above the login page's), and the same at
  peak and off-peak: the cost is per render, not load.
- PHP-FPM slow-log stacks on `/` end in a page-builder or theme function that loads enrolled users, for example
  Edwiser `filter_edwiserpbf ... ContentGenerator::get_courses` → `local_edwiserpagebuilder coursehandler::
  get_enrolled_students`, which loads the full user rows of every enrolled student of each card just to count them,
  on every render, guests included (on 4.2.26 the count is hard-coded on; no shortcode attribute turns it off).
- The front page is the target of PHP-FPM pool exhaustion during floods.

## Discovery (read-only)
```bash
bash run-as-web.sh frontpage-blocks.php      # blocks, shortcodes per block ([edwiser-fc] flagged), script counts
sudo grep -c '<vendor file>:<line>' <php-fpm slow log>      # how many slow stacks end there (watch it grow or not)
sudo bash ../../audit/scripts/measure-endpoints.sh --from "<from>" --to "<to>"   # front page vs login page server time
```
Also count students per course shown on the cards (read-only, aggregate) if the owner wants static numbers.

## Options to propose (owner decides; Arabic text in assets/owner-texts-ar.md)
| Option | What | Effort | Keeps the look | Survives upgrades |
|---|---|---|---|---|
| A. Static numbers | Replace the counting shortcode with static card HTML; numbers as text, refreshed by hand monthly or by the optional helper plugin's daily task | 1–2 h, content editor | yes | yes |
| B. Hide the section | Hide the block(s); optionally a light static "featured courses" list | minutes | no | yes |
| C. Live counts, cheap | Vendor patch so the count is one `COUNT` query (`vendor-patches.md` §6) | developer | yes | no (re-apply after upgrades) |
The first server's owner chose A; C was later prepared as a pinned patch with a helper plugin.

## Procedure for A or B
1. **Backup (mandatory):** a site-home backup without users from the UI (Site home → Backup, include blocks), and
   save the front page HTML as a guest (visual reference). Optional exact copy of the two blocks' `configdata` by
   the owner's DB procedure (read-only SELECT of the block ids found above, into a root-only file; run redirects
   inside `sudo sh -c '...'` because the non-root shell cannot write into a 700 directory).
2. **Change (content editor, quiet hour):**
   - A: in the page-builder's own editor (not the classic block "Configure" form, which can mangle large HTML and
     strip scripts), delete the whole dynamic component (for Edwiser the element with `data-edwiser-dynamic` /
     `data-shortcode="edwiser-fc"`, which the editor regenerates on save if any part of it is left) and add the
     static cards as a separate HTML element: copy the rendered card markup from a logged-out browser (DevTools →
     Copy outerHTML), keep links, images, titles; numbers as static text (or the helper plugin's markers).
   - B: block menu → Hide.
3. **Test:** guest and student, mobile and desktop: cards render, links work, no broken images, layout signed off
   on a screenshot by the owner before saving (the front page is the marketing page).
4. **Apply:** saving is live immediately. A cache purge is normally not needed (block content is read per request).
5. **Verify:** front page server time p50/p95 (target close to the login page), no new slow-log stacks at the vendor
   line, visual check. Compare a full day before with a full day after.
6. **Rollback:** B: Show. A: paste the original shortcode back from the backup, or restore the block from the
   site-home backup. A direct DB update of `configdata` is the last resort (skips events; purge caches after).

## Pitfalls
- The same blocks often carry duplicated third-party scripts captured from the live DOM (`frontend-weight.md`).
  If the editor is open anyway, do both in one sitting but verify each separately.
- Static numbers go stale: agree the refresh cadence and wording with the owner (first server: rounded down to the
  hundred with a "+", e.g. "+1,200", monthly or nightly by the helper).
- With option C, separate-groups courses: the vendor count depends on the viewer's groups; a static or core count
  does not. Say so in the proposal.
