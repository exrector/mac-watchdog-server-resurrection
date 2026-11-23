# Mac Watchdog Server Resurrection

A Mac that fixes its own network and comes back online by itself — using
**only the on-device Apple Intelligence model**. No third-party models, no
cloud, no chat, no human in the loop. A small local model (Apple's ~3B
on-device model) checks the machine against a blueprint of "healthy" every
5 minutes and repairs what is broken. If it cannot repair the machine, it
opens an outbound channel so you can reach it anyway.

## The problem this solves

A Mac that runs as a server — a Mac mini in a closet, a machine in
another city or another country, a headless box under a desk — will
eventually lose its network. Wi-Fi drops. DNS stops resolving. The VPN
disconnects. The default route disappears. It happens for boring reasons:
a router reboot, a DHCP hiccup, a VPN app update, a system update that
resets a setting.

When it happens, you have a problem with no good answer. The machine is
offline, so you cannot reach it to fix it — the very thing you need to
fix is the thing that would let you in. If the machine is next to you,
you walk over and click a few things. If it is a thousand kilometres
away, you are stuck until someone physically goes to it. Meanwhile
whatever it was running — a home server, a build job, a file share, a
camera feed — is dead, and it stays dead.

The usual answers do not cover this. A hardware watchdog reboots the
machine, but a reboot does not fix a wrong DNS server or a logged-out
VPN. Remote-access tools (VNC, SSH, Tailscale) all need the network to
already work. A second machine watching the first just moves the problem
one step over: who watches the watcher, and what happens when the
watcher's own network breaks? Cloud AI cannot help either — when the
network is down, there is no cloud to call.

The missing piece is a machine that can **think about its own health
and repair itself, with no network and no human**. That is what this
project is.

## Who this is for

- **You have a Mac mini (or Mac Studio) running as a server** — a home
  server, a media server, a Home Assistant box, a file server, a build
  machine — and it has to stay up while you are not there.
- **Your Mac is remote.** It sits in another flat, another city, another
  country. You cannot walk over to it when the network breaks. Picture
  it: your Mac mini is in Sacramento, USA, and you are in Uryupinsk,
  Russia. (Purely hypothetical. The author is not in Uryupinsk.
  Probably.)
- **You run something on a Mac that must not silently die.** A scheduled
  job, a camera, a home automation hub. If it goes offline at 3 a.m.,
  you want it back by itself before morning, not a dead box discovered
  days later.
- **You run a homelab and are tired of babysitting it.** You already
  have Tailscale, you already have a Mac that mostly works — you want the
  "mostly" to become "always", without adding another machine to watch
  the first one.
- **You care that the fix is local.** No data leaves the machine for the
  repair itself, no third-party AI service, no account, no subscription.
  The model lives on the Mac and works with the network cable unplugged.

If your Mac is on your desk and you are always next to it, you do not
need this. If the machine is somewhere you cannot reach, and it must
stay reachable, this is for you.

## What it does

Every 5 minutes, a small supervisor checks the machine against a
blueprint of "healthy": Wi-Fi on, ping works, DNS resolves, the default
route is there, Tailscale is online. If something is broken, it wakes
the local Apple Intelligence model, which reads the blueprint, repairs
only the broken items, and reports each repair with the exact command
output as evidence. Then the supervisor independently re-checks
everything itself — the verdict comes from the checks, never from the
model's words — and repeats up to 3 times. If the machine still cannot
fix itself, it opens an outbound SSH tunnel to a host you control, so
you can reach it anyway (NAT blocks inbound connections, but outbound
always works).

It also protects itself. The watchdog's own files are marked immutable,
so nothing — not even the model, which has a terminal and sudo — can
delete them. A backup copy lives outside the watchdog directory, and a
second agent restores anything missing every 5 minutes. The watchdog
therefore survives even a wipe of its own directory.

This started as a personal project to keep a remote Mac mini alive — a
machine that has to survive network outages on its own, with nobody
next to it to click anything. It now works as a general tool for any
Apple Silicon Mac that needs to stay reachable.

## How it works

```
LaunchAgent (every 5 min)
   └─ watcher.sh
       ├─ deterministic health check (Wi-Fi, ping, DNS, route, Tailscale)
       ├─ if broken: wake the local model (recovery-agent)
       │     model reads blueprint.md, repairs only the broken items,
       │     and reports one line per item with the exact command output
       ├─ independent VERIFY (the script re-checks everything itself;
       │     the verdict comes from the checks, never from the model's words)
       ├─ up to 3 attempts, then GAVE UP
       └─ on GAVE UP: call-home.sh opens the outbound tunnel (Plan B)
watchdog-bootstrap.sh (every 5 min)
   └─ restores any missing watchdog file from the backup copy
```

