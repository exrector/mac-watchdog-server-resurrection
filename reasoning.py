#!/usr/bin/env python3
"""Extract the last completed Watcher run from watcher.log into last-reasoning.txt.
Shows, per step, the command, its exit code and a short outcome, plus the
model's ANSWER and the independent VERIFY verdict. No model internals exist
(the agent only logs TOOL>/RESULT>/ANSWER=), so this is the reasoning trace.

The watchdog directory is taken from the WATCHDOG_DIR environment variable
(set by watcher.sh) and falls back to ~/watchdog.
"""
import os
import re
from pathlib import Path

WATCHDOG = Path(os.environ.get("WATCHDOG_DIR", str(Path.home() / "watchdog")))
LOG = WATCHDOG / "watcher.log"
OUT = WATCHDOG / "last-reasoning.txt"

def main():
    if not LOG.exists():
        OUT.write_text("No watcher.log yet.\n")
        return
    text = LOG.read_text(errors="replace")
    # Split into runs delimited by WAKE ... DONE.
    runs = re.split(r"=== .*? WAKE ===", text)
    # Keep only runs that reached DONE.
    done = []
    for chunk in runs[1:]:
        if "DONE ===" in chunk:
            done.append(chunk)
    if not done:
        OUT.write_text("No completed run yet.\n")
        return
    last = done[-1]
    lines = []
    # Model tool calls: TOOL> ... RESULT> ... (agent logs these).
    tools = re.findall(r"TOOL>\s*(.*?)\nRESULT>\s*(.*?)(?=\nTOOL>|\nANSWER=|\n===|\Z)", last, re.S)
    for cmd, res in tools:
        cmd = " ".join(cmd.split())[:120]
        res = " ".join(res.split())[:200]
        lines.append(f"- {cmd}\n  -> {res}")
    # ANSWER block.
    m = re.search(r"ANSWER=\s*(.*?)(?=\n===|\nVERIFY|\nVERIFIED|\nSTILL|\nGAVE UP|\Z)", last, re.S)
    if m:
        ans = " ".join(m.group(1).split())[:600]
        lines.append(f"ANSWER: {ans}")
    # VERIFY lines and verdict.
    for v in re.findall(r"^VERIFY .*$", last, re.M):
        lines.append(v.strip()[:200])
    for v in re.findall(r"^(VERIFIED HEALTHY.*|STILL BROKEN.*|GAVE UP.*|MODEL TIMEOUT.*)$", last, re.M):
        lines.append(v.strip()[:200])
    if not lines:
        lines.append("(run had no tool calls, answer or verdict recorded)")
    OUT.write_text("\n".join(lines) + "\n")

if __name__ == "__main__":
    main()
