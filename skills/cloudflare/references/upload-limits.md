# Upload limits through Cloudflare

## The layers (outermost first)
| Layer | Setting | Default | What the user sees when exceeded |
|---|---|---|---|
| Cloudflare | plan body limit: Free 100 MB, Pro 100 MB, Business 200 MB, Enterprise by contract (verify current numbers on Cloudflare's site) | n/a | Cloudflare "413 Request Entity Too Large" page; the upload bar stops |
| nginx | `client_max_body_size` (http, server or location) | 1m | nginx 413 page |
| Apache | `LimitRequestBody` | 1 GiB since 2.4.54 (unlimited before) | Apache 413 |
| PHP-FPM | `post_max_size`, `upload_max_filesize` (php.ini, conf.d, pool `php_admin_value`) | 8M / 2M | Moodle's error after the full upload, or an empty form |
| Moodle site | `maxbytes` (Site administration → Security → Site security settings → Maximum uploaded file size) | 0 = PHP limit | clear Moodle message before upload starts |
| Moodle course / activity | course "Maximum upload size", assignment/forum limits | ≤ site | clear message |

Moodle computes what it shows from the smallest of PHP's limits and `maxbytes`; it knows nothing about Cloudflare or
nginx. That is why the outer layers should not be lower than what Moodle advertises, and Moodle should not advertise
more than Cloudflare passes.

## Recommended alignment (behind Cloudflare Free/Pro)
- nginx Moodle server block: `client_max_body_size 100M;`
- Moodle `maxbytes`: `104857600` (100 MB). Cloudflare states its limit as "100 MB" and a multipart request is a
  little larger than the file inside it, so a file just under 100 MB can still be refused at the edge. If the owner
  wants zero surprises, use 95 MB (`99614720`) in Moodle and keep nginx at 100M. The first server used 100 MB in both
  places; it was not tested with a file near the limit.
- PHP: leave as is when it is already ≥ the cap; lowering it gains nothing.
- Course and activity limits: unchanged (they cannot exceed the site limit; values above it fall back to it).

A test upload near the limit is a write on the live site: the owner (or a teacher) does it in a hidden test course,
not Claude.

## Large files that no longer fit
- Videos: a video platform (or an unlisted streaming service) with the link in the course; or compress.
- Course backups (`.mbz`) above the limit: copy the file to the server over SFTP and restore with the CLI
  (`<MOODLE>/admin/cli/restore_backup.php --file=... --categoryid=...`, available since Moodle 3.10). The CLI does not
  pass through Cloudflare and has no request time limit. A restore is a write: the owner approves each one.
- A DNS-only "upload" hostname would bypass the cap, but also all protection and the origin lock: not recommended.

## The 100-second timeout
On non-Enterprise plans Cloudflare closes a proxied request that has not started answering within 100 s and shows
524. nginx and PHP may allow much more (`fastcgi_read_timeout 600`). Long admin actions (big course restore, large
report export, bulk user actions) should run as ad-hoc tasks or from the CLI. `cf-discover.sh` flags read timeouts
above 100 s as a reminder. Raising nginx or PHP timeouts does not help through Cloudflare; leave them as they are.

## Apache
`LimitRequestBody 104857600` in the Moodle `<VirtualHost>` (or `<Directory>`), `apache2ctl configtest`, reload.

## Teacher notice
`assets/teacher-upload-notice-ar.md` (Arabic). The owner sends it; it says the new limit, what to do with larger
files, and whom to contact.

## Rollback
nginx: copy back the backup of the resolved vhost file (`$(readlink -f <VHOST>).bak-YYYY-MM-DD`, or the copy in
`/root/cloudflare-<date>/`), `nginx -t`, reload. Moodle: `cfg.php --name=maxbytes --set=<old value>`.
