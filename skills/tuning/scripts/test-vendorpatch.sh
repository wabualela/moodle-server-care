#!/usr/bin/env bash
# test-vendorpatch.sh — tests for vendorpatch.sh on a synthetic Moodle tree (no root, no real vendor files, no
# network). Run it after changing vendorpatch.sh, and once on a new server before the first real patch:
#   bash test-vendorpatch.sh          (needs bash, GNU patch, diff, sha256sum, php; git optional)
# Environment: PHP  PHP binary used for the syntax check (default: php)
# Exit status: 0 when every check passes, 1 otherwise.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
php=${PHP:-php}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
checks=0

ok() { checks=$((checks + 1)); echo "ok   $1"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
expect_rc() { if [ "$1" = "$2" ]; then ok "$3 (exit $2)"; else bad "$3: exit $2, expected $1"; fi; }
same_file() { if cmp -s "$1" "$2"; then ok "$3"; else bad "$3"; fi; }

# Synthetic vendor files (one nested plugin type: course/format), their patched versions, a patch and its pins.
mkdir -p "$work/a/theme/x/classes" "$work/a/course/format/y/classes"
printf '<?php\n$n = count($this->get_enrolled_students($course, $context));\n' > "$work/a/theme/x/classes/one.php"
printf '<?php\nfunction two() {\n    return 2;\n}\n' > "$work/a/course/format/y/classes/two.php"
printf "<?php\n\$plugin->version = 2026010100;\n\$plugin->release = '1.0';\n" > "$work/a/theme/x/version.php"
printf "<?php\n\$plugin->version = 2026020200;\n\$plugin->release = '2.0';\n" > "$work/a/course/format/y/version.php"
cp -r "$work/a" "$work/b"
printf '<?php\n// TEST-PATCH t v1\n$n = 1;\n' > "$work/b/theme/x/classes/one.php"
printf '<?php\nfunction two() {\n    return 22; // TEST-PATCH t v1\n}\n' > "$work/b/course/format/y/classes/two.php"
mkdir -p "$work/vp"
cp "$here/vendorpatch.sh" "$work/vp/"
(cd "$work" && diff -ruN a b) > "$work/vp/test.diff"
{
    echo "# pre post path"
    echo "# marker: TEST-PATCH"
    for f in theme/x/classes/one.php course/format/y/classes/two.php; do
        echo "$(sha256sum "$work/a/$f" | cut -d' ' -f1) $(sha256sum "$work/b/$f" | cut -d' ' -f1) $f"
    done
} > "$work/vp/test.sha256"

# A patch that produces invalid PHP, with correct hashes, to test the syntax gate.
cp -r "$work/a" "$work/c"
printf '<?php\n$n = ;\n' > "$work/c/theme/x/classes/one.php"
(cd "$work" && diff -ruN a/theme c/theme) > "$work/vp/broken.diff"
f=theme/x/classes/one.php
echo "$(sha256sum "$work/a/$f" | cut -d' ' -f1) $(sha256sum "$work/c/$f" | cut -d' ' -f1) $f" > "$work/vp/broken.sha256"

reset_tree() {
    rm -rf "$work/public" "$work/backups"
    cp -r "$work/a" "$work/public"
    chmod 664 "$work/public/theme/x/classes/one.php" "$work/public/course/format/y/classes/two.php"
}
vp() {
    MSC_ENV=/nonexistent VP_ROOT="$work/public" VP_PATCH_DIR="$work/vp" BACKUP_ROOT="$work/backups" ALLOW_NONROOT=1 \
        PHP="$php" bash "$work/vp/vendorpatch.sh" "$@"
}

reset_tree
vp status test >/dev/null; expect_rc 1 $? "status on original files"
out=$(vp status test); echo "$out" | grep -q "release 2.0" && ok "status finds the nested plugin's release" || bad "status finds the nested plugin's release"

out=$(vp apply test 2>&1); expect_rc 0 $? "apply"
same_file "$work/public/theme/x/classes/one.php" "$work/b/theme/x/classes/one.php" "apply: first file patched"
same_file "$work/public/course/format/y/classes/two.php" "$work/b/course/format/y/classes/two.php" "apply: second file patched"
[ "$(stat -c %a "$work/public/theme/x/classes/one.php")" = 664 ] && ok "apply keeps the file mode" || bad "apply keeps the file mode"
[ -z "$(find "$work/public" -name '*.vpnew*')" ] && ok "apply leaves no temporary file" || bad "apply leaves no temporary file"
backup=$(echo "$out" | sed -n 's/^saved the current files in //p')
[ -f "$backup/files/theme/x/classes/one.php" ] && ok "apply saves a backup" || bad "apply saves a backup"
[ -f "$backup/meta/course/format/y/version.php" ] && [ -f "$backup/meta/test.sha256" ] && ok "apply saves the release information" || bad "apply saves the release information"
out=$(vp status test); expect_rc 0 $? "status after apply"
echo "$out" | grep -q "markers 1" && ok "status counts the marker from the pin header" || bad "status counts the marker from the pin header"

out=$(vp apply test 2>&1); expect_rc 0 $? "apply again"
echo "$out" | grep -q "already patched" && ok "apply again does nothing" || bad "apply again does nothing"

vp revert test >/dev/null 2>&1; expect_rc 0 $? "revert"
same_file "$work/public/theme/x/classes/one.php" "$work/a/theme/x/classes/one.php" "revert: first file original"
same_file "$work/public/course/format/y/classes/two.php" "$work/a/course/format/y/classes/two.php" "revert: second file original"
vp status test >/dev/null; expect_rc 1 $? "status after revert"

# A patch given by path instead of name.
vp status "$work/vp/test.diff" >/dev/null; expect_rc 1 $? "status with a path to the .diff"

# Restore from the backup taken by apply, after the live file was damaged.
vp apply test >/dev/null 2>&1
echo "damaged" >> "$work/public/theme/x/classes/one.php"
cp "$work/public/theme/x/classes/one.php" "$work/damaged.php"
out=$(vp restore "$backup" 2>&1); expect_rc 0 $? "restore"
same_file "$work/public/theme/x/classes/one.php" "$work/a/theme/x/classes/one.php" "restore puts the saved file back"
pre=$(echo "$out" | sed -n 's/^saved the current files in //p')
same_file "$pre/files/theme/x/classes/one.php" "$work/damaged.php" "restore keeps the replaced file"

# Restore refuses to put files into another vendor release, unless forced.
echo "// new release" >> "$work/public/theme/x/version.php"
cp "$work/public/theme/x/classes/one.php" "$work/before.php"
vp restore "$backup" >/dev/null 2>&1; expect_rc 2 $? "restore refuses after a vendor upgrade"
same_file "$work/public/theme/x/classes/one.php" "$work/before.php" "refused restore changes nothing"
vp restore "$backup" --force >/dev/null 2>&1; expect_rc 0 $? "restore --force"
mkdir -p "$work/nometa/files/theme/x/classes" && cp "$work/a/theme/x/classes/one.php" "$work/nometa/files/theme/x/classes/"
vp restore "$work/nometa" >/dev/null 2>&1; expect_rc 2 $? "restore refuses a backup without release information"

# A symbolic link in place of a vendor file is never followed.
reset_tree
mv "$work/public/theme/x/classes/one.php" "$work/real-one.php"
ln -s "$work/real-one.php" "$work/public/theme/x/classes/one.php"
vp status test >/dev/null; expect_rc 3 $? "status reports a symbolic link as unknown"
vp apply test >/dev/null 2>&1; expect_rc 2 $? "apply refuses a symbolic link"
same_file "$work/real-one.php" "$work/a/theme/x/classes/one.php" "the link target is untouched"

# A planted *.vpnew link next to a vendor file gains nothing (temporary names are random).
reset_tree
echo "secret" > "$work/victim"; chmod 600 "$work/victim"
ln -s "$work/victim" "$work/public/theme/x/classes/one.php.vpnew"
vp apply test >/dev/null 2>&1; expect_rc 0 $? "apply with a planted .vpnew link"
[ "$(cat "$work/victim")" = secret ] && ok "planted link target untouched" || bad "planted link target untouched"
rm -f "$work/public/theme/x/classes/one.php.vpnew"

# A file that matches neither hash: status says unknown, apply refuses and changes nothing.
reset_tree
echo "// local edit" >> "$work/public/theme/x/classes/one.php"
cp "$work/public/theme/x/classes/one.php" "$work/edited.php"
vp status test >/dev/null; expect_rc 3 $? "status on an edited file"
vp apply test >/dev/null 2>&1; expect_rc 2 $? "apply refuses an edited file"
same_file "$work/public/theme/x/classes/one.php" "$work/edited.php" "refused apply leaves the edited file"
same_file "$work/public/course/format/y/classes/two.php" "$work/a/course/format/y/classes/two.php" "refused apply leaves the other file"

# Half applied: one file patched by hand, the other original.
reset_tree
cp "$work/b/theme/x/classes/one.php" "$work/public/theme/x/classes/one.php"
vp apply test >/dev/null 2>&1; expect_rc 2 $? "apply refuses a half-applied state"
same_file "$work/public/course/format/y/classes/two.php" "$work/a/course/format/y/classes/two.php" "half-applied: other file untouched"

# A patch that breaks PHP syntax is never put live.
reset_tree
vp apply broken >/dev/null 2>&1; expect_rc 2 $? "apply refuses a patch with a PHP syntax error"
same_file "$work/public/theme/x/classes/one.php" "$work/a/theme/x/classes/one.php" "syntax error: live file untouched"

# Without root and without ALLOW_NONROOT, changes are refused.
reset_tree
MSC_ENV=/nonexistent VP_ROOT="$work/public" VP_PATCH_DIR="$work/vp" BACKUP_ROOT="$work/backups" bash "$work/vp/vendorpatch.sh" apply test >/dev/null 2>&1
rc=$?
if [ "$(id -u)" -eq 0 ]; then ok "root check skipped (running as root)"; else expect_rc 2 $rc "apply refuses without root"; fi

# The owner-side swap (runuser) path, with a stand-in for runuser that checks its arguments.
reset_tree
cat > "$work/fake-runuser" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -u ] && [ "$2" = "$(id -un)" ] && [ "$3" = -- ] || { echo "bad runuser arguments: $*" >&2; exit 9; }
shift 3
exec "$@"
EOF
chmod +x "$work/fake-runuser"
VP_TEST_RUNUSER="$work/fake-runuser" vp apply test >/dev/null 2>&1; expect_rc 0 $? "apply through runuser"
same_file "$work/public/theme/x/classes/one.php" "$work/b/theme/x/classes/one.php" "runuser path: file patched"
VP_TEST_RUNUSER="$work/fake-runuser" vp revert test >/dev/null 2>&1; expect_rc 0 $? "revert through runuser"
same_file "$work/public/theme/x/classes/one.php" "$work/a/theme/x/classes/one.php" "runuser path: file reverted"

