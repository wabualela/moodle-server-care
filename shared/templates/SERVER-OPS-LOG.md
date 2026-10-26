# <SERVER NAME> (<SITE>): operations log

Record of every change on this server: configuration, packages, service restarts or reloads, Moodle settings, plugins,
docroot files, crontabs, DB writes, users and permissions. Append new entries at the end of section 3; never edit old
entries (add a correction entry instead). Never write secrets here.

Entry format:
```
### YYYY-MM-DD HH:MM — short title  (session: <session name>, approved by owner: yes/no/n.a.)
- What/why:
- Files/settings touched:
- Backup / rollback:
- Verified:
- Next:
```

## 1. Customised system files (current state)

| File / setting | What it does | Since |
|---|---|---|
| `<path>` | `<purpose>` | `<date>` |

## 2. System events (reboots, automatic upgrades)
- `<date time>`: `<event>`

## 3. Log (oldest first; append new entries at the end)
