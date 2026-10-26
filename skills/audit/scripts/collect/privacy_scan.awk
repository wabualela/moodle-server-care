# privacy_scan.awk -- counts residual personal data in one output file
# (PRIVACY_CHECK.txt of the moodle-server-care audit collector).
#   zcat -f FILE | LC_ALL=C gawk -f privacy_scan.awk -v name=REL_PATH [-v origin_ip=A.B.C.D]
# Prints one line: name <TAB> ipv4 <TAB> email <TAB> phone <TAB> ipv6 <TAB> other
#
# The detectors mirror mask.sed and lib_norm.awk maskfree(); change all three
# together.
#
# ipv4  = dotted quads with every octet <= 255 that are not allowlisted:
#         the server's own address (-v origin_ip), 127/8, 0.0.0.0, 10/8,
#         172.16/12, 192.168/16, 169.254/16.  Also counted when glued to a letter on either side.
#         Skipped: a dotted quad right after one of the product names
#         Chrome/ Safari/ Version/ ... (same list as mask.sed, L5), and a /16
#         aggregate written as a.b.0.0/16.
# email = user@domain.tld, also URL-encoded (%40, L6)
# phone = Saudi mobile in every form mask.sed masks: (+|00)966 and 05x, with
#         optional separators, ASCII or Arabic-Indic digits (L1, W10), and
#         any '+'-prefixed international number of 9-15 digits (rule 5b).
#         Skipped: a digit run inside a hex token of 32+ characters, which
#         mask.sed rule 4 turns into <hex> before its phone rules (the raw
#         performance_schema DIGEST hashes in 40_mariadb/digest_*.tsv).
# ipv6  = IPv6 tokens as defined in the IPv6 block of mask.sed: bounded,
#         hex and colons, contains '::' or has 8 groups, contains a digit.
#         Skipped: ::1, x:y::/NN aggregates, ::ffff:<IPv4> (the IPv4 part is
#         counted as ipv4), and tokens followed by '(' (PHP frames a1::b2()).
# other = secrets left in clear: JWT and base64 JSON, "password":"x" JSON,
#         password=/token=/secret= and password:/token: values, user:pass@ in
#         URLs, -u user:pass, redis-cli -a X, Telegram bot tokens, mysql -pX,
#         web server directives that set a secret-named header/parameter/
#         variable (fastcgi_param DB_PASSWORD x; SetEnv X_TOKEN x), and
#         healthchecks.io ping keys (hc-ping.com/<key>).
#         A value that starts with '<' (a mask placeholder) is not counted.

function allowed(ip,    o) {
    split(ip, o, ".")
    if ((origin_ip != "" && ip == origin_ip) || ip == "0.0.0.0") return 1
    if (o[1] == 127 || o[1] == 10) return 1
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
    if (o[1] == 192 && o[2] == 168) return 1
    if (o[1] == 169 && o[2] == 254) return 1
    return 0
}

