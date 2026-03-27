# OpenClaw Proxmox — Backup & Restore Guide

## Übersicht

Das OpenClaw-Backup-System sichert die gesamte Proxmox-Infrastruktur nach der **3-2-1-Strategie**:

| Layer | Inhalt | Rhythmus | Ziele |
|-------|--------|----------|-------|
| **L1 Config** | `/etc/pve/`, `.env`-Files, `answer.toml` | Täglich 03:00 | USB + GitHub (verschlüsselt) |
| **L2 vzdump** | Vollständige LXC/VM-Archive | Sonntag 02:00 | USB oder NAS |
| **L3 App-Data** | MariaDB, n8n, Headscale, Authentik | Täglich 03:00 | USB oder NAS + optional B2 |

---

## Schnellstart: Backup-System einrichten

### 1. Abhängigkeiten installieren (einmalig)

```bash
# Auf dem Proxmox-Host (als root):
bash /opt/openclaw/scripts/backup/install-backup-deps.sh
```

Das Script installiert automatisch: `age`, `rclone`, Git, USB-Mount-Points, Cron-Jobs.

### 2. Konfiguration anpassen

```bash
nano /opt/openclaw/config/backup.conf
```

Wichtige Werte:
- `BACKUP_TARGETS="usb,github"` — Ziele aktivieren
- `AGE_PUBKEY="age1..."` — Public Key nach `age-keygen` eintragen
- `NTFY_URL="https://ntfy.sh/openclaw-..."` — Push-Notifications
- `BACKUP_NETWORK_ENABLED=true` — NAS aktivieren (optional)

### 3. USB-Festplatte formatieren

```bash
# Gerät ermitteln (ACHTUNG: richtiges Gerät wählen!)
lsblk
fdisk -l | grep -E "^Disk /dev/sd"

# Formatieren mit Label (ersetzt alle Daten!):
mkfs.ext4 -L OPENCLAW-BAK /dev/sdX
```

### 4. age-Key sichern

```bash
# Public Key anzeigen (für backup.conf):
grep "public key" /root/.age/key.txt

# Privaten Key JETZT extern sichern (Passwort-Manager / Ausdruck):
cat /root/.age/key.txt
```

> **KRITISCH:** Ohne den privaten Key können GitHub-Backups nie entschlüsselt werden!

### 5. Backup testen

```bash
# Layer 1 manuell testen:
bash /opt/openclaw/scripts/backup/backup-config.sh

# Alle Layer testen:
bash /opt/openclaw/scripts/backup/backup-all.sh --layer all
```

---

## Backup-Ziele

### USB-Festplatte

Standard-Ziel. Festplatte mit Label `OPENCLAW-BAK` wird automatisch erkannt.

```bash
# USB-Status prüfen:
blkid -L OPENCLAW-BAK
df -h /mnt/backup-usb/
```

### Netzwerkfreigabe (SMB/NFS)

NAS im Heimnetz (Synology, TrueNAS, QNAP).

```bash
# In backup.conf aktivieren:
BACKUP_NETWORK_ENABLED=true
BACKUP_NETWORK_TYPE="smb"          # oder "nfs"
BACKUP_NETWORK_HOST="192.168.10.50"
BACKUP_NETWORK_SHARE="proxmox-backup"

# SMB-Credentials:
cp /opt/openclaw/secrets/backup-credentials.example /etc/backup-credentials
nano /etc/backup-credentials       # Zugangsdaten eintragen
chmod 600 /etc/backup-credentials
```

### GitHub (verschlüsselt)

Nur für Layer 1 (Configs, ~50 MB). Benötigt separates privates Repo.

```bash
# SSH-Key für GitHub generieren:
ssh-keygen -t ed25519 -f /root/.ssh/github-backup -N '' -C 'proxmox-backup'
cat /root/.ssh/github-backup.pub    # Deploy Key → GitHub-Repo → Settings → Deploy Keys

# In backup.conf:
GITHUB_REPO="git@github.com:WaR10ck-2025/openclaw-proxmox-configs.git"
AGE_PUBKEY="age1..."
```

### Backblaze B2 (optional, App-Daten)

