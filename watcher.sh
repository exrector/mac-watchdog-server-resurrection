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
        # Select the tool by its registry score: the highest-scored
        # tool for this symptom is the one applied. If the registry
        # has no tool for this symptom yet, fall back to the built-in
        # default for it.
        tool_id=$(select_tool_for_symptom "$item")
        if [ -z "$tool_id" ]; then
          case "$item" in
            wifi) tool_id="wifi-on" ;;
            dns) tool_id="dns-reset" ;;
            route) tool_id="route-add" ;;
            tailscale) tool_id="tailscale-up" ;;
          esac
        fi
        echo "TOOL-SELECT $item -> $tool_id (by registry score)" >> "$LOG"
        start=$(date +%s)
        case "$tool_id" in
          wifi-on) reflex_wifi ;;
          dns-reset) reflex_dns ;;
          route-add) reflex_route ;;
          tailscale-up|tailscale-login) reflex_tailscale ;;
          *) echo "TOOL $tool_id: no implementation, skipping" >> "$LOG"; continue ;;
        esac
        # For tailscale, the reflex may have done a login instead of a
        # plain up (state decides: logged out needs a login). Record
        # the tool that actually ran, so its score is the one updated.
        if [ "$item" = "tailscale" ] && [ "$REFLEX_TS_KIND" = "login" ]; then tool_id="tailscale-login"; fi
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

