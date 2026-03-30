# Hermes Agent MicroVM Setup — Volledige Documentatie

## Overzicht

Dit document beschrijft hoe de hermes-sandbox opgezet is: een NixOS MicroVM met cloud-hypervisor als hypervisor, hermes-agent als AI-agent, Discord als messaging platform, en een Next.js Mission Control dashboard. De setup is gebaseerd op de bestaande openclaw-sandbox infrastructuur en hergebruikt zoveel mogelijk dezelfde aanpak.

---

## Netwerkarchitectuur

Drie VMs draaien parallel op de host, elk in hun eigen subnet:

| VM | TAP interface | Subnet | VM IP | vsock CID |
|---|---|---|---|---|
| nanoclaw | vmtap0 | 10.0.0.0/24 | 10.0.0.2 | — |
| openclaw | vmtap1 | 10.0.1.0/24 | 10.0.1.2 | 42 |
| hermes | vmtap2 | 10.0.2.0/24 | 10.0.2.2 | 43 |

De host fungeert als gateway (10.0.2.1) en NAT-router voor internettoegang vanuit de VM.

---

## Stap 1 — Directorystructuur aanmaken

Op de host twee mappen aanmaken:

```
~/hermes-sandbox/    — Nix flake, scripts, VM-image
~/hermes-workspace/  — Persistente data (gemount in VM via virtiofs)
```

Workspace directories:

```bash
mkdir -p ~/hermes-workspace/{.claude,.npm-global,.hermes/{logs,agents,workspace},dashboard,content/{articles,newsletters,research,scripts}}
```

---

## Stap 2 — Nix Flake

### flake.nix

De volledige NixOS MicroVM configuratie. Kritieke punten:

**Inputs:**
```nix
inputs = {
  nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
  microvm.url    = "github:astro/microvm.nix";
  microvm.inputs.nixpkgs.follows = "nixpkgs";
  hermes-agent.url = "github:NousResearch/hermes-agent";
  hermes-agent.inputs.nixpkgs.follows = "nixpkgs";
};
```

Hermes-agent heeft geen entry in nixpkgs — het is een dedicated flake van NousResearch. De NixOS module zit in `hermes-agent.nixosModules.default`.

**Virtiofsd wrapper (kritiek):**

De standaard virtiofsd accepteert geen `--posix-acl` flag op sommige NixOS versies. De wrapper filtert die flag eruit en herstart virtiofsd automatisch bij een crash:

```nix
virtiofsd.package = pkgs.writeShellScriptBin "virtiofsd" ''
  args=()
  for arg in "$@"; do
    case "$arg" in
      --posix-acl) ;;
      *) args+=( "$arg" ) ;;
    esac
  done
  while true; do
    ${pkgs.virtiofsd}/bin/virtiofsd "''${args[@]}" >> /dev/null 2>&1
    sleep 1
  done
'';
```

**Virtiofs shares:**

```nix
shares = [
  { source = "/nix/store";                   mountPoint = "/nix/store";            tag = "ro-store";     proto = "virtiofs"; }
  { source = hostWorkspace;                  mountPoint = "/home/agent/workspace"; tag = "hermes-data";  proto = "virtiofs"; }
  { source = "${hostWorkspace}/.claude";     mountPoint = "/home/agent/.claude";   tag = "agent-claude"; proto = "virtiofs"; }
  { source = "${hostWorkspace}/.npm-global"; mountPoint = "/home/agent/.npm-global"; tag = "agent-npm";  proto = "virtiofs"; }
];
```

**Kritiek — nix-store-rw.img grootte:**

Oorspronkelijk ingesteld op 2048 MB. Dit is te klein voor de hermes-agent build (Python environment + alle dependencies). Resulteert in `ENFILE` errors en kapotte library-paden waarna geen enkel commando meer werkt. Juiste waarde:

```nix
volumes = [ {
  image      = "nix-store-rw.img";
  mountPoint = "/nix/.rw-store";
  size       = 8192;  # 8GB — minimaal voor hermes-agent
} ];
```

**Agent user (uid/gid = 1000):**

De agent user krijgt uid 1000, gelijk aan de host-gebruiker michiel. Dit is vereist voor schrijfrechten via virtiofs — virtiofs mapt bestandseigenaarschap op basis van UID.

**Root wachtwoord voor noodgevallen:**

```nix
users.users.root.password = "root";
```

