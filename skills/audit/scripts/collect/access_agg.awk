# access_agg.awk -- web access-log aggregator (moodle-server-care audit collector).
#
#   zcat -f <logs oldest-first> | gawk -f lib_norm.awk -f access_agg.awk \
#       -v fmt=perf|combined -v cutoff=<epoch> -v surge=<epoch> -v outdir=<dir>
#
# fmt=combined is the standard "combined" format of nginx and Apache:
#   $remote_addr - $remote_user [$time_local] "$request" $status
#   $body_bytes_sent "$http_referer" "$http_user_agent"
# fmt=perf is combined plus ' rt=$request_time urt=$upstream_response_time'
# at the end (nginx; see assets/nginx-perf-logformat.conf).  Only perf gives
# timings; without it the per_minute, endpoint, slowest, ajax and ws files are
# not written.
# surge splits the window into two periods: P0 = before surge, P1 = from surge
# on.  surge=0 (the collector's default) puts the whole window in P1.
#
# Optional: -v top_paths=N -v top_prefix=N -v top_clients=N -v top_ua=N
#           -v files="<the same files, space separated>": enables pass 2
#
# Memory: pass 1 keeps only two numbers per client IP (window total and
# per-period total).  At END a second pass re-reads the files (gawk runs
# "zcat -f" itself, so the IPs never leave this process) and collects the
# per-client detail (php requests, sum_urt, UA class, top path, first/last
# minute, distinct paths) for the selected top clients only.
#
# Privacy: no raw IP, query string (except allowlisted info=/wsfunction=),
# referer or untruncated UA is written.  Clients appear as per-run
# pseudonyms C0001.. (ranked by requests in the window).  The pseudonym-to-IP
# mapping exists only in memory.  Network aggregates are /16 (IPv4) or
# /32 (IPv6) with counts.
#
# Percentiles are nearest-rank over exact value histograms.  nginx logs times
# with millisecond resolution, so a value->count histogram is exact and much
# smaller than a list of values.
#
# Status counters: s499 is a subset of s4xx; s502 and s504 are subsets of s5xx.
#
# Further outputs:
#   - endpoint groups for the mail path, keyed by method: GET/POST
#     /enrol/index.php, GET/POST /login/signup.php, GET/POST
#     /login/forgot_password.php, /login/confirm.php; plus installaddon
#   - endpoint_hourly.tsv gains urt_p99, s499, s5xx, bytes_sum, n_bytes_gt32k;
#     endpoint_summary_P0/P1.tsv give the whole-period view per group
#     (urt/rt p50..p99, status classes, bytes)
#   - status_detail.tsv / status_detail_minute.tsv: the FULL list (no top-N
#     cut) of (status, method, path) for every status >= 500, every 414 and
#     every /admin/tool/installaddon request.  A 414 whose request line was
#     cut before " HTTP/x" is listed as "METHOD /norm/path[cut]" there
#     (query stripped) instead of "- <malformed>"
#   - per_minute.tsv gains front_req ('/' + '/index.php'), rphp404_req,
#     top_client_req, top_client_share, n_bytes_gt32k (per_hour.tsv too);
#     per_minute_top_client.tsv names the top client of every minute by
#     pseudonym, with its UA class
#   - top_paths_P*.tsv gain bytes_sum, bytes_max, n_bytes_gt32k
#   - "bytes" is nginx $body_bytes_sent; gt32k means > 32768 bytes

BEGIN {
    FS = "\""
    lib_init()
    if (fmt == "") fmt = "perf"
    PERF = (fmt == "perf")
    if (outdir == "") { print "access_agg: -v outdir= is required" > "/dev/stderr"; _noout = 1; exit 2 }
    cutoff += 0; surge += 0
    if (top_paths == "")   top_paths   = PERF ? 100 : 50
    if (top_prefix == "")  top_prefix  = PERF ? 25 : 15
    if (top_clients == "") top_clients = 50
    if (top_ua == "")      top_ua      = 40
    top_paths += 0; top_prefix += 0; top_clients += 0; top_ua += 0
    GRACE = 900          # flush minutes/hours/days that ended >15 min before newest
    MAXCPATH = 5000      # distinct paths tracked per selected client and period (pass 2)
    UAIPCAP = 20000      # distinct IPs counted per UA string and period
    CR["P0"]["\001"] = 1; delete CR["P0"]["\001"]
    CR["P1"]["\001"] = 1; delete CR["P1"]["\001"]
    SLOWKEEP = 300
    BIG = 32768          # response size threshold for n_bytes_gt32k
    AGG_VERSION = "msc-1.0"
    slowmin = -1; nslow = 0
    newest = 0; lastflush = 0; Mflushed = -1; Hflushed = -1
    T = "\t"

    F_MIN  = outdir "/per_minute.tsv"
    F_HOUR = outdir "/per_hour.tsv"
    F_DAY  = outdir "/per_day.tsv"
    F_EP   = outdir "/endpoint_hourly.tsv"
    F_SPD  = outdir "/status_paths_daily.tsv"
    F_UAD  = outdir "/ua_classes_daily.tsv"
    F_MON  = outdir "/monitor_requests.tsv"
    F_SLOW = outdir "/slowest_requests.tsv"
    F_PDM  = outdir "/path_day_matrix.tsv"
    F_META = outdir "/agg_meta.tsv"
    F_SD   = outdir "/status_detail.tsv"
    F_SDM  = outdir "/status_detail_minute.tsv"
    F_MTC  = outdir "/per_minute_top_client.tsv"

    COLS = "req" T "php_req" T "s2xx" T "s3xx" T "s4xx" T "s5xx" T "s499" T "s502" T "s504" T "uniq_ip" T \
           "rt_p50" T "rt_p95" T "rt_p99" T "rt_max" T "urt_p50" T "urt_p95" T "urt_p99" T "urt_max" T \
           "n_urt_gt1" T "n_urt_gt5" T "bytes"
    # later columns, appended at the end so earlier column positions do not move
    COLS2 = "front_req" T "rphp404_req" T "top_client_req" T "top_client_share" T "n_bytes_gt32k"
    if (PERF) print "minute" T COLS T COLS2 > F_MIN
    print "hour" T COLS T "uniq_ua" T "bot_req" T "urt_p90_php" T COLS2 > F_HOUR
    print "day" T "req" T "php_req" T "uniq_ip" T "bot_share" T "top1_share" T "top10_share" T "top100_share" T \
          "ips_gt1k" T "ips_gt10k" T "s4xx" T "s5xx" T "rt_p50" T "rt_p95" T "urt_p50" T "urt_p95" T "urt_p99" > F_DAY
    if (PERF) print "hour" T "group" T "req" T "php_req" T "urt_p50" T "urt_p95" T "urt_max" T \
                    "urt_p99" T "s499" T "s5xx" T "bytes_sum" T "n_bytes_gt32k" > F_EP
    print "day" T "status" T "method" T "norm_path" T "count" > F_SPD
    print "day" T "ua_class" T "req" T "uniq_ip" > F_UAD
    print "minute" T "method" T "norm_path" T "status" T "rt" T "urt" T "bytes" > F_MON
}

