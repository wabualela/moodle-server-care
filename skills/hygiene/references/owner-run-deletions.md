# Irreversible steps: the owner runs them (the permission-classifier lesson)

## What happened on the first server
The owner approved purging a multi-gigabyte cron mailbox and deleting a CSV of student data. The Claude session's
permission system refused both commands (`truncate` of the mailbox, `rm` of the CSV) as irreversible, even though
the owner had said yes in the conversation. The working pattern that followed, and that this plugin uses everywhere:
1. The session does every read-only pre-check itself (nothing references the file, nothing writes to it, the
   replacement is live, there is space for an archive if one is wanted).
2. The session gives the owner **one exact command**, in a short Arabic message that says what it does, why it is safe
   now, and that it cannot be undone.
3. The owner runs it in their own terminal.
4. The session verifies the result and appends a log entry: "owner ran it; checked by session <name>".

The same system also blocks some reads of personal data (for example querying student phone numbers from the
database). Route such data requests to Moodle's report builder (Site administration → Reports → Report builder),
where the owner exports what they need under Moodle's own permissions.

## Rules
- Never work around a refusal: no `: > file`, `python -c "open(f,'w')"`, `find -delete`, `mv` to `/dev/null`,
  `dd`, a script file that does the same, or splitting the command. A refusal is a signal to hand over, not a puzzle.
- Prefer a reversible step first (move to a root-only archive with `archive-path.sh`), and leave only the final delete
  to the owner, later.
- One command per message, copy-pasteable, with exact paths (no globs unless wrapped in `sudo sh -c '…'` for `/root`).
- Use `--one-file-system` with `rm -rf`, and `truncate -s 0` (not `rm`) for files a service writes to (mailboxes,
  logs), so owner, group and mode stay as the service expects.
- After the owner runs it: verify (`test ! -e`, `stat`, `df`), then log. If the owner ran something different from
  what you gave, record what was actually run.

## Message template
See `../assets/owner-command-ar.md`. Example shape:
> **أمر تنفّذه أنت (لا يمكن التراجع عنه):** يفرّغ صندوق بريد المهام المجدولة القديم (الحجم <SIZE>). تحققت أن السطر
> المسبب أُصلح وأن لا شيء يكتب في الملف منذ <TIME>. انسخ السطر التالي كما هو في الطرفية:
> ```
> sudo truncate -s 0 /var/mail/<WEBUSER>
> ```
> بعد تنفيذه أخبرني لأتحقق وأسجل العملية.
