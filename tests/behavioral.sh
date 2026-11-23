#!/bin/zsh
# tests/behavioral.sh — behavioral tests for the ranking, memory and
# fallback logic in watcher.sh. Runs on any machine with zsh and awk
# (no macOS, no Apple Intelligence, no real network). The CI runs it on
# ubuntu-latest; a real end-to-end test still needs a Mac.
#
# What it covers (the audit's P0/P1 concerns):
#   1. Ranking: a 19/20 tool beats a 5/5 tool (more evidence wins);
#      a candidate never wins (it is not admitted to real repair);
#      a preferred with 0/10 loses to a verified tool with a good record.
#   2. Fallback: a high-scored tool with no implementation is skipped
#      and the next implemented tool wins — it must not block repair.
#   3. verify_hypothesis: a hypothesis whose first-mentioned symptom
#      (the claimed cause) was not broken is UNKNOWN, even if a broken
#      symptom also appears in the text.
#   4. apply_tool_evals: only tools that actually ran are applied.
#   5. filter_history_by_symptoms: the model's old prose (ANALYSIS:)
#      is stripped, only facts are passed on.
#   6. filter_hypotheses_by_symptoms: capped at 10 rows, refuted ones
#      excluded.
#   7. Lock: a stale lock (dead PID) is removed; a live lock skips.
#
# Usage: zsh tests/behavioral.sh   (exit 0 = all pass, exit 1 = failure)

