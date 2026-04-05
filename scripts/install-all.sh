#!/bin/bash
# install-all.sh — Master-Skript: alle LXCs + VM anlegen
#
# Muss auf dem Proxmox-Host als root ausgeführt werden:
#   bash /opt/jarvis-os-infra/scripts/install-all.sh
#
# Ablauf:
#   1. Debian 12 Template prüfen (herunterladen falls fehlt)
#   2. Infrastruktur-LXCs anlegen (Reverse-Proxy, CasaOS)
#   3. J.A.R.V.I.S-OS Service-LXCs anlegen
#   4. Wine Manager LXCs anlegen
#   5. usbipd LXC anlegen
#   6. Status-Übersicht ausgeben

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-zfs"     # Proxmox Storage für Disks
TEMPLATE_STORAGE="local" # Storage für Templates

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Wine Manager — Proxmox LXC Install (Master)          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Root-Check
if [ "$(id -u)" -ne 0 ]; then
  echo "✗ Muss als root ausgeführt werden (auf Proxmox-Host)." >&2
  exit 1
fi

# Proxmox-Check
if ! command -v pct &>/dev/null; then
  echo "✗ pct nicht gefunden — kein Proxmox-Host?" >&2
  exit 1
fi

# ── Schritt 0: SSH-Key-Setup (einmalig) ────────────────────────────────────
echo "► Schritt 0: SSH-Key für Proxmox-Host prüfen..."
SSH_KEY="$HOME/.ssh/proxmox_key"
if [ ! -f "$SSH_KEY" ]; then
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "jarvis-os-infra-deploy" -q
  echo "  ✓ SSH-Key erstellt: $SSH_KEY"
fi
# Public Key idempotent in authorized_keys eintragen
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qF "$(cat "${SSH_KEY}.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  cat "${SSH_KEY}.pub" >> "$HOME/.ssh/authorized_keys"
  echo "  ✓ SSH-Key in authorized_keys eingetragen"
else
  echo "  ✓ SSH-Key bereits in authorized_keys"
fi
HOST_IP=$(hostname -I | awk '{print $1}')
echo "  → Private Key auf Workstation kopieren: scp root@${HOST_IP}:${SSH_KEY} ~/.ssh/proxmox_key"
echo "  → Künftig: ssh -i ~/.ssh/proxmox_key root@${HOST_IP}"
echo ""

# ── Schritt 1: Template prüfen ─────────────────────────────────────────────
echo "► Schritt 1: Debian 12 Template prüfen..."
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  echo "  Template nicht gefunden — herunterladen..."
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  echo "  ✓ Template heruntergeladen"
else
  echo "  ✓ Template vorhanden"
fi

# ── Schritt 1b: LXC App-Template (Docker-in-LXC Basis) ───────────────────
echo ""
echo "► Schritt 1b: LXC App-Template (ID 9000) für CasaOS App-Store-Bridge..."
bash "$SCRIPT_DIR/install-lxc-app-template.sh"

# ── Schritt 2: Infrastruktur ───────────────────────────────────────────────
echo ""
echo "► Schritt 2: Infrastruktur-LXCs..."
bash "$SCRIPT_DIR/install-lxc-reverse-proxy.sh" || echo "  ⚠  Reverse-Proxy: Fehler (ggf. bereits installiert)"
bash "$SCRIPT_DIR/install-lxc-casaos.sh" || echo "  ⚠  CasaOS: Fehler (ggf. bereits installiert)"

