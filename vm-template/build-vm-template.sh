#!/bin/bash
# ============================================================================
# build-vm-template.sh — Erstellt das J.A.R.V.I.S-OS VM-Template (ID 9003)
#
# Ausfuehren auf dem Proxmox-Host (als root).
# Erstellt eine VM, installiert Debian 12 und konvertiert zu einem Template.
#
# Voraussetzung: Debian 12 Cloud-Image als ISO auf dem Host
# ============================================================================

set -euo pipefail

TEMPLATE_ID="${1:-9003}"
TEMPLATE_NAME="jarvis-vm-template"
STORAGE="local-lvm"
DISK_SIZE="20"
RAM="2048"
CORES="2"
BRIDGE="vmbr0"

echo "=== J.A.R.V.I.S-OS VM-Template Builder ==="
echo "Template-ID: $TEMPLATE_ID"
echo "Name: $TEMPLATE_NAME"
echo ""

# -----------------------------------------------------------------------
# Schritt 1: Pruefen ob Template bereits existiert
# -----------------------------------------------------------------------
if qm status "$TEMPLATE_ID" &>/dev/null; then
    echo "FEHLER: VM/Template $TEMPLATE_ID existiert bereits!"
    echo "Zum Loeschen: qm destroy $TEMPLATE_ID --purge"
    exit 1
fi

# -----------------------------------------------------------------------
# Schritt 2: Cloud-Image herunterladen (falls nicht vorhanden)
# -----------------------------------------------------------------------
CLOUD_IMG="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"
if [ ! -f "$CLOUD_IMG" ]; then
    echo "Lade Debian 12 Cloud-Image herunter..."
    wget -O "$CLOUD_IMG" \
        "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
fi

# -----------------------------------------------------------------------
# Schritt 3: VM erstellen
# -----------------------------------------------------------------------
echo "Erstelle VM $TEMPLATE_ID..."
qm create "$TEMPLATE_ID" \
    --name "$TEMPLATE_NAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --ostype l26 \
    --boot order=scsi0

# Cloud-Image als Disk importieren
echo "Importiere Cloud-Image..."
qm importdisk "$TEMPLATE_ID" "$CLOUD_IMG" "$STORAGE" --format raw
qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:vm-${TEMPLATE_ID}-disk-0,ssd=1,size=${DISK_SIZE}G"

# Cloud-Init Drive hinzufuegen
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit"
qm set "$TEMPLATE_ID" --boot order=scsi0

# Cloud-Init Defaults
qm set "$TEMPLATE_ID" \
    --ciuser root \
    --cipassword "jarvis-template" \
    --ipconfig0 ip=dhcp \
    --nameserver "1.1.1.1 8.8.8.8" \
    --serial0 socket \
    --vga serial0

echo ""
echo "=== VM $TEMPLATE_ID erstellt ==="
echo ""
echo "Naechste Schritte:"
echo "  1. VM starten: qm start $TEMPLATE_ID"
echo "  2. Warten bis Cloud-Init fertig (ca. 2 Min)"
echo "  3. setup-template.sh in der VM ausfuehren:"
echo "     scp setup-template.sh root@<VM-IP>:/tmp/"
echo "     ssh root@<VM-IP> 'bash /tmp/setup-template.sh'"
echo "  4. VM herunterfahren: qm shutdown $TEMPLATE_ID"
echo "  5. Template konvertieren: qm template $TEMPLATE_ID"
echo ""
echo "Oder automatisiert:"
echo "  qm start $TEMPLATE_ID && sleep 120"
echo "  # IP herausfinden (via arp-scan oder DHCP)"
echo "  scp setup-template.sh root@<IP>:/tmp/"
echo "  ssh root@<IP> 'bash /tmp/setup-template.sh'"
echo "  ssh root@<IP> 'shutdown -h now'"
echo "  sleep 30 && qm template $TEMPLATE_ID"
