#!/usr/bin/env python3
"""replace-once.py - exact, asserted text replacement in a config file (core-rules section 3).

The one tool every module uses for "change exactly this text" (nginx vhosts, .env files, crontab copies,
authorized_keys). Safer than sed: the old text (or anchor line) must occur EXACTLY ONCE, otherwise nothing is
written. Without --apply it is a dry run that only shows the change. With --apply it refuses unless the backup of
the day exists (<file>.bak-YYYY-MM-DD, optionally with a letter, or --backup PATH), so the backup step cannot be
skipped by accident. Symlinks (sites-enabled entries) are resolved: the real file is edited, never the link.

Usage:
  python3 -I replace-once.py FILE --old 'client_max_body_size 256M;' --new 'client_max_body_size 100M;' [--apply]
  python3 -I replace-once.py FILE --old-file OLD.txt --new-file NEW.txt [--apply] [--backup PATH]
  python3 -I replace-once.py FILE --insert-before 'location ~ [^/]\\.php(/|$) {' --new-file BLOCK.txt [--apply]
  python3 -I replace-once.py --file <APP_DIR>/.env --line --old 'APP_DEBUG=true' --new 'APP_DEBUG=false' --in-place [--apply]

  FILE / --file FILE  the file to edit (both spellings work)
  --line              --old/--new are whole lines (trailing CR/LF ignored); with --new '' the line is deleted
  --insert-before T   insert the new text as whole lines before the single line containing T
  --backup PATH       the backup made for this change (for example a copy in /root/<topic>-YYYY-MM-DD/)
  --no-backup-check   skip the backup check: only for a scratch copy you made yourself (e.g. /root/crontab-x.new)
  --in-place          rewrite the same inode (keeps hard links, ACLs and extended attributes; use it for .env,
                      authorized_keys). Default: temp file with the same mode and owner, renamed over the target.
  --no-context        print only the old and new text, never neighbouring lines. Automatic for files that hold
                      secrets (.env*, *.env, config.php, *.cnf, authorized_keys, names with secret/passwd/credential)
Pass only non-secret text in --old/--new: arguments are visible in the process list and are printed.
Exit codes: 0 ok (dry run shown or applied), 1 text/anchor not found exactly once or backup missing, 2 usage.
"""
import argparse
import datetime
import difflib
import glob
import os
import sys

SECRET_NAMES = ("config.php", "authorized_keys", "authorized_keys2")
SECRET_WORDS = ("secret", "passwd", "password", "credential")


def secretish(path: str) -> bool:
    b = os.path.basename(path).lower()
    return (b.startswith(".env") or b.endswith(".env") or b.endswith(".cnf") or b in SECRET_NAMES
            or any(w in b for w in SECRET_WORDS))


def read_text(path: str) -> str:
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="surrogateescape")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", nargs="?")
    ap.add_argument("--file", dest="file_opt")
    ap.add_argument("--old")
    ap.add_argument("--old-file")
    ap.add_argument("--new")
    ap.add_argument("--new-file")
    ap.add_argument("--insert-before")
    ap.add_argument("--line", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--backup")
    ap.add_argument("--no-backup-check", action="store_true")
    ap.add_argument("--in-place", action="store_true")
    ap.add_argument("--no-context", action="store_true")
    a = ap.parse_args()

    if (a.target is None) == (a.file_opt is None):
        print("give the file once: FILE or --file FILE", file=sys.stderr)
        return 2
    path = a.target if a.target is not None else a.file_opt

    def text(val, fpath, name):
        if fpath is not None and val is not None:
            print(f"give only one of --{name} or --{name}-file", file=sys.stderr)
            sys.exit(2)
        if fpath is not None:
            return read_text(fpath)
        return val

    new = text(a.new, a.new_file, "new")
    old = text(a.old, a.old_file, "old")
    if new is None:
        print("give --new or --new-file", file=sys.stderr)
        return 2
    if (a.insert_before is None) == (old is None):
        print("give exactly one of --old/--old-file or --insert-before", file=sys.stderr)
        return 2
    if a.line and a.insert_before is not None:
        print("--line works with --old, not with --insert-before", file=sys.stderr)
        return 2

    # sites-enabled entries are usually symlinks: edit the real file, never replace the link with a copy.
    real = os.path.realpath(path)
    cur = read_text(real)
    quiet = a.no_context or secretish(real)

    if a.insert_before is not None:
        lines = cur.splitlines(keepends=True)
        idx = [i for i, l in enumerate(lines) if a.insert_before in l]
        if len(idx) != 1:
            print(f"anchor found on {len(idx)} lines (need exactly 1): {a.insert_before!r}", file=sys.stderr)
            return 1
        block = new if new.endswith("\n") else new + "\n"
        out = "".join(lines[: idx[0]]) + block + "".join(lines[idx[0]:])
        count = 1
    elif a.line:
        lines = cur.splitlines(keepends=True)
        idx = [i for i, l in enumerate(lines) if l.rstrip("\r\n") == old]
        count = len(idx)
        out = cur
        if count == 1:
            i = idx[0]
            if new == "":
                del lines[i]                         # --line with an empty --new deletes the line
            else:
                lines[i] = new + lines[i][len(lines[i].rstrip("\r\n")):]
            out = "".join(lines)
    else:
        count = cur.count(old)
        out = cur.replace(old, new, 1) if count == 1 else cur

    if count != 1:
        print(f"{real}: the old text occurs {count} times (need exactly 1); nothing changed", file=sys.stderr)
        return 1

    if quiet:
        print(f"{real}: 1 occurrence (context not shown: file may hold secrets)")
        if a.insert_before is not None:
            print(f"insert before the line containing: {a.insert_before}")
            for l in new.splitlines():
                print(f"+ {l}")
        else:
            for l in old.splitlines() or [""]:
                print(f"- {l}")
            for l in new.splitlines() or ["(line deleted)" if a.line else ""]:
                print(f"+ {l}")
    else:
        sys.stdout.writelines(difflib.unified_diff(cur.splitlines(keepends=True), out.splitlines(keepends=True),
                                                   fromfile=real, tofile=real + " (new)"))
    sys.stdout.flush()
    if not a.apply:
        print("\n(dry run: pass --apply to write)", file=sys.stderr)
        return 0

    if not a.no_backup_check:
        if a.backup:
            found = [a.backup] if os.path.exists(a.backup) else []
        else:
            day = f"{real}.bak-{datetime.date.today().isoformat()}"
            found = [p for p in [day] + sorted(glob.glob(glob.escape(day) + "[a-z]")) if os.path.exists(p)]
        if not found:
            want = a.backup or f"{real}.bak-{datetime.date.today().isoformat()}"
            print(f"backup {want} not found: make it first (core-rules 3.1), or pass --backup PATH", file=sys.stderr)
            return 1
        backup = found[-1]
    else:
        backup = "(not checked: --no-backup-check)"

    data = out.encode("utf-8", errors="surrogateescape")
    if a.in_place:
        with open(real, "r+b") as fh:                # same inode: owner, group, mode, ACLs, xattrs kept
            fh.seek(0)
            fh.write(data)
            fh.truncate()
    else:
        st = os.stat(real)
        tmp = f"{real}.tmp-replace-once-{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, real)
    print(f"\napplied to {real} (backup: {backup})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
