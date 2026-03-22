# OpenClaw Proxmox

> **Proxmox VE Homelab Setup** — Ein LXC-Container pro Service, maximale Isolation.
> Inklusive Custom Installer ISO, LUKS2 Disk-Verschlüsselung und optionalem YubiKey-Support.

---

## Was ist das?

Dieses Repo enthält alle Skripte und Konfigurationen um einen **Proxmox VE 8.x Server**
vollständig automatisch einzurichten — von der Installation bis zum laufenden System.

**Prinzip: Ein LXC-Container = Ein Service**

```
Proxmox VE 8.x
├── LXC  10: Nginx Proxy Manager   192.168.10.140  :80 :443 :81
├── LXC  20: CasaOS Dashboard      192.168.10.141  :80
├── LXC 101: Setup-Repair Agent    192.168.10.101  :8007
├── LXC 102: Pionex MCP Server     192.168.10.102  :8000
├── LXC 103: Voice Assistant       192.168.10.103  :8000
├── LXC 104: n8n                   192.168.10.104  :5678
├── LXC 105: SV Niederklein        192.168.10.105  :3001
├── LXC 106: Schützenverein        192.168.10.106  :3002
├── LXC 107: Deployment Hub        192.168.10.107  :8100
├── LXC 108: YubiKey Auth          192.168.10.108  :8110
├── LXC 200: Wine Desktop          192.168.10.200  :5900 :8090
├── LXC 201: Wine API              192.168.10.201  :4000
├── LXC 202: Wine UI               192.168.10.202  :3000
├── LXC 210: usbipd                192.168.10.210  :3240
└── VM  100: Windows OBD2          192.168.10.220  :3389
```

---

## Schnellstart — Autoinstall ISO

```bash
# 1. answer.toml anpassen (Passwörter setzen):
nano autoinstall/answer.toml

# 2. ISO erstellen (auf Linux/WSL2):
sudo bash autoinstall/build-iso.sh --pve-iso proxmox-ve_8.x.iso

# 3. USB erstellen:
dd if=proxmox-openclaw.iso of=/dev/sdX bs=4M status=progress

# 4. Booten → ~8 Min → fertig
```

→ Detaillierte Anleitung: [autoinstall/README.md](autoinstall/README.md)

---

## Struktur

```
openclaw-proxmox/
├── README.md                     # Diese Datei
├── MIGRATION.md                  # Umbrel → Proxmox Schritt-für-Schritt
├── docker-compose.proxmox.yml    # Docker-Compose Override für Proxmox
│
├── autoinstall/                  # Custom ISO + Sicherheits-Setup
│   ├── README.md                 # ISO-Build Anleitung
│   ├── answer.toml               # Proxmox Autoinstall (DHCP + LUKS)
│   ├── build-iso.sh              # ISO erstellen
│   ├── first-boot.sh             # Basis-Plattform beim ersten Boot deployen
│   ├── first-boot.service        # systemd one-shot Unit
│   ├── yubikey-enroll.sh         # [optional] YubiKey FIDO2 LUKS-Enrollment
│   ├── zfs-unlock.sh             # [optional] ZFS Pools beim Boot entsperren
│   ├── zfs-unlock.service        # [optional] systemd Unit
│   └── zfs-pool-create.sh        # [optional] verschlüsselten ZFS Pool anlegen
│
├── scripts/                      # LXC-Deploy-Skripte
│   ├── install-all.sh            # Alle LXCs auf einmal deployen
│   ├── install-lxc-reverse-proxy.sh
│   ├── install-lxc-casaos.sh
│   ├── install-lxc-*.sh          # je ein Skript pro Service
│   └── setup-windows-vm.md       # VM 100 Anleitung
│
└── config/                       # Konfigurationsdateien
    ├── ip-plan.md                # Vollständige IP-Tabelle
    ├── usbipd.service            # systemd Unit für LXC 210
    ├── yubikey-usb-passthrough.md
    └── usb-passthrough-obd2.md
```

---

## Optionen

### A — Autoinstall ISO (empfohlen, fire-and-forget)

Proxmox VE + Basis-Services installieren sich vollautomatisch vom USB-Stick.
→ [autoinstall/README.md](autoinstall/README.md)

### B — Manuelle Installation + Skripte

Proxmox VE manuell installieren, dann LXCs per Skript anlegen:

```bash
# SSH auf Proxmox-Host als root
git clone https://github.com/WaR10ck-2025/openclaw-proxmox.git /opt/openclaw-proxmox
cd /opt/openclaw-proxmox

# Alle LXCs (dauert ~10-15 Min):
bash scripts/install-all.sh

# Oder einzeln:
bash scripts/install-lxc-casaos.sh
bash scripts/install-lxc-wine-desktop.sh
```

### C — Migration von Umbrel

Bestehende Services von Umbrel zu Proxmox migrieren.
→ [MIGRATION.md](MIGRATION.md)

---

## Sicherheit

| Feature | Status |
|---|---|
| LUKS2 Disk-Verschlüsselung | ✅ Immer (Passphrase) |
| YubiKey FIDO2 als LUKS-Schlüssel | ✅ Optional, nachträglich |
| ZFS Native Encryption | ✅ Optional für Datenpools |
| Ohne Unlock: keine LXCs/VMs | ✅ systemd dependency chain |
| YubiKey Fallback | ✅ Passphrase immer gültig |

```bash
# YubiKey nachträglich enrollen:
bash /opt/openclaw-proxmox/autoinstall/yubikey-enroll.sh

# Verschlüsselten ZFS Datenpool anlegen:
bash /opt/openclaw-proxmox/autoinstall/zfs-pool-create.sh
```

---

## Ressourcen-Übersicht

| LXC | Dienst | RAM | Disk |
|---|---|---|---|
| LXC 10 | Nginx Proxy Manager | 256 MB | 4 GB |
| LXC 20 | CasaOS Dashboard | 512 MB | 8 GB |
| LXC 101–108 | OpenClaw Services | 256–1024 MB | 4–16 GB |
| LXC 200 | Wine Desktop | 2048 MB | 16 GB |
| LXC 201–202 | Wine API/UI | 512/256 MB | 8/4 GB |
| LXC 210 | usbipd nativ | 128 MB | 2 GB |
| VM 100 | Windows OBD2 | 3072 MB | 64 GB |
| **Gesamt** | | **~11 GB RAM** | **~163 GB** |

→ Vollständige IP-Tabelle: [config/ip-plan.md](config/ip-plan.md)

---

## Verwandte Projekte

- [wine-docker-manager](https://github.com/WaR10ck-2025/wine-docker-manager) — Wine Desktop Manager (läuft in LXC 200-202)
- [GitHub-Deployment-Connector](https://github.com/WaR10ck-2025/GitHub-Deployment-Connector) — Deployment Hub (LXC 107)
- [Pionex-MCP-Server](https://github.com/WaR10ck-2025/Pionex-MCP-Server) — Pionex Trading MCP (LXC 102)
