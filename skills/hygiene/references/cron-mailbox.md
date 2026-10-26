# H3: cron output mailed into a local mailbox (the web user's /var/mail growing)

## Why it matters
cron mails a job's output to the crontab owner unless the line redirects it or `MAILTO=""` is set. With a local MTA
(exim4, postfix) the mail lands in `/var/mail/<WEBUSER>`, which nobody reads. A Moodle ad hoc task runner started
every minute without redirection adds one message per minute: the mailbox grows by gigabytes per year, every message
is an MTA delivery (noise in the mail logs and statistics), and the bodies contain task output, which can include
personal data, at rest in a file nobody manages. Stop the growth first (reversible), then decide the old mailbox
(irreversible, the owner's decision).

## Discovery (read-only)
```bash
bash scripts/cron-output-check.sh --sample 120      # job lines marked MAILS-OUTPUT, MAILTO in effect, mailbox size and growth
sudo env LC_ALL=C awk -f scripts/mbox-header-stats.awk /var/mail/<WEBUSER>   # headers only: per month, per subject (= command line)
sudo crontab -u <WEBUSER> -l
grep -rl '/var/log/moodle_cron\|<log dir>' /etc/logrotate.d/                  # is the target log directory rotated?
```
- The subject of each cron mail contains the command line, so the per-subject table maps the growth to the line.
  "minutes with 2+ of the same subject" > 0 means the line is duplicated (two runners started each minute).
- Moodle lines: `admin/cli/cron.php` (scheduled tasks) and `admin/cli/adhoc_task.php --execute --keep-alive=N`
  (dedicated ad hoc runner). On Moodle 5.1+ the CLI is `<MOODLE>/admin/cli/`, not under `public/`.
- `system:mails-if-output` rows (package files in `/etc/cron.d`) mail root only when a job prints an error: leave them.
- **Adapt:** no MTA installed → cron logs "No MTA installed, discarding output" and nothing grows: the item is only
  about adding log files. Postfix: same mailbox path. A different web user (`apache`, `nginx`, `nobody`): use it.
  Mailbox under `/var/spool/mail`: same procedure.

## Decide the target log
- One log file per job, in a directory that logrotate already rotates (or add a stanza: `assets/logrotate-moodle-cron.conf`),
  created `640 <WEBUSER>:<WEBUSER>` so the job can write it and only the web user's group can read it.
- Each cron run reopens the file by name (`>>`), so rotation needs no `copytruncate`.
- Keep `MAILTO=""` at the top as a safety net for lines added later without redirection.

## Proposal (Arabic)
> **صندوق بريد المهام المجدولة:** أحد أسطر المهام المجدولة لمستخدم الويب لا يحوّل مخرجاته إلى ملف، فيرسلها النظام بريداً
> محلياً كل دقيقة إلى ملف لا يقرؤه أحد (حجمه الآن <SIZE> ويزيد نحو <RATE> يومياً)، وقد يحتوي بيانات شخصية من مخرجات
> المهام. أقترح خطوتين منفصلتين:
> 1. (قابلة للتراجع) إضافة `MAILTO=""` وتحويل مخرجات السطر إلى ملف سجل يُدوَّر يومياً بصلاحيات مقيدة. يتوقف النمو فوراً.
> 2. (لا رجعة فيها، قرارك) التعامل مع الصندوق القديم: أرشفة مضغوطة في مجلد لا يقرؤه إلا المدير ثم تفريغه، أو تفريغه
>    مباشرة. سأجهز لك الأمر الدقيق لتنفذه بنفسك بعد أن أتحقق أن لا شيء يكتب فيه.

## Procedure

### Step 1: stop the growth (reversible)
1. **Backup:** `sudo sh -c 'crontab -u <WEBUSER> -l > /root/crontab-<WEBUSER>.bak-<DATE> && chmod 600 /root/crontab-<WEBUSER>.bak-<DATE>'`
2. **Prepare the log file** (so the first run does not create it with the wrong mode):
   ```bash
   sudo install -d -m 750 -o <WEBUSER> -g <WEBUSER> /var/log/moodle_cron          # if it does not exist
   sudo install -m 640 -o <WEBUSER> -g <WEBUSER> /dev/null /var/log/moodle_cron/<site>_adhoc.log
   ```
3. **Change:** build the new crontab in a root-only file, not with an interactive editor, so the diff is reviewable:
   ```bash
   sudo cp /root/crontab-<WEBUSER>.bak-<DATE> /root/crontab-<WEBUSER>.new
   # add MAILTO="" as the first line, then append the redirection to the one line that lacks it:
   sudo python3 -I ../nginx/scripts/replace-once.py --file /root/crontab-<WEBUSER>.new --line \
     --old '<the exact adhoc line>' --new '<the exact adhoc line> >> /var/log/moodle_cron/<site>_adhoc.log 2>&1' \
     --backup /root/crontab-<WEBUSER>.bak-<DATE> --apply
   sudo sed -i '1i MAILTO=""' /root/crontab-<WEBUSER>.new
   sudo diff /root/crontab-<WEBUSER>.bak-<DATE> /root/crontab-<WEBUSER>.new   # only MAILTO and the redirection differ
   ```
4. **Test:** the diff above; `bash -n` is not applicable to crontabs, so read the new file once more for typos in paths.
5. **Apply:** `sudo crontab -u <WEBUSER> /root/crontab-<WEBUSER>.new` (cron reloads it within a minute).
6. **Verify** (after 3–5 minutes; take times from `date`/`stat`):
   - `sudo stat -c '%s %y' /var/mail/<WEBUSER>` stops changing. One more mail can arrive from a runner that started
     under the old crontab (a keep-alive runner lives up to its keep-alive time): wait for it before calling it done.
   - `sudo tail -n 3 /var/log/moodle_cron/<site>_adhoc.log` shows each run.
   - Exactly one runner per minute: `pgrep -fa adhoc_task.php`.
   - The MTA's local deliveries drop (exim: `sudo grep -c ' <= .*U=<WEBUSER>' /var/log/exim4/mainlog`).
7. **Rollback:** `sudo crontab -u <WEBUSER> /root/crontab-<WEBUSER>.bak-<DATE>`.

### Step 2: the old mailbox (irreversible; the owner runs it)
Pre-checks you run yourself:
```bash
sudo stat -c '%s B, last change %y, %U:%G %a' /var/mail/<WEBUSER>     # unchanged for several minutes after step 1
sudo fuser -v /var/mail/<WEBUSER> 2>&1 | tail -n +2                    # no process has it open
df -h /var                                                             # space for an archive, if the owner wants one
```
Then give the owner (Arabic message, `assets/owner-command-ar.md`) one of these exact commands:
- **Archive, then empty** (keep about 30 days, then the owner deletes the archive):
  ```bash
  sudo install -d -m 700 /root/mailbox-cleanup-<DATE> && sudo sh -c 'gzip -c /var/mail/<WEBUSER> > /root/mailbox-cleanup-<DATE>/<WEBUSER>.mbox.gz && gzip -t /root/mailbox-cleanup-<DATE>/<WEBUSER>.mbox.gz' && sudo truncate -s 0 /var/mail/<WEBUSER>
  ```
  (`zstd -q -19 -T0` instead of gzip when installed: faster and smaller.)
- **Empty directly** (no archive; the owner decided the content has no value):
  `sudo truncate -s 0 /var/mail/<WEBUSER>`

Why `truncate` and not `rm`: the file keeps its owner, group and mode (`<WEBUSER>:mail 660`), so local delivery keeps
working exactly as before if anything ever mails that user again.

Verify afterwards: `sudo stat -c '%s %U:%G %a' /var/mail/<WEBUSER>` → `0 <WEBUSER>:mail 660`; `df -h` shows the space back.
Log it as "owner ran it; checked by session <name>".

## Pitfalls
- Changing the crontab with `crontab -e` as root without a saved copy leaves no rollback. Always save first.
- A crontab line duplicated in the past (two identical runners) doubles the load and the mail: check the per-subject
  "2+ per minute" column and `pgrep -fa`, and remove the duplicate in the same change (owner informed).
- Never print message bodies to look for the cause: the header statistics are enough and bodies can hold personal data.
- Do not purge before step 1 is live: the runner would keep appending to a file you think is empty.
