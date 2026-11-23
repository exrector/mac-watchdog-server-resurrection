#!/bin/zsh
# review.sh — daily self-review. Proposals only, no code changes.
#
# Runs once a day via its own LaunchAgent. The system does not wait for
# a failure: once a day the local model reads the incident history and
# the recent events and asks what it should improve. The model writes
# PROPOSALS to proposals.md. It does NOT modify any code, and it does
# not apply anything — applying a proposal is a separate step (see
# blueprint.md "Self-improvement"). The point is initiative: the system
# looks at its own history and forms a task by itself.
#
# A proposal must say: what to change, why, what it is expected to
# achieve, and how to verify it. A change is judged by two criteria:
# safety (did it break anything) and usefulness (did the incident rate
# actually drop, or the fix actually help). A change that breaks nothing
# but helps nothing is a failed change.
#
# Configuration: watchdog.conf in the same directory as this script.

SCRIPT_DIR="${0:A:h}"
CONF="$SCRIPT_DIR/watchdog.conf"
WATCHDOG_DIR="$HOME/watchdog"
MODEL_TIMEOUT=240
INCIDENT_HISTORY_LINES=200
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  source "$CONF" 2>/dev/null
  WATCHDOG_DIR="${WATCHDOG_DIR:-$HOME/watchdog}"
  MODEL_TIMEOUT="${MODEL_TIMEOUT:-240}"
  INCIDENT_HISTORY_LINES="${INCIDENT_HISTORY_LINES:-200}"
fi
LOG="$WATCHDOG_DIR/review.log"
INCIDENTS="$WATCHDOG_DIR/incidents.log"
EVENTS="$WATCHDOG_DIR/events.log"
PROPOSALS="$WATCHDOG_DIR/proposals.md"
AGENT="$WATCHDOG_DIR/recovery-agent"
BLUEPRINT="$WATCHDOG_DIR/blueprint.md"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') REVIEW ===" >> "$LOG"

# Nothing to review yet: no incidents recorded.
if [ ! -f "$INCIDENTS" ] || [ ! -s "$INCIDENTS" ]; then
  echo "REVIEW: no incidents yet, nothing to improve" >> "$LOG"
  exit 0
fi

history=$(tail -n "$INCIDENT_HISTORY_LINES" "$INCIDENTS" 2>/dev/null)
events=""
if [ -f "$EVENTS" ]; then
  events=$(tail -n 60 "$EVENTS" 2>/dev/null)
fi

prompt="You are this Mac's self-improvement reviewer. You have NO terminal and cannot run commands — analyse only. Read the blueprint's Self-improvement section in $BLUEPRINT. Incident history (newest last): $history. Recent state events (newest last): $events. Look for patterns: a problem that recurs, a reflex that fires often, a fix that only treats symptoms, a hypothesis that turned out wrong. Propose up to 3 concrete improvements. Each proposal must say: what to change, why, what it is expected to achieve, and how to verify it (a concrete check). If nothing is worth changing, say so plainly — do not invent work. Finish with ANSWER= followed by the proposals, one per line, or 'NO CHANGE NEEDED'."
echo "--- review model call ---" >> "$LOG"

# Reuse run_to from watcher.sh if available; otherwise a simple call.
# (review.sh is standalone, so it defines its own minimal timeout.)
# READ-ONLY: the reviewer runs in `ask` mode, which has NO terminal.
# It cannot modify files — the "Do NOT modify any files" instruction is
# enforced by the tool, not by the prompt. All data it needs is embedded
# in the prompt by this script.
out=$(mktemp /tmp/mac-watchdog-review.XXXXXX)
"$AGENT" ask "$prompt" > "$out" 2>&1 &
pid=$!
i=0
while kill -0 $pid 2>/dev/null; do
  if [ "$i" -ge "$MODEL_TIMEOUT" ]; then
    kill -9 $pid 2>/dev/null
    pkill -9 -f "recovery-agent ask" 2>/dev/null
    echo "REVIEW MODEL TIMEOUT" >> "$LOG"
    break
  fi
  sleep 1
  i=$((i + 1))
done
wait $pid 2>/dev/null
cat "$out" >> "$LOG"
{
  echo "## $(date '+%Y-%m-%d %H:%M:%S') Daily review"
  echo ""
  grep -A 20 "^ANSWER=" "$out" 2>/dev/null | sed 's/^ANSWER=//'
  echo ""
} >> "$PROPOSALS"
rm -f "$out"
echo "REVIEW done, proposals in $PROPOSALS" >> "$LOG"
exit 0
