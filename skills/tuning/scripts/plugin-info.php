<?php
// plugin-info.php — READ-ONLY pre-flight for installing or upgrading one Moodle plugin (moodle-server-care "tuning").
// Called by install-plugin.sh; can also be run alone. Reads the NEW plugin's version.php as text (it is never
// executed), asks the site where that plugin type lives and what is installed, and checks versions and dependencies.
//
// Usage (as the web user): php plugin-info.php --moodle=DIR --source=STAGED_PLUGIN_DIR
// Output: KEY=value lines (COMPONENT, TARGET, INSTALLED, NEW, RELEASE, MATURITY, REQUIRES, SITEVERSION, BRANCH,
//         ACTION=install|upgrade|same|downgrade), then WARN/ERROR lines. Exit 0 = OK to proceed, 1 = an ERROR.

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'source:', 'help']);
if (isset($opts['help']) || empty($opts['moodle']) || empty($opts['source'])) {
    fwrite(STDERR, "usage: php plugin-info.php --moodle=DIR --source=PLUGIN_DIR\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
$src = rtrim($opts['source'], '/');
$vf = "$src/version.php";
if (!is_readable($vf)) {
    fwrite(STDERR, "plugin-info: cannot read $vf\n");
    exit(2);
}
$text = file_get_contents($vf);
$get = function (string $key) use ($text): ?string {
    if (preg_match('/\$plugin->' . $key . '\s*=\s*([\'"]?)([^\'";]+)\1\s*;/', $text, $m)) {
        return trim($m[2]);
    }
    return null;
};
$component = $get('component');
$newversion = $get('version');
$requires = $get('requires');
$release = $get('release');
$maturity = $get('maturity');
$supported = null;
if (preg_match('/\$plugin->supported\s*=\s*\[\s*(\d+)\s*,\s*(\d+)\s*\]/', $text, $m)) {
    $supported = [(int)$m[1], (int)$m[2]];
}
$deps = [];
if (preg_match('/\$plugin->dependencies\s*=\s*(?:array\s*\(|\[)(.*?)(?:\)|\])\s*;/s', $text, $m)) {
    preg_match_all('/[\'"]([a-z][a-z0-9_]+)[\'"]\s*=>\s*([0-9.]+|ANY_VERSION)/', $m[1], $dm, PREG_SET_ORDER);
    foreach ($dm as $d) {
        $deps[$d[1]] = $d[2];
    }
}

if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "plugin-info: cannot read $moodle/config.php\n");
    exit(2);
}
require("$moodle/config.php");

$errors = [];
$warns = [];
if (!$component || !preg_match('/^[a-z][a-z0-9]*_[a-z][a-z0-9_]*$/', $component)) {
    $errors[] = 'version.php has no valid $plugin->component (needed to know where the plugin goes)';
}
if (!$newversion || !preg_match('/^\d{10}(\.\d+)?$/', $newversion)) {
    $errors[] = 'version.php has no valid $plugin->version (YYYYMMDDXX)';
}
$target = '';
$installed = '';
$action = '?';
if (!$errors) {
    [$type, $name] = explode('_', $component, 2);
    $types = core_component::get_plugin_types();
    if (!isset($types[$type])) {
        $errors[] = "plugin type '$type' does not exist on this Moodle version";
    } else {
        $target = $types[$type] . '/' . $name;
        $info = core_plugin_manager::instance()->get_plugin_info($component);
        $installed = $info && $info->versiondb ? (string)$info->versiondb : '';
        if ($installed === '') {
            $action = 'install';
        } else if ((float)$newversion > (float)$installed) {
            $action = 'upgrade';
        } else if ((float)$newversion == (float)$installed) {
            $action = 'same';
            $warns[] = 'the same version is already installed: only files would change, no upgrade step runs';
        } else {
            $action = 'downgrade';
            $errors[] = "the new version $newversion is OLDER than the installed $installed: Moodle refuses downgrades";
        }
        if ($installed === '' && is_dir($target)) {
            $warns[] = "$target exists on disk but the plugin is not installed in the database (half-finished install?)";
        }
        if ($info && $info->versiondisk && $installed !== '' && (string)$info->versiondisk !== $installed) {
            $errors[] = "files on disk ($info->versiondisk) and database ($installed) already differ: an upgrade is pending; finish or roll it back first";
        }
    }
}
if ($requires && (float)$requires > (float)$CFG->version) {
    $errors[] = "requires Moodle $requires, this site is $CFG->version";
}
if ($supported && !empty($CFG->branch)) {
    $b = (int)$CFG->branch;
    if ($b < $supported[0] || $b > $supported[1]) {
        $warns[] = "declares supported branches {$supported[0]}-{$supported[1]}, this site is branch $b";
    }
}
if ($maturity && $maturity !== 'MATURITY_STABLE') {
    $warns[] = "maturity is $maturity (not stable): the CLI upgrade needs --allow-unstable; prefer a stable release";
}
foreach ($deps as $dep => $ver) {
    $di = core_plugin_manager::instance()->get_plugin_info($dep);
    $have = $di && $di->versiondb ? (string)$di->versiondb : '';
    if ($have === '') {
        $errors[] = "dependency $dep is not installed";
    } else if ($ver !== 'ANY_VERSION' && (float)$have < (float)$ver) {
        $errors[] = "dependency $dep is $have, needs $ver";
    }
}

$out = ['COMPONENT' => $component, 'TARGET' => $target, 'INSTALLED' => $installed, 'NEW' => $newversion,
    'RELEASE' => $release, 'MATURITY' => $maturity, 'REQUIRES' => $requires, 'SITEVERSION' => $CFG->version,
    'BRANCH' => $CFG->branch ?? '', 'ACTION' => $action];
foreach ($out as $k => $v) {
    echo "$k=" . preg_replace('/[^A-Za-z0-9_.\/: -]/', '', (string)$v) . "\n";
}
foreach ($warns as $w) {
    echo "WARN $w\n";
}
foreach ($errors as $e) {
    echo "ERROR $e\n";
}
exit($errors ? 1 : 0);
