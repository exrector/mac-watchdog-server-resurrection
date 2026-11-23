#!/bin/zsh
# scripts/setup-secrets.sh — interactive setup for the Watchdog's secrets.
#
# Asks for two secrets and stores them:
#   sudo-password    — this Mac's login password (for sudo in repairs)
#   tailscale-authkey — a Tailscale auth key (tskey-auth-...), used by the
#                       model to re-login Tailscale if the node logs out.
#                       Create one at https://login.tailscale.com/admin/settings/keys
#
# Storage backends (you choose; Keychain is the default and recommended):
#   1. macOS Keychain — generic passwords, service "mac-watchdog"
#      (or $KEYCHAIN_SERVICE). The -T flags grant the listed programs
#      access without a GUI prompt.
#   2. Secrets file — $SECRETS_FILE (default ~/.config/mac-watchdog/secrets),
#      mode 600, KEY=VALUE lines. Use only if you cannot use the Keychain.
#
# This script NEVER prints a secret value to stdout or to a log.
# It is idempotent: re-running it updates the stored secrets.

SCRIPT_DIR="${0:A:h}"
# The config lives in the watchdog dir (parent of scripts/).
CONF="${WATCHDOG_CONF:-$SCRIPT_DIR/../watchdog.conf}"
if [ ! -f "$CONF" ]; then
  echo "watchdog.conf not found at $CONF. Run install.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

WATCHDOG_DIR="${WATCHDOG_DIR:-$SCRIPT_DIR/..}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-mac-watchdog}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.config/mac-watchdog/secrets}"

echo "macOS Watchdog — secrets setup"
echo "Secrets: sudo-password, tailscale-authkey"
echo

# --- Choose backend ---
backend="keychain"
echo "Where should the secrets be stored?"
echo "  1) macOS Keychain (recommended — the OS guards the values)"
echo "  2) Secrets file $SECRETS_FILE (mode 600, owner-only)"
printf "Choice [1/2, default 1]: "
read -r choice
case "$choice" in
  2) backend="file" ;;
  *) backend="keychain" ;;
esac
echo "Storing in: $backend"
echo

# --- Read a secret without echoing it. Never prints the value. ---
read_secret() {
  local prompt="$1" varname="$2" val=""
  printf '%s: ' "$prompt"
  IFS= read -rs val
  echo
  # Assign via indirect reference without echoing.
  eval "$varname=\$val"
  unset val
}

# --- Validate the sudo password (best effort). ---
validate_sudo() {
  local pw="$1"
  printf '%s\n' "$pw" | sudo -S -n true 2>/dev/null
}

store_keychain() {
  local name="$1" value="$2"
  security add-generic-password -U -a "$name" -s "$KEYCHAIN_SERVICE" -w "$value" \
    -T /bin/zsh -T /bin/sh -T /usr/bin/security -T "$WATCHDOG_DIR/recovery-agent" 2>/dev/null
}

store_file() {
  local name="$1" value="$2"
  mkdir -p "$(dirname "$SECRETS_FILE")" 2>/dev/null
  chmod 700 "$(dirname "$SECRETS_FILE")" 2>/dev/null
  touch "$SECRETS_FILE" 2>/dev/null
  chmod 600 "$SECRETS_FILE" 2>/dev/null
  # Replace the line if it exists, else append. Values are never echoed.
  if grep -qE "^${name}=" "$SECRETS_FILE" 2>/dev/null; then
    grep -vE "^${name}=" "$SECRETS_FILE" > "$SECRETS_FILE.tmp" 2>/dev/null \
      && mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"
  fi
  printf '%s=%s\n' "$name" "$value" >> "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE" 2>/dev/null
}

store_secret() {
  local name="$1" value="$2"
  if [ "$backend" = "keychain" ]; then
    if store_keychain "$name" "$value"; then
      echo "  stored '$name' in Keychain (service '$KEYCHAIN_SERVICE')"
    else
      echo "  WARNING: could not store '$name' in Keychain. Check Keychain Access." >&2
      return 1
    fi
  else
    store_file "$name" "$value"
    echo "  stored '$name' in $SECRETS_FILE (mode 600)"
  fi
  return 0
}

# --- sudo password ---
tries=0
sudo_pw=""
while [ "$tries" -lt 3 ]; do
  read_secret "Sudo password (your Mac login password)" sudo_pw
  if [ -z "$sudo_pw" ]; then
    echo "  empty password, try again"
    tries=$((tries + 1))
    continue
  fi
  if validate_sudo "$sudo_pw"; then
    echo "  sudo password verified"
    break
  else
    echo "  WARNING: sudo did not accept that password (typo? wrong account?)"
    tries=$((tries + 1))
    if [ "$tries" -lt 3 ]; then
      echo "  try again ($tries/3)"
      sudo_pw=""
    fi
  fi
done
if [ -z "$sudo_pw" ]; then
  echo "No usable sudo password entered; skipping it." >&2
else
  store_secret "sudo-password" "$sudo_pw" || echo "  (continuing anyway)"
  unset sudo_pw
fi
echo

# --- Tailscale auth key ---
tries=0
authkey=""
while [ "$tries" -lt 3 ]; do
  read_secret "Tailscale auth key (tskey-auth-...)" authkey
  if [ -z "$authkey" ]; then
    echo "  empty key, try again"
    tries=$((tries + 1))
    continue
  fi
  case "$authkey" in
    tskey-auth-*)
      echo "  auth key format looks right"
      break
      ;;
    *)
      echo "  WARNING: an auth key normally starts with 'tskey-auth-'. Check for a typo."
      tries=$((tries + 1))
      if [ "$tries" -lt 3 ]; then
        echo "  try again ($tries/3)"
        authkey=""
      fi
      ;;
  esac
done
if [ -z "$authkey" ]; then
  echo "No auth key entered; the Watcher will not be able to re-login Tailscale on its own." >&2
else
  store_secret "tailscale-authkey" "$authkey" || echo "  (continuing anyway)"
  unset authkey
fi
echo

# --- Verify retrieval works (without printing values) ---
echo "Verifying retrieval (values are not printed):"
if [ -x "$WATCHDOG_DIR/lib/get-secret.sh" ]; then
  if [ -n "$(/bin/zsh "$WATCHDOG_DIR/lib/get-secret.sh" sudo-password 2>/dev/null)" ]; then
    echo "  sudo-password: OK (retrievable)"
  else
    echo "  sudo-password: NOT FOUND — run this script again" >&2
  fi
  if [ -n "$(/bin/zsh "$WATCHDOG_DIR/lib/get-secret.sh" tailscale-authkey 2>/dev/null)" ]; then
    echo "  tailscale-authkey: OK (retrievable)"
  else
    echo "  tailscale-authkey: NOT FOUND — run this script again" >&2
  fi
else
  echo "  lib/get-secret.sh not found at $WATCHDOG_DIR/lib/ — run install.sh" >&2
fi
echo
echo "Done. Secrets are stored; this script never printed them."
