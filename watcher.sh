#!/bin/zsh
# Watcher: deterministic health check -> local Apple Intelligence model ->
# independent verify. If the model fails MAX_ATTEMPTS times, call home
# (open the outbound tunnel) and give up.
#
# Configuration: watchdog.conf in the same directory as this script.
# All machine-specific values (hostnames, gateway, interfaces) come from
# there. This script contains no personal data.
#
# Uses ONLY the local Apple Intelligence model via ./recovery-agent.
# No third-party models, no cloud.

# --- Load configuration ---
SCRIPT_DIR="${0:A:h}"
CONF="$SCRIPT_DIR/watchdog.conf"
if [ ! -f "$CONF" ]; then
  echo "watchdog.conf not found at $CONF. Run install.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# Defaults for values the config may omit.
WATCHDOG_DIR="${WATCHDOG_DIR:-$SCRIPT_DIR}"
TAILSCALE_CLI="${TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
WIFI_INTERFACE="${WIFI_INTERFACE:-en1}"
PING_TARGET="${PING_TARGET:-8.8.8.8}"
DNS_TEST_HOST="${DNS_TEST_HOST:-example.net}"
MODEL_TIMEOUT="${MODEL_TIMEOUT:-240}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
LOG_MAX_LINES="${LOG_MAX_LINES:-2000}"

# Required: fail with a clear error naming the variable.
require_var() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "watchdog.conf: required variable $name is not set. Edit $CONF." >&2
    exit 1
  fi
}
require_var TAILSCALE_HOSTNAME "$TAILSCALE_HOSTNAME"

export WATCHDOG_DIR
LOG="$WATCHDOG_DIR/watcher.log"
BLUEPRINT="$WATCHDOG_DIR/blueprint.md"
AGENT="$WATCHDOG_DIR/recovery-agent"
LOCK="$WATCHDOG_DIR/watcher.lock"

# Trim the log if it grew too large (keep the newest half).
if [ "$LOG_MAX_LINES" -gt 0 ] && [ -f "$LOG" ]; then
  _lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if [ "${_lines:-0}" -gt "$LOG_MAX_LINES" ]; then
    tail -n $((LOG_MAX_LINES / 2)) "$LOG" > "$LOG.tmp" 2>/dev/null \
      && mv "$LOG.tmp" "$LOG"
  fi
fi

# Prevent overlapping runs.
if [ -e "$LOCK" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') SKIP overlap, lock exists" >> "$LOG"
  exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "=== $(date '+%Y-%m-%d %H:%M:%S') WAKE ===" >> "$LOG"

# Run a command with a hard timeout (seconds). Prints output, returns exit code.
# macOS has no `timeout` command, so this runs the job in the background,
# polls once a second, and kills it if it overruns. Returns 124 on timeout.
run_to() {
  local secs="$1"; shift
  local out
  out=$(mktemp /tmp/mac-watchdog-run.XXXXXX)
  "$@" > "$out" 2>&1 &
  local pid=$!
  local i=0
  while kill -0 $pid 2>/dev/null; do
    if [ "$i" -ge "$secs" ]; then
      kill -9 $pid 2>/dev/null
      wait $pid 2>/dev/null
      cat "$out"
      rm -f "$out"
      return 124
    fi
    sleep 1
    i=$((i + 1))
  done
  wait $pid 2>/dev/null
  local rc=$?
  cat "$out"
  rm -f "$out"
  return $rc
}

# Deterministic health verification. Prints one VERIFY line per item.
# Returns 0 only if all 5 are OK.
verify_health() {
  local ok=1
  local wifi ping dns route ts
  wifi=$(run_to 10 networksetup -getairportpower "$WIFI_INTERFACE" 2>&1)
  if echo "$wifi" | grep -q "On"; then
    echo "VERIFY wifi OK: $wifi" >> "$LOG"
  else
    echo "VERIFY wifi BROKEN: $wifi" >> "$LOG"; ok=0
  fi
  ping=$(run_to 10 ping -c1 -q -W 2000 "$PING_TARGET" 2>&1)
  if echo "$ping" | grep -q "1 packets received"; then
    echo "VERIFY ping OK" >> "$LOG"
  else
    echo "VERIFY ping BROKEN: $ping" >> "$LOG"; ok=0
  fi
  dns=$(run_to 15 dig +short "$DNS_TEST_HOST" 2>&1)
  if echo "$dns" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; then
    echo "VERIFY dns OK: $dns" >> "$LOG"
  else
    echo "VERIFY dns BROKEN: $dns" >> "$LOG"; ok=0
  fi
  route=$(run_to 10 route -n get default 2>&1 | grep gateway)
  if [ -n "${EXPECTED_GATEWAY:-}" ]; then
    if echo "$route" | grep -q "$EXPECTED_GATEWAY"; then
      echo "VERIFY route OK: $route" >> "$LOG"
    else
      echo "VERIFY route BROKEN: $route" >> "$LOG"; ok=0
    fi
  else
    if echo "$route" | grep -q "gateway:"; then
      echo "VERIFY route OK: $route" >> "$LOG"
    else
      echo "VERIFY route BROKEN: $route" >> "$LOG"; ok=0
    fi
  fi
  ts=$(run_to 15 "$TAILSCALE_CLI" status 2>&1 | head -1)
  if echo "$ts" | grep -q "$TAILSCALE_HOSTNAME" && ! echo "$ts" | grep -Eqi "offline|stopped"; then
    echo "VERIFY tailscale OK: $ts" >> "$LOG"
  else
    echo "VERIFY tailscale BROKEN: $ts" >> "$LOG"; ok=0
  fi
  return $((1 - ok))
}

PROMPT="Read $BLUEPRINT and check this Mac against it, item by item, in order. Check each item ONCE. Do not re-run a Check that already returned Good. For each item report one line: OK or BROKEN with the exact command output that proves it. Repair only the BROKEN items using the Repairs section, then re-run ONLY that item's Check. Finish with ANSWER= followed by one line per item."

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  echo "--- attempt $attempt ---" >> "$LOG"
  # Give the model MODEL_TIMEOUT seconds; kill the agent itself if it hangs.
  run_to "$MODEL_TIMEOUT" "$AGENT" agent "$PROMPT" >> "$LOG" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    pkill -9 -f "recovery-agent agent" 2>/dev/null
    echo "MODEL TIMEOUT on attempt $attempt" >> "$LOG"
  fi
  if verify_health; then
    echo "VERIFIED HEALTHY after attempt $attempt" >> "$LOG"
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') DONE ===" >> "$LOG"
    python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
    exit 0
  else
    echo "STILL BROKEN after attempt $attempt" >> "$LOG"
  fi
  attempt=$((attempt + 1))
done

echo "GAVE UP after $MAX_ATTEMPTS attempts, needs a human" >> "$LOG"
# Plan B: open the outbound channel so we can reach this machine.
if [ -x "$WATCHDOG_DIR/call-home.sh" ]; then
  "$WATCHDOG_DIR/call-home.sh" >> "$LOG" 2>&1
  echo "CALL-HOME invoked" >> "$LOG"
fi
echo "=== $(date '+%Y-%m-%d %H:%M:%S') DONE ===" >> "$LOG"
python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
exit 1
