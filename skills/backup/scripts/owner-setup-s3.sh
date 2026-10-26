#!/bin/bash
set +x   # never trace: this script reads secrets (bash -x would print them)
# owner-setup-s3.sh: run by the OWNER (never by Claude). Creates the two rclone remotes of moodle-backup for an
# S3-compatible bucket (Cloudflare R2 recommended and tested in design; other providers need their lock semantics
# checked first):
#   s3              the bucket's S3 API, key scoped to ONE bucket (Object Read & Write, not admin)
#   <NAME>-crypt    client-side encryption on top of s3:<bucket>/<folder> (file names + contents; folder names readable,
#                   so lifecycle and lock rules can match the prefixes daily/, weekly/, monthly/, code/, filedir-deleted/)
# in /var/lib/<NAME>/rclone/rclone.conf (root 0600, directory 0700), and tests them. Part of moodle-server-care.
#
#   sudo bash owner-setup-s3.sh [--name NAME] [--set-prefix P]     first setup (refuses to overwrite an existing config)
#   sudo bash owner-setup-s3.sh --read-only [--name NAME]          restore-drill host with a READ-ONLY key: same
#                                                                  passphrases, checks that writes are refused
#
# Tests after writing the config: bucket reachable; key not broader than needed; the passphrases open what is already
# in the folder (keycheck object, or names that decrypt; a manifest is not required); encrypted write/read/delete;
# the keycheck object (first setup).
#
# Secrets (keys, passphrases) are typed into hidden prompts. They are not echoed, not stored in shell history, never
# passed as command arguments or environment (never visible in `ps` or /proc), and never written to a temporary file
# other than the config's own .tmp (0600, removed on any exit). Run it in your own SSH session after `unset HISTFILE`.
# Any wrong entry is asked again; the script never exits between hidden prompts (a later paste would land at the shell).
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin

NAME=moodle-backup
SET_PREFIX=moodle
MODE=new
while [ $# -gt 0 ]; do
  case "$1" in
    --read-only) MODE=readonly; shift ;;
    --name) NAME=${2:-}; shift 2 ;;
    --set-prefix) SET_PREFIX=${2:-}; shift 2 ;;
    *) echo "usage: $0 [--read-only] [--name NAME] [--set-prefix P]" >&2; exit 2 ;;
  esac
