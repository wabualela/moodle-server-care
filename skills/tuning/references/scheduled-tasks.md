# Scheduled tasks: review and reschedule

Detailed procedure behind SKILL.md §5.1. Scripts: `scripts/tasks-review.php`, `scripts/tasks-apply.php`,
`scripts/tasks-verify.php`, run through `scripts/run-as-web.sh`.

## Contents
1. Why cron can dominate database load
2. What to look for (candidates and decisions)
3. Discovery
4. The plan file and owner approval
5. Apply, verify, roll back
6. Version and environment differences
7. Risks and notes

## 1. Why cron can dominate database load
- On a quiet Moodle site most database statements can come from cron, not from students. On the first server
  cron made most of the MariaDB statement time, and a few tasks explained most of that.
- `cron.php` is started every minute and stays alive `cron_keepalive` seconds (default 180) polling for work, so
  several runners overlap (about `cron_keepalive / 60`). Each poll reads `task_scheduled` and tries a lock per due task.
- **Enabled tasks of disabled plugins are the hidden cost.** In `core\task\manager::get_next_scheduled_task()` a
  *disabled* task is skipped before any lock, but an *enabled* task whose *plugin* is disabled is skipped only after
  `GET_LOCK`/`RELEASE_LOCK`, and its next run time is never advanced. It stays "due" forever and costs two lock
  statements per poll per runner. On the first server a couple of dozen such tasks made most of the lock statements.
  The review labels each one: "DUE NOW" (costs now), "due <date>" (will cost from then on, because cron never advances
  it), or "never due" (next run time is Moodle's never-run sentinel: no cost, disabling is only tidiness).
- Some core defaults are aggressive: `\core\task\question_preview_cleanup_task` runs every minute by default and
  can scan a large `question_usages` table to delete nothing. Cohort and meta enrolment syncs are sometimes
  customised to every minute although event observers already apply those enrolments immediately.

## 2. What to look for (candidates and decisions)

| Candidate | Typical proposal | Why it is safe | Who decides |
|---|---|---|---|
| Enabled task whose plugin is disabled | `disable` | It never runs anyway (cron skips it); disabling only removes the lock cost | Owner approves the list; script re-checks the plugin is still disabled at apply time |
| `\core\task\question_preview_cleanup_task` every minute | daily, at a quiet-hour minute | It removes previews older than a day; once a day loses nothing | Owner |
| `\enrol_cohort\task\enrol_cohort_sync`, `\enrol_meta\task\enrol_meta_sync` every minute | `*/15 * * * *` or `reset` (default hourly) | Safety net only: `enrol/cohort/db/events.php` and `enrol/meta/db/events.php` observers sync immediately | Owner accepts up to 15 min (or 1 h) for changes made outside Moodle's API (direct SQL, external tools without events) |
| `\core\task\completion_regular_task` every minute | optional `*/5 * * * *` | Only course-completion aggregation waits (activity ticks stay instant); certificates that wait for course completion wait too | Business sign-off; first server kept it unchanged |
| `cron_keepalive` above 120 with 3+ overlapping runners | `120` | Fewer runners competing for the same locks; tasks still start every minute | Owner |
| Task disabled for years (for example forum notifications) | **no change here** | Enabling may send a backlog of mail or messages to students | Business decision, separate item; never part of a performance batch |
| Task in fail delay | investigate, do not reschedule | A failing task is a bug or a configuration problem, not a schedule problem | Read the task log first |

Leave alone: tasks overridden in `config.php` (`$CFG->scheduled_tasks`; change them there with the owner), tasks the
owner customised on purpose (section C of the review shows them), and everything not in the approved list.

## 3. Discovery
```bash
cd <SKILL_DIR>/scripts        # <SKILL_DIR> = this skill's base directory
bash run-as-web.sh tasks-review.php --plan-out=/tmp/msc-tasks-plan.txt --quiet-hour=<H>
pgrep -fc 'admin/cli/cron.php'            # overlapping cron runners right now (repeat a few times)
sudo crontab -u "$WEBUSER" -l | grep -v '^#'   # how cron is started (php version, log file, adhoc runners)
```
- `--quiet-hour` is the hour used for daily schedules in the draft; take it from the audit's measured quiet hours.
- Section E (task log) shows the heaviest tasks by total time and DB reads when `task_logmode = 1` (all runs). With
  `task_logmode = 2` only failures are logged; do not read those numbers as load.
- Also measure the baseline now (`references/db-load-measurement.md`), before anything changes.

## 4. The plan file and owner approval
- The draft lists every proposal commented out with `#? `. Nothing in it is applied until a line is un-commented.
- Show the owner the proposal in Arabic (template in `assets/owner-texts-ar.md`, section "المهام المجدولة"):
  what each change does, what users notice (normally nothing), the rollback.
- After approval, write the approved copy as a NEW file (the draft is owned by the web user and `/tmp` is sticky, so
  it cannot be edited in place): `sed 's/^#? //' /tmp/msc-tasks-plan.txt > /tmp/msc-tasks-approved.txt` when
  everything is approved, otherwise copy it and un-comment only the approved lines. The copy is yours, mode 644:
  the web user can read it, nobody else can change it. Keep it with the backup and write the approval into the log.
- Format and actions: `assets/tasks-plan.example.txt`. `disable` only acts while the plugin is still disabled (else
  it prints KEEP); `disable-anyway` stops a working feature and needs explicit approval for that task by name.

## 5. Apply, verify, roll back
```bash
cd <SKILL_DIR>/scripts        # <SKILL_DIR> = this skill's base directory
# dry run: current -> target per line; nothing changes
bash run-as-web.sh tasks-apply.php --plan=/tmp/msc-tasks-approved.txt
# apply (old values go to the backup file first; the web user writes it, mode 600)
bash run-as-web.sh tasks-apply.php --plan=/tmp/msc-tasks-approved.txt --execute --backup=/tmp/msc-tasks-backup-$(date +%F-%H%M).json
# verify: every line OK, no permanently-due task of a disabled plugin (two readings 10 min apart)
bash run-as-web.sh tasks-verify.php --plan=/tmp/msc-tasks-approved.txt --wait=600
# keep the evidence root-only
sudo install -d -m 700 /root/tuning-$(date +%F)
sudo mv /tmp/msc-tasks-backup-*.json /tmp/msc-tasks-plan.txt /tmp/msc-tasks-approved.txt /root/tuning-$(date +%F)/
```
- Apply is one quick DB write per task through `core\task\manager::configure_scheduled_task()` (the same call the
  admin form uses). No maintenance mode, no cache purge, no service reload. Any hour is acceptable, but take the
  before/after DB samples around it with no other change in between (`db-load-measurement.md`).
- `--wait=600` takes two readings 10 min apart, because busy runners can delay a healthy task by more than 5 min once.
- Rollback, all at once: `sudo install -o "$WEBUSER" -m 600 /root/tuning-<date>/<backup>.json /tmp/`, then
  `bash run-as-web.sh tasks-apply.php --restore=/tmp/<backup>.json` (dry run) and again with `--execute`.
  Rollback for one task: Site administration → Server → Tasks → Scheduled tasks → cog → "Reset to default" or untick
  "Disabled"; or `admin/cli/scheduled_task.php --enable='\plugin\task\name'` (Moodle 4.x/5.x, as the web user).
- Confirm with evidence after the next real runs: the daily task ran at its new time (task log or `lastruntime`),
  cohort/meta syncs ran every 15 min, no task in fail delay, and the DB numbers (after sample).

## 6. Version and environment differences
- Moodle 4.x and 5.x: all APIs used exist (`get_all_scheduled_tasks`, `configure_scheduled_task`,
  `get_default_scheduled_task`, `scheduled_task_has_override`). On 3.x the scripts fall back where a method is
  missing; read their output carefully and prefer the admin UI if anything looks odd.
- CLI path: `<MOODLE>/admin/cli/` on every version (on 5.1+ it is NOT under `public/`).
- `$CFG->preventscheduledtaskchanges` set in config.php: tasks-apply refuses. Ask the owner whether to change
  config.php instead (a config change with its own backup and log entry).
- PostgreSQL sites: the review and apply scripts work unchanged; lock statements look different (advisory locks),
  but the cost of permanently-due tasks is the same.
- Several web/cron nodes: run the scripts once (the settings are in the shared DB); check runners on every node.
- No root/sudo for the operator: the owner can apply the same plan through the admin UI (§3 of the first-server
  runbook was UI-only); the scripts then serve as review and verify.

## 7. Risks and notes
- A plugin enabled again later keeps its task disabled until someone enables it. Write the list of disabled tasks
  into the log entry; the `hygiene` module can re-check it.
- Changes made by direct SQL or by tools that bypass Moodle events now reach cohort/meta enrolments after up to
  15 min (or 1 h with the default).
- Do not combine this with another change in the same hour if the DB measurement is the evidence (core-rules §4).
- Never edit `task_scheduled` with SQL: `configure_scheduled_task` also computes the next run time.
