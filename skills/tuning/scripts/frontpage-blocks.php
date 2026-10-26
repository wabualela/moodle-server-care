<?php
// frontpage-blocks.php — READ-ONLY inventory of the blocks on the site front page (moodle-server-care, "tuning").
//
// For every block on the front page it prints: id, type, region, weight, visibility, stored HTML size, number of
// <script> tags, repeated script sources, external script hosts, and the [shortcodes] it contains. Use it for:
//   - slow front page: page-builder shortcodes that count enrolments on every render (Edwiser "edwiser-fc");
//   - heavy front page: page builders that saved copies of the live DOM, including tracking scripts, many times.
// It prints counts and names only, never the HTML itself.
//
// Usage (as the web user; run-as-web.sh copies the script to /tmp and adds --moodle):
//   php frontpage-blocks.php --moodle=DIR

define('CLI_SCRIPT', true);
$opts = getopt('', ['moodle:', 'help']);
if (isset($opts['help']) || empty($opts['moodle'])) {
    fwrite(STDERR, "usage: php frontpage-blocks.php --moodle=DIR\n");
    exit(2);
}
$moodle = rtrim($opts['moodle'], '/');
if (!is_readable("$moodle/config.php")) {
    fwrite(STDERR, "frontpage-blocks: cannot read $moodle/config.php\n");
    exit(2);
}
require("$moodle/config.php");

$known = [
    'edwiser-fc' => 'Edwiser page builder course cards: counts the students of every card by loading all enrolled ' .
        'users, on every render, guests included (see references/frontpage-counters.md)',
];
$sys = context_system::instance();
$front = context_course::instance(SITEID);
$rows = $DB->get_records_select('block_instances',
    "parentcontextid = ? OR (parentcontextid = ? AND pagetypepattern IN ('site-index', '*'))",
    [$front->id, $sys->id], 'defaultregion, defaultweight, id',
    'id, blockname, parentcontextid, pagetypepattern, defaultregion, defaultweight, configdata, timemodified');

$strings = function ($v) use (&$strings): array {
    if (is_string($v)) {
        return [$v];
    }
    $out = [];
    if (is_array($v) || is_object($v)) {
        foreach ((array)$v as $x) {
            $out = array_merge($out, $strings($x));
        }
    }
    return $out;
};

echo '== front-page blocks (read-only) ' . date('Y-m-d H:i:s T') . ' on ' . $CFG->wwwroot . " ==\n";
$totalscripts = 0;
$allshort = [];
foreach ($rows as $r) {
    $cfg = null;
    if (!empty($r->configdata)) {
        $raw = base64_decode($r->configdata, true);
        $cfg = $raw === false ? null : @unserialize($raw, ['allowed_classes' => ['stdClass']]);
    }
    $text = implode("\n", $strings($cfg));
    $scripts = preg_match_all('/<script\b/i', $text);
    $totalscripts += $scripts;
    preg_match_all('/<script\b[^>]*\bsrc\s*=\s*["\']([^"\']+)["\']/i', $text, $m);
    $srcs = array_count_values(array_map(fn($u) => preg_replace('/[?#].*$/', '', $u), $m[1]));
    arsort($srcs);
    $dupes = array_filter($srcs, fn($n) => $n > 1);
    $hosts = [];
    foreach (array_keys($srcs) as $u) {
        $h = parse_url((strpos($u, '//') === 0 ? 'https:' : '') . $u, PHP_URL_HOST);
        if ($h) {
            $hosts[$h] = ($hosts[$h] ?? 0) + $srcs[$u];
        }
    }
    $inline = [];
    foreach (['hotjar', 'googletagmanager', 'gtag(', 'fbq(', 'connect.facebook.net', 'analytics.tiktok.com', 'ttq.'] as $sig) {
        $c = substr_count($text, $sig);
        if ($c) {
            $inline[] = "$sig x$c";
        }
    }
    preg_match_all('/\[([a-z][a-z0-9_-]{2,40})(?=[\s\]])[^\]\[]{0,400}\]/i', $text, $sm);
    preg_match_all('/data-shortcode\s*=\s*["\']([a-z0-9_-]+)["\']/i', $text, $dm);
    // CSS attribute selectors such as [data-aos] or [hidden] look like shortcodes: drop HTML attribute names.
    $notshort = '/^(data-|aria-)|^(hidden|disabled|checked|selected|readonly|required|href|src|dir|lang|role|class|id|style|type|name|title|alt)$/i';
    $short = array_count_values(array_merge(preg_grep($notshort, $sm[1], PREG_GREP_INVERT), $dm[1]));
    foreach ($short as $k => $n) {
        $allshort[$k] = ($allshort[$k] ?? 0) + $n;
    }
    $pos = $DB->get_records('block_positions', ['blockinstanceid' => $r->id], '', 'id, pagetype, visible');
    $hidden = array_filter($pos, fn($p) => empty($p->visible));
    printf("\nblock %d %s  region %s weight %d  page %s  %s  modified %s\n", $r->id, $r->blockname, $r->defaultregion,
        $r->defaultweight, $r->pagetypepattern, $hidden ? 'HIDDEN on ' . implode(',', array_map(fn($p) => $p->pagetype, $hidden)) : 'visible',
        $r->timemodified ? date('Y-m-d', (int)$r->timemodified) : '?');
    printf("  stored text %d B, <script> tags %d, external script hosts: %s\n", strlen($text), $scripts,
        $hosts ? implode(', ', array_map(fn($h, $n) => "$h x$n", array_keys($hosts), $hosts)) : '-');
    if ($dupes) {
        echo '  repeated script sources: ' . implode(', ', array_map(fn($u, $n) => basename($u) . " x$n", array_keys($dupes), $dupes)) . "\n";
    }
    if ($inline) {
        echo '  tracking signatures: ' . implode(', ', $inline) . "\n";
    }
    if ($short) {
        echo '  shortcodes: ' . implode(', ', array_map(fn($k, $n) => "[$k] x$n", array_keys($short), $short)) . "\n";
        foreach (array_keys($short) as $k) {
            if (isset($known[strtolower($k)])) {
                echo "    !! [$k]: " . $known[strtolower($k)] . "\n";
            }
        }
    }
}
printf("\nblocks: %d, <script> tags in stored block text: %d, shortcodes: %s\n", count($rows), $totalscripts,
    $allshort ? implode(', ', array_map(fn($k, $n) => "[$k] x$n", array_keys($allshort), $allshort)) : 'none');
echo "compare with the live page: bash static-check.sh (counts <script> tags in the HTML visitors get)\n";
