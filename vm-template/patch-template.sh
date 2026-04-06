#!/bin/bash
# ============================================================================
# patch-template.sh — Surgical Patch fuer bestehendes Template
#
# Wendet die Bug-Fixes aus commit abf0843 an, ohne setup-template.sh
# komplett neu auszufuehren. Erwartet Manifeste in /tmp/jarvis-build/manifests/.
#
# Schritte:
#   1. Operator/Portal/Monitoring/Grafana Manifeste in k3s auto-deploy
#   2. firstboot.sh ersetzen (k3s node-ip via config.yaml)
#   3. jarvis-firstboot.service ersetzen (After=cloud-final.service)
#   4. Sysprep + k3s stoppen
# ============================================================================

set -euo pipefail

echo "=== J.A.R.V.I.S-OS Template Patch (commit abf0843) ==="

MANIFESTS_DIR="/var/lib/rancher/k3s/server/manifests"
SRC="/tmp/jarvis-build/manifests"

# -----------------------------------------------------------------------
# 1. Manifeste kopieren
# -----------------------------------------------------------------------
echo "[1/4] Kopiere Operator/Portal/Monitoring/Grafana Manifeste..."
for f in jarvis-operator.yaml jarvis-portal.yaml jarvis-monitoring.yaml jarvis-grafana-dashboards.yaml; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" "$MANIFESTS_DIR/$f"
        echo "  + $f"
    else
        echo "  - $f (nicht gefunden in $SRC)"
    fi
done

# -----------------------------------------------------------------------
# 2. firstboot.sh ersetzen
# -----------------------------------------------------------------------
echo "[2/4] Ersetze /opt/jarvis/firstboot.sh..."
cat > /opt/jarvis/firstboot.sh << 'FBEOF'
#!/bin/bash
# /opt/jarvis/firstboot.sh — Einmalige Konfiguration nach VM-Clone

set -euo pipefail

if [ -f /opt/jarvis/.firstboot-done ]; then
    echo "Firstboot bereits ausgefuehrt — ueberspringe."
    exit 0
fi

CONFIG="/opt/jarvis/vm.conf"
if [ ! -f "$CONFIG" ]; then
    echo "FEHLER: $CONFIG nicht gefunden!"
    exit 1
fi
source "$CONFIG"

echo "=== J.A.R.V.I.S-OS Firstboot ==="
echo "Username: $VM_USERNAME"
echo "IP: $VM_IP"
echo "Profil: $VM_PROFILE"
echo "Modus: $VM_MODE"

# 1. Hostname setzen
hostnamectl set-hostname "jarvis-${VM_USERNAME}"

# 2. k3s Node-IP via /etc/rancher/k3s/config.yaml setzen
CURRENT_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "$VM_IP")
if [ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "0.0.0.0" ]; then
    echo "Setze k3s node-ip = $CURRENT_IP"
    mkdir -p /etc/rancher/k3s
    cat > /etc/rancher/k3s/config.yaml << CFGEOF
node-ip: $CURRENT_IP
node-name: jarvis-${VM_USERNAME}
CFGEOF
    systemctl restart k3s
fi

# 3. Warten bis k3s bereit
echo "Warte auf k3s..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 60); do
    if kubectl get nodes &>/dev/null; then
        echo "k3s bereit"
        break
    fi
    sleep 2
done

# 4. Portal-Konfiguration injizieren
kubectl create configmap jarvis-portal-config \
    --from-literal=ADMIN_SERVICE_URL="$ADMIN_SERVICE_URL" \
    --from-literal=VM_USERNAME="$VM_USERNAME" \
    --from-literal=VM_MODE="$VM_MODE" \
    --from-literal=VM_PROFILE="$VM_PROFILE" \
    -n jarvis-system --dry-run=client -o yaml | kubectl apply -f -

# 5. Tailscale registrieren (wenn Key vorhanden)
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    echo "Registriere Tailscale..."
    tailscale up --login-server="$HEADSCALE_URL" \
        --authkey="$TAILSCALE_AUTH_KEY" \
        --accept-routes --accept-dns=false \
        --hostname="jarvis-${VM_USERNAME}" || true
fi

# 6. App-Katalog initial laden
if [ -n "${ADMIN_SERVICE_URL:-}" ]; then
    echo "Lade App-Katalog..."
    curl -sf "${ADMIN_SERVICE_URL}/api/v1/catalog" > /opt/jarvis/catalog.json 2>/dev/null || true
fi

# 7. Firstboot-Marker setzen
touch /opt/jarvis/.firstboot-done
systemctl disable jarvis-firstboot.service 2>/dev/null || true

echo "=== Firstboot abgeschlossen ==="
FBEOF
chmod +x /opt/jarvis/firstboot.sh
echo "  firstboot.sh ersetzt"

# -----------------------------------------------------------------------
# 3. systemd Service ersetzen
# -----------------------------------------------------------------------
echo "[3/4] Ersetze /etc/systemd/system/jarvis-firstboot.service..."
cat > /etc/systemd/system/jarvis-firstboot.service << 'SVCEOF'
[Unit]
Description=J.A.R.V.I.S-OS First Boot Configuration
# WICHTIG: cloud-init.target verwenden, NICHT multi-user.target.
# cloud-final.service hat After=multi-user.target — das wuerde einen
# Ordering-Cycle erzeugen (multi-user → firstboot → cloud-final → multi-user).
# cloud-init.target ist der dokumentierte Sync-Punkt fuer "nach cloud-init"
# (siehe Kommentar in /lib/systemd/system/cloud-init.target).
# Auch KEIN After=k3s.service — k3s.service haengt transitiv an multi-user.target.
After=cloud-init.target network-online.target
Wants=cloud-init.target network-online.target
ConditionPathExists=!/opt/jarvis/.firstboot-done

[Service]
Type=oneshot
ExecStart=/opt/jarvis/firstboot.sh
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=300

[Install]
WantedBy=cloud-init.target
SVCEOF
# Alte Symlinks (aus frueherer Version) entfernen
rm -f /etc/systemd/system/multi-user.target.wants/jarvis-firstboot.service
systemctl daemon-reload
systemctl enable jarvis-firstboot.service
echo "  service ersetzt"

# -----------------------------------------------------------------------
# 4. Sysprep + k3s stoppen
# -----------------------------------------------------------------------
echo "[4/4] Sysprep..."

# Marker entfernen falls vom letzten Boot vorhanden
rm -f /opt/jarvis/.firstboot-done

# Machine-ID loeschen (wird beim naechsten Boot neu generiert)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# SSH Host-Keys loeschen (werden beim naechsten Boot neu generiert)
rm -f /etc/ssh/ssh_host_*

# Cloud-Init clean
cloud-init clean 2>/dev/null || true

# Logs + Temp bereinigen
journalctl --rotate && journalctl --vacuum-time=1s
rm -rf /tmp/jarvis-build /var/tmp/*
apt-get clean && rm -rf /var/lib/apt/lists/*

# k3s stoppen (wird beim naechsten Boot sauber gestartet)
systemctl stop k3s 2>/dev/null || true

echo ""
echo "=== Patch abgeschlossen ==="
echo "Naechster Schritt: shutdown -h now (manuell)"
