#!/bin/bash
# mail-discover.sh — READ-ONLY discovery for the mail module: how Moodle sends mail today, which local MTA exists
# and how it is configured, whether credentials are present (never their values), queue health, and the hints
# that decide whether the module applies as written, needs adapting, or must stop for the owner.
#
# Usage: bash mail-discover.sh [--no-net]
#   --no-net   skip the TCP reachability test to the provider's SMTP ports
# Reads ~/.config/moodle-server-care/server.env (MOODLE, PHP, WEBUSER, SITE ...); env vars override it.
# Uses sudo only to read root-only files (exim logs, passwd.client) and to run the Moodle CLI as the web user.
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init; msc_exim_init; msc_postfix_init

NET=1
for a in "$@"; do case "$a" in --no-net) NET=0 ;; -h|--help) sed -n '2,9p' "$0"; exit 0 ;; *) echo "unknown option $a"; exit 2 ;; esac; done

HINTS=()
hint() { HINTS+=("$*"); }
say() { printf '%-30s %s\n' "$1" "$2"; }

msc_hr "environment"
say "env file" "${MSC_ENV_FILE:-none (run skills/start/scripts/detect-env.sh)}"
say "site / release" "${SITE:-?} / ${RELEASE:-?}"
say "moodle dir / php / web user" "${MOODLE:-?} / $PHP / $WEBUSER"
say "date" "$(date '+%F %T %Z')"

# ---------------------------------------------------------------- Moodle side
msc_hr "Moodle outgoing mail (non-secret)"
MOUT=$(msc_moodle_php --show 2>&1); MRC=$?
echo "$MOUT"
mval() { printf '%s\n' "$MOUT" | sed -n "s/^$1=//p" | head -n 1; }
if [ $MRC -ne 0 ]; then hint "STOP: could not read Moodle settings (rc=$MRC); fix MOODLE/PHP/WEBUSER first"; fi
MODE=$(mval mailer_mode); SMTPHOSTS=$(mval smtphosts); AUTHTYPE=$(mval smtpauthtype); FORCED=$(mval forced_in_config_php)
AUTOTLS=$(mval phpmailer_smtpautotls); NOREPLY=$(mval noreplyaddress)
case "$MODE" in
  smtp)
    case "$SMTPHOSTS" in
      127.0.0.1*|localhost*|"[::1]"*) hint "DONE ALREADY?: Moodle already relays through the local MTA ($SMTPHOSTS); run mail-daily-check.sh instead of the switch" ;;
      *) hint "APPLIES: Moodle talks SMTP straight to '$SMTPHOSTS' inside the page request" ;;
    esac ;;
  php-mail) hint "DIFFERS: smtphosts is empty, Moodle uses PHP mail() -> the sendmail binary of the local MTA. Pages already hand mail to the MTA; check the MTA's relay/DNS instead (references/moodle-switch.md 'When Moodle uses PHP mail()')" ;;
  qmail) hint "STOP: smtphosts=qmail; this module does not cover qmail" ;;
esac
[ "$AUTHTYPE" = "XOAUTH2" ] && hint "STOP: Moodle uses XOAUTH2 for SMTP; exim/Postfix password auth cannot reuse it. Ask the owner (provider relay connector or app password)"
[ -n "$FORCED" ] && [ "$FORCED" != "none" ] && hint "CHECK: config.php forces: $FORCED (database changes to those settings have no effect)"
[ "$AUTOTLS" = "true" ] && hint "CHECK: PHPMailer SMTPAutoTLS is true: Moodle would try STARTTLS against the local MTA's self-signed certificate. Disable STARTTLS advertising on loopback (references/exim-smarthost.md §11) or stop"
[ -n "$NOREPLY" ] && say "noreply domain" "${NOREPLY#*@} (must be a domain the provider has verified)"

msc_hr "new-user password loop (counts and IDs only)"
msc_moodle_php --loop-check 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------- PHP-FPM slow log evidence
msc_hr "evidence: PHPMailer frames in the PHP-FPM slow log"
SLOWLOGS=$(grep -hsE '^[[:space:]]*slowlog[[:space:]]*=' /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf 2>/dev/null | sed -E 's/.*=[[:space:]]*//' | sort -u)
if [ -z "$SLOWLOGS" ]; then echo "  no slowlog configured in the FPM pools (the audit module can enable one)"; fi
for f in $SLOWLOGS; do
  [ -e "$f" ] || $SUDO test -e "$f" || continue
  n=$($SUDO grep -c -i 'phpmailer' "$f" 2>/dev/null); t=$($SUDO grep -c 'script_filename' "$f" 2>/dev/null)
  say "  $f" "phpmailer frames=${n:-0} of ${t:-0} slow requests"
  [ "${n:-0}" -gt 0 ] && hint "EVIDENCE: $n slow requests waited inside PHPMailer ($f)"
done