# ------------------------------------------------------------------ helpers
# Endpoint group of one request ("" = not grouped).  The mail-path
# endpoints are split by method (the student actions are GET enrol and POST
# signup/forgot), so their p50/p95/p99 and 499s can be read directly.
function epgroup(np, isphp, status, method) {
    if (np == "/" || np == "/index.php") return "/"
    if (np == "/enrol/index.php" || np == "/login/signup.php" || np == "/login/forgot_password.php")
        return ((method ~ /^[A-Z]+$/) ? method : "-") " " np
    if (np == "/login/confirm.php") return "/login/confirm.php"
    if (np ~ /^\/admin\/tool\/installaddon(\/|$)/) return "/admin/tool/installaddon/*"
    if (np ~ /^\/my(\/|$)/) return "/my/*"
    if (np == "/course/view.php") return "/course/view.php"
    if (np ~ /^\/mod\/quiz\//) return "/mod/quiz/*"
    if (np == "/lib/ajax/service.php") return "/lib/ajax/service.php"
    if (np ~ /^\/pluginfile\.php\/\*\/local_[a-z0-9_]+(\/|$)/) return "/pluginfile.php/*/local_* (page builders, local plugins)"
    if (np ~ /^\/pluginfile\.php\/\*\/theme_[a-z0-9_]+(\/|$)/) return "/pluginfile.php/*/theme_*"
    if (np ~ /^\/pluginfile\.php\/\*\/course\/overviewfiles$/) return "/pluginfile.php/*/course/overviewfiles"
    if (np ~ /^\/pluginfile\.php(\/|$)/) return "/pluginfile.php/* (other)"
    if (np == "/login/index.php") return ((method ~ /^[A-Z]+$/) ? method : "-") " /login/index.php"
    if (np == "/login/token.php" || np == "/webservice/rest/server.php") return "mobile app (token.php, rest/server.php)"
    if (np ~ /^\/admin(\/|$)/) return "/admin/*"
    if (np ~ /^\/mod\/hvp\//) return "/mod/hvp/*"
    if (np ~ /^\/theme\//) return "/theme/*"
    if (isphp && status == 404 && np !~ /\.php/ && np !~ /\/$/ && np ~ /^\//) return "r.php-routed 404"
    return ""
}

function v0(x) { return x == "" ? 0 : x }

function clearH() { HP50 = HP90 = HP95 = HP99 = HMAX = "" }

function ensure_day(day,    y) {
    if (day in Dend) return
    y = day; gsub(/-/, " ", y)
    Dend[day] = mktime(y " 00 00 00") + 86400
    DAYSEEN[day] = 1
    UCip[day]["\001"] = 1; delete UCip[day]["\001"]
}

function pct_line(h, hn, k,   a50, a95, a99, amax) {
    # helper used by out_minute/out_hour: returns "p50\tp95\tp99\tmax" for h[k]
    if (k in h) hstats(h[k], hn[k] + 0); else clearH()
    return HP50 T HP95 T HP99 T HMAX
}

# Top client of one minute or hour: sets TOPIP and TOPN from cnt (ip -> count).
# Ties go to the smaller address string, so the result is deterministic.
function top_of(cnt,    ip) {
    TOPIP = ""; TOPN = 0
    for (ip in cnt) if (cnt[ip] > TOPN || (cnt[ip] == TOPN && ip < TOPIP)) { TOPN = cnt[ip]; TOPIP = ip }
}

function out_minute(m,    rtpart, urtpart, share) {
    rtpart  = pct_line(Mrt, Mrtn, m)
    urtpart = pct_line(Murt, Mphp, m)
    if (m in Mip) top_of(Mip[m]); else { TOPIP = ""; TOPN = 0 }
    share = (Mreq[m] ? TOPN / Mreq[m] : 0)
    print strftime("%Y-%m-%d %H:%M", m) T Mreq[m] T v0(Mphp[m]) T v0(M2[m]) T v0(M3[m]) T v0(M4[m]) T v0(M5[m]) T \
          v0(M499[m]) T v0(M502[m]) T v0(M504[m]) T length(Mip[m]) T rtpart T urtpart T v0(Mgt1[m]) T v0(Mgt5[m]) T v0(Mbytes[m]) T \
          v0(Mfront[m]) T v0(Mr404[m]) T TOPN T sprintf("%.4f", share) T v0(Mbig[m]) > F_MIN
    # kept for per_minute_top_client.tsv (pseudonyms exist only at END)
    if (TOPIP != "") {
        MT_ip[m] = TOPIP; MT_n[m] = TOPN; MT_req[m] = Mreq[m]; MT_front[m] = v0(Mfront[m])
        MT_php[m] = v0(Mipphp[m][TOPIP]); MT_tfront[m] = v0(Mipfront[m][TOPIP]); MT_cls[m] = Mipcls[m][TOPIP]
    }
    delete Mreq[m]; delete Mphp[m]; delete M2[m]; delete M3[m]; delete M4[m]; delete M5[m]
    delete M499[m]; delete M502[m]; delete M504[m]; delete Mip[m]; delete Mrt[m]; delete Mrtn[m]
    delete Murt[m]; delete Mgt1[m]; delete Mgt5[m]; delete Mbytes[m]
    delete Mfront[m]; delete Mr404[m]; delete Mbig[m]; delete Mipphp[m]; delete Mipfront[m]; delete Mipcls[m]
}

function out_hour(h,    rtpart, urtpart, p90, g, gi, gn, gord, ep99, share) {
    rtpart = pct_line(Hrt, Hrtn, h)
    if (h in Hurt) { hstats(Hurt[h], Hphp[h] + 0) } else clearH()
    urtpart = HP50 T HP95 T HP99 T HMAX; p90 = HP90
    if (h in Hip) top_of(Hip[h]); else { TOPIP = ""; TOPN = 0 }
    share = (Hreq[h] ? TOPN / Hreq[h] : 0)
    print strftime("%Y-%m-%d %H:00", h) T Hreq[h] T (PERF ? v0(Hphp[h]) : "") T v0(H2[h]) T v0(H3[h]) T v0(H4[h]) T v0(H5[h]) T \
          v0(H499[h]) T v0(H502[h]) T v0(H504[h]) T length(Hip[h]) T rtpart T urtpart T \
          (PERF ? v0(Hgt1[h]) : "") T (PERF ? v0(Hgt5[h]) : "") T v0(Hbytes[h]) T length(Hua[h]) T v0(Hbot[h]) T p90 T \
          v0(Hfront[h]) T (PERF ? v0(Hr404[h]) : "") T TOPN T sprintf("%.4f", share) T v0(Hbig[h]) > F_HOUR
    if (PERF && (h in EH)) {
        gn = asorti(EH[h], gord)
        for (gi = 1; gi <= gn; gi++) {
            g = gord[gi]
            if ((h in EHu) && (g in EHu[h])) hstats(EHu[h][g], EHn[h][g] + 0); else clearH()
            print strftime("%Y-%m-%d %H:00", h) T g T EH[h][g] T ((h in EHn) && (g in EHn[h]) ? EHn[h][g] : 0) T HP50 T HP95 T HMAX T \
                  HP99 T v0(EH499[h][g]) T v0(EH5[h][g]) T v0(EHb[h][g]) T v0(EHbig[h][g]) > F_EP
        }
    }
    delete Hreq[h]; delete Hphp[h]; delete H2[h]; delete H3[h]; delete H4[h]; delete H5[h]
    delete H499[h]; delete H502[h]; delete H504[h]; delete Hip[h]; delete Hrt[h]; delete Hrtn[h]
    delete Hurt[h]; delete Hgt1[h]; delete Hgt5[h]; delete Hbytes[h]; delete Hua[h]; delete Hbot[h]
    delete EH[h]; delete EHn[h]; delete EHu[h]
    delete Hfront[h]; delete Hr404[h]; delete Hbig[h]; delete EH499[h]; delete EH5[h]; delete EHb[h]; delete EHbig[h]
}

function out_day(d,    n, v, i, top1, top10, top100, gt1k, gt10k, tot, rtp50, rtp95, k, ord, z, c, cn, cord) {
    tot = Dreq[d]
    n = asort(Dip[d], v, "@val_num_desc")
    top1 = top10 = top100 = gt1k = gt10k = 0
    for (i = 1; i <= n; i++) {
        if (i <= 1) top1 += v[i]
        if (i <= 10) top10 += v[i]
        if (i <= 100) top100 += v[i]
        if (v[i] > 1000) gt1k++
        if (v[i] > 10000) gt10k++
    }
    if (d in Drt) hstats(Drt[d], Drtn[d] + 0); else clearH()
    rtp50 = HP50; rtp95 = HP95
    if (d in Durt) hstats(Durt[d], Dphp[d] + 0); else clearH()
    printf "%s\t%d\t%s\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", d, tot, (PERF ? v0(Dphp[d]) : ""), n,
        (tot ? Dbot[d] / tot : 0), (tot ? top1 / tot : 0), (tot ? top10 / tot : 0), (tot ? top100 / tot : 0),
        gt1k, gt10k, v0(D4[d]), v0(D5[d]), rtp50, rtp95, HP50, HP95, HP99 > F_DAY
    # status x path, top 50 for the day
    if (d in SP) {
        n = asorti(SP[d], ord, "@val_num_desc")
        for (i = 1; i <= n && i <= 50; i++) {
            split(ord[i], z, SUBSEP)
            k = z[2]
            print d T z[1] T substr(k, 1, index(k, " ") - 1) T substr(k, index(k, " ") + 1) T SP[d][ord[i]] > F_SPD
        }
    }
    if (d in UC) {
        cn = asorti(UC[d], cord)
        for (i = 1; i <= cn; i++) {
            c = cord[i]
            print d T c T UC[d][c] T v0(UCipn[d][c]) > F_UAD
        }
    }
    delete Dreq[d]; delete Dphp[d]; delete Dbot[d]; delete Dip[d]; delete Drt[d]; delete Drtn[d]
    delete Durt[d]; delete D4[d]; delete D5[d]; delete SP[d]; delete UC[d]; delete UCip[d]; delete UCipn[d]
    DFLUSHED[d] = 1
}

function flush_all(limit,    k, ord, n, i) {
    if (PERF) {
        n = 0; delete ord
        for (k in Mreq) if (k + 60 <= limit) ord[++n] = k + 0
        if (n) { asort(ord); for (i = 1; i <= n; i++) { out_minute(ord[i]); if (ord[i] > Mflushed) Mflushed = ord[i] } }
    }
    n = 0; delete ord
    for (k in Hreq) if (k + 3600 <= limit) ord[++n] = k + 0
    if (n) { asort(ord); for (i = 1; i <= n; i++) { out_hour(ord[i]); if (ord[i] > Hflushed) Hflushed = ord[i] } }
    n = 0; delete ord
    for (k in Dreq) if (Dend[k] <= limit) ord[++n] = k
    if (n) { asort(ord); for (i = 1; i <= n; i++) out_day(ord[i]) }
}

function slow_prune(    ord, n, i, nv, nr) {
    n = asorti(SLv, ord, "@val_num_desc")
    for (i = 1; i <= n && i <= SLOWKEEP; i++) { nv[i] = SLv[ord[i]]; nr[i] = SLr[ord[i]] }
    delete SLv; delete SLr
    nslow = 0
    for (i = 1; i in nv; i++) { nslow++; SLv[nslow] = nv[i]; SLr[nslow] = nr[i] }
    slowmin = (nslow >= SLOWKEEP) ? SLv[nslow] : -1
}

# One request of a "full list" kind (5xx, 414, installaddon).  Every
# (kind, status, method path) key is kept; there is no top-N cut.  Per key:
# count, distinct clients (IPs stay in memory; only the count and the top
# client's pseudonym are written), UA classes, PHP count, max urt, first and
# last minute, and a per-minute count.
function sd_add(kind,    k) {
    k = kind SUBSEP status SUBSEP key
    SD[k]++
    SDip[k][ip]++
    SDcls[k][cls]++
    if (isphp) { SDphp[k]++; if (urt + 0 > SDumax[k] + 0) SDumax[k] = urt }
    if (!(k in SDf) || mi < SDf[k]) SDf[k] = mi
    if (mi > SDl[k] + 0) SDl[k] = mi
    SDM[k SUBSEP mi]++
}

# ------------------------------------------------------------------ main
# Parses one record split on '"'.  Sets globals ts ip method np status bytes
# ua cls bot rt urt isphp hasrt key P.  Returns 0 for a bad timestamp, -1 for
# a line before the cutoff, 1 otherwise.
function parse_rec(f1, f2, f3, f6, f7, nf,    t, off, a, r, nr, sb, mm, uu) {
    if (!match(f1, /\[([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})\]/, t) || !(t[2] in MON))
        return 0
    ts = mktime(t[3] " " MON[t[2]] " " t[1] " " t[4] " " t[5] " " t[6], 1)
    off = t[8] * 3600 + t[9] * 60
    ts -= (t[7] == "-") ? -off : off
    if (ts < cutoff) return -1
    split(f1, a, " "); ip = a[1]
    nr = split(f2, r, " ")
    if (nr != 3 || r[1] !~ /^[A-Z]+$/) { method = "-"; np = "<malformed>"; NP_AJ = ""; NP_WS = ""; MALF = 1 }
    else { method = r[1]; np = normpath(r[2]); MALF = 0 }
    split(f3, sb, " "); status = sb[1] + 0; bytes = sb[2] + 0
    ua = (nf >= 6) ? f6 : ""
    cls = uaclass(ua)
    bot = isbot(cls)
    rt = ""; urt = ""; isphp = 0
    if (PERF) {
        if (match(f7, /(^| )rt=([0-9.]+)/, mm)) rt = mm[2]
        if (match(f7, /urt=([0-9.]+)/, uu)) { urt = uu[1]; isphp = 1 }
    }
    hasrt = (rt != "")
    key = method " " np
    P = (ts < surge) ? "P0" : "P1"
    return 1
}

{
    nread++
    pr = parse_rec($1, $2, $3, $6, $7, NF)
    if (pr == 0) { bad_ts++; next }
    if (pr < 0) { before++; next }
    inwin++
    if (MALF) malformed++
    if (first_ts == "" || ts < first_ts) first_ts = ts
    if (ts > last_ts) last_ts = ts
    if (ts > newest) newest = ts
    mi = ts - ts % 60
    hr = ts - ts % 3600
    day = strftime("%Y-%m-%d", ts)
    sc = int(status / 100)
    g = epgroup(np, isphp, status, method)
    isfront = (g == "/")
    isbig = (bytes > BIG)

    # ---- per minute (perf only)
    if (PERF) {
        if (mi <= Mflushed) late_min++
        else {
            Mreq[mi]++; Mbytes[mi] += bytes
            if (sc == 2) M2[mi]++; else if (sc == 3) M3[mi]++; else if (sc == 4) M4[mi]++; else if (sc == 5) M5[mi]++
            if (status == 499) M499[mi]++; else if (status == 502) M502[mi]++; else if (status == 504) M504[mi]++
            Mip[mi][ip]++
            Mipcls[mi][ip] = cls
            if (isfront) { Mfront[mi]++; Mipfront[mi][ip]++ }
            if (g == "r.php-routed 404") Mr404[mi]++
            if (isbig) Mbig[mi]++
            if (hasrt) { Mrt[mi][rt]++; Mrtn[mi]++ }
            if (isphp) { Mphp[mi]++; Mipphp[mi][ip]++; Murt[mi][urt]++; if (urt + 0 > 1) Mgt1[mi]++; if (urt + 0 > 5) Mgt5[mi]++ }
        }
    }
    # ---- per hour
    if (hr <= Hflushed) late_hour++
    else {
        Hreq[hr]++; Hbytes[hr] += bytes; Hbot[hr] += bot
        if (sc == 2) H2[hr]++; else if (sc == 3) H3[hr]++; else if (sc == 4) H4[hr]++; else if (sc == 5) H5[hr]++
        if (status == 499) H499[hr]++; else if (status == 502) H502[hr]++; else if (status == 504) H504[hr]++
        Hip[hr][ip]++
        Hua[hr][ua] = 1
        if (isfront) Hfront[hr]++
        if (g == "r.php-routed 404") Hr404[hr]++
        if (isbig) Hbig[hr]++
        if (hasrt) { Hrt[hr][rt]++; Hrtn[hr]++ }
        if (isphp) { Hphp[hr]++; Hurt[hr][urt]++; if (urt + 0 > 1) Hgt1[hr]++; if (urt + 0 > 5) Hgt5[hr]++ }
        if (PERF && g != "") {
            EH[hr][g]++
            EHb[hr][g] += bytes
            if (isbig) EHbig[hr][g]++
            if (status == 499) EH499[hr][g]++
            if (sc == 5) EH5[hr][g]++
            if (isphp) { EHn[hr][g]++; EHu[hr][g][urt]++ }
        }
    }
    # ---- per day
    if (day in DFLUSHED) late_day++
    else {
        ensure_day(day)
        Dreq[day]++; Dbot[day] += bot
        Dip[day][ip]++
        if (sc == 4) D4[day]++; else if (sc == 5) D5[day]++
        if (hasrt) { Drt[day][rt]++; Drtn[day]++ }
        if (isphp) { Dphp[day]++; Durt[day][urt]++ }
        if (status >= 400) SP[day][status SUBSEP key]++
        UC[day][cls]++
        if (!((cls SUBSEP ip) in UCip[day])) { UCip[day][cls SUBSEP ip] = 1; UCipn[day][cls]++ }
    }
    DAYSEEN[day] = 1

    # ---- per period
    Preq[P]++
    PC[P][key]++
    if (sc == 4) PN4[P][key]++; else if (sc == 5) PN5[P][key]++
    PB[P][key] += bytes
    if (bytes > PBM[P][key] + 0) PBM[P][key] = bytes
    if (isbig) PBG[P][key]++
    # ---- per period and endpoint group
    if (PERF && g != "") {
        EP[P][g]++
        EPb[P][g] += bytes
        if (bytes > EPbm[P][g] + 0) EPbm[P][g] = bytes
        if (isbig) EPbig[P][g]++
        if (sc == 2) EP2[P][g]++; else if (sc == 3) EP3[P][g]++; else if (sc == 4) EP4[P][g]++; else if (sc == 5) EP5[P][g]++
        if (status == 499) EP499[P][g]++
        if (hasrt) { EPr[P][g][rt]++; EPrn[P][g]++ }
        if (isphp) { EPn[P][g]++; EPu[P][g][urt]++; EPs[P][g] += urt }
    }
    # ---- full lists for 5xx, 414 and installaddon
    if (status >= 500) sd_add("5xx")
    # A 414 request line is cut at the end of nginx's header buffer, so it has
    # no " HTTP/x" part and parse_rec() marks it malformed.  For the 414 list
    # only, "METHOD /path..." is normalised (query stripped as usual) and
    # tagged "[cut]"; every other output keeps "- <malformed>".
    if (status == 414) {
        k414 = key
        if (MALF && split($2, r414, " ") == 2 && r414[1] ~ /^[A-Z]+$/ && substr(r414[2], 1, 1) == "/") {
            sa414 = NP_AJ; sw414 = NP_WS
            key = r414[1] " " normpath(r414[2]) "[cut]"
            NP_AJ = sa414; NP_WS = sw414
        }
        sd_add("414")
        key = k414
    }
    if (np ~ /^\/admin\/tool\/installaddon(\/|$)/) sd_add("installaddon")
    if (isphp) {
        Pphp[P]++
        PS[P][key] += urt; PU[P][key][urt]++; PUn[P][key]++
        if (!((P SUBSEP key) in PMAX) || urt + 0 > PMAX[P, key] + 0) PMAX[P, key] = urt
    }
    if (hasrt) { PR[P][key][rt]++; PRn[P][key]++ }
    PD[key][day]++; PDT[key]++

    if (NP_AJ != "") {
        nm = split(NP_AJ, am, ",")
        for (j = 1; j <= nm; j++) {
            if (am[j] == "") continue
            AJc[P][am[j]]++
            if (isphp) { AJs[P][am[j]] += urt; AJu[P][am[j]][urt]++; AJn[P][am[j]]++ }
        }
    }
    if (NP_WS != "") {
        WSc[P][NP_WS]++
        if (isphp) { WSs[P][NP_WS] += urt; WSu[P][NP_WS][urt]++; WSn[P][NP_WS]++ }
    }

    # ---- user agents
    if (!(ua in UAT)) {
        if (nuat > 200000) { delete UAT; nuat = 0 }
        UAT[ua] = uatrunc(ua); nuat++
    }
    uat = UAT[ua]
    UAc[P][uat]++
    UAcl[uat] = cls
    if (!((P, uat, ip) in UAip) && UAipn[P, uat] + 0 < UAIPCAP) { UAip[P, uat, ip] = 1; UAipn[P, uat]++ }

    # ---- clients (IPs stay in memory only; details come from pass 2)
    G[ip]++
    pfx = prefix16(ip)
    if (!(ip in CR[P])) FIpn[P, pfx]++
    CR[P][ip]++
    FR[P][pfx]++
    FC[P, pfx, cls]++

    # ---- slowest and own monitor
    if (PERF && isphp && (nslow < SLOWKEEP || urt + 0 > slowmin)) {
        nslow++
        SLv[nslow] = urt + 0
        SLr[nslow] = strftime("%Y-%m-%d %H:%M", mi) T method T np \
                     (NP_AJ != "" ? "?info=" NP_AJ : (NP_WS != "" ? "?wsfunction=" NP_WS : "")) \
                     T status T rt T urt T bytes T cls
        if (nslow >= 2 * SLOWKEEP) slow_prune()
    }
    if (cls == "self_monitor")
        print strftime("%Y-%m-%d %H:%M:%S", ts) T method T np T status T rt T urt T bytes > F_MON

    if (newest - lastflush >= 60) { flush_all(newest - GRACE); lastflush = newest }
}

# ------------------------------------------------------------------ end
function top_class(P, ip,    c, best, bn) {
    best = ""; bn = -1
    for (c in CLSNAMES) if (((P, ip, c) in CC) && CC[P, ip, c] > bn) { bn = CC[P, ip, c]; best = c }
    return best
}

function top_class_pfx(P, pf,    c, best, bn) {
    best = ""; bn = -1
    for (c in CLSNAMES) if (((P, pf, c) in FC) && FC[P, pf, c] > bn) { bn = FC[P, pf, c]; best = c }
    return best
}

function write_paths(P,    f, ord, n, i, k, sel, lists, L, rtp50, rtp95, umax) {
    f = outdir "/top_paths_" P ".tsv"
    print "list" T "rank" T "method" T "norm_path" T "count" T "share" T "sum_urt" T "urt_p50" T "urt_p95" T "urt_p99" T \
          "urt_max" T "n4xx" T "n5xx" T "rt_p50" T "rt_p95" T "bytes_sum" T "bytes_max" T "n_bytes_gt32k" > f
    if (!(P in PC)) return
    for (L = 1; L <= 2; L++) {
        delete ord
        if (L == 1) { if (!PERF || !(P in PS)) continue; n = asorti(PS[P], ord, "@val_num_desc") }
        else n = asorti(PC[P], ord, "@val_num_desc")
        for (i = 1; i <= n && i <= top_paths; i++) {
            k = ord[i]
            if ((P in PR) && (k in PR[P])) hstats(PR[P][k], PRn[P][k] + 0); else clearH()
            rtp50 = HP50; rtp95 = HP95
            if ((P in PU) && (k in PU[P])) hstats(PU[P][k], PUn[P][k] + 0); else clearH()
            umax = ((P SUBSEP k) in PMAX) ? PMAX[P, k] : ""
            printf "%s\t%d\t%s\t%s\t%d\t%.5f\t%.3f\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%d\t%d\t%d\n",
                (L == 1 ? "by_sum_urt" : "by_count"), i, substr(k, 1, index(k, " ") - 1), substr(k, index(k, " ") + 1),
                PC[P][k], PC[P][k] / Preq[P], ((P in PS) && (k in PS[P]) ? PS[P][k] : 0), HP50, HP95, HP99, umax,
                ((P in PN4) && (k in PN4[P]) ? PN4[P][k] : 0), ((P in PN5) && (k in PN5[P]) ? PN5[P][k] : 0), rtp50, rtp95,
                ((P in PB) && (k in PB[P]) ? PB[P][k] : 0), ((P in PBM) && (k in PBM[P]) ? PBM[P][k] : 0),
                ((P in PBG) && (k in PBG[P]) ? PBG[P][k] : 0) > f
        }
    }
}

function write_methods(P, kind,    f, ord, n, i, m) {
    f = outdir "/" (kind == "ajax" ? "ajax_methods_" : "ws_functions_") P ".tsv"
    print (kind == "ajax" ? "method" : "wsfunction") T "count" T "php_count" T "sum_urt" T "urt_p50" T "urt_p95" T "urt_max" > f
    if (kind == "ajax") {
        if (!(P in AJc)) return
        n = asorti(AJc[P], ord, "@val_num_desc")
        for (i = 1; i <= n; i++) {
            m = ord[i]
            if ((P in AJu) && (m in AJu[P])) hstats(AJu[P][m], AJn[P][m] + 0); else clearH()
            printf "%s\t%d\t%d\t%.3f\t%s\t%s\t%s\n", m, AJc[P][m], ((P in AJn) && (m in AJn[P]) ? AJn[P][m] : 0),
                ((P in AJs) && (m in AJs[P]) ? AJs[P][m] : 0), HP50, HP95, HMAX > f
        }
    } else {
        if (!(P in WSc)) return
        n = asorti(WSc[P], ord, "@val_num_desc")
        for (i = 1; i <= n; i++) {
            m = ord[i]
            if ((P in WSu) && (m in WSu[P])) hstats(WSu[P][m], WSn[P][m] + 0); else clearH()
            printf "%s\t%d\t%d\t%.3f\t%s\t%s\t%s\n", m, WSc[P][m], ((P in WSn) && (m in WSn[P]) ? WSn[P][m] : 0),
                ((P in WSs) && (m in WSs[P]) ? WSs[P][m] : 0), HP50, HP95, HMAX > f
        }
    }
}

function write_ua(P,    f, ord, n, i, u) {
    f = outdir "/top_ua_" P ".tsv"
    print "ua_truncated" T "ua_class" T "count" T "uniq_ip" > f
    if (!(P in UAc)) return
    n = asorti(UAc[P], ord, "@val_num_desc")
    for (i = 1; i <= n && i <= top_ua; i++) {
        u = ord[i]
        print u T UAcl[u] T UAc[P][u] T (UAipn[P, u] + 0 >= UAIPCAP ? ">=" UAIPCAP : UAipn[P, u]) > f
    }
}

function select_clients(P,    ord, n, i) {
    n = asorti(CR[P], ord, "@val_num_desc")
    for (i = 1; i <= n && i <= top_clients; i++) { SELC[P, ord[i]] = i; SELIP[ord[i]] = 1; SELORD[P, i] = ord[i] }
    NSEL[P] = (n < top_clients) ? n : top_clients
}

# Pass 2: re-read the input and collect detail for the selected clients only.
function pass2(    cmd, nfl, fl, i, line, sp, q, nq, pr) {
    if (files == "") { PASS2 = "skipped (no -v files)"; return }
    cmd = "zcat -f --"
    nfl = split(files, fl, " ")
    for (i = 1; i <= nfl; i++) cmd = cmd " '" fl[i] "'"
    while ((cmd | getline line) > 0) {
        sp = index(line, " ")
        if (!(substr(line, 1, sp - 1) in SELIP)) continue
        nq = split(line, q, "\"")
        pr = parse_rec(q[1], q[2], q[3], q[6], q[7], nq)
        if (pr <= 0 || !((P, ip) in SELC)) continue
        mi = ts - ts % 60
        if (!((P, ip) in CF) || mi < CF[P, ip]) CF[P, ip] = mi
        if (mi > CL[P, ip] + 0) CL[P, ip] = mi
        if (isphp) { CP[P, ip]++; CS[P, ip] += urt }
        CC[P, ip, cls]++
        if ((P, ip, key) in CPa) CPa[P, ip, key]++
        else if (CPd[P, ip] + 0 < MAXCPATH) { CPa[P, ip, key] = 1; CPd[P, ip]++ }
        else CPo[P, ip]++
        p2lines++
    }
    close(cmd)
    PASS2 = "done lines=" p2lines + 0
}

function write_clients(P,    f, ord, n, i, ip, k, z, dp) {
    f = outdir "/top_clients_" P ".tsv"
    print "client" T "req" T "share" T "php_req" T "sum_urt" T "top_ua_class" T "top_path" T "first_minute" T "last_minute" T "distinct_paths" > f
    n = NSEL[P] + 0
    if (n == 0) return
    for (i = 1; i <= n; i++) ord[i] = SELORD[P, i]
    delete TPc; delete TPk
    for (k in CPa) {
        split(k, z, SUBSEP)
        if (z[1] != P || !((P, z[2]) in SELC)) continue
        if (CPa[k] > TPc[P, z[2]] + 0) { TPc[P, z[2]] = CPa[k]; TPk[P, z[2]] = z[3] }
    }
    for (i = 1; i <= n; i++) {
        ip = ord[i]
        dp = CPd[P, ip] + 0
        if (((P, ip) in CPo) && CPo[P, ip] > 0) dp = ">=" MAXCPATH
        printf "%s\t%d\t%.5f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", PSEUDO[ip], CR[P][ip], CR[P][ip] / Preq[P],
            (PERF ? CP[P, ip] + 0 : ""), (PERF ? sprintf("%.3f", CS[P, ip] + 0) : ""), top_class(P, ip),
            TPk[P, ip], (((P, ip) in CF) ? strftime("%Y-%m-%d %H:%M", CF[P, ip]) : ""),
            (((P, ip) in CL) ? strftime("%Y-%m-%d %H:%M", CL[P, ip]) : ""), dp > f
    }
}

function write_prefix(P,    f, ord, n, i, pf) {
    f = outdir "/top_prefix16_" P ".tsv"
    print "prefix" T "req" T "share" T "uniq_ip" T "top_ua_class" > f
    if (!(P in FR)) return
    n = asorti(FR[P], ord, "@val_num_desc")
    for (i = 1; i <= n && i <= top_prefix; i++) {
        pf = ord[i]
        printf "%s\t%d\t%.5f\t%d\t%s\n", pf, FR[P][pf], FR[P][pf] / Preq[P], FIpn[P, pf], top_class_pfx(P, pf) > f
    }
}

# ---- endpoint and status writers
function write_ep_summary(P,    f, ord, n, i, g, r50, r95, r99) {
    f = outdir "/endpoint_summary_" P ".tsv"
    print "group" T "req" T "php_req" T "urt_p50" T "urt_p90" T "urt_p95" T "urt_p99" T "urt_max" T "sum_urt" T \
          "rt_p50" T "rt_p95" T "rt_p99" T "s2xx" T "s3xx" T "s4xx" T "s499" T "s5xx" T \
          "bytes_sum" T "bytes_mean" T "bytes_max" T "n_bytes_gt32k" > f
    if (!(P in EP)) return
    n = asorti(EP[P], ord)
    for (i = 1; i <= n; i++) {
        g = ord[i]
        if ((P in EPr) && (g in EPr[P])) hstats(EPr[P][g], EPrn[P][g] + 0); else clearH()
        r50 = HP50; r95 = HP95; r99 = HP99
        if ((P in EPu) && (g in EPu[P])) hstats(EPu[P][g], EPn[P][g] + 0); else clearH()
        printf "%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.0f\t%d\t%d\n",
            g, EP[P][g], v0(EPn[P][g]), HP50, HP90, HP95, HP99, HMAX, v0(EPs[P][g]), r50, r95, r99,
            v0(EP2[P][g]), v0(EP3[P][g]), v0(EP4[P][g]), v0(EP499[P][g]), v0(EP5[P][g]),
            v0(EPb[P][g]), (EP[P][g] ? EPb[P][g] / EP[P][g] : 0), v0(EPbm[P][g]), v0(EPbig[P][g]) > f
    }
}

function best_key(arr,    k, best, bn) {
    best = ""; bn = -1
    for (k in arr) if (arr[k] > bn || (arr[k] == bn && k < best)) { bn = arr[k]; best = k }
    return best
}

function write_status_detail(    ord, n, i, k, z, kk, tc, cm, cmn, mord, mn, j, zz) {
    print "kind" T "status" T "method" T "norm_path" T "count" T "clients" T "top_client" T "top_client_req" T \
          "top_ua_class" T "php_req" T "urt_max" T "first_minute" T "last_minute" > F_SD
    print "minute" T "kind" T "status" T "method" T "norm_path" T "count" > F_SDM
    n = asorti(SD, ord)
    for (i = 1; i <= n; i++) {
        k = ord[i]
        split(k, z, SUBSEP)
        kk = z[3]
        tc = best_key(SDip[k])
        printf "%s\t%s\t%s\t%s\t%d\t%d\t%s\t%d\t%s\t%d\t%s\t%s\t%s\n", z[1], z[2], substr(kk, 1, index(kk, " ") - 1),
            substr(kk, index(kk, " ") + 1), SD[k], length(SDip[k]), PSEUDO[tc], SDip[k][tc], best_key(SDcls[k]),
            v0(SDphp[k]), SDumax[k], strftime("%Y-%m-%d %H:%M", SDf[k]), strftime("%Y-%m-%d %H:%M", SDl[k]) > F_SD
    }
    # per minute, sorted by minute then kind/status/path
    mn = 0
    for (k in SDM) { split(k, zz, SUBSEP); mord[++mn] = sprintf("%012d", zz[4]) SUBSEP zz[1] SUBSEP zz[2] SUBSEP zz[3] }
    asort(mord)
    for (j = 1; j <= mn; j++) {
        split(mord[j], zz, SUBSEP)
        kk = zz[4]
        print strftime("%Y-%m-%d %H:%M", zz[1] + 0) T zz[2] T zz[3] T substr(kk, 1, index(kk, " ") - 1) T \
              substr(kk, index(kk, " ") + 1) T SDM[zz[2] SUBSEP zz[3] SUBSEP zz[4] SUBSEP (zz[1] + 0)] > F_SDM
    }
}

function write_minute_top_client(    ord, n, i, m) {
    print "minute" T "req" T "front_req" T "top_client" T "top_client_req" T "top_client_share" T \
          "top_client_php_req" T "top_client_front_req" T "top_client_ua_class" > F_MTC
    n = 0
    for (m in MT_ip) ord[++n] = m + 0
    asort(ord)
    for (i = 1; i <= n; i++) {
        m = ord[i]
        printf "%s\t%d\t%d\t%s\t%d\t%.4f\t%d\t%d\t%s\n", strftime("%Y-%m-%d %H:%M", m), MT_req[m], MT_front[m],
            PSEUDO[MT_ip[m]], MT_n[m], (MT_req[m] ? MT_n[m] / MT_req[m] : 0), MT_php[m], MT_tfront[m], MT_cls[m] > F_MTC
    }
}

END {
    if (_noout) exit 2     # BEGIN refused (no outdir): END must not write to "/<file>"
    flush_all(2 ^ 53)
    split("empty self_monitor scanner_quoted_ua scanner_go_pentest scanner_libredtail scanner_websiphon googlebot bingbot yandex baidu applebot meta bytedance ai_crawler petalbot seo_blocked other_bot moodle_mobile library monitor suspect_chrome120_6099 browser_mobile browser_desktop", cl, " ")
    for (i in cl) CLSNAMES[cl[i]] = 1
    # Per-run pseudonyms, ranked by requests over the whole window.
    ng = asorti(G, gord, "@val_num_desc")
    for (i = 1; i <= ng; i++) PSEUDO[gord[i]] = sprintf("C%04d", i)

    split("P0 P1", PP, " ")
    select_clients("P0"); select_clients("P1")
    pass2()
    for (pi = 1; pi <= 2; pi++) {
        P = PP[pi]
        write_paths(P)
        write_ua(P)
        write_clients(P)
        write_prefix(P)
        if (PERF) { write_methods(P, "ajax"); write_methods(P, "ws"); write_ep_summary(P) }
    }
    write_status_detail()
    if (PERF) write_minute_top_client()

    # path x day matrix, top 30 paths by count
    nd = asorti(DAYSEEN, dord)
    hdr = "method" T "norm_path" T "total"
    for (i = 1; i <= nd; i++) hdr = hdr T dord[i]
    print hdr > F_PDM
    np_ = asorti(PDT, pord, "@val_num_desc")
    for (i = 1; i <= np_ && i <= 30; i++) {
        k = pord[i]
        line = substr(k, 1, index(k, " ") - 1) T substr(k, index(k, " ") + 1) T PDT[k]
        for (j = 1; j <= nd; j++) line = line T ((dord[j] in PD[k]) ? PD[k][dord[j]] : 0)
        print line > F_PDM
    }

    if (PERF) {
        if (nslow > SLOWKEEP) slow_prune()
        print "minute" T "method" T "norm_path" T "status" T "rt" T "urt" T "bytes" T "ua_class" > F_SLOW
        n = asorti(SLv, sord, "@val_num_desc")
        for (i = 1; i <= n && i <= SLOWKEEP; i++) print SLr[sord[i]] > F_SLOW
    }

    print "key" T "value" > F_META
    print "aggregator_version" T AGG_VERSION > F_META
    print "fmt" T fmt > F_META
    print "ua_maxlen" T (UA_MAXLEN ? UA_MAXLEN : 300) > F_META
    print "big_response_bytes" T BIG > F_META
    print "cutoff_epoch" T cutoff T strftime("%Y-%m-%d %H:%M:%S %z", cutoff) > F_META
    print "surge_epoch" T surge T strftime("%Y-%m-%d %H:%M:%S %z", surge) > F_META
    print "lines_read" T nread + 0 > F_META
    print "lines_bad_timestamp" T bad_ts + 0 > F_META
    print "lines_before_cutoff" T before + 0 > F_META
    print "lines_in_window" T inwin + 0 > F_META
    print "lines_malformed_request" T malformed + 0 > F_META
    print "late_lines_minute_skipped" T late_min + 0 > F_META
    print "late_lines_hour_skipped" T late_hour + 0 > F_META
    print "late_lines_day_skipped" T late_day + 0 > F_META
    print "first_ts" T (first_ts == "" ? "" : strftime("%Y-%m-%d %H:%M:%S %z", first_ts)) > F_META
    print "last_ts" T (last_ts == "" ? "" : strftime("%Y-%m-%d %H:%M:%S %z", last_ts)) > F_META
    print "distinct_clients_window" T ng > F_META
    print "req_P0" T Preq["P0"] + 0 > F_META
    print "req_P1" T Preq["P1"] + 0 > F_META
    print "php_req_P0" T Pphp["P0"] + 0 > F_META
    print "php_req_P1" T Pphp["P1"] + 0 > F_META
    print "pass2" T PASS2 > F_META

    printf "access_agg: fmt=%s read=%d in_window=%d before_cutoff=%d bad_ts=%d malformed=%d late_min=%d clients=%d\n",
        fmt, nread, inwin, before, bad_ts, malformed, late_min, ng
}
