#!/bin/zsh
# install.sh — install Mac Watchdog Server Resurrection on this Mac.
#
# Usage:
#   ./install.sh [--dir /path/to/install] [--no-secrets] [--no-agents]
#                [--with-call-home]
#
# Default install dir is ~/watchdog. The script is idempotent: re-running
# it is safe. It will NOT overwrite an existing watchdog.conf or a
# secrets store without asking, and it re-applies the chflags uchg
# protection after copying (removing the flag first so the copy succeeds).
#
# The permanent call-home tunnel agent is NOT installed by default. By
# default, the Watcher opens a one-shot outbound tunnel only when it
# gives up after 3 failed repair attempts. Pass --with-call-home to also
# install a permanent tunnel agent (KeepAlive) that keeps the machine
# reachable at all times. See README.md, "Plan B".
#
# This repo contains NO binaries. recovery-agent is built from the Swift
# source in src/recovery-agent/ on this machine (swift build -c release,
# relative paths only). Full Xcode is required: the agent uses Foundation
# Models macros (@Generable, @Guide), whose compiler plugin ships only
# with Xcode from the App Store, not with Command Line Tools alone.
#
# What it does:
#   1. Checks macOS + Apple Silicon + Apple Intelligence (best effort).
#   2. Builds recovery-agent from source (src/recovery-agent/).
#   3. Copies the watchdog files and the built binary to the install dir
#      and to the backup dir.
#   4. Creates watchdog.conf from the example (auto-detecting the values
#      it can) and fills the blueprint placeholders from it.
#   5. Installs and loads the three LaunchAgents.
#   6. Runs scripts/setup-secrets.sh (unless --no-secrets).

set -u
SRC_DIR="${0:A:h}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/watchdog}"
SUPPORT_DIR="$HOME/Library/Application Support/MacWatchdog"
DO_SECRETS=1
DO_AGENTS=1
DO_CALL_HOME=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --no-secrets) DO_SECRETS=0; shift ;;
    --no-agents) DO_AGENTS=0; shift ;;
    --with-call-home) DO_CALL_HOME=1; shift ;;
    -h|--help)
      echo "usage: $0 [--dir /path/to/install] [--no-secrets] [--no-agents] [--with-call-home]"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Escape a string for use as a sed replacement (delimiter |).
sed_escape() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Run a command with a hard timeout (seconds). macOS has no `timeout`.
run_to() {
  local secs="$1"; shift
  "$@" > /tmp/mac-watchdog-install.out 2>&1 &
  local pid=$!
  local i=0
  while kill -0 $pid 2>/dev/null; do
    if [ "$i" -ge "$secs" ]; then kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; return 124; fi
    sleep 1; i=$((i + 1))
  done
  wait $pid 2>/dev/null
  return $?
}

echo "Mac Watchdog Server Resurrection — installer"
echo "Install dir: $INSTALL_DIR"
echo

# --- 1. Preflight checks ---
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this installer only runs on macOS." >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "WARNING: Apple Intelligence requires Apple Silicon. This machine ($(uname -m)) may not run the local model." >&2
fi
_os_ver=$(sw_vers -productVersion 2>/dev/null)
_os_major=${_os_ver%%.*}
if [ "${_os_major:-0}" -lt 26 ]; then
  echo "WARNING: macOS $_os_ver detected. The Foundation Models framework for third-party apps needs macOS 26+. The Watcher may not work until you upgrade." >&2
fi
if [ ! -d /System/Library/Frameworks/FoundationModels.framework ]; then
  echo "WARNING: FoundationModels.framework not found. Apple Intelligence may not be available on this Mac." >&2
else
  echo "Foundation Models framework: present (macOS $_os_ver)"
