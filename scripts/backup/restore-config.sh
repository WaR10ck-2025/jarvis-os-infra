#!/bin/bash
# restore-config.sh — Proxmox-Konfiguration aus Backup wiederherstellen
# Stellt /etc/pve/, /etc/network/, .env-Files und answer.toml wieder her.
#
# Verwendung:
#   restore-config.sh                         # Neuestes Backup (USB)
#   restore-config.sh --from-usb              # Von USB-Festplatte
#   restore-config.sh --from-network          # Von Netzwerkfreigabe
#   restore-config.sh --from-github           # Von GitHub-Repo klonen
#   restore-config.sh --date 2026-03-27       # Bestimmtes Datum
#   restore-config.sh --file /path/to/backup.tar.gz.age  # Direkte Datei

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
LOG_FILE="${LOG_DIR}/restore-config-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR" "$TEMP_DIR"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

# ── Argument-Parsing ─────────────────────────────────────────────────────────
FROM="usb"
RESTORE_DATE=""
RESTORE_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --from-usb)     FROM="usb"; shift ;;
    --from-network) FROM="network"; shift ;;
    --from-github)  FROM="github"; shift ;;
    --date)         RESTORE_DATE="$2"; shift 2 ;;
    --file)         RESTORE_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

log "► Config-Restore starten ($TIMESTAMP, Quelle: $FROM)"

# ── Backup-Datei lokalisieren ─────────────────────────────────────────────────
BACKUP_ARCHIVE=""

if [ -n "$RESTORE_FILE" ]; then
  BACKUP_ARCHIVE="$RESTORE_FILE"
  log "  → Direkte Datei: $BACKUP_ARCHIVE"

elif [ "$FROM" = "usb" ]; then
  USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
  [ -n "$USB_DEV" ] && (mountpoint -q "$BACKUP_USB_MOUNT" || mount "$USB_DEV" "$BACKUP_USB_MOUNT")
  SEARCH_DIR="${BACKUP_BASE_DIR_USB}/configs"
  if [ -n "$RESTORE_DATE" ]; then
    BACKUP_ARCHIVE=$(find "$SEARCH_DIR/$RESTORE_DATE" -name "*.tar.gz.age" 2>/dev/null | head -1)
  else
    BACKUP_ARCHIVE=$(find "$SEARCH_DIR" -name "*.tar.gz.age" -newer /dev/null 2>/dev/null \
      | sort -r | head -1)
  fi

elif [ "$FROM" = "network" ]; then
  if ! mountpoint -q "$BACKUP_NETWORK_MOUNT"; then
    if [ "$BACKUP_NETWORK_TYPE" = "smb" ]; then
      mount -t cifs "//${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}" \
        "$BACKUP_NETWORK_MOUNT" \
        -o "credentials=/etc/backup-credentials,uid=0,gid=0,vers=3.0"
    else
      mount -t nfs "${BACKUP_NETWORK_HOST}:/${BACKUP_NETWORK_SHARE}" "$BACKUP_NETWORK_MOUNT"
    fi
  fi
  SEARCH_DIR="${BACKUP_BASE_DIR_NETWORK}/configs"
  if [ -n "$RESTORE_DATE" ]; then
    BACKUP_ARCHIVE=$(find "$SEARCH_DIR/$RESTORE_DATE" -name "*.tar.gz.age" 2>/dev/null | head -1)
  else
    BACKUP_ARCHIVE=$(find "$SEARCH_DIR" -name "*.tar.gz.age" 2>/dev/null | sort -r | head -1)
  fi

elif [ "$FROM" = "github" ]; then
  log "  → GitHub-Repo klonen..."
  GITHUB_WORK_DIR="${TEMP_DIR}/restore-github-$$"
  git clone --quiet "$GITHUB_REPO" "$GITHUB_WORK_DIR"
  if [ -n "$RESTORE_DATE" ]; then
    BACKUP_ARCHIVE=$(find "${GITHUB_WORK_DIR}/archive/$RESTORE_DATE" -name "*.tar.gz.age" 2>/dev/null | head -1)
  else
    BACKUP_ARCHIVE="${GITHUB_WORK_DIR}/latest/config-backup.tar.gz.age"
  fi
fi

