# mask.sed -- privacy masking for free text (journal, web server error logs,
# MTA logs, ufw/nft, FPM log and config, crontabs, configs).
# Run with:  sed -E -f mask.sed
# GNU sed is required (\b, \xHH, the I flag) and LC_ALL=C is REQUIRED: the
# Arabic-digit rules match UTF-8 bytes, and under a UTF-8 locale such as
# en_US.UTF-8 GNU sed rejects this file ("Invalid range end").  The collector
# and selftest.sh export LC_ALL=C; do the same when you run it by hand:
#   LC_ALL=C sed -E -f mask.sed
# Part of the moodle-server-care audit collector.
#
# The server's own public IPv4 is allowlisted at run time: the collector writes
# a copy of this file with the @ORIGIN_IP_RE@ / @ORIGIN_IP_PROT@ line filled in
# from server.env (or deletes that line when the address is unknown).  Used as
# is, that line only matches the literal placeholder text, which is harmless.
#
# lib_norm.awk maskfree() mirrors these rules for text masked inside gawk,
# and privacy_scan.awk counts what is left after them.  Change all three
# together.
#
# The IPv6 block is between the #BEGIN-IPV6 and #END-IPV6 lines.  The collector
# deletes that block to build mask_nov6.sed for PHP stack traces, because they
# contain '::'.
#
# Placeholders: \x03 replaces the dots of allowlisted IPv4 (no '@', so the
# e-mail rules cannot eat it); \x01 \x02 \x05 \x06 mark IPv6 candidates.
#
# Step order: normalise, protect the allowlist, mask secrets, e-mail, long
# hex, phone, IPv4 and IPv6, then restore the allowlist.

# 0. Normalise: Arabic-Indic (U+0660..9) and Extended Arabic-Indic (U+06F0..9)
#    digits become ASCII, so the phone rules see them (L1).  URL-encoded
#    '@' '+' '=' '.' are decoded, so encoded e-mails and secrets are seen (L6).
s/\xd9\xa0|\xdb\xb0/0/g
s/\xd9\xa1|\xdb\xb1/1/g
s/\xd9\xa2|\xdb\xb2/2/g
s/\xd9\xa3|\xdb\xb3/3/g
s/\xd9\xa4|\xdb\xb4/4/g
s/\xd9\xa5|\xdb\xb5/5/g
s/\xd9\xa6|\xdb\xb6/6/g
s/\xd9\xa7|\xdb\xb7/7/g
s/\xd9\xa8|\xdb\xb8/8/g
s/\xd9\xa9|\xdb\xb9/9/g
s/\xef\xbc\x90/0/g
s/\xef\xbc\x91/1/g
s/\xef\xbc\x92/2/g
s/\xef\xbc\x93/3/g
s/\xef\xbc\x94/4/g
s/\xef\xbc\x95/5/g
s/\xef\xbc\x96/6/g
s/\xef\xbc\x97/7/g
s/\xef\xbc\x98/8/g
s/\xef\xbc\x99/9/g
s/\xc2\xa0/ /g
s/\xe2\x80[\x8e\x8f\xaa-\xae]|\xe2\x81[\xa6-\xa9]|\xd8\x9c//g
s/\xe2\x80[\x90-\x95]/-/g
s/%25/%/Ig
s/%40/@/Ig
s/%20/ /g
s/%3A/:/Ig
s/%2B/+/Ig
s/%3D/=/Ig
s/%2E/./Ig