The key design decision: **reliability comes from the loop
(check → model → independent re-check), not from the model itself.**
The local model is small and can be wrong — it sometimes stops after one
step, or claims success it did not achieve. The deterministic VERIFY
catches that. The model is the hands; the script is the judge.

## What it repairs

| Problem | Repair |
|---|---|
| Wi-Fi off | `networksetup -setairportpower <interface> on` |
| DNS broken | `networksetup -setdnsservers Wi-Fi Empty` |
| Default route missing | `sudo route add default <gateway>` |
| Tailscale stopped | `tailscale up` |
| Tailscale logged out | `tailscale up --authkey=... --reset`, then restore settings |

Every repair is verified by re-running that item's check. The model's
reasoning (every command it ran, its exit code and outcome) is saved to
`last-reasoning.txt` after each run, so you can see exactly what it did
and why.

## Plan B — the outbound channel

If the machine cannot fix itself after 3 attempts, the Watcher opens an
outbound SSH tunnel to a rendezvous host you control
(`-R <port>:127.0.0.1:22`). NAT blocks inbound connections, but outbound
works — so from the rendezvous host you SSH to `localhost:<port>` and land
on the broken Mac. A persistent version (`call-home-loop.sh`, kept alive
by its own LaunchAgent) can hold the tunnel open continuously.

## Requirements

- Apple Silicon Mac (M1 or newer). Intel Macs cannot run Apple Intelligence.
- macOS 26 or newer (the Swift package targets macOS 26.0; the
  Foundation Models framework itself is available from macOS 26).
- **Full Xcode from the App Store** (to build the agent from source).
  Command Line Tools alone is **not** enough: the agent uses Foundation
  Models macros (`@Generable`, `@Guide`), whose compiler plugin ships
  only with full Xcode. Swift 6.2+ (included in Xcode 26+).
- Apple Intelligence enabled and the on-device model downloaded
  (System Settings → Apple Intelligence & Siri).
- Tailscale installed (the GUI app; the CLI inside it is used).
  The Watcher verifies the node is online; without Tailscale the
  Tailscale check is skipped only if you remove it from the blueprint.
- Python 3 (for `reasoning.py`; ships with macOS).
- A rendezvous host with SSH for Plan B (optional but recommended) —
  any server you can SSH into, e.g. a small VPS. Example values in the
  config use `user@100.64.0.1` and port `22999` as placeholders.

## Installation

Two ways to get the agent binary — pick one:

**A. Build from source (default).** Needs full Xcode (see Requirements).

```sh
git clone https://github.com/<you>/mac-watchdog-server-resurrection.git
cd mac-watchdog-server-resurrection
./install.sh
```

