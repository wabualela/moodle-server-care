# Installing the on-server check (layer 2): exact steps

Loaded on demand from SKILL.md. Every step: backup → change → test → apply → verify → log, rollback written first
(core-rules §3). `scripts/install.sh` enforces the order; each change step prints its plan and does nothing without
`--yes`. Run it from this module's `scripts/` directory.

## Contents
1. The order and why it matters
2. Before any test: the URL-file rule
3. Step by step
4. Upgrading the script later
5. Removing it
6. Without the installer (manual equivalent)

## 1. The order and why it matters
```
discover → plan → install (timer OFF) → baseline + dry run → owner: healthchecks check + URL file → enable → verify
```
- **Baseline before the URL.** Healthy Moodle sites usually have status checks that already fail (environment
  recommendations, router configuration, an optional antivirus...). Without a recorded baseline, the first real run
  reports each of them as a new critical problem and the owner gets an alert the minute monitoring starts.
- **Dry run before the URL.** It shows exactly what the timer would report, sends nothing, and writes no state.
  Enable only when it is clean or the owner accepted each remaining line.
- **The owner writes the URL last**, with a no-echo command; Claude checks only that the file exists, is root 600 and
  holds one https line. From the moment that file exists, any non-dry run on this server can send a real alert.

## 2. Before ANY test: the URL-file rule
On the first server a session tested the confirmation logic with a deliberately failing config three minutes after
the owner had saved the URL. Two `/fail` pings reached healthchecks.io and the owner got a false DOWN alert on
Telegram. Therefore, before running the script in any mode other than `--dry-run`, `--self-check`, `--status`:
1. Use the harness: `bash scripts/selftest.sh <scratch dir>` (mocks, ping sink, URL path that must not exist).
2. For a hand test, set all three overrides and a sink, and check the URL path does not exist:
   ```bash
   M=$(mktemp -d)        # private scratch dir for the hand test
   export MOODLE_HEALTH_URLFILE=$M/no-such-url MOODLE_HEALTH_STATE=$M/state \
          MOODLE_HEALTH_CONF=$M/conf MOODLE_HEALTH_PING_SINK=$M/sink.jsonl
   test ! -e "$MOODLE_HEALTH_URLFILE" && echo "safe to test"
   ```
   The script also refuses to send when CONF or STATE is overridden without URLFILE, but do not rely on that alone.
3. Never read, print, copy or `cat` `/etc/default/moodle-health.url`. Never run `--test-fail` unless the owner asked
   for a test alert at that moment.

## 3. Step by step
### 3.1 Discover (read-only)
```bash
bash ../start/scripts/detect-env.sh          # if ~/.config/moodle-server-care/server.env is missing or older than a day
bash scripts/discover.sh                     # existing monitoring, tools, logs, MTA, proxy ranges, other vhosts
bash scripts/discover.sh --net               # adds a DNS lookup of hc-ping.com (nothing is pinged)
```
Stop and ask when discovery shows: another monitoring agent already alerting the owner (do not duplicate; ask),
an existing `moodle-health` install (upgrade path §4), no systemd, python3 < 3.7, no curl.

### 3.2 Plan (read-only; writes only the staging dir in the operator's home)
```bash
bash scripts/install.sh plan
```
It renders `moodle-health.default`, the service and the timer for this server into
`~/.cache/moodle-server-care/monitoring-stage/`, runs `--self-check` and a preview `--dry-run` against the staged
config (probes only; Moodle status-check lines are expected before the baseline) and lists the files it would write.
Review with the owner, in particular `SERVICES` (only what must stay up), `EXTRA_SITES` (dead vhosts are left out
and listed), thresholds. Edit the staged file if needed; `install` takes the staged config as it is.

### 3.3 Install (change; timer stays off)
- Backup: automatic for any existing file → `/root/moodle-health-YYYY-MM-DD/` (700; a letter is added for a second
  copy the same day). New install: nothing to back up.
- Change: `sudo bash scripts/install.sh install` (shows the plan) → owner approves → `... install --yes`.
- Test: python parse check, `systemd-analyze verify` of both units, then a dry run of the installed script (on an
  upgrade a failing dry run restores the previous script automatically).
