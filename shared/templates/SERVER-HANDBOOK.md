# <SERVER NAME>: <SITE> (Moodle <VERSION>) — server handbook

Read this file before doing anything on this server, together with the operations log `<LOG>`. Update it at the end of
every work session.

## 1. What this server is
- Host: `<hostname>`, provider/region `<provider, region>`, public IPv4 `<ORIGIN_IP>`.
- Moodle `<VERSION>` at `<MOODLE>` (web root `<DOCROOT>`), data `<DATAROOT>`, DB `<dbtype>` `<dbname>`.
- Stack: `<web server + version>`, `<PHP versions and FPM pools>`, `<DB server>`, `<cache: Redis/none>`, `<MTA>`.
- CDN/proxy: `<Cloudflare yes/no, since when, SSL mode>`.
- Other sites on this server: `<vhost list with one line each>`.
- Quiet hours (measured): `<HH–HH local>`.

## 2. Rules for working here
The plugin rules apply (`moodle-server-care/shared/core-rules.md`). Server-specific additions:
- `<e.g. who approves what, maintenance announcement channel, files that must never be touched>`

## 3. History (most recent last)
- `<date>`: `<what happened, one line, pointer to the log entry>`

## 4. Where things are
| What | Where |
|---|---|
| Operations log | `<LOG>` |
| Audit data / reports | `<path>` |
| Runbooks and scripts for this server | `<path>` |
| Backups of edited files | `*.bak-YYYY-MM-DD` next to each file, `/root/<topic>-YYYY-MM-DD/` |

## 5. Plan and to-do list
- [ ] `<item>` (module, date, owner decision needed?)

## 6. Memory and tracking
- `<Claude memory files, task tracker links>`