fi
# --- 1b. Get recovery-agent: prebuilt binary (from a GitHub Release) or build from source ---
# The repo contains NO binaries. Two ways to get the agent:
#   A. Place a prebuilt `recovery-agent` next to install.sh (downloaded from
#      the Releases page) — the installer uses it as-is, no Xcode needed.
#      A download (curl, browser) may arrive without the executable bit;
#      the installer sets it, so a non-executable file is not mistaken
#      for a missing one.
#   B. Otherwise, build it from the Swift source in src/recovery-agent/.
#      The agent uses Foundation Models macros (@Generable, @Guide), whose
#      compiler plugin ships only with full Xcode — Command Line Tools alone
#      is NOT enough.
if [ -f "$SRC_DIR/recovery-agent" ]; then
  chmod +x "$SRC_DIR/recovery-agent" 2>/dev/null || true
  BUILT_AGENT="$SRC_DIR/recovery-agent"
  echo "Using prebuilt recovery-agent next to install.sh (no build needed)."
elif ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: Swift toolchain not found and no prebuilt recovery-agent next to install.sh." >&2
  echo "Either install full Xcode from the App Store, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  echo "or download the prebuilt binary from the Releases page and place it" >&2
  echo "next to install.sh, then re-run ./install.sh." >&2
  exit 1
elif ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: full Xcode is required to build recovery-agent (not just Command Line Tools)," >&2
  echo "and no prebuilt recovery-agent was found next to install.sh." >&2
  echo "The agent uses Foundation Models macros (@Generable, @Guide), whose compiler plugin" >&2
  echo "ships only with Xcode from the App Store. Install Xcode, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  echo "or download the prebuilt binary from the Releases page and place it" >&2
  echo "next to install.sh, then re-run ./install.sh." >&2
  exit 1
else
  echo "Xcode: $(xcodebuild -version | head -1)"
  echo "Building recovery-agent from source (src/recovery-agent/)..."
  if ! (cd "$SRC_DIR/src/recovery-agent" && swift build -c release); then
    echo "ERROR: failed to build recovery-agent from source." >&2
    echo "Make sure full Xcode is installed and selected (sudo xcode-select -s /Applications/Xcode.app)," >&2
    echo "then re-run ./install.sh. The build output is above." >&2
    exit 1
  fi
  BUILT_AGENT="$SRC_DIR/src/recovery-agent/.build/release/recovery-agent"
  if [ ! -x "$BUILT_AGENT" ]; then
    echo "ERROR: build finished but no binary at $BUILT_AGENT — unexpected. Aborting." >&2
    exit 1
  fi
  echo "recovery-agent built: $BUILT_AGENT"
fi
# Best-effort model check via the agent's selftest.
if run_to 30 "$BUILT_AGENT" selftest >/dev/null 2>&1; then
  echo "Local model selftest: OK"
else
  echo "WARNING: the local model selftest did not pass (rc=$?). The model may not be downloaded yet — enable Apple Intelligence in System Settings and let it download, then re-run this installer." >&2
fi
echo

# --- 2. Directories ---
# BACKUP_DIR lives under SUPPORT_DIR (outside the watchdog dir), so a
# wipe of ~/watchdog/ cannot take the backup with it. The bootstrap
# script itself also lives in SUPPORT_DIR for the same reason (see
# watchdog-bootstrap.sh) — the LaunchAgent runs that copy.
BACKUP_DIR="$SUPPORT_DIR/backup"
mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/scripts" "$INSTALL_DIR/tools" "$BACKUP_DIR/lib" "$BACKUP_DIR/scripts" "$BACKUP_DIR/launchagents" "$SUPPORT_DIR" 2>/dev/null

# Remove the immutable flag from existing files so the copy can overwrite
# them (re-applied at the end). Ignore errors (files may not exist yet).
chflags -R nouchg "$INSTALL_DIR" 2>/dev/null || true
chflags -R nouchg "$BACKUP_DIR" 2>/dev/null || true

