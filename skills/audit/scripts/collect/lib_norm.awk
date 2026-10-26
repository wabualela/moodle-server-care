# lib_norm.awk -- shared gawk functions for the moodle-server-care audit
# collector (access_agg.awk, fpmlog_agg.awk, errlog_agg.awk, slowlog_parse.awk,
# cronlog_agg.awk).  Needs gawk 4.2 or later.
# Load it first:  gawk -f lib_norm.awk -f access_agg.awk ...
#
# Optional variables (set with -v): docroot=<Moodle web root> and
# moodle_dir=<Moodle code root>; file paths under either are shown relative.
#
# Nothing here prints raw IPs, query strings or referers.

# ---------------------------------------------------------------- months
function lib_init(   mn, i) {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= 12; i++) MON[mn[i]] = i
    DOCROOT_RE = ""
    if (docroot != "" || moodle_dir != "") DOCROOT_RE = "^(" re_escape(docroot != "" ? docroot : moodle_dir) "|" re_escape(moodle_dir != "" ? moodle_dir : docroot) ")/(public/)?"
    # info=/wsfunction= items must be <component>_<name> with a known Moodle plugin type (or core/tool/local...)
    QP_T = "(core|tool|mod|block|local|theme|format|qtype|qbank|qbehaviour|report|gradereport|gradeimport|gradeexport|gradingform|message|enrol|auth|filter|editor|tiny|atto|repository|availability|customfield|aiprovider|aiplacement|media|plagiarism|portfolio|search|webservice|dataformat|fileconverter|contenttype|h5plib|paygw|mlbackend|antivirus|cachestore|cachelock|factor|quizaccess|assignsubmission|assignfeedback|booktool|datafield|forumreport|ltisource|ltiservice|workshopform|workshopallocation|workshopeval|logstore|calendartype|communication|smsgateway|profilefield|coursereport|scormreport|quiz|mlbackend)_[a-z0-9_]+"
    QP_RE = "^" QP_T "(," QP_T ")*$"
    LIB_INIT = 1
}

# Escapes regex metacharacters so a path can be used inside a dynamic regex.
function re_escape(s) {
    gsub(/[][\\.^$*+?(){}|]/, "\\\\&", s)
    return s
}

# ---------------------------------------------------------------- percentiles
# Nearest-rank percentile: the smallest value whose cumulative count is at
# least ceil(p*n).
function rank(p, n,    r) {
    r = int(p * n)
    if (r < p * n) r++
    if (r < 1) r = 1
    return r
}

# h is a histogram (value -> count) and n its total count.  The function sets
# the globals HP50 HP90 HP95 HP99 HMAX (empty strings when n == 0).
function hstats(h, n,    idx, m, i, cum, r50, r90, r95, r99) {
    HP50 = HP90 = HP95 = HP99 = HMAX = ""
    if (n <= 0) return
    m = asorti(h, idx, "@ind_num_asc")
    if (m == 0) return
    r50 = rank(0.50, n); r90 = rank(0.90, n); r95 = rank(0.95, n); r99 = rank(0.99, n)
    cum = 0
    for (i = 1; i <= m; i++) {
        cum += h[idx[i]]
        if (HP50 == "" && cum >= r50) HP50 = idx[i]
        if (HP90 == "" && cum >= r90) HP90 = idx[i]
        if (HP95 == "" && cum >= r95) HP95 = idx[i]
        if (HP99 == "" && cum >= r99) { HP99 = idx[i] }
    }
    HMAX = idx[m]
}

# ---------------------------------------------------------------- query allowlist
# Returns the value of parameter `name` in query string qs when it matches
# ^[a-z0-9_,]+$ (after decoding %2C to a comma), "<invalid>" when the parameter
# is present but fails the check, and "" when it is absent.
function qparam(qs, name,    n, kv, i, eq, k, v) {
    n = split(qs, kv, "&")
    for (i = 1; i <= n; i++) {
        eq = index(kv[i], "=")
        if (eq == 0) continue
        k = substr(kv[i], 1, eq - 1)
        if (k != name) continue
        v = substr(kv[i], eq + 1)
        gsub(/%2[Cc]/, ",", v)
        if (v ~ /^[a-z0-9_,]+$/ && v !~ /[0-9]{6,}/ && v ~ QP_RE) return v
        return "<invalid>"
    }
    return ""
}