Off-Site Cloud-Backup für Layer 3.

```bash
# Template anpassen:
cp /opt/openclaw/secrets/rclone.conf.example /etc/rclone.conf
nano /etc/rclone.conf               # B2-Credentials eintragen

# In backup.conf:
B2_ENABLED=true
B2_RCLONE_REMOTE="b2-openclaw-crypt"
```

---

## Automatische Backups

Die Cron-Jobs werden von `install-backup-deps.sh` eingerichtet:

```cron
# /etc/cron.d/openclaw-backup
0 3 * * *   root  backup-all.sh --layer 1,3    # täglich 03:00 (Config + App-Daten)
0 2 * * 0   root  backup-all.sh --layer 2       # Sonntag 02:00 (vzdump)
```

```bash
# Status prüfen:
cat /etc/cron.d/openclaw-backup
tail -50 /var/log/openclaw-backup/cron.log
```

---

## Manuelles Backup

```bash
# Alle Layer:
bash /opt/openclaw/scripts/backup/backup-all.sh

# Einzelne Layer:
bash /opt/openclaw/scripts/backup/backup-config.sh     # L1: Config
bash /opt/openclaw/scripts/backup/backup-appdata.sh    # L3: App-Daten
bash /opt/openclaw/scripts/backup/backup-vzdump.sh     # L2: vzdump (USB nötig!)

# Nur Layer 1 + 3:
bash /opt/openclaw/scripts/backup/backup-all.sh --layer 1,3
```

---

## Restore-Optionen

### Einzelne LXC/VM aus vzdump wiederherstellen

```bash
# Neuestes Backup:
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 109

# Bestimmtes Datum:
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 109 --date 2026-03-27

# VM (Windows OBD2):
bash /opt/openclaw/scripts/backup/restore-lxc.sh --vm 100

# Anderer Storage:
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 109 --storage local-lvm
```

### App-Daten zurückspielen

```bash
# Einzelner Service:
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service nextcloud
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service n8n
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service headscale
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service authentik

# Alle Services:
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service all

# Bestimmtes Datum:
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service nextcloud --date 2026-03-20
```

### Proxmox-Konfiguration wiederherstellen

```bash
# Von USB:
bash /opt/openclaw/scripts/backup/restore-config.sh --from-usb

# Von GitHub:
bash /opt/openclaw/scripts/backup/restore-config.sh --from-github

# Von NAS:
bash /opt/openclaw/scripts/backup/restore-config.sh --from-network

# Bestimmtes Datum:
bash /opt/openclaw/scripts/backup/restore-config.sh --from-usb --date 2026-03-27
```

---

## Full-Restore: Neue Hardware

> **Geschätzte Dauer: 90–120 Minuten**

### Option A: Interaktiver Assistent (empfohlen)

```bash
bash /opt/openclaw/scripts/backup/restore-full.sh
```

Der Assistent führt durch alle 6 Phasen mit Bestätigungsabfragen.

### Option B: Manuell

**Phase 1: Proxmox installieren (10–20 Min)**
```bash
# proxmox-openclaw.iso flashen + booten
# Autoinstall läuft automatisch durch
# SSH: ssh root@192.168.10.147
```

**Phase 2: Repo + Tools (5 Min)**
```bash
git clone https://github.com/WaR10ck-2025/openclaw-proxmox.git /opt/openclaw
bash /opt/openclaw/scripts/backup/install-backup-deps.sh
# age-Key auf Host kopieren: mkdir -p /root/.age && nano /root/.age/key.txt
```

**Phase 3: Config wiederherstellen (5 Min)**
```bash
bash /opt/openclaw/scripts/backup/restore-config.sh --from-usb
# ODER von GitHub:
bash /opt/openclaw/scripts/backup/restore-config.sh --from-github
```

**Phase 4: LXCs in Reihenfolge (30–60 Min)**

> Reihenfolge ist kritisch wegen Abhängigkeiten!

```bash
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 10   # Nginx PM (zuerst!)
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 115  # Headscale
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 125  # Authentik
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 109  # Nextcloud
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 104  # n8n
bash /opt/openclaw/scripts/backup/restore-lxc.sh --lxc 120  # CasaOS Bridge
bash /opt/openclaw/scripts/backup/restore-lxc.sh --vm  100  # Windows VM
```