if [ -z "$BACKUP_ARCHIVE" ] || [ ! -f "$BACKUP_ARCHIVE" ]; then
  log_err "Backup-Datei nicht gefunden (Quelle: $FROM, Datum: ${RESTORE_DATE:-neuestes})"
  log_err "Verfügbare Backups prüfen:"
  log_err "  ls ${BACKUP_BASE_DIR_USB}/configs/"
  exit 1
fi

log_ok "Backup gefunden: $BACKUP_ARCHIVE"
BACKUP_SIZE=$(du -sh "$BACKUP_ARCHIVE" | cut -f1)
log "  Größe: $BACKUP_SIZE"

# ── age-Entschlüsselung ───────────────────────────────────────────────────────
WORK_DIR="${TEMP_DIR}/restore-config-$$"
mkdir -p "$WORK_DIR"
trap "rm -rf '$WORK_DIR'" EXIT

if [[ "$BACKUP_ARCHIVE" == *.age ]]; then
  log "  → Entschlüsseln mit age..."
  if [ ! -f "$AGE_KEY_FILE" ]; then
    log_err "age-Key nicht gefunden: $AGE_KEY_FILE"
    log_err "  age-Key auf diesen Host kopieren:"
    log_err "  scp user@other-host:/root/.age/key.txt /root/.age/key.txt"
    exit 1
  fi
  DECRYPTED="${WORK_DIR}/config-backup.tar.gz"
  age --decrypt -i "$AGE_KEY_FILE" "$BACKUP_ARCHIVE" -o "$DECRYPTED"
  log_ok "Entschlüsselt"
else
  DECRYPTED="$BACKUP_ARCHIVE"
  log_warn "Backup ist nicht verschlüsselt!"
fi

