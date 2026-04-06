#!/bin/bash
# install-lxc-admin-service.sh — J.A.R.V.I.S-OS Admin Service LXC 160
#
# Installiert den zentralen Admin-Service (FastAPI) als LXC auf Proxmox.
# Verwaltet: User-CRUD, VM-Lifecycle, App-Katalog, Backup-Trigger.
# Kommuniziert mit Proxmox REST-API + SSH zum Host.
#
# Voraussetzung:
#   - GitHub PAT mit read:packages Scope (fuer private Repos)
#   - Proxmox API-Token (PVEAPIToken=jarvis@pve!admin-service-token=<uuid>)
#   - SSH-Key fuer Host-Zugriff (Bridge/ZFS/iptables)
#
# Verwendung: bash scripts/install-lxc-admin-service.sh
set -e

LXC_ID=160
LXC_IP=192.168.10.160
LXC_HOSTNAME=jarvis-admin
LXC_STORAGE=${PROXMOX_STORAGE:-local-lvm}
LXC_MEMORY=512
LXC_CORES=1
PROXMOX_NODE=${PROXMOX_NODE:-jarvis}

# Debian 12 Template
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

# GitHub Repo (Private — PAT benoetigt)
GITHUB_REPO="https://github.com/WaR10ck-2025/jarvis-admin-service.git"

echo "=== J.A.R.V.I.S-OS Admin Service LXC ${LXC_ID} (${LXC_IP}) ==="

# ── Pruefen ob LXC bereits existiert ────────────────────────────────────────
if pct status ${LXC_ID} &>/dev/null; then
    echo "WARNUNG: LXC ${LXC_ID} existiert bereits."
    echo "  Status: $(pct status ${LXC_ID})"
    echo "  Zum Loeschen: pct destroy ${LXC_ID} --purge"
    exit 1
fi

# ── LXC anlegen ─────────────────────────────────────────────────────────────
pct create ${LXC_ID} "${TEMPLATE}" \
  --hostname ${LXC_HOSTNAME} \
  --storage ${LXC_STORAGE} \
  --rootfs ${LXC_STORAGE}:8 \
  --memory ${LXC_MEMORY} \
  --cores ${LXC_CORES} \
  --net0 name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1 \
  --nameserver "1.1.1.1 8.8.8.8" \
  --unprivileged 1 \
  --features nesting=1 \
  --start 1 \
  --onboot 1

echo "Warte auf LXC-Start..."
sleep 8

# ── System-Pakete ───────────────────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  apt-get update -qq
  apt-get install -y -qq \
    python3 python3-pip python3-venv \
    git openssh-client curl jq
"

# ── Repository klonen ───────────────────────────────────────────────────────
echo "Klone Admin-Service Repository..."
echo "HINWEIS: Falls privates Repo, GitHub PAT in URL einsetzen:"
echo "  git clone https://USER:TOKEN@github.com/WaR10ck-2025/jarvis-admin-service.git"

pct exec ${LXC_ID} -- bash -c "
  if [ -d /opt/jarvis-admin ]; then
    cd /opt/jarvis-admin && git pull
  else
    git clone ${GITHUB_REPO} /opt/jarvis-admin || {
      echo 'FEHLER: git clone fehlgeschlagen. PAT noetig fuer private Repos.'
      echo 'Manuell: pct exec ${LXC_ID} -- git clone https://USER:TOKEN@github.com/...'
      exit 1
    }
  fi
"

# ── Python venv + Dependencies ──────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  cd /opt/jarvis-admin
  python3 -m venv venv
  ./venv/bin/pip install --quiet -r requirements.txt
"

# ── Datenverzeichnis ────────────────────────────────────────────────────────
pct exec ${LXC_ID} -- mkdir -p /opt/jarvis-admin/data

# ── .env anlegen (Platzhalter) ──────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  if [ ! -f /opt/jarvis-admin/.env ]; then
    cat > /opt/jarvis-admin/.env << 'ENVEOF'
# J.A.R.V.I.S-OS Admin Service Konfiguration
# Werte vor dem ersten Start anpassen!

PROXMOX_HOST=https://192.168.10.147:8006
PROXMOX_TOKEN=PVEAPIToken=jarvis@pve!admin-service-token=HIER_TOKEN_EINTRAGEN
PROXMOX_NODE=pve
PROXMOX_SSH_KEY=/opt/jarvis-admin/proxmox_key

VM_TEMPLATE_ID=9003
ADMIN_API_KEY=$(openssl rand -hex 32)

AUTHENTIK_URL=http://192.168.10.125:9000
AUTHENTIK_TOKEN=HIER_AUTHENTIK_TOKEN
HEADSCALE_URL=http://192.168.10.115:8080
HEADSCALE_LXC_ID=115

ZFS_POOL_NAME=tank
DB_PATH=/opt/jarvis-admin/data/jarvis.db
ENVEOF
    echo '.env mit Platzhaltern erstellt — bitte Werte anpassen!'
  fi
"

# ── SSH-Key generieren (fuer Host-Zugriff) ──────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  if [ ! -f /opt/jarvis-admin/proxmox_key ]; then
    ssh-keygen -t ed25519 -f /opt/jarvis-admin/proxmox_key -N '' -C 'jarvis-admin-service'
    echo ''
    echo '╔══════════════════════════════���════════════════════════╗'
    echo '║  SSH-Key generiert. Public Key auf Proxmox-Host      ║'
    echo '║  hinzufuegen:                                        ║'
    echo '╚═══════════════════════════════════════════════════════╝'
    echo ''
    echo 'Public Key:'
    cat /opt/jarvis-admin/proxmox_key.pub
    echo ''
    echo 'Auf Proxmox-Host ausfuehren:'
    echo '  cat >> /root/.ssh/authorized_keys << EOF'
    cat /opt/jarvis-admin/proxmox_key.pub
    echo 'EOF'
  fi
"

# ── systemd Service ─────────────────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  cat > /etc/systemd/system/jarvis-admin.service << 'EOF'
[Unit]
Description=J.A.R.V.I.S-OS Admin Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/jarvis-admin
EnvironmentFile=/opt/jarvis-admin/.env
ExecStart=/opt/jarvis-admin/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8300
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable jarvis-admin
  systemctl start jarvis-admin || echo 'HINWEIS: Service start fehlgeschlagen — .env pruefen!'
"

echo ""
echo "=== Admin Service LXC ${LXC_ID} erstellt ==="
echo ""
echo "  IP:      ${LXC_IP}:8300"
echo "  Health:  curl http://${LXC_IP}:8300/api/v1/health"
echo "  Logs:    pct exec ${LXC_ID} -- journalctl -u jarvis-admin -f"
echo "  Config:  pct exec ${LXC_ID} -- nano /opt/jarvis-admin/.env"
echo ""
echo "WICHTIG — Vor dem ersten Einsatz:"
echo "  1. .env mit echten Werten befuellen (Proxmox-Token, Authentik, etc.)"
echo "  2. SSH-Key auf Proxmox-Host hinterlegen (authorized_keys)"
echo "  3. VM-Template 9003 erstellen (vm-template/build-vm-template.sh)"
echo "  4. Service neustarten: pct exec ${LXC_ID} -- systemctl restart jarvis-admin"
echo ""
