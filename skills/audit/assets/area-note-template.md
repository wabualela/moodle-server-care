# <Area> — <site placeholder>, <window start> to <window end> (<time zone>)

<!-- Working note for one area of the audit (traffic, PHP, DB, ops/mail/security, monitor capacity, monitor TTFB,
     network, cron/events). Lives in the session's scratch directory or the audit folder on the server, not in the
     plugin. English for Claude; the team report is written in Arabic from these notes. Method:
     references/interpreting-the-data.md. -->

## 1. Headline
Two lines: the answer for this area, with the one number that carries it (what, where, period, n).

## 2. Data and method
- Files used (paths inside the extracted tarball or monitor directory): ...
- Window: <start> to <end> = <exact hours> h; rates are per hour (or per full day).
- Exclusions: monitor probes (UA moodle-audit-monitor), collector minutes, other work (list the minutes and why).
- Percentiles: nearest-rank from the collector / type-7 recomputed; "median of hourly p95" vs pooled: say which.
- Statistics used (correlation, Little's law, Mann-Whitney ...), and their inputs.

## 3. Findings
| # | Finding | Number (what, where, period, n) | File | Confidence |
|---|---|---|---|---|
| F1 | ... | ... | ... | high / medium / low |

## 4. Hypothesis verdicts
| H | Verdict (CONFIRMED / PARTIAL / REFUTED / NOT TESTABLE) | Deciding evidence (file) |
|---|---|---|
| H1 | ... | ... |

## 5. New issues (not in the hypotheses)
- ... (severity, evidence, which module would fix it)

## 6. Limits
- Load level reached vs the historic peak; sampling interval; what the data cannot show (browser time, the students'
  network, logged-in pages ...).

## 7. What the team report should say
Plain sentences (English here; the lead translates): the claim, the number with its context, and the caveat.

## 8. Claims dropped or corrected during this pass
- ...
