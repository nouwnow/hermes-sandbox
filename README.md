<div align="center">

# Hermes Sandbox

**A hypervisor-isolated AI agent with persistent memory, skills, and Discord integration — controlled entirely from your terminal or phone.**

*Built on [Hermes Agent](https://github.com/NousResearch/hermes-agent) + [NixOS MicroVM](https://github.com/astro/microvm.nix). Declarative, reproducible, and migration-ready from OpenClaw.*

---

[![NixOS](https://img.shields.io/badge/NixOS-MicroVM-7B5EA7?style=for-the-badge&logo=nixos)](https://github.com/astro/microvm.nix)
[![Hypervisor](https://img.shields.io/badge/Isolation-cloud--hypervisor-blue?style=for-the-badge&logo=linux)](https://github.com/cloud-hypervisor/cloud-hypervisor)
[![Discord](https://img.shields.io/badge/Interface-Discord-5865F2?style=for-the-badge&logo=discord)](https://discord.com)
[![Hermes](https://img.shields.io/badge/Agent-Hermes_Agent-orange?style=for-the-badge)](https://github.com/NousResearch/hermes-agent)
[![Claude](https://img.shields.io/badge/Auth-Claude_Subscription-CC785C?style=for-the-badge)](https://claude.ai)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

</div>

---

## Table of Contents

- [Why This Exists](#why-this-exists)
- [OpenClaw vs Hermes — What Changed](#openclaw-vs-hermes--what-changed)
- [What You Get](#what-you-get)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Daily Use](#daily-use)
- [How the Filesystem Bridge Works](#how-the-filesystem-bridge-works)
- [Hermes Setup Wizard](#hermes-setup-wizard)
- [Skills & Memory](#skills--memory)
- [Discord & Gateway](#discord--gateway)
- [Mission Control Dashboard](#mission-control-dashboard)
- [Migrating from OpenClaw](#migrating-from-openclaw)
- [Configuration](#configuration)
- [Persistent Network](#persistent-network)
- [Project Structure](#project-structure)
- [Lessons Learned](#lessons-learned)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Related Projects](#related-projects)

---

## Why This Exists

[Hermes Agent](https://github.com/NousResearch/hermes-agent) by NousResearch is a powerful open-source AI agent with persistent memory, a rich skills system, multi-platform messaging, and scheduled automations. But like any capable agent, it benefits from isolation — you don't want an agent with full tool access running directly on your host.

This sandbox wraps Hermes in a **NixOS MicroVM** with **cloud-hypervisor** — giving you true hypervisor-level isolation. The agent can only see what you explicitly share via virtiofs. The entire environment is declarative: one `flake.nix` defines every package, service, user, and mount — reproducibly, version-locked via `flake.lock`.

The result: Hermes Agent's full capabilities — memory, skills, Discord, webhooks, Home Assistant, browser automation — without touching your host system.

> **Coming from OpenClaw?**
> See [Migrating from OpenClaw](#migrating-from-openclaw) — Hermes has a built-in `hermes claw migrate` command that imports your memories, skills, and config.

> **Looking for a lighter single-agent setup?**
> See [nanoclaw-sandbox](https://github.com/nouwnow/nanoclaw-sandbox) — the same hypervisor isolation for a minimal Telegram bot.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## OpenClaw vs Hermes — What Changed

This project is a direct successor to [openclaw-sandbox](https://github.com/nouwnow/openclaw-sandbox). The isolation architecture (NixOS MicroVM, cloud-hypervisor, virtiofs) is identical. What's inside the VM is different.

| | OpenClaw | Hermes Agent |
|---|---|---|
| **Language** | Node.js | Python |
| **Agent model** | Multi-agent executive team (COO/CTO/CMO/CRO) | Single powerful agent + delegation |
| **Memory** | Custom MEMORY.md + agent config files | Native memory system (state.db + SOUL.md) |
| **Skills** | Custom via `skills_spawn` | Built-in skills marketplace (`hermes skills`) |
| **Messaging** | Discord only | Discord, Telegram, Slack, WhatsApp, Matrix |
| **Routing** | Multi-gateway, agent bindings per channel | Single gateway, smart model routing |
| **Model config** | Buried in `openclaw.json` | `hermes model` interactive CLI |
| **Auth (Anthropic)** | `auth-profiles.json` (manual) | Claude subscription / `ANTHROPIC_TOKEN` (auto) |
| **Sessions** | Persistent per agent workspace | `hermes sessions list/stats` |
| **Automations** | `cron/` directory | `hermes cron` + skills |
| **Dashboard** | Mission Control (Next.js, port 3333) | Mission Control (Next.js, port 3333, ported) |
| **Subnet** | 10.0.1.x | 10.0.2.x |
| **Nix store size** | 4 GB sufficient | **8 GB minimum** (Python env is larger) |

**Advantages of Hermes over OpenClaw:**

- **Simpler config** — one `hermes model` command replaces digging through `openclaw.json`
- **Built-in memory** — structured long-term memory without manual MEMORY.md management
- **Skills marketplace** — install, update, and manage tools via CLI
- **Multi-platform** — Discord is one of many supported platforms, not a hard dependency
- **Anthropic auth** — works directly with Claude Pro/Max subscription, no `auth-profiles.json` needed
- **Active upstream** — NousResearch ships frequent updates; `hermes config migrate` handles upgrades

**Advantages of OpenClaw (things you give up):**

- **True multi-agent team** — OpenClaw's COO/CTO/CMO/CRO architecture with live Discord thread binding per sub-agent has no direct equivalent in Hermes (Hermes has delegation but no persistent named agents)
- **Per-agent workspaces** — each OpenClaw agent had an isolated workspace directory; Hermes uses a single shared workspace
- **Node.js ecosystem** — if you relied on OpenClaw plugins or custom Node.js skills, they don't port directly

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## What You Get

```
You (Discord / Telegram / CLI)
    │
    ▼
Hermes Agent 🤖
    ├── Persistent memory (state.db + MEMORY.md)
    ├── Skills system (web, terminal, file, browser, home automation...)
    ├── Scheduled automations (hermes cron)
    ├── Webhook receiver (port 8644, GitHub etc.)
    ├── Home Assistant integration (192.168.1.114:8123)
    ├── Browser automation (local Chromium)
    └── Mission Control dashboard (port 3333)
         │
         ▼
    ~/hermes-workspace/   (persistent via virtiofs)
```

**From Discord:**
```
@hermes schrijf een samenvatting van de afgelopen week
@hermes check of de website bereikbaar is en geef een SEO audit
@hermes zet mijn Home Assistant scene "avond" aan
@hermes plan elke maandag een weekrapportage om 09:00
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Architecture

```
Host (Linux)
└── NixOS MicroVM (cloud-hypervisor, 8GB RAM, 4 vCPU)
    ├── hermes-agent service     (stateDir: /home/agent/workspace/.hermes)
    ├── hermes-gateway service   (port 8644) ← Discord / webhooks
    ├── hermes-dashboard         (port 3333) ← Mission Control web UI
    └── virtiofs mounts
        ├── /nix/store              → host Nix store (read-only)
        ├── /home/agent/workspace   → ~/hermes-workspace (read-write, persistent)
        ├── /home/agent/.claude     → ~/hermes-workspace/.claude
        └── /home/agent/.npm-global → ~/hermes-workspace/.npm-global
```

**Network:**
```
Host (10.0.2.1 / vmtap2)
    │
    ▼
VM  (10.0.2.2)
    ├── hermes-gateway  :8644
    └── hermes-dashboard :3333

Access from host:
  http://10.0.2.2:3333  — Mission Control dashboard
  http://10.0.2.2:8644  — webhook endpoint
```

**Three VMs, three subnets (on the same host):**

| VM | TAP | Subnet | IP | vsock CID |
|---|---|---|---|---|
| nanoclaw | vmtap0 | 10.0.0.x | 10.0.0.2 | — |
| openclaw | vmtap1 | 10.0.1.x | 10.0.1.2 | 42 |
| **hermes** | vmtap2 | 10.0.2.x | 10.0.2.2 | 43 |

**Isolation model:**
- The VM runs under cloud-hypervisor — hardware-level separation from the host
- The agent user (uid 1000) can only write to the virtiofs workspace
- No SSH, no host network access beyond the tap interface
- `/nix/store` is shared read-only — no redundant downloads, fast builds

**Declarative:** The entire VM — packages, services, users, mounts — is defined in `flake.nix`. Rebuild with `nix build`. Version-locked via `flake.lock`.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Requirements

- **Host OS:** Linux (Ubuntu 22.04+ / Debian 12+ / NixOS)
- **RAM:** 12 GB minimum (VM uses 8 GB)
- **Disk:** 25 GB free (Hermes Python environment is larger than OpenClaw's Node.js env)
- **KVM:** required (`/dev/kvm` accessible)
- **Nix:** with flakes enabled
- **Accounts:** [Claude](https://claude.ai) Pro or Max subscription (or Anthropic API key), Discord bot

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/nouwnow/hermes-sandbox
cd hermes-sandbox

# 2. Install Nix (skip if already installed)
curl -L https://nixos.org/nix/install | sh
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# 3. KVM access
sudo usermod -aG kvm $USER  # log out and back in

# 4. Workspace
mkdir -p ~/hermes-workspace/{.claude,.npm-global,.hermes/{logs,agents,workspace},dashboard,content/{articles,newsletters,research,scripts}}

# 5. Disk image — 8GB minimum (Python env requires this)
truncate -s 8G nix-store-rw.img
nix-shell -p e2fsprogs --run "mkfs.ext4 nix-store-rw.img"

# 6. Build the VM
nix build  # first time: 15–40 min

# 7. Network
sudo ./setup-network.sh

# 8. Start
./result/bin/virtiofsd-run   # terminal 1 — keep open
./result/bin/microvm-run     # terminal 2 — login: agent / agent
```

Then follow [Hermes Setup Wizard](#hermes-setup-wizard) inside the VM.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Installation

<details>
<summary>⚙️ Steps 1–4: Host preparation</summary>

### Step 1 — Host dependencies

```bash
sudo apt update && sudo apt install -y git curl iptables qemu-utils acl e2fsprogs
```

### Step 2 — Install Nix

```bash
curl -L https://nixos.org/nix/install | sh
. ~/.nix-profile/etc/profile.d/nix.sh
```

Enable flakes:
```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### Step 3 — KVM access

```bash
sudo usermod -aG kvm $USER
# Log out and back in, then verify:
id | grep kvm
```

### Step 4 — Check UID/GID

```bash
id
# uid=1000(yourname) ...
```

If your uid/gid is **not** 1000, edit `flake.nix`:
```nix
users.groups.agent.gid = <your-gid>;
users.users.agent.uid  = <your-uid>;
```

> virtiofs maps file ownership by UID. If the VM uid doesn't match your host uid, the agent won't be able to write to the shared workspace.

</details>

<details>
<summary>🖥️ Steps 5–8: Build and start the VM</summary>

### Step 5 — Create workspace

```bash
mkdir -p ~/hermes-workspace/{.claude,.npm-global,.hermes/{logs,agents,workspace},dashboard,content/{articles,newsletters,research,scripts}}
chmod 755 ~/hermes-workspace
```

### Step 6 — Create disk image

```bash
cd ~/hermes-sandbox
truncate -s 8G nix-store-rw.img
nix-shell -p e2fsprogs --run "mkfs.ext4 nix-store-rw.img"
```

> **Critical:** The image must be formatted as ext4 before the VM starts. `truncate` alone is not enough — without `mkfs.ext4` the kernel will refuse to mount it and drop to emergency mode.

> **Critical:** 8 GB is the minimum. The Hermes Agent Python environment with all dependencies requires more space than OpenClaw's Node.js stack. With 2 GB you will hit `ENFILE` errors that corrupt the library paths and break every command in the VM.

### Step 7 — Build the VM

```bash
nix build
```

First build: 15–40 minutes (downloads hermes-agent flake + Python environment). Produces `./result/bin/microvm-run` and `./result/bin/virtiofsd-run`.

> If `nix build` fails with `file '...' has an unsupported type`: you have a stale socket file from a previous VM run. Fix: `rm -f *.sock *.sock.pid && nix build`

### Step 8 — Configure network

```bash
sudo ./setup-network.sh
```

> **After every host reboot:** run `sudo ./setup-network.sh` again — TAP interfaces and NAT rules don't persist across reboots. See [Persistent Network](#persistent-network) to automate this.

</details>

<details>
<summary>🤖 Steps 9–12: Start the VM and configure Hermes</summary>

### Step 9 — Start the VM

```bash
./result/bin/virtiofsd-run   # terminal 1 — filesystem bridge (keep open)
./result/bin/microvm-run     # terminal 2 — VM console, login: agent / agent
```

### Step 10 — Persist hermes config directory

Inside the VM, run this once before any `hermes setup`:

```bash
# Ensure ~/.hermes points to the persistent workspace (survives rebuilds)
cp -r ~/.hermes/. /home/agent/workspace/.hermes/ 2>/dev/null || true
rm -rf ~/.hermes
ln -s /home/agent/workspace/.hermes ~/.hermes
```

> Without this symlink, all hermes configuration written by `hermes setup` lives in the ephemeral VM home — it will be gone after the next `nix build`.

### Step 11 — Configure credentials

Create `/home/agent/workspace/.env` with your API keys/tokens:

```bash
# In the VM:
nano /home/agent/workspace/.env
```

Minimum required:
```bash
# Anthropic — use one of these:
ANTHROPIC_TOKEN=sk-ant-oat01-...      # Claude Pro/Max OAuth token
# OR
ANTHROPIC_API_KEY=sk-ant-...          # Anthropic API key

HERMES_STATE_DIR=/home/agent/workspace/.hermes
HERMES_CONFIG_PATH=/home/agent/workspace/.hermes/hermes.json
NPM_CONFIG_PREFIX=/home/agent/workspace/.npm-global
```

> Get your `ANTHROPIC_TOKEN` via `claude setup-token` inside the VM (requires Claude Code in PATH, which is mounted from `.npm-global`).

### Step 12 — Run the setup wizard

```bash
hermes setup
```

See [Hermes Setup Wizard](#hermes-setup-wizard) for the full walkthrough.

</details>

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Daily Use

### VM opstarten

```bash
# Terminal 1 — filesystem bridge (open laten)
./result/bin/virtiofsd-run

# Terminal 2 — VM console
./result/bin/microvm-run
# login: agent / agent
```

### Services checken

```bash
systemctl status hermes-agent
systemctl status hermes-gateway
systemctl status hermes-dashboard
```

### Live logs

```bash
journalctl -u hermes-agent   -f
journalctl -u hermes-gateway -f
journalctl -u hermes-dashboard -f
```

### Hermes CLI (in de VM)

```bash
hermes                          # interactieve chat
hermes chat -q "Wat is de status van mijn taken?"
hermes sessions list            # recente sessies
hermes sessions stats           # statistieken
hermes model                    # model/provider wisselen
hermes config show              # volledige configuratie
hermes skills list              # geïnstalleerde skills
hermes cron list                # geplande taken
```

### VM stoppen

```bash
./backup.sh                     # graceful stop + backup

# Of direct via control socket:
curl -sf --unix-socket ~/hermes-sandbox/control.sock -X PUT http://localhost/vm.shutdown
```

### Rebuild na flake.nix wijziging

```bash
cd ~/hermes-sandbox
rm -f *.sock *.sock.pid         # socket files blokkeren nix build
nix build
# Herstart VM
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## How the Filesystem Bridge Works

When you run `./result/bin/virtiofsd-run`, you're starting the bridge that makes your host directories available inside the VM — securely, without network overhead, at near-native speed.

### The virtiofsd wrapper

`microvm.nix` always passes `--posix-acl` when launching virtiofsd — a flag that some virtiofsd versions don't support, causing an immediate crash. We replace the virtiofsd binary with a shell script that silently drops that flag:

```bash
# flake.nix — virtiofsd.package (simplified)
for arg in "$@"; do
  case "$arg" in
    --posix-acl) ;;           # drop silently
    *) args+=( "$arg" ) ;;
  esac
done
while true; do
  virtiofsd "${args[@]}" >> /dev/null 2>&1   # run real binary
  sleep 1                                     # restart after clean VM reboot
done
```

The `while true` loop means that when the VM reboots cleanly, virtiofsd exits and immediately restarts — so the filesystem bridge is ready before the VM finishes its boot sequence.

### What gets mounted where

```
Host directory                     → VM mount point                  → Used by
─────────────────────────────────────────────────────────────────────────────────────
~/hermes-workspace                 → /home/agent/workspace           → hermes state, content, all agent data
~/hermes-workspace/.claude         → /home/agent/.claude             → Claude Code auth + credentials
~/hermes-workspace/.npm-global     → /home/agent/.npm-global         → claude binary + npm packages
/nix/store                         → /nix/store (read-only)          → all NixOS packages, shared with host
```

**Why `/nix/store` is shared read-only:** No package is downloaded twice across VMs. Nanoclaw, openclaw, and hermes all share the same Nix store on the host — fast builds, minimal disk use, clean isolation boundary.

**Log bloat:** virtiofsd defaults to `--log-level=debug`. In an active setup this generates gigabytes per hour. This sandbox forces `--log-level=error` and redirects output to `/dev/null`:

```nix
virtiofsd.extraArgs = [ "--sandbox=none" "--log-level=error" ];
# wrapper redirects to /dev/null, not a file
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Hermes Setup Wizard

Run `hermes setup` inside the VM. These are the choices made for this setup and why:

| Setting | Choice | Reason |
|---|---|---|
| Auth provider | Anthropic (Claude) | Claude Pro/Max subscription, no API key billing |
| TTS | Edge TTS | Better quality than NeuTTS, acceptable cloud dependency in isolated VM |
| Max iterations | 130 | Headroom for complex multi-step tasks |
| Tool progress | all | Enough detail for dashboard monitoring |
| Discord | Yes | Primary messaging interface |
| Slack / Matrix / WhatsApp | No | Not needed |
| Webhooks | Yes | GitHub integration |
| Webhook port | 8644 | Default |
| Web search | Disabled | Firecrawl self-hosted build failed (see [Lessons Learned](#lessons-learned)) |
| Browser | Local Chromium | Pre-installed in VM |
| Home Assistant | Yes — `http://192.168.1.114:8123` | Direct IP instead of `homeassistant.local` — mDNS doesn't resolve through NAT |

> **Critical:** Run `hermes setup` only after you've created the `~/.hermes → /home/agent/workspace/.hermes` symlink (Step 10 in [Installation](#installation)). Otherwise config is written to ephemeral storage and lost on the next rebuild.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Skills & Memory

### Installing skills

```bash
hermes skills list                          # what's installed
hermes skills install <skill-name>          # install a skill
hermes skills install <skill-name> --force  # force install (bypasses security scanner false positives on file paths)
hermes skills update                        # update all skills
```

### Memory

Hermes maintains two types of persistent memory:

- **`MEMORY.md`** — facts, context, and learned preferences (written automatically)
- **`SOUL.md`** — the agent's core personality and operating principles (editable)

Both live in `~/hermes-workspace/.hermes/` and survive VM rebuilds.

```bash
cat ~/.hermes/memories/MEMORY.md   # inspect what hermes remembers
hermes                             # ask: "what do you remember about X?"
```

### Sessions

```bash
hermes sessions list                # recent sessions
hermes sessions list --limit 50
hermes sessions stats               # message counts, db size
hermes --continue                   # resume last session
hermes --resume <session_id>        # resume specific session
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Discord & Gateway

### Discord bot setup

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Create application → Bot → **Reset Token** — copy the token (starts with `MTQ...`)
3. Add `DISCORD_BOT_TOKEN=MTQ...` to `/home/agent/workspace/.hermes/.env`
4. Invite the bot: `https://discord.com/api/oauth2/authorize?client_id=<APPLICATION_ID>&permissions=8&scope=bot`

> **Common mistake:** `hermes setup` stores the Discord token as a hex string — this is not a valid bot token. The bot will appear online (OAuth works) but won't respond (WebSocket fails). Always reset and re-copy the token from the Developer Portal.

### Gateway service

The gateway runs as a **system-level** service (not user-level), which matters in a NixOS MicroVM:

```bash
systemctl status hermes-gateway
journalctl -u hermes-gateway -f

# Restart after config change:
systemctl restart hermes-gateway
```

The gateway is defined directly in `flake.nix` as a `systemd.services` entry running as the `agent` user. This avoids the D-Bus user session dependency that `hermes gateway install` creates.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Mission Control Dashboard

The Next.js dashboard runs as a systemd service on port 3333:

```
http://10.0.2.2:3333
```

```bash
systemctl status hermes-dashboard
journalctl -u hermes-dashboard -f
```

**Note:** The dashboard was ported from the openclaw-sandbox. The UI is fully functional but some data feeds (agents, sessions, stats) are still openclaw-specific and show no hermes data. Updating the API routes to read from hermes state (`/home/agent/workspace/.hermes/`) is planned.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Migrating from OpenClaw

Hermes has a built-in migration command that imports OpenClaw data. Here's the full procedure:

### Step 1 — Copy openclaw data to hermes workspace

On the **host** (not in the VM):

```bash
cp -r ~/openclaw-workspace/.openclaw ~/hermes-workspace/openclaw-import
```

### Step 2 — Install the migration skill

Inside the hermes VM:

```bash
hermes skills install openclaw-migration --force
```

> `--force` is required — the security scanner flags file paths in `SKILL.md` as false positives.

### Step 3 — Verify the migration script is present

```bash
# The skill installs SKILL.md and _meta.json but not always the Python script:
ls ~/.hermes/skills/migration/openclaw-migration/scripts/

# If the script is missing, find it in the Nix store:
find /nix/store -name "openclaw_to_hermes.py" 2>/dev/null
# → /nix/store/<hash>-source/optional-skills/migration/.../openclaw_to_hermes.py

# Create the symlink:
mkdir -p ~/.hermes/skills/migration/openclaw-migration/scripts
ln -sf /nix/store/<hash>-source/optional-skills/migration/openclaw-migration/scripts/openclaw_to_hermes.py \
  ~/.hermes/skills/migration/openclaw-migration/scripts/openclaw_to_hermes.py
```

### Step 4 — Dry run

```bash
hermes claw migrate --source /home/agent/workspace/openclaw-import --dry-run
```

Review what will be imported. Conflicts on `soul` and `model` are expected if you've already run `hermes setup`.

### Step 5 — Execute migration

```bash
hermes claw migrate --source /home/agent/workspace/openclaw-import --preset full
```

**What gets migrated:**

| Data | Migrated |
|---|---|
| Memories (`MEMORY.md`, `USER.md`) | ✅ |
| Skills | ✅ |
| Agent config (compression, terminal settings) | ✅ |
| Environment variables (`HERMES_GATEWAY_TOKEN`, `DEEPSEEK_API_KEY`) | ✅ |
| Ollama provider configuration | ✅ |
| Browser configuration | ✅ |

**What does NOT migrate:**

| Data | Reason |
|---|---|
| Multi-agent team (COO/CTO/CMO/CRO) | Hermes uses a single-agent model with delegation — no persistent named agents |
| Per-agent workspaces | Hermes uses one shared workspace |
| OpenClaw gateway config / Discord thread bindings | Different gateway architecture |
| Custom Node.js plugins | Python-only in Hermes |

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Configuration

### Key files

| File | Location (VM) | Location (host) | Purpose |
|---|---|---|---|
| `config.yaml` | `~/.hermes/config.yaml` | `~/hermes-workspace/.hermes/config.yaml` | Main agent config |
| `.env` (hermes) | `~/.hermes/.env` | `~/hermes-workspace/.hermes/.env` | API keys, tokens, Discord config |
| `.env` (workspace) | `/home/agent/workspace/.env` | `~/hermes-workspace/.env` | Service env vars (loaded by systemd) |
| `SOUL.md` | `~/.hermes/SOUL.md` | `~/hermes-workspace/.hermes/SOUL.md` | Agent personality |

### Model & provider

```bash
hermes model                                          # interactive selection
hermes model set anthropic/claude-sonnet-4-6          # set directly
hermes config show                                    # view full config
hermes config set model.default anthropic/claude-sonnet-4-6
```

### Smart model routing (optional)

Edit `config.yaml` to route simple messages to a cheaper model:

```yaml
smart_model_routing:
  cheap_model:
    provider: openrouter
    model: google/gemini-2.5-flash
```

### flake.nix — NixOS module settings

The `services.hermes-agent` block in `flake.nix` controls the systemd service:

```nix
services.hermes-agent = {
  enable           = true;
  user             = "agent";
  group            = "agent";
  createUser       = false;
  stateDir         = "/home/agent/workspace/.hermes";
  workingDirectory = "/home/agent/workspace";
  environmentFiles = [ "/home/agent/workspace/.env" ];
  addToSystemPackages = true;    # makes `hermes` available in PATH system-wide
  settings = {
    model.default = "anthropic/claude-sonnet-4-6";
  };
};
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Persistent Network

The TAP interface and NAT rules created by `setup-network.sh` are lost on every host reboot. To make them permanent, create a systemd service on the host:

```bash
sudo tee /etc/systemd/system/hermes-network.service <<'EOF'
[Unit]
Description=Hermes VM network setup
After=network.target

[Service]
Type=oneshot
ExecStart=/home/michiel/hermes-sandbox/setup-network.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now hermes-network.service
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Project Structure

```
hermes-sandbox/
├── flake.nix             — entire VM definition (packages, services, mounts, users)
├── flake.lock            — version-locked inputs
├── setup-network.sh      — TAP interface + NAT setup (run after host reboot)
├── backup.sh             — graceful VM shutdown + workspace backup
├── nix-store-rw.img      — writable ext4 overlay for /nix/.rw-store (8GB, gitignored)
├── result/               — nix build output (gitignored, symlink)
│   └── bin/
│       ├── microvm-run   — start the VM
│       └── virtiofsd-run — start the filesystem bridge
├── HERMES-SETUP.md       — full setup documentation, pitfalls, and decisions
└── README.md             — this file

~/hermes-workspace/       — persistent data (virtiofs-mounted at /home/agent/workspace)
├── .hermes/              — hermes state dir (config.yaml, .env, state.db, skills, memory)
├── .claude/              — Claude Code credentials
├── .npm-global/          — claude binary + npm packages
├── dashboard/            — Mission Control Next.js app
└── content/              — agent output (articles, research, scripts)
```

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Lessons Learned

These are hard-won discoveries from the build process. Each one caused at least one broken VM.

**`nix-store-rw.img` must be 8 GB, not 2 GB**

The Hermes Agent Python environment (Python 3.11 + all dependencies) requires significantly more overlay space than OpenClaw's Node.js stack. With 2 GB, the overlay fills silently. The first symptom is `ENFILE` (too many open files) or `No such file or directory` on library paths — not a helpful "disk full" error. Every command in the VM stops working. Fix: recreate the image at 8 GB and format it fresh with `mkfs.ext4`.

**`~/.hermes` must be symlinked before running `hermes setup`**

Hermes writes config to `~/.hermes/`. In the VM, `~` is the ephemeral home — lost on rebuild. Without the symlink `~/.hermes → /home/agent/workspace/.hermes`, a complete `hermes setup` run produces zero persistent output.

**hermes-agent must start after virtiofs mounts**

The NixOS module places hermes-agent in the default service start order — before `remote-fs.target`. Since `stateDir` lives on the virtiofs mount, the service fails to start and the mount dependency deadlocks the boot. Fix: `lib.mkForce` on the `after` and `wantedBy` keys.

**hermes gateway as user-level vs system-level service**

`hermes gateway install` installs a user-level systemd service. User-level services require a D-Bus user session which doesn't exist in a NixOS MicroVM system context. Result: `hermes gateway start` fails with `Unit not found`. Fix: define the gateway directly as `systemd.services.hermes-gateway` in `flake.nix`, running as the `agent` user at system level.

**Discord bot token format**

`hermes setup` stores the Discord token as a hex string. This is not a valid Discord bot token. The bot will appear online (OAuth with Application ID works) but will never respond (WebSocket authentication to Discord's gateway fails silently). Always retrieve the real token from the Discord Developer Portal → Bot → Reset Token.

**Firecrawl self-hosted build fails in Docker**

The Firecrawl Docker image runs `npx playwright install chromium --with-deps` during build. Inside the container this fails because `dpkg` and system dependencies are unavailable. The cloud version is limited to 500 pages/month. Web search is currently disabled; SearXNG is the planned alternative.

**mDNS doesn't resolve through NAT**

`homeassistant.local` doesn't resolve from the VM — mDNS (Avahi/Bonjour) multicast doesn't traverse the NAT gateway. Use the direct IP address (`192.168.1.114:8123`) instead.

**Socket files break `nix build`**

Nix evaluates the flake by hashing the directory. Socket files (`.sock`) have an unsupported type and cause `nix build` to fail with `file '...' has an unsupported type`. Fix: `rm -f *.sock *.sock.pid` before every build, or use git (Nix respects `.gitignore` which excludes `*.sock`).

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `nix build` fails: "unsupported type" | Socket file in sandbox dir | `rm -f *.sock *.sock.pid` |
| Emergency mode at boot | Various — see below | Login as root / root, `journalctl -xb` |
| `EXT4-fs: Can't find ext4 filesystem` | `nix-store-rw.img` not formatted | `mkfs.ext4 nix-store-rw.img` |
| `libXXX.so: No such file or directory` on all commands | `nix-store-rw.img` full (2 GB too small) | Recreate at 8 GB + `mkfs.ext4` |
| hermes-agent starts before virtiofs mount | Default NixOS module service order | `lib.mkForce` on `after` and `wantedBy` |
| `hermes` command not found | `addToSystemPackages` not set | Add `addToSystemPackages = true` in `services.hermes-agent` |
| `hermes model` — no inference provider | `~/.hermes/.env` missing or symlink not set | Check symlink + verify keys in `~/.hermes/.env` |
| Discord bot online but not responding | Hex string stored instead of real token | Reset token in Discord Developer Portal |
| `hermes gateway start` fails | User-level service not installed | Use system-level service in `flake.nix` |
| `homeassistant.local` not reachable | mDNS doesn't traverse NAT | Use `192.168.1.114:8123` |
| Config lost after rebuild | `~/.hermes` not symlinked | `ln -s /home/agent/workspace/.hermes ~/.hermes` |
| Dashboard shows no hermes data | API routes still read openclaw paths | Update dashboard API routes to read `.hermes/` |

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## FAQ

**Can I run hermes and openclaw simultaneously?**

Yes. They use separate TAP interfaces (vmtap1 for openclaw, vmtap2 for hermes) and separate subnets (10.0.1.x and 10.0.2.x). Start both virtiofsd-run scripts and both microvm-run scripts in separate terminals.

**Can I use an API key instead of a Claude subscription?**

Yes. Set `ANTHROPIC_API_KEY=sk-ant-...` in `~/hermes-workspace/.hermes/.env`. The `ANTHROPIC_TOKEN` (OAuth) approach is for Claude Pro/Max subscribers who want to avoid per-token billing.

**How do I update Hermes Agent?**

```bash
cd ~/hermes-sandbox
nix flake update hermes-agent   # pull latest upstream
nix build
hermes config migrate            # apply any new config options interactively
```

**Where is everything stored after a VM rebuild?**

Everything in `~/hermes-workspace/` persists — it's on your host filesystem, mounted into the VM via virtiofs. The VM itself is stateless except for the `nix-store-rw.img` overlay (which holds installed Nix packages, not your data).

**Why is the first `nix build` so slow?**

Hermes Agent's flake pulls a full Python 3.11 environment with dozens of dependencies. Subsequent builds are fast because Nix caches everything in `/nix/store`.

<sub>[↑ Back to top](#table-of-contents)</sub>

---

## Related Projects

- [openclaw-sandbox](https://github.com/nouwnow/openclaw-sandbox) — predecessor: multi-agent executive team (COO/CTO/CMO/CRO) in the same NixOS MicroVM pattern
- [nanoclaw-sandbox](https://github.com/nouwnow/nanoclaw-sandbox) — minimal single-agent Telegram bot with the same hypervisor isolation
- [hermes-agent](https://github.com/NousResearch/hermes-agent) — upstream Hermes Agent by NousResearch
- [microvm.nix](https://github.com/astro/microvm.nix) — NixOS MicroVM framework
- [cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) — the hypervisor used for VM isolation

<sub>[↑ Back to top](#table-of-contents)</sub>
