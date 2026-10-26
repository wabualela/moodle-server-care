#!/bin/bash
# moodle-mail.sh — runs moodle-mail.php as the web user with the right PHP binary and config.php (from server.env),
# using a 0644 copy in /tmp because the operator's home is usually not readable by the web user.
# All arguments go to moodle-mail.php; stdin is passed through (for --restore). See moodle-mail.php for actions:
#   --show | --dump-rollback | --execute [--host=H:P] [--maxbulk=N] | --restore | --connect-test [--timeout=S]
#   --send-test --to=ADDR --confirm-owner-permission | --loop-check | --clear-smtppass --confirm
set -uo pipefail
set +x
. "$(dirname "$0")/_common.sh"
msc_load_env; msc_sudo_init
msc_moodle_php "$@"