- Apply: `systemctl daemon-reload` (the timer is NOT enabled).
- Verify: `ls -l /usr/local/sbin/moodle-health /etc/default/moodle-health /etc/systemd/system/moodle-health.*`
  (755 / 644 / 644), `systemctl is-enabled moodle-health.timer` → disabled.
- Rollback: remove the four files (or restore them from the backup folder), `systemctl daemon-reload`.

### 3.4 Baseline + dry run (writes only `/var/lib/moodle-health`; sends nothing)
`sudo bash scripts/install.sh baseline --yes`. It prints the refs recorded as known (each is a real, already
existing Moodle warning: list them for the owner), the dry run and the self-check. Required result: "Dry run clean",
or every CRITICAL line explained and either fixed or explicitly accepted by the owner.

### 3.5 Owner: healthchecks.io check, Telegram, URL file
Send `owner-steps-ar.md` §1–§3 (Arabic). Then `bash scripts/install.sh url-command` prints the exact no-echo command
for this server; the owner runs it in his own SSH session. Afterwards verify without reading the content:
```bash
sudo stat -c '%U %a %s bytes' /etc/default/moodle-health.url        # root 600, about 50-90 bytes
sudo grep -c '^https://' /etc/default/moodle-health.url             # 1
```

### 3.6 Enable (change; owner go-ahead at that moment)
`sudo bash scripts/install.sh enable` (pre-checks only) → `... enable --yes`. Pre-checks: baseline recorded, URL file
root 600 with one https line, dry run clean (or `--accept-critical` after the owner accepted the lines). Then
`systemctl enable --now moodle-health.timer`; it waits for the first run and prints `--status`.
- Verify (evidence): `last.json` status ok and `ping: sent`; `systemctl list-timers moodle-health.timer` shows the
  next run; the owner sees the check turn green in healthchecks.io with body "all checks OK" (or known warnings).
- Rollback: `sudo systemctl disable --now moodle-health.timer`, and the owner pauses the check (otherwise the missing
  pings alert after the grace time).

### 3.7 End-to-end alert test (optional, owner decides the time)
The owner should see once what an alert looks like on his phone. Only with his go-ahead at that moment:
`sudo /usr/local/sbin/moodle-health --test-fail` sends one failure ("TEST alert ... No action needed") and, 5 s later,
a recovery. Tell the owner the exact minute beforehand. Log it.

### 3.8 Log and handbook
Log entry (SKILL.md §7), add the four files to the log's "customised files" table, add to the handbook: where the
check lives, how to mute, what each alert means, and the healthchecks/UptimeRobot accounts' owner (not credentials).

## 4. Upgrading the script later
`bash scripts/install.sh plan` (shows a diff of the config: the installed config is KEPT unless `--replace-config`)
→ `sudo bash scripts/install.sh install --yes`. The timer keeps running; the new script is used from the next
minute, and the installer's dry run restores the old script if the new one fails. After a version that changes how
Moodle check messages are hashed (this module's 1.0.0 normalises digits), re-run `--baseline` right after the
upgrade, before the next 15-minute refresh, or the known checks show as "different message".

## 5. Removing it
The owner first pauses or deletes the healthchecks.io check (and pauses dependent UptimeRobot monitors), otherwise
the missing pings alert. Then `sudo bash scripts/install.sh uninstall --yes`: the timer is disabled and every file,
the URL file and the state directory move to `/root/moodle-health-removed-YYYY-MM-DD/` (700). The owner deletes that
folder after about 30 days (it holds the URL, a secret).

## 6. Without the installer (manual equivalent)
Only if the installer cannot run (unusual layout). Same order, by hand:
```bash
sudo install -m 755 -o root -g root scripts/moodle-health /usr/local/sbin/moodle-health
sudo install -m 644 -o root -g root <reviewed config> /etc/default/moodle-health
sudo install -m 644 -o root -g root assets/moodle-health.service assets/moodle-health.timer /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/moodle-health.service /etc/systemd/system/moodle-health.timer
sudo systemctl daemon-reload
sudo /usr/local/sbin/moodle-health --baseline && sudo /usr/local/sbin/moodle-health --dry-run
# owner writes the URL (url-command text), then:
sudo systemctl enable --now moodle-health.timer
```