function safeseg(s) {
    return (s ~ /^[A-Za-z0-9_]+$/) ? s : "*"
}

# ---------------------------------------------------------------- path normalisation
# normpath(target) returns the normalised path.  It also sets the globals
#   NP_AJ  allowlisted ajax "info" value (may be comma-separated) or ""
#   NP_WS  allowlisted "wsfunction" value or ""
# N1: strip the query string, keeping only the allowlisted info/wsfunction.
# N2: pluginfile collapse.  N3: versioned theme/lib handlers.
# N4: per-segment masking, at most 4 segments, at most 100 characters.
function normpath(target,    q, path, qs, x, n, seg, i, s, out, nseg) {
    NP_AJ = ""; NP_WS = ""
    if (target == "") return "<malformed>"
    q = index(target, "?")
    if (q) { path = substr(target, 1, q - 1); qs = substr(target, q + 1) }
    else   { path = target; qs = "" }
    if (substr(path, 1, 1) != "/") {
        if (path ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) return "<absolute-uri>"
        if (path == "*") return "*"
        return "<non-path-target>"
    }
    gsub(/\/\/+/, "/", path)
    gsub(/\t/, " ", path)
    if (qs != "") {
        if (path ~ /^\/lib\/ajax\/service(-nologin)?\.php$/) NP_AJ = qparam(qs, "info")
        else if (path ~ /^\/webservice\/rest\/server\.php$/) NP_WS = qparam(qs, "wsfunction")
    }
    # N2
    if (match(path, /^\/(webservice\/)?pluginfile\.php\/[0-9]+\/([^\/]+)\/([^\/]+)/, x))
        return "/" x[1] "pluginfile.php/*/" safeseg(x[2]) "/" safeseg(x[3])
    if (match(path, /^\/(webservice\/)?pluginfile\.php(\/|$)/, x))
        return "/" x[1] "pluginfile.php/*"
    if (path ~ /^\/tokenpluginfile\.php(\/|$)/) return "/tokenpluginfile.php/*"
    if (path ~ /^\/draftfile\.php(\/|$)/)       return "/draftfile.php/*"
    # N3
    if (path ~ /^\/theme\/image\.php\//)      return "/theme/image.php/*"
    if (path ~ /^\/theme\/styles\.php\//)     return "/theme/styles.php/*"
    if (path ~ /^\/theme\/font\.php\//)       return "/theme/font.php/*"
    if (path ~ /^\/theme\/jquery\.php\//)     return "/theme/jquery.php/*"
    if (path ~ /^\/theme\/javascript\.php\//) return "/theme/javascript.php/*"
    if (path ~ /^\/theme\/yui_combo\.php/)    return "/theme/yui_combo.php*"
    if (path ~ /^\/lib\/javascript\.php\//)   return "/lib/javascript.php/*"
    if (path ~ /^\/lib\/requirejs\.php\//)    return "/lib/requirejs.php/*"
    # N4
    n = split(path, seg, "/")
    out = ""; nseg = 0
    for (i = 2; i <= n; i++) {
        s = seg[i]
        if (s == "") { if (i == n) out = out "/"; continue }
        # W3: digits/dots -> N; any character outside [A-Za-z0-9._~-] -> *
        # (this covers % @ \ : ; = + , & ' ( ) ! $ * and non-ASCII); 32+
        # characters -> *; 16-31 characters -> * unless lowercase words with
        # '_' and at most one extension (a long plugin directory name, x_y.php).
        if (s ~ /^[0-9.]+$/) s = "N"
        else if (s ~ /[^A-Za-z0-9._~-]/) s = "*"
        else if (s ~ /[0-9]{6,}/) s = "*"
        else if (length(s) >= 32) s = "*"
        else if (length(s) >= 16 && s !~ /^[a-z_]+(\.[a-z0-9]+)?$/) s = "*"
        nseg++
        if (nseg > 4) { out = out "/*"; break }
        out = out "/" s
    }
    if (out == "") out = "/"
    if (length(out) > 100) out = substr(out, 1, 100)
    return out
}

# ---------------------------------------------------------------- user agents
# Scanner classes seen in real traffic: a UA that starts with a literal quote
# (nginx logs it as \x22), "Go Web Pentest Tool", libredtail, WebSiphon, and
# the exact desktop build Chrome/120.0.6099.71 used by a scanner family.  They
# are checked before the generic classes; Chrome/120.0.6099.71 only just
# before the browser fallback, so a named crawler that happens to carry that
# build keeps its own class.  self_monitor is the audit module's own 48-hour
# monitor (UA "moodle-audit-monitor/..."), so its probes can be excluded.
function uaclass(ua,    l) {
    if (ua == "" || ua == "-") return "empty"
    l = tolower(ua)
    if (l ~ /moodle-audit-monitor/) return "self_monitor"
    if (substr(ua, 1, 4) == "\\x22") return "scanner_quoted_ua"
    if (l ~ /go web pentest/) return "scanner_go_pentest"
    if (l ~ /libredtail/) return "scanner_libredtail"
    if (l ~ /websiphon/) return "scanner_websiphon"
    if (l ~ /googlebot/) return "googlebot"
    if (l ~ /bingbot/) return "bingbot"
    if (l ~ /yandex/) return "yandex"
    if (l ~ /baidu/) return "baidu"
    if (l ~ /applebot/) return "applebot"
    if (l ~ /facebookexternalhit|meta-externalagent/) return "meta"
    if (l ~ /bytespider|tiktok/) return "bytedance"
    if (l ~ /gptbot|claudebot|ccbot|perplexity|amazonbot|oai-searchbot/) return "ai_crawler"
    if (l ~ /petalbot/) return "petalbot"
    if (l ~ /semrush|ahrefs|mj12|dotbot|blexbot|serankingbacklinks/) return "seo_blocked"
    if (l ~ /bot|crawl|spider|slurp/) return "other_bot"
    if (l ~ /moodlemobile/) return "moodle_mobile"
    if (l ~ /curl|wget|python|go-http|java\/|okhttp|axios|node-fetch|libwww|scrapy|httpclient|guzzle/) return "library"
    if (l ~ /uptime|pingdom|digitalocean|statuscake/) return "monitor"
    if (index(ua, "Chrome/120.0.6099.71")) return "suspect_chrome120_6099"
    if (ua ~ /Mobile|Android|iPhone/) return "browser_mobile"
    return "browser_desktop"
}

# "Automated" means anything that is not a human browser, the Moodle app or our
# own monitor.
function isbot(cls) {
    return !(cls == "browser_mobile" || cls == "browser_desktop" || cls == "moodle_mobile" || cls == "self_monitor")
}

# ---------------------------------------------------------------- masking
# Arabic-Indic (U+0660..9) and Extended Arabic-Indic (U+06F0..9) digits ->
# ASCII.  Works on UTF-8 bytes; the collector runs with LC_ALL=C.
function ar2ascii(s,    i) {
    if (s !~ /[\302\331\333\342\357\330]/) return s
    if (index(s, "\357\274")) for (i = 0; i <= 9; i++) gsub(sprintf("\357\274%c", 144 + i), i, s)
    gsub(/\302\240/, " ", s)
    gsub(/\342\200[\216\217\252-\256]|\342\201[\246-\251]|\330\234/, "", s)
    gsub(/\342\200[\220-\225]/, "-", s)
    gsub(/\331\240|\333\260/, "0", s); gsub(/\331\241|\333\261/, "1", s)
    gsub(/\331\242|\333\262/, "2", s); gsub(/\331\243|\333\263/, "3", s)
    gsub(/\331\244|\333\264/, "4", s); gsub(/\331\245|\333\265/, "5", s)
    gsub(/\331\246|\333\266/, "6", s); gsub(/\331\247|\333\267/, "7", s)
    gsub(/\331\250|\333\270/, "8", s); gsub(/\331\251|\333\271/, "9", s)
    return s
}

# IPv6 tokens, same rule as the IPv6 block of mask.sed: bounded by
# space/tab/[]()=,"'<>/@ (start) and space/tab/]),;"'<>/. (end), hex and
# colons only, at least 2 colons, contains '::' or has all 8 groups, contains
# a digit, not hh:mm:ss, not ::1.
function mask6(s,    out, m, tok, repl) {
    out = ""
    s = gensub(/((^|[^0-9A-Za-z_:])[A-Za-z]*[G-Zg-z][A-Za-z]*:)([0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{1,4}){0,6}::([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?)($|[] \t),;"'<>\/.%&}|#!@?*+-])/, "\\1\002\\3\\7", "g", s)
    while (match(s, /(^|[][ \t(=,"'<>\/@{|!#&;?*+\002-])([0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7})($|[] \t),;"'<>\/.%&}|#!@?*+-])/, m)) {
        tok = m[2]; repl = tok
        if (tok != "::1" && tok ~ /[0-9]/ && tok !~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ &&
            (index(tok, "::") || tok ~ /^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7}$/)) repl = "<ip6>"
        out = out substr(s, 1, RSTART - 1) m[1] repl
        s = substr(s, RSTART + length(m[1]) + length(tok))
    }
    out = out s
    gsub(/\002/, "", out)
    return out
}

# Free-text masking inside awk.  It mirrors mask.sed rule for rule, except that
# it masks every IPv4 (no allowlist; product versions are still kept).
# privacy_scan.awk counts what is left.  Change all three together.
function maskfree(s,    save, i) {
    save = IGNORECASE
    s = ar2ascii(s)
    IGNORECASE = 1
    gsub(/%25/, "%", s)
    gsub(/%40/, "@", s); gsub(/%2B/, "+", s); gsub(/%3D/, "=", s); gsub(/%2E/, ".", s)
    gsub(/%20/, " ", s); gsub(/%3A/, ":", s)
    IGNORECASE = 0
    s = gensub(/((Chrome|Chromium|CriOS|HeadlessChrome|Edg|EdgA|EdgiOS|OPR|YaBrowser|SamsungBrowser|UCBrowser|Version|Safari|AppleWebKit|Firefox|Electron|MoodleMobile)\/)([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/, "\\1\\3\001\\4\001\\5\001\\6", "g", s)
    IGNORECASE = 1
    s = gensub(/(sesskey|token|wstoken|password|passwd|passphrase|pass|pwd|secret|key|auth|credentials?|moodlesession[a-z0-9]*|moodleid[0-9]*_)([[:space:]]*=[[:space:]]*)("([^"\\]|\\.)*"|'[^']*'|[^&" ;]+)/, "\\1\\2<redacted>", "g", s)
    s = gensub(/("?[a-z0-9_-]*(sesskey|token|password|passwd|passphrase|pass|pwd|secret|key|auth|credentials?)"?[[:space:]]*:[[:space:]]*)("([^"\\]|\\.)*"|'[^']*'|[^[:space:],}"':][^[:space:],}"']*)/, "\\1<redacted>", "g", s)
    s = gensub(/^([[:space:]]*[a-z0-9_.-]*(pass|secret|token|key|auth)[a-z0-9_.-]*[[:space:]]*=[[:space:]]*).+/, "\\1<redacted>", 1, s)
    s = gensub(/^([[:space:]]*(fastcgi_param|uwsgi_param|scgi_param|proxy_set_header|add_header|env|setenv|setenvif[a-z]*|passenv|requestheader[[:space:]]+(set|append|add|merge)|header[[:space:]]+(always[[:space:]]+)?(set|append|add|merge))[[:space:]]+"?[a-z0-9_.-]*(pass|secret|token|key|auth|credential)[a-z0-9_.-]*"?[[:space:]]+)[^;]*/, "\\1<redacted>", 1, s)
    s = gensub(/(hc-ping\.com\/)[a-z0-9_-]{16,}/, "\\1<redacted>", "g", s)
    s = gensub(/("authorization"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/, "\\1<redacted>", "g", s)
    s = gensub(/(authorization:)[[:space:]]*([a-z]+[[:space:]]+)?[^[:space:]"]+/, "\\1 <redacted>", "g", s)
    IGNORECASE = 0
    s = gensub(/\y(Bearer|Basic|bearer|basic|BEARER|BASIC)[[:space:]]+[A-Za-z0-9._~+\/=-]*([0-9+\/=]|[a-z][A-Z])[A-Za-z0-9._~+\/=-]*/, "\\1 <redacted>", "g", s)
    if (s ~ /(mysql|mariadb|mysqldump|mariadb-dump|mysqladmin)/)
        s = gensub(/(^|[[:space:]])-p("[^"]*"|'[^']*'|[^[:space:]]+)/, "\\1-p<redacted>", "g", s)
    s = gensub(/--password=("[^"]*"|'[^']*'|[^[:space:]]+)/, "--password=<redacted>", "g", s)
    s = gensub(/(:\/\/[^\/:@[:space:]]*):[^@\/[:space:]]+@/, "\\1:<redacted>@", "g", s)
    s = gensub(/((^|[[:space:]])(-u|--user)[[:space:]]+[^:[:space:]]+):[^[:space:]]+/, "\\1:<redacted>", "g", s)
    if (s ~ /curl|wget/)
        s = gensub(/((^|[[:space:]])(-[A-Za-z]*u[[:space:]]*|--user=|--proxy-user[[:space:]=]+)[^:[:space:]]+):[^[:space:]]+/, "\\1:<redacted>", "g", s)
    if (s ~ /lftp/)
        s = gensub(/((^|[[:space:]])-u[[:space:]]+[^,[:space:]]+),[^[:space:]]+/, "\\1,<redacted>", "g", s)
    if (s ~ /smbclient|mount/)
        s = gensub(/((^|[[:space:]])(-U|--user=|--username=)[[:space:]]*[^%[:space:]]+)%[^[:space:]]+/, "\\1%<redacted>", "g", s)
    s = gensub(/(--passphrase)([[:space:]]+|=)("[^"]*"|'[^']*'|[^[:space:]]+)/, "\\1\\2<redacted>", "g", s)
    if (s ~ /(^|[[:space:]\/])(zip|7z|7za|7zr)[[:space:]]/)
        s = gensub(/(^|[[:space:]])-([pP])([[:space:]]*)("[^"]*"|'[^']*'|[^-[:space:]][^[:space:]]*)/, "\\1-\\2\\3<redacted>", "g", s)
    IGNORECASE = 1
    s = gensub(/((^|[[:space:]])--([a-z0-9]+-)*(token|secret|password|api-key|apikey)[[:space:]]+)([^-[:space:]][^[:space:]]*)/, "\\1<redacted>", "g", s)
    IGNORECASE = 0
    if (s ~ /redis-cli/)
        s = gensub(/((^|[[:space:]])(-a|--pass)[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/, "\\1<redacted>", "g", s)
    s = gensub(/((^|[[:space:]])sshpass[[:space:]]+-p[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]]+)/, "\\1<redacted>", "g", s)
    gsub(/\yeyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/, "<jwt>", s)
    gsub(/\yeyJ[A-Za-z0-9_-]{16,}={0,2}/, "<b64json>", s)
    s = gensub(/\ybot[0-9]{6,}:[A-Za-z0-9_-]{30,}/, "bot<redacted>", "g", s)
    gsub(/\y[0-9]{8,10}:[A-Za-z0-9_-]{30,}\y/, "<tgtoken>", s)
    gsub(/\y[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\y/, "<uuid>", s)
    gsub(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "<email>", s)
    s = gensub(/(^|[^A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+)@([A-Za-z][A-Za-z0-9-]*)\y/, "\\1<user>@\\3", "g", s)
    gsub(/\y[0-9a-fA-F]{32,}\y/, "<hex>", s)
    for (i = 1; i <= 2; i++) {
        s = gensub(/(^|[^0-9.]|[A-Za-z_]\.)\(?(\+|00)?966\)?[ .-]?(\(?0\)?[ .-]?)?\(?5[0-9]\)?([ .-]?[0-9]){7}([^0-9]|$)/, "\\1<phone>\\5", "g", s)
        s = gensub(/(^|[^0-9.]|[A-Za-z_]\.)\(?05[0-9]\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}([^0-9]|$)/, "\\1<phone>\\2", "g", s)
        s = gensub(/(^|[^0-9.]|[A-Za-z_]\.)\(?05[ -]?[0-9]\)?([ -]?[0-9]){7}([^0-9]|$)/, "\\1<phone>\\3", "g", s)
        s = gensub(/(^|[^0-9A-Za-z+])\+[1-9]([ .-]?\(?[0-9]\)?){8,14}([^0-9]|$)/, "\\1<phone>\\3", "g", s)
    }
    gsub(/([0-9]{1,3}\.){3}[0-9]{1,3}/, "<ip>", s)
    gsub(/\001/, ".", s)
    s = mask6(s)
    IGNORECASE = save
    return s
}

# L2/W8/W9: scrubs a free-form PHP or FastCGI message before maskfree().
# Moodle debuginfo after " Debug: " is dropped (it carries parameter values);
# query strings, quoted literals (names, JSON values), var_export values and
# key=value values are replaced; non-ASCII runs (Arabic names, Arabic-Indic digits) become
# <txt>.  Unquoted free-form names cannot be caught by any regex; the
# aggregation and the length cut are the only protection for those.
# Replaces quoted literals with q S q.  A quote opens a literal only after a
# non-alphanumeric character, and the literal ends at the next unescaped
# quote that is followed by a non-alphanumeric character, so apostrophes
# (Can't, O'Neil) and an outer wrapper quote cannot shift the pairing.
function unquote(m, q,    out, p, rest, j, k, nx) {
    out = ""
    while ((p = index(m, q)) > 0) {
        if (p > 1 && substr(m, p - 1, 1) ~ /[A-Za-z0-9\\]/) { out = out substr(m, 1, p); m = substr(m, p + 1); continue }
        rest = substr(m, p + 1); k = 0
        while ((j = index(rest, q)) > 0) {
            k += j; nx = substr(rest, j + 1, 1)
            if (substr(rest, j - 1, 1) != "\\" && (nx == "" || nx !~ /[A-Za-z0-9]/)) break
            rest = substr(rest, j + 1)
        }
        if (j == 0) { out = out m; m = ""; break }
        out = out substr(m, 1, p - 1) q "S" q
        m = substr(m, p + k + 1)
    }
    return out m
}

function scrub(m) {
    sub(/ Debug: .*$/, " Debug: <dropped>", m)
    gsub(/sid: [A-Za-z0-9,-]+/, "sid: <sid>", m)
    gsub(/\?[^ "'\])]*/, "?<q>", m)
    m = unquote(unquote(m, "'"), "\"")
    gsub(/=> [^,)\]]+/, "=> V", m)
    gsub(/=[^ >,;)&\]"']+/, "=V", m)
    gsub(/[\200-\377]+/, "<txt>", m)
    return m
}

# UA for top_ua files: masked, tabs removed, at most UA_MAXLEN (300)
# characters.  300 (not 150) so in-app webview markers at the
# end of long mobile UAs (FBAV, Instagram, TikTok, ...) survive.  Masking runs
# on the whole string before the cut.
function uatrunc(ua) {
    gsub(/\t/, " ", ua)
    ua = maskfree(ua)
    return substr(ua, 1, (UA_MAXLEN ? UA_MAXLEN : 300))
}

# Coarse network prefix: /16 for IPv4 (also for ::ffff:a.b.c.d), /32 for IPv6.
function prefix16(ip,    a, n, h) {
    sub(/^::ffff:/, "", ip)
    if (ip ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) {
        split(ip, a, ".")
        return a[1] "." a[2] ".0.0/16"
    }
    if (index(ip, ":")) {
        if (substr(ip, 1, 2) == "::") return "::/v6-other"
        n = split(ip, h, ":")
        if (n >= 2 && h[2] != "") return tolower(h[1]) ":" tolower(h[2]) "::/32"
        return tolower(h[1]) "::/16"
    }
    return "<unparsed>"
}

function relpath(p) {
    sub(DOCROOT_RE, "", p)
    return p
}
