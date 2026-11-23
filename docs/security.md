# Security

How secrets, permissions and the model's access work in Mac Watchdog
Server Resurrection.

## Secrets

The Watcher needs two secrets:

| Secret | Used for |
|---|---|
| `sudo-password` | the Mac login password, for `sudo` in repairs |
| `tailscale-authkey` | a Tailscale auth key (`tskey-auth-...`), to re-login Tailscale |

### How and when you enter them

The installer asks you at the **last step** (after the files, config
and LaunchAgents are already in place). It runs
`scripts/setup-secrets.sh`, which:

1. Asks for the sudo password (typed with hidden input — nothing shows
   on screen) and **validates** it by trying `sudo` once (up to 3 tries).
2. Asks for the Tailscale auth key (hidden input) and validates the
   format (`tskey-auth-` prefix).
3. Asks where to store them — **Keychain (default)** or a **secrets
   file** — and stores them there.
4. Verifies retrieval: it reads each secret back through the same path
   the Watcher will use, without printing the value, and reports OK or
   FAIL.

You can also run the setup later, any time, with:

```sh
/bin/zsh ~/watchdog/scripts/setup-secrets.sh
```

### How they are stored

1. **macOS Keychain (default, recommended).** Generic password items,
   service `mac-watchdog`, accounts `sudo-password` and
   `tailscale-authkey`, in your login Keychain
   (`~/Library/Keychains/login.keychain-db`) — encrypted by macOS and
   tied to your login password. The setup script grants the watchdog's
   programs access with `-T` flags (`/bin/zsh`, `/bin/sh`,
   `/usr/bin/security`, the recovery-agent binary), so the Watcher can
   read them at runtime without a GUI prompt.
2. **Secrets file (fallback).** `~/.config/mac-watchdog/secrets`, mode
   `600` (readable only by you), `KEY=VALUE` lines. Use only if you
   cannot use the Keychain.

Retrieval is via `lib/get-secret.sh <name>`: it tries the Keychain first,
then the file, and fails with a clear error if the secret is in neither.
It never prints a secret to a log. The Watcher reads the auth key only
when it actually has to re-login Tailscale — not on every run.

Create a Tailscale auth key at
`https://login.tailscale.com/admin/settings/keys` (reusable, tagged if
you use ACLs). Rotate it if it ever leaks.

### Removing secrets

Uninstalling the watchdog (`./uninstall.sh`) does **not** delete your
secrets. To remove them:

- **Keychain:** open Keychain Access, find the items with service
  `mac-watchdog` (accounts `sudo-password` and `tailscale-authkey`),
  and delete them. Or from the terminal:
  `security delete-generic-password -s mac-watchdog -a sudo-password`
  and `security delete-generic-password -s mac-watchdog -a tailscale-authkey`.
- **Secrets file:** `rm ~/.config/mac-watchdog/secrets`.

Also revoke the Tailscale auth key at
`https://login.tailscale.com/admin/settings/keys` if it is no longer needed.

## Sudo

Some repairs need `sudo` (adding a route). The cleanest setup is a
passwordless sudo rule for the specific commands, or for the watchdog's
user if you accept that trade-off. The model gets the sudo password from
the secret store only when a repair needs it; the password is never
written to a log. If you prefer not to grant sudo at all, the Watcher
still fixes Wi-Fi, DNS and Tailscale — only the route repair will fail.

## The model's access (risk surface)

The model gets an **unrestricted terminal** (`/bin/zsh -lc`) and, when
you set it up, sudo and the secrets it needs. That is a deliberate
trade-off: a watchdog that cannot act cannot heal. It is also the
largest risk surface in this project — a mistaken command can change
settings or damage files. Scope it to the machine's purpose and keep the
machine's own access controls in mind.

A future version should restrict the model to a fixed set of repair
operations (diagnose freely, execute only from an allow-list, with
argument checking on privileged commands). That is not implemented yet.

## What the model cannot do

- It cannot see the screen (the local model is text-only). GUI
  interaction is limited to scripted helpers such as `click-allow.sh`
  via System Events.
- It cannot read files under `~/Documents` from a LaunchAgent (macOS
  TCC) — which is why everything lives in `~/watchdog` and the backup.

## What is never committed

`.gitignore` excludes `watchdog.conf`, the secrets file, logs, and
anything matching `*password*` or `*authkey*`. The helper scripts
`lib/get-secret.sh` and `scripts/setup-secrets.sh` are source code, not
secrets, and **are** committed — an earlier overly broad `*secret*`
rule used to exclude them by mistake, which broke installation from a
clean clone.
