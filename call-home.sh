#!/bin/zsh
# call-home.sh: open the outbound tunnel once (invoked by Watcher on GAVE UP).
# Starts ssh in the background so the Watcher can exit; the tunnel survives
# because the Watcher runs under launchd, not under an SSH session.
#
# Configuration: watchdog.conf in the same directory as this script.
# The explicit 127.0.0.1 in -R matters: plain "localhost" is unreliable
# for remote forwarding on some sshd builds.

SCRIPT_DIR="${0:A:h}"
CONF="$SCRIPT_DIR/watchdog.conf"
if [ ! -f "$CONF" ]; then
  echo "watchdog.conf not found at $CONF. Run install.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

WATCHDOG_DIR="${WATCHDOG_DIR:-$SCRIPT_DIR}"
CALL_HOME_KEY="${CALL_HOME_KEY:-$HOME/.ssh/mac-watchdog-call-home}"

require_var() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "watchdog.conf: required variable $name is not set. Edit $CONF." >&2
    exit 1
  fi
}
require_var RENDEZVOUS_HOST "$RENDEZVOUS_HOST"
require_var RENDEZVOUS_PORT "$RENDEZVOUS_PORT"

LOG="$WATCHDOG_DIR/call-home.log"
nohup ssh -N -R "$RENDEZVOUS_PORT:127.0.0.1:22" -i "$CALL_HOME_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o ConnectTimeout=20 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$RENDEZVOUS_HOST" >> "$LOG" 2>&1 &
echo "$(date '+%Y-%m-%d %H:%M:%S') tunnel start requested (pid $!)" >> "$LOG"
exit 0
