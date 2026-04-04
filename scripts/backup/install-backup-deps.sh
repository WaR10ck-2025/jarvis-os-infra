#!/bin/bash
# install-backup-deps.sh — Backup-Abhängigkeiten auf Proxmox-Host einrichten
# Einmalig ausführen nach Proxmox-Installation.
# Idempotent: mehrfach ausführbar ohne Schaden.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"

# Config laden
if [ ! -f "$CONFIG_FILE" ]; then
  echo "  ✗ $CONFIG_FILE nicht gefunden — ist das Repo unter /opt/openclaw?"
  echo "    git clone https://github.com/WaR10ck-2025/openclaw-proxmox.git /opt/openclaw"
  exit 1
fi
source "$CONFIG_FILE"

echo "► OpenClaw Backup-System: Abhängigkeiten installieren..."
echo ""

# ── 1. Basis-Pakete ──────────────────────────────────────────────────────────
echo "  → Basis-Pakete prüfen..."
apt-get update -qq 2>/dev/null
PKGS_NEEDED=""
for pkg in git curl wget tar rsync cifs-utils nfs-common sqlite3; do
  if ! dpkg -l "$pkg" &>/dev/null; then
    PKGS_NEEDED="$PKGS_NEEDED $pkg"
  fi
done
if [ -n "$PKGS_NEEDED" ]; then
  apt-get install -y -qq $PKGS_NEEDED
  echo "  ✓ Installiert:$PKGS_NEEDED"
else
  echo "  ✓ Basis-Pakete bereits vorhanden"
fi

