#!/bin/bash
# install.sh — jarvis-lxc-bridge installieren (auf CasaOS-LXC 20)
# Läuft auf dem CasaOS-Host (192.168.10.141)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

echo "► jarvis-lxc-bridge installieren..."

# Docker + docker-compose-plugin prüfen
if ! command -v docker &>/dev/null; then
  echo "  → Docker installieren..."
  apt-get update -qq && apt-get install -y -qq docker.io docker-compose-plugin
fi

# .env aus Beispiel erstellen wenn nicht vorhanden
if [ ! -f "$PROJECT_ROOT/.env" ]; then
  cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
  echo ""
  echo "  ⚠  .env erstellt — bitte PROXMOX_TOKEN eintragen:"
  echo "     nano $PROJECT_ROOT/.env"
  echo ""
  echo "  Proxmox-Token erstellen (auf Proxmox-Host):"
  echo "    pveum user add casaos@pve"
  echo "    pveum acl modify / --users casaos@pve --roles PVEVMAdmin"
  echo "    pveum user token add casaos@pve casaos-bridge-token --privsep=0"
  echo ""
fi

# jarvis-net erstellen wenn nicht vorhanden
docker network create jarvis-net 2>/dev/null || true

# Bridge deployen
cd "$PROJECT_ROOT"
docker compose pull 2>/dev/null || true
docker compose up -d --build

echo ""
echo "  ✓ jarvis-lxc-bridge läuft auf http://192.168.10.141:8200"
echo ""
echo "  Verfügbare Endpunkte:"
echo "    GET  http://192.168.10.141:8200/health"
echo "    GET  http://192.168.10.141:8200/bridge/catalog"
echo "    POST http://192.168.10.141:8200/bridge/install?appid=N8n"
echo "    GET  http://192.168.10.141:8200/bridge/list"