# --- 3. Copy source files ---
for f in watcher.sh blueprint.md reasoning.py click-allow.sh call-home.sh call-home-loop.sh watchdog-bootstrap.sh observer.sh review.sh watchdog.conf.example watchdog.gitignore; do
  cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
  cp "$SRC_DIR/$f" "$BACKUP_DIR/$f"
done
# The installed watchdog directory is the evolution layer: version it.
# Every change to it is a Git commit with a justification, so a bad
# change can be reverted. Logs and the live config are ignored.
if command -v git >/dev/null 2>&1; then
  cp "$SRC_DIR/watchdog.gitignore" "$INSTALL_DIR/.gitignore"
  (cd "$INSTALL_DIR" && git init -q 2>/dev/null && git add -A 2>/dev/null \
    && git -c user.name="Mac Watchdog" -c user.email="watchdog@localhost" \
       commit -qm "Initial watchdog installation" 2>/dev/null) || true
fi
# The built recovery-agent binary (from the source build above).
cp "$BUILT_AGENT" "$INSTALL_DIR/recovery-agent"
cp "$BUILT_AGENT" "$BACKUP_DIR/recovery-agent"
cp "$SRC_DIR/lib/get-secret.sh" "$INSTALL_DIR/lib/get-secret.sh"
cp "$SRC_DIR/lib/get-secret.sh" "$BACKUP_DIR/lib/get-secret.sh"
cp "$SRC_DIR/scripts/setup-secrets.sh" "$INSTALL_DIR/scripts/setup-secrets.sh"
cp "$SRC_DIR/scripts/setup-secrets.sh" "$BACKUP_DIR/scripts/setup-secrets.sh"
# The bootstrap script lives in SUPPORT_DIR (outside the watchdog dir)
# so it survives a wipe of the watchdog dir itself. A copy also stays
# in the watchdog dir and the backup for reference.
cp "$SRC_DIR/watchdog-bootstrap.sh" "$SUPPORT_DIR/watchdog-bootstrap.sh"
cp "$SRC_DIR/watchdog-bootstrap.sh" "$BACKUP_DIR/watchdog-bootstrap.sh"
# The bootstrap finds its config at $WATCHDOG_DIR/watchdog.conf, and
# its default WATCHDOG_DIR is $HOME/watchdog. For a custom --dir
# install that default is wrong: the config lives in the install dir,
# so the bootstrap would never find it and would restore to the wrong
# place. Patch the default in the installed copies to the real dir.
_wd_esc=$(sed_escape "$INSTALL_DIR")
sed -i '' "s|^WATCHDOG_DIR=\"\$HOME/watchdog\"|WATCHDOG_DIR=\"$_wd_esc\"|" "$SUPPORT_DIR/watchdog-bootstrap.sh" "$BACKUP_DIR/watchdog-bootstrap.sh" 2>/dev/null
chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/lib/*.sh "$INSTALL_DIR"/scripts/*.sh "$INSTALL_DIR/recovery-agent" "$SUPPORT_DIR/watchdog-bootstrap.sh" 2>/dev/null
chmod +x "$BACKUP_DIR"/*.sh "$BACKUP_DIR"/lib/*.sh "$BACKUP_DIR"/scripts/*.sh "$BACKUP_DIR/recovery-agent" 2>/dev/null
echo "Files copied to $INSTALL_DIR and to the backup dir."

# --- 4. Config: create from the example if missing, never overwrite ---
CONF="$INSTALL_DIR/watchdog.conf"
if [ -f "$CONF" ]; then
  echo "watchdog.conf already exists — leaving it untouched."
else
  cp "$SRC_DIR/watchdog.conf.example" "$CONF"
  # Point the config at the real install dir.
  _wd_esc=$(sed_escape "$INSTALL_DIR")
  sed -i '' "s|^WATCHDOG_DIR=.*|WATCHDOG_DIR=\"$_wd_esc\"|" "$CONF"
  # Auto-detect what we can (best effort; the user reviews the file).
  _ts_cli="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  if [ -x "$_ts_cli" ]; then
    _hn=$("$_ts_cli" status 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$_hn" ]; then
      sed -i '' "s|^TAILSCALE_HOSTNAME=.*|TAILSCALE_HOSTNAME=\"$(sed_escape "$_hn")\"|" "$CONF"
      echo "Auto-detected Tailscale hostname: $_hn"
    fi
  fi
  _gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  if [ -n "$_gw" ]; then
    sed -i '' "s|^EXPECTED_GATEWAY=.*|EXPECTED_GATEWAY=\"$(sed_escape "$_gw")\"|" "$CONF"
    echo "Auto-detected default gateway: $_gw"
  fi
  _iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  if [ -n "$_iface" ]; then
    sed -i '' "s|^WIFI_INTERFACE=.*|WIFI_INTERFACE=\"$(sed_escape "$_iface")\"|" "$CONF"
    echo "Auto-detected network interface: $_iface"
  fi
  echo "Created $CONF — please review it (especially RENDEZVOUS_HOST and RENDEZVOUS_PORT)."
fi
# The backup gets the real config (not the example).
cp "$CONF" "$BACKUP_DIR/watchdog.conf"

# Load the config so the blueprint and plists can use its values.
# shellcheck disable=SC1090
source "$CONF"
WATCHDOG_DIR="${WATCHDOG_DIR:-$INSTALL_DIR}"

# --- 5. Fill the blueprint placeholders from the config ---
_bp="$INSTALL_DIR/blueprint.md"
if grep -q "<YOUR_\|<WATCHDOG_DIR>\|<TAILSCALE_CLI>" "$_bp" 2>/dev/null; then
  _hn_esc=$(sed_escape "${TAILSCALE_HOSTNAME:-mac-mini}")
  _gw_esc=$(sed_escape "${EXPECTED_GATEWAY:-any}")
  _iface_esc=$(sed_escape "${WIFI_INTERFACE:-en1}")
  _wd_esc=$(sed_escape "$WATCHDOG_DIR")
  _ts_esc=$(sed_escape "${TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}")
  sed -i '' \
    -e "s|<YOUR_TAILSCALE_HOSTNAME>|$_hn_esc|g" \
    -e "s|<YOUR_GATEWAY>|$_gw_esc|g" \
    -e "s|<YOUR_WIFI_INTERFACE>|$_iface_esc|g" \
    -e "s|<WATCHDOG_DIR>|$_wd_esc|g" \
    -e "s|<TAILSCALE_CLI>|$_ts_esc|g" \
    "$_bp"
  cp "$_bp" "$BACKUP_DIR/blueprint.md"
  echo "Blueprint placeholders filled from watchdog.conf."
else
  echo "Blueprint already filled in — leaving it untouched."
fi

# --- 6. Protect the source files (NOT the config, NOT the logs) ---
# chflags uchg = user immutable: the files resist accidental deletion or
# modification, including by the model (which has a terminal and sudo).
# This is a speed bump, not a guarantee: the owner or root can remove
# the flag with `chflags nouchg`. Logs stay writable.
for d in "$INSTALL_DIR" "$BACKUP_DIR"; do
  chflags uchg "$d/watcher.sh" "$d/blueprint.md" "$d/recovery-agent" "$d/reasoning.py" "$d/click-allow.sh" "$d/call-home.sh" "$d/call-home-loop.sh" "$d/watchdog-bootstrap.sh" "$d/observer.sh" "$d/review.sh" "$d/lib/get-secret.sh" "$d/scripts/setup-secrets.sh" 2>/dev/null || true
done
chflags uchg "$SUPPORT_DIR/watchdog-bootstrap.sh" 2>/dev/null || true
echo "Source files marked chflags uchg (immutable). Config and logs stay writable."
echo "To update a source file later: chflags nouchg <file>, edit, chflags uchg <file>."

# --- 7. LaunchAgents ---
# The watcher and bootstrap agents always install. The call-home agent
# (permanent outbound tunnel) installs only with --with-call-home; by
# default the Watcher opens a one-shot tunnel only when it gives up.
if [ "$DO_AGENTS" -eq 1 ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  _uid=$(id -u)
  _ci="${CHECK_INTERVAL:-300}"
  _wd_esc=$(sed_escape "$WATCHDOG_DIR")
  _sup_esc=$(sed_escape "$SUPPORT_DIR")
  _agents=(watcher bootstrap observer review)
  if [ "$DO_CALL_HOME" -eq 1 ]; then
    _agents+=(call-home)
  fi
  for p in "${_agents[@]}"; do
    _tmpl="$SRC_DIR/com.macwatchdog.$p.plist"
    _dst="$HOME/Library/LaunchAgents/com.macwatchdog.$p.plist"
    sed -e "s|__WATCHDOG_DIR__|$_wd_esc|g" \
        -e "s|__SUPPORT_DIR__|$_sup_esc|g" \
        -e "s|__CHECK_INTERVAL__|$_ci|g" \
        "$_tmpl" > "$_dst"
    cp "$_dst" "$BACKUP_DIR/launchagents/com.macwatchdog.$p.plist"
    _out=$(launchctl bootstrap "gui/$_uid" "$_dst" 2>&1) || true
    if echo "$_out" | grep -qi "already"; then
      echo "LaunchAgent com.macwatchdog.$p: already loaded."
    elif [ -n "$_out" ]; then
      echo "LaunchAgent com.macwatchdog.$p: bootstrap said: $_out" >&2
    else
      echo "LaunchAgent com.macwatchdog.$p: loaded."
    fi
  done
  if [ "$DO_CALL_HOME" -eq 0 ]; then
    echo "Call-home agent NOT installed (default). The Watcher still opens a one-shot tunnel when it gives up. Re-run with --with-call-home for a permanent tunnel."
  fi
else
  echo "Skipping LaunchAgent install (--no-agents)."
fi
echo

# --- 8. Secrets ---
if [ "$DO_SECRETS" -eq 1 ]; then
  printf "Run the secrets setup now? (stores the sudo password and the Tailscale auth key) [Y/n]: "
  read -r _ans
  case "$_ans" in
    n|N|no|NO) echo "Skipped. Run $INSTALL_DIR/scripts/setup-secrets.sh later — without the auth key the Watcher cannot re-login Tailscale on its own." ;;
    *) /bin/zsh "$INSTALL_DIR/scripts/setup-secrets.sh" ;;
  esac
else
  echo "Skipping secrets setup (--no-secrets). Run $INSTALL_DIR/scripts/setup-secrets.sh later."
fi
echo

# --- 9. Summary ---
echo "Installed. Summary:"
echo "  Watchdog dir: $INSTALL_DIR"
echo "  Backup dir:   $BACKUP_DIR"
echo "  Config:       $CONF"
echo "  Logs:         $INSTALL_DIR/watcher.log, $INSTALL_DIR/bootstrap.log, $INSTALL_DIR/call-home.log"
echo "  Incidents:    $INSTALL_DIR/incidents.log (problem, cause, fix, outcome)"
echo "  Events:       $INSTALL_DIR/events.log (state every minute, for the analyst)"
echo "  Reasoning:    $INSTALL_DIR/last-reasoning.txt (updated after every run)"
echo
echo "Next steps:"
echo "  1. Review $CONF (rendezvous host/port, Tailscale hostname)."
echo "  2. If you skipped secrets, run: /bin/zsh $INSTALL_DIR/scripts/setup-secrets.sh"
echo "  3. Test it: turn Wi-Fi off, break DNS, or run 'tailscale logout' —"
echo "     the Watcher should repair it within ~5 minutes. Watch the log:"
echo "     tail -f $INSTALL_DIR/watcher.log"
echo "  4. Re-run this installer any time to repair or update the install."