Zonder dit is de emergency shell onbereikbaar als de boot mislukt. In NixOS MicroVMs is emergency mode de enige debug-mogelijkheid — altijd toevoegen.

**hermes-agent NixOS module:**

```nix
services.hermes-agent = {
  enable              = true;
  user                = "agent";
  group               = "agent";
  createUser          = false;        # agent user al gedeclareerd
  stateDir            = "/home/agent/workspace/.hermes";
  workingDirectory    = "/home/agent/workspace";
  environmentFiles    = [ "/home/agent/workspace/.env" ];
  addToSystemPackages = true;         # maakt `hermes` CLI beschikbaar in PATH
  settings = {
    model.default = "anthropic/claude-sonnet-4-6";
  };
};
```

**Kritiek — hermes-agent start-volgorde:**

De NixOS module plaatst hermes-agent standaard voor de virtiofs mounts. `stateDir` ligt op de virtiofs mount — als de service start voor de mount beschikbaar is, mislukt hij en blokkeert de boot. Fix via `lib.mkForce`:

```nix
systemd.services.hermes-agent = {
  after    = lib.mkForce [ "network.target" "remote-fs.target" "local-fs.target" ];
  wantedBy = lib.mkForce [ "multi-user.target" ];
  serviceConfig.Restart    = lib.mkOverride 90 "on-failure";
  serviceConfig.RestartSec = lib.mkOverride 90 "10s";
};
```

**Hermes Gateway als system-level service:**

Hermes gateway is een Discord/messaging daemon. `hermes gateway install` installeert normaal een user-level systemd service. Dit werkt niet goed in een NixOS MicroVM omdat:
- User-level services vereisen een D-Bus user session
- `systemctl --user` werkt niet vanuit system service context
- Symlinks naar virtiofs bestanden die via tmpfiles aangemaakt worden kunnen timing-problemen hebben

Oplossing: gateway direct als system service definiëren, draaiend als agent user:

```nix
systemd.services.hermes-gateway = {
  description = "Hermes Agent Gateway - Messaging Platform Integration";
  after       = [ "network.target" "remote-fs.target" "hermes-agent.service" ];
  wantedBy    = [ "multi-user.target" ];
  startLimitIntervalSec = 600;
  startLimitBurst       = 5;
  environment = {
    HERMES_HOME = "/home/agent/workspace/.hermes";
    VIRTUAL_ENV = "${hermesPackage}";
  };
  serviceConfig = {
    Type             = "simple";
    User             = "agent";
    Group            = "agent";
    WorkingDirectory = "/home/agent/workspace";
    ExecStart        = "${hermesPackage}/bin/hermes gateway run --replace";
    Restart          = "on-failure";
    RestartSec       = "30s";
    KillMode         = "mixed";
    KillSignal       = "SIGTERM";
    TimeoutStopSec   = "60s";
    EnvironmentFile  = "/home/agent/workspace/.env";
  };
};
```

`hermesPackage` wordt bovenaan de module gebonden aan `config.services.hermes-agent.package` — zo verwijst de gateway altijd naar exact hetzelfde Python environment als de hermes-agent service.

---

## Stap 3 — Nix-store image aanmaken

```bash
truncate -s 8G ~/hermes-sandbox/nix-store-rw.img
nix-shell -p e2fsprogs --run "mkfs.ext4 ~/hermes-sandbox/nix-store-rw.img"
```

**Kritiek:** het sparse bestand moet geformatteerd worden als ext4 voordat de VM gestart wordt. Zonder mkfs.ext4 geeft de kernel bij boot: `EXT4-fs (vda): VFS: Can't find ext4 filesystem` en gaat de VM in emergency mode.

---

## Stap 4 — Netwerksetup

`setup-network.sh` maakt de TAP interface en NAT aan:

```bash
sudo ./setup-network.sh
```

Inhoud:
```bash
TAP_DEV="vmtap2"
HOST_IP="10.0.2.1"
ip tuntap add dev $TAP_DEV mode tap user $USER_NAME multi_queue
ip addr add $HOST_IP/24 dev $TAP_DEV
ip link set $TAP_DEV up
sysctl net.ipv4.ip_forward=1
INT_IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $INT_IFACE -j MASQUERADE
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $TAP_DEV -o $INT_IFACE -j ACCEPT
```

Na elke reboot van de host opnieuw uitvoeren (niet persistent).

---

## Stap 5 — Git initialiseren en bouwen

