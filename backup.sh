#!/usr/bin/env bash
# backup.sh — Stop Hermes VM en maak backup
# Gebruik: ./backup.sh
#
# Na de backup start je zelf opnieuw:
#   Terminal 1: cd ~/hermes-sandbox && ./result/bin/virtiofsd-run
#   Terminal 2: cd ~/hermes-sandbox && ./result/bin/microvm-run

set -euo pipefail

SANDBOX="$HOME/hermes-sandbox"
BACKUP_DATE=$(date +%Y-%m-%d)
BACKUP_DIR="$HOME/Documents/Hermes-Backup/$BACKUP_DATE"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Hermes Backup ==="
log "Doelmap: $BACKUP_DIR"
echo ""

# ─────────────────────────────────────────────────────────
# 1. STOP DE VM (met graceful agent shutdown)
# ─────────────────────────────────────────────────────────
log "Stap 1/3 — VM afsluiten..."

if pgrep -f "microvm@hermes-agent" > /dev/null 2>&1; then
    # Eerst hermes-agent graceful stoppen voor data integriteit
    if [[ -S "$SANDBOX/control.sock" ]]; then
        log "  Hermes agent graceful stoppen..."

        curl -sf --unix-socket "$SANDBOX/control.sock" \
            -X PUT http://localhost/vm.exec -H "Content-Type: application/json" \
            -d '{"cmd": ["systemctl", "stop", "hermes-agent", "hermes-dashboard"]}' \
            && log "  Agent stop signaal verstuurd"

        # Wacht maximaal 30 seconden
        log "  Wachten op agent shutdown (max 30s)..."
        AGENT_TIMEOUT=30
        AGENT_STOPPED=false

        for i in $(seq 1 $AGENT_TIMEOUT); do
            SERVICES_RUNNING=0

            # Check hermes-agent (poort 3000)
            curl -sf --unix-socket "$SANDBOX/control.sock" \
                -X PUT http://localhost/vm.exec -H "Content-Type: application/json" \
                -d '{"cmd": ["timeout", "1", "bash", "-c", "echo > /dev/tcp/127.0.0.1/3000"]}' > /dev/null 2>&1 && SERVICES_RUNNING=$((SERVICES_RUNNING + 1))

            # Check dashboard (poort 3333)
            curl -sf --unix-socket "$SANDBOX/control.sock" \
                -X PUT http://localhost/vm.exec -H "Content-Type: application/json" \
                -d '{"cmd": ["timeout", "1", "bash", "-c", "echo > /dev/tcp/127.0.0.1/3333"]}' > /dev/null 2>&1 && SERVICES_RUNNING=$((SERVICES_RUNNING + 1))

            if [[ $SERVICES_RUNNING -eq 0 ]]; then
                log "  Alle services gestopt na ${i}s"
                AGENT_STOPPED=true
                break
            fi

            sleep 1

            if [[ $i -eq 15 ]]; then
                log "  Services nemen lang... probeer force stop..."
                curl -sf --unix-socket "$SANDBOX/control.sock" \
                    -X PUT http://localhost/vm.exec -H "Content-Type: application/json" \
                    -d '{"cmd": ["systemctl", "kill", "-s", "SIGKILL", "hermes-agent", "hermes-dashboard"]}' > /dev/null 2>&1
            fi
        done

        if [[ "$AGENT_STOPPED" == false ]]; then
            log "  Agent shutdown timeout — ga door met VM shutdown"
        fi
    fi

    # VM shutdown
    if [[ -S "$SANDBOX/control.sock" ]]; then
        log "  VM shutdown signaal versturen..."
        curl -sf --unix-socket "$SANDBOX/control.sock" \
            -X PUT http://localhost/vm.shutdown > /dev/null \
            && log "  VM shutdown signaal verstuurd"
    fi

    log "  Wachten op VM shutdown (max 30s)..."
    for i in $(seq 1 30); do
        if ! pgrep -f "microvm@hermes-agent" > /dev/null 2>&1; then
            log "  VM gestopt na ${i}s"
            break
        fi
        sleep 1
        if [[ $i -eq 30 ]]; then
            log "  VM shutdown timeout — force kill..."
            pkill -f "microvm@hermes-agent" || true
            sleep 2
        fi
    done
else
    log "  VM was al gestopt"
fi

# ─────────────────────────────────────────────────────────
# 2. STOP VIRTIOFSD
# ─────────────────────────────────────────────────────────
log "Stap 2/3 — virtiofsd stoppen..."

pkill -9 -f "virtiofsd.*hermes" 2>/dev/null || true
pkill -9 -f "supervisord.*hermes" 2>/dev/null || true
sleep 2

# Clean up socket en PID bestanden
rm -f "$SANDBOX"/hermes-agent-virtiofs*.sock
rm -f "$SANDBOX"/hermes-agent-virtiofs*.sock.pid
rm -f "$SANDBOX"/control.sock
rm -f "$SANDBOX"/notify.vsock
rm -f "$SANDBOX"/*.sock "$SANDBOX"/*.sock.pid 2>/dev/null || true

log "  virtiofsd gestopt en alle socket bestanden opgeruimd"

# ─────────────────────────────────────────────────────────
# 3. BACKUP
# ─────────────────────────────────────────────────────────
log "Stap 3/3 — Backup maken..."
mkdir -p "$BACKUP_DIR"

log "  hermes-sandbox/ ..."
rsync -a --info=progress2 \
    --exclude='result' \
    --exclude='*.sock' \
    --exclude='*.sock.pid' \
    --exclude='supervisord.log' \
    --exclude='supervisord.pid' \
    --exclude='notify.vsock' \
    --exclude='control.sock' \
    "$SANDBOX/" "$BACKUP_DIR/hermes-sandbox/"

log "  hermes-workspace/ ..."
rsync -a --info=progress2 \
    "$HOME/hermes-workspace/" "$BACKUP_DIR/hermes-workspace/"

BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)

echo ""
log "=== Backup klaar ==="
log "Locatie: $BACKUP_DIR ($BACKUP_SIZE)"
echo ""
log "Start de omgeving nu zelf opnieuw:"
log "  Terminal 1:  cd ~/hermes-sandbox && ./result/bin/virtiofsd-run"
log "  Terminal 2:  cd ~/hermes-sandbox && ./result/bin/microvm-run"