# --- Tool selection by score (Adaptive Tool Evolution, the ranking). ---
# Given a symptom, pick the tool with the highest score from the
# registry (tools.tsv). The score is the smoothed success rate
# (successes+1)/(runs+2) — Laplace smoothing, so a new tool starts at
# a neutral 0.5 and a tool with more evidence wins over one with a
# single lucky run — plus a small state weight (preferred 3, verified
# 2, candidate 1), with faster average time breaking ties. Retired
# tools are never selected. The tool with the highest score is the one
# applied at the next failure for that symptom. A new tool is NEVER a
# modification of an existing one: it is added alongside, and the
# statistics decide which one is preferred. Returns the tool id, or
# nothing if no tool in the registry handles this symptom.
select_tool_for_symptom() {
  local sym="$1"
  [ -f "$TOOLS" ] || return 1
  awk -F'\t' -v sym="$sym" '
    NR==1 { next }
    $3 == "retired" { next }
    {
      n = split($7, types, ",")
      found = 0
      for (i = 1; i <= n; i++) if (types[i] == sym) found = 1
      if (!found) next
      rate = ($5 + 1) / ($4 + 2)
      w = ($3 == "preferred") ? 3 : ($3 == "verified") ? 2 : 1
      avg = ($4 > 0) ? $6 / $4 : 0
      score = rate * 100 + w
      if (score > best_score || (score == best_score && avg < best_avg)) {
        best_score = score; best_avg = avg; best_id = $1
      }
    }
    END { if (best_id != "") print best_id }
  ' "$TOOLS" 2>/dev/null
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
#   status (active|refuted|established), text, evidence
# The evidence column ties each hypothesis to the specific incidents
# that support it: a comma-separated list of "timestamp:symptoms".
# A hypothesis is never a fact on its own — it is an interpretation,
# and the evidence column shows exactly which incidents it rests on.
# The analyst's ANSWER must contain a line:
#   HYPOTHESIS: <short text> | CONFIDENCE: <HYPOTHESIS|PATTERN|ESTABLISHED> | REFUTES: <id|none>
# record_hypothesis() parses that line and updates the table. The next
# analyst call receives the table, so it can reference hypothesis IDs
# and see refutation counts instead of guessing from prose.
# Arguments: $1 = the analyst's answer, $2 = the current symptoms
# (for the evidence column).
HYPOTHESES="$WATCHDOG_DIR/hypotheses.tsv"
record_hypothesis() {
  local answer="$1" symptoms="$2" line text conf refutes now
  line=$(echo "$answer" | grep "^HYPOTHESIS:" | head -1)
  [ -z "$line" ] && return 0
  text=$(echo "$line" | sed 's/^HYPOTHESIS: *//; s/ *| CONFIDENCE:.*//' | tr -d '\t' | sed 's/^ *//; s/ *$//')
  conf=$(echo "$line" | sed 's/.*| CONFIDENCE: *//; s/ *| REFUTES:.*//' | tr -d ' \t')
  refutes=$(echo "$line" | sed 's/.*| REFUTES: *//' | tr -d ' \t')
  [ -z "$text" ] && return 0
  # UNKNOWN is not a hypothesis — it means the evidence did not support
  # a cause. Do not record it as a supported hypothesis.
  if [ "$text" = "UNKNOWN" ]; then
    echo "HYPOTHESIS UNKNOWN: no supported cause recorded" >> "$LOG"
    return 0
  fi
  [ -z "$conf" ] && conf="HYPOTHESIS"
  # Normalise the confidence level: it must be one of the three words.
  # The model sometimes answers with a number ("95") — a percentage is
  # not an evidence level, so it falls back to HYPOTHESIS.
  case "$(echo "$conf" | tr 'a-z' 'A-Z')" in
    HYPOTHESIS|PATTERN|ESTABLISHED) conf="$(echo "$conf" | tr 'a-z' 'A-Z')" ;;
    *) echo "HYPOTHESIS confidence '$conf' is not a level, using HYPOTHESIS" >> "$LOG"; conf="HYPOTHESIS" ;;
  esac
  # Validate REFUTES: it must be a hypothesis id (H<number>) or "none".
  # The model sometimes puts prose or the ANSWER text in this field —
  # that is not an id, so it is ignored (treated as "none").
  case "$refutes" in
    none|H[0-9]*) ;;
    *) echo "HYPOTHESIS REFUTES '$refutes' is not an id, ignoring" >> "$LOG"; refutes="none" ;;
  esac
  now=$(date '+%Y-%m-%d %H:%M:%S')
  if [ ! -f "$HYPOTHESES" ]; then
    printf 'id\tfirst_seen\tlast_seen\toccurrences\trefutations\tconfidence\tstatus\ttext\tevidence\n' > "$HYPOTHESES"
  fi
  # 1. A refutation: the new incident disproves an earlier hypothesis.
  # Guard: if the refuted id's text MATCHES the new hypothesis text, the
  # model contradicted itself (it confirmed the very hypothesis it claims
  # to refute). Skip the refutation — a match is a confirmation.
  if [ -n "$refutes" ] && [ "$refutes" != "none" ]; then
    if awk -F'\t' -v id="$refutes" -v txt="$text" 'NR>1 && $1==id && index(tolower($8), tolower(txt))>0{found=1} END{exit !found}' "$HYPOTHESES" 2>/dev/null; then
      echo "HYPOTHESIS $refutes NOT refuted: its text matches the new hypothesis (confirmation, not refutation)" >> "$LOG"
    else
      awk -F'\t' -v id="$refutes" -v now="$now" 'BEGIN{OFS="\t"} $1==id{$5=$5+1; $3=now; if($5>=3)$7="refuted"; print; next} {print}' "$HYPOTHESES" > "$HYPOTHESES.tmp" 2>/dev/null && mv "$HYPOTHESES.tmp" "$HYPOTHESES"
      echo "HYPOTHESIS $refutes refuted (refutations now $(awk -F'\t' -v id="$refutes" '$1==id{print $5}' "$HYPOTHESES"))" >> "$LOG"
    fi
  fi
  # 2. Same hypothesis as an existing active one: count the occurrence
  # and append this incident to the evidence column. Cap the confidence
  # by occurrences: a first occurrence is HYPOTHESIS, 2+ is at most
  # PATTERN. ESTABLISHED needs a controlled check, which the model
  # cannot do — the model claiming ESTABLISHED is downgraded to PATTERN.
  if awk -F'\t' -v txt="$text" 'NR>1 && index(tolower($8), tolower(txt))>0{found=1} END{exit !found}' "$HYPOTHESES" 2>/dev/null; then
    awk -F'\t' -v txt="$text" -v now="$now" -v conf="$conf" -v ev="$now:$symptoms" 'BEGIN{OFS="\t"} NR>1 && index(tolower($8), tolower(txt))>0{$4=$4+1; $3=now; if($4<2){$6="HYPOTHESIS"} else if(conf=="ESTABLISHED"){$6="PATTERN"} else {$6=conf}; if($9!="")$9=$9","; $9=$9 ev; print; next} {print}' "$HYPOTHESES" > "$HYPOTHESES.tmp" 2>/dev/null && mv "$HYPOTHESES.tmp" "$HYPOTHESES"
    echo "HYPOTHESIS occurrence counted for: $text" >> "$LOG"
  else
    # 3. New hypothesis: next id, with this incident as its first
    # evidence. A first occurrence is always HYPOTHESIS, whatever the
    # model claimed.
    local next_id
    next_id=$(awk -F'\t' 'NR>1 && $1 ~ /^H[0-9]+$/{n=substr($1,2)+0; if(n>m)m=n} END{print "H" (m+1)}' "$HYPOTHESES" 2>/dev/null)
    printf '%s\t%s\t%s\t1\t0\t%s\tactive\t%s\t%s:%s\n' "$next_id" "$now" "$now" "HYPOTHESIS" "$text" "$now" "$symptoms" >> "$HYPOTHESES"
    echo "HYPOTHESIS $next_id recorded: $text" >> "$LOG"
  fi
}