**Kritiek:** hermes-sandbox is geen git repo. Nix evalueert de flake door de directory te hashen. Socket-bestanden (`.sock`) van een vorige VM-run hebben een onondersteund bestandstype en laten `nix build` crashen met:

```
error: file '/home/michiel/hermes-sandbox/control.sock' has an unsupported type
```

Oplossing:
```bash
rm -f ~/hermes-sandbox/*.sock ~/hermes-sandbox/*.sock.pid
git init ~/hermes-sandbox
cd ~/hermes-sandbox
git add flake.nix flake.lock setup-network.sh backup.sh .gitignore .claude/settings.local.json
nix build
```

De `.gitignore` bevat `*.sock`, `control.sock`, `nix-store-rw.img`, `result`, etc. Nix respecteert de git-index en negeert alles wat niet getracked is.

---

## Stap 6 — VM starten

Twee terminals vereist:

```bash
# Terminal 1 — virtiofsd (filesystem daemon voor virtiofs shares)
cd ~/hermes-sandbox && ./result/bin/virtiofsd-run

# Terminal 2 — de VM zelf
cd ~/hermes-sandbox && ./result/bin/microvm-run
```

Inloggen als `agent` / `agent`.

---

## Stap 7 — Hermes setup wizard

```bash
hermes setup
```

Keuzes die gemaakt zijn:

| Instelling | Keuze | Reden |
|---|---|---|
| Auth provider | Anthropic (Claude) | Token zat al in .env |
| TTS | Edge TTS | Betere kwaliteit dan NeuTTS, cloud maar geïsoleerde VM |
| Max iterations | 130 | Meer ruimte voor complexe taken |
| Tool progress | all | Voldoende detail voor dashboard, niet te verbose |
| Discord | Ja | Primaire messaging interface |
| Slack/Matrix/WhatsApp | Nee | Niet nodig |
| Webhooks | Ja | GitHub integratie |
| Webhook poort | 8644 | Standaard |
| Firecrawl | Self-hosted (later gewijzigd) | Gratis, maar Docker build mislukte |
| Browser | Local (Chromium) | Al geïnstalleerd in VM |
| Smart Home | Home Assistant op 192.168.1.114:8123 | Direct IP i.p.v. homeassistant.local (mDNS werkt niet via NAT) |

**Kritiek — hermes setup niet in standaard systemd service uitvoeren:**

`hermes setup` schrijft naar `~/.hermes/`. Zorg dat `~/.hermes` symlinkt naar `/home/agent/workspace/.hermes` vóór de setup, anders is de configuratie na een rebuild verdwenen.

```bash
# Vóór setup uitvoeren:
cp -r ~/.hermes/. /home/agent/workspace/.hermes/
rm -rf ~/.hermes
ln -s /home/agent/workspace/.hermes ~/.hermes
```

---

## Stap 8 — Discord bot koppelen

**Probleem 1:** Bot token format.

`hermes setup` sloeg het Discord token op als een hex-string in `~/.hermes/.env`. Dit is geen geldig Discord bot token — de bot verscheen wel in de server (OAuth2 werkt op Client ID) maar reageerde niet (WebSocket-verbinding met Discord mislukte).

Oplossing: Echt token ophalen via Discord Developer Portal:
1. Ga naar discord.com/developers/applications
2. Klik op applicatie → Bot
3. Klik **Reset Token** — kopieer het token (begint met `MTQ4...`)
4. Vervang `DISCORD_BOT_TOKEN` in `~/.hermes/.env`

**Probleem 2:** Bot niet in server.

De bot was aangemaakt maar nog niet uitgenodigd. Invite link formaat:
```
https://discord.com/api/oauth2/authorize?client_id=<APPLICATION_ID>&permissions=8&scope=bot
```

Application ID te vinden via Discord Developer Portal → je applicatie → General Information.

**Probleem 3:** `hermes gateway start` mislukt.

```
Failed to start hermes-gateway.service: Unit hermes-gateway.service not found.
```

`hermes gateway start` probeert een user-level systemd service te starten die nog niet bestaat. Volgorde:
```bash
hermes gateway install   # installeert ~/.config/systemd/user/hermes-gateway.service
hermes gateway start     # start de service
```

Dit is later vervangen door de system-level gateway service in flake.nix (zie boven).

---

## Stap 9 — Persistentie van hermes config

