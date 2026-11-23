#!/bin/zsh
# watchdog-bootstrap.sh: self-healing for the watchdog install directory.
# If any essential file is missing (deleted, wiped, corrupted), restore it
# from the backup directory. Also restores the LaunchAgent plists if they
# were removed from ~/Library/LaunchAgents/ and reloads them.
# Run by LaunchAgent com.macwatchdog.bootstrap every 5 min and at load.
#
# This exists because a watchdog directory was once found wiped with no
# human action and no trace. The cause was never established, so the system
# must be able to rebuild itself from a separate copy.
#
# Configuration: watchdog.conf in the same directory as this script.
# If the config itself is missing, built-in defaults are used (this script
# must work even when the config is gone — that is its whole purpose).

# This script lives OUTSIDE the watchdog dir (in ~/Library/Application
# Support/MacWatchdog/), so it survives a wipe of ~/watchdog/ itself.
# A copy also lives in ~/watchdog/ for reference, but the LaunchAgent
# runs the support-dir copy. The paths below are therefore fixed, not
# derived from the script's own location — the script must work no
# matter where it is run from.
SUPPORT_DIR="$HOME/Library/Application Support/MacWatchdog"
WATCHDOG_DIR="$HOME/watchdog"
BACKUP_DIR="$SUPPORT_DIR/backup"
CONF="$WATCHDOG_DIR/watchdog.conf"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  source "$CONF"
  WATCHDOG_DIR="${WATCHDOG_DIR:-$HOME/watchdog}"
  BACKUP_DIR="${BACKUP_DIR:-$SUPPORT_DIR/backup}"
fi
LOG="$WATCHDOG_DIR/bootstrap.log"
mkdir -p "$WATCHDOG_DIR" 2>/dev/null

# Files restored to the watchdog dir. Secrets are NOT here: they live in
# the macOS Keychain or in ~/.config/mac-watchdog/secrets (see
# lib/get-secret.sh), outside the watchdog dir, so a wipe cannot take them.
# NOTE: these are zsh arrays, not strings. In zsh, `for f in $FILES`
# does NOT split a string on whitespace (unlike bash), so a plain string
# would make the loop see one long name instead of many files and the
# restore would silently do nothing. Always use "${FILES[@]}".
FILES=(watcher.sh blueprint.md recovery-agent reasoning.py click-allow.sh call-home.sh call-home-loop.sh watchdog.conf observer.sh review.sh lib/get-secret.sh scripts/setup-secrets.sh)
# Source files get the user-immutable flag after restore (logs and the
# config stay writable so the user can edit the config and the Watcher
# can write logs).
PROTECTED="watcher.sh blueprint.md recovery-agent reasoning.py click-allow.sh call-home.sh call-home-loop.sh lib/get-secret.sh scripts/setup-secrets.sh"

restored=0
for f in "${FILES[@]}"; do
  if [ ! -e "$WATCHDOG_DIR/$f" ]; then
    if [ -e "$BACKUP_DIR/$f" ]; then
      mkdir -p "$WATCHDOG_DIR/$(dirname "$f")" 2>/dev/null
      cp -p "$BACKUP_DIR/$f" "$WATCHDOG_DIR/$f" 2>/dev/null
      case " $PROTECTED " in
        *" $f "*) chflags uchg "$WATCHDOG_DIR/$f" 2>/dev/null ;;
      esac
      case "$f" in
        *.sh|recovery-agent) chmod +x "$WATCHDOG_DIR/$f" 2>/dev/null ;;
      esac
      echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORED $f from backup" >> "$LOG"
      restored=1
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') MISSING $f (no backup copy)" >> "$LOG"
    fi
  fi
done

# LaunchAgent plists: restore to ~/Library/LaunchAgents/ if missing, then
# load them (best effort). The bootstrap's own plist cannot reload itself
# if it was removed — restoring the file is still useful; a reboot or a
# manual `launchctl bootstrap` brings it back.
PLISTS=(com.macwatchdog.watcher.plist com.macwatchdog.bootstrap.plist com.macwatchdog.observer.plist com.macwatchdog.review.plist com.macwatchdog.call-home.plist)
for p in "${PLISTS[@]}"; do
  if [ ! -e "$HOME/Library/LaunchAgents/$p" ] && [ -e "$BACKUP_DIR/launchagents/$p" ]; then
    cp -p "$BACKUP_DIR/launchagents/$p" "$HOME/Library/LaunchAgents/$p" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORED $p to LaunchAgents" >> "$LOG"
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$p" 2>> "$LOG" || true
    restored=1
  fi
done

if [ "$restored" -eq 1 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog restored; Watcher picks it up on next tick" >> "$LOG"
fi
exit 0
