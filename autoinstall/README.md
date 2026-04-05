# J.A.R.V.I.S-OS OS — Custom Proxmox Installer

Bootfähiges USB-Image / ISO das Proxmox VE installiert und
die J.A.R.V.I.S-OS Basis-Plattform (CasaOS + Deployment Hub + Nginx Proxy) deployt.

**Zwei ISO-Varianten stehen zur Verfügung:**

| ISO | Installations-Phase | Wann verwenden |
|---|---|---|
| `proxmox-jarvis.iso` | Vollautomatisch (kein Input) | Headless-Server, CI/CD, Reproduzierbarkeit |
| `proxmox-jarvis-interactive.iso` | Proxmox-Wizard (Benutzer wählt Disk/Passwort) | Neue Hardware, individuelle Konfiguration |

Beide ISOs deployen nach der Installation **automatisch** LXC 110/120/170.

---

## Was wird installiert?

| Phase | Was | Dauer |
|---|---|---|
| **Boot** | Proxmox VE Installer | ~3 Min |
| **Neustart** | System startet (interaktiv: LUKS-Passphrase aus Wizard) | — |
| **First-Boot** | LXC 110: Nginx Proxy Manager | ~5 Min |
| | LXC 120: CasaOS App-Store Dashboard | |
| | LXC 170: GitHub Deployment Hub | |
| **Danach** | Weitere Services über CasaOS on demand | — |

**Gesamt: ~8-10 Minuten bis zur fertigen Basis-Plattform.**

---

## Schritt 1 — answer.toml anpassen (nur für automatische ISO)

```toml
# autoinstall/answer.toml öffnen:
root_password = "SICHERES-PASSWORT-SETZEN"    # Proxmox root + Web-UI Login
disk_password = "SICHERES-LUKS-PASSWORT"       # Disk-Verschlüsselung
fqdn = "mein-server.local"                     # Hostname
```

> **Nur relevant für die automatische ISO.** Bei der interaktiven ISO werden
> Passwort und Hostname im Installer-Wizard eingegeben.

---

## Schritt 2 — ISO erstellen

### Voraussetzungen (Linux / WSL2)

```bash
# Debian/Ubuntu:
apt install xorriso squashfs-tools p7zip-full syslinux-utils curl git

# Optional (bevorzugter Baumodus):
apt install proxmox-auto-install-assistant
```

### Automatische ISO bauen

```bash
cd jarvis-os-infra/autoinstall

# answer.toml anpassen (Passwörter setzen) — dann:
sudo bash build-iso.sh --pve-iso /path/to/proxmox-ve_8.x.iso

# Output: proxmox-jarvis.iso
```

### Interaktive ISO bauen

```bash
cd jarvis-os-infra/autoinstall

# Kein answer.toml nötig — Proxmox-Wizard fragt alles ab
sudo bash build-iso.sh --interactive --pve-iso /path/to/proxmox-ve_8.x.iso

# Output: proxmox-jarvis-interactive.iso
```

---

## Schritt 3 — USB-Stick erstellen

### Linux

```bash
# USB-Stick identifizieren:
lsblk   # oder: fdisk -l

# Auf USB schreiben (VORSICHT — alle Daten werden gelöscht!):
dd if=proxmox-jarvis.iso of=/dev/sdX bs=4M status=progress
# oder:
dd if=proxmox-jarvis-interactive.iso of=/dev/sdX bs=4M status=progress
sync
```

### Windows

- **Balena Etcher** → gewünschte ISO → USB-Stick
- **Rufus** → DD-Modus

### Alternativ: direkt beim Build

```bash
sudo bash build-iso.sh --pve-iso proxmox-ve_8.x.iso --output /dev/sdX
sudo bash build-iso.sh --interactive --pve-iso proxmox-ve_8.x.iso --output /dev/sdX
```

---

## Schritt 4a — Booten (Automatische ISO)

1. USB-Stick einstecken → Zielrechner einschalten
2. Boot-Reihenfolge: USB-Stick (BIOS/UEFI → Boot Menu)
3. Proxmox installiert sich **automatisch** (kein Input nötig)
4. Neustart → **LUKS-Passphrase eingeben** (aus answer.toml → `disk_password`)
5. `jarvis-os-first-boot.service` startet automatisch (~5 Min)
6. Logs verfolgen: `journalctl -u jarvis-os-first-boot -f`

