#!/bin/bash
set +x   # never trace: this script reads secrets (bash -x would print them)
# owner-setup-sharepoint.sh: run by the OWNER (never by Claude). Creates the two rclone remotes of moodle-backup for a
# SharePoint document library (Microsoft 365):
#   m365            the document library (rclone "onedrive" backend, drive_type=documentLibrary)
#   <NAME>-crypt    client-side encryption on top of m365:<folder> (file names + contents; folder names readable)
# in /var/lib/<NAME>/rclone/rclone.conf (root 0600, directory 0700; the backup service must be able to rewrite it,
# because Microsoft rolls the refresh token on every use), and tests them. Part of moodle-server-care (skills/backup).
#
#   sudo bash owner-setup-sharepoint.sh [--name NAME] [--set-prefix P]                 first setup
#   sudo bash owner-setup-sharepoint.sh --renew-token [--name NAME]   new Microsoft token only (revoked or expired token,
#                                       e.g. after "Revoke sessions"); passphrases, library and ACCOUNT stay as they
#                                       are (a token of another account is refused)
#   sudo bash owner-setup-sharepoint.sh --read-only [--name NAME]     restore-drill host: same passphrases, no write test
#
# Tests after writing the config: library reachable; one forced token refresh (Microsoft accepts rclone's refresh and
# rclone saves the new token: otherwise the first long run would fail hours later); the passphrases open what is
# already in the folder (keycheck object, or names that decrypt); encrypted write/read/delete; the keycheck object.
#
# Before running: on YOUR OWN computer run   rclone authorize "onedrive"   , sign in in the browser AS THE BACKUP
# ACCOUNT, and keep the terminal with the result open. The access part of that token is valid about one hour.
#
# Secrets (token, passphrases) are typed into hidden prompts. They are not echoed, not stored in shell history, never
# passed as command arguments or environment (so never visible in `ps` or /proc), and never written to a temporary
# file other than the config's own .tmp (0600, removed on any exit). Microsoft Graph is queried by python3, which
# reads the token from its stdin. Run this in your own SSH session after `unset HISTFILE`.
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin

NAME=moodle-backup
SET_PREFIX=moodle
MODE=new
while [ $# -gt 0 ]; do
  case "$1" in
    --read-only) MODE=readonly; shift ;;
    --renew-token) MODE=renew; shift ;;
    --name) NAME=${2:-}; shift 2 ;;
    --set-prefix) SET_PREFIX=${2:-}; shift 2 ;;
    *) echo "usage: $0 [--renew-token | --read-only] [--name NAME] [--set-prefix P]" >&2; exit 2 ;;
  esac