**Probleem:** `~/.hermes/` ligt in de ephemere VM home — verdwijnt na rebuild.

**Oplossing:**
```bash
cp -r ~/.hermes/. /home/agent/workspace/.hermes/
rm -rf ~/.hermes
ln -s /home/agent/workspace/.hermes ~/.hermes
```

Alles in `/home/agent/workspace/` leeft op de virtiofs mount en is persistent op de host in `~/hermes-workspace/`.

---

## Stap 10 — OpenClaw migratie

### Data kopiëren naar hermes-workspace

De openclaw-workspace is niet gemount in de hermes VM. Op de host:

```bash
cp -r ~/openclaw-workspace/.openclaw ~/hermes-workspace/openclaw-import
```

### Migratie skill installeren

```bash
hermes skills install openclaw-migration --force
```

`--force` vereist omdat de security scanner false positives geeft op bestandspaden in de SKILL.md markdown.

**Probleem:** De geïnstalleerde skill bevat alleen `SKILL.md` en `_meta.json` — het Python migratiescript ontbreekt.

Het script zit wel in de Nix store:
```bash
find /nix/store -name "openclaw_to_hermes.py" 2>/dev/null
# → /nix/store/bc7rz10ngvrffi4lc0gcqs3i8713wyzq-source/optional-skills/migration/...
```

Symlink aanmaken:
```bash
mkdir -p ~/.hermes/skills/migration/openclaw-migration/scripts
ln -sf /nix/store/bc7rz10ngvrffi4lc0gcqs3i8713wyzq-source/optional-skills/migration/openclaw-migration/scripts/openclaw_to_hermes.py \
  ~/.hermes/skills/migration/openclaw-migration/scripts/openclaw_to_hermes.py
```

**Probleem:** Kapotte shell-omgeving door volle nix-store-rw.img.

Als de overlay vol zit, werken zelfs basiscommando's niet meer (`mkdir`, `python3`, `df`). Symptoom: `error while loading shared libraries: libXXX.so: No such file or directory` of `Error 23` (ENFILE). Oplossing: zie sectie nix-store-rw.img aanmaken — vergroot naar 8GB.

### Dry-run

```bash
hermes claw migrate --source /home/agent/workspace/openclaw-import --dry-run
```

Output toont: 11 te migreren, 2 conflicten (soul, model — al correct ingesteld).

### Uitvoeren

```bash
hermes claw migrate --source /home/agent/workspace/openclaw-import --preset full
```

Gemigreerd:
- Memories (`MEMORY.md`, `USER.md`)
- Skills (`analytics-query`, `warren-revenue-analytics`)
- Agent config (compression, terminal settings)
- Environment variabelen (`HERMES_GATEWAY_TOKEN`, `DEEPSEEK_API_KEY`)
- Ollama provider configuratie
- Browser configuratie

---

## Stap 11 — Dashboard

Het Next.js dashboard is gekopieerd van `~/openclaw-workspace/dashboard` naar `~/hermes-workspace/dashboard`.

### npm install

```bash
cd /home/agent/workspace/dashboard && npm install
```

### Build problemen en oplossingen

**Probleem 1:** `Module not found: Can't resolve '@/components/Nav'`

Oorzaak: webpack pikt de TypeScript path aliases (`@/*` → `./src/*`) niet op zonder expliciete webpack alias. Oplossing via `next.config.js`:

```js
const path = require('path')
const nextConfig = {
  serverExternalPackages: ['ws', 'bufferutil', 'utf-8-validate'],
  webpack: (config) => {
    config.resolve.alias['@'] = path.resolve(__dirname, 'src')
    return config
  },
}
module.exports = nextConfig
```

**Probleem 2:** `Cannot find module 'tailwindcss'`

Oorzaak: `npm install` installeerde niet alle devDependencies (tailwindcss, postcss, autoprefixer). Oplossing:

```bash
npm install tailwindcss postcss autoprefixer
```

### Dashboard starten

```bash
sudo systemctl start hermes-dashboard
```

Bereikbaar op `http://10.0.2.2:3333` vanuit de host.

**Huidige status:** Dashboard UI werkt volledig. De data-feeds (agents, sessions, memory, stats) zijn nog openclaw-specifiek en tonen geen hermes data. Aanpassing voor hermes state structuur is gepland.

---

## Stap 12 — Firecrawl (niet gelukt)

Tijdens `hermes setup` gekozen voor Firecrawl Self-Hosted als websearch provider (poort 3002). Docker Compose build mislukt:

