#!/bin/zsh
# observer.sh — lightweight state collector. No model involved.
#
# Runs every minute via its own LaunchAgent. Appends ONE line per minute
# to events.log: the machine's network state BEFORE any failure.
#
# This is what lets the analyst establish a CAUSE later. If you only
# collect information AFTER a failure, the model can only guess from
# post-failure symptoms — it cannot tell what changed just before the
# break. The observer gives it the "before" picture: what the network
# looked like in the minutes leading up to the incident (an interface
# changing address after a wake, a gateway disappearing, Tailscale
# going offline). Cheap commands only; the log is a rolling window.
#
# Configuration: watchdog.conf in the same directory as this script.

SCRIPT_DIR="${0:A:h}"
CONF="$SCRIPT_DIR/watchdog.conf"
WATCHDOG_DIR="$HOME/watchdog"
EVENTS_MAX_LINES=2000
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  source "$CONF" 2>/dev/null
  WATCHDOG_DIR="${WATCHDOG_DIR:-$HOME/watchdog}"
  EVENTS_MAX_LINES="${EVENTS_MAX_LINES:-2000}"
fi
EVENTS="$WATCHDOG_DIR/events.log"

_ts=$(date '+%Y-%m-%d %H:%M:%S')
_wifi=$(networksetup -getairportpower "${WIFI_INTERFACE:-en1}" 2>/dev/null | grep -o "On\|Off" | head -1)
_ip=$(ipconfig getifaddr "${WIFI_INTERFACE:-en1}" 2>/dev/null)
_gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
_dns=$(networksetup -getdnsservers Wi-Fi 2>/dev/null | tr '\n' ',' | sed 's/,$//')
_ts_state="no-tailscale"
if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  _ts_state=$("${TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}" status 2>/dev/null | head -1 | tr -s ' ' | cut -d' ' -f1-2)
  _ts_state=${_ts_state:-unknown}
fi
_up=$(uptime 2>/dev/null | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

echo "$_ts wifi=${_wifi:-?} ip=${_ip:-none} gw=${_gw:-none} dns=${_dns:-none} ts=$_ts_state up=${_up:-?}" >> "$EVENTS"

# Cap the log (keep the newest half when it exceeds the limit).
if [ "$EVENTS_MAX_LINES" -gt 0 ]; then
  _lines=$(wc -l < "$EVENTS" 2>/dev/null | tr -d ' ')
  if [ "${_lines:-0}" -gt "$EVENTS_MAX_LINES" ]; then
    tail -n $((EVENTS_MAX_LINES / 2)) "$EVENTS" > "$EVENTS.tmp" 2>/dev/null \
      && mv "$EVENTS.tmp" "$EVENTS"
  fi
fi
exit 0