# ── Archiv entpacken ──────────────────────────────────────────────────────────
log "  → Archiv entpacken..."
tar -xzf "$DECRYPTED" -C "$WORK_DIR" 2>/dev/null
EXTRACT_DIR=$(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
if [ -z "$EXTRACT_DIR" ]; then
  log_err "Entpacken fehlgeschlagen — leeres Archiv?"
  exit 1
fi
log_ok "Entpackt: $(basename "$EXTRACT_DIR")"

# Backup-Meta anzeigen
if [ -f "$EXTRACT_DIR/backup-meta.txt" ]; then
  log "  Backup-Info:"
  grep "timestamp\|hostname\|proxmox_version" "$EXTRACT_DIR/backup-meta.txt" \
    | while read -r line; do log "    $line"; done
fi

# ── Sicherheitsabfrage ────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║                      ACHTUNG — RESTORE                       ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Folgende Verzeichnisse werden ÜBERSCHRIEBEN:                 ║"
echo "  ║    /etc/pve/                                                  ║"
echo "  ║    /etc/network/interfaces                                    ║"
echo "  ║    .env-Files in den LXCs                                     ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Proxmox-Services werden neu gestartet!                       ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
read -r -p "  Fortfahren? [y/N]: " CONFIRM
[ "${CONFIRM,,}" != "y" ] && { log "Abgebrochen."; exit 0; }

# ── /etc/pve/ wiederherstellen ────────────────────────────────────────────────
if [ -d "$EXTRACT_DIR/pve" ]; then
  log "  → /etc/pve/ wiederherstellen..."
  # Cluster-Service stoppen für konsistenten Restore
  systemctl stop pve-cluster 2>/dev/null || true
  sleep 2

  # Backup von aktuellem Zustand
  cp -a /etc/pve /etc/pve.pre-restore.$(date +%Y%m%d%H%M) 2>/dev/null || true

  rsync -a --delete \
    --exclude="*.lock" \
    --exclude="priv/authorized_keys" \
    "$EXTRACT_DIR/pve/" /etc/pve/ 2>/dev/null

  systemctl start pve-cluster 2>/dev/null || true
  sleep 3
  log_ok "/etc/pve/ wiederhergestellt"
fi

# ── Netzwerk-Konfiguration ────────────────────────────────────────────────────
if [ -f "$EXTRACT_DIR/network/interfaces" ]; then
  log "  → /etc/network/interfaces wiederherstellen..."
  cp /etc/network/interfaces /etc/network/interfaces.pre-restore 2>/dev/null || true
  cp "$EXTRACT_DIR/network/interfaces" /etc/network/interfaces
  log_ok "/etc/network/interfaces wiederhergestellt"
  log_warn "Netzwerk-Neustart nötig: systemctl restart networking"
fi

# ── .env-Files in LXCs zurückspielen ─────────────────────────────────────────
log "  → .env-Files in LXCs zurückspielen..."
LXC_ENV_DIR="$EXTRACT_DIR/lxc-envs"

if [ -f "${LXC_ENV_DIR}/lxc120-casaos-bridge.env" ]; then
  if pct status 120 2>/dev/null | grep -q "running"; then
    pct push 120 "${LXC_ENV_DIR}/lxc120-casaos-bridge.env" \
      "/opt/openclaw-proxmox/casaos-lxc-bridge/.env"
    log_ok "LXC 120: casaos-bridge .env zurückgespielt"
  fi
fi

if [ -f "${LXC_ENV_DIR}/lxc109-nextcloud.env" ]; then
  if pct status 109 2>/dev/null | grep -q "running"; then
    pct push 109 "${LXC_ENV_DIR}/lxc109-nextcloud.env" "/opt/nextcloud/.env"
    log_ok "LXC 109: Nextcloud .env zurückgespielt"
  fi
fi

if [ -f "${LXC_ENV_DIR}/lxc104-n8n.env" ]; then
  if pct status 104 2>/dev/null | grep -q "running"; then
    pct push 104 "${LXC_ENV_DIR}/lxc104-n8n.env" "/root/docker/n8n/.env"
    log_ok "LXC 104: n8n .env zurückgespielt"
  fi
fi

if [ -f "${LXC_ENV_DIR}/lxc125-authentik.env" ]; then
  if pct status 125 2>/dev/null | grep -q "running"; then
    pct push 125 "${LXC_ENV_DIR}/lxc125-authentik.env" "/opt/authentik/.env"
    log_ok "LXC 125: Authentik .env zurückgespielt"
  fi
fi

# Headscale Config + Keys
if [ -f "${LXC_ENV_DIR}/headscale/config.yaml" ] && pct status 115 2>/dev/null | grep -q "running"; then
  pct push 115 "${LXC_ENV_DIR}/headscale/config.yaml" "/etc/headscale/config.yaml"
  [ -f "${LXC_ENV_DIR}/headscale/private.key" ] && \
    pct push 115 "${LXC_ENV_DIR}/headscale/private.key" "/var/lib/headscale/private.key"
  log_ok "LXC 115: Headscale config + key zurückgespielt"
fi

# ── answer.toml ───────────────────────────────────────────────────────────────
if [ -f "$EXTRACT_DIR/answer.toml" ]; then
  mkdir -p /root/openclaw-secrets
  cp "$EXTRACT_DIR/answer.toml" /root/openclaw-secrets/answer.toml
  chmod 600 /root/openclaw-secrets/answer.toml
  log_ok "answer.toml wiederhergestellt → /root/openclaw-secrets/answer.toml"
fi

# ── Proxmox-Services neu starten ─────────────────────────────────────────────
log "  → Proxmox-Services neu starten..."
systemctl restart pvedaemon pveproxy 2>/dev/null && log_ok "Proxmox-Services neu gestartet" || \
  log_warn "Service-Neustart fehlgeschlagen — manuell: systemctl restart pvedaemon pveproxy"

# ── Verifikation ──────────────────────────────────────────────────────────────
log "  → LXC-Liste prüfen:"
pct list 2>/dev/null | tee -a "$LOG_FILE" || true

log ""
log_ok "Config-Restore abgeschlossen"
log "  Log: $LOG_FILE"

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║              Config-Restore abgeschlossen                     ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Nächste Schritte:                                            ║"
echo "  ║  1. LXC-Liste prüfen: pct list                                ║"
echo "  ║  2. Netzwerk neu starten: systemctl restart networking         ║"
echo "  ║  3. LXCs aus vzdump restore:                                  ║"
echo "  ║     bash restore-lxc.sh --lxc 10                              ║"
echo "  ║  4. App-Daten zurückspielen:                                  ║"
echo "  ║     bash restore-appdata.sh --service nextcloud               ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
