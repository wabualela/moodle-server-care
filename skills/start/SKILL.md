---
name: start
description: >-
  Entry point for caring for a production Moodle server: discovers the server read-only, sets up the server
  handbook, operations log and CLAUDE.md, and recommends which module to run next (audit, cloudflare, mail,
  nginx, tuning, hygiene, backup, maintenance, monitoring). Use it whenever work begins on a Moodle server that
  has not been set up with these skills, when the user asks to apply "what we did on the other server" to a new
  one, asks what to do next on a Moodle server, mentions slowness, security, backups or maintenance of a Moodle
  site, or opens a session on a new Moodle host — even if they do not name the plugin.
---

# Moodle server care: start here

This plugin packages a proven, careful method for remediating and operating production Moodle servers. It is modular:
the owner may run the whole sequence on a new server or only one module (for example only `mail`).

First read `../../shared/core-rules.md` (relative to this file). Every module depends on it; the most important parts
are the change protocol (backup → change → test → apply → verify → log → report) and the secrets rules.

## Step 1: discover (read-only)
Run `bash scripts/detect-env.sh [MOODLE_DIR]` from this skill's directory. It prints a summary and writes non-secret
facts to `~/.config/moodle-server-care/server.env`, which the other modules read. If several Moodle sites exist it
lists them; ask the owner which one, then rerun with that directory.

Also measure the quiet hours before planning any change: `sudo bash ../audit/scripts/quiet-hours.sh --days 14` (needs gawk;
install it or ask). Then look for existing operations documents: `~/SERVER-HANDBOOK.md`, `~/SERVER-OPS-LOG.md`, `~/.claude/CLAUDE.md`,
`/etc/claude-code/CLAUDE.md`, or older names those files point to. If they exist, read them fully before anything else.

## Step 2: set up the operations documents (only if missing)
These files are how every future session (and the owner) knows what was done. Propose creating them; on approval:
- `~/SERVER-HANDBOOK.md` from `../../shared/templates/SERVER-HANDBOOK.md`, filled with the discovery results.
- `~/SERVER-OPS-LOG.md` from `../../shared/templates/SERVER-OPS-LOG.md`; first entry: "documents created". Backfill
  section 2 with system events you can see read-only (`/var/log/apt/history.log`, `journalctl --list-boots`,
  `last -x reboot`), marked "(origin unverified)" when you cannot tell who did it.
- `~/.claude/CLAUDE.md` from `../../shared/templates/CLAUDE.md` (merge if one exists; never overwrite the user's own
  content). Installing the same text system-wide in `/etc/claude-code/CLAUDE.md` is a system change: ask, then log it.
Creating files in the operator's home is low risk but still gets a log entry.

## Step 3: recommend the next module
Show the owner (in Arabic) a short table: each module, whether it applies to this server based on discovery, and the
recommended order. Default order on a server not yet examined:

| Order | Module | Use when |
|---|---|---|
| 1 | `audit` | Always first on a new server: read-only performance/security audit, 48 h monitor, team report |
| 2 | `monitoring` | No alerting yet: external uptime checks (UptimeRobot) plus a one-minute on-server health check reporting to healthchecks.io → Telegram. Worth doing early: the first server learned about an outage from student complaints |
| 3 | `cloudflare` | The site is (or will be) behind Cloudflare: real client IP, cache rules, upload limit, SSL, renewal test |
| 4 | `mail` | Moodle sends SMTP directly (pages wait for the mail server); SPF/DKIM/DMARC and bounce domain |
| 5 | `nginx` | Scanner floods, missing default server, no request limits |
| 6 | `tuning` | Moodle-side speed: scheduled tasks, static caching, slow counters, plugin installs, vendor patches |
| 7 | `hygiene` | Failing timers, dead certificates, log rotation, cron mailboxes, debug modes, secrets permissions, abandoned projects |
| 8 | `backup` | No off-provider encrypted backup yet (SharePoint/Microsoft 365 or S3-compatible such as R2) |
| 9 | `maintenance` | Pending reboot (kernel/OpenSSL), Redis/DB password changes, unattended-upgrade timing: one announced night |

Skip what does not apply and say why. Each module starts with read-only discovery and a proposal; nothing changes
without the owner's approval.

## Running only part of the work
If the owner names a module ("run mail on this server"), still do Step 1 (discovery) and read the handbook/log, then
go straight to that module's skill: `/moodle-server-care:<module>`.

## What "done" looks like for a server
- Handbook and log exist and are current; every change has a log entry with backup, rollback and evidence.
- The audit report is shared with the team, and each fix has a status (done / partial / scheduled / owner decision).
- Backups run nightly off-provider, encrypted, alerting on failure, with a restore test on record.