**B. Prebuilt binary (no Xcode needed).** Download `recovery-agent`
from the [Releases page](https://github.com/<you>/mac-watchdog-server-resurrection/releases),
verify the SHA-256 checksum, and place the binary next to `install.sh`
before running it. The installer detects the prebuilt binary and uses it
instead of building. The binary is built by GitHub Actions on a clean
macOS runner at release time, so it contains no personal paths.

The installer:

1. Checks macOS, Apple Silicon and Apple Intelligence (best effort).
2. Builds `recovery-agent` from the Swift source in `src/recovery-agent/`
   (`swift build -c release`, relative paths only). **This repo contains
   no binaries** — everything is built on your machine from source, so
   every install is reproducible.
3. Copies the files (and the built binary) to `~/watchdog` (or
   `--dir <path>`) and to a backup
   directory (`~/Library/Application Support/MacWatchdog/backup`).
4. Creates `watchdog.conf` from the example, auto-detecting the Tailscale
   hostname, gateway and Wi-Fi interface when possible. Review it.
5. Fills the placeholders in `blueprint.md` from your config.
6. Marks the source files `chflags uchg` (user immutable) so nothing —
   not even the model, which has a terminal and sudo — can delete them.
   Logs and the config stay writable.
7. Installs and loads three LaunchAgents: `com.macwatchdog.watcher`,
   `com.macwatchdog.bootstrap`, `com.macwatchdog.call-home`.
8. Runs `scripts/setup-secrets.sh` to store the sudo password and the
   Tailscale auth key (see Security below).

Re-running `./install.sh` is safe: it will not overwrite your
`watchdog.conf` or your secrets, and it re-applies the protection.

## Configuration

### `watchdog.conf`

One file, all machine-specific values. Created from
`watchdog.conf.example` by the installer. The important ones:

| Variable | Meaning | Example |
|---|---|---|
| `WATCHDOG_DIR` | install directory | `~/watchdog` |
| `BACKUP_DIR` | self-healing backup | `~/Library/Application Support/MacWatchdog/backup` |
| `CHECK_INTERVAL` | seconds between runs | `300` |
| `TAILSCALE_HOSTNAME` | your node name in `tailscale status` | `mac-mini` |
| `WIFI_INTERFACE` | Wi-Fi interface | `en1` |
| `EXPECTED_GATEWAY` | default gateway, or empty = any | `192.168.0.1` |
| `RENDEZVOUS_HOST` | `user@host` for the Plan B tunnel | `user@100.64.0.1` |
| `RENDEZVOUS_PORT` | tunnel port on the rendezvous host | `22999` |
| `CALL_HOME_KEY` | dedicated SSH key for the tunnel | `~/.ssh/mac-watchdog-call-home` |

After editing the config, re-run `./install.sh` (it refreshes the
blueprint placeholders) or update `blueprint.md` by hand.

### `blueprint.md`

The model's definition of a healthy machine: one Check and one expected
Good result per item, the rules of evidence, the Tailscale login
procedure and the repairs. It is a template in the repo; the installer
fills in your values. If you change what "healthy" means, edit this file
(and remember to `chflags nouchg` it first, then re-apply `chflags uchg`).

## Secrets

The Watcher needs two secrets, and both are stored **securely by
default** — never as plaintext files in the watchdog directory:

| Secret | Used for |
|---|---|
| `sudo-password` | the Mac login password, for `sudo` in repairs |
| `tailscale-authkey` | a Tailscale auth key (`tskey-auth-...`), to re-login Tailscale |

### How and when you enter them

The installer asks you at the **last step** (step 8, after the files,
config and LaunchAgents are already in place). It runs
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

### How they are stored in the system

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

> Note: on the author's own machine the secrets were deliberately kept
> as plaintext `644` files, because that machine is a closed test bench.
> That is **not** this project's default and is not recommended for anyone
> else. The default here is Keychain, with the 600 file as the fallback.

Create a Tailscale auth key at
`https://login.tailscale.com/admin/settings/keys` (reusable, tagged if
you use ACLs). Rotate it if it ever leaks.

### Sudo

Some repairs need `sudo` (adding a route). The cleanest setup is a
passwordless sudo rule for the specific commands, or for the watchdog's
user if you accept that trade-off. The model gets the sudo password from
the secret store only when a repair needs it; the password is never
written to a log. If you prefer not to grant sudo at all, the Watcher
still fixes Wi-Fi, DNS and Tailscale — only the route repair will fail.

## Testing it

Break something on purpose and watch it heal. The Watcher runs every
5 minutes; give it one tick plus up to a minute for the model.

```sh
# Wi-Fi off — the Watcher turns it back on
networksetup -setairportpower en1 off

# DNS broken — the Watcher resets it to Empty (DHCP)
networksetup -setdnsservers Wi-Fi 192.0.2.1

# Tailscale stopped — the Watcher brings it up
/Applications/Tailscale.app/Contents/MacOS/Tailscale down

# Tailscale logged out — the strongest test: the Watcher re-logs in
# using the auth key from the secret store
/Applications/Tailscale.app/Contents/MacOS/Tailscale logout
```

Watch the recovery live:

```sh
tail -f ~/watchdog/watcher.log
```

And read what the model actually did, step by step:

```sh
cat ~/watchdog/last-reasoning.txt
```

A healthy run ends with `VERIFIED HEALTHY`. A full kill (Wi-Fi off +
DNS broken + Tailscale logged out at once) was repaired in about 30
seconds on an M4 Mac mini in testing.

**Do not test by deleting the Tailscale VPN profile** in System Settings:
the VPN-approval dialog and the `click-allow.sh` helper are the least
tested part of this project. And do not power the machine off to test
wake-on-LAN — Wake-on-LAN over Wi-Fi does not work on these machines.

## Files

| File | What it is |
|---|---|
| `install.sh` | installer (see above) |
| `watcher.sh` | the supervisor: check → model → VERIFY, up to 3 attempts |
| `blueprint.md` | template for the model's definition of "healthy" |
| `src/recovery-agent/` | Swift source of the agent (`Package.swift` + `main.swift`); built by the installer, no binary in the repo |
| `reasoning.py` | extracts the last run's reasoning into `last-reasoning.txt` |
| `click-allow.sh` | clicks Allow in a VPN-configuration dialog (System Events) |
| `call-home.sh` | opens the Plan B tunnel once (on GAVE UP) |
| `call-home-loop.sh` | keeps the Plan B tunnel open forever (LaunchAgent) |
| `watchdog-bootstrap.sh` | self-healing: restores missing files from the backup |
| `lib/get-secret.sh` | secret retrieval (Keychain, then 600 file) |
| `scripts/setup-secrets.sh` | interactive secrets setup |
| `com.macwatchdog.*.plist` | LaunchAgent templates (watcher, bootstrap, call-home) |
| `watchdog.conf.example` | config template |
| `.github/workflows/release.yml` | GitHub Actions: builds the binary on a clean macOS runner and attaches it to a Release |

There are **no binaries in this repository**. The installer builds
`recovery-agent` from the Swift source in `src/recovery-agent/` on your
machine (`swift build -c release`, relative paths only), so every install
is reproducible from source. Full Xcode is required for the build (see
Requirements above). If you do not have Xcode, download the prebuilt
binary from the Releases page and place it next to `install.sh` — the
installer will use it instead of building.

## Build requirements

- Full Xcode from the App Store (Swift 6.2+, Xcode 26+). Command Line
  Tools alone is not enough: the agent uses Foundation Models macros
  (`@Generable`, `@Guide`), whose compiler plugin ships only with Xcode.
- macOS 26 or newer (the Swift package in `src/recovery-agent/`
  declares `.macOS("26.0")`).
- No third-party dependencies: the Swift package has no external
  dependencies, so the build needs no network access. Build it by hand
  with:

```sh
cd src/recovery-agent
swift build -c release
# binary: .build/release/recovery-agent
```

Verify the built agent with `./.build/release/recovery-agent selftest`
(it asks the local model to create and read back a marker file).

## Security

- **Secrets** live in the Keychain (or a 600 file), never in the repo and
  never as plaintext in the watchdog directory. `.gitignore` excludes
  `watchdog.conf`, the secrets file, logs, and anything matching
  `*secret*`, `*password*`, `*authkey*`.
- **Source protection.** After install, every source file is marked
  `chflags uchg` (user immutable). `rm` on such a file fails with
  `Operation not permitted` — this protects against the model itself
  deleting its own files (which happened once during development, almost
  certainly by mistake). Logs and `watchdog.conf` stay writable.
- **Self-healing.** A backup copy lives outside the watchdog directory.
  The bootstrap agent checks every 5 minutes and restores anything
  missing, including the LaunchAgent plists. The watchdog therefore
  survives even a wipe of its own directory.
- **Only Apple Intelligence.** The model runs entirely on-device via
  Apple's Foundation Models framework. No data leaves the machine for
  inference, no third-party model is involved, and there is no cloud
  component. (The optional Plan B tunnel is plain SSH to a host you
  control.)
- **Model permissions.** The model gets a terminal and, when you set it
  up, sudo and the secrets it needs to do its job. That is a deliberate
  trade-off: a watchdog that cannot act cannot heal. Scope it to the
  machine's purpose and keep the machine's own access controls in mind.
- **What the model cannot do.** It cannot see the screen (the local model
  is text-only); GUI interaction is limited to scripted helpers such as
  `click-allow.sh` via System Events. It cannot read files under
  `~/Documents` from a LaunchAgent (macOS TCC) — which is why everything
  lives in `~/watchdog` and the backup.

## Troubleshooting

- **Watcher never runs / no log.** Check the agent:
  `launchctl list | grep macwatchdog`. If it is not loaded, re-run
  `./install.sh`. The log is `~/watchdog/watcher.launchd.log`.
- **`watchdog.conf: required variable ... is not set`.** Edit
  `~/watchdog/watchdog.conf` and set the named variable, then wait for
  the next tick (or run `~/watchdog/watcher.sh` by hand).
- **Model says `unavailable` / `modelNotReady`.** Apple Intelligence is
  off or the model has not downloaded yet. Enable it in System Settings
  → Apple Intelligence & Siri, wait for the download, and check the
  language: the model requires the system language (or at least Siri) to
  be a supported one. Run `./install.sh` again to re-check.
- **`tailscale up` fails with "The Tailscale GUI failed to start"**
  when run over SSH. That is expected: the GUI app must be running in a
  GUI session. The Watcher runs under launchd in the GUI session, so it
  does not hit this; only manual SSH invocations do.
- **Keychain prompts appear at runtime.** The `-T` grants in
  `setup-secrets.sh` cover `/bin/zsh`, `/bin/sh`, `/usr/bin/security`
  and the recovery-agent. If a prompt still appears, grant access once
  in Keychain Access (or re-run `setup-secrets.sh`).
- **The machine is unreachable and the tunnel is not up.** The tunnel
  only opens after the Watcher gives up (3 failed attempts). If the
  Watcher itself cannot run (e.g. the whole directory was wiped and the
  bootstrap has not restored it yet), wait 5–10 minutes for the bootstrap
  tick. As a last resort, the machine needs hands-on access.

## Only Apple Intelligence

This project deliberately uses **only** Apple's on-device model. The
model is the same ~3B-parameter model on every supported Mac (M1 through
M4); what differs between machines is speed (memory bandwidth, Neural
Engine) and available context, not the model itself. No Ollama, no
third-party agents, no API keys, no cloud inference. If a machine has no
Apple Intelligence, this tool cannot run on it — the Watcher will say so
in the log rather than silently doing nothing.

## License

MIT — see `LICENSE`. Copyright (c) 2026 Exrector.