```
RUN npx playwright install chromium --with-deps
exit code: 1
```

Playwright kan geen Chromium installeren in de Docker container vanwege ontbrekende dpkg dependencies. Firecrawl cloud is niet gratis genoeg (500 pagina's/maand). Web search tool is voorlopig uitgeschakeld.

---

## Services overzicht

| Service | Type | Poort | Auto-start |
|---|---|---|---|
| `hermes-agent` | system | — | ja |
| `hermes-gateway` | system | 8644 | ja |
| `hermes-dashboard` | system | 3333 | ja |
| `docker` | system | — | ja |

Alle services starten automatisch na VM-reboot. Volgorde: virtiofs mounts → hermes-agent → hermes-gateway → hermes-dashboard.

---

## .env configuratie

Locatie: `/home/agent/workspace/.env` (persistent via virtiofs)

```bash
HERMES_STATE_DIR=/home/agent/workspace/.hermes
HERMES_CONFIG_PATH=/home/agent/workspace/.hermes/hermes.json
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
NPM_CONFIG_PREFIX=/home/agent/workspace/.npm-global
WP_STAGING_URL=https://www.logiesopdreef.nl
WP_API_USER=blogger_nouwnow
WP_API_PASSWORD=...
DEEPSEEK_API_KEY=sk-...
GEMINI_API_KEY=...
OLLAMA_API_KEY=ollama-local
```

---

## Dagelijks gebruik

### VM starten (na host-reboot)

```bash
sudo ./setup-network.sh          # TAP interface herstellen
# Terminal 1:
cd ~/hermes-sandbox && ./result/bin/virtiofsd-run
# Terminal 2:
cd ~/hermes-sandbox && ./result/bin/microvm-run
```

### VM stoppen

```bash
./backup.sh   # stopt VM graceful + maakt backup
```

Of via de control socket:
```bash
curl -sf --unix-socket ~/hermes-sandbox/control.sock -X PUT http://localhost/vm.shutdown
```

### Rebuild na flake.nix wijziging

```bash
cd ~/hermes-sandbox
rm -f *.sock *.sock.pid          # socket bestanden blokkeren nix build
nix build
# Herstart VM
```

### Services checken in VM

```bash
systemctl status hermes-agent
systemctl status hermes-gateway
systemctl status hermes-dashboard
journalctl -u hermes-gateway -f   # live logs
```

---

## Veelvoorkomende problemen en oplossingen

| Symptoom | Oorzaak | Oplossing |
|---|---|---|
| `nix build` faalt met "unsupported type" | Socket-bestand in sandbox-dir | `rm -f *.sock` + git init |
| Emergency mode bij boot | Diverse: zie volgende rijen | Login als root / root, `journalctl -xb` |
| `EXT4-fs: Can't find ext4 filesystem` | nix-store-rw.img niet geformatteerd | `mkfs.ext4 nix-store-rw.img` |
| `libXXX.so: No such file or directory` op alle commando's | nix-store-rw.img vol (2GB te klein) | Recreëer als 8GB + mkfs.ext4 |
| hermes-agent start voor virtiofs mount | Standaard module volgorde | `lib.mkForce` op `after` en `wantedBy` |
| `hermes` command not found | addToSystemPackages niet ingesteld | `addToSystemPackages = true` in services.hermes-agent |
| Discord bot reageert niet | Hex token i.p.v. echt bot token | Reset token via Developer Portal |
| `hermes gateway start` mislukt | User-level service bestaat niet | `hermes gateway install` eerst, of gebruik system service in flake.nix |
| Dashboard bouwt niet: Nav not found | Webpack pikt tsconfig paths niet op | Expliciete alias in next.config.js |
| Dashboard bouwt niet: tailwindcss missing | npm install mist devDependencies | `npm install tailwindcss postcss autoprefixer` |
| homeassistant.local niet bereikbaar | mDNS werkt niet via NAT | Gebruik direct IP-adres (192.168.1.114:8123) |

---

## Toekomstig werk

- **Dashboard aanpassen voor hermes:** API routes vervangen die nu `.openclaw/` paden en openclaw gateway WebSocket gebruiken
- **Firecrawl alternatief:** SearXNG self-hosted of andere gratis websearch provider
- **OpenClaw import integratie:** Hermes heeft een `claw` command voor verdere integratie met de draaiende openclaw omgeving
