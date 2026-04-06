#!/bin/bash
# migrate-to-per-vm.sh — Migration von Shared-K8s (VM 500) zu Per-VM-Architektur
#
# Migriert bestehende Workloads aus dem k3s-Testcluster (VM 500, 192.168.10.150)
# in die neue Per-VM-Architektur. Paralleler Betrieb waehrend Migration.
#
# Voraussetzung:
#   - Admin-Service (LXC 160) laeuft
#   - VM-Template (9003) erstellt
#   - Admin-VM (192.168.10.155) provisioniert
#   - Netzwerk-Isolation (setup-network-isolation.sh) konfiguriert
#
# Ausfuehren auf dem Proxmox-Host.
# Verwendung: bash scripts/migrate-to-per-vm.sh [phase]
#   phase 1: Vorbereitung + Verifizierung
#   phase 2: Admin-VM aufsetzen (Workloads von VM 500 → Admin-VM)
#   phase 3: Test-User erstellen
#   phase 4: Altes System abschalten
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_SERVICE_URL="http://192.168.10.160:8300"
ADMIN_API_KEY="${ADMIN_API_KEY:-}"
OLD_K3S_IP="192.168.10.150"
ADMIN_VM_IP="192.168.10.155"

PHASE="${1:-all}"

log()      { echo "[$(date +%H:%M:%S)] $*"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*"; }

# ── Hilfsfunktionen ─────────────────────────────────────────────────────────
admin_api() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" "${ADMIN_SERVICE_URL}${path}" \
        -H "X-API-Key: ${ADMIN_API_KEY}" \
        -H "Content-Type: application/json" "$@"
}