set -u
ROOT="${0:A:h:h}"
WATCHER="$ROOT/watcher.sh"
TMP=$(mktemp -d /tmp/mac-watchdog-behavioral.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# --- Load the pure functions from watcher.sh (without running it). ---
export WATCHDOG_DIR="$TMP/wd" TOOLS="$TMP/tools.tsv" LOG="$TMP/watcher.log"
mkdir -p "$WATCHDOG_DIR" "$WATCHDOG_DIR/tools"
: > "$LOG"
for _fn in select_tool_for_symptom tool_is_implemented verify_hypothesis \
           apply_tool_evals filter_history_by_symptoms \
           filter_hypotheses_by_symptoms record_tool_run; do
  _src=$(sed -n "/^$_fn()/,/^}/p" "$WATCHER")
  [ -n "$_src" ] || { echo "FAIL: function $_fn not found in watcher.sh"; exit 1; }
  eval "$_src"
done

# --- 1. Ranking. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tool-a\ttool-a\tpreferred\t20\t19\t20\ttailscale\n' >> "$TOOLS"
printf 'tool-b\ttool-b\tverified\t5\t5\t5\ttailscale\n' >> "$TOOLS"
printf 'tool-c\ttool-c\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
printf 'tool-d\ttool-d\tpreferred\t10\t0\t10\ttailscale\n' >> "$TOOLS"
_ranked=$(select_tool_for_symptom tailscale)
_first=$(echo "$_ranked" | head -1)
check "ranking: 19/20 beats 5/5" "tool-a" "$_first"
echo "$_ranked" | grep -q "tool-c" && fail "ranking: candidate is listed" || pass "ranking: candidate excluded"
_last=$(echo "$_ranked" | tail -1)
check "ranking: 0/10 preferred is last" "tool-d" "$_last"

# --- 2. Fallback to an implemented tool. ---
# tool-a is top-ranked but has no implementation (not a builtin, no script).
# tool-b is verified but also has no script. tailscale-up is a builtin.
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'ghost\tghost\tpreferred\t20\t19\t20\ttailscale\n' >> "$TOOLS"
printf 'tailscale-up\ttailscale-up\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
_first_impl=""
for _c in $(select_tool_for_symptom tailscale); do
  if tool_is_implemented "$_c"; then _first_impl="$_c"; break; fi
done
check "fallback: first implemented tool wins" "tailscale-up" "$_first_impl"
tool_is_implemented ghost && fail "fallback: ghost is implemented" || pass "fallback: ghost is not implemented"
tool_is_implemented tailscale-up && pass "fallback: builtin is implemented" || fail "fallback: builtin is not implemented"

# --- 3. verify_hypothesis: first-mentioned symptom is the claimed cause. ---
_out=$(verify_hypothesis "HYPOTHESIS: DNS failure caused the Tailscale shutdown | CONFIDENCE: PATTERN | REFUTES: none" "tailscale" | head -1)
check "verify: DNS-as-cause for tailscale-only is UNKNOWN" "HYPOTHESIS: UNKNOWN | CONFIDENCE: HYPOTHESIS | REFUTES: none" "$_out"
_out=$(verify_hypothesis "HYPOTHESIS: Tailscale service stopped responding | CONFIDENCE: HYPOTHESIS | REFUTES: none" "tailscale" | head -1)
check "verify: Tailscale-as-cause for tailscale passes" "HYPOTHESIS: Tailscale service stopped responding | CONFIDENCE: HYPOTHESIS | REFUTES: none" "$_out"
_out=$(verify_hypothesis "HYPOTHESIS: DNS servers unreachable after wake | CONFIDENCE: HYPOTHESIS | REFUTES: none" "dns" | head -1)
check "verify: DNS-as-cause for dns passes" "HYPOTHESIS: DNS servers unreachable after wake | CONFIDENCE: HYPOTHESIS | REFUTES: none" "$_out"

# --- 4. apply_tool_evals: only tools that ran. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tailscale-up\ttailscale-up\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
printf 'dns-reset\tdns-reset\tverified\t2\t2\t2\tdns\n' >> "$TOOLS"
apply_tool_evals "TOOL-EVAL: tailscale-up | preferred | fast and consistent
TOOL-EVAL: dns-reset | verified | temporary fix" "tailscale-up"
_state=$(awk -F'\t' '$1=="dns-reset"{print $3}' "$TOOLS")
check "tool-eval: dns-reset not re-applied (did not run)" "verified" "$_state"
grep -q "did not run in this incident" "$LOG" && pass "tool-eval: skip is logged" || fail "tool-eval: skip is not logged"

# --- 5. History: the model's old prose is stripped. ---
cat > "$TMP/inc.log" <<'EOF'
=== 2026-11-24 00:40:00 INCIDENT ===
SYMPTOMS: tailscale
REFLEXES: tailscale-up (rc=0)
OUTCOME: FIXED-BY-REFLEX
ANALYSIS: The model once thought this was DNS. Old prose, must not be shown again.
CAUSE: HYPOTHESIS: Transient state inconsistency in Tailscale service | CONFIDENCE: HYPOTHESIS | REFUTES: none
=== 2026-11-24 00:44:00 INCIDENT ===
SYMPTOMS: dns
REFLEXES: dns-reset (rc=0)
OUTCOME: FIXED-BY-REFLEX
ANALYSIS: DNS was broken.
CAUSE: HYPOTHESIS: DNS fails after Mac wakes | CONFIDENCE: PATTERN | REFUTES: none
EOF
_hist=$(filter_history_by_symptoms "$TMP/inc.log" "tailscale" 80)
echo "$_hist" | grep -q "ANALYSIS:" && fail "history: ANALYSIS prose leaked" || pass "history: ANALYSIS prose stripped"
echo "$_hist" | grep -q "SYMPTOMS: tailscale" && pass "history: tailscale block kept" || fail "history: tailscale block missing"
echo "$_hist" | grep -q "SYMPTOMS: dns" && fail "history: dns block leaked" || pass "history: dns block filtered out"

# --- 6. Hypotheses: capped at 10, refuted excluded. ---
printf 'id\tfirst_seen\tlast_seen\toccurrences\trefutations\tconfidence\tstatus\ttext\tevidence\n' > "$TMP/hyp.tsv"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf "H$i\t2026-11-24 00:00:0$i\t2026-11-24 00:00:0$i\t1\t0\tHYPOTHESIS\tactive\tHypothesis $i about tailscale\t2026-11-24:tailscale\n" >> "$TMP/hyp.tsv"
done
printf 'H99\t2026-11-20 00:00:00\t2026-11-20 00:00:00\t5\t3\tPATTERN\trefuted\tRetired hypothesis about tailscale\t2026-11-20:dns\n' >> "$TMP/hyp.tsv"
_rows=$(filter_hypotheses_by_symptoms "$TMP/hyp.tsv" "tailscale" | tail -n +2 | wc -l | tr -d ' ')
check "hypotheses: capped at 10 rows" "10" "$_rows"
filter_hypotheses_by_symptoms "$TMP/hyp.tsv" "tailscale" | grep -q "H99" && fail "hypotheses: refuted row leaked" || pass "hypotheses: refuted row excluded"

# --- 7. Lock: stale is removed, live skips. ---
# acquire_lock is now a function, so the test calls it directly.
for _fn in acquire_lock; do
  _src=$(sed -n "/^$_fn()/,/^}/p" "$WATCHER")
  [ -n "$_src" ] || { echo "FAIL: function $_fn not found in watcher.sh"; exit 1; }
  eval "$_src"
done
LOCK="$TMP/watcher.lock"
# Stale: dead PID, old file.
echo "999999" > "$LOCK"
touch -t 202001010000 "$LOCK" 2>/dev/null || touch -d "2020-01-01" "$LOCK" 2>/dev/null
if acquire_lock; then
  pass "lock: stale lock removed and acquired"
  rm -f "$LOCK"; trap - EXIT
else
  fail "lock: stale lock blocked the run"
fi
# Live: a lock held by a running watcher process. Start a background
# zsh that holds the lock file with its own PID and sleeps, then check
# that acquire_lock refuses.
( echo $$ > "$LOCK"; sleep 5 ) &
_bg=$!
sleep 0.5
# Rewrite the lock with the background shell's PID (it is a zsh, and
# its command line contains the test script name, not "watcher" — so
# the PID-reuse check would treat it as stale. To test the live path
# properly, use a fake watcher process instead: a sleep whose args
# contain "watcher".
kill $_bg 2>/dev/null; wait $_bg 2>/dev/null
zsh -c 'echo $$ > "'"$LOCK"'"; exec -a watcher.sh sleep 5' &
_bg2=$!
sleep 0.5
if acquire_lock; then
  fail "lock: live lock did not block the run"
  rm -f "$LOCK"; trap - EXIT
else
  pass "lock: live lock skips the run"
fi
kill $_bg2 2>/dev/null; wait $_bg2 2>/dev/null; rm -f "$LOCK"

if [ "$FAIL" -eq 0 ]; then echo "ALL BEHAVIORAL TESTS PASSED"; exit 0; else echo "BEHAVIORAL TESTS FAILED"; exit 1; fi