# 1. Protect allowlisted IPv4 addresses by swapping their dots for \x03:
#    the server's own address, loopback 127/8, 0.0.0.0, RFC1918 and
#    link-local 169.254/16 (the cloud metadata address).
#ORIGIN-IP (the next line is rewritten or deleted by the collector)
s/\b@ORIGIN_IP_RE@\b/@ORIGIN_IP_PROT@/g
s/\b127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\b/127\x03\1\x03\2\x03\3/g
s/\b0\.0\.0\.0\b/0\x030\x030\x030/g
s/\b10\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\b/10\x03\1\x03\2\x03\3/g
s/\b172\.(1[6-9]|2[0-9]|3[01])\.([0-9]{1,3})\.([0-9]{1,3})\b/172\x03\1\x03\2\x03\3/g
s/\b192\.168\.([0-9]{1,3})\.([0-9]{1,3})\b/192\x03168\x03\1\x03\2/g
s/\b169\.254\.([0-9]{1,3})\.([0-9]{1,3})\b/169\x03254\x03\1\x03\2/g
#    Product versions such as "Chrome/120.0.0.0" are not addresses.  Only these
#    product names qualify (L5); "ip/8.8.8.8" is still masked.
#    privacy_scan.awk uses the same list.
s/((Chrome|Chromium|CriOS|HeadlessChrome|Edg|EdgA|EdgiOS|OPR|YaBrowser|SamsungBrowser|UCBrowser|Version|Safari|AppleWebKit|Firefox|Electron|MoodleMobile)\/)([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/\1\3\x03\4\x03\5\x03\6/g

# 2. Secrets (case-insensitive where marked I).
#    key=value, also with spaces around '=' and with a quoted value (S3):
#    password = x, cftoken="x", MYSQL_PWD=x, sesskey=x&...
s/(sesskey|token|wstoken|password|passwd|passphrase|pass|pwd|secret|key|auth|credentials?|MoodleSession[A-Za-z0-9]*|MOODLEID[0-9]*_)([[:space:]]*=[[:space:]]*)("([^"\\]|\\.)*"|'[^']*'|[^&" ;]+)/\1\2<redacted>/Ig
#    key: value and JSON "key": "value" (S3, L7).  The key must END in one of
#    the words (api_key:, "password":, dbpass:), so key_count: or Keys: stay.
#    The value may not start with ':', so PHP frames such as core_auth::foo()
#    are left alone.
s/("?[A-Za-z0-9_-]*(sesskey|token|password|passwd|passphrase|pass|pwd|secret|key|auth|credentials?)"?[[:space:]]*:[[:space:]]*)("([^"\\]|\\.)*"|'[^']*'|[^[:space:],}"':][^[:space:],}"']*)/\1<redacted>/Ig
#    INI line: anything = value whose key contains one of the words (L7).
s/^([[:space:]]*[A-Za-z0-9_.-]*(pass|secret|token|key|auth)[A-Za-z0-9_.-]*[[:space:]]*=[[:space:]]*).+/\1<redacted>/I
#    Web server directives whose header, parameter or variable NAME contains
#    one of the words: fastcgi_param DB_PASSWORD x;  proxy_set_header
#    X-Api-Key x;  SetEnv DB_PASSWORD x;  RequestHeader set X-Auth-Token x.
#    The value up to ';' (nginx) or the end of the line (Apache) is redacted;
#    Host $host, SCRIPT_FILENAME and Cache-Control are not touched.
s/^([[:space:]]*(fastcgi_param|uwsgi_param|scgi_param|proxy_set_header|add_header|env|SetEnv|SetEnvIf[A-Za-z]*|PassEnv|RequestHeader[[:space:]]+(set|append|add|merge)|Header[[:space:]]+(always[[:space:]]+)?(set|append|add|merge))[[:space:]]+"?[A-Za-z0-9_.-]*(pass|secret|token|key|auth|credential)[A-Za-z0-9_.-]*"?[[:space:]]+)[^;]*/\1<redacted>/I
#    healthchecks.io ping URLs: the path is the check's secret (ping key and
#    slug form; the UUID form is also caught by the <uuid> rule below).
s#(hc-ping\.com/)[A-Za-z0-9_-]{16,}#\1<redacted>#g
#    Authorization headers and Bearer/Basic credentials.  The credential must
#    look like a token (a digit, + / =, or a lower-to-upper case change, as
#    in base64), so prose such as "# Basic Settings" in nginx.conf is kept.
s/\b(Bearer|Basic|bearer|basic|BEARER|BASIC)[[:space:]]+[A-Za-z0-9._~+\/=-]*([0-9+\/=]|[a-z][A-Z])[A-Za-z0-9._~+\/=-]*/\1 <redacted>/g
s/("authorization"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/\1<redacted>/Ig
s/(Authorization:)[[:space:]]*([A-Za-z]+[[:space:]]+)?[^[:space:]"]+/\1 <redacted>/Ig
#    CLI passwords: mysql -pX / -p"X Y" (W10), --password=X, user:pass@ in
#    URLs, curl -u user:pass, redis-cli -a X, sshpass -pX (L7).
/(mysql|mariadb|mysqldump|mariadb-dump|mysqladmin)/s/(^|[[:space:]])-p("[^"]*"|'[^']*'|[^[:space:]]+)/\1-p<redacted>/g
s/--password=("[^"]*"|'[^']*'|[^[:space:]]+)/--password=<redacted>/g
s#(://[^/:@[:space:]]*):[^@/[:space:]]+@#\1:<redacted>@#g
s/((^|[[:space:]])(-u|--user)[[:space:]]+[^:[:space:]]+):[^[:space:]]+/\1:<redacted>/g
/(curl|wget)/s/((^|[[:space:]])(-[A-Za-z]*u[[:space:]]*|--user=|--proxy-user[[:space:]=]+)[^:[:space:]]+):[^[:space:]]+/\1:<redacted>/g
/lftp/s/((^|[[:space:]])-u[[:space:]]+[^,[:space:]]+),[^[:space:]]+/\1,<redacted>/g
/(smbclient|mount)/s/((^|[[:space:]])(-U|--user=|--username=)[[:space:]]*[^%[:space:]]+)%[^[:space:]]+/\1%<redacted>/g
s/(--passphrase)([[:space:]]+|=)("[^"]*"|'[^']*'|[^[:space:]]+)/\1\2<redacted>/g
/(^|[[:space:]\/])(zip|7z|7za|7zr)[[:space:]]/s/(^|[[:space:]])-([pP])([[:space:]]*)("[^"]*"|'[^']*'|[^-[:space:]][^[:space:]]*)/\1-\2\3<redacted>/g
s/((^|[[:space:]])--([A-Za-z0-9]+-)*(token|secret|password|api-key|apikey)[[:space:]]+)([^-[:space:]][^[:space:]]*)/\1<redacted>/Ig
/redis-cli/s/((^|[[:space:]])(-a|--pass)[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1<redacted>/g
s/((^|[[:space:]])sshpass[[:space:]]+-p[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]]+)/\1<redacted>/g
#    Tokens: JWT, other base64-encoded JSON ("eyJ" = '{"', e.g. ACME JWS
#    fields that can carry a contact e-mail), Telegram bot tokens, UUIDs
#    (healthcheck ping URLs).
s/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/<jwt>/g
s/\beyJ[A-Za-z0-9_-]{16,}={0,2}/<b64json>/g
s/\bbot[0-9]{6,}:[A-Za-z0-9_-]{30,}/bot<redacted>/g
s/\b[0-9]{8,10}:[A-Za-z0-9_-]{30,}\b/<tgtoken>/g
s/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/<uuid>/g

# 3. E-mail addresses, then local addresses with no TLD (user@hostname,
#    W5).  The host part of a local address is kept: it is a machine name.
s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g
s/(^|[^A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+)@([A-Za-z][A-Za-z0-9-]*)\b/\1<user>@\3/g

# 4. Long hex strings (session ids, tokens, hashes).  Before the phone rules,
#    so a phone-like run inside a hex token cannot split it.
s/\b[0-9a-fA-F]{32,}\b/<hex>/g

# 5. Saudi mobile numbers (L1, W10): +966 / 00966 / 966 forms and 05x forms,
#    with optional space, dot, dash or (05x).  The number may follow a letter
#    or '_' (x0551234567) but not a digit or '.', so decimals such as
#    0.0551234567 are left alone.  A bare 9-digit 5XXXXXXXX is not masked: it
#    would hit byte counts.  Each rule runs twice, because a match consumes
#    the separator in front of the next number.
s/(^|[^0-9.]|[A-Za-z_]\.)\(?(\+|00)?966\)?[ .-]?(\(?0\)?[ .-]?)?\(?5[0-9]\)?([ .-]?[0-9]){7}([^0-9]|$)/\1<phone>\5/g
s/(^|[^0-9.]|[A-Za-z_]\.)\(?(\+|00)?966\)?[ .-]?(\(?0\)?[ .-]?)?\(?5[0-9]\)?([ .-]?[0-9]){7}([^0-9]|$)/\1<phone>\5/g
s/(^|[^0-9.]|[A-Za-z_]\.)\(?05[0-9]\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}([^0-9]|$)/\1<phone>\2/g
s/(^|[^0-9.]|[A-Za-z_]\.)\(?05[0-9]\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}([^0-9]|$)/\1<phone>\2/g
s/(^|[^0-9.]|[A-Za-z_]\.)\(?05[ -]?[0-9]\)?([ -]?[0-9]){7}([^0-9]|$)/\1<phone>\3/g
s/(^|[^0-9.]|[A-Za-z_]\.)\(?05[ -]?[0-9]\)?([ -]?[0-9]){7}([^0-9]|$)/\1<phone>\3/g
# 5b. Any other international number written with a leading '+': '+', a digit
#     1-9, then 8 to 14 more digits, each optionally preceded by one space, dot
#     or dash and optionally wrapped in brackets (+44 20 7946 0958,
#     +1 (555) 123-4567).  Not after a letter, digit or '+', so timezone offsets
#     (+0300, +03:00), kernel offsets (+0x1a2) and versions (1.2+deb12u1) stay.
#     The Saudi rules above are the default country set; add your country's
#     national (no '+') mobile format here and in lib_norm.awk maskfree() and
#     privacy_scan.awk if students type numbers without the country code.
s/(^|[^0-9A-Za-z+])\+[1-9]([ .-]?\(?[0-9]\)?){8,14}([^0-9]|$)/\1<phone>\3/g
s/(^|[^0-9A-Za-z+])\+[1-9]([ .-]?\(?[0-9]\)?){8,14}([^0-9]|$)/\1<phone>\3/g

# 6. IPv4 that is not allowlisted, including an address glued to a letter or
#    '_' on either side (W4).
s/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g
s/([A-Za-z_])([0-9]{1,3}\.){3}[0-9]{1,3}\b/\1<ip>/g
s/(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([A-Za-z_])/\1<ip>\3/g

#BEGIN-IPV6
# 7. IPv6.  A token qualifies only if all of these hold:
#    - it starts at line start or after space tab [ ( = , " ' < > / @, and ends
#      at line end or before space tab ] ) , ; " ' < > / .   (L4)
#    - it is only hex digits and colons, with at least 2 colons
#    - it contains '::', or has all 8 groups (anything else, such as
#      maxstartups 10:30:100, a MAC address or 12:34:56:789, is not IPv6)
#    - it contains a digit, and it is not hh:mm:ss
#    Loopback ::1 is allowlisted.  Candidates are marked \x01..\x02, valid ones
#    are re-marked \x05..\x06, and only those with a digit become <ip6>.
s/(^|[][ \t(=,"'<>\/@{|!#&;?*+-])::1($|[] \t),;"'<>\/.%&}|#!@?*+-])/\1@LO6@\2/g
s/(^|[][ \t(=,"'<>\/@{|!#&;?*+-])::1($|[] \t),;"'<>\/.%&}|#!@?*+-])/\1@LO6@\2/g
s/((^|[^0-9A-Za-z_:])[A-Za-z]*[G-Zg-z][A-Za-z]*:)([0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{1,4}){0,6}::([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?)($|[] \t),;"'<>\/.%&}|#!@?*+-])/\1\x01\3\x02\7/g
:v6
s/(^|[][ \t(=,"'<>\/@{|!#&;?*+-])([0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7})($|[] \t),;"'<>\/.%&}|#!@?*+-])/\1\x01\2\x02\4/
tv6
s/\x01([0-9]{2}:[0-9]{2}:[0-9]{2})\x02/\1/g
s/\x01([^\x02]*::[^\x02]*)\x02/\x05\1\x06/g
s/\x01([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7})\x02/\x05\1\x06/g
s/[\x01\x02]//g
s/\x05[^\x06]*[0-9][^\x06]*\x06/<ip6>/g
s/[\x05\x06]//g
s/@LO6@/::1/g
#END-IPV6

# 8. Restore the allowlisted IPv4 addresses.
s/\x03/./g
