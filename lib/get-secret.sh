#!/bin/zsh
# lib/get-secret.sh — retrieve a secret by name.
#
# Usage as a command (what the model and the scripts use):
#   /bin/zsh lib/get-secret.sh <name>
#   Prints the secret to stdout and exits 0.
#
# Usage as a library (source it, then call the function):
#   source lib/get-secret.sh
#   value=$(get_secret <name>)
#
# Secret names: "sudo-password" (the Mac login password, for sudo) and
# "tailscale-authkey" (a Tailscale auth key, tskey-auth-...).
#
# Backends, tried in this order:
#   1. macOS Keychain: generic password, service $KEYCHAIN_SERVICE
#      (default "mac-watchdog"), account <name>.
#   2. Secrets file: $SECRETS_FILE (default ~/.config/mac-watchdog/secrets),
#      mode 600, one KEY=VALUE line per secret.
#
# Prints NOTHING but the secret on stdout. Errors go to stderr.
# Never log a secret value.

# Resolve config values: prefer the environment (the calling script already
# sourced watchdog.conf), otherwise look for the config next to this file
# or in the default install dir, otherwise use built-in defaults.
if [ -z "${KEYCHAIN_SERVICE:-}" ] || [ -z "${SECRETS_FILE:-}" ]; then
  _lib_dir="${0:A:h}"
  _conf=""
  if [ -f "$_lib_dir/../watchdog.conf" ]; then
    _conf="$_lib_dir/../watchdog.conf"
  elif [ -f "$HOME/watchdog/watchdog.conf" ]; then
    _conf="$HOME/watchdog/watchdog.conf"
  fi
  if [ -n "$_conf" ]; then
    # shellcheck disable=SC1090
    source "$_conf" 2>/dev/null || true
  fi
fi
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-mac-watchdog}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.config/mac-watchdog/secrets}"

get_secret() {
  local name="$1" value=""
  if [ -z "$name" ]; then
    echo "get-secret: usage: get-secret <name>" >&2
    return 2
  fi
  # 1. Keychain.
  value=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$name" -w 2>/dev/null)
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  # 2. Secrets file (mode 600).
  if [ -f "$SECRETS_FILE" ]; then
    value=$(grep -E "^${name}=" "$SECRETS_FILE" 2>/dev/null | tail -1 | sed "s/^${name}=//" | tr -d '\r')
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  echo "get-secret: secret '$name' not found in Keychain (service '$KEYCHAIN_SERVICE') or in $SECRETS_FILE. Run scripts/setup-secrets.sh." >&2
  return 1
}

# When executed directly (not sourced), print the requested secret.
# In zsh, ZSH_EVAL_CONTEXT is "toplevel" for a directly executed script
# and contains "file" when the file is sourced.
if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  if [ -z "${1:-}" ]; then
    echo "usage: $0 <secret-name>" >&2
    echo "secret names: sudo-password, tailscale-authkey" >&2
    exit 2
  fi
  get_secret "$1"
fi
