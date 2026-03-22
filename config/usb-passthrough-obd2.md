# USB-Passthrough OBD2 — Autocom CDP+ an VM 100

Beschreibt den nativen KVM USB-Passthrough des Autocom CDP+ (FTDI 0403:d6da) an die Windows-VM.

## Vorteil gegenüber Umbrel

```
Umbrel (Docker):                    Proxmox (KVM):
────────────────────────────────    ──────────────────────────────
Host-USB                            Host-USB
  └─ usbip-server (Docker priv.)     └─ KVM USB-Passthrough (direkt)
      └─ usbipd-win (Windows)              └─ Windows VM (VM 100)
          └─ Autocom-Treiber                    └─ Autocom-Treiber
               └─ CDP+ USB (3 Layer)                 └─ CDP+ USB (1 Layer)
```

**KVM USB-Passthrough hat:**
- Volle USB-Geschwindigkeit (kein TCP-Overhead)
- Kein usbipd nötig auf Windows-Seite
- Native FTDI-Treiber-Unterstützung
- Stabile Verbindung ohne usbip-Reconnect-Probleme

## Autocom CDP+ USB-Identifikation

```bash
# Auf Proxmox-Host, Autocom CDP+ einstecken:
lsusb | grep -i ftdi
# Bus 003 Device 006: ID 0403:d6da Future Technology Devices International, Ltd

# Bus-ID für QEMU ermitteln
lsusb -t | grep -A2 "0403"
# Ausgabe z.B.: Bus 03.Port 6: Dev 6, Class=...
# → Bus: 3, Device: 6 → hostbus=3, hostaddr=6
```

## VM 100 anlegen mit USB-Passthrough

```bash
# Neue VM anlegen (Proxmox Web-UI oder CLI):
qm create 100 \
  --name "windows-obd2" \
  --memory 3072 \
  --cores 2 \
  --sockets 1 \
  --cpu host \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --ipconfig0 ip=192.168.10.220/24,gw=192.168.10.1 \
  --ostype win10 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 local-lvm:0,format=raw,efitype=4m,pre-enrolled-keys=1 \
  --scsi0 local-lvm:64,format=raw,ssd=1,discard=on \
  --scsihw virtio-scsi-pci \
  --cdrom local:iso/Win10_22H2_German_x64.iso \
  --boot order="cdrom;scsi0" \
  --vga qxl \
  --agent enabled=1 \
  --balloon 0

# USB-Passthrough hinzufügen (VendorID + ProductID — stabiler als Bus:Device)
qm set 100 --usb0 "host=0403:d6da"

# KVM aktivieren
qm set 100 --kvm 1
```

## Windows-ISO bereitstellen

```bash
# Option A: ISO herunterladen (Microsoft Media Creation Tool oder direct link)
# Datei nach /var/lib/vz/template/iso/ kopieren:
scp Win10_22H2_German_x64.iso root@192.168.10.147:/var/lib/vz/template/iso/

# Option B: In Proxmox Web-UI unter "local" → "ISO Images" hochladen
```

## Windows installieren + Treiber

1. **Windows installieren:** VM 100 starten, via noVNC (https://192.168.10.147:8006 → VM 100 → Console)
2. **VirtIO-Treiber installieren:** https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso
3. **QEMU Guest Agent:** Aus VirtIO-ISO installieren → ermöglicht `qm guest exec`
4. **Autocom-Treiber:** Aus Autocom CDP+ CD oder Download installieren
5. **USB-Gerät prüfen:** Geräte-Manager → FTDI → "Autocom CDP+" sollte erscheinen

## USB-Passthrough nach VM-Neustart testen

```bash
# Prüfen ob USB-Gerät der VM zugewiesen ist
qm config 100 | grep usb

# QEMU Monitor: USB-Geräte in VM anzeigen
# (nur wenn VM läuft)
qm monitor 100 <<< "info usb"
```

## Troubleshooting

| Problem | Lösung |
|---|---|
| USB-Gerät nicht gefunden | `lsusb` auf Host prüfen, Autocom neu einstecken |
| VM bootet nicht | KVM aktiviert? `qm set 100 --kvm 1` |
| FTDI-Treiber Fehler | VirtIO-Treiber installiert? Q35 Chipsatz verwenden |
| USB nach Suspend weg | `qm set 100 --usb0 "host=0403:d6da"` — VendorID stabiler als Bus:Device |
| Keine RDP-Verbindung | Windows Firewall → Remote Desktop erlauben |

## Remote-Zugriff auf VM

```
noVNC (Browser):  http://192.168.10.147:8006 → VM 100 → Console
RDP:              192.168.10.220:3389
                  (Windows Netzwerk-Adapter: VirtIO)
```

## Autocom-Software auf Windows-VM

Nach Installation von CDP+:
1. Autocom CSS/CDP+ starten
2. Verbindung: USB (FTDI COM Port, z.B. COM3)
3. Fahrzeug auswählen + Diagnose starten

## Vergleich: Vorher (Umbrel) vs. Nachher (Proxmox)

| | Umbrel | Proxmox |
|---|---|---|
| USB-Schichten | 3 (USB → usbip → usbipd-win → Windows) | 1 (USB → KVM → Windows) |
| Latenz | ~5-20ms | <1ms |
| usbipd-win nötig | ✅ Ja | ❌ Nein |
| KVM-Beschleunigung | ❌ Nein (Docker nested) | ✅ Ja (native) |
| Stabilität | Gelegentliche Verbindungsabbrüche | Stabil |