check_service() {
    local name="$1" url="$2"
    if curl -sf --connect-timeout 5 "$url" > /dev/null 2>&1; then
        log_ok "$name erreichbar: $url"
        return 0
    else
        log_err "$name NICHT erreichbar: $url"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: Vorbereitung + Verifizierung
# ═══════════════════════════════════════════════════════════════════════════
phase_1() {
    log "══ Phase 1: Vorbereitung + Verifizierung ══"

    log "Pruefe Voraussetzungen..."
    local errors=0

    # Admin-Service
    check_service "Admin-Service" "${ADMIN_SERVICE_URL}/api/v1/health" || ((errors++))

    # VM-Template
    if qm status 9003 &>/dev/null; then
        log_ok "VM-Template 9003 existiert"
    else
        log_err "VM-Template 9003 nicht gefunden! → vm-template/build-vm-template.sh"
        ((errors++))
    fi

    # Altes k3s (VM 500)
    if qm status 500 &>/dev/null; then
        log_ok "Alter k3s-Cluster (VM 500) vorhanden"
    else
        log_warn "VM 500 nicht gefunden (kein Problem wenn bereits migriert)"
    fi

    # Netzwerk
    if iptables -L JARVIS-FORWARD -n &>/dev/null; then
        log_ok "JARVIS-FORWARD Chain existiert"
    else
        log_err "Netzwerk-Isolation nicht konfiguriert! → setup-network-isolation.sh"
        ((errors++))
    fi

    if [ $errors -gt 0 ]; then
        log_err "Phase 1 fehlgeschlagen: $errors Fehler"
        exit 1
    fi

    # Bestandsaufnahme: Pods auf altem Cluster
    log ""
    log "Bestandsaufnahme VM 500 (alter k3s-Cluster):"
    ssh root@${OLD_K3S_IP} "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A --no-headers" 2>/dev/null || \
        log_warn "SSH zu VM 500 fehlgeschlagen — VM evtl. nicht erreichbar"

    log ""
    log_ok "Phase 1 abgeschlossen"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Admin-VM aufsetzen
# ═══════════════════════════════════════════════════════════════════════════
phase_2() {
    log "══ Phase 2: Admin-VM aufsetzen ══"

    # Admin-VM via Template klonen (manuell oder via Admin-Service)
    log "Pruefe ob Admin-VM (155) existiert..."
    if qm status 155 &>/dev/null; then
        log_ok "Admin-VM 155 existiert bereits"
    else
        log "Klone VM-Template 9003 → Admin-VM 155..."
        qm clone 9003 155 --name jarvis-admin-vm --full --storage local-lvm
        qm set 155 --memory 4096 --cores 4
        qm set 155 --net0 virtio,bridge=vmbr0
        qm set 155 --ipconfig0 ip=192.168.10.155/24,gw=192.168.10.1
        qm start 155

        log "Warte auf Admin-VM Boot (90s)..."
        sleep 90
    fi

    # vm.conf schreiben
    log "Konfiguriere Admin-VM..."
    ssh root@${ADMIN_VM_IP} "cat > /opt/jarvis/vm.conf << 'EOF'
VM_USERNAME=admin
VM_IP=192.168.10.155
VM_GATEWAY=192.168.10.1
VM_MGMT_IP=192.168.10.155
VM_PROFILE=large
VM_MODE=admin
ADMIN_SERVICE_URL=http://192.168.10.160:8300
HEADSCALE_URL=http://192.168.10.115:8080
EOF" 2>/dev/null || log_warn "SSH zur Admin-VM fehlgeschlagen"

    # Firstboot triggern (falls nicht automatisch)
    ssh root@${ADMIN_VM_IP} "
        if [ ! -f /opt/jarvis/.firstboot-done ]; then
            bash /opt/jarvis/firstboot.sh
        else
            echo 'Firstboot bereits ausgefuehrt'
        fi
    " 2>/dev/null || log_warn "Firstboot fehlgeschlagen — manuell pruefen"

    # Bestehende Websites/Services als JarvisApps deployen
    log ""
    log "Migriere Workloads von VM 500 → Admin-VM..."
    log "(Websites und FastAPI-Services werden als JarvisApp CRDs deployed)"
    log ""
    log "Manuell auf der Admin-VM ausfuehren:"
    log "  # Websites (Container-Images bleiben gleich)"
    log "  kubectl apply -f - << 'EOF'"
    log "  apiVersion: jarvis-os.io/v1"
    log "  kind: JarvisApp"
    log "  metadata: { name: sv-niederklein }"
    log "  spec:"
    log "    appId: sv-niederklein"
    log "    image: ghcr.io/war10ck-2025/sv-niederklein-website:latest"
    log "    port: 80"
    log "    ingress: { enabled: true, host: sv-niederklein.jarvis.local }"
    log "  EOF"
    log ""
    log "  # Analog fuer: schuetzenverein, ich-ag, pionex-mcp, voice-assistant, deployment-hub"

    log ""
    log_ok "Phase 2 abgeschlossen"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: Test-User erstellen
# ═══════════════════════════════════════════════════════════════════════════
phase_3() {
    log "══ Phase 3: Test-User erstellen ══"

    if [ -z "$ADMIN_API_KEY" ]; then
        log_err "ADMIN_API_KEY nicht gesetzt!"
        log "  export ADMIN_API_KEY=<key-aus-admin-service-.env>"
        exit 1
    fi

    log "Erstelle Test-User 'test-alice' (Profil: small)..."
    RESULT=$(admin_api POST "/api/v1/users" -d '{"username":"test-alice","profile":"small"}' 2>&1) || true
    echo "$RESULT" | jq . 2>/dev/null || echo "$RESULT"

    log ""
    log "Warte auf Provisioning (3-5 Minuten)..."
    for i in $(seq 1 60); do
        STATUS=$(admin_api GET "/api/v1/users/1" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unknown")
        if [ "$STATUS" = "ready" ]; then
            log_ok "User 'test-alice' ist bereit!"
            admin_api GET "/api/v1/users/1" | jq '{ username, status, vm_id, vm_ip, mgmt_ip, portal_url }'
            break
        fi
        [ "$STATUS" = "error" ] && { log_err "Provisioning fehlgeschlagen!"; break; }
        echo -n "."
        sleep 5
    done

    log ""
    log "Verifizierung:"
    log "  Portal: curl http://192.168.10.150:30080"
    log "  k3s:    ssh root@192.168.10.150 'kubectl get nodes'"
    log "  App:    curl -X POST http://192.168.10.150:30080/deploy/vaultwarden"

    log ""
    log_ok "Phase 3 abgeschlossen"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: Altes System abschalten
# ═══════════════════════════════════════════════════════════════════════════
phase_4() {
    log "══ Phase 4: Altes System abschalten ══"

    log "WARNUNG: Diese Phase stoppt das alte System!"
    log "Stelle sicher, dass alle Workloads migriert sind."
    log ""
    read -p "Fortfahren? (ja/nein) " CONFIRM
    [ "$CONFIRM" != "ja" ] && { log "Abgebrochen."; exit 0; }

    # VM 500 (alter k3s-Cluster)
    if qm status 500 &>/dev/null; then
        log "Stoppe VM 500 (alter k3s-Cluster)..."
        qm shutdown 500 --timeout 60 || qm stop 500
        log_ok "VM 500 gestoppt (nicht geloescht — Rollback-Fenster: 1 Woche)"
    fi

    # LXC 300 (casaos-lxc-bridge)
    if pct status 300 &>/dev/null; then
        log "Stoppe LXC 300 (casaos-lxc-bridge)..."
        pct shutdown 300 --timeout 30 || pct stop 300
        log_ok "LXC 300 gestoppt"
    fi

    # CasaOS-App-LXCs (301-399)
    for id in $(seq 301 399); do
        if pct status $id &>/dev/null; then
            log "Stoppe LXC $id..."
            pct shutdown $id --timeout 15 || pct stop $id
        fi
    done

    log ""
    log "╔════════════════════════════════════════════════════════╗"
    log "║  Altes System gestoppt (NICHT geloescht).             ║"
    log "║  Rollback: qm start 500 && pct start 300             ║"
    log "║                                                       ║"
    log "║  Nach 1 Woche ohne Probleme endgueltig loeschen:      ║"
    log "║    qm destroy 500 --purge                             ║"
    log "║    pct destroy 300 --purge                            ║"
    log "║    for id in \$(seq 301 399); do                       ║"
    log "║      pct destroy \$id --purge 2>/dev/null              ║"
    log "║    done                                               ║"
    log "╚════════════════════════════════════════════════════════╝"

    log ""
    log_ok "Phase 4 abgeschlossen"
}

# ── Main ────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  J.A.R.V.I.S-OS Migration: Shared-K8s → Per-VM"
echo "  Phase: ${PHASE}"
echo "═══════════════════════════════════════════════════════════"
echo ""

case "$PHASE" in
    1) phase_1 ;;
    2) phase_2 ;;
    3) phase_3 ;;
    4) phase_4 ;;
    all)
        phase_1
        echo ""
        phase_2
        echo ""
        phase_3
        echo ""
        log "Phase 4 (Abschaltung) muss manuell gestartet werden:"
        log "  bash scripts/migrate-to-per-vm.sh 4"
        ;;
    *)
        echo "Verwendung: $0 [1|2|3|4|all]"
        echo "  1: Vorbereitung + Verifizierung"
        echo "  2: Admin-VM aufsetzen"
        echo "  3: Test-User erstellen"
        echo "  4: Altes System abschalten"
        echo "  all: Phase 1-3 (Phase 4 manuell)"
        exit 1
        ;;
esac
