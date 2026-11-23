#!/bin/zsh
# uninstall.sh — remove Mac Watchdog Server Resurrection from this Mac.
#
# Usage:
#   ./uninstall.sh [--dir /path/to/install] [--yes]
#
# What it does:
#   1. Unloads and removes all three LaunchAgents (watcher, bootstrap,
#      call-home) from ~/Library/LaunchAgents/.
#   2. Removes the chflags uchg protection from the installed files.
#   3. Deletes the install dir (default ~/watchdog), the backup dir and
#      the support dir (~/Library/Application Support/MacWatchdog).
#
# What it does NOT delete (remove yourself if you want them gone):
#   - Secrets in the Keychain (service mac-watchdog) or in
#     ~/.config/mac-watchdog/secrets — see docs/security.md.
#   - The Tailscale auth key itself — revoke it at
#     https://login.tailscale.com/admin/settings/keys if unneeded.
#   - The rendezvous host's ~/.ssh/authorized_keys entry for the
#     call-home key.
#
# Without --yes it asks for confirmation first.

set -u
INSTALL_DIR="${INSTALL_DIR:-$HOME/watchdog}"
SUPPORT_DIR="$HOME/Library/Application Support/MacWatchdog"
BACKUP_DIR="$SUPPORT_DIR/backup"
AUTO=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --yes) AUTO=1; shift ;;
    -h|--help)
      echo "usage: $0 [--dir /path/to/install] [--yes]"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "Mac Watchdog Server Resurrection — uninstaller"
echo "This will remove:"
echo "  LaunchAgents: com.macwatchdog.{watcher,bootstrap,call-home}"
echo "  Install dir:  $INSTALL_DIR"
echo "  Support dir:  $SUPPORT_DIR (includes the backup)"
echo "Secrets in the Keychain and ~/.config/mac-watchdog/secrets are NOT removed (see docs/security.md)."
echo

if [ "$AUTO" -eq 0 ]; then
  printf "Continue? [y/N]: "
  read -r _ans
  case "$_ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

_uid=$(id -u)
for p in watcher bootstrap call-home; do
  _plist="$HOME/Library/LaunchAgents/com.macwatchdog.$p.plist"
  launchctl bootout "gui/$_uid" "$_plist" 2>/dev/null || true
  rm -f "$_plist" 2>/dev/null
  echo "LaunchAgent com.macwatchdog.$p: removed."
done

# Remove the immutable flag so the delete can succeed.
chflags -R nouchg "$INSTALL_DIR" 2>/dev/null || true
chflags -R nouchg "$SUPPORT_DIR" 2>/dev/null || true

rm -rf "$INSTALL_DIR" 2>/dev/null
rm -rf "$SUPPORT_DIR" 2>/dev/null
echo "Deleted $INSTALL_DIR and $SUPPORT_DIR."
echo
echo "Done. If you used the Keychain, remove the secrets there (service mac-watchdog) — see docs/security.md."
