#!/bin/zsh
# Watcher: an autonomous immune system for this Mac.
#
# Layers, in order:
#   1. Deterministic health check (verify_health) — cheap, no model.
#   2. Reflexes — deterministic repair for KNOWN problems (Wi-Fi off,
#      DNS broken, route missing, Tailscale stopped/logged out). Fast,
#      predictable, safe. A script does these better than a model.
#   3. Analyst (the local Apple Intelligence model) — after every
#      incident, the model investigates WHY it happened, looks for
#      patterns in the incident history, and records the incident
#      (problem, cause hypothesis, fix, outcome) in incidents.log.
#      The model is the analyst, not the repairman: it explains and
#      remembers, it does not execute the routine fixes.
#   4. Escalation — only when reflexes fail (unknown problem): the model
#      is called as repairman, up to MAX_ATTEMPTS, with independent
#      verification after each attempt. Then the analyst records it.
#   5. GAVE UP — after MAX_ATTEMPTS, the analyst records the incident
#      and the Watcher opens the outbound tunnel (Plan B).
#
# The verdict always comes from the deterministic checks, never from
# the model's words. The incident memory (incidents.log) is what makes
# the system learn: a problem seen three times and fixed the same way
# becomes a reflex, not a model call.
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
# How many recent incidents to show the analyst for pattern-spotting.
INCIDENT_HISTORY_LINES="${INCIDENT_HISTORY_LINES:-80}"

# Tailscale is optional: if TAILSCALE_HOSTNAME is empty, the Tailscale
# check is skipped (the machine is used without Tailscale).

export WATCHDOG_DIR
LOG="$WATCHDOG_DIR/watcher.log"
INCIDENTS="$WATCHDOG_DIR/incidents.log"
EVENTS="$WATCHDOG_DIR/events.log"
TOOLS="$WATCHDOG_DIR/tools.tsv"
ATTEMPTS="$WATCHDOG_DIR/tool-attempts.log"
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

# Check ONE item by name. Prints one VERIFY line, returns 0 if OK,
# 1 if BROKEN. A skipped check (Wi-Fi with no WIFI_INTERFACE, Tailscale
# with no TAILSCALE_HOSTNAME) returns 0 — it is not a failure. Sets
# TS_STATUS to the raw Tailscale status line (for the reflex to tell
# "stopped" from "logged out"). Used both by verify_health (all items)
# and by run_reflexes, which verifies each item IMMEDIATELY after its
# reflex runs — so a tool is scored by the state of its own item right
# after it acted, not by the global state after all reflexes. (Scoring
# by the final global state misattributes success: if DNS and Tailscale
# are both broken and DNS recovers after the Tailscale fix, the DNS tool
# would wrongly get the credit.)
verify_item() {
  local item="$1" wifi ping dns route ts
  case "$item" in
    wifi)
      if [ -z "${WIFI_INTERFACE:-}" ]; then
        echo "VERIFY wifi SKIP (no WIFI_INTERFACE configured)" >> "$LOG"; return 0
      fi
      wifi=$(run_to 10 networksetup -getairportpower "$WIFI_INTERFACE" 2>&1)
      if echo "$wifi" | grep -q "On"; then
        echo "VERIFY wifi OK: $wifi" >> "$LOG"; return 0
      else
        echo "VERIFY wifi BROKEN: $wifi" >> "$LOG"; return 1
      fi
      ;;
    ping)
      ping=$(run_to 10 ping -c1 -q -W 2000 "$PING_TARGET" 2>&1)
      if echo "$ping" | grep -q "1 packets received"; then
        echo "VERIFY ping OK" >> "$LOG"; return 0
      else
        echo "VERIFY ping BROKEN: $ping" >> "$LOG"; return 1
      fi
      ;;
    dns)
      dns=$(run_to 15 dig +short "$DNS_TEST_HOST" 2>&1)
      if echo "$dns" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; then
        echo "VERIFY dns OK: $dns" >> "$LOG"; return 0
      else
        echo "VERIFY dns BROKEN: $dns" >> "$LOG"; return 1
      fi
      ;;
    route)
      route=$(run_to 10 route -n get default 2>&1 | grep gateway)
      if [ -n "${EXPECTED_GATEWAY:-}" ]; then
        if echo "$route" | grep -q "$EXPECTED_GATEWAY"; then
          echo "VERIFY route OK: $route" >> "$LOG"; return 0
        else
          echo "VERIFY route BROKEN: $route" >> "$LOG"; return 1
        fi
      else
        if echo "$route" | grep -q "gateway:"; then
          echo "VERIFY route OK: $route" >> "$LOG"; return 0
        else
          echo "VERIFY route BROKEN: $route" >> "$LOG"; return 1
        fi
      fi
      ;;
    tailscale)
      if [ -z "${TAILSCALE_HOSTNAME:-}" ]; then
        echo "VERIFY tailscale SKIP (no TAILSCALE_HOSTNAME configured)" >> "$LOG"; return 0
      fi
      ts=$(run_to 15 "$TAILSCALE_CLI" status 2>&1 | head -1)
      TS_STATUS="$ts"
      if echo "$ts" | grep -q "$TAILSCALE_HOSTNAME" && ! echo "$ts" | grep -Eqi "offline|stopped"; then
        echo "VERIFY tailscale OK: $ts" >> "$LOG"; return 0
      else
        echo "VERIFY tailscale BROKEN: $ts" >> "$LOG"; return 1
      fi
      ;;
  esac
  return 0
}