done
[[ $NAME =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || { echo "Bad --name." >&2; exit 2; }
[[ $SET_PREFIX =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Bad --set-prefix." >&2; exit 2; }

STATE=/var/lib/$NAME
CONF_DIR=$STATE/rclone
CONF=$CONF_DIR/rclone.conf
ERRF=$CONF_DIR/setup-errors.log   # rclone messages of the tests only (never secrets); removed on exit
KEYCHECK="keycheck/$SET_PREFIX-keycheck.txt"   # small encrypted object: later runs prove the passphrases by reading it
KEYCHECK_MARK="moodle-backup keycheck"
OD=m365
CRYPT=$NAME-crypt
GRAPH=https://graph.microsoft.com/v1.0
RCLONE_APP_ID=b15665d9-eda6-4092-8539-0eec376afd59    # rclone's public default OneDrive app id (rclone 1.60.x)
USER_AGENT="NONISV|MoodleServerCare|moodle-backup/msc-backup-1.1"
RE_PASS='^[[:graph:]][[:print:]]{22,}[[:graph:]]$'    # printable ASCII, 24+ characters, no space at either end
RE_SITE='^https://[A-Za-z0-9-]+\.sharepoint\.com/(sites|teams)/[A-Za-z0-9._-]+/?$'
RE_DRIVE='^b![A-Za-z0-9_-]{20,}$'
RE_FOLDER='^[A-Za-z0-9][A-Za-z0-9._-]{1,60}$'

REMOVE_CONF=0     # new/read-only: remove a config whose tests did not pass (it holds every secret)
RESTORE_PREV=0    # renew: put the previous config back if the new token does not pass
cleanup() {
  rm -f -- "$CONF.tmp" "$ERRF"
  if [ "$RESTORE_PREV" = 1 ] && [ -f "$CONF.prev" ]; then mv -f -- "$CONF.prev" "$CONF"; echo "Previous config restored." >&2; fi
  if [ "$REMOVE_CONF" = 1 ]; then rm -f -- "$CONF"; echo "The untested config was removed. Nothing is left behind." >&2; fi
  unset RAW TOKEN P1 P2 OP1 OP2
}
trap cleanup EXIT
trap 'echo >&2; echo "Interrupted." >&2; exit 130' INT TERM HUP

# ---------------------------------------------------------------- prompts
ask_secret() {  # ask_secret VAR "Prompt" REGEX [confirm]: asks again on any mistake, never exits between prompts
  local _v _w
  while :; do
    IFS= read -rsp "$2: " _v; echo >&2
    _v=${_v%$'\r'}
    [ -n "$_v" ] || continue                       # an empty line (e.g. the CR/LF tail of a paste): ask again
    if [ "${4:-}" = confirm ]; then
      while :; do IFS= read -rsp "    Same value again: " _w; echo >&2; _w=${_w%$'\r'}; [ -n "$_w" ] && break; done
      [ "$_v" = "$_w" ] || { echo "    The two entries differ. Paste it again." >&2; continue; }
    fi
    [[ $_v =~ $3 ]] || { echo "    Wrong format (24+ printable characters, no spaces at the ends). Paste it again." >&2; continue; }
    printf -v "$1" '%s' "$_v"; return 0
  done
}
ask_line() {  # ask_line VAR "Prompt" REGEX [default]: visible, not secret
  local _v
  while :; do
    IFS= read -rp "$2: " _v
    _v=${_v//$'\r'/}; _v=${_v#"${_v%%[![:space:]]*}"}; _v=${_v%"${_v##*[![:space:]]}"}
    [ -n "$_v" ] || _v=${4:-}
    if [[ $_v =~ $3 ]]; then printf -v "$1" '%s' "$_v"; return 0; fi
    echo "    Not valid, type it again." >&2
  done
}
# read_token VAR: hidden and NON-canonical (read -n): the token is 3-6 KB, and a terminal in normal (canonical) mode
# silently cuts a line at 4095 bytes. Accepts the paste on one line or wrapped over several, with or without rclone's
# "Paste the following ... --->" / "<---End paste" lines.
read_token() {
  local _l _t="" _i
  local re_end='\}[[:space:]]*(<---End[[:space:]]*paste)?[[:space:]]*$' re_skip='^[[:space:]]*(Paste the following.*)?$'
  echo "    Paste the whole result of 'rclone authorize' now, then press Enter (nothing is shown):" >&2
  for _i in $(seq 1 40); do
    IFS= read -rs -n 65536 _l || break
    _l=${_l//$'\r'/}
    _t+=$_l
    if [[ $_t == *'{'* ]]; then
      if [[ $_t =~ $re_end ]]; then break; fi      # JSON: wait for the closing brace (wrapped paste)
    elif ! [[ $_l =~ $re_skip ]]; then
      break                                        # one-line value (base64 form, or a wrong paste: checked next)
    fi                                             # blank line or rclone's "Paste the following" line: keep reading
  done
  while IFS= read -rs -t 0.5 -n 65536 _l; do :; done   # swallow the rest of the paste (end marker, blank lines)
  echo >&2
  printf -v "$1" '%s' "$_t"
}

# ---------------------------------------------------------------- python helpers (token on stdin, never in argv)
PY_M365='
import base64, datetime, json, sys, urllib.error, urllib.parse, urllib.request
def out(*f):
    print("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in f), flush=True)
def b64json(p):
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
def norm(raw):
    s = "".join(raw.split())
    for m in ("Pastethefollowingintoyourremotemachine--->", "<---Endpaste"):
        s = s.replace(m, "")
    i, j = s.find("{"), s.rfind("}")
    if i != -1 and j > i:
        c = s[i:j + 1]
    else:
        c = None
        for dec in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                c = dec(s + "=" * (-len(s) % 4)).decode(); break
            except Exception:
                pass
        if c is None:
            raise ValueError("neither JSON nor base64")
    o = json.loads(c)
    if isinstance(o, dict) and isinstance(o.get("token"), str):
        o = json.loads(o["token"])
    if not isinstance(o, dict):
        raise ValueError("not a JSON object")
    for k in ("access_token", "refresh_token", "expiry"):
        if not isinstance(o.get(k), str) or not o[k]:
            raise ValueError("no " + k + " in it")
    o["token_type"] = o.get("token_type") or "Bearer"
    return {k: o[k] for k in ("access_token", "token_type", "refresh_token", "expiry")}
def minutes_left(exp):
    try:
        e = datetime.datetime.fromisoformat(exp.replace("Z", "+00:00"))
        if e.tzinfo is None:
            e = e.replace(tzinfo=datetime.timezone.utc)
        return int((e - datetime.datetime.now(datetime.timezone.utc)).total_seconds() // 60)
    except Exception:
        return -9999
cmd = sys.argv[1]
data = sys.stdin.read()
if cmd == "token":
    try:
        t = norm(data)
    except Exception as e:
        out("ERR", "not a valid rclone token: " + str(e)); sys.exit(2)
    try:
        c = b64json(t["access_token"].split(".")[1])
    except Exception:
        c = {}
    print(json.dumps(t, separators=(",", ":")))
    out("INFO", c.get("appid") or c.get("azp") or "-", c.get("upn") or c.get("unique_name") or c.get("preferred_username") or "-",
        c.get("tid") or "-", c.get("scp") or "-", minutes_left(t["expiry"]), c.get("oid") or "-")
    sys.exit(0)
base, ua = sys.argv[2], sys.argv[3]
at = json.loads(data)["access_token"]
def get(path):
    req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + at, "Accept": "application/json", "User-Agent": ua})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        code = ""
        try:
            code = json.loads(e.read(4000).decode("utf-8", "replace"))["error"]["code"]
        except Exception:
            pass
        out("ERR", e.code, code, path.split("?")[0]); sys.exit(3)
    except Exception as e:
        out("ERR", "network", type(e).__name__, path.split("?")[0]); sys.exit(3)
if cmd == "site":
    # No GET /me: it needs User.Read, which is not among the rclone scopes; the account is decoded from the token.
    u = urllib.parse.urlsplit(sys.argv[4])
    site = get("/sites/" + u.hostname + ":" + urllib.parse.quote(u.path.rstrip("/")) + "?$select=id,displayName,webUrl")
    out("SITE", site["id"], site.get("displayName", "-"), site.get("webUrl", "-"))
    d = get("/sites/" + urllib.parse.quote(site["id"], safe="") + "/drives?$select=id,name,driveType,webUrl")
    for x in d.get("value", []):
        if x.get("driveType") == "documentLibrary":
            out("DRIVE", x["id"], x.get("name", "-"), x.get("driveType"), x.get("webUrl", "-"))
elif cmd == "drive":
    x = get("/drives/" + urllib.parse.quote(sys.argv[4], safe="!") + "?$select=id,name,driveType,webUrl")
    out("DRIVE", x["id"], x.get("name", "-"), x.get("driveType", "-"), x.get("webUrl", "-"))
'
py() { python3 -I -c "$PY_M365" "$@"; }

# get_token: ask until a usable token is pasted. Sets TOKEN (normalised JSON) and T_UPN, T_TID, T_SCP, T_OID.
get_token() {
  local out info appid mins
  while :; do
    read_token RAW
    if ! out=$(printf '%s' "$RAW" | py token); then
      echo "    ${out#*$'\t'}. Paste the result again (run rclone authorize again if needed)." >&2; continue
    fi
    TOKEN=${out%%$'\n'*}; info=${out#*$'\n'}
    IFS=$'\t' read -r _ appid T_UPN T_TID T_SCP mins T_OID <<<"$info"
    if [ "$appid" != - ] && [ "$appid" != "$RCLONE_APP_ID" ]; then
      echo "    This token belongs to app $appid, not to rclone's default OneDrive app ($RCLONE_APP_ID)." >&2
      echo "    Run: rclone authorize \"onedrive\"  (no client id/secret)." >&2; continue
    fi
    if [ "$mins" -lt 5 ]; then
      echo "    The token has expired (rclone authorize was run more than an hour ago, or the PC clock is wrong)." >&2
      echo "    Run rclone authorize \"onedrive\" again and paste the new result." >&2; continue
    fi
    echo "    Token OK. Signed-in account: $T_UPN (tenant $T_TID); access part valid ~$mins more minutes." >&2
    if [ "$T_SCP" != - ] && [[ " $T_SCP " != *" Files.ReadWrite.All "* ]]; then
      echo "    WARNING: permission Files.ReadWrite.All was not granted (scopes: $T_SCP). Writes to the library may fail." >&2
    fi
    return 0
  done
}

# old_identity: "<oid><TAB><upn>" of the account whose token is in the config now, from the token's claims
# ("-" when unknown). The token goes to python on stdin and is never printed.
old_identity() {
  local out oid upn
  out=$(awk -v s="[$OD]" '$0 == s {f = 1; next} /^\[/ {f = 0} f && index($0, "token = ") == 1 {print substr($0, 9); exit}' "$CONF" \
        | py token 2>/dev/null) || { printf -- '-\t-\n'; return 0; }
  IFS=$'\t' read -r _ _ upn _ _ _ oid <<<"${out#*$'\n'}"
  out=""
  printf '%s\t%s\n' "${oid:--}" "${upn:--}"
}

graph_error() {  # graph_error "<ERR line>"
  local _e code gcode
  IFS=$'\t' read -r _e code gcode _ <<<"$1"
  case "$code" in
    401) echo "    Microsoft refused the token (401 $gcode): expired, or consent for rclone missing (owner steps 3)." >&2 ;;
    403) echo "    Access denied (403 $gcode): the account is not allowed on that site, or Sites.Read.All was not granted." >&2 ;;
    404) echo "    Not found (404 $gcode): check the site URL (copy it from the browser, up to the site name)." >&2 ;;
    network) echo "    Network error ($gcode): no connection to graph.microsoft.com." >&2 ;;
    *) echo "    Microsoft Graph error $code $gcode." >&2 ;;
  esac
}

# ---------------------------------------------------------------- tests (after the config is written)
RL=(--config "$CONF" --user-agent "$USER_AGENT" --tpslimit 4)
fail=0
KC_FOUND=0
ok()  { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }
t_list() {
  if rclone lsf "${RL[@]}" --max-depth 1 "$OD:" >/dev/null 2>"$ERRF"; then ok "library reachable with the token"
  else bad "library listing failed:"; tail -n 3 "$ERRF" | sed 's/^/       /'; fi
}
tok_expiry() { sed -nE '/^token = /s/.*"expiry":"([^"]*)".*/\1/p' "$CONF" | head -n 1; }
t_refresh() {  # the pasted access token is fresh, so nothing else here makes rclone refresh it: force one refresh now
  sed -i -E '/^token = /s/"expiry":"[^"]*"/"expiry":"2000-01-01T00:00:00Z"/' "$CONF"
  if rclone lsf "${RL[@]}" --max-depth 1 "$OD:" >/dev/null 2>>"$ERRF" && [ "$(tok_expiry)" != 2000-01-01T00:00:00Z ] \
     && [ "$(stat -c %a "$CONF")" = 600 ]; then
    ok "token refresh works (Microsoft renewed the token and rclone saved it)"
  else
    bad "token refresh failed: Microsoft refused to renew the token, or rclone could not save it:"
    tail -n 3 "$ERRF" | sed 's/^/       /'
    echo "     (Conditional Access policy? Admin consent missing? See the owner steps, sections 1 and 3.)"
  fi
}
t_existing() {  # the passphrases must open what is already in the folder (rclone hides undecryptable names)
  local f raw dec r kc n=0
  for f in keycheck daily weekly monthly code; do
    r=0; raw=$(rclone lsf "${RL[@]}" --files-only "$OD:$LIB_PATH/$f/" 2>>"$ERRF") || r=$?
    if [ "$r" != 0 ] && [ "$r" != 3 ]; then bad "cannot list $LIB_PATH/$f/ (rclone exit $r)"; tail -n 3 "$ERRF" | sed 's/^/       /'; return 0; fi
    [ -n "$raw" ] || continue
    n=$(( n + $(wc -l <<<"$raw") ))
    # any set prefix proves the passphrases (renew and read-only runs do not know the install's --set-prefix)
    r=0; dec=$(rclone lsf "${RL[@]}" --files-only "$CRYPT:$f/" 2>>"$ERRF") || r=$?
    if [ "$f" = keycheck ]; then
      kc=$(grep -E '^[a-z0-9][a-z0-9-]*-keycheck\.txt$' <<<"$dec" | head -n 1 || true)
      if [ -n "$kc" ] && rclone cat "${RL[@]}" "$CRYPT:keycheck/$kc" 2>>"$ERRF" | grep "^$KEYCHECK_MARK" >/dev/null; then
        KC_FOUND=1; ok "passphrases open the existing backups (keycheck)"; t_otherhost; return 0
      fi
      continue
    fi
    # one decrypted name proves both passphrases (both feed the key that encrypts names and contents); a manifest is
    # not required, so an interrupted first upload is not mistaken for wrong passphrases
    if grep -Eq '^[a-z0-9][a-z0-9-]*-(db|users|config|manifest|code)-[0-9]{8}-[0-9]{4}\.' <<<"$dec"; then
      ok "passphrases open the existing backups (names in $f/ decrypt)"; t_otherhost; return 0
    fi
  done
  if [ "$n" = 0 ]; then ok "no earlier backups in $LIB_PATH/ (first install)"; return 0; fi
  bad "$n earlier object(s) in the folder but none opens with these passphrases."
  echo "     Use the passphrases those backups were made with (password manager). Nothing was uploaded."
}
t_otherhost() {  # first setup on a folder whose newest set came from another server: two writers would undo each other
  local m man host age_h
  [ "$MODE" = new ] || return 0
  m=$(rclone lsf "${RL[@]}" --files-only --include "$SET_PREFIX-manifest-*" "$CRYPT:daily/" 2>>"$ERRF" | sort | tail -n 1 || true)
  [ -n "$m" ] || return 0
  man=$(rclone cat "${RL[@]}" "$CRYPT:daily/$m" 2>>"$ERRF" | head -n 5 || true)
  host=$(sed -nE 's/^run=[0-9-]+ host=([^ ]+).*/\1/p' <<<"$man")
  age_h=$(( ($(date +%s) - $(date -d "$(sed -E 's/^.*-([0-9]{8})-([0-9]{2})([0-9]{2})\.txt$/\1 \2:\3/' <<<"$m")" +%s)) / 3600 ))
  if [ -n "$host" ] && [ "$host" != "$(hostname)" ]; then
    echo "     WARNING: the newest set was written by another server ($host), ${age_h} h ago."
    echo "     Two servers must NEVER write to the same folder: each would move the other's new files away."
    ask_line MOVEANS "     Type MOVE if this is a server move and the old server's timer is already disabled, or 'stop'" '^(MOVE|stop)$'
    [ "$MOVEANS" = MOVE ] || bad "stopped: choose another folder for this server, or disable the old server's timer first"
  fi
}
t_keycheck() {  # no keycheck object yet (first install): write it; every later run and setup reads it back
  [ "$KC_FOUND" = 0 ] || return 0
  if printf '%s written %s at setup\n' "$KEYCHECK_MARK" "$(date '+%F %T %z')" | rclone rcat "${RL[@]}" "$CRYPT:$KEYCHECK" 2>>"$ERRF" \
     && rclone cat "${RL[@]}" "$CRYPT:$KEYCHECK" 2>>"$ERRF" | grep "^$KEYCHECK_MARK" >/dev/null; then
    ok "keycheck object written ($KEYCHECK; it proves these passphrases to every later run)"
  else
    bad "could not write the keycheck object:"; tail -n 3 "$ERRF" | sed 's/^/       /'
  fi
}
t_canary() {
  local can raw
  can="canary/setup-$(date +%Y%m%d-%H%M%S).txt"
  if printf 'moodle-backup canary %s\n' "$(date '+%F %T')" | rclone rcat "${RL[@]}" "$CRYPT:$can" 2>"$ERRF" \
     && rclone cat "${RL[@]}" "$CRYPT:$can" 2>>"$ERRF" | grep '^moodle-backup canary' >/dev/null; then
    ok "encrypted write + read back"
    raw=$(rclone lsf "${RL[@]}" --files-only "$OD:$LIB_PATH/canary/" 2>>"$ERRF" || true)
    echo "     Name as stored in SharePoint (must be unreadable: digits and lowercase letters a-v, rclone's base32):"
    sed 's/^/       /' <<<"$raw"
    grep -Eqv '^[0-9a-v]+$' <<<"$raw" && bad "a stored name is not base32 (check filename_encoding)" || ok "names are base32 (safe on case-insensitive SharePoint)"
    if rclone deletefile "${RL[@]}" "$CRYPT:$can" 2>>"$ERRF"; then ok "canary deleted (it goes to the SharePoint recycle bin)"
    else bad "canary delete refused: the backup account needs Contribute (add/edit/delete) on the library"; fi
  else
    bad "encrypted write/read failed (account needs Contribute on the library):"; tail -n 3 "$ERRF" | sed 's/^/       /'
  fi
}

# ---------------------------------------------------------------- start
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
for c in rclone python3 flock; do command -v "$c" >/dev/null || { echo "$c is not installed." >&2; exit 1; }; done
mkdir -p "$STATE"; chmod 755 "$STATE"
mkdir -p -m 700 "$CONF_DIR"; chmod 700 "$CONF_DIR"
exec 9>"$STATE/run.lock"
flock -n 9 || { echo "A backup run is active right now. Try again in a few minutes." >&2; exit 1; }

if [ "$MODE" = renew ]; then
  [ -f "$CONF" ] || { echo "$CONF does not exist: run the first setup (without --renew-token)." >&2; exit 1; }
  DRIVE_ID=$(awk -v s="[$OD]" '$0 == s {f = 1; next} /^\[/ {f = 0} f && index($0, "drive_id = ") == 1 {print substr($0, 12); exit}' "$CONF")
  [[ $DRIVE_ID =~ $RE_DRIVE ]] || { echo "No valid drive_id in [$OD] of $CONF." >&2; exit 1; }
  LIB_PATH=$(awk -v s="[$CRYPT]" '$0 == s {f = 1; next} /^\[/ {f = 0} f && index($0, "remote = ") == 1 {print substr($0, 10); exit}' "$CONF")
  LIB_PATH=${LIB_PATH#"$OD":}
  IFS=$'\t' read -r OLD_OID OLD_UPN <<<"$(old_identity)"
  echo "== Renew the Microsoft token (library $DRIVE_ID, folder $LIB_PATH; passphrases are not touched) =="
  [ "$OLD_UPN" = - ] || echo "   The token must belong to the same backup account: $OLD_UPN"
  echo "1/2 New token from: rclone authorize \"onedrive\"  (signed in as the backup account, private browser window)"
  while :; do
    get_token
    # Same account only: a token of another account (an admin still signed in in the browser) would leave the server
    # with a delegated Files.ReadWrite.All token for everything that account can reach.
    if [ "$OLD_OID" != - ] && [ "$T_OID" != - ]; then same=$([ "$OLD_OID" = "$T_OID" ] && echo 1 || echo 0)
    elif [ "$OLD_UPN" != - ] && [ "$T_UPN" != - ]; then same=$([ "${OLD_UPN,,}" = "${T_UPN,,}" ] && echo 1 || echo 0)
    else
      echo "    The account of the current token cannot be read from the config." >&2
      ask_line ACC "    Type the backup account's sign-in name (as in the password manager)" '^[^[:space:]@]+@[^[:space:]@]+$'
      same=$([ "${ACC,,}" = "${T_UPN,,}" ] && echo 1 || echo 0)
    fi
    if [ "$same" != 1 ]; then
      if [ "$OLD_UPN" = - ]; then ou=""; else ou=" ($OLD_UPN)"; fi
      echo "    This token belongs to $T_UPN, not to the backup account$ou. Nothing changed." >&2
      echo "    Sign in as the backup account in a private browser window, run rclone authorize again, paste the result." >&2
      echo "    (Moving the backup to another account on purpose is a new setup with the SAME passphrases: owner steps 9.)" >&2
      continue
    fi
    if ! res=$(printf '%s' "$TOKEN" | py drive "$GRAPH" "$USER_AGENT" "$DRIVE_ID"); then graph_error "$res"; echo "    Paste a token of the backup account." >&2; continue; fi
    IFS=$'\t' read -r _ d_id d_name d_type d_url <<<"$res"
    [ "$d_id" = "$DRIVE_ID" ] && [ "$d_type" = documentLibrary ] || { echo "    Unexpected library ($d_id $d_type)." >&2; continue; }
    echo "    Library: $d_name ($d_url)"
    break
  done
  ask_line ANS "2/2 Replace the token for account $T_UPN? (yes/no)" '^(yes|no)$'
  [ "$ANS" = yes ] || { echo "Stopped. Nothing changed."; exit 1; }
  in_od=0; replaced=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "[$OD]") in_od=1 ;; "["*"]") in_od=0 ;; esac
    if [ "$in_od" = 1 ] && [[ $line == "token = "* ]]; then printf 'token = %s\n' "$TOKEN"; replaced=1
    else printf '%s\n' "$line"; fi
  done < "$CONF" > "$CONF.tmp"
  [ "$replaced" = 1 ] || { echo "No token line found in [$OD]. Nothing changed." >&2; exit 1; }
  chmod 600 "$CONF.tmp"
  cp -p -- "$CONF" "$CONF.prev"; RESTORE_PREV=1
  mv -f -- "$CONF.tmp" "$CONF"
  unset TOKEN RAW
  echo; echo "== Tests =="
  t_list
  [ "$fail" = 1 ] || t_refresh
  [ "$fail" = 1 ] || t_existing
  [ "$fail" = 1 ] || t_canary
  [ "$fail" = 1 ] || t_keycheck
  echo
  if [ "$fail" = 0 ]; then
    rm -f -- "$CONF.prev"; RESTORE_PREV=0
    echo "All tests passed: token renewed. Tell Claude: 'token renewed'. Save nothing: the token is not kept anywhere else."
    exit 0
  fi
  echo "A test failed; the previous config is put back. Fix the cause, run rclone authorize again, then this again."
  exit 1
fi

if [ -e "$CONF" ]; then
  echo "$CONF already exists. Nothing changed." >&2
  echo "New token only:  sudo bash $0 --renew-token --name $NAME" >&2
  echo "Start over: delete it first (sudo rm $CONF) and run this again with the SAME passphrases." >&2
  exit 1
fi

DEF_FOLDER=$(hostname -s | tr -c 'A-Za-z0-9._\n-' '-')
echo "== SharePoint (Microsoft 365) backup: rclone setup for $NAME =="
echo "Have ready: the site URL, the result of 'rclone authorize \"onedrive\"' (run it now if it is older than ~45 min),"
echo "the crypt passphrase and the crypt salt passphrase (password manager). Hidden prompts show nothing; that is normal."
[ "$MODE" = readonly ] && echo "Read-only mode (restore drill): no write test. Prefer an account with Read (Visitors) only on the site."
echo

ask_line SITE_URL "1/7 SharePoint site URL (like https://<tenant>.sharepoint.com/sites/<SiteName>)" "$RE_SITE"
SITE_URL=${SITE_URL%/}
echo "2/7 Token from: rclone authorize \"onedrive\"  (signed in as the BACKUP account)"
get_token
ask_line ANS "    Is $T_UPN the dedicated backup account? (yes/no)" '^(yes|no)$'
[ "$ANS" = yes ] || { echo "Stopped. Sign in as the backup account (private browser window) and run this again."; exit 1; }

DRIVE_ID=""; LIB_NAME=""
while [ -z "$DRIVE_ID" ]; do
  echo "    Looking up the document libraries of $SITE_URL ..."
  if res=$(printf '%s' "$TOKEN" | py site "$GRAPH" "$USER_AGENT" "$SITE_URL"); then
    mapfile -t drives < <(grep '^DRIVE' <<<"$res" || true)
    site_line=$(grep '^SITE' <<<"$res" || true)
    echo "    Site: $(cut -f3 <<<"$site_line")  ($(cut -f4 <<<"$site_line"))"
    if [ "${#drives[@]}" -eq 0 ]; then echo "    That site has no document library the account can see." >&2
    else
      for i in "${!drives[@]}"; do IFS=$'\t' read -r _ d_id d_name _ d_url <<<"${drives[$i]}"; printf '      %d) %s   %s\n' $((i + 1)) "$d_name" "$d_url"; done
      ask_line CH "3/7 Number of the library for the backups" '^[0-9]{1,2}$'
      if [ "$CH" -ge 1 ] && [ "$CH" -le "${#drives[@]}" ]; then
        IFS=$'\t' read -r _ DRIVE_ID LIB_NAME _ _ <<<"${drives[$((CH - 1))]}"; break
      fi
      echo "    No such number." >&2; continue
    fi
  else
    graph_error "$(grep '^ERR' <<<"$res" | head -n 1)"
  fi
  ask_line NEXT "    Type a corrected site URL, or 'manual' to paste the library's drive ID, or 'quit'" "^(manual|quit|https://.+)$"
  case "$NEXT" in
    quit) echo "Stopped. Nothing written."; exit 1 ;;
    manual) ask_line DRIVE_ID "    Drive ID (starts with b!)" "$RE_DRIVE"; LIB_NAME="(entered by hand)" ;;
    *) [[ ${NEXT%/} =~ $RE_SITE ]] && SITE_URL=${NEXT%/} || echo "    Not a SharePoint site URL." >&2 ;;
  esac
