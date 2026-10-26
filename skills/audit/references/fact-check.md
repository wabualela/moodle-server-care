# Independent fact-check before publishing

Why: on the first server, a fact-check of the team report against the operations log, done just before publishing,
found estimated times written as facts, a note that later events had made out of date, services still showing the
"failed" state of runs that happened before the fix, and a claim about a leaked credential that turned out to concern
an old, already-invalid value. Each would have misled the team. The fix took minutes; finding it later would have
cost trust.

## Who and with what
A checker that did not write the report: a fresh sub-agent, or Claude in a separate pass that starts from the
sources, not from the report's reasoning. Give it:
- the report HTML (or its text),
- the operations log (the whole of section 3 for the period) and the handbook,
- the synthesis and the aggregate files the report cites,
- this checklist and `assets/factcheck-template.md`.
The checker is read-only. It may run read-only commands to confirm a state (`stat -c %z <file>`, `systemctl show
-p ActiveState,Result,ExecMainExitTimestamp <unit>`, `systemctl list-timers`, `curl -sI` against the site), never a
change.

## Checklist
1. **Every claim has evidence.** List each number, date, time, "done/fixed/enabled/removed", comparison and causal
   statement. For each, find the source (a log entry, an aggregate file and its row, a command output). No source →
   "unsupported": drop it or mark it as an estimate.
2. **Dry run vs done.** A dry run, a staging test, a debug-mode run, a `--dry-run`, `logrotate -d`, `certbot renew
   --dry-run`, rate limits in `dry_run` mode, a CLI test with cold caches: these are "tested", not "done". The report
   says «اختبار تجريبي ناجح» and when the real confirmation comes (the next real run, at a stated time).
3. **Server time vs student time.** Every timing says what it measures: server (urt), server plus sending (rt),
   probe from the server (TTFB), or browser (PageSpeed, a probe from the students' country). A server-side
   improvement is never reported as "the page is now X s for students".
4. **Timestamps are real.** Times of changes come from the log entries, and the log entries from `date` or file
   change times (`stat -c '%z' <file>`), not from memory. Compare a sample of log entry times with the ctimes of the
   files they touched; a mismatch means the log needs a correction entry.
5. **Fresh state.** A unit whose last run failed before the fix still shows "failed" until it runs again: report the
   fix as done and the confirmation as pending (with the next run time). A statement written earlier in the day may
   be out of date: re-check anything the log changed later.
6. **Scope and origin.** Changes made by the provider, by automatic upgrades or by the owner outside the audit are
   attributed correctly ("origin unverified" when only timestamps show them). The report does not claim the team
   did them, and does not claim the audit changed nothing if it did.
7. **Numbers and units.** Recompute two or three key numbers from the aggregates; check units (KiB vs kB, ms vs s),
   rounding, and that percentages have the right base (share of browser requests vs of all requests).
8. **Privacy and secrets.** No personal data, IP addresses, secrets, credential paths, or names the owner did not
   want in a team document.
9. **Consistency.** The same fact has the same number and status everywhere in the page (summary tiles, cards, plan
   table, ops table, footer).

## Output and follow-up
- A corrections table (`assets/factcheck-template.md`): claim, where in the page, source checked, verdict (supported
  / corrected / unsupported / out of date), correction applied.
- Apply the corrections, then republish to the same URL.
- If operations-log entries were wrong (estimated times, a stale statement), append a correction entry at the end of
  the log listing each correction. Never edit old entries.
- Tell the owner in one line what the fact-check changed.
