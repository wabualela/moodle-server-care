# Measuring database load before and after, honestly

Script: `scripts/db-load-sample.php` (through `scripts/run-as-web.sh`). For page times use
`../audit/scripts/measure-endpoints.sh` (audit module); for a 48-hour picture use the `audit` module's monitor.

## What to measure
| Change | Primary number | Secondary |
|---|---|---|
| Scheduled tasks rescheduled/disabled | MariaDB/MySQL `Questions`/s (PostgreSQL: transactions/s) | `Com_select`/s, slow queries per minute, cron runners (`pgrep -fc admin/cli/cron.php`) |
| Front-page counters, card patches | page server time (urt p50/p95 of that URL) | slow-log entries at the vendor file, Questions/s at the same hour |
| Static caching | PHP requests per day for those URLs, response headers | page weight (static-check.sh) |

## Procedure
1. **Baseline right before the change**, in the same session:
   `bash run-as-web.sh db-load-sample.php --samples=5 --interval=60 --label=before`
   (5 minutes; use more samples in busy hours, where the noise is larger).
2. Make **only that change**. If another change happens in the same window (yours, another session's, a package
   upgrade, a DB restart), say so: the numbers can no longer be attributed to one change.
3. **After sample** as soon as the change is active, same settings and label `after`.
4. **Confirm later at a comparable time**: the same hour and weekday a day or a week later (cron work is the same
   at night and at peak, web work is not, so a quiet-hour reduction in percent looks larger than it will at peak).
5. Copy the script's `log line:` into the log entry, with the label, sample count, window and DB uptime.

## Rules (each one comes from a mistake that is easy to make)
- Counters are **server-wide**: other sites on the same database server count too. Say so when they exist.
- A DB **restart resets** the counters and empties the buffer pool. On the first server MariaDB had been restarted
  shortly before the baseline for an unrelated change; the report had to mention it. The script drops a sample
  that spans a restart; prefer taking the baseline more than an hour after a restart.
- **Cron is bursty**: tasks start at minute boundaries. One 60-s sample is anecdotal. Report the median and range of
  several samples, and the sample count.
- Model wording (the first server reported its scheduled-task result this way): "Questions/s A → B
  (−N %), preliminary: two 60-second samples in the same quiet hour; confirmation at a comparable hour pending".
- A dry run or a CLI timing is not the page time students see; nginx `urt` is server time, not browser time.
- Do not round a partial result up. If the after number is not lower, report that and look for the reason.

## Reading the numbers
- `q/s` falls sharply and `select/s` with it: polling and lock traffic went away (expected after disabling dead tasks).
- `slow/min` falls: the heavy task no longer runs every minute (expected after the preview-cleanup change).
- `running` (threads running) above the CPU count for long: real contention; look at the slow log, not at cron.
- PostgreSQL: `xact/s` is the closest equivalent of statements; `returned/s` shows scans (rows read), which is
  where a heavy cleanup task shows up.

## Without the script
MariaDB/MySQL, read-only, as an account that can run `SHOW GLOBAL STATUS` (the site's own DB user can):
`SHOW GLOBAL STATUS LIKE 'Questions';` twice, 60 s apart, difference / 60. Never print or type the DB password to do
this; the script uses Moodle's own connection for that reason.
