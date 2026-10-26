# <SERVER NAME>: production Moodle server (<SITE>)

This file is read by every Claude Code session on this machine. Install it as `~/.claude/CLAUDE.md` for the operator
account and, with the owner's approval (it is a system change: log it), as `/etc/claude-code/CLAUDE.md` for all users.

Before doing anything on this server, read:
- `<HANDBOOK>`: what runs here, the working rules, locations, the current plan.
- `<LOG>`: the operations log, a record of every change made on this server.

After ANY change on this server (config, package, service restart/reload, Moodle setting, plugin, docroot file,
crontab, DB write, user or permission change), append an entry at the end of section 3 of `<LOG>` before reporting.
Re-read it right before editing (other sessions may be writing at the same time) and only append. Never write secrets
into it.

Live production server: agreed changes only, one at a time, backup, test, verify, rollback ready. The owner works in
Arabic. Operations skills for this server: the `moodle-server-care` plugin (start with `/moodle-server-care:start`).