# ---------------------------------------------------------------- MTA
msc_hr "local MTA"
MTA=$(msc_detect_mta)
say "detected" "$MTA"
L25=$($SUDO ss -Hltn 'sport = :25' 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')
say "port 25 listeners" "${L25:-none}"
for l in $L25; do
  case "$l" in 127.0.0.1:25|\[::1\]:25|::1:25) ;; *) hint "STOP: the MTA listens on $l (not only loopback): it may be a real mail server for the domain. Ask before changing it" ;; esac
done
[ -r /etc/mailname ] && say "/etc/mailname" "$(cat /etc/mailname)"
ROOTALIAS=$(grep -E '^root:' /etc/aliases 2>/dev/null | sed -E 's/^root:[[:space:]]*//')
say "root alias (/etc/aliases)" "${ROOTALIAS:-none}"
case "$ROOTALIAS" in *@*) hint "CHECK: root mail is forwarded to an external address; once the MTA relays, cron/system mail to it leaves the server with a From the provider may reject (frozen bounces)" ;; esac

case "$MTA" in
exim)
  msc_hr "exim4"
  say "binary / version" "$EXIM_BIN / $($SUDO "$EXIM_BIN" -bV 2>/dev/null | sed -n '1s/^Exim version \([^ ]*\).*/\1/p')"
  say "packages" "$(dpkg-query -W -f='${Package} ${Version}  ' 'exim4*' 2>/dev/null)"
  if [ -r "$EXIM_CONF" ]; then
    grep -E "^dc_(eximconfig_configtype|smarthost|local_interfaces|relay_nets|other_hostnames|use_split_config|hide_mailname|readhost)=" "$EXIM_CONF" | sed 's/^/  /'
  else
    hint "DIFFERS: no $EXIM_CONF (not the Debian exim4 packaging); see references/exim-smarthost.md §2"
  fi
  CT=$(sed -nE "s/^dc_eximconfig_configtype='([^']*)'.*/\1/p" "$EXIM_CONF" 2>/dev/null)
  SH=$(sed -nE "s/^dc_smarthost='([^']*)'.*/\1/p" "$EXIM_CONF" 2>/dev/null)
  LI=$(sed -nE "s/^dc_local_interfaces='([^']*)'.*/\1/p" "$EXIM_CONF" 2>/dev/null)
  case "$CT" in
    local) hint "APPLIES: exim configtype 'local' (non-local mail is unrouteable today; nothing else can depend on exim relaying)" ;;
    smarthost) if [ -n "$SH" ]; then hint "CHECK: exim already relays via '$SH' (another app may depend on it; compare with the provider Moodle uses)"; fi ;;
    internet) hint "STOP: exim configtype 'internet' (delivers straight to recipients' MX; may receive mail). Ask the owner before turning it into a smarthost" ;;
    satellite) hint "CHECK: configtype 'satellite' sends ALL mail, even local cron mail, to the smarthost; 'smarthost' keeps local delivery" ;;
    none|"") hint "CHECK: exim configtype '${CT:-unset}'" ;;
  esac
  [ -z "$LI" ] && [ -r "$EXIM_CONF" ] && hint "STOP: dc_local_interfaces is empty = exim listens on ALL interfaces; restrict it to '127.0.0.1 ; ::1' first (separate change)"
  [ -e "$EXIM_DIR/exim4.conf" ] && hint "STOP: $EXIM_DIR/exim4.conf exists = a hand-written config that bypasses the Debian generator"
  say "split config" "$(sed -nE "s/^dc_use_split_config='([^']*)'.*/\1/p" "$EXIM_CONF" 2>/dev/null) (transport file: $EXIM_TPL)"
  if [ -r "$EXIM_TPL" ]; then
    say "hosts_require_auth in transport" "$(grep -c '^[[:space:]]*hosts_require_auth' "$EXIM_TPL")"
    say "PROTOCOL macro supported" "$(grep -q 'REMOTE_SMTP_SMARTHOST_PROTOCOL' "$EXIM_TPL" && echo yes || echo 'no (use port 587 STARTTLS)')"
  fi
  if [ -e "$EXIM_MACROS" ]; then echo "  $EXIM_MACROS:"; grep -vE '^[[:space:]]*(#|$)' "$EXIM_MACROS" | grep -viE 'pass|secret|key' | sed 's/^/    /'; else say "local macros" "none ($EXIM_MACROS)"; fi
  say "queue runner" "$(grep -E '^(QUEUERUNNER|QUEUEINTERVAL)=' "$EXIM_DEFAULT" 2>/dev/null | tr '\n' ' ')"
  PC="$EXIM_DIR/passwd.client"
  if $SUDO test -e "$PC"; then
    say "passwd.client" "$($SUDO stat -c '%U:%G %a' "$PC"), entries: $($SUDO grep -cvE '^[[:space:]]*(#|$)' "$PC") (values not read; check-credentials.sh)"
  else say "passwd.client" "absent"; fi
  $SUDO "$EXIM_BIN" -bP smtp_accept_max smtp_accept_queue_per_connection remote_max_parallel ignore_bounce_errors_after \
    timeout_frozen_after tls_advertise_hosts primary_hostname qualify_domain 2>/dev/null | sed 's/^/  /'
  say "queue / frozen" "$($SUDO "$EXIM_BIN" -bpc 2>/dev/null) / $($SUDO "$EXIM_BIN" -bp 2>/dev/null | grep -c '\*\*\* frozen \*\*\*')"
  say "paniclog" "$($SUDO stat -c '%s bytes' "$EXIM_LOGDIR/paniclog" 2>/dev/null || echo absent)"
  ML="$EXIM_LOGDIR/mainlog"
  if $SUDO test -r "$ML"; then
    say "mainlog today: arrivals" "local=$($SUDO grep -c ' <= .* P=local' "$ML") smtp=$($SUDO grep -cE ' <= .* P=e?smtps?a? ' "$ML")"
    say "mainlog today: deliveries" "smarthost=$($SUDO grep -c ' => .* R=smarthost' "$ML") local=$($SUDO grep -cE ' => .* R=(local_user|system_aliases|userforward)' "$ML") defer(==)=$($SUDO grep -c ' == ' "$ML") fail(**)=$($SUDO grep -c ' \*\* ' "$ML")"
    U=$($SUDO zgrep -h 'Unrouteable address' "$ML" "$ML".1 "$ML".[2-9].gz 2>/dev/null | wc -l)
    say "unrouteable (about 10 days)" "$U"
    [ "$U" -gt 0 ] && hint "CHECK: $U 'Unrouteable address' lines in the last days: some local program mails external addresses today and would start delivering once exim relays (look at senders U=..., not addresses)"
  fi
  ;;
