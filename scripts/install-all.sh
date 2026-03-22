#!/bin/bash
# install-all.sh — Master-Skript: alle LXCs + VM anlegen
#
# Muss auf dem Proxmox-Host als root ausgeführt werden:
#   bash /opt/openclaw-proxmox/scripts/install-all.sh
#
# Ablauf:
#   1. Debian 12 Template prüfen (herunterladen falls fehlt)
#   2. Infrastruktur-LXCs anlegen (Reverse-Proxy, CasaOS)
#   3. OpenClaw Service-LXCs anlegen
#   4. Wine Manager LXCs anlegen
#   5. usbipd LXC anlegen
#   6. Status-Übersicht ausgeben

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="local-lvm"     # Proxmox Storage für Disks
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

# ── Schritt 2: Infrastruktur ───────────────────────────────────────────────
echo ""
echo "► Schritt 2: Infrastruktur-LXCs..."
bash "$SCRIPT_DIR/install-lxc-reverse-proxy.sh"
bash "$SCRIPT_DIR/install-lxc-casaos.sh"

# ── Schritt 3: OpenClaw Services ──────────────────────────────────────────
echo ""
echo "► Schritt 3: OpenClaw Service-LXCs..."
bash "$SCRIPT_DIR/install-lxc-setup-repair.sh"
bash "$SCRIPT_DIR/install-lxc-pionex.sh"
bash "$SCRIPT_DIR/install-lxc-voice.sh"
bash "$SCRIPT_DIR/install-lxc-n8n.sh"
bash "$SCRIPT_DIR/install-lxc-sv-niederklein.sh"
bash "$SCRIPT_DIR/install-lxc-schuetzenverein.sh"
bash "$SCRIPT_DIR/install-lxc-deployment-hub.sh"
bash "$SCRIPT_DIR/install-lxc-yubikey.sh"

# ── Schritt 4: Wine Manager ───────────────────────────────────────────────
echo ""
echo "► Schritt 4: Wine Manager LXCs..."
bash "$SCRIPT_DIR/install-lxc-wine-desktop.sh"
bash "$SCRIPT_DIR/install-lxc-wine-api.sh"
bash "$SCRIPT_DIR/install-lxc-wine-ui.sh"

# ── Schritt 5: usbipd ─────────────────────────────────────────────────────
echo ""
echo "► Schritt 5: usbipd LXC..."
bash "$SCRIPT_DIR/install-lxc-usbipd.sh"

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
  [200]="wine-desktop:192.168.10.200"
  [201]="wine-api:192.168.10.201"
  [202]="wine-ui:192.168.10.202"
  [210]="usbipd:192.168.10.210"
)

for ID in 10 20 101 102 103 104 105 106 107 108 200 201 202 210; do
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
echo "  Wine Manager UI:      http://192.168.10.202:3000"
echo "  n8n:                  http://192.168.10.104:5678"
echo ""
echo "  Windows VM (optional): siehe scripts/setup-windows-vm.md"
echo ""
echo "✓ Installation abgeschlossen!"
