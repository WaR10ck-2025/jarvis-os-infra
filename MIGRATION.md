# Migration: Umbrel → Proxmox

Schrittweise Anleitung für die Migration aller OpenClaw Services von Umbrel (Docker) zu Proxmox (LXC).

---

## Voraussetzungen

- Proxmox VE 8.x installiert (ISO: https://www.proxmox.com/proxmox-virtual-environment/get-started)
- Gleiche IP wie bisheriger Umbrel-Server **oder** neue IP + DNS-Anpassung
- SSH-Zugriff auf Proxmox als `root`
- LVM-Storage mit min. 200 GB verfügbar (Standard: `local-lvm`)
- Debian 12 Template heruntergeladen (siehe Schritt 1)

---

## Schritt 1 — Proxmox vorbereiten

```bash
# SSH auf Proxmox-Host
ssh root@<proxmox-ip>

# Debian 12 Template herunterladen
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst

# Template prüfen
pveam list local | grep debian-12

# Git klonen
apt install -y git
git clone https://github.com/WaR10ck-2025/wine-docker-manager.git /opt/wine-manager
```

---

## Schritt 2 — Datensicherung auf Umbrel

```bash
# SSH auf Umbrel
ssh umbrel@192.168.10.147

# Wine-Prefix sichern (Wine Registry + installierte Apps)
docker run --rm -v wine-prefix:/data -v /tmp:/backup \
  alpine tar czf /backup/wine-prefix-backup.tar.gz -C /data .

# n8n-Daten sichern
docker run --rm -v n8n_data:/data -v /tmp:/backup \
  alpine tar czf /backup/n8n-backup.tar.gz -C /data .

# Uploads sichern
docker cp wine-manager-api:/uploads /tmp/uploads-backup

# Backups auf lokalen PC kopieren
scp umbrel@192.168.10.147:/tmp/wine-prefix-backup.tar.gz ./
scp umbrel@192.168.10.147:/tmp/n8n-backup.tar.gz ./
scp -r umbrel@192.168.10.147:/tmp/uploads-backup ./
```

---

## Schritt 3 — LXCs anlegen (Master-Skript)

```bash
# Auf Proxmox-Host:
cd /opt/openclaw-proxmox
bash scripts/install-all.sh

# Dauert ca. 10-15 Minuten
# Zeigt Fortschritt: "✓ LXC 102 (pionex-mcp-server): http://192.168.10.102:8000"
```

Alternativ einzeln:

```bash
bash scripts/install-lxc-wine-desktop.sh    # LXC 200
bash scripts/install-lxc-wine-api.sh        # LXC 201
bash scripts/install-lxc-wine-ui.sh         # LXC 202
```

---

## Schritt 4 — Daten wiederherstellen

```bash
# Wine-Prefix in LXC 200 wiederherstellen
scp wine-prefix-backup.tar.gz root@192.168.10.200:/tmp/
pct exec 200 -- bash -c "
  mkdir -p /home/wineuser/.wine
  tar xzf /tmp/wine-prefix-backup.tar.gz -C /home/wineuser/.wine
  chown -R wineuser:wineuser /home/wineuser/.wine
"

# Uploads in LXC 201 wiederherstellen
scp -r uploads-backup/* root@192.168.10.201:/uploads/

# n8n-Daten in LXC 104 wiederherstellen
scp n8n-backup.tar.gz root@192.168.10.104:/tmp/
pct exec 104 -- bash -c "
  docker stop n8n 2>/dev/null || true
  tar xzf /tmp/n8n-backup.tar.gz -C /root/docker/n8n
  docker compose -f /root/docker/n8n/docker-compose.yml up -d
"
```

---

## Schritt 5 — Reverse Proxy konfigurieren

Nginx Proxy Manager unter http://192.168.10.140:81 öffnen:

- Login: `admin@example.com` / `changeme` (beim ersten Start)
- **Passwort sofort ändern!**

Proxy Hosts anlegen:

| Domain | IP:Port | SSL |
|---|---|---|
| wine.local | 192.168.10.202:3000 | optional |
| n8n.local | 192.168.10.104:5678 | optional |
| pioneer.local | 192.168.10.102:8000 | optional |
| casaos.local | 192.168.10.141:80 | optional |

---

## Schritt 6 — CasaOS mit Proxmox API verbinden

```bash
# Auf Proxmox-Host: API-Token für CasaOS anlegen (nur Lese-Zugriff)
pveum user add casaos@pve --password "casaos-readonly"
pveum acl modify / --users casaos@pve --roles PVEAuditor

pveum user token add casaos@pve casaos-token --privsep=0
# Ausgabe: Token-ID und Secret notieren!
```

CasaOS Dashboard (http://192.168.10.141):
- Einstellungen → Proxmox-Integration
- Host: `https://192.168.10.147:8006`
- Token-ID: `casaos@pve!casaos-token`
- Token-Secret: `<gespeichertes Secret>`

---

## Schritt 7 — Windows VM einrichten (optional)

Siehe [scripts/setup-windows-vm.md](scripts/setup-windows-vm.md) für:
- VM 100 anlegen mit KVM-Beschleunigung
- Windows 10 ISO installieren
- USB-Passthrough: FTDI 0403:d6da (Autocom CDP+)
- Autocom CSS/CDP+ Software installieren

---

## Schritt 8 — Umbrel abschalten

```bash
# Erst alle Services auf Proxmox verifizieren!
# Dann Umbrel stoppen:
ssh umbrel@192.168.10.147
sudo shutdown -h now
```

---

## Rollback

Falls etwas schiefgeht — Umbrel läuft weiterhin unverändert bis `sudo shutdown`.

```bash
# Alle Proxmox-LXCs stoppen (Umbrel übernimmt wieder)
for ID in 10 20 101 102 103 104 105 106 107 108 200 201 202 210; do
  pct stop $ID 2>/dev/null || true
done
```

---

## Verifikation nach Migration

```bash
# Health-Checks aller Services
curl -s http://192.168.10.201:4000/health    # Wine API
curl -s http://192.168.10.202:3000           # Wine UI
curl -s http://192.168.10.102:8000/health   # Pionex MCP
curl -s http://192.168.10.104:5678          # n8n
curl -s http://192.168.10.141               # CasaOS

# LXC-Status aller Container
for ID in 10 20 101 102 103 104 105 106 107 108 200 201 202 210; do
  printf "LXC %3d: %s\n" $ID "$(pct status $ID 2>/dev/null || echo 'FEHLT')"
done
```