# pin: writes the hash list from the live files and a staged patched copy; refuses to overwrite; read-only.
reset_tree
cp "$work/vp/test.diff" "$work/vp/new.diff"
cp -a "$work/public" "$work/public-before"
vp pin new >/dev/null 2>&1; expect_rc 0 $? "pin"
diff -r "$work/public" "$work/public-before" >/dev/null && ok "pin does not touch the live tree" || bad "pin does not touch the live tree"
a=$(grep -v '^#' "$work/vp/new.sha256" | sort); b=$(grep -v '^#' "$work/vp/test.sha256" | sort)
[ "$a" = "$b" ] && ok "pin writes the same hashes as the reference list" || bad "pin writes the same hashes as the reference list"
grep -q 'course/format/y: release 2.0' "$work/vp/new.sha256" && ok "pin records the vendor release" || bad "pin records the vendor release"
vp pin new >/dev/null 2>&1; expect_rc 2 $? "pin refuses to overwrite without --force"
vp apply test >/dev/null 2>&1
vp pin new --force >/dev/null 2>&1; expect_rc 2 $? "pin refuses when the patch is already applied"

# Core files tracked by git are refused.
if command -v git >/dev/null; then
    reset_tree
    (cd "$work/public" && git init -q && git add theme/x/classes/one.php && git -c user.email=t@t -c user.name=t commit -qm t) >/dev/null 2>&1
    vp apply test >/dev/null 2>&1; expect_rc 2 $? "apply refuses a file tracked by the core git checkout"
    same_file "$work/public/theme/x/classes/one.php" "$work/a/theme/x/classes/one.php" "git-tracked: live file untouched"
    rm -rf "$work/public/.git"
else
    ok "git not installed: core-file check skipped"
fi

# Unknown patch name; missing pin file.
vp status nosuchpatch >/dev/null 2>&1; expect_rc 2 $? "unknown patch name"
cp "$work/vp/test.diff" "$work/vp/nopin.diff"
vp status nopin >/dev/null 2>&1; expect_rc 2 $? "patch without a pin file"

echo "$((checks - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