function ps_ar2ascii(s,    i) {
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

BEGIN {
    PRODUCT_RE = "(Chrome|Chromium|CriOS|HeadlessChrome|Edg|EdgA|EdgiOS|OPR|YaBrowser|SamsungBrowser|UCBrowser|Version|Safari|AppleWebKit|Firefox|Electron|MoodleMobile)/$"
    ipv4 = email = phone = ipv6 = other = 0
}

{
    line = $0

    # ---- ipv4
    s = line; off = 0
    while (match(s, /[0-9][0-9.]*[0-9]/)) {
        run = substr(s, RSTART, RLENGTH)
        st = off + RSTART                       # position of run in line
        before = (st > 1) ? substr(line, st - 1, 1) : ""
        off += RSTART + RLENGTH - 1
        s = substr(s, RSTART + RLENGTH)
        if (before == ".") continue
        if (run !~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) continue
        split(run, o, ".")
        if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) continue
        if (before == "/" && substr(line, 1, st - 1) ~ PRODUCT_RE) continue
        if (run ~ /\.0\.0$/ && substr(s, 1, 3) == "/16") continue
        if (allowed(run)) continue
        ipv4++
    }

    # ---- email (plain and %40-encoded)
    t = line
    gsub(/%25/, "%", t); gsub(/%40/, "@", t); gsub(/%2[Ee]/, ".", t); gsub(/%2[Bb]/, "+", t)
    email += gsub(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "", t)

    # ---- phone (Arabic-Indic digits normalised first)
    u = ps_ar2ascii(line); gsub(/%20/, " ", u)
    gsub(/\y[0-9a-fA-F]{32,}\y/, "<hex>", u)   # mask.sed rule 4: a hex token (digest hash) is not a phone
    phone += gsub(/(^|[^0-9.]|[A-Za-z_]\.)\(?(\+|00)?966\)?[ .-]?(\(?0\)?[ .-]?)?\(?5[0-9]\)?([ .-]?[0-9]){7}([^0-9]|$)|(^|[^0-9.]|[A-Za-z_]\.)\(?05[0-9]\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}([^0-9]|$)|(^|[^0-9.]|[A-Za-z_]\.)\(?05[ -]?[0-9]\)?([ -]?[0-9]){7}([^0-9]|$)/, "", u)
    phone += gsub(/(^|[^0-9A-Za-z+])\+[1-9]([ .-]?\(?[0-9]\)?){8,14}([^0-9]|$)/, "", u)

    # ---- ipv6
    s = line; gsub(/%3[Aa]/, ":", s)
    # a letter word ending in a non-hex letter, then ':' (client:, ip:, src:) may start a '::' token
    s = gensub(/((^|[^0-9A-Za-z_:])[A-Za-z]*[G-Zg-z][A-Za-z]*):([0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{1,4}){0,6}::)/, "\\1: \\3", "g", s)
    while (match(s, /(^|[^0-9A-Za-z_:\\>.])([0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7})([^0-9A-Za-z_:(]|$)/, m)) {
        tok = m[2]
        rest = substr(s, RSTART + RLENGTH - length(m[4]))
        nxt = substr(rest, 1, 1)
        s = rest
        if (tok !~ /[0-9]/ || tok == "::1") continue
        if (!index(tok, "::") && tok !~ /^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7}$/) continue
        # x:y::/32 and x::/16 aggregates written by the access-log aggregator
        if (tok ~ /^[0-9a-f]{1,4}(:[0-9a-f]{1,4})?::$/ && substr(rest, 1, 3) ~ /^\/(32|16)$/) continue
        if (tok ~ /^::[Ff][Ff][Ff][Ff]:[0-9]{1,3}$/ && nxt == ".") continue   # ::ffff:a.b.c.d
        ipv6++
    }

    # ---- other: secrets in clear
    v = line
    other += gsub(/eyJ[A-Za-z0-9_-]{16,}/, "", v)                                   # JWT / base64 JSON
    v = line
    other += gsub(/"(password|passwd|pwd|secret|token|api_?key)"[ \t]*:[ \t]*"[^"<]/, "", v)
    IGNORECASE = 1
    v = line
    other += gsub(/(sesskey|wstoken|password|passwd|pwd|secret|token)[ \t]*=[ \t]*[^<[:space:]"'&;,]/, "", v)
    v = line
    other += gsub(/(password|passwd|pwd|secret|token)"?[ \t]*:[ \t]*[^<[:space:]"',}:]/, "", v)
    v = line
    other += gsub(/^[[:space:]]*(fastcgi_param|uwsgi_param|scgi_param|proxy_set_header|add_header|env|setenv|setenvif[a-z]*|passenv|requestheader[[:space:]]+(set|append|add|merge)|header[[:space:]]+(always[[:space:]]+)?(set|append|add|merge))[[:space:]]+"?[a-z0-9_.-]*(pass|secret|token|key|auth|credential)[a-z0-9_.-]*"?[[:space:]]+[^<;[:space:]]/, "", v)
    v = line
    other += gsub(/hc-ping\.com\/[a-z0-9_-]{16,}/, "", v)
    IGNORECASE = 0
    v = line
    other += gsub(/(^|[[:space:]])(-u|--user)[[:space:]]+[^:[:space:]]+:[^<[:space:]]/, "", v)
    v = line
    other += gsub(/:\/\/[^\/:@[:space:]]*:[^@\/[:space:]<]+@/, "", v)               # user:pass@host
    v = line
    other += gsub(/bot[0-9]{6,}:[A-Za-z0-9_-]{30,}/, "", v)
    v = line
    other += gsub(/(^|[^0-9])[0-9]{8,10}:[A-Za-z0-9_-]{30,}([^A-Za-z0-9_-]|$)/, "", v)          # raw Telegram token
    v = line
    other += gsub(/"(passphrase|authorization|credentials?|client_secret|access_token|refresh_token)"[ \t]*:[ \t]*"[^"<]/, "", v)
    v = line
    other += gsub(/--passphrase([ \t]+|=)[^<[:space:]]/, "", v)
    if (line ~ /curl|wget/) { v = line; other += gsub(/(^|[[:space:]])(-[A-Za-z]+u[[:space:]]*|-u|--user=)[^:[:space:]]+:[^<[:space:]]/, "", v) }
    if (line ~ /lftp/) { v = line; other += gsub(/(^|[[:space:]])-u[[:space:]]+[^,[:space:]]+,[^<[:space:]]/, "", v) }
    if (line ~ /smbclient|mount/) { v = line; other += gsub(/(^|[[:space:]])(-U|--user(name)?=)[[:space:]]*[^%[:space:]]+%[^<[:space:]]/, "", v) }
    if (line ~ /redis-cli/) {
        v = line
        other += gsub(/(^|[[:space:]])(-a|--pass)[[:space:]]*[^<[:space:]-]/, "", v)
    }
    if (line ~ /(mysql|mariadb|mysqldump|mariadb-dump|mysqladmin)/) {
        v = line
        other += gsub(/(^|[[:space:]])-p[^<[:space:]]/, "", v)
    }
}

END { printf "%s\t%d\t%d\t%d\t%d\t%d\n", name, ipv4, email, phone, ipv6, other }