# ── Schritt 2b: Proxmox API-Token für jarvis-lxc-bridge ───────────────────
echo ""
echo "► Schritt 2b: Proxmox API-Token für jarvis-lxc-bridge..."
pveum user add casaos@pve 2>/dev/null || true
pveum acl modify / --users casaos@pve --roles PVEVMAdmin 2>/dev/null || true
if ! pveum user token list casaos@pve 2>/dev/null | grep -q "casaos-bridge-token"; then
  TOKEN_OUTPUT=$(pveum user token add casaos@pve casaos-bridge-token --privsep=0 --output-format json)
  TOKEN_UUID=$(echo "$TOKEN_OUTPUT" | grep -o '"value":"[^"]*"' | cut -d'"' -f4)
  echo "  ✓ Token erstellt: PVEAPIToken=casaos@pve!casaos-bridge-token=$TOKEN_UUID"
  # Token automatisch in Bridge-.env auf LXC 20 eintragen + Bridge neu starten
  pct exec 20 -- bash -c "
    ENV_FILE=/opt/jarvis-os-infra/jarvis-lxc-bridge/.env
    if [ -f \"\$ENV_FILE\" ]; then
      sed -i \"s|PROXMOX_TOKEN=.*|PROXMOX_TOKEN=PVEAPIToken=casaos@pve!casaos-bridge-token=${TOKEN_UUID}|\" \"\$ENV_FILE\"
      docker compose -f /opt/jarvis-os-infra/jarvis-lxc-bridge/docker-compose.yml restart 2>/dev/null || true
      echo '  ✓ Token in Bridge-.env eingetragen + Bridge neu gestartet'
    else
      echo '  ⚠  Bridge-.env nicht gefunden — Token manuell eintragen'
    fi
  " 2>/dev/null || echo "  ⚠  LXC 20 nicht erreichbar — Token manuell eintragen"
else
  echo "  ✓ Token bereits vorhanden"
fi

# ── Schritt 3: J.A.R.V.I.S-OS Services ──────────────────────────────────────────
echo ""
echo "► Schritt 3: J.A.R.V.I.S-OS Service-LXCs..."
bash "$SCRIPT_DIR/install-lxc-setup-repair.sh"  || echo "  ⚠  setup-repair: Fehler"
bash "$SCRIPT_DIR/install-lxc-pionex.sh"         || echo "  ⚠  pionex: Fehler"
bash "$SCRIPT_DIR/install-lxc-voice.sh"          || echo "  ⚠  voice: Fehler"
bash "$SCRIPT_DIR/install-lxc-n8n.sh"            || echo "  ⚠  n8n: Fehler"
bash "$SCRIPT_DIR/install-lxc-sv-niederklein.sh" || echo "  ⚠  sv-niederklein: Fehler"
bash "$SCRIPT_DIR/install-lxc-schuetzenverein.sh"|| echo "  ⚠  schuetzenverein: Fehler"
bash "$SCRIPT_DIR/install-lxc-deployment-hub.sh" || echo "  ⚠  deployment-hub: Fehler"
bash "$SCRIPT_DIR/install-lxc-yubikey.sh"        || echo "  ⚠  yubikey: Fehler"
bash "$SCRIPT_DIR/install-lxc-nextcloud.sh"      || echo "  ⚠  nextcloud: Fehler"

# ── Schritt 4: Wine Manager ───────────────────────────────────────────────
echo ""
echo "► Schritt 4: Wine Manager LXCs..."
bash "$SCRIPT_DIR/install-lxc-wine-desktop.sh" || echo "  ⚠  wine-desktop: Fehler"
bash "$SCRIPT_DIR/install-lxc-wine-api.sh"     || echo "  ⚠  wine-api: Fehler"
bash "$SCRIPT_DIR/install-lxc-wine-ui.sh"      || echo "  ⚠  wine-ui: Fehler"

# ── Schritt 5: usbipd ─────────────────────────────────────────────────────
echo ""
echo "► Schritt 5: usbipd LXC..."
bash "$SCRIPT_DIR/install-lxc-usbipd.sh" || echo "  ⚠  usbipd: Fehler"

# ── Schritt 6: Status-Übersicht ───────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Status-Übersicht                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
printf "%-8s %-25s %-18s %s\n" "LXC-ID" "Hostname" "IP" "Status"
printf "%-8s %-25s %-18s %s\n" "------" "--------" "--" "------"

declare -A LXC_MAP=(
  [10]="reverse-proxy:192.168.10.140"
  [20]="casaos-dashboard:192.168.10.141"
  [101]="setup-repair-agent:192.168.10.101"
  [102]="pionex-mcp-server:192.168.10.102"
  [103]="voice-assistant:192.168.10.103"
  [104]="n8n:192.168.10.104"
  [105]="sv-niederklein:192.168.10.105"
  [106]="schuetzenverein:192.168.10.106"
  [107]="deployment-hub:192.168.10.107"
  [108]="yubikey-auth:192.168.10.108"
  [109]="nextcloud:192.168.10.109"
  [200]="wine-desktop:192.168.10.200"
  [201]="wine-api:192.168.10.201"
  [202]="wine-ui:192.168.10.202"
  [210]="usbipd:192.168.10.210"
  [300]="jarvis-lxc-bridge:192.168.10.180"
)

for ID in 10 20 101 102 103 104 105 106 107 108 109 200 201 202 210 300; do
  IFS=':' read -r HOSTNAME IP <<< "${LXC_MAP[$ID]}"
  STATUS=$(pct status "$ID" 2>/dev/null | awk '{print $2}' || echo "FEHLT")
  if [ "$STATUS" = "running" ]; then
    STATUS_STR="✓ running"
  elif [ "$STATUS" = "stopped" ]; then
    STATUS_STR="○ stopped"
  else
    STATUS_STR="✗ FEHLT"
  fi
  printf "%-8s %-25s %-18s %s\n" "$ID" "$HOSTNAME" "$IP" "$STATUS_STR"
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Wichtige URLs                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Proxmox Web-UI:       https://192.168.10.147:8006"
echo "  Nginx Proxy Manager:  http://192.168.10.140:81  (admin/changeme)"
echo "  CasaOS Dashboard:     http://192.168.10.141"
echo "  Nextcloud:            http://192.168.10.109  (admin / siehe LXC .env)"
echo "  CasaOS LXC-Bridge:   http://192.168.10.180:8200"
echo "  Bridge App-Katalog:  http://192.168.10.180:8200/bridge/catalog"
echo "  Wine Manager UI:      http://192.168.10.202:3000"
echo "  n8n:                  http://192.168.10.104:5678"
echo ""
echo "  Windows VM (optional): siehe scripts/setup-windows-vm.md"
echo ""
echo "✓ Installation abgeschlossen!"
