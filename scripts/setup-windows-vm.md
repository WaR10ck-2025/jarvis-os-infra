# VM 100: Windows OBD2 — Einrichtungsanleitung

Native KVM Windows-VM auf Proxmox mit direktem USB-Passthrough des Autocom CDP+.

## Vorbereitung

### Windows-ISO bereitstellen

```bash
# Option A: Direkt auf Proxmox hochladen
# Proxmox Web-UI → local → ISO Images → Upload
# ISO: Windows 10 22H2 (aus Microsoft Media Creation Tool)

# Option B: Per scp
scp Win10_22H2_German_x64.iso root@192.168.10.147:/var/lib/vz/template/iso/

# VirtIO-Treiber-ISO (für Festplatten- und Netzwerktreiber)
wget -O /var/lib/vz/template/iso/virtio-win.iso \
  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso
```

### Autocom CDP+ identifizieren

```bash
# Auf Proxmox-Host, Autocom CDP+ einstecken:
lsusb | grep -i "0403:d6da"
# Bus 003 Device 006: ID 0403:d6da Future Technology Devices International, Ltd
# → hostbus=3, hostaddr=6 (kann variieren!)
```

## VM anlegen (Proxmox Web-UI)

### Allgemein
- **VM ID:** 100
- **Name:** windows-obd2
- **OS:** Microsoft Windows 10/2016/2019

### System
- **Machine:** q35
- **BIOS:** OVMF (UEFI)
- **EFI Storage:** local-lvm
- **TPM:** optional (Win 11 braucht TPM 2.0)

### Festplatte
- **Bus:** SCSI (VirtIO SCSI)
- **Storage:** local-lvm
- **Size:** 64 GB
- **SSD emulation:** ✅
- **Discard:** ✅

### CPU
- **Sockets:** 1
- **Cores:** 2
- **Type:** host (für maximale Kompatibilität mit Autocom-Treibern)

### Memory
- **RAM:** 3072 MB (3 GB)
- **Ballooning:** ❌ Aus (Windows-Treiber-Problem)

### Netzwerk
- **Model:** VirtIO (paravirtualized)
- **Bridge:** vmbr0
- **IP:** 192.168.10.220/24 (statisch in Windows konfigurieren)

### CD-ROM Drives
1. Windows-ISO (primär)
2. VirtIO-ISO (sekundär, für Treiber während Installation)

## VM anlegen per CLI

```bash
# VM erstellen
qm create 100 \
  --name "windows-obd2" \
  --memory 3072 \
  --balloon 0 \
  --cores 2 \
  --sockets 1 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "local-lvm:0,format=raw,efitype=4m,pre-enrolled-keys=1" \
  --ostype win10 \
  --scsi0 "local-lvm:64,format=raw,ssd=1,discard=on" \
  --scsihw virtio-scsi-pci \
  --ide2 "local:iso/Win10_22H2_German_x64.iso,media=cdrom" \
  --ide3 "local:iso/virtio-win.iso,media=cdrom" \
  --net0 "virtio,bridge=vmbr0,firewall=0" \
  --boot "order=ide2;scsi0" \
  --vga qxl \
  --agent enabled=1 \
  --kvm 1

# USB-Passthrough: Autocom CDP+ per VendorID:ProductID (stabiler als Bus:Device)
qm set 100 --usb0 "host=0403:d6da"

echo "VM 100 angelegt — starte mit: qm start 100"
```

## Windows installieren

1. **VM 100 starten:** `qm start 100`
2. **noVNC öffnen:** https://192.168.10.147:8006 → VM 100 → Console
3. **Windows installieren** (Standard-Prozess)
4. **Während Installation — VirtIO-Treiber laden:**
   - Festplatteninstallation: "Treiber laden" → VirtIO-CD → `vioscsi\w10\amd64`
5. **Nach Installation:**
   - VirtIO-ISO öffnen → `virtio-win-gt-x64.msi` installieren (alle VirtIO-Treiber)
   - QEMU Guest Agent installieren: `virtio-win-guest-tools.exe`

## Autocom CDP+ konfigurieren

1. **USB prüfen:** Geräte-Manager → "USB Serial Port (FTDI)" sollte erscheinen
2. **Autocom-Treiber installieren** (aus Autocom CD oder Download)
3. **Autocom CSS/CDP+ starten:**
   - Verbindung: USB
   - COM-Port: entsprechender FTDI-Port (z.B. COM3)

## Netzwerk statisch konfigurieren (Windows)

```
Einstellungen → Netzwerk → Ethernet → IP-Einstellungen:
  IP-Adresse: 192.168.10.220
  Subnetzmaske: 255.255.255.0
  Gateway: 192.168.10.1
  DNS: 192.168.10.1
```

## Remote-Zugriff

```
noVNC (Browser): https://192.168.10.147:8006 → VM 100 → Console
RDP:             192.168.10.220:3389
                 (Windows Einstellungen → Remote Desktop → aktivieren)
```

## Autostart

```bash
# VM beim Proxmox-Boot automatisch starten
qm set 100 --onboot 1
```

## Vergleich Umbrel vs. Proxmox

| | Umbrel (dockurr/windows) | Proxmox (native KVM) |
|---|---|---|
| USB-Passthrough | 3 Layer (USB→Docker→QEMU→Win) | 1 Layer (USB→KVM→Win) |
| KVM-Beschleunigung | ❌ (nested, deaktiviert) | ✅ (nativ) |
| usbipd-win nötig | ✅ Ja | ❌ Nein |
| noVNC-Port | :8100 | :8006 (Proxmox) |
| RAM-Overhead | ~500MB Docker overhead | kein Overhead |
| Autocom-Stabilität | Gelegentliche USB-Disconnects | Stabil |
