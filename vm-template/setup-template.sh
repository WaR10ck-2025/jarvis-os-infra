#!/bin/bash
# ============================================================================
# setup-template.sh — Installiert k3s + Jarvis in der Template-VM
#
# Ausfuehren INNERHALB der VM (nach build-vm-template.sh).
# Installiert alle Software und Konfigurationen die jede User-VM braucht.
# Nach Ausfuehrung: VM herunterfahren → Template konvertieren.
# ============================================================================

set -euo pipefail

echo "=== J.A.R.V.I.S-OS VM-Template Setup ==="
echo "Hostname: $(hostname)"
echo ""

# -----------------------------------------------------------------------
# 1. System-Pakete
# -----------------------------------------------------------------------
echo "[1/8] System-Pakete installieren..."
apt-get update
apt-get install -y --no-install-recommends \
    qemu-guest-agent \
    curl wget git jq htop \
    nfs-common \
    ca-certificates \
    gnupg \
    apt-transport-https \
    sudo

# Guest Agent aktivieren
systemctl enable --now qemu-guest-agent

# -----------------------------------------------------------------------
# 2. k3s installieren
# -----------------------------------------------------------------------
echo "[2/8] k3s installieren..."
curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    --node-name jarvis-node

# Warten bis k3s bereit
echo "Warte auf k3s..."
for i in $(seq 1 60); do
    if /usr/local/bin/kubectl get nodes &>/dev/null; then
        echo "k3s bereit nach ${i}s"
        break
    fi
    sleep 2
done

# KUBECONFIG global verfuegbar machen
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /etc/profile.d/k3s.sh

# -----------------------------------------------------------------------
# 3. Helm installieren
# -----------------------------------------------------------------------
echo "[3/8] Helm installieren..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# -----------------------------------------------------------------------
# 4. Jarvis-Verzeichnisse + Konfiguration
# -----------------------------------------------------------------------
echo "[4/8] Jarvis-Verzeichnisse erstellen..."
mkdir -p /opt/jarvis
mkdir -p /data/appdata /data/files

# Beispiel vm.conf (wird beim Clone durch Admin-Service ueberschrieben)
cat > /opt/jarvis/vm.conf << 'EOF'
VM_USERNAME="template"
VM_IP="0.0.0.0"
VM_GATEWAY="0.0.0.0"
VM_MGMT_IP="0.0.0.0"
VM_PROFILE="medium"
VM_MODE="user"
ADMIN_SERVICE_URL="http://192.168.10.160:8300"
HEADSCALE_URL="http://192.168.10.115:8080"
EOF

# -----------------------------------------------------------------------
# 5. k3s Auto-Deploy Manifeste
# -----------------------------------------------------------------------
echo "[5/8] k3s Auto-Deploy Manifeste kopieren..."
MANIFESTS_DIR="/var/lib/rancher/k3s/server/manifests"

# Namespace
cat > "$MANIFESTS_DIR/jarvis-namespace.yaml" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: jarvis-system
  labels:
    app.kubernetes.io/part-of: jarvis-os
    app.kubernetes.io/managed-by: jarvis-operator
EOF

# JarvisApp CRD
cat > "$MANIFESTS_DIR/jarvis-app-crd.yaml" << 'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: jarvisapps.jarvis-os.io
spec:
  group: jarvis-os.io
  names:
    kind: JarvisApp
    listKind: JarvisAppList
    plural: jarvisapps
    singular: jarvisapp
    shortNames: ["ja"]
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["appId"]
              properties:
                appId:
                  type: string
                image:
                  type: string
                helmChart:
                  type: string
                helmRepo:
                  type: string
                helmValues:
                  type: object
                  x-kubernetes-preserve-unknown-fields: true
                port:
                  type: integer
                  default: 8080
                ingress:
                  type: object
                  properties:
                    enabled:
                      type: boolean
                      default: true
                    host:
                      type: string
                resources:
                  type: object
                  properties:
                    requests:
                      type: object
                      properties:
                        memory: { type: string, default: "64Mi" }
                        cpu: { type: string, default: "50m" }
                    limits:
                      type: object
                      properties:
                        memory: { type: string, default: "512Mi" }
                        cpu: { type: string, default: "1" }
                persistence:
                  type: object
                  properties:
                    enabled: { type: boolean, default: false }
                    size: { type: string, default: "5Gi" }
                    mountPath: { type: string, default: "/data" }
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: App
          type: string
          jsonPath: .spec.appId
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Endpoint
          type: string
          jsonPath: .status.endpoint
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
CRDEOF

# -----------------------------------------------------------------------
# 6. Firstboot-Service (laeuft einmalig nach Clone)
# -----------------------------------------------------------------------
echo "[6/8] Firstboot-Service einrichten..."
cat > /opt/jarvis/firstboot.sh << 'FBEOF'
#!/bin/bash
# /opt/jarvis/firstboot.sh — Einmalige Konfiguration nach VM-Clone
# Liest VM_USERNAME und ADMIN_SERVICE_URL aus /opt/jarvis/vm.conf

set -euo pipefail

# Abbrechen wenn bereits ausgefuehrt
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

# 2. k3s Node-IP anpassen
CURRENT_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "$VM_IP")
if [ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "0.0.0.0" ]; then
    # k3s Service-File anpassen
    if grep -q "node-ip" /etc/systemd/system/k3s.service; then
        sed -i "s/--node-ip [^ ]*/--node-ip $CURRENT_IP/" /etc/systemd/system/k3s.service
    else
        sed -i "s|server'|server' \\\\\n    '--node-ip' '$CURRENT_IP'|" /etc/systemd/system/k3s.service
    fi
    systemctl daemon-reload
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

# systemd-Service fuer firstboot
cat > /etc/systemd/system/jarvis-firstboot.service << 'EOF'
[Unit]
Description=J.A.R.V.I.S-OS First Boot Configuration
After=network-online.target k3s.service
Wants=network-online.target
ConditionPathExists=!/opt/jarvis/.firstboot-done

[Service]
Type=oneshot
ExecStart=/opt/jarvis/firstboot.sh
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl enable jarvis-firstboot.service

# -----------------------------------------------------------------------
# 7. Prometheus Node-Exporter
# -----------------------------------------------------------------------
echo "[7/8] Node-Exporter installieren..."
NODE_EXPORTER_VERSION="1.8.2"
cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}"*

cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable node-exporter

# -----------------------------------------------------------------------
# 8. Sysprep (Template-Vorbereitung)
# -----------------------------------------------------------------------
echo "[8/8] Sysprep..."

# Machine-ID loeschen (wird beim naechsten Boot neu generiert)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# SSH Host-Keys loeschen (werden beim naechsten Boot neu generiert)
rm -f /etc/ssh/ssh_host_*

# Cloud-Init fuer naechsten Boot vorbereiten
cloud-init clean 2>/dev/null || true

# Logs + Temp bereinigen
journalctl --rotate && journalctl --vacuum-time=1s
rm -rf /tmp/* /var/tmp/*
apt-get clean && rm -rf /var/lib/apt/lists/*

# k3s stoppen (wird beim naechsten Boot sauber gestartet)
systemctl stop k3s

echo ""
echo "=== Template-Setup abgeschlossen ==="
echo ""
echo "Naechste Schritte:"
echo "  1. VM herunterfahren: shutdown -h now"
echo "  2. Auf Proxmox: qm template $TEMPLATE_ID"
echo ""
