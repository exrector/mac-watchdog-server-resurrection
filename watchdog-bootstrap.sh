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
# Memory files: the system's accumulated experience (incident history,
# hypothesis table, tool registry and per-attempt log). They are NOT
# code, so they are not in PROTECTED and stay writable. Without them a
# wipe restores the executables but loses everything the system learned
# — its memory, statistics and priorities. The backup step below keeps
# the backup copies current, so a restore brings back the latest state.
MEMORY_FILES=(incidents.log hypotheses.tsv tools.tsv tool-attempts.log tools-manifest.tsv tools-cooldown.tsv)
# The tool library: the executable scripts in tools/ are part of the
# system's memory, not just its code. A candidate proposed by the
# reviewer lives only here — the registry (tools.tsv) without the
# scripts is a catalogue of tools that no longer exist. The library is
# backed up as a whole, and on restore each script is verified against
# the manifest (tools-manifest.tsv) by checksum.
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

# Memory files: keep the backup current, then restore if missing.
# The backup is refreshed whenever the live copy is newer (or the
# backup is missing), so a wipe restores the latest learned state, not
# an install-time snapshot. A one-time backup at install would be
# stale within a day; this runs every 5 minutes with the bootstrap.
mkdir -p "$BACKUP_DIR" 2>/dev/null
for f in "${MEMORY_FILES[@]}"; do
  if [ -f "$WATCHDOG_DIR/$f" ]; then
    if [ ! -f "$BACKUP_DIR/$f" ] || [ "$WATCHDOG_DIR/$f" -nt "$BACKUP_DIR/$f" ]; then
      cp -p "$WATCHDOG_DIR/$f" "$BACKUP_DIR/$f" 2>/dev/null
    fi
  fi
  if [ ! -e "$WATCHDOG_DIR/$f" ] && [ -e "$BACKUP_DIR/$f" ]; then
    cp -p "$BACKUP_DIR/$f" "$WATCHDOG_DIR/$f" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORED $f from backup" >> "$LOG"
    restored=1
  fi
done

# LaunchAgent plists: restore to ~/Library/LaunchAgents/ if missing, then
# load them (best effort). The bootstrap's own plist cannot reload itself
# if it was removed — restoring the file is still useful; a reboot or a
# manual `launchctl bootstrap` brings it back.
PLISTS=(com.macwatchdog.watcher.plist com.macwatchdog.bootstrap.plist com.macwatchdog.observer.plist com.macwatchdog.review.plist com.macwatchdog.call-home.plist)

# Tool library: back up the scripts in tools/ and restore them with a
# checksum verification against the manifest. The library is small (a
# handful of short scripts). Order matters:
#   1. Verify the live library against the manifest FIRST. A script
#      whose checksum does not match was changed after install — log it
#      loudly and remove its executable bit. A mismatched script is
#      never backed up and never executed.
#   2. Back up only verified scripts (and scripts with no manifest
#      entry, which predate the manifest or were added by hand).
#   3. Restore a missing live library from the backup, then verify it.
if [ -d "$WATCHDOG_DIR/tools" ] && [ -f "$WATCHDOG_DIR/tools-manifest.tsv" ]; then
  while IFS= read -r _mline; do
    case "$_mline" in
      id*) continue ;;
    esac
    _mid=$(echo "$_mline" | awk -F'\t' '{print $1}')
    _msha=$(echo "$_mline" | awk -F'\t' '{print $2}')
    [ -n "$_mid" ] || continue
    if [ -f "$WATCHDOG_DIR/tools/$_mid.sh" ]; then
      _got=$(shasum -a 256 "$WATCHDOG_DIR/tools/$_mid.sh" 2>/dev/null | awk '{print $1}')
      if [ "$_got" = "$_msha" ]; then
        chmod +x "$WATCHDOG_DIR/tools/$_mid.sh" 2>/dev/null
      else
        chmod -x "$WATCHDOG_DIR/tools/$_mid.sh" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') MANIFEST MISMATCH $_mid: script changed after install, not executable" >> "$LOG"
      fi
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') MANIFEST MISSING $_mid: registered but no script" >> "$LOG"
    fi
  done < "$WATCHDOG_DIR/tools-manifest.tsv"
fi
if [ -d "$WATCHDOG_DIR/tools" ]; then
  mkdir -p "$BACKUP_DIR/tools" 2>/dev/null
  _backed_up=0
  for _s in "$WATCHDOG_DIR/tools"/*.sh; do
    [ -f "$_s" ] || continue
    # Only verified scripts are backed up: a script that failed the
    # manifest check above is non-executable and must not pollute the
    # backup with a tampered copy.
    if [ ! -x "$_s" ] && [ -f "$WATCHDOG_DIR/tools-manifest.tsv" ] && awk -F'\t' -v id="$(basename "$_s" .sh)" '$1==id{found=1} END{exit !found}' "$WATCHDOG_DIR/tools-manifest.tsv" 2>/dev/null; then
      continue
    fi
    if [ ! -f "$BACKUP_DIR/tools/$(basename "$_s")" ] || ! cmp -s "$_s" "$BACKUP_DIR/tools/$(basename "$_s")"; then
      cp -p "$_s" "$BACKUP_DIR/tools/" 2>/dev/null
      _backed_up=1
    fi
  done
  if [ "$_backed_up" -eq 1 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') BACKED UP tools/ library" >> "$LOG"
  fi
fi
if [ ! -d "$WATCHDOG_DIR/tools" ] && [ -d "$BACKUP_DIR/tools" ]; then
  mkdir -p "$WATCHDOG_DIR/tools" 2>/dev/null
  cp -R "$BACKUP_DIR/tools/." "$WATCHDOG_DIR/tools/" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORED tools/ library from backup" >> "$LOG"
  restored=1
  # Verify what was just restored before it can run.
  if [ -f "$WATCHDOG_DIR/tools-manifest.tsv" ]; then
    while IFS= read -r _mline; do
      case "$_mline" in
        id*) continue ;;
      esac
      _mid=$(echo "$_mline" | awk -F'\t' '{print $1}')
      _msha=$(echo "$_mline" | awk -F'\t' '{print $2}')
      [ -n "$_mid" ] || continue
      if [ -f "$WATCHDOG_DIR/tools/$_mid.sh" ]; then
        _got=$(shasum -a 256 "$WATCHDOG_DIR/tools/$_mid.sh" 2>/dev/null | awk '{print $1}')
        if [ "$_got" = "$_msha" ]; then
          chmod +x "$WATCHDOG_DIR/tools/$_mid.sh" 2>/dev/null
        else
          chmod -x "$WATCHDOG_DIR/tools/$_mid.sh" 2>/dev/null
          echo "$(date '+%Y-%m-%d %H:%M:%S') MANIFEST MISMATCH $_mid: restored script does not match manifest, not executable" >> "$LOG"
        fi
      fi
    done < "$WATCHDOG_DIR/tools-manifest.tsv"
  fi
fi
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