# Deterministic verification of the analyst's hypothesis (Proposal 3).
# The model's conclusion must be about something that was actually
# broken in this incident. Extract the symptom keywords from the
# HYPOTHESIS text (dns, tailscale, wifi, route, ping). If the text
# mentions symptoms but NONE of them were broken in this incident, the
# hypothesis is unsupported: the model attributed the incident to
# something that was not broken. The answer is rewritten with
# HYPOTHESIS: UNKNOWN, so the unsupported claim never inflates a
# hypothesis in the memory. If the text mentions no symptom keyword at
# all, it cannot be verified this way and passes through.
verify_hypothesis() {
  local answer="$1" symptoms="$2"
  local line text low sym mentioned supported
  line=$(echo "$answer" | grep "^HYPOTHESIS:" | head -1)
  if [ -z "$line" ]; then echo "$answer"; return 0; fi
  text=$(echo "$line" | sed 's/^HYPOTHESIS: *//; s/ *| CONFIDENCE:.*//')
  low=$(echo "$text" | tr 'A-Z' 'a-z')
  mentioned=0; supported=0
  for sym in dns tailscale wifi route ping; do
    if echo "$low" | grep -q "$sym"; then
      mentioned=1
      if echo "$symptoms" | grep -qw "$sym"; then supported=1; fi
    fi
  done
  if [ "$mentioned" -eq 1 ] && [ "$supported" -eq 0 ]; then
    echo "HYPOTHESIS UNSUPPORTED: '$text' is about symptoms not broken in this incident ($symptoms) — recording UNKNOWN" >> "$LOG"
    echo "$answer" | sed 's/^HYPOTHESIS:.*/HYPOTHESIS: UNKNOWN | CONFIDENCE: HYPOTHESIS | REFUTES: none/'
    return 0
  fi
  echo "$answer"
}

