# Fact-check of the team report — version <n>, <date> (<time zone>)

<!-- Filled by the independent checker (references/fact-check.md). Kept with the audit working notes, not in the
     plugin. One row per claim; every number, date, time, status ("done", "fixed", "enabled") and causal sentence. -->

Sources given to the checker: report version <n>; operations log section 3 up to <last entry time>; handbook;
synthesis; aggregates in <path>.

| # | Claim (as written) | Where in the page | Source checked | Verdict | Correction applied |
|---|---|---|---|---|---|
| 1 | | summary tile 2 | log entry <time> / <file> row <n> | supported / corrected / unsupported / out of date | |

Checks done (tick each):
- [ ] every claim has a source (§1)
- [ ] dry runs and tests are not reported as done; real confirmation time stated (§2)
- [ ] every timing says server / server+send / probe / browser (§3)
- [ ] change times match the log entries and the files' ctimes (`stat -c %z`) for a sample of <k> entries (§4)
- [ ] states re-checked now (units, timers, caches, settings) where the log changed them later (§5)
- [ ] changes made outside the audit attributed correctly (§6)
- [ ] two or three key numbers recomputed; units and percentage bases right (§7)
- [ ] no personal data, IP addresses, secrets or unwanted names (§8)
- [ ] the same fact has the same number and status everywhere (§9)

Operations-log correction entry needed: yes / no (if yes, appended at <time>, listing the corrected entries).

Summary for the owner (one line, Arabic): ...
