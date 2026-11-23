# Mac Watchdog Server Resurrection

A Mac that fixes its own network and comes back online by itself — using
**only the on-device Apple Intelligence model**. No third-party models, no
cloud, no chat, no human in the loop. A small local model (Apple's ~3B
on-device model) checks the machine against a blueprint of "healthy" every
5 minutes and repairs what is broken. If it cannot repair the machine, it
opens an outbound channel so you can reach it anyway.

> **Status: Experimental.** This works on the author's machine and is
> published so others can try it, but it is not a finished product. Do
> not install it on a remote Mac unless you have another way to reach
> that machine if the watchdog itself fails.

## Quick Start

```sh
git clone https://github.com/exrector/mac-watchdog-server-resurrection.git
cd mac-watchdog-server-resurrection
./install.sh
```

Requirements: Apple Silicon Mac, macOS 26+, Apple Intelligence enabled,
Tailscale installed (optional — see Configuration). To build from source
you need full Xcode; without Xcode, download the prebuilt
`recovery-agent` from the
[Releases page](https://github.com/exrector/mac-watchdog-server-resurrection/releases)
and place it next to `install.sh` first. After install, check
`tail -f ~/watchdog/watcher.log` — a healthy run ends with
`VERIFIED HEALTHY`.

## The problem this solves

A Mac that runs as a server — a Mac mini in a closet, a machine in
another city or another country, a headless box under a desk — will
eventually lose its network. Wi-Fi drops. DNS stops resolving. The VPN
disconnects. The default route disappears. Boring causes: a router
reboot, a DHCP hiccup, a VPN app update, a system update that resets a
setting.

When it happens, you cannot reach the machine to fix it — the very
thing you need to fix is the thing that would let you in. If the
machine is next to you, you walk over and click a few things. If it is
far away, you are stuck until someone physically goes to it. Meanwhile
whatever it was running is dead, and it stays dead.

A hardware watchdog reboots the machine, but a reboot does not fix a
wrong DNS server or a logged-out VPN. Remote-access tools all need the
network to already work. A second machine watching the first just moves
the problem over. Cloud AI cannot help — when the network is down, there
is no cloud to call. The missing piece is a machine that can think
about its own health and repair itself, with no network and no human.

## Who this is for

- **Your Mac is remote.** It sits in another flat, another city, another
  country, and you cannot walk over to it when the network breaks.
  Picture it: your Mac mini is in Sacramento, USA, and you are in
  Uryupinsk, Russia. (Purely hypothetical. The author is not in
  Uryupinsk. Probably.)
- **You run something on a Mac that must not silently die.** A scheduled
  job, a camera, a home automation hub. If it goes offline at 3 a.m.,
  you want it back by itself before morning, not a dead box discovered
  days later.
- **You run a homelab and are tired of babysitting it.** You already
  have Tailscale and a Mac that mostly works — you want the "mostly" to
  become "always", without adding another machine to watch the first.
- **You care that the fix is local.** No data leaves the machine for
  the repair itself, no third-party AI service, no account, no
  subscription. The model lives on the Mac and works with the network
  cable unplugged.

If your Mac is on your desk and you are always next to it, you do not
need this.

## How it works

This is an autonomous immune system, not a watchdog with a model bolted
on. It has layers, and the model is the analyst — not the repairman.

```
LaunchAgent (every CHECK_INTERVAL, default 5 min)
   └─ watcher.sh
       ├─ deterministic health check (Wi-Fi, ping, DNS, route, Tailscale)
       ├─ if healthy: log HEALTHY and stop (nothing is woken)
       ├─ if broken: REFLEXES — deterministic repair for KNOWN problems
       │     (Wi-Fi on, DNS reset, route add, Tailscale up / re-login)
       │     No model involved: a script does these better.
       ├─ re-check. If healthy: ANALYST — the local model investigates
       │     WHY it happened, using the observer's pre-failure record
       │     and the incident history, and records the incident
       │     (problem, cause + confidence, fix, outcome).
       ├─ if still broken: ESCALATION — the model acts as repairman
       │     (the problem is unknown), up to 3 attempts, each verified
       │     independently; then the analyst records it.
       └─ if still broken: GAVE UP — analyst records it, Plan B opens
observer.sh (every minute, own LaunchAgent)
   └─ appends one line to events.log: the machine's state BEFORE any
      failure (Wi-Fi, IP, gateway, DNS, Tailscale, uptime). The analyst
      needs this "before" picture — without it, a cause is a guess.
review.sh (once a day at 09:00, own LaunchAgent)
   └─ the model reads the incident history and proposes improvements
      (proposals.md). It does NOT apply them — applying is a separate,
      human-approved step.
watchdog-bootstrap.sh (every 5 min, from outside the watchdog dir)
   └─ restores any missing watchdog file from the backup copy
```

The key design decision: **reliability comes from the loop
(check → reflex → independent re-check), not from the model.** The
model is small and can be wrong at executing procedures — it sometimes
stops after one step, or claims success it did not achieve. So it does
not execute the routine fixes. What it is good at is reasoning about
unfamiliar states, spotting patterns across incidents, and explaining
what happened. That is its job here: analyst, not repairman.

**Incident memory** (`incidents.log` + `hypotheses.tsv`) is what makes
the system learn. Every incident is recorded with its symptoms, the
reflexes tried, the outcome, and the model's analysis. The analysis
answers three questions, in order: **What broke? Why does it keep
happening? What should change so it does not happen again?** The third
question is the point of the whole system. The model reads the recent
history on every call, so it can say "this DNS failure is the third
this week" instead of starting from zero. It also judges its own past
hypotheses: `hypotheses.tsv` tracks each hypothesis with its
occurrences and refutations, so a hypothesis refuted three times is
retired by the data, not by the model's memory. Turning a recurring
problem into a NEW reflex is not automatic yet — that is the v1.1
Evolution Engine (see below).

The model's reasoning (every command it ran, its exit code and outcome)
is saved to `last-reasoning.txt` after each run, so you can see exactly
what it did and why.

## Kernel vs evolution layer (self-improvement)

The system is split in two, on purpose. The split is what makes
self-improvement safe instead of suicidal.

**Kernel (untouchable).** The minimal mechanism that keeps the machine
reachable and recoverable: `watchdog-bootstrap.sh`, the backup copy of
the files, `call-home.sh` (Plan B), and the version history. The model
never changes the kernel. The kernel restores the last known-good
snapshot when files are missing, and it is the only thing that can roll
the evolution layer back. If the model could change the kernel, a bad
change could cut off the machine with no way back. The kernel is
protected (`chflags uchg`) and lives outside the watchdog directory.

**Evolution layer (improvable).** Everything else: `watcher.sh`,
`blueprint.md`, `observer.sh`, `review.sh`, the reflexes, the
diagnostics. This is where improvements happen. The rules:

- Every change is a Git commit in the watchdog directory, with a
  message that says WHY (justification), what it is expected to achieve,
  and how to verify it. No commit without a reason. (`install.sh`
  initialises the Git repo; logs and the live config are ignored.)
- A change is judged by TWO criteria: **safety** (did it break
  anything) and **usefulness** (did the incident rate actually drop, or
  the fix actually help). A change that breaks nothing but helps nothing
  is a failed change — say so and revert it.
- After a change, the system is observed for several cycles. If a
  regression appears, revert to the previous commit. The backup copy is
  updated (consolidated) only after a change has proven itself.
- Changes that could cut off remote access (network, Tailscale, the
  watcher itself) are never applied blindly: they are checked in
  isolation first, and the kernel's rollback must be verified working
  before the change goes in.

**Daily review (initiative).** The system does not wait for a failure.
Once a day at 09:00, `review.sh` calls the model with the incident
history and asks what should improve — for example, "DNS was restored
six times in seven days; the current strategy fixes the consequence,
not the cause." The model writes proposals to `proposals.md`. It does
NOT apply them. Applying a proposal is a separate, human-approved step:
the model proposes, a human (or an explicit grant of authority) applies.

**What is NOT yet enabled.** The model currently has no write access
to the evolution layer — it proposes, it does not change code. Granting
it the authority to apply its own proposals is a separate decision, and
a significant one: it turns the system from a watchdog with a memory
into an autonomous evolving system. That decision belongs to the human
who owns the machine.

## v1.1 — Adaptive Tool Evolution (planned)

The next milestone: the system improves by evolving its TOOL LIBRARY,
not by rewriting itself. This is safer than self-modification of the
running system: a new tool is ADDED alongside the old ones, and the
statistics decide which one is preferred. Nothing that works is ever
deleted or modified — it is only demoted.

**The library.** Each reflex is a tool with an id, a version, a
checksum, a run history, and an effectiveness score (`tools.tsv`,
maintained by `watcher.sh` after every reflex run: runs, successes,
total time, incident types). The five built-in reflexes are the initial
tools, all in state `preferred`.

**Lifecycle (four states).** A tool moves through:
- `candidate` — the model created it as a separate script. Not yet
  admitted to automatic repair.
- `verified` — it passed independent checks (allowed actions only, no
  violation of base constraints, no kernel access). The trust mark is
  issued by the controller after verification, never by the model.
- `preferred` — it showed the best results on a sufficient number of
  COMPARABLE incidents (same incident type, enough samples — a
  promotion needs a minimum sample size, not two lucky runs).
- `retired` — no longer chosen by default, but preserved in the
  library as a fallback.

**Selection.** Priorities are data, not opinion: success rate AND
recovery time AND side effects AND repeat-failure frequency, per
incident type. A tool that is fast but causes repeat failures is worse
than a slower one that holds.

**Strategies.** The most interesting level: the model can improve not
the tools but their COMBINATION — discovering that a certain sequence
of existing tools restores the network more reliably than each action
alone. A strategy is a new, named sequence of ready tools; the original
tools stay unchanged. The system thus accumulates three kinds of
experience: diagnostic (which symptoms mean which failure), practical
(which tools actually help), and strategic (in what order and under
what conditions to apply them).

**Open problems (not solved yet).** How to admit a candidate tool
safely: an experimental tool must not be tested on the real network
connection of a remote Mac if it could cut off the only access channel.
The admission checks (what a candidate must prove before it runs on a
live failure) are the key unsolved piece, and the reason the model does
not yet have write access to the tool library. The six-step cycle from
the earlier Evolution Engine sketch (research → proposal → experiment
→ apply → observe → decide) still applies; Adaptive Tool Evolution is
the safer shape of it: evolve the library, not the system.

## What the reflexes repair

The five known problems, fixed deterministically by the script (no
model involved). If a reflex fails, the problem is by definition not
one of these — that is when the model is escalated to.

| Problem | Reflex |
|---|---|
| Wi-Fi off | `networksetup -setairportpower <interface> on` |
| DNS broken | `networksetup -setdnsservers Wi-Fi Empty` |
| Default route missing | `sudo route add default <gateway>` |
| Tailscale stopped | `tailscale up` |
| Tailscale logged out | `tailscale up --authkey=... --reset`, then restore settings |

Wi-Fi and Tailscale are optional: leave `WIFI_INTERFACE` empty for an
Ethernet-only Mac, or `TAILSCALE_HOSTNAME` empty to skip Tailscale.
Skipped checks are not failures.

## Plan B — the outbound channel

If the machine cannot fix itself after 3 attempts, the Watcher opens an
outbound SSH tunnel to a rendezvous host you control
(`-R <port>:127.0.0.1:22`). NAT blocks inbound connections, but outbound
works — so from the rendezvous host you SSH to `localhost:<port>` and land
on the broken Mac.

By default the tunnel is opened only on GAVE UP (one-shot). If you want
a standing tunnel at all times, install with `./install.sh
--with-call-home`, which adds a permanent tunnel agent (KeepAlive) that
holds the tunnel open continuously.

## Requirements

- Apple Silicon Mac (M1 or newer). Intel Macs cannot run Apple Intelligence.
- macOS 26 or newer. The Swift package targets macOS 26.0; the
  Foundation Models framework itself is available from macOS 26.
- Apple Intelligence enabled and the on-device model downloaded
  (System Settings → Apple Intelligence & Siri).
- **Full Xcode from the App Store** (to build the agent from source).
  Command Line Tools alone is **not** enough: the agent uses Foundation
  Models macros (`@Generable`, `@Guide`), whose compiler plugin ships
  only with full Xcode. Swift 6.2+ (included in Xcode 26+). Without
  Xcode, use the prebuilt binary from the Releases page.
- Tailscale installed (the GUI app; the CLI inside it is used) — only
  if you want the Tailscale check; otherwise leave
  `TAILSCALE_HOSTNAME` empty.
- Python 3 (for `reasoning.py`; ships with macOS).
- A rendezvous host with SSH for Plan B (optional but recommended) —
  any server you can SSH into, e.g. a small VPS.

## Installation

**A. Build from source (default).** Needs full Xcode.

```sh
git clone https://github.com/exrector/mac-watchdog-server-resurrection.git
cd mac-watchdog-server-resurrection
./install.sh
```

**B. Prebuilt binary (no Xcode needed).** Download `recovery-agent`
from the [Releases page](https://github.com/exrector/mac-watchdog-server-resurrection/releases),
verify the SHA-256 checksum, and place the binary next to `install.sh`
before running it. The installer detects the prebuilt binary and uses it
instead of building. The binary is built by GitHub Actions on a clean
macOS runner at release time, so it contains no personal paths.

The installer:

1. Checks macOS, Apple Silicon and Apple Intelligence (best effort).
2. Gets `recovery-agent`: uses a prebuilt binary next to `install.sh`
   if present, otherwise builds it from the Swift source in
   `src/recovery-agent/` (`swift build -c release`, relative paths
   only). **This repo contains no binaries** — everything is built on
   your machine from source, so every install is reproducible.
3. Copies the files (and the binary) to `~/watchdog` (or
   `--dir <path>`) and to a backup directory outside it
   (`~/Library/Application Support/MacWatchdog/backup`). The bootstrap
   script itself is installed in the support directory too, so it
   survives a wipe of `~/watchdog/`.
4. Creates `watchdog.conf` from the example, auto-detecting the Tailscale
   hostname, gateway and Wi-Fi interface when possible. Review it.
5. Fills the placeholders in `blueprint.md` from your config.
6. Marks the source files `chflags uchg` (user immutable) so they
   resist accidental deletion — including by the model, which has a
   terminal and sudo. This is a speed bump, not a guarantee: the owner
   or root can remove the flag with `chflags nouchg`. Logs and the
   config stay writable.
7. Installs and loads the LaunchAgents: `com.macwatchdog.watcher`,
   `com.macwatchdog.bootstrap`, `com.macwatchdog.observer` and
   `com.macwatchdog.review` (always), plus `com.macwatchdog.call-home`
   only with `--with-call-home`.
8. Runs `scripts/setup-secrets.sh` to store the sudo password and the
   Tailscale auth key (see Secrets below).

Re-running `./install.sh` is safe: it will not overwrite your
`watchdog.conf` or your secrets, and it re-applies the protection.

## Configuration

One file, `watchdog.conf`, created from `watchdog.conf.example` by the
installer. The important values:

| Variable | Meaning | Example |
|---|---|---|
| `WATCHDOG_DIR` | install directory | `~/watchdog` |
| `BACKUP_DIR` | self-healing backup | `~/Library/Application Support/MacWatchdog/backup` |
| `CHECK_INTERVAL` | seconds between runs | `300` |
| `TAILSCALE_HOSTNAME` | your node name in `tailscale status`, or empty = skip Tailscale | `mac-mini` |
| `WIFI_INTERFACE` | Wi-Fi interface, or empty = skip Wi-Fi | `en1` |
| `EXPECTED_GATEWAY` | default gateway, or empty = any | `192.168.0.1` |
| `RENDEZVOUS_HOST` | `user@host` for the Plan B tunnel | `user@100.64.0.1` |
| `RENDEZVOUS_PORT` | tunnel port on the rendezvous host | `22999` |
| `CALL_HOME_KEY` | dedicated SSH key for the tunnel | `~/.ssh/mac-watchdog-call-home` |

After editing the config, re-run `./install.sh` (it refreshes the
blueprint placeholders and the agents' intervals) or update
`blueprint.md` by hand.

`blueprint.md` is the model's definition of a healthy machine: one Check
and one expected Good result per item, the rules of evidence, the
Tailscale login procedure and the repairs. It is a template in the repo;
the installer fills in your values.

## Secrets

The Watcher needs two secrets: the sudo password and a Tailscale auth
key. Both are stored **securely by default** — in the macOS Keychain
(recommended) or in a `600` file at `~/.config/mac-watchdog/secrets`.
Never as plaintext in the watchdog directory, never in the repo. The
installer asks for them at the last step and validates them (sudo is
tried once; the key format is checked). You can re-run the setup any
time with `/bin/zsh ~/watchdog/scripts/setup-secrets.sh`. Retrieval is
via `lib/get-secret.sh <name>` (Keychain first, then the file), and the
auth key is read only when a Tailscale re-login is actually needed.
Full details: [docs/security.md](docs/security.md).

## Limitations

Be honest about what this cannot do:

- It cannot restore a physically absent network connection. If the
  cable is unplugged or the router is dead, no software on the Mac
  will bring the network back.
- The Plan B tunnel needs a working **outbound** connection. If the
  Mac cannot reach the internet at all, the tunnel cannot open.
- A rendezvous host reached over Tailscale is not a fallback when
  Tailscale itself is the thing that broke. Use a host reachable over
  plain SSH for Plan B.
- LaunchAgents in `~/Library/LaunchAgents` run in your user session:
  they do not run before you log in after a reboot. If the Mac reboots
  to a login screen, the Watcher starts only after login.
- Remote SSH access to the Mac needs Remote Login enabled
  (System Settings → General → Sharing → Remote Login).
- The model is text-only: it cannot see the screen. GUI interaction is
  limited to scripted helpers such as `click-allow.sh` (System Events).
  The VPN-approval dialog helper is the least tested part of the
  project — do not test by deleting the Tailscale VPN profile.
- Wake-on-LAN over Wi-Fi does not work on these machines. Do not power
  the machine off to test it.

## Testing it

Break something on purpose and watch it heal. The Watcher runs every
`CHECK_INTERVAL`; give it one tick plus up to a minute for the model.

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

Watch the recovery live with `tail -f ~/watchdog/watcher.log`, and read
what the model did with `cat ~/watchdog/last-reasoning.txt`. A healthy
run ends with `VERIFIED HEALTHY`.

Dry run (check only, change nothing):

```sh
/bin/zsh ~/watchdog/watcher.sh --dry-run
```

## Uninstall

```sh
./uninstall.sh
```

This unloads and removes all three LaunchAgents, removes the `uchg`
flags, and deletes `~/watchdog`, the backup directory and the support
directory. It does **not** delete your secrets from the Keychain or the
`~/.config/mac-watchdog/secrets` file — remove those yourself if you
want them gone (see [docs/security.md](docs/security.md)).

## Files

The repo is flat on purpose: the scripts, the config template and the
LaunchAgent templates live at the top level, the Swift agent in
`src/recovery-agent/`, the secrets helpers in `lib/` and `scripts/`,
docs in `docs/`, and the release workflow in `.github/workflows/`.
There are **no binaries in this repository**.

## Security

- **Secrets** live in the Keychain (or a `600` file), never in the repo
  and never as plaintext in the watchdog directory. `.gitignore`
  excludes `watchdog.conf`, the secrets file, logs, and anything
  matching `*password*` or `*authkey*`.
- **Source protection.** After install, source files are marked
  `chflags uchg` (user immutable), which resists accidental deletion —
  including by the model. It is not absolute: the owner or root can
  remove the flag. Logs and `watchdog.conf` stay writable.
- **Self-healing.** A backup copy lives outside the watchdog directory,
  and the bootstrap agent (itself installed outside that directory)
  checks every 5 minutes and restores anything missing, including the
  LaunchAgent plists. So a wipe of the watchdog directory can be
  rebuilt from the backup.
- **Only Apple Intelligence.** The model runs entirely on-device via
  Apple's Foundation Models framework. No data leaves the machine for
  inference, no third-party model is involved, and there is no cloud
  component. (The optional Plan B tunnel is plain SSH to a host you
  control.) The model is the same ~3B-parameter model on every
  supported Mac; what differs is speed and context, not the model.
- **Model permissions.** The model gets an unrestricted terminal and,
  when you set it up, sudo and the secrets it needs. That is a
  deliberate trade-off: a watchdog that cannot act cannot heal. It is
  also the largest risk surface in this project — a mistaken command
  can change settings or damage files. Scope it to the machine's
  purpose and keep the machine's own access controls in mind. A future
  version should restrict the model to a fixed set of repair operations.
- **What the model cannot do.** It cannot see the screen, and it cannot
  read files under `~/Documents` from a LaunchAgent (macOS TCC) — which
  is why everything lives in `~/watchdog` and the backup.

Full details: [docs/security.md](docs/security.md).

## Troubleshooting

- **Watcher never runs / no log.** Check the agents:
  `launchctl list | grep macwatchdog`. If one is not loaded, re-run
  `./install.sh`. The log is `~/watchdog/watcher.launchd.log`.
- **Model says `unavailable` / `modelNotReady`.** Apple Intelligence is
  off or the model has not downloaded yet. Enable it in System Settings
  → Apple Intelligence & Siri, wait for the download, and check the
  language: the model requires the system language (or at least Siri)
  to be a supported one.
- **`tailscale up` fails with "The Tailscale GUI failed to start"**
  when run over SSH. That is expected: the GUI app must be running in a
  GUI session. The Watcher runs under launchd in the GUI session, so it
  does not hit this; only manual SSH invocations do.
- **Keychain prompts appear at runtime.** The `-T` grants in
  `setup-secrets.sh` cover `/bin/zsh`, `/bin/sh`, `/usr/bin/security`
  and the recovery-agent. If a prompt still appears, grant access once
  in Keychain Access (or re-run `setup-secrets.sh`).
- **The machine is unreachable and the tunnel is not up.** The tunnel
  only opens after the Watcher gives up (3 failed attempts) — or, with
  `--with-call-home`, it is held open permanently. If the Watcher itself
  cannot run (e.g. the whole directory was wiped and the bootstrap has
  not restored it yet), wait 5–10 minutes for the bootstrap tick. As a
  last resort, the machine needs hands-on access.

## License

MIT — see `LICENSE`. Copyright (c) 2026 Exrector.
