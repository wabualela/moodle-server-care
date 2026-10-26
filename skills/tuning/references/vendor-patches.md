# Vendor patches: practice, tool, and optional version-pinned patches

Script: `scripts/vendorpatch.sh` (tests: `scripts/test-vendorpatch.sh`). "Vendor" means third-party plugins
(commercial themes, page builders, activity plugins). **Moodle core is never patched** on these servers
(core-rules §7); the tool refuses files tracked by the core git checkout. Report core problems upstream instead.

## Contents
1. When a vendor patch is justified
2. Rules
3. Writing a new patch
4. Applying, checking, rolling back
5. After a vendor upgrade, and detecting a lost patch
6. Optional, version-pinned patches from the first server (Edwiser RemUI / page builder)
7. The course-card counts helper (optional)

## 1. When a vendor patch is justified
Only when all are true: the cost is measured (slow log frames or page timings point at one vendor function); no
setting turns the behaviour off; the vendor has been (or will be) asked for a fix; the change is small, keeps the
output identical, and can be tested on a copy; the owner approves. Otherwise prefer a content or setting change
(for example removing a counting shortcode from the front page, `frontpage-counters.md`).

## 2. Rules
- Patches live in the **owner's own repository** (a diff plus a pin file), never only on the server. The code tree's
  git does not track third-party plugins, so nothing else records them.
- Every patch is **pinned** to the exact vendor release: `<pre-sha256> <post-sha256> <path>` per file. Apply refuses
  any other file content, so a vendor upgrade cannot be half-patched.
- Each changed block carries a marker comment (for example `// MYORG-PATCH <name> v1`) so `status` and a human can
  see it; the pin file's `# marker:` header names it.
- Files are swapped by their owner, atomically, after a staged copy passed `php -l` and the post-hash check; the
  replaced files are saved under `/var/backups/moodle-vendor-patches/<UTC time>-<name>-<apply|revert>/`.
- A patch is a change on a live server: proposal, approval, log entry with the hashes (first 8 characters), the
  backup path and the rollback command. Add the file to the log's "customised files" table with "lost on vendor
  upgrade; check with vendorpatch.sh status".
- OPcache: with `opcache.validate_timestamps=1` PHP picks the file up within `opcache.revalidate_freq` seconds (read
  the FPM pool's effective values, not the CLI's). With validate_timestamps=0 a gentle FPM reload is needed.

## 3. Writing a new patch
1. On the server, read-only: note the plugin release (`version.php`), copy the files to change into a scratch
   tree `a/<path relative to web root>` and again into `b/...`.
2. Edit `b/...` only; add the marker comment on each changed block. Keep it minimal and behaviour-preserving.
3. `diff -ruN a b > <name>.diff` (paths become `a/<path>` and `b/<path>`).
4. Test on a copy of the site when the change affects output (restore drill host from the `backup` module, or a
   staging copy). Compare the output before and after for several kinds of viewer (guest, student, teacher, admin).
5. Pin it on the server (read-only on the live tree): `bash vendorpatch.sh pin /path/to/<name>.diff`
   (`VP_MARKER=<marker>` if the marker is not of the form WORD-PATCH). Commit diff and pin file to the repository.
6. Run `bash test-vendorpatch.sh` once on a new server (synthetic tree; checks the tool itself works there).

## 4. Applying, checking, rolling back
```bash
bash vendorpatch.sh status /path/to/<name>.diff        # exit 0 applied, 1 not applied, 3 unknown (vendor changed)
sudo bash vendorpatch.sh apply /path/to/<name>.diff    # refuses unless every file is the pinned original
sudo bash vendorpatch.sh revert /path/to/<name>.diff   # reverse; verifies the original hashes
sudo bash vendorpatch.sh restore <backup dir>          # put back saved files when revert is impossible
```
`VP_ROOT` defaults to `<DOCROOT>` from server.env (`<MOODLE>/public` on 5.1+, `<MOODLE>` before), so the same
patch paths (`theme/x/...`) work on both layouts. Measure before and after (`../audit/scripts/measure-endpoints.sh`
on the affected URLs, same weekday and hours).