# Deterministic health verification. Sets BROKEN_ITEMS to an array of
# broken item names (empty when healthy). Returns 0 only if all enabled
# checks are OK.
# NOTE (critical): BROKEN_ITEMS is an ARRAY. In zsh, `for item in
# $BROKEN` with BROKEN="dns tailscale" iterates ONCE with the whole
# string — the reflexes would silently never fire. Always iterate
# "${BROKEN_ITEMS[@]}".
BROKEN_ITEMS=()
TS_STATUS=""
verify_health() {
  BROKEN_ITEMS=()
  TS_STATUS=""
  local item
  for item in wifi ping dns route tailscale; do
    if ! verify_item "$item"; then
      BROKEN_ITEMS+=("$item")
    fi
  done
  [ "${#BROKEN_ITEMS[@]}" -eq 0 ]
}

# --- Reflexes: deterministic repair for KNOWN problems. ---
# Each reflex fixes one broken item with a fixed command and logs what
# it did. No model involved: these are the five rules a script does
# better. REFLEX_LOG accumulates a one-line summary per reflex fired,
# for the incident record.
REFLEX_LOG=""
reflex_wifi() {
  echo "REFLEX wifi: networksetup -setairportpower $WIFI_INTERFACE on" >> "$LOG"
  run_to 15 networksetup -setairportpower "$WIFI_INTERFACE" on >> "$LOG" 2>&1
  REFLEX_LOG="$REFLEX_LOG wifi-on(rc=$?)"
}
reflex_dns() {
  echo "REFLEX dns: networksetup -setdnsservers Wi-Fi Empty" >> "$LOG"
  run_to 15 networksetup -setdnsservers Wi-Fi Empty >> "$LOG" 2>&1
  REFLEX_LOG="$REFLEX_LOG dns-reset(rc=$?)"
}
reflex_route() {
  if [ -z "${EXPECTED_GATEWAY:-}" ]; then
    echo "REFLEX route: SKIP (no EXPECTED_GATEWAY configured, cannot guess a gateway)" >> "$LOG"
    REFLEX_LOG="$REFLEX_LOG route-skip(no-gateway)"
    return 0
  fi
  echo "REFLEX route: sudo route add default $EXPECTED_GATEWAY" >> "$LOG"
  run_to 15 sudo -n /sbin/route add default "$EXPECTED_GATEWAY" >> "$LOG" 2>&1
  REFLEX_LOG="$REFLEX_LOG route-add(rc=$?)"
}
reflex_tailscale() {
  # "Logged out" needs the two-step re-login with the auth key; anything
  # else (stopped/offline) just needs `tailscale up`. Records which one
  # in REFLEX_TS_KIND, so the tool registry scores the right tool.
  if echo "$TS_STATUS" | grep -qi "logged out"; then
    REFLEX_TS_KIND="login"
    echo "REFLEX tailscale: re-login (logged out)" >> "$LOG"
    _key=$(/bin/zsh "$WATCHDOG_DIR/lib/get-secret.sh" tailscale-authkey 2>/dev/null)
    if [ -z "$_key" ]; then
      echo "REFLEX tailscale: no auth key available, cannot re-login" >> "$LOG"
      REFLEX_LOG="$REFLEX_LOG tailscale-login-fail(no-key)"
      return 0
    fi
    run_to 60 "$TAILSCALE_CLI" up --authkey="$_key" --reset >> "$LOG" 2>&1
    _rc1=$?
    run_to 30 "$TAILSCALE_CLI" up --accept-routes --hostname="${TAILSCALE_HOSTNAME}-cli" >> "$LOG" 2>&1
    _rc2=$?
    REFLEX_LOG="$REFLEX_LOG tailscale-login(rc=$_rc1/$_rc2)"
  else
    REFLEX_TS_KIND="up"
    echo "REFLEX tailscale: tailscale up" >> "$LOG"
    run_to 30 "$TAILSCALE_CLI" up >> "$LOG" 2>&1
    REFLEX_LOG="$REFLEX_LOG tailscale-up(rc=$?)"
  fi
}
# Run the reflex for every item in $BROKEN_ITEMS (array). After each
# reflex, the item is verified IMMEDIATELY (verify_item) and the tool is
# scored by that result — not by the global state after all reflexes.
# That is the correct attribution: a tool gets credit only if its own
# item recovered right after it acted. (A side effect — e.g. DNS
# recovering because Tailscale came back — is not credited to the tool
# that caused it; that is a known limitation, noted in the README.)
# Each attempt is also appended to tool-attempts.log: one line per run
# with its timestamp, tool, incident symptoms, duration and outcome.
# The aggregate (tools.tsv) is for ranking; the per-attempt log is the
# raw history the analyst and the reviewer use to judge a tool.
run_reflexes() {
  REFLEX_LOG=""
  REFLEX_TS_KIND=""
  local start end secs item tool_id ok
  for item in "${BROKEN_ITEMS[@]}"; do
    case "$item" in
      wifi|dns|route|tailscale)
        start=$(date +%s)
        case "$item" in
          wifi) reflex_wifi; tool_id="wifi-on" ;;
          dns) reflex_dns; tool_id="dns-reset" ;;
          route) reflex_route; tool_id="route-add" ;;
          tailscale)
            reflex_tailscale
            if [ "$REFLEX_TS_KIND" = "login" ]; then tool_id="tailscale-login"; else tool_id="tailscale-up"; fi
            ;;
        esac
        end=$(date +%s)
        secs=$((end - start))
        if verify_item "$item"; then
          ok=1
        else
          ok=0
        fi
        record_tool_run "$tool_id" "$ok" "$secs" "$item"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $tool_id symptoms=$SYMPTOMS secs=$secs success=$ok" >> "$ATTEMPTS"
        echo "TOOL $tool_id: success=$ok, ${secs}s" >> "$LOG"
        ;;
      ping) echo "REFLEX ping: no direct reflex (ping is a symptom, not a cause — the other reflexes address it)" >> "$LOG" ;;
    esac
  done
  REFLEX_LOG="${REFLEX_LOG# }"
}

