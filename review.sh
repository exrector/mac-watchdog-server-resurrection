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
# The idle-time research loop (how new tools enter the library):
# the machine is healthy right now, but problems have accumulated in
# the incident history. The reviewer looks up the most frequent problem
# on the web (best-effort, see web_research) and proposes NEW TOOLS for
# it — a better repair for a recurring failure, written as a script.
# A proposed tool is installed by the deterministic installer below
# (install_new_tools) as a *candidate* in tools.tsv: the model only
# writes text, the installer mechanically extracts it and registers it.
# The candidate then gets its chance in the next real incident as a
# last attempt, after every admitted tool failed (see watcher.sh
# run_reflexes), and only independent verification of the fix counts
# toward its record. That is the admission: proposed in idle time,
# proven in a real failure, promoted by its own results.
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
TOOLS="$WATCHDOG_DIR/tools.tsv"
ATTEMPTS="$WATCHDOG_DIR/tool-attempts.log"
PROPOSALS="$WATCHDOG_DIR/proposals.md"
AGENT="$WATCHDOG_DIR/recovery-agent"
BLUEPRINT="$WATCHDOG_DIR/blueprint.md"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') REVIEW ===" >> "$LOG"

# web_research: best-effort web search for a query, returns up to 5
# title+snippet pairs as plain text (or nothing). The local model is
# offline, so the research is done here, by this script, and the
# results are embedded in the model's prompt. Uses Bing's HTML results
# via curl and a small python3 parser; DuckDuckGo's HTML endpoints
# block automated requests (verified 2026-11-24: empty 15 KB pages).
# Any failure — no internet, no python3, no results, a changed page
# layout — returns nothing and the review continues from the model's
# own knowledge. Never blocks the review.
web_research() {
  local query="$1" html out
  command -v curl >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  html=$(mktemp /tmp/mac-watchdog-search.XXXXXX)
  if ! curl -s --max-time 15 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
      "https://www.bing.com/search?q=${query}" -o "$html" 2>/dev/null; then
    rm -f "$html"; return 1
  fi
  out=$(python3 - "$html" <<'PYEOF' 2>/dev/null
import re, html as h, sys
try:
    data = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
except OSError:
    sys.exit(1)
titles = re.findall(r'<h2><a[^>]*>(.*?)</a></h2>', data, re.S)
snips = re.findall(r'<div class="b_caption"><p[^>]*>(.*?)</p>', data, re.S)
def clean(s):
    return h.unescape(re.sub(r'<[^>]+>', '', s)).strip()
n = 0
for t, s in zip(titles, snips):
    t, s = clean(t), clean(s)
    if not t or not s:
        continue
    print("- %s: %s" % (t[:100], s[:250]))
    n += 1
    if n >= 5:
        break
sys.exit(0 if n else 1)
PYEOF
)
  rm -f "$html"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# research_query_for: the most frequent broken symptom in recent
# incidents, mapped to a web search query. The reviewer researches the
# problem that actually recurs on this machine, not a generic topic.
research_query_for() {
  local top
  top=$(grep -o 'SYMPTOMS: [a-z,]*' "$INCIDENTS" 2>/dev/null | tail -n 100 \
        | sed 's/SYMPTOMS: //; s/,/\n/g' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  case "$top" in
    tailscale) echo "macOS+Tailscale+keeps+disconnecting+fix" ;;
    dns) echo "macOS+DNS+stops+resolving+after+sleep+fix" ;;
    wifi) echo "macOS+Wi-Fi+disconnects+frequently+fix" ;;
    route) echo "macOS+default+route+disappears+fix" ;;
    ping) echo "macOS+network+unreachable+intermittent+fix" ;;
    *) return 1 ;;
  esac
}