## 5. After a vendor upgrade, and detecting a lost patch
- An upgrade of the plugin replaces the patched files: the improvement silently disappears.
- Detection: run `vendorpatch.sh status` after every plugin upgrade (put it in the upgrade checklist), and let a
  daily check report it: exit 1 (back to vendor original = patch lost) or 3 (new vendor release) means act. The
  `hygiene` module can schedule the check; the optional helper plugin below reports it in Moodle's status checks.
- Re-porting: check whether the new release still has the problem (maybe the vendor fixed it), redo §3 against the
  new files, new pin, test, release, apply.

## 6. Optional, version-pinned patches from the first server (Edwiser RemUI / page builder)
Use these **only on a server running exactly theme_remui 5.2.2 (2026070300) and local_edwiserpagebuilder 4.2.26
(2026042200)**. They are kept with the owner's course-card counts helper plugin (`<COUNTS_HELPER>`: its component
name and repository are recorded in the server handbook, not in this plugin), in its `vendor-patches/` folder with
their own README and pins; the pins make `vendorpatch.sh` refuse any other release. On other versions, read them as
examples and re-port (§3), or skip.

| Patch | Files (relative to the web root) | What it changes | Needs |
|---|---|---|---|
| enrol-page limits | `theme/remui/classes/EnrolmentPageHandler.php` | The course enrol page built 10 "related" and 20 "latest" course cards, each counting students by loading full user rows, but showed only a few (and none when the block is off). Builds a list only when its setting shows it (or in editing mode), and only as many cards as shown. Output identical. | nothing else |
| course-card counts | `theme/remui/classes/coursehandler.php`, `local/edwiserpagebuilder/classes/coursehandler.php` | Card student counts come from one `COUNT` query through the helper (§7) instead of loading every enrolled user; guarded by `class_exists()`, falls back to the vendor code when the helper is missing, switched off, or fails. | the helper plugin installed first |

First-server results, for expectations only: the enrol page's card build became several times faster in a
cold-cache CLI test with identical cards; real page times must be measured on each server.

Check whether a server matches before proposing them:
```bash
grep -E "release|version" <DOCROOT>/theme/remui/version.php <DOCROOT>/local/edwiserpagebuilder/version.php
VP_ROOT=<DOCROOT> bash vendorpatch.sh status <repo>/vendor-patches/<patch>.diff   # 1 = pinned originals = can apply
```
The helper repository may ship an older patch tool of its own; it and this module's generic one read the same
diff/pin format and detect the marker from the diff. Prefer this module's script (no site paths built in) and pass
the diff path. A backup directory can only be restored by the tool that made it (the layouts differ).

## 7. The course-card counts helper (optional)
The owner's course-card counts helper (`<COUNTS_HELPER>`, a small local plugin for Moodle 5.1/5.2; component name and
repository in the server handbook) does the following:
- provides `\<COUNTS_HELPER>\local\cards::count_students($course, $context)`: the same population as the
  Edwiser cards (any enrolment, users with `moodle/course:isincompletionreports`, not deleted) including the
  separate-groups rule, with one `COUNT`; memoised per request, optional shared cache (`cardcachettl`, default 0 =
  exact) dropped by enrolment/role/capability events; never throws (returns null so the vendor code counts);
- reports a lost patch: a status check (Site administration → Reports → System status;
  `admin/cli/checks.php --filter=<COUNTS_HELPER>`) and an hourly task, driven by the setting listing the
  expected patches (set it to the patches actually applied, or the check fails);
- `cli/verify_cards.php --userid=N --courseids=...` compares vendor and helper counts on real data, read-only
  (on the first server: no mismatch for guest, admin, a student without a group in a separate-groups course, and
  an ordinary account, across all courses tested);
- optionally keeps static count markers in page-builder block HTML up to date with a daily task (dry run first with
  `cli/update.php`, saves the previous block configuration before each write) — the static-numbers option of
  `frontpage-counters.md`.
Install it with `install-plugin.sh` from a release tag (its dev folders, CI config and `vendor-patches/` are
excluded by default). Its README is the reference for settings and CLI options.