# --- Tool registry (tools.tsv) — the foundation of Adaptive Tool Evolution. ---
# Each reflex is a tool. The registry records, per tool: how many times
# it ran, how many times it fixed its item, and how long it took.
# Columns (tab-separated):
#   id, name, state, runs, successes, total_seconds, incident_types
# States: candidate (created, not yet admitted), verified (passed
# independent checks), preferred (best results on comparable incidents),
# retired (kept in the library, no longer chosen by default). The five
# built-in reflexes start as "preferred" — they are the current
# defaults. A new tool is NEVER a modification of an existing one: it is
# added alongside, and the statistics decide which one is preferred.
# The trust mark (state) is issued by this script after verification,
# never by the model itself.
record_tool_run() {
  # $1 = tool id, $2 = success (1/0), $3 = seconds, $4 = incident type
  local id="$1" ok="$2" secs="$3" itype="$4"
  if [ ! -f "$TOOLS" ]; then
    printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
  fi
  # Existence check via awk, not grep: grep's \t is not a tab in BSD
  # grep (macOS), so `grep "^$id\t"` would never match and a duplicate
  # row would be appended on every run. awk -F'\t' splits on real tabs.
  if ! awk -F'\t' -v id="$id" '$1==id{found=1} END{exit !found}' "$TOOLS" 2>/dev/null; then
    printf '%s\t%s\tpreferred\t0\t0\t0\t%s\n' "$id" "$id" "$itype" >> "$TOOLS"
  fi
  awk -F'\t' -v id="$id" -v ok="$ok" -v secs="$secs" -v itype="$itype" 'BEGIN{OFS="\t"} $1==id{$4=$4+1; $5=$5+ok; $6=$6+secs; if(index($7, itype)==0){if($7!="")$7=$7","; $7=$7 itype} print; next} {print}' "$TOOLS" > "$TOOLS.tmp" 2>/dev/null && mv "$TOOLS.tmp" "$TOOLS"
}
# --- Structured hypothesis memory (hypotheses.tsv). ---
# "after three refutations, stop proposing a hypothesis". This table
# does. Columns (tab-separated):
#   id, first_seen, last_seen, occurrences, refutations, confidence,
#   status (active|refuted|established), text
# The analyst's ANSWER must contain a line:
#   HYPOTHESIS: <short text> | CONFIDENCE: <HYPOTHESIS|PATTERN|ESTABLISHED> | REFUTES: <id|none>
# record_hypothesis() parses that line and updates the table. The next
# analyst call receives the table, so it can reference hypothesis IDs
# and see refutation counts instead of guessing from prose.
HYPOTHESES="$WATCHDOG_DIR/hypotheses.tsv"
record_hypothesis() {
  local answer="$1" line text conf refutes now
  line=$(echo "$answer" | grep "^HYPOTHESIS:" | head -1)
  [ -z "$line" ] && return 0
  text=$(echo "$line" | sed 's/^HYPOTHESIS: *//; s/ *| CONFIDENCE:.*//' | tr -d '\t' | sed 's/^ *//; s/ *$//')
  conf=$(echo "$line" | sed 's/.*| CONFIDENCE: *//; s/ *| REFUTES:.*//' | tr -d ' \t')
  refutes=$(echo "$line" | sed 's/.*| REFUTES: *//' | tr -d ' \t')
  [ -z "$text" ] && return 0
  [ -z "$conf" ] && conf="HYPOTHESIS"
  now=$(date '+%Y-%m-%d %H:%M:%S')
  if [ ! -f "$HYPOTHESES" ]; then
    printf 'id\tfirst_seen\tlast_seen\toccurrences\trefutations\tconfidence\tstatus\ttext\n' > "$HYPOTHESES"
  fi
  # 1. A refutation: the new incident disproves an earlier hypothesis.
  if [ -n "$refutes" ] && [ "$refutes" != "none" ]; then
    awk -F'\t' -v id="$refutes" -v now="$now" 'BEGIN{OFS="\t"} $1==id{$5=$5+1; $3=now; if($5>=3)$7="refuted"; print; next} {print}' "$HYPOTHESES" > "$HYPOTHESES.tmp" 2>/dev/null && mv "$HYPOTHESES.tmp" "$HYPOTHESES"
    echo "HYPOTHESIS $refutes refuted (refutations now $(awk -F'\t' -v id="$refutes" '$1==id{print $5}' "$HYPOTHESES"))" >> "$LOG"
  fi
  # 2. Same hypothesis as an existing active one: count the occurrence.
  if awk -F'\t' -v txt="$text" 'NR>1 && index(tolower($8), tolower(txt))>0{found=1} END{exit !found}' "$HYPOTHESES" 2>/dev/null; then
    awk -F'\t' -v txt="$text" -v now="$now" -v conf="$conf" 'BEGIN{OFS="\t"} NR>1 && index(tolower($8), tolower(txt))>0{$4=$4+1; $3=now; $6=conf; print; next} {print}' "$HYPOTHESES" > "$HYPOTHESES.tmp" 2>/dev/null && mv "$HYPOTHESES.tmp" "$HYPOTHESES"
    echo "HYPOTHESIS occurrence counted for: $text" >> "$LOG"
  else
    # 3. New hypothesis: next id.
    local next_id
    next_id=$(awk -F'\t' 'NR>1 && $1 ~ /^H[0-9]+$/{n=substr($1,2)+0; if(n>m)m=n} END{print "H" (m+1)}' "$HYPOTHESES" 2>/dev/null)
    printf '%s\t%s\t%s\t1\t0\t%s\tactive\t%s\n' "$next_id" "$now" "$now" "$conf" "$text" >> "$HYPOTHESES"
    echo "HYPOTHESIS $next_id recorded: $text" >> "$LOG"
  fi
}
# --- Analyst: the model as investigator, not repairman. ---
# After an incident (fixed by reflexes, fixed by the model, or gave up),
# the model analyses WHAT happened and WHY, looks for patterns in the
# incident history, and the result is appended to incidents.log. The
# model does NOT fix anything here — the fixing is already done (or has
# failed). Its job is understanding and memory.
#
# READ-ONLY: the analyst runs in `ask` mode, which has NO terminal.
# It cannot run commands, so it cannot repair anything even if it
# wanted to — the "Do NOT run any repair commands" instruction is now
# enforced by the tool, not by the prompt. All data it needs (symptoms,
# reflexes, pre-failure events, incident history, hypothesis table) is
# embedded in the prompt by this script. The repairman (escalation) is
# the only role that gets the terminal, via `agent` mode.
#
# Three rules for the analysis (the analyst's job description):
#   1. Use the PRE-FAILURE record. events.log (written by observer.sh
#      every minute) shows what the machine looked like BEFORE the
#      break. A cause needs pre-failure evidence, not just post-failure
#      symptoms. If the events do not support a cause, say so.
#   2. Label confidence. Every cause assessment gets one level:
#      HYPOTHESIS (single occurrence, weak evidence), PATTERN (seen 2+
#      times with the same signature), ESTABLISHED (confirmed by a
#      controlled check, or a permanent fix that held). Never present a
#      hypothesis as an established cause.
#   3. Judge your own past hypotheses. The hypothesis table (below)
#      lists earlier hypotheses with their refutation counts. Check the
#      previous incident's cause hypothesis against what happened this
#      time. If it was wrong, name its id in REFUTES — a refuted
#      hypothesis is also knowledge. A hypothesis refuted three times
#      is retired and must not be proposed again.
# The analyst's three questions, in order: What broke? Why does it keep
# happening? What should change so it does not happen again? The third
# question is the point of the whole system.
# Arguments: $1 = outcome (FIXED-BY-REFLEX | FIXED-BY-MODEL | GAVE-UP),
#            $2 = symptoms (the BROKEN list at detection time).
call_analyst() {
  local outcome="$1" symptoms="$2"
  local history="" events="" hypotheses=""
  if [ -f "$INCIDENTS" ]; then
    history=$(tail -n "$INCIDENT_HISTORY_LINES" "$INCIDENTS" 2>/dev/null)
  fi
  if [ -f "$EVENTS" ]; then
    events=$(tail -n 30 "$EVENTS" 2>/dev/null)
  fi
  if [ -f "$HYPOTHESES" ]; then
    hypotheses=$(cat "$HYPOTHESES" 2>/dev/null)
  fi
  local prompt="You are the analyst for this Mac's watchdog. You have NO terminal and cannot run commands — analyse only. An incident just happened. Symptoms: $symptoms. Reflexes tried: ${REFLEX_LOG:-none}. Outcome: $outcome. State BEFORE the failure (observer, newest last): $events. Recent incident history (newest last): $history. Hypothesis table (id, occurrences, refutations, confidence, status, text): $hypotheses. Analyse: what most likely caused this (use the pre-failure events, not just the symptoms), is it a repeat of an earlier incident (say which one and how many times), and was an earlier hypothesis confirmed or refuted by this one (name its id)? Label your cause assessment HYPOTHESIS, PATTERN or ESTABLISHED. Answer the three questions: what broke, why does it keep happening, what should change so it does not happen again. Finish with two lines: first HYPOTHESIS: <short cause text> | CONFIDENCE: <level> | REFUTES: <id or none>, then ANSWER= followed by a short incident analysis (cause + confidence level + recurrence + recommendation). Keep it under 10 lines."
  echo "--- analyst ---" >> "$LOG"
  local out
  out=$(run_to "$MODEL_TIMEOUT" "$AGENT" ask "$prompt" 2>&1)
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    pkill -9 -f "recovery-agent ask" 2>/dev/null
    echo "ANALYST TIMEOUT" >> "$LOG"
  fi
  echo "$out" >> "$LOG"
  # Update the structured hypothesis memory from the analyst's answer.
  record_hypothesis "$out"
  # Record the incident: facts from the script + the model's analysis.
  {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') INCIDENT ==="
    echo "SYMPTOMS: $symptoms"
    echo "REFLEXES: ${REFLEX_LOG:-none}"
    echo "OUTCOME: $outcome"
    echo "$out" | grep -A 20 "^ANSWER=" | sed 's/^/ANALYSIS: /'
    echo "$out" | grep "^HYPOTHESIS:" | sed 's/^/CAUSE: /'
  } >> "$INCIDENTS"
  echo "INCIDENT recorded in $INCIDENTS" >> "$LOG"
}

