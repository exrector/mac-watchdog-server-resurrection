# Blueprint: healthy Mac (<YOUR_TAILSCALE_HOSTNAME>)
#
# TEMPLATE — the installer (install.sh) fills in the placeholders below
# from watchdog.conf. If you edit watchdog.conf, re-run install.sh or
# update this file by hand to match.
#
# Placeholders:
#   <YOUR_TAILSCALE_HOSTNAME> — your node's hostname in `tailscale status`
#   <YOUR_GATEWAY>            — your default gateway (e.g. 192.168.0.1),
#                               or empty if you accept any gateway
#   <YOUR_WIFI_INTERFACE>     — your Wi-Fi interface (usually en1)
#   <WATCHDOG_DIR>            — install directory (usually ~/watchdog)
#   <TAILSCALE_CLI>           — path to the Tailscale CLI inside the app

Good is the expected result written next to each Check in THIS file.
There is no separate good file. Do not look for good.md or good.txt.

## Health checklist — Check each item ONCE. Do not re-run a Check that already returned Good.

Skip an item when it is not configured for this machine: skip item 1
(Wi-Fi) when no Wi-Fi interface is configured (Ethernet-only Mac);
skip item 5 (Tailscale) when no Tailscale hostname is configured
(no Tailscale). A skipped item is not a failure — do not repair it
and do not report it as broken.

1. Wi-Fi power
   Check: networksetup -getairportpower <YOUR_WIFI_INTERFACE>
   Good: Wi-Fi Power (<YOUR_WIFI_INTERFACE>): On
2. Internet ping
   Check: ping -c1 -q -W 2000 8.8.8.8
   Good: 1 packets received
3. DNS
   Check: dig +short example.net
   Good: returns an IP address (any)
4. Default route
   Check: route -n get default | grep gateway
   Good: gateway: <YOUR_GATEWAY>
5. Tailscale
   Check: <TAILSCALE_CLI> status | head -1
   Good: own line shows <YOUR_TAILSCALE_HOSTNAME> without offline or stopped

## Rules of evidence
- Every OK or FIXED must quote the exact output of the command that proved it.
- Without output, say only NOT VERIFIED. Never claim success from memory.
- Do not call the node online when status says offline or stopped.

## Tailscale login (if status says Logged out)
Run directly, NOT through launchctl asuser, NOT piped. Two steps:
1. <TAILSCALE_CLI> up --authkey=$(/bin/zsh <WATCHDOG_DIR>/lib/get-secret.sh tailscale-authkey) --reset
2. <TAILSCALE_CLI> up --accept-routes --hostname=<YOUR_TAILSCALE_HOSTNAME>-cli
Then verify with status. If a VPN dialog appears, run <WATCHDOG_DIR>/click-allow.sh.
Note: the `-cli` suffix keeps the CLI login distinct from the GUI app's
registration. If you only use the CLI, drop the suffix.

## System dialogs
- If macOS asks to allow VPN configurations, click Allow (see click-allow.sh).
- If a permission dialog appears that you cannot answer, report it exactly and stop.

## Repairs (only for items that are NOT Good)
- DNS broken: networksetup -setdnsservers Wi-Fi Empty
- No default route: sudo -n /sbin/route add default <YOUR_GATEWAY>
- Wi-Fi Off: networksetup -setairportpower <YOUR_WIFI_INTERFACE> on
- Tailscale stopped: <TAILSCALE_CLI> up
After each repair, re-run ONLY that item's Check to verify it.

## Secrets
- Never print a secret value in your answer or in a log.
- Get the Tailscale auth key only via: /bin/zsh <WATCHDOG_DIR>/lib/get-secret.sh tailscale-authkey
- Get the sudo password only via: /bin/zsh <WATCHDOG_DIR>/lib/get-secret.sh sudo-password
- Never write a secret to a file, and never `cat` a plaintext secret file.