## Schritt 4b — Booten (Interaktive ISO)

1. USB-Stick einstecken → Zielrechner einschalten
2. Boot-Reihenfolge: USB-Stick (BIOS/UEFI → Boot Menu)
3. **Proxmox-Installer-Wizard** erscheint → Disk, Hostname, Passwort konfigurieren
4. Installation starten → Neustart
5. `jarvis-os-first-boot.service` startet automatisch (~5 Min)
6. Logs verfolgen: `journalctl -u jarvis-os-first-boot -f`

---

## Schritt 5 — Dashboard öffnen

```bash
# IP ermitteln:
ip addr | grep "inet " | grep -v 127
# Oder: Router DHCP-Tabelle prüfen
```

| URL | Was |
|---|---|
| `http://<IP>:8006` | Proxmox Web-UI (root / Ihr Passwort) |
| `http://192.168.10.141` | CasaOS App-Store |
| `http://192.168.10.140:81` | Nginx Proxy Manager (admin@example.com / changeme) |
| `http://192.168.10.107:8100` | Deployment Hub |

> **Nginx Proxy Manager Passwort sofort ändern!**

---

## Weitere Services installieren (CasaOS App-Store)

Über CasaOS → App-Store können alle weiteren Services per Klick installiert werden:

| Service | LXC | IP |
|---|---|---|
| Wine Manager | LXC 200-202, 210 | 192.168.10.200-202 |
| n8n | LXC 104 | 192.168.10.104 |
| Pionex MCP | LXC 102 | 192.168.10.102 |
| SV Niederklein | LXC 105 | 192.168.10.105 |
| ...weitere... | LXC 101-108 | 192.168.10.101-108 |

---

## Optional — YubiKey für LUKS enrollen

Nach der Installation kann ein YubiKey als **Touch-to-Unlock** für LUKS hinzugefügt werden.
Die Passphrase bleibt immer als Fallback erhalten.

```bash
# SSH auf Proxmox:
ssh root@<IP>

# YubiKey einstecken und enrollen:
bash /root/yubikey-enroll.sh
```

Ab dem nächsten Boot: YubiKey einstecken + berühren → LUKS öffnet sich automatisch.

Ohne YubiKey: Passphrase-Eingabe wie gewohnt möglich.

---

## Optional — Verschlüsselten ZFS Datenpool anlegen

Für zusätzliche Daten-Disks (Backups, VM-Disks, etc.) kann ein verschlüsselter
ZFS Pool angelegt werden:

```bash
bash /root/zfs-pool-create.sh
```

Das Skript fragt interaktiv nach:
- RAID-Layout (single / mirror / raidz)
- Disks (/dev/sdb, /dev/sdc, ...)
- Schlüssel (Passphrase oder YubiKey HMAC)

Beim nächsten Boot wird der Pool automatisch via `zfs-unlock.service` entsperrt.

---

## Sicherheits-Hinweise

| | Status |
|---|---|
| System-Disk verschlüsselt | ✅ LUKS2 (AES-256-XTS) |
| LXCs/VMs ohne Unlock | ✅ Starten nicht (systemd Abhängigkeit) |
| ZFS Pools | ✅ AES-256-GCM optional |
| YubiKey | ✅ Optional, Passphrase immer als Fallback |
| Recovery | Passphrase sicher verwahren! |

> **Recovery-Passphrase** ist der einzige Weg das System ohne YubiKey zu entsperren.
> **Sicherheitskopie der Passphrase anlegen** (z.B. KeePass, Passwortmanager).

---

## Troubleshooting

### First-Boot Logs

```bash
journalctl -u jarvis-os-first-boot -f
cat /var/log/jarvis-os-first-boot.log
```

### First-Boot manuell wiederholen

```bash
rm /etc/jarvis-setup.done
systemctl restart jarvis-os-first-boot
```

### LXC nicht gestartet

```bash
pct status 20    # CasaOS
pct start 20
journalctl -u pve-guests -n 50
```

### LUKS-Partition vergessen

```bash
lsblk -f | grep crypto_LUKS
cryptsetup luksDump /dev/sda3   # Slots anzeigen
```

### ZFS Pool nicht entsperrt

```bash
zpool status
zfs get keystatus
bash /usr/local/bin/zfs-unlock.sh  # manuell
```