PROMPT="Read $BLUEPRINT and check this Mac against it, item by item, in order. Check each item ONCE. Do not re-run a Check that already returned Good. For each item report one line: OK or BROKEN with the exact command output that proves it. Repair only the BROKEN items using the Repairs section, then re-run ONLY that item's Check. Finish with ANSWER= followed by one line per item."

# Dry run: check only, change nothing. Runs the deterministic health
# check, prints the result, and exits without waking the model.
if [ "${1:-}" = "--dry-run" ]; then
  if verify_health; then
    echo "DRY-RUN: HEALTHY — no repair needed, model would not be woken."
    exit 0
  else
    echo "DRY-RUN: BROKEN (${(j: :)BROKEN_ITEMS}) — reflexes would fire, then the analyst. See VERIFY lines above."
    exit 1
  fi
fi

# Test mode: invoke the analyst on prepared data, without touching the
# network. Reads the prepared incident history, events and hypothesis
# table from the watchdog dir and calls the analyst with a synthetic
# incident. Usage: watcher.sh --test-analyst [symptoms] [outcome]
#   symptoms: e.g. "dns" (default: "dns")
#   outcome: FIXED-BY-REFLEX | FIXED-BY-MODEL | GAVE-UP (default: FIXED-BY-REFLEX)
# The analyst runs in read-only `ask` mode and cannot repair anything,
# so this is safe to run on a healthy machine. Prepare the data first:
# write a past incident to incidents.log, pre-incident state lines to
# events.log, and a hypothesis to hypotheses.tsv — then the analyst
# should spot the pattern (or refute the hypothesis) and record its
# conclusion in incidents.log and hypotheses.tsv.
if [ "${1:-}" = "--test-analyst" ]; then
  SYMPTOMS="${2:-dns}"
  REFLEX_LOG="dns-reset (test)"
  echo "TEST-ANALYST: invoking the analyst on prepared data (symptoms=$SYMPTOMS, outcome=${3:-FIXED-BY-REFLEX})" >> "$LOG"
  call_analyst "${3:-FIXED-BY-REFLEX}" "$SYMPTOMS"
  echo "TEST-ANALYST: done. See incidents.log and hypotheses.tsv." >> "$LOG"
  exit 0