done
[[ $NAME =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || { echo "Bad --name." >&2; exit 2; }
[[ $SET_PREFIX =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Bad --set-prefix." >&2; exit 2; }

STATE=/var/lib/$NAME
CONF_DIR=$STATE/rclone
CONF=$CONF_DIR/rclone.conf
ERRF=$CONF_DIR/setup-errors.log   # rclone messages of the tests only (never secrets); removed on exit
S3=s3
CRYPT=$NAME-crypt
KEYCHECK="keycheck/$SET_PREFIX-keycheck.txt"   # small encrypted object: later runs prove the passphrases by reading it
KEYCHECK_MARK="moodle-backup keycheck"
RE_PASS='^[[:graph:]][[:print:]]{22,}[[:graph:]]$'    # printable ASCII, 24+ characters, no space at either end
RE_BUCKET='^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
RE_FOLDER='^[A-Za-z0-9][A-Za-z0-9._-]{1,60}$'

REMOVE_CONF=0
cleanup() {
  rm -f -- "$CONF.tmp" "$ERRF"
  if [ "$REMOVE_CONF" = 1 ]; then rm -f -- "$CONF"; echo "The untested config was removed. Nothing is left behind." >&2; fi
  unset AK SK P1 P2 OP1 OP2
}
trap cleanup EXIT
trap 'echo >&2; echo "Interrupted." >&2; exit 130' INT TERM HUP

ask_secret() {  # ask_secret VAR "Prompt" REGEX [confirm]: asks again on any mistake
  local _v _w
  while :; do
    IFS= read -rsp "$2: " _v; echo >&2
    _v=${_v%$'\r'}
    [ -n "$_v" ] || continue
    if [ "${4:-}" = confirm ]; then
      while :; do IFS= read -rsp "    Same value again: " _w; echo >&2; _w=${_w%$'\r'}; [ -n "$_w" ] && break; done
      [ "$_v" = "$_w" ] || { echo "    The two entries differ. Paste it again." >&2; continue; }
    fi
    [[ $_v =~ $3 ]] || { echo "    Wrong format (length or characters). Paste it again." >&2; continue; }
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

fail=0
KC_FOUND=0
ok()  { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }
RL=()
t_list() {
  if rclone lsf "${RL[@]}" --max-depth 1 "$S3:$BUCKET" >/dev/null 2>"$ERRF"; then ok "bucket $BUCKET reachable with the key"
  else
    bad "bucket listing failed:"; tail -n 3 "$ERRF" | sed 's/^/       /'
    echo "     403/AccessDenied: wrong key or not scoped to $BUCKET. NoSuchBucket: wrong name or jurisdiction."
    echo "     SignatureDoesNotMatch: the secret was pasted incompletely."
  fi
}
t_scope() {   # a key that can list every bucket is broader than needed (warning only)
  if rclone lsd "${RL[@]}" "$S3:" >/dev/null 2>&1; then
    echo "WARN this key can list every bucket of the account: prefer an Object Read & Write token for $BUCKET only"
  fi
}
t_existing() {  # the passphrases must open what is already in the folder (rclone hides undecryptable names)
  local f raw dec r kc n=0
  for f in keycheck daily weekly monthly code; do
    r=0; raw=$(rclone lsf "${RL[@]}" --files-only "$S3:$BUCKET/$FOLDER/$f/" 2>>"$ERRF") || r=$?
    if [ "$r" != 0 ] && [ "$r" != 3 ]; then bad "cannot list $FOLDER/$f/ (rclone exit $r)"; tail -n 3 "$ERRF" | sed 's/^/       /'; return 0; fi
    [ -n "$raw" ] || continue
    n=$(( n + $(wc -l <<<"$raw") ))
    # any set prefix proves the passphrases (a read-only drill does not know the install's --set-prefix)
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
  if [ "$n" = 0 ]; then ok "no earlier backups in $FOLDER/ (first install)"; return 0; fi
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
t_keycheck() {  # no keycheck object yet (first install): write it; every later run reads it back. keycheck/ must never
  [ "$KC_FOUND" = 0 ] || return 0   # get a lock rule (it is written once, but a rewrite after a lost object must work)
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
    raw=$(rclone lsf "${RL[@]}" --files-only "$S3:$BUCKET/$FOLDER/canary/" 2>>"$ERRF" || true)
    echo "     Name as stored in the bucket (must be unreadable):"
    sed 's/^/       /' <<<"$raw"
    if rclone delete "${RL[@]}" "$CRYPT:canary/" 2>>"$ERRF"; then ok "canary deleted (canary/ is not a locked prefix)"
    else bad "canary delete refused: a lock on the whole bucket or on $FOLDER/? The filedir mirror needs deletes there."; fi
  else
    bad "encrypted write/read failed: does the token have Object Read & Write on $BUCKET?"; tail -n 3 "$ERRF" | sed 's/^/       /'
  fi
}
t_readonly_probe() {   # --read-only: a write must be REFUSED (the drill key must not be able to change backups)
  local probe="$S3:$BUCKET/$FOLDER/canary/ro-probe-$(date +%s)"
  if printf 'x\n' | rclone rcat "${RL[@]}" "$probe" 2>>"$ERRF"; then
    bad "this key CAN write: use a read-only (Object Read) token for restore drills"
    rclone deletefile "${RL[@]}" "$probe" 2>/dev/null || true
  else
    ok "writes are refused with this key (read-only, as intended)"
  fi
}

[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v rclone >/dev/null || { echo "rclone is not installed." >&2; exit 1; }
mkdir -p "$STATE"; chmod 755 "$STATE"
mkdir -p -m 700 "$CONF_DIR"; chmod 700 "$CONF_DIR"
if [ -e "$CONF" ]; then
  echo "$CONF already exists. Nothing changed." >&2
  echo "To start over: sudo rm $CONF, then run this again with the SAME passphrases." >&2
  exit 1
fi
RL=(--config "$CONF")

DEF_FOLDER=$(hostname -s | tr -c 'A-Za-z0-9._\n-' '-')
echo "== S3-compatible (Cloudflare R2 or other) backup: rclone setup for $NAME =="
echo "Have ready (password manager): bucket name, Account ID (R2) or endpoint (other), Access Key ID, Secret Access Key,"
echo "the crypt passphrase and the crypt salt passphrase. Hidden prompts show nothing while you paste; that is normal."
[ "$MODE" = readonly ] && echo "Read-only mode (restore drill): use an Object Read token; the script checks that writes are refused."
echo

ask_line PROV "1/8 Provider: r2 (Cloudflare R2) or other (S3-compatible endpoint) [r2]" '^(r2|other)$' r2
ask_line BUCKET "2/8 Bucket name" "$RE_BUCKET"
if [ "$PROV" = r2 ]; then
  ask_line ACC "3/8 Cloudflare Account ID (32 hex characters, not secret)" '^[0-9A-Fa-f]{32}$'
  ACC=${ACC,,}
  ask_line JUR "    Bucket jurisdiction: default or eu [default]" '^([Dd][Ee][Ff][Aa][Uu][Ll][Tt]|[Ee][Uu])$' default
  JUR=${JUR,,}
  if [ "$JUR" = eu ]; then EP="https://${ACC}.eu.r2.cloudflarestorage.com"; else EP="https://${ACC}.r2.cloudflarestorage.com"; fi
  PROVIDER=Cloudflare; REGION=auto
  RE_AK='^[0-9a-f]{32}$'; RE_SK='^[0-9a-f]{64}$'
else
  ask_line EP "3/8 S3 endpoint URL (https://...)" '^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$'
  EP=${EP%/}
  ask_line REGION "    Region (as the provider documents it, e.g. us-east-1)" '^[A-Za-z0-9-]{2,40}$'
  PROVIDER=Other
  RE_AK='^[A-Za-z0-9]{16,128}$'; RE_SK='^[A-Za-z0-9/+=]{20,128}$'
fi
echo "    Each Moodle server needs its OWN folder in the bucket (two servers in one folder would undo each other)."
ask_line FOLDER "4/8 Folder for THIS server's backups [$DEF_FOLDER]" "$RE_FOLDER" "$DEF_FOLDER"
ask_secret AK "5/8 Access Key ID (hidden)" "$RE_AK"
ask_secret SK "    Secret Access Key (hidden)" "$RE_SK"
ask_secret P1 "6/8 Crypt passphrase (hidden, 24+ characters)" "$RE_PASS" confirm
while :; do
  ask_secret P2 "7/8 Crypt SALT passphrase (hidden, 24+ characters, different from the first)" "$RE_PASS" confirm
  [ "$P2" != "$P1" ] && break
  echo "    Must differ from the first passphrase." >&2
done
echo
echo "Without BOTH passphrases nobody can read the backups, not even the storage provider or us."
while :; do IFS= read -rsp "8/8 Type YES once the keys and both passphrases are saved in the password manager (2 people): " ACK; echo; ACK=${ACK%$'\r'}; [ -n "$ACK" ] && break; done
[ "$ACK" = YES ] || { echo "Stopped. Nothing written."; exit 1; }

OP1=$(printf '%s\n' "$P1" | rclone obscure -)
OP2=$(printf '%s\n' "$P2" | rclone obscure -)
unset P1 P2
{
  printf '[%s]\n' "$S3"
  printf 'type = s3\nprovider = %s\nenv_auth = false\n' "$PROVIDER"
  printf 'access_key_id = %s\n' "$AK"
  printf 'secret_access_key = %s\n' "$SK"
  printf 'region = %s\nendpoint = %s\n' "$REGION" "$EP"
  printf '# the key is scoped to one bucket: never try to create or check buckets\nno_check_bucket = true\n\n'
  printf '[%s]\n' "$CRYPT"
  printf 'type = crypt\nremote = %s:%s/%s\n' "$S3" "$BUCKET" "$FOLDER"
  printf '# file names encrypted, folder names readable (lifecycle and lock rules match folder prefixes)\n'
  printf 'filename_encryption = standard\ndirectory_name_encryption = false\nfilename_encoding = base32\n'
  printf 'password = %s\n' "$OP1"
  printf 'password2 = %s\n' "$OP2"
} > "$CONF.tmp"
chmod 600 "$CONF.tmp"
mv -f -- "$CONF.tmp" "$CONF"
REMOVE_CONF=1
unset AK SK OP1 OP2
echo "Written: $CONF (root 0600, directory 0700). Remotes: $(rclone listremotes --config "$CONF" | tr '\n' ' ')"
echo
echo "== Tests =="
t_list
[ "$fail" = 1 ] || t_scope
[ "$fail" = 1 ] || t_existing
if [ "$fail" = 0 ] && [ "$MODE" = new ]; then t_canary; fi
if [ "$fail" = 0 ] && [ "$MODE" = new ]; then t_keycheck; fi
if [ "$fail" = 0 ] && [ "$MODE" = readonly ]; then t_readonly_probe; fi
echo
if [ "$fail" != 0 ]; then
  echo "A test failed. Fix the value in the provider's dashboard, then run this again (sudo bash $0)."
  exit 1
fi
REMOVE_CONF=0
cat <<EOF
All tests passed. Tell Claude: 'rclone ready' (Claude checks only remote names and file modes).

Save these NON-secret values in the password-manager entry (needed to rebuild the config after losing the server):
  provider:         $PROVIDER   endpoint: $EP   region: $REGION
  bucket / folder:  $BUCKET / $FOLDER
  rclone config:    [$S3] type=s3 provider=$PROVIDER env_auth=false region=$REGION endpoint=$EP no_check_bucket=true
                         access_key_id=<key id> secret_access_key=<secret>
                    [$CRYPT] type=crypt remote=$S3:$BUCKET/$FOLDER filename_encryption=standard
                             directory_name_encryption=false filename_encoding=base32
                             password=<crypt passphrase> password2=<salt passphrase>
  and attach this script (it contains no secret): $(readlink -f "$0")
EOF