# ── 2. age (Verschlüsselung) ─────────────────────────────────────────────────
echo "  → age prüfen..."
if ! command -v age &>/dev/null; then
  echo "    → age herunterladen..."
  AGE_VERSION=$(curl -s "https://api.github.com/repos/FiloSottile/age/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)
  AGE_VERSION="${AGE_VERSION:-v1.1.1}"
  curl -fsSLo /tmp/age.tar.gz \
    "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
  tar -xzf /tmp/age.tar.gz -C /tmp/
  install -m 755 /tmp/age/age /usr/local/bin/age
  install -m 755 /tmp/age/age-keygen /usr/local/bin/age-keygen
  rm -rf /tmp/age /tmp/age.tar.gz
  echo "  ✓ age $(age --version 2>/dev/null | head -1) installiert"
else
  echo "  ✓ age bereits vorhanden ($(age --version 2>/dev/null | head -1))"
fi

# ── 3. age-Schlüssel generieren ──────────────────────────────────────────────
mkdir -p /root/.age && chmod 700 /root/.age
if [ ! -f "/root/.age/key.txt" ]; then
  echo "  → age-Schlüsselpaar generieren..."
  age-keygen -o /root/.age/key.txt 2>/dev/null
  chmod 600 /root/.age/key.txt
  AGE_PUBKEY_GENERATED=$(grep "^# public key:" /root/.age/key.txt | cut -d' ' -f4)
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║                    age-Schlüssel generiert                   ║"
  echo "  ╠══════════════════════════════════════════════════════════════╣"
  echo "  ║  Public Key:                                                  ║"
  echo "  ║  $AGE_PUBKEY_GENERATED"
  echo "  ╠══════════════════════════════════════════════════════════════╣"
  echo "  ║  AKTION ERFORDERLICH:                                         ║"
  echo "  ║  1. Public Key in config/backup.conf eintragen:               ║"
  echo "  ║     AGE_PUBKEY=\"$AGE_PUBKEY_GENERATED\""
  echo "  ║  2. Privaten Key SEPARAT sichern (Passwort-Manager, USB):     ║"
  echo "  ║     cat /root/.age/key.txt                                    ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo ""
else
  echo "  ✓ age-Schlüssel bereits vorhanden (/root/.age/key.txt)"
fi

# ── 4. rclone (für Backblaze B2) ─────────────────────────────────────────────
echo "  → rclone prüfen..."
if ! command -v rclone &>/dev/null; then
  echo "    → rclone installieren..."
  curl -fsSL https://rclone.org/install.sh | bash 2>/dev/null
  echo "  ✓ rclone $(rclone --version 2>/dev/null | head -1) installiert"
else
  echo "  ✓ rclone bereits vorhanden ($(rclone --version 2>/dev/null | head -1 | cut -d' ' -f2))"
fi

# ── 5. Mount-Points anlegen ──────────────────────────────────────────────────
echo "  → Mount-Points anlegen..."
mkdir -p "$BACKUP_USB_MOUNT"
mkdir -p "$BACKUP_NETWORK_MOUNT"
echo "  ✓ $BACKUP_USB_MOUNT und $BACKUP_NETWORK_MOUNT erstellt"

# ── 6. Log-Verzeichnis ───────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
echo "  ✓ Log-Verzeichnis: $LOG_DIR"

# ── 7. Temp-Verzeichnis ──────────────────────────────────────────────────────
mkdir -p "$TEMP_DIR"
echo "  ✓ Temp-Verzeichnis: $TEMP_DIR"

# ── 8. USB als Proxmox-Storage registrieren ──────────────────────────────────
echo "  → Proxmox-Storage für USB prüfen..."
if ! pvesm list 2>/dev/null | grep -q "$PROXMOX_BACKUP_STORAGE_USB"; then
  mkdir -p "$BACKUP_BASE_DIR_USB/dump"
  pvesm add dir "$PROXMOX_BACKUP_STORAGE_USB" \
    --path "$BACKUP_USB_MOUNT" \
    --content backup \
    --shared 0 2>/dev/null || echo "  ⚠  Proxmox-Storage konnte nicht registriert werden (USB noch nicht eingesteckt?)"
  echo "  ✓ Proxmox-Storage '$PROXMOX_BACKUP_STORAGE_USB' registriert"
else
  echo "  ✓ Proxmox-Storage '$PROXMOX_BACKUP_STORAGE_USB' bereits vorhanden"
fi

# ── 9. NAS-Storage registrieren (falls aktiviert) ────────────────────────────
if [ "$BACKUP_NETWORK_ENABLED" = "true" ]; then
  if ! pvesm list 2>/dev/null | grep -q "$PROXMOX_BACKUP_STORAGE_NAS"; then
    pvesm add dir "$PROXMOX_BACKUP_STORAGE_NAS" \
      --path "$BACKUP_NETWORK_MOUNT" \
      --content backup \
      --shared 0 2>/dev/null || echo "  ⚠  NAS-Storage konnte nicht registriert werden"
    echo "  ✓ Proxmox-Storage '$PROXMOX_BACKUP_STORAGE_NAS' registriert"
  fi
fi

# ── 10. GitHub SSH-Key prüfen ────────────────────────────────────────────────
echo "  → GitHub SSH-Key prüfen..."
if [ ! -f "/root/.ssh/github-backup" ]; then
  echo ""
  echo "  ⚠  Kein GitHub-Backup-SSH-Key gefunden."
  echo "     GitHub-Backup-Repo einrichten:"
  echo "     1. SSH-Key generieren:"
  echo "        ssh-keygen -t ed25519 -f /root/.ssh/github-backup -N '' -C 'proxmox-backup'"
  echo "     2. Public Key auf GitHub als Deploy Key hinzufügen:"
  echo "        cat /root/.ssh/github-backup.pub"
  echo "     3. Repo-URL in config/backup.conf eintragen"
  echo ""
else
  echo "  ✓ GitHub SSH-Key vorhanden (/root/.ssh/github-backup)"
fi

# ── 11. answer.toml Backup-Hinweis ───────────────────────────────────────────
if [ ! -f "/root/openclaw-secrets/answer.toml" ]; then
  echo ""
  echo "  ⚠  KRITISCH: answer.toml nicht gefunden!"
  echo "     Die Datei enthält Proxmox root-Passwort + LUKS-Passphrase."
  echo "     Falls vorhanden, bitte sichern:"
  echo "       mkdir -p /root/openclaw-secrets"
  echo "       cp /path/to/answer.toml /root/openclaw-secrets/"
  echo "     → backup-config.sh wird diese Datei verschlüsselt sichern."
  echo ""
fi

# ── 12. Cron-Job einrichten ──────────────────────────────────────────────────
echo "  → Cron-Job einrichten..."
CRON_FILE="/etc/cron.d/openclaw-backup"
if [ ! -f "$CRON_FILE" ]; then
  cat > "$CRON_FILE" << EOF
# OpenClaw Proxmox Backup — automatische Backups
# Generiert von install-backup-deps.sh am $(date +%Y-%m-%d)

# Layer 1 (Config) + Layer 3 (App-Daten): täglich um 03:00 Uhr
0 3 * * * root ${OPENCLAW_DIR}/scripts/backup/backup-all.sh --layer 1,3 >> ${LOG_DIR}/cron.log 2>&1

# Layer 2 (vzdump): jeden Sonntag um 02:00 Uhr
0 2 * * 0 root ${OPENCLAW_DIR}/scripts/backup/backup-all.sh --layer 2 >> ${LOG_DIR}/cron.log 2>&1
EOF
  chmod 644 "$CRON_FILE"
  echo "  ✓ Cron-Job eingerichtet: $CRON_FILE"
else
  echo "  ✓ Cron-Job bereits vorhanden: $CRON_FILE"
fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║            OpenClaw Backup-System: Setup abgeschlossen       ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Nächste Schritte:                                            ║"
echo "  ║  1. AGE_PUBKEY in config/backup.conf eintragen               ║"
echo "  ║  2. GitHub Deploy-Key einrichten (siehe oben)                 ║"
echo "  ║  3. USB-Festplatte einlegen + label: Backup                   ║"
echo "  ║     mkfs.exfat -L Backup /dev/sdX                            ║"
echo "  ║  4. Backup testen: bash scripts/backup/backup-config.sh       ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Cron-Jobs aktiv: tägl. 03:00 (L1+L3), So. 02:00 (L2)       ║"
echo "  ║  Logs: $LOG_DIR"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