fi

# 1. Pre-check: if the machine is already healthy, do nothing. The model
# is not woken on a healthy machine.
if verify_health; then
  echo "HEALTHY, no repair needed" >> "$LOG"
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') DONE ===" >> "$LOG"
  python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
  exit 0
fi
SYMPTOMS="${(j: :)BROKEN_ITEMS}"
echo "BROKEN items: $SYMPTOMS" >> "$LOG"

# 2. Reflexes: deterministic repair for the known problems.
run_reflexes

# 3. Re-verify after the reflexes. (Each tool was already scored inline
# in run_reflexes, by verifying its own item right after it acted.)
verify_health
_reflex_rc=$?
if [ "$_reflex_rc" -eq 0 ]; then
  echo "VERIFIED HEALTHY after reflexes" >> "$LOG"
  call_analyst "FIXED-BY-REFLEX" "$SYMPTOMS"
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') DONE ===" >> "$LOG"
  python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
  exit 0
fi
echo "STILL BROKEN after reflexes (${(j: :)BROKEN_ITEMS}) — escalating to the model" >> "$LOG"

# 4. Escalation: reflexes failed, the problem is unknown. Only now does
# the model act as repairman, up to MAX_ATTEMPTS, with independent
# verification after each attempt.
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  echo "--- model attempt $attempt ---" >> "$LOG"
  run_to "$MODEL_TIMEOUT" "$AGENT" agent "$PROMPT" >> "$LOG" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    pkill -9 -f "recovery-agent agent" 2>/dev/null
    echo "MODEL TIMEOUT on attempt $attempt" >> "$LOG"
  fi
  if verify_health; then
    echo "VERIFIED HEALTHY after model attempt $attempt" >> "$LOG"
    call_analyst "FIXED-BY-MODEL" "$SYMPTOMS"
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') DONE ===" >> "$LOG"
    python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
    exit 0
  else
    echo "STILL BROKEN after model attempt $attempt" >> "$LOG"
  fi
  attempt=$((attempt + 1))
done

# 5. GAVE UP: the analyst records the incident, then Plan B.
echo "GAVE UP after $MAX_ATTEMPTS model attempts, needs a human" >> "$LOG"
call_analyst "GAVE-UP" "$SYMPTOMS"
if [ -x "$WATCHDOG_DIR/call-home.sh" ]; then
  "$WATCHDOG_DIR/call-home.sh" >> "$LOG" 2>&1
  echo "CALL-HOME invoked" >> "$LOG"
fi
echo "=== $(date '+%Y-%m-%d %H:%M:%S') DONE ===" >> "$LOG"
python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
exit 1
