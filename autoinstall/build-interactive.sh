#!/bin/bash
# build-interactive.sh — Interaktive J.A.R.V.I.S-OS ISO (Proxmox-Wizard + first-boot)
#
# Erstellt proxmox-jarvis-interactive.iso via squashfs-Modifikation:
#   - Kein answer.toml → Proxmox Installer-Wizard bleibt aktiv
#   - first-boot.sh wird in squashfs injiziert → läuft nach Installation
#
# Verwendung (WSL2 Ubuntu):
#   sudo bash /mnt/c/Daten/Projekte/jarvis-os-infra/autoinstall/build-interactive.sh
#
set -e

SCRIPT_DIR="/mnt/c/Daten/Projekte/jarvis-os-infra/autoinstall"
PVE_ISO="/mnt/c/Users/WaR10ck/Downloads/proxmox-ve_9.1-1.iso"

echo "► Abhängigkeiten prüfen..."
for PKG in xorriso squashfs-tools p7zip-full syslinux-utils; do
  dpkg -l "$PKG" &>/dev/null || apt-get install -y -qq "$PKG"
done
echo "  ✓ Tools vorhanden"

echo ""
echo "► Starte interaktiven ISO-Build..."
bash "$SCRIPT_DIR/build-iso.sh" \
  --interactive \
  --pve-iso "$PVE_ISO"