**Phase 5: App-Daten (20–40 Min)**
```bash
bash /opt/openclaw/scripts/backup/restore-appdata.sh --service all
```

**Phase 6: Validierung (10 Min)**
```bash
pct list
qm list
curl -s -o /dev/null -w "%{http_code}" http://192.168.10.140:81  # Nginx PM
curl -s -o /dev/null -w "%{http_code}" http://192.168.10.109     # Nextcloud
curl -s -o /dev/null -w "%{http_code}" http://192.168.10.104:5678 # n8n
```

---

## Backup-Verzeichnisstruktur

```
/mnt/backup-usb/openclaw-backups/
├── configs/
│   ├── 2026-03-27/
│   │   └── config-backup-2026-03-27_03-00.tar.gz.age
│   └── 2026-03-28/
│       └── config-backup-2026-03-28_03-00.tar.gz.age
├── dump/
│   ├── vzdump-lxc-10-2026-03-27_02-00-00.vma.zst
│   ├── vzdump-lxc-109-2026-03-27_02-15-00.vma.zst
│   ├── vzdump-qemu-100-2026-03-27_03-30-00.vma.zst
│   └── manifest-2026-03-27.sha256
└── appdata/
    ├── 2026-03-27/
    │   ├── nextcloud/
    │   │   ├── nextcloud-db-2026-03-27.sql.gz
    │   │   └── nextcloud-data-2026-03-27.tar.gz
    │   ├── n8n/
    │   │   ├── n8n-workflows-2026-03-27.json
    │   │   └── n8n-volume-2026-03-27.tar.gz
    │   ├── headscale/
    │   │   ├── headscale-2026-03-27.sqlite
    │   │   └── headscale-config-2026-03-27.tar.gz
    │   └── authentik/
    │       └── authentik-db-2026-03-27.sql.gz
    └── manifest.sha256
```

---

## Backup manuell entschlüsseln

```bash
# Config-Backup von GitHub entschlüsseln:
age --decrypt -i /root/.age/key.txt config-backup-2026-03-27.tar.gz.age \
  > config-backup.tar.gz
tar -xzf config-backup.tar.gz
ls config-backup-2026-03-27_03-00/
```

---

## Logs

```bash
# Letzte Backup-Logs:
tail -100 /var/log/openclaw-backup/backup-all-$(date +%Y-%m-%d).log

# Cron-Log:
tail -50 /var/log/openclaw-backup/cron.log

# rclone-Log (B2):
tail -50 /var/log/openclaw-backup/rclone-$(date +%Y-%m-%d).log

# Alle Logs:
ls -lt /var/log/openclaw-backup/
```

---

## Wichtige Hinweise

### Kritische Secrets

| Secret | Pfad | Backup-Ziel |
|--------|------|-------------|
| `answer.toml` | `/root/openclaw-secrets/answer.toml` | GitHub (verschlüsselt) via L1 |
| age-Private-Key | `/root/.age/key.txt` | **Manuell** — Passwort-Manager/Ausdruck |
| Proxmox API-Token | in `/etc/pve/` | GitHub (verschlüsselt) via L1 |
| `.env`-Files | in LXCs | GitHub (verschlüsselt) via L1 |

### Nicht im Repo

- `secrets/` — enthält nur `.gitignore` und Beispiel-Dateien
- `autoinstall/answer.toml` — ist in `.gitignore`
- `/root/.age/key.txt` — NIEMALS commiten

### Speicherplatz-Bedarf

| Layer | Häufigkeit | Größe (Schätzung) | Gesamt (30 Tage) |
|-------|-----------|-------------------|------------------|
| L1 Config | täglich | ~15 MB | ~450 MB |
| L2 vzdump | wöchentlich | ~50 GB | ~150 GB (3 Gen.) |
| L3 App-Data | täglich | ~1.5 GB | ~21 GB |
| **Gesamt** | | | **~172 GB** |

Empfohlen: **500 GB USB-Festplatte** oder entsprechender NAS-Share.
