<?php
// rename-theme-file.php — find and rename stored theme/plugin setting files whose names contain spaces or other
// URL-unsafe characters (moodle-server-care, module "tuning"). DRY RUN by default.
//
// Why: a file name with a space ("Logo final.svg") reaches the browser as %20, and some clients, proxies and
// page-builder copies double-encode it (%2520). Every such failing request boots Moodle and returns 404. On the
// first server a theme favicon caused dozens of 404s a day. Renaming the stored file (same content) removes the problem.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php rename-theme-file.php --moodle=DIR --component=theme_x                 list unsafe names (read-only)
//   php rename-theme-file.php --moodle=DIR --component=theme_x --filearea=A --from="Logo final.svg" --to=favicon.svg
//                             [--itemid=0] [--setting=A] [--no-cache-reset] [--execute]
//   Rollback: run again with --from and --to swapped (--to may contain spaces then).
//
// What --execute does: copies the stored file under the new name (same content hash, so no new file content),
// deletes the old file record, updates the plugin setting when it points at the old name ("/old" -> "/new"), and
// for theme_* components resets theme caches (new theme revision: every visitor downloads CSS again and a CDN
// re-caches it, so do it in a quiet hour). System context only (where theme and site settings keep their files).

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'component:', 'filearea:', 'itemid:', 'setting:', 'from:', 'to:', 'no-cache-reset',
    'execute', 'help']);
if (isset($opts['help']) || empty($opts['moodle']) || empty($opts['component'])) {
    fwrite(STDERR, "usage: php rename-theme-file.php --moodle=DIR --component=C [--filearea=A --from=OLD --to=NEW " .
        "[--itemid=0] [--setting=A] [--no-cache-reset] [--execute]]\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "rename-theme-file: cannot read $moodle/config.php\n");
    exit(2);
}
$component = $opts['component'];
if (!preg_match('/^[a-z][a-z0-9]*_[a-z0-9_]+$/', $component)) {
    fwrite(STDERR, "rename-theme-file: '$component' is not a component name like theme_boost\n");
    exit(2);
}
require("$moodle/config.php");

$fs = get_file_storage();
$ctx = context_system::instance();
$unsafe = fn(string $n): bool => (bool)preg_match('/[^A-Za-z0-9._-]/', $n);
$safename = function (string $n): string {
    $n = preg_replace('/[^A-Za-z0-9._-]+/', '-', $n);
    $n = preg_replace(['/-+/', '/-+\./'], ['-', '.'], $n);
    return trim($n, '-.') ?: 'file';
};

if (empty($opts['from'])) {
    // Discovery: files of this component in the system context with unsafe names, and settings pointing at them.
    echo "== stored files of $component (system context) with unsafe names (read-only) ==\n";
    $files = $DB->get_records_select('files', "contextid = ? AND component = ? AND filename <> '.'",
        [$ctx->id, $component], 'filearea, itemid, filename', 'id, filearea, itemid, filepath, filename, filesize, mimetype');
    $found = 0;
    foreach ($files as $f) {
        if (!$unsafe($f->filename)) {
            continue;
        }
        $found++;
        $setting = get_config($component, $f->filearea);
        printf("  filearea=%s itemid=%d name=\"%s\" %d B %s; setting %s = %s\n", $f->filearea, $f->itemid,
            $f->filename, $f->filesize, $f->mimetype, $f->filearea, var_export($setting, true));
        printf("    propose: --filearea=%s --itemid=%d --from=%s --to=%s\n", $f->filearea, $f->itemid,
            escapeshellarg($f->filename), escapeshellarg($safename($f->filename)));
    }
    echo "  files with unsafe names: $found (of " . count($files) . ")\n";
    exit(0);
}

foreach (['filearea', 'to'] as $need) {
    if (empty($opts[$need])) {
        fwrite(STDERR, "rename-theme-file: --$need is required with --from\n");
        exit(2);
    }
}
$filearea = $opts['filearea'];
$itemid = (int)($opts['itemid'] ?? 0);
$setting = $opts['setting'] ?? $filearea;
$from = $opts['from'];
$to = $opts['to'];
if ($to === $from || strpos($to, '/') !== false || $to === '' || $to[0] === '.') {
    fwrite(STDERR, "rename-theme-file: --to must be a plain new file name\n");
    exit(2);
}
$execute = isset($opts['execute']);

$files = $fs->get_area_files($ctx->id, $component, $filearea, $itemid, 'filepath, filename', false);
echo "== $component / $filearea / item $itemid (system context) ==\n";
$old = null;
foreach ($files as $f) {
    printf("  file: %s%s %d B %s hash %s\n", $f->get_filepath(), $f->get_filename(), $f->get_filesize(),
        $f->get_mimetype(), substr($f->get_contenthash(), 0, 12));
    if ($f->get_filename() === $from) {
        if ($old) {
            echo "REFUSED: more than one file named \"$from\" in this area; nothing done\n";
            exit(2);
        }
        $old = $f;
    }
}
if (!$old) {
    foreach ($files as $f) {
        if ($f->get_filename() === $to) {
            echo "already renamed: \"$to\" exists and \"$from\" does not\n";
            exit(0);
        }
    }
    echo "REFUSED: no file named \"$from\" here; nothing done\n";
    exit(2);
}
$path = $old->get_filepath();
if ($fs->file_exists($ctx->id, $component, $filearea, $itemid, $path, $to)) {
    echo "REFUSED: \"$path$to\" already exists; nothing done\n";
    exit(2);
}
$cur = get_config($component, $setting);
$newsetting = null;
if ($cur === $path . $from || $cur === $from) {
    $newsetting = ($cur === $from) ? $to : $path . $to;
}
echo "setting $component | $setting = " . var_export($cur, true) .
    ($newsetting !== null ? " -> '$newsetting'" : ' (does not point at this file: unchanged)') . "\n";
$reset = strpos($component, 'theme_') === 0 && !isset($opts['no-cache-reset']);
echo 'theme caches: ' . ($reset ? 'reset after the rename (new revision; quiet hour)' : 'not reset') . "\n";
if (!$execute) {
    echo "dry run: would rename \"$path$from\" -> \"$path$to\" (same content); add --execute\n";
    exit(0);
}
$new = $fs->create_file_from_storedfile(['filename' => $to], $old);
if ($new->get_contenthash() !== $old->get_contenthash()) {
    echo "FAILED: the copy has a different content hash; the old file was kept\n";
    exit(1);
}
$old->delete();
if ($newsetting !== null) {
    set_config($setting, $newsetting, $component);
}
if ($reset) {
    theme_reset_all_caches();
}
echo "renamed: \"$path$to\" hash " . substr($new->get_contenthash(), 0, 12) . '; setting = ' .
    var_export(get_config($component, $setting), true) . ($reset ? '; theme caches reset' : '') . "\n";
echo "rollback: same command with --from=" . escapeshellarg($to) . ' --to=' . escapeshellarg($from) . "\n";
