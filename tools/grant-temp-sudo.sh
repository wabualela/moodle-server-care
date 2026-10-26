#!/usr/bin/env bash
# grant-temp-sudo.sh — run on YOUR computer (Linux, macOS, or Git Bash/WSL on Windows).
#
# Shows the hosts from your ~/.ssh/config, lets you pick one, then on that server:
#   grant  : passwordless sudo for a user until a time you choose, removed automatically by a systemd timer
#            (fixed date, survives reboots; if the server was off at that time, it is removed at the next boot)
#   status : shows whether the rule exists and when it expires
#   revoke : removes the rule now
# It asks the server's sudo password once (typed into the server's own prompt, never stored by this script).
# Same file names as the rule already used on the first server, so running it there extends that rule:
#   /etc/sudoers.d/90-<user>-nopasswd  and  revoke-<user>-nopasswd-sudo.{timer,service}
# If the server keeps an operations log in the user's home (SERVER-OPS-LOG.md or *-SERVER-LOG.md), an entry is appended.
#
# Usage: bash grant-temp-sudo.sh            (interactive)
set -euo pipefail

SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"

die() { printf 'خطأ: %s\n' "$*" >&2; exit 1; }

# ---- 1. hosts from ~/.ssh/config (and files it Includes), without wildcard patterns
list_hosts() {
  local files=("$SSH_CONFIG") inc f
  [ -f "$SSH_CONFIG" ] || die "لا يوجد ملف $SSH_CONFIG"
  while read -r inc; do
    for f in $inc; do
      case "$f" in /*) ;; ~*) f="${f/#\~/$HOME}" ;; *) f="$HOME/.ssh/$f" ;; esac
      for g in $f; do [ -f "$g" ] && files+=("$g"); done
    done
  done < <(awk 'tolower($1)=="include"{ $1=""; print }' "$SSH_CONFIG")
  awk 'tolower($1)=="host"{ for (i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i }' "${files[@]}" | awk '!seen[$0]++'
}

HOSTS=(); while IFS= read -r h; do HOSTS+=("$h"); done < <(list_hosts)   # no mapfile: macOS ships bash 3.2
[ "${#HOSTS[@]}" -gt 0 ] || die "لم أجد أي Host في $SSH_CONFIG"

echo "الخوادم في إعدادات SSH:"
for i in "${!HOSTS[@]}"; do
  h="${HOSTS[$i]}"
  hn=$(ssh -G "$h" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
  us=$(ssh -G "$h" 2>/dev/null | awk '$1=="user"{print $2; exit}')
  printf '  %2d) %-28s %s@%s\n' "$((i+1))" "$h" "$us" "$hn"
done
read -rp "اختر رقم الخادم: " n
[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#HOSTS[@]}" ] || die "اختيار غير صحيح"
HOST="${HOSTS[$((n-1))]}"
DEFAULT_USER=$(ssh -G "$HOST" 2>/dev/null | awk '$1=="user"{print $2; exit}')

# ---- 2. what to do
echo "ماذا تريد على $HOST؟"
echo "   1) منح sudo بلا كلمة مرور لمدة محددة (أو تمديد منح قائم)"
echo "   2) عرض الحالة"
echo "   3) إزالة الصلاحية الآن"
read -rp "اختيارك [1]: " a; a="${a:-1}"
case "$a" in 1) ACTION=grant ;; 2) ACTION=status ;; 3) ACTION=revoke ;; *) die "اختيار غير صحيح" ;; esac

read -rp "اسم المستخدم على الخادم [$DEFAULT_USER]: " TUSER; TUSER="${TUSER:-$DEFAULT_USER}"
[[ "$TUSER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "اسم مستخدم غير صالح"
[ "$TUSER" != root ] || die "لا معنى لمنح root"

WHEN=""
if [ "$ACTION" = grant ]; then
  echo "المدة: مثل 30m أو 2h أو 3d أو 1w، أو وقت محدد مثل \"2026-11-02 03:00\" (بتوقيت الخادم)"
  read -rp "المدة: " d
  if   [[ "$d" =~ ^([0-9]+)m$ ]]; then WHEN="now + ${BASH_REMATCH[1]} minutes"
  elif [[ "$d" =~ ^([0-9]+)h$ ]]; then WHEN="now + ${BASH_REMATCH[1]} hours"
  elif [[ "$d" =~ ^([0-9]+)d$ ]]; then WHEN="now + ${BASH_REMATCH[1]} days"
  elif [[ "$d" =~ ^([0-9]+)w$ ]]; then WHEN="now + ${BASH_REMATCH[1]} weeks"
  elif [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]]; then WHEN="$d"
  else die "صيغة مدة غير مفهومة: $d"; fi
fi

echo
echo "الملخص: الخادم=$HOST  المستخدم=$TUSER  العملية=$ACTION ${WHEN:+ المدة/الموعد=$d}"
read -rp "متابعة؟ [y/N]: " ok; [[ "$ok" =~ ^[Yy]$ ]] || { echo "أُلغي."; exit 0; }

# ---- 3. the part that runs on the server, as root (sent base64-encoded; contains no secrets)
REMOTE=$(cat <<'RSCRIPT'
set -euo pipefail
ACTION="$1"; U="$2"; WHEN="${3:-}"
F="/etc/sudoers.d/90-${U}-nopasswd"
UNIT="revoke-${U}-nopasswd-sudo"
SD=/etc/systemd/system
id "$U" >/dev/null 2>&1 || { echo "المستخدم $U غير موجود على هذا الخادم"; exit 1; }
logentry() {  # append to the server's operations log if it keeps one in the user's home
  local home log
  home=$(getent passwd "$U" | cut -d: -f6)
  for log in "$home/SERVER-OPS-LOG.md" "$home"/*-SERVER-LOG.md; do
    [ -f "$log" ] && [ ! -L "$log" ] || continue            # never follow a symlink as root
    printf '\n### %s — %s  (session: grant-temp-sudo.sh, approved by owner: yes)\n- What/why: %s\n' \
      "$(date '+%F %H:%M')" "$1" "$2" | runuser -u "$U" -- tee -a "$log" >/dev/null   # append as the file's user
    echo "سُجّل في $log"; return
  done
}
status() {
  if [ -f "$F" ]; then echo "القاعدة موجودة: $F"; else echo "لا توجد قاعدة sudo مؤقتة لـ $U"; fi
  systemctl list-timers "$UNIT.timer" --all --no-pager 2>/dev/null | sed -n '1,2p'
}
case "$ACTION" in
  status) status ;;
  revoke)
    rm -f "$F"
    systemctl disable --now "$UNIT.timer" 2>/dev/null || true
    sudo -l -U "$U" 2>/dev/null | grep -q NOPASSWD && echo "تحذير: ما زالت هناك قاعدة NOPASSWD أخرى لـ $U" || echo "أُزيلت الصلاحية."
    logentry "temporary passwordless sudo revoked for $U" "Removed $F and disabled $UNIT.timer."
    ;;
  grant)
    EXP=$(date -d "$WHEN" '+%Y-%m-%d %H:%M:%S') || { echo "موعد غير مفهوم: $WHEN"; exit 1; }
    [ "$(date -d "$EXP" +%s)" -gt "$(date +%s)" ] || { echo "الموعد في الماضي: $EXP"; exit 1; }
    TMP=$(mktemp)
    printf '# Temporary passwordless sudo for %s until %s (grant-temp-sudo.sh). Removed by %s.timer.\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' \
      "$U" "$EXP" "$UNIT" "$U" > "$TMP"
    visudo -cqf "$TMP" || { rm -f "$TMP"; echo "فشل التحقق من قاعدة sudo"; exit 1; }
    cat > "$SD/$UNIT.service" <<EOF
# Removes the temporary passwordless sudo rule (written by grant-temp-sudo.sh).
[Unit]
Description=Revoke temporary passwordless sudo for $U
[Service]
Type=oneshot
ExecStart=/usr/bin/rm -f $F
EOF
    cat > "$SD/$UNIT.timer" <<EOF
# Fixed-date expiry (survives reboots; Persistent=true runs it at boot if the date passed while the box was down).
[Unit]
Description=Expiry of temporary passwordless sudo for $U
[Timer]
OnCalendar=$EXP
Persistent=true
AccuracySec=1min
[Install]
WantedBy=timers.target
EOF
    systemd-analyze verify "$SD/$UNIT.service" "$SD/$UNIT.timer" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable "$UNIT.timer" >/dev/null 2>&1
    systemctl restart "$UNIT.timer"          # recompute the elapse time when extending an existing grant
    install -m 440 -o root -g root "$TMP" "$F"; rm -f "$TMP"   # rule goes live only after its removal timer is armed
    NEXT=$(systemctl show "$UNIT.timer" -p NextElapseUSecRealtime --value)
    [ -n "$NEXT" ] && [ "$NEXT" != "n/a" ] || { rm -f "$F"; echo "لم يُضبط المؤقت؛ أُزيلت القاعدة احتياطاً"; exit 1; }
    echo "تم: $U يملك sudo بلا كلمة مرور حتى $EXP (توقيت الخادم: $(date +%Z))."
    echo "الإزالة التلقائية: $UNIT.timer — الموعد القادم: $NEXT"
    logentry "temporary passwordless sudo for $U until $EXP" \
      "Rule $F (440, validated with visudo); removal by $UNIT.timer (OnCalendar=$EXP, Persistent=true). Revoke early: rm -f $F; systemctl disable --now $UNIT.timer."
    ;;
  *) echo "عملية غير معروفة"; exit 1 ;;
esac
RSCRIPT
)
B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')

echo "الاتصال بـ $HOST (سيطلب الخادم كلمة مرور sudo إن لزم)..."
# shellcheck disable=SC2029  # the arguments are validated above; B64 contains only [A-Za-z0-9+/=]
ssh -t "$HOST" "sudo bash -c \"\$(printf %s '$B64' | base64 -d)\" grant-temp-sudo '$ACTION' '$TUSER' '$WHEN'"
