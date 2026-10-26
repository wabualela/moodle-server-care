#!/usr/bin/env php
<?php
// laravel-config-keydiff.php — compare two Laravel cached config files (bootstrap/cache/config.php) and print ONLY the
// dotted key names that were added, removed or changed. Values are never printed, except for an allow-list of
// non-secret keys (app.env, app.debug) so the expected change can be confirmed.
//
// Usage (run as the app's unprivileged user, never as root: the files are PHP code writable by the app):
//   sudo -u <APP_USER> php laravel-config-keydiff.php OLD_config.php NEW_config.php
//   Copy a root-only backup to a private temp file readable by that user first (see references/laravel-debug.md).
// Exit code: 0 = identical, 1 = differences, 2 = usage or read error.
//
// Why: after switching APP_ENV/APP_DEBUG and rebuilding the cache, the only expected difference is app.env and
// app.debug. Any other changed key means the rebuild picked up something else (an edited .env, a changed config file)
// and must be explained before the change is called done.

if (PHP_SAPI !== 'cli') { exit(2); }
if (function_exists('posix_geteuid') && posix_geteuid() === 0 && !in_array('--allow-root', $argv, true)) {
    fwrite(STDERR, "refusing to run as root: run as the app user (or pass --allow-root if the files are root-only copies)\n");
    exit(2);
}
$args = array_values(array_filter(array_slice($argv, 1), fn($a) => $a !== '--allow-root'));
if (count($args) !== 2) {
    fwrite(STDERR, "usage: php laravel-config-keydiff.php OLD_config.php NEW_config.php\n");
    exit(2);
}

function load_config(string $f): array {
    if (!is_readable($f)) { fwrite(STDERR, "cannot read $f\n"); exit(2); }
    $c = include $f;
    if (!is_array($c)) { fwrite(STDERR, "$f did not return an array\n"); exit(2); }
    return $c;
}

function flatten(array $a, string $prefix = ''): array {
    $out = [];
    foreach ($a as $k => $v) {
        $key = $prefix === '' ? (string)$k : $prefix . '.' . $k;
        if (is_array($v) && $v !== [] && array_keys($v) !== range(0, count($v) - 1)) {
            $out += flatten($v, $key);
        } else {
            $out[$key] = $v;   // lists and scalars compared as a whole
        }
    }
    return $out;
}

$showvalues = ['app.env', 'app.debug'];
$old = flatten(load_config($args[0]));
$new = flatten(load_config($args[1]));

$added = array_diff_key($new, $old);
$removed = array_diff_key($old, $new);
$changed = [];
foreach (array_intersect_key($old, $new) as $k => $v) {
    if ($v !== $new[$k]) { $changed[] = $k; }
}
ksort($added); ksort($removed); sort($changed);

$fmt = function ($k, $v) use ($showvalues) {
    return in_array($k, $showvalues, true) ? $k . ' = ' . var_export($v, true) : $k;
};
printf("keys: old %d, new %d\n", count($old), count($new));
foreach ($changed as $k) {
    if (in_array($k, $showvalues, true)) {
        printf("changed  %s: %s -> %s\n", $k, var_export($old[$k], true), var_export($new[$k], true));
    } else {
        printf("changed  %s\n", $k);
    }
}
foreach (array_keys($added) as $k) { printf("added    %s\n", $fmt($k, $new[$k])); }
foreach (array_keys($removed) as $k) { printf("removed  %s\n", $fmt($k, $old[$k])); }
if (!$changed && !$added && !$removed) { echo "identical\n"; exit(0); }
exit(1);