postfix)
  msc_hr "postfix"
  if [ -n "$POSTCONF_BIN" ]; then
    say "version" "$("$POSTCONF_BIN" -h mail_version 2>/dev/null)"
    for k in inet_interfaces mydestination relayhost smtp_tls_security_level smtp_tls_wrappermode smtp_sasl_auth_enable \
             smtp_sasl_password_maps smtp_sasl_security_options smtp_sasl_auth_soft_bounce virtual_mailbox_domains default_database_type; do
      say "  $k" "$("$POSTCONF_BIN" -h "$k" 2>/dev/null)"
    done
    case "$("$POSTCONF_BIN" -h inet_interfaces 2>/dev/null)" in loopback-only|localhost|127.0.0.1*) ;; *) hint "CHECK: Postfix inet_interfaces is not loopback-only (it may receive mail for the domain)";; esac
    [ -n "$("$POSTCONF_BIN" -h virtual_mailbox_domains 2>/dev/null)" ] && hint "STOP: Postfix hosts mailboxes (virtual_mailbox_domains): it is a real mail server"
    dpkg-query -W -f='${Status}' libsasl2-modules 2>/dev/null | grep -q 'ok installed' || hint "CHECK: libsasl2-modules not installed: Postfix cannot do AUTH PLAIN/LOGIN (package install needs approval)"
    say "queue" "$($SUDO postqueue -p 2>/dev/null | tail -n 1)"
  fi
  hint "DIFFERS: Postfix instead of exim: follow references/postfix-relay.md"
  ;;
none)
  hint "DIFFERS: no local MTA. Installing one (exim4-daemon-light on Debian/Ubuntu, postfix elsewhere) is a package install: propose it, get approval"
  ;;
other:*)
  hint "STOP: MTA '${MTA#other:}' is not covered (sendmail, OpenSMTPD, nullmailer, msmtp...). Ask the owner"
  ;;
esac

# ---------------------------------------------------------------- reachability of the provider
if [ "$NET" = 1 ] && [ "$MODE" = smtp ] && [ -n "$SMTPHOSTS" ]; then
  msc_hr "TCP reachability to the provider (connect only, nothing sent)"
  PH=${SMTPHOSTS%%;*}; PH=${PH%%:*}
  case "$PH" in
    127.*|localhost|::1|"[::1]"|"")
      # Moodle already hands mail to the local MTA: test the MTA's own smarthost instead (exim dc_smarthost
      # 'host::port[ : host2::port]', Postfix relayhost '[host]:port'), not loopback.
      PH=$(printf '%s' "${SH:-}" | sed -E 's/[[:space:]]*:[[:space:]]+.*//; s/::.*//')
      if [ -z "$PH" ] && [ -n "${POSTCONF_BIN:-}" ] && command -v "$POSTCONF_BIN" >/dev/null 2>&1; then
        PH=$("$POSTCONF_BIN" -h relayhost 2>/dev/null | sed -E 's/^\[([^]]+)\].*/\1/; s/:[0-9]+$//')
      fi
      if [ -z "$PH" ]; then say "  smarthost" "Moodle relays through the local MTA, which has no smarthost: nothing to test"; PH=""; fi ;;
  esac
  [ -n "$PH" ] && for p in 465 587 25; do
    # host and port go in as arguments, never into the -c string (a crafted smtphosts value must not run as code)
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$PH" "$p" 2>/dev/null; then say "  $PH:$p" "open"; else say "  $PH:$p" "closed or filtered"; fi
  done
fi

msc_hr "hints"
if [ ${#HINTS[@]} -eq 0 ]; then echo "  (none)"; else printf '  - %s\n' "${HINTS[@]}"; fi