# install_new_tools: deterministic installer for NEW-TOOL proposals.
# The model only writes text (a proposal in proposals.md); this
# function mechanically extracts it and registers the tool. It never
# runs the script and never modifies an existing tool.
# Format of a proposal (one block per tool):
#   NEW-TOOL: <id> | <symptom> | <one-line reason>
#   SCRIPT:
#   <zsh script, standard macOS tools only>
#   END-SCRIPT
# Validation (a proposal is untrusted text): the id must be lowercase
# letters, digits and dashes (no path traversal, no spaces); the
# symptom must be one of the known ones; the script must be non-empty
# and at most 200 lines; an id that already exists (registry or file)
# is skipped, never overwritten. The tool is registered as a candidate
# in tools.tsv — it enters real repair only as a last attempt, after
# every admitted tool failed (see watcher.sh).
install_new_tools() {
  local proposals="$1" id sym reason script_file
  local tools_dir="$WATCHDOG_DIR/tools"
  mkdir -p "$tools_dir" 2>/dev/null
  [ -f "$TOOLS" ] || printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
  awk '
    /^NEW-TOOL:/ { in_block=1; header=$0; next }
    in_block && /^SCRIPT:/ { in_script=1; next }
    in_block && in_script && /^END-SCRIPT/ { in_block=0; in_script=0; print header; for (i=1;i<=n;i++) print script[i]; print "END-BLOCK"; n=0; next }
    in_block && in_script { script[++n]=$0; next }
    in_block { next }
  ' "$proposals" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      NEW-TOOL:*)
        header="$line"
        id=$(echo "$header" | sed 's/^NEW-TOOL: *//; s/ *|.*//' | tr -d ' \t')
        sym=$(echo "$header" | awk -F'|' '{print $2}' | tr -d ' \t')
        reason=$(echo "$header" | awk -F'|' '{print $3}' | sed 's/^ *//')
        script_file=$(mktemp /tmp/mac-watchdog-newtool.XXXXXX)
        ;;
      END-BLOCK)
        # Validate and install.
        if ! echo "$id" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
          echo "INSTALL-TOOL: bad id '$id', skipping" >> "$LOG"; rm -f "$script_file"; continue
        fi
        case "$sym" in
          wifi|dns|route|tailscale|ping) ;;
          *) echo "INSTALL-TOOL: bad symptom '$sym' for $id, skipping" >> "$LOG"; rm -f "$script_file"; continue ;;
        esac
        if [ ! -s "$script_file" ] || [ "$(wc -l < "$script_file")" -gt 200 ]; then
          echo "INSTALL-TOOL: script for $id is empty or too long, skipping" >> "$LOG"; rm -f "$script_file"; continue
        fi
        if [ -f "$tools_dir/$id.sh" ] || awk -F'\t' -v id="$id" '$1==id{found=1} END{exit !found}' "$TOOLS" 2>/dev/null; then
          echo "INSTALL-TOOL: $id already exists, skipping (never overwritten)" >> "$LOG"; rm -f "$script_file"; continue
        fi
        {
          echo "#!/bin/zsh"
          echo "# Candidate tool proposed by the daily reviewer on $(date '+%Y-%m-%d')."
          echo "# Symptom: $sym. Reason: $reason"
          echo "# State: candidate. It runs only as a last attempt, after every"
          echo "# admitted tool for $sym failed, and only independent verification"
          echo "# of the fix counts toward its record (see watcher.sh)."
          cat "$script_file"
        } > "$tools_dir/$id.sh"
        chmod +x "$tools_dir/$id.sh"
        printf '%s\t%s\tcandidate\t0\t0\t0\t%s\n' "$id" "$id" "$sym" >> "$TOOLS"
        echo "INSTALL-TOOL: $id (symptom $sym) installed as candidate" >> "$LOG"
        rm -f "$script_file"
        ;;
      *) printf '%s\n' "$line" >> "$script_file" ;;
    esac
  done
}

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
# Tool statistics: the reviewer must see how the repair tools actually
# perform, or it cannot judge whether a fix helps. Without tools.tsv
# and the per-attempt log it would propose changes blind to the
# evidence about which tools work.
tools=""
if [ -f "$TOOLS" ]; then
  tools=$(cat "$TOOLS" 2>/dev/null)
fi
attempts=""
if [ -f "$ATTEMPTS" ]; then
  attempts=$(tail -n 40 "$ATTEMPTS" 2>/dev/null)
fi
# The blueprint's Self-improvement section, embedded in the prompt.
# The model runs in `ask` mode with NO file tools, so telling it to
# "read $BLUEPRINT" is an unreachable instruction — it cannot open the
# file. The section's text must be passed to it directly.
blueprint_section=""
if [ -f "$BLUEPRINT" ]; then
  blueprint_section=$(awk '/^#.*Self-improvement/,/^# [^S]/' "$BLUEPRINT" 2>/dev/null | head -n 60)
  [ -z "$blueprint_section" ] && blueprint_section=$(grep -A 30 "Self-improvement" "$BLUEPRINT" 2>/dev/null | head -n 40)
fi

# Web research on the most frequent problem (best-effort): the local
# model is offline, so this script fetches search results for it. If
# there is no internet or no results, the variable stays empty and the
# model works from its own knowledge.
research=""
_rq=$(research_query_for 2>/dev/null)
if [ -n "$_rq" ]; then
  research=$(web_research "$_rq" 2>/dev/null)
  if [ -n "$research" ]; then
    echo "REVIEW: web research for '${_rq//+/ }' returned results" >> "$LOG"
  else
    echo "REVIEW: web research unavailable, model works from knowledge" >> "$LOG"
  fi
fi

prompt="You are this Mac's self-improvement reviewer. You have NO terminal and cannot run commands — analyse only. The blueprint's Self-improvement section says: $blueprint_section. Incident history (newest last): $history. Recent state events (newest last): $events. Tool registry (id, name, state, runs, successes, total_seconds, incident_types): $tools. Recent tool attempts (newest last): $attempts. Web research on the most frequent problem (may be empty): $research. Look for patterns: a problem that recurs, a reflex that fires often, a fix that only treats symptoms, a hypothesis that turned out wrong, a tool that keeps failing or one that should be preferred. Propose up to 3 concrete improvements. Each proposal must say: what to change, why, what it is expected to achieve, and how to verify it (a concrete check). In addition, if a recurring problem has a better repair than the current tool, propose up to 2 NEW TOOLS for it — a script that would fix the problem better next time, using only standard macOS tools (networksetup, scutil, tailscale, route, ifconfig, ping). Each new tool, in this exact format, one block per tool: NEW-TOOL: <short-id-lowercase-dashes> | <symptom: wifi|dns|route|tailscale|ping> | <one line: why it is better than the current tool>. Then a line SCRIPT:, then the zsh script (shebang not needed), then a line END-SCRIPT. A new tool is installed as a candidate and only runs as a last attempt after every admitted tool failed, so propose only tools you would trust to run unattended. If nothing is worth changing and no new tool is needed, say so plainly — do not invent work. Finish with ANSWER= followed by the proposals and any NEW-TOOL blocks, or 'NO CHANGE NEEDED'."
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
  # Everything after ANSWER=, capped at 200 lines: a NEW-TOOL block
  # carries a whole script, so the old 20-line window would truncate it.
  awk '/^ANSWER=/{f=1; next} f{print; if(++n>=200) exit}' "$out" 2>/dev/null
  echo ""
} >> "$PROPOSALS"
rm -f "$out"
# Install any new tools the reviewer proposed: deterministic, the
# model only wrote text. A tool is registered as a candidate and
# enters real repair only as a last attempt (see watcher.sh).
install_new_tools "$PROPOSALS"
echo "REVIEW done, proposals in $PROPOSALS" >> "$LOG"
exit 0