done
echo "    Library: $LIB_NAME  drive_id=$DRIVE_ID"
echo "    Each Moodle server needs its OWN folder in the library (two servers in one folder would undo each other)."
ask_line LIB_PATH "4/7 Folder for THIS server's backups [$DEF_FOLDER]" "$RE_FOLDER" "$DEF_FOLDER"

ask_secret P1 "5/7 Crypt passphrase (hidden, 24+ characters)" "$RE_PASS" confirm
while :; do
  ask_secret P2 "6/7 Crypt SALT passphrase (hidden, 24+ characters, different from the first)" "$RE_PASS" confirm
  [ "$P2" != "$P1" ] && break
  echo "    Must differ from the first passphrase." >&2
done
echo
echo "Without BOTH passphrases nobody can read the backups, not even Microsoft or us."
while :; do IFS= read -rsp "7/7 Type YES once both passphrases are saved in the password manager (2 people): " ACK; echo; ACK=${ACK%$'\r'}; [ -n "$ACK" ] && break; done
[ "$ACK" = YES ] || { echo "Stopped. Nothing written."; exit 1; }

# rclone stores crypt passwords "obscured" (reversible, not encryption); the file itself is the secret (0600).
# printf is a bash builtin, so the passphrases reach rclone on stdin only.
OP1=$(printf '%s\n' "$P1" | rclone obscure -)
OP2=$(printf '%s\n' "$P2" | rclone obscure -)
unset P1 P2
{
  printf '[%s]\n' "$OD"
  printf 'type = onedrive\nregion = global\ndrive_type = documentLibrary\n'
  printf 'drive_id = %s\n' "$DRIVE_ID"
  printf 'token = %s\n\n' "$TOKEN"
  printf '[%s]\n' "$CRYPT"
  printf 'type = crypt\nremote = %s:%s\n' "$OD" "$LIB_PATH"
  printf 'filename_encryption = standard\ndirectory_name_encryption = false\nfilename_encoding = base32\n'
  printf 'password = %s\n' "$OP1"
  printf 'password2 = %s\n' "$OP2"
} > "$CONF.tmp"
chmod 600 "$CONF.tmp"
mv -f -- "$CONF.tmp" "$CONF"
REMOVE_CONF=1
unset TOKEN RAW OP1 OP2
echo "Written: $CONF (root 0600, directory 0700). Remotes: $(rclone listremotes --config "$CONF" | tr '\n' ' ')"
echo
echo "== Tests =="
t_list
[ "$fail" = 1 ] || t_refresh
[ "$fail" = 1 ] || t_existing
if [ "$fail" = 0 ] && [ "$MODE" = new ]; then t_canary; fi
if [ "$fail" = 0 ] && [ "$MODE" = new ]; then t_keycheck; fi
[ "$MODE" = readonly ] && echo "     (read-only mode: no write test)"
echo
if [ "$fail" != 0 ]; then
  echo "A test failed. Fix the cause (owner steps, 'If the script reports an error'), then run this again."
  exit 1
fi
REMOVE_CONF=0
cat <<EOF
All tests passed. Tell Claude: 'rclone ready' (Claude checks only remote names, file modes and drive_type).

Save these NON-secret values in the password-manager entry (needed to rebuild the config after losing the server):
  site URL:         $SITE_URL
  library:          $LIB_NAME
  drive_type:       documentLibrary
  drive_id:         $DRIVE_ID
  folder:           $LIB_PATH
  backup account:   $T_UPN   (tenant $T_TID)
  rclone config:    [$OD] type=onedrive region=global drive_type=documentLibrary drive_id=<above> token=<from rclone authorize>
                    [$CRYPT] type=crypt remote=$OD:$LIB_PATH filename_encryption=standard directory_name_encryption=false
                             filename_encoding=base32 password=<crypt passphrase> password2=<salt passphrase>
  and attach this script (it contains no secret): $(readlink -f "$0")
EOF