# Apply the model's tool evaluations (TOOL-EVAL lines) to the registry.
# The model evaluates the tools that ran in this incident and proposes
# their state — this is the model's job: it judges which tools work and
# ranks them. The controller applies the proposal, with one safety
# bound: a tool can only become `preferred` if it has 3+ runs and a
# success rate of 0.8 or better. If the model proposes `preferred` for
# a tool with insufficient evidence, it is capped at `verified`. A tool
# the model marks `retired` is retired. The model decides the ranking;
# the controller only enforces minimum evidence and records the facts.
apply_tool_evals() {
  local answer="$1"
  local evals line tool_id state reason
  evals=$(echo "$answer" | grep "^TOOL-EVAL:" 2>/dev/null)
  [ -z "$evals" ] && return 0
  echo "$evals" | while IFS= read -r line; do
    tool_id=$(echo "$line" | sed 's/^TOOL-EVAL: *//; s/ *| STATE:.*//' | tr -d ' \t')
    state=$(echo "$line" | sed 's/.*| STATE: *//; s/ *| REASON:.*//' | tr -d ' \t' | tr 'A-Z' 'a-z')
    reason=$(echo "$line" | sed 's/.*| REASON: *//')
    [ -z "$tool_id" ] && continue
    case "$state" in
      preferred|verified|candidate|retired) ;;
      *) echo "TOOL-EVAL $tool_id: state '$state' is not valid, ignoring" >> "$LOG"; continue ;;
    esac
    if [ "$state" = "preferred" ]; then
      if ! awk -F'\t' -v id="$tool_id" '$1==id && $4>=3 && $4>0 && $5/$4>=0.8{found=1} END{exit !found}' "$TOOLS" 2>/dev/null; then
        echo "TOOL-EVAL $tool_id: preferred needs 3+ runs and >=0.8 success, capping at verified" >> "$LOG"
        state="verified"
      fi
    fi
    awk -F'\t' -v id="$tool_id" -v st="$state" 'BEGIN{OFS="\t"} $1==id{$3=st; print; next} {print}' "$TOOLS" > "$TOOLS.tmp" 2>/dev/null && mv "$TOOLS.tmp" "$TOOLS"
    echo "TOOL-EVAL $tool_id -> $state ($reason)" >> "$LOG"
  done
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
# Filter the incident history to blocks whose SYMPTOMS share at least
# one word with the current symptoms. Without this, a dominant pattern
# (e.g. six DNS incidents) overwhelms the analyst: it attributes a new,
# different incident (Tailscale) to the frequent pattern instead of
# analysing the current symptoms. The history is only useful for
# same-symptom recurrence.
filter_history_by_symptoms() {
  local file="$1" symptoms="$2" maxlines="$3"
  [ -f "$file" ] || return 0
  awk -v sym="$symptoms" -v max="$maxlines" '
    function flush() {
      if (block == "") return
      n = split(sym, s, " ")
      for (i = 1; i <= n; i++) {
        if (index(symline, s[i]) > 0) { print block; return }
      }
    }
    /^=== / { flush(); block = $0 "\n"; symline = ""; next }
    { block = block $0 "\n"; if ($1 == "SYMPTOMS:") symline = $0 }
    END { flush() }
  ' "$file" 2>/dev/null | tail -n "$maxlines"
}
# Filter the hypothesis table to rows whose text mentions at least one
# of the current symptoms (case-insensitive). Without this, a dominant
# hypothesis (e.g. H1, DNS, 6 occurrences) anchors the analyst even
# when the incident history is already filtered: the model latches onto
# the most frequent hypothesis in the table regardless of the current
# symptoms. The header row is always kept.
filter_hypotheses_by_symptoms() {
  local file="$1" symptoms="$2"
  [ -f "$file" ] || return 0
  awk -F'\t' -v sym="$symptoms" '
    NR==1 { print; next }
    {
      n = split(sym, s, " ")
      low = tolower($8)
      for (i = 1; i <= n; i++) {
        if (index(low, tolower(s[i])) > 0) { print; next }
      }
    }
  ' "$file" 2>/dev/null
}
call_analyst() {
  local outcome="$1" symptoms="$2"
  local events="" history="" hypotheses=""
  if [ -f "$EVENTS" ]; then
    events=$(tail -n 30 "$EVENTS" 2>/dev/null)
  fi
  # Phase 1: analyse ONLY the current incident. No history, no
  # hypotheses — the model forms a preliminary conclusion from the
  # current facts alone, so a dominant old pattern cannot anchor it.
  # The diagnostic experiment showed the model misattributes even with
  # a clean context, so Phase 1 alone is not trusted either — Phase 2
  # and the deterministic verification below are the safety net.
  echo "--- analyst phase 1 (current incident only) ---" >> "$LOG"
  local prompt1="You are the analyst for this Mac's watchdog. You have NO terminal and cannot run commands — analyse only. An incident just happened. SYMPTOMS (what was broken): $symptoms. Reflexes tried: ${REFLEX_LOG:-none}. Outcome: $outcome. State BEFORE the failure (observer, newest last): $events. Analyse ONLY this incident: what broke, and what most likely caused it. Use the symptoms and the pre-failure events. Do NOT invent history — there is none in this prompt. Label your cause assessment with exactly one of these three words — HYPOTHESIS, PATTERN or ESTABLISHED — never a number or a percentage. Finish with one line: HYPOTHESIS: <short cause text> | CONFIDENCE: <HYPOTHESIS or PATTERN or ESTABLISHED> | REFUTES: none. Keep it under 5 lines."
  local out1
  out1=$(run_to "$MODEL_TIMEOUT" "$AGENT" ask "$prompt1" 2>&1)
  local rc1=$?
  if [ "$rc1" -eq 124 ]; then
    pkill -9 -f "recovery-agent ask" 2>/dev/null
    echo "ANALYST PHASE 1 TIMEOUT" >> "$LOG"
  fi
  echo "$out1" >> "$LOG"
  local prelim
  prelim=$(echo "$out1" | grep "^HYPOTHESIS:" | head -1)
  # Phase 2: compare the preliminary conclusion against the history.
  # Only now does the model see past incidents and hypotheses — and
  # only those with the SAME symptoms, so a frequent pattern for a
  # different symptom cannot hijack this incident.
  if [ -f "$INCIDENTS" ]; then
    history=$(filter_history_by_symptoms "$INCIDENTS" "$symptoms" "$INCIDENT_HISTORY_LINES" 2>/dev/null)
  fi
  if [ -f "$HYPOTHESES" ]; then
    hypotheses=$(filter_hypotheses_by_symptoms "$HYPOTHESES" "$symptoms" 2>/dev/null)
  fi
  local tools=""
  if [ -f "$TOOLS" ]; then
    tools=$(cat "$TOOLS" 2>/dev/null)
  fi
  echo "--- analyst phase 2 (compare with history) ---" >> "$LOG"
  local prompt2="You are the analyst for this Mac's watchdog. You have NO terminal and cannot run commands — analyse only. Preliminary conclusion for the CURRENT incident (symptoms: $symptoms, outcome: $outcome): $prelim. Now compare it with the history. Recent incident history with THE SAME SYMPTOMS (newest last): $history. Hypothesis table for THESE symptoms (id, occurrences, refutations, confidence, status, text, evidence): $hypotheses. If the history and the hypothesis table are EMPTY, there is no prior hypothesis to confirm or refute — write REFUTES: none and do not invent an id. Is the preliminary conclusion a repeat of an earlier incident WITH THE SAME SYMPTOMS? If yes, say which one and how many times, and confirm or upgrade the confidence (HYPOTHESIS -> PATTERN after 2+ same-symptom occurrences). If the preliminary conclusion does NOT match the history, say so — do not force it onto an old pattern. Was an earlier hypothesis confirmed or refuted by this incident (name its id)? REFUTES names an id ONLY when the new evidence CONTRADICTS that hypothesis, and the id must be one that appears in the hypothesis table above. If this incident CONFIRMS an earlier hypothesis (same cause again), write REFUTES: none. Answer the three questions: what broke, why does it keep happening, what should change so it does not happen again. Then evaluate the tools that ran in this incident (tools used: ${REFLEX_LOG:-none}). Tool registry (id, name, state, runs, successes, total_seconds, incident_types): $tools. For each tool that ran, judge it: did it fix its item well, was it the right tool, was it slow, did it cause harm? Propose its state: preferred (it worked well and should be the default for this symptom), verified (it worked but needs more evidence), candidate (untested or uncertain), or retired (it failed or caused harm). Output one line per tool you evaluated, each on its own line: TOOL-EVAL: <tool-id> | STATE: <preferred|verified|candidate|retired> | REASON: <short>. Finish with two lines, each on its own line and nothing else on those lines: first HYPOTHESIS: <short cause text> | CONFIDENCE: <HYPOTHESIS or PATTERN or ESTABLISHED> | REFUTES: <id or none>, then ANSWER= followed by a short incident analysis (cause + confidence level + recurrence + recommendation). The REFUTES field holds ONLY an id from the table above or the word none — never prose, never the ANSWER text. Keep it under 12 lines."
  local out
  out=$(run_to "$MODEL_TIMEOUT" "$AGENT" ask "$prompt2" 2>&1)
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    pkill -9 -f "recovery-agent ask" 2>/dev/null
    echo "ANALYST TIMEOUT" >> "$LOG"
  fi
  echo "$out" >> "$LOG"
  # Deterministic verification: the model's hypothesis must be about
  # something that was actually broken in this incident. If it is not,
  # the answer is rewritten with HYPOTHESIS: UNKNOWN, so the
  # unsupported claim never inflates a hypothesis in the memory.
  local verified_out
  verified_out=$(verify_hypothesis "$out" "$symptoms")
  # Update the structured hypothesis memory from the verified answer.
  record_hypothesis "$verified_out" "$symptoms"
  # The model evaluates the tools that ran in this incident and proposes
  # their states — this is the model's job: it judges which tools work
  # and ranks them. The controller applies the proposal (with a minimum
  # evidence bound) and records the facts.
  apply_tool_evals "$out"
  # Record the incident: facts from the script + the model's analysis.
  {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') INCIDENT ==="
    echo "SYMPTOMS: $symptoms"
    echo "REFLEXES: ${REFLEX_LOG:-none}"
    echo "OUTCOME: $outcome"
    echo "$verified_out" | grep -A 20 "^ANSWER=" | sed 's/^/ANALYSIS: /'
    echo "$verified_out" | grep "^HYPOTHESIS:" | sed 's/^/CAUSE: /'
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
  case "$SYMPTOMS" in
    *tailscale*) REFLEX_LOG="tailscale-up (test)" ;;
    *dns*) REFLEX_LOG="dns-reset (test)" ;;
    *wifi*) REFLEX_LOG="wifi-on (test)" ;;
    *route*) REFLEX_LOG="route-add (test)" ;;
    *) REFLEX_LOG="none (test)" ;;
  esac
  echo "TEST-ANALYST: invoking the analyst on prepared data (symptoms=$SYMPTOMS, outcome=${3:-FIXED-BY-REFLEX})" >> "$LOG"
  call_analyst "${3:-FIXED-BY-REFLEX}" "$SYMPTOMS"
  python3 "$WATCHDOG_DIR/reasoning.py" 2>/dev/null
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
