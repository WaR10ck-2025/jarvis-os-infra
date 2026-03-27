#!/bin/bash
# backup-config.sh — Layer 1: Proxmox-Konfiguration sichern
# Sichert: /etc/pve/, /etc/network/, .env-Files aus LXCs, answer.toml
# Ziele: USB-Festplatte und/oder GitHub (age-verschlüsselt)
# Läuft auf dem Proxmox-Host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
DATE_DIR=$(date +%Y-%m-%d)
BACKUP_NAME="config-backup-${TIMESTAMP}"
WORK_DIR="${TEMP_DIR}/${BACKUP_NAME}"
LOG_FILE="${LOG_DIR}/backup-config-${DATE_DIR}.log"

mkdir -p "$LOG_DIR" "$TEMP_DIR"

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

ERRORS=0
notify() {
  local status="$1" msg="$2"
  if [ "$NTFY_ENABLED" = "true" ] && [ -n "$NTFY_URL" ]; then
    local prio="default"; local tags="floppy_disk"
    [ "$status" = "error" ] && prio="urgent" && tags="warning"
    curl -s -X POST "$NTFY_URL" \
      -H "Title: OpenClaw Backup L1 ${status^^}" \
      -H "Priority: $prio" -H "Tags: $tags" \
      -d "$msg" -o /dev/null 2>/dev/null || true
  fi
}

log "► Layer 1: Config-Backup starten ($TIMESTAMP)"

# ── Ziel-Ermittlung ───────────────────────────────────────────────────────────
TARGET_USB=false
TARGET_NETWORK=false
TARGET_GITHUB=false

IFS=',' read -ra TARGETS <<< "$BACKUP_TARGETS"
for t in "${TARGETS[@]}"; do
  case "$(echo "$t" | tr -d ' ')" in
    usb)     TARGET_USB=true ;;
    network) TARGET_NETWORK=true ;;
    github)  TARGET_GITHUB=true ;;
  esac
done

# ── USB mounten ───────────────────────────────────────────────────────────────
USB_OK=false
if [ "$TARGET_USB" = "true" ]; then
  log "  → USB-Festplatte mounten..."
  USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
  if [ -n "$USB_DEV" ]; then
    mountpoint -q "$BACKUP_USB_MOUNT" || mount "$USB_DEV" "$BACKUP_USB_MOUNT"
    mkdir -p "${BACKUP_BASE_DIR_USB}/configs"
    USB_OK=true
    log_ok "USB gemountet: $USB_DEV → $BACKUP_USB_MOUNT"
  else
    log_warn "USB-Festplatte nicht gefunden (Label: $BACKUP_USB_LABEL)"
    ERRORS=$((ERRORS + 1))
  fi
fi

# ── Netzwerkfreigabe mounten ───────────────────────────────────────────────────
NETWORK_OK=false
if [ "$TARGET_NETWORK" = "true" ] && [ "$BACKUP_NETWORK_ENABLED" = "true" ]; then
  log "  → Netzwerkfreigabe mounten (${BACKUP_NETWORK_TYPE})..."
  if ping -c1 -W3 "$BACKUP_NETWORK_HOST" &>/dev/null; then
    if ! mountpoint -q "$BACKUP_NETWORK_MOUNT"; then
      if [ "$BACKUP_NETWORK_TYPE" = "smb" ]; then
        mount -t cifs "//${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}" \
          "$BACKUP_NETWORK_MOUNT" \
          -o "credentials=/etc/backup-credentials,uid=0,gid=0,vers=3.0" 2>/dev/null
      else
        mount -t nfs "${BACKUP_NETWORK_HOST}:/${BACKUP_NETWORK_SHARE}" \
          "$BACKUP_NETWORK_MOUNT" 2>/dev/null
      fi
    fi
    mkdir -p "${BACKUP_BASE_DIR_NETWORK}/configs"
    NETWORK_OK=true
    log_ok "Netzwerkfreigabe gemountet: ${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}"
  else
    log_warn "NAS nicht erreichbar: $BACKUP_NETWORK_HOST — übersprungen"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Prüfen ob mindestens ein Ziel verfügbar
if [ "$USB_OK" = "false" ] && [ "$NETWORK_OK" = "false" ] && [ "$TARGET_GITHUB" = "false" ]; then
  log_err "Kein Backup-Ziel verfügbar — Abbruch"
  notify "error" "Layer 1 fehlgeschlagen: Kein Backup-Ziel verfügbar"
  exit 1
fi

# ── Arbeitsverzeichnis anlegen ────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
trap "rm -rf '$WORK_DIR'" EXIT

# ── /etc/pve/ sichern ─────────────────────────────────────────────────────────
log "  → /etc/pve/ sichern..."
mkdir -p "${WORK_DIR}/pve"
rsync -a --exclude='*.lock' --exclude='*.tmp' \
  /etc/pve/ "${WORK_DIR}/pve/" 2>/dev/null
log_ok "/etc/pve/ gesichert"

# ── Netzwerk-Konfiguration ────────────────────────────────────────────────────
log "  → Netzwerk-Konfiguration sichern..."
mkdir -p "${WORK_DIR}/network"
cp /etc/network/interfaces "${WORK_DIR}/network/" 2>/dev/null || true
cp /etc/hosts "${WORK_DIR}/network/" 2>/dev/null || true
log_ok "Netzwerk-Konfiguration gesichert"

# ── .env-Files aus LXCs holen ────────────────────────────────────────────────
log "  → .env-Files aus LXCs sichern..."
mkdir -p "${WORK_DIR}/lxc-envs"

collect_from_lxc() {
  local lxc_id="$1" src="$2" dst_name="$3"
  if pct status "$lxc_id" 2>/dev/null | grep -q "running"; then
    pct exec "$lxc_id" -- bash -c "cat '$src' 2>/dev/null || true" \
      > "${WORK_DIR}/lxc-envs/${dst_name}" 2>/dev/null
    if [ -s "${WORK_DIR}/lxc-envs/${dst_name}" ]; then
      log_ok "LXC $lxc_id: $src → ${dst_name}"
    else
      log_warn "LXC $lxc_id: $src nicht gefunden oder leer"
      rm -f "${WORK_DIR}/lxc-envs/${dst_name}"
    fi
  else
    log_warn "LXC $lxc_id nicht laufend — .env übersprungen"
  fi
}

collect_from_lxc 120 "/opt/openclaw-proxmox/casaos-lxc-bridge/.env" "lxc120-casaos-bridge.env"
collect_from_lxc 109 "/opt/nextcloud/.env"                           "lxc109-nextcloud.env"
collect_from_lxc 104 "/root/docker/n8n/.env"                         "lxc104-n8n.env"
collect_from_lxc 125 "/opt/authentik/.env"                           "lxc125-authentik.env"

# Headscale: Config + Private Key
if pct status 115 2>/dev/null | grep -q "running"; then
  mkdir -p "${WORK_DIR}/lxc-envs/headscale"
  pct exec 115 -- bash -c "cat /etc/headscale/config.yaml 2>/dev/null || true" \
    > "${WORK_DIR}/lxc-envs/headscale/config.yaml" 2>/dev/null
  pct exec 115 -- bash -c "cat /var/lib/headscale/private.key 2>/dev/null || true" \
    > "${WORK_DIR}/lxc-envs/headscale/private.key" 2>/dev/null
  log_ok "LXC 115: Headscale config + private.key gesichert"
fi

# Nginx Proxy Manager: DB + Letsencrypt
if pct status 10 2>/dev/null | grep -q "running"; then
  mkdir -p "${WORK_DIR}/lxc-envs/nginx-pm"
  pct exec 10 -- bash -c "
    if command -v docker &>/dev/null; then
      docker exec \$(docker ps --filter name=npm --format '{{.Names}}' | head -1) \
        sqlite3 /data/database.sqlite .dump 2>/dev/null | gzip > /tmp/npm-db.sql.gz
      cat /tmp/npm-db.sql.gz
    fi
  " > "${WORK_DIR}/lxc-envs/nginx-pm/database.sql.gz" 2>/dev/null || true
  log_ok "LXC 10: Nginx PM Datenbank gesichert"
fi

log_ok ".env-Files gesammelt"

# ── answer.toml sichern (falls vorhanden) ────────────────────────────────────
log "  → answer.toml prüfen..."
if [ -f "/root/openclaw-secrets/answer.toml" ]; then
  cp "/root/openclaw-secrets/answer.toml" "${WORK_DIR}/answer.toml"
  log_ok "answer.toml eingeschlossen"
else
  log_warn "answer.toml nicht gefunden (/root/openclaw-secrets/answer.toml)"
fi

# ── Meta-Info ─────────────────────────────────────────────────────────────────
cat > "${WORK_DIR}/backup-meta.txt" << EOF
backup_type: config
timestamp: ${TIMESTAMP}
hostname: $(hostname)
proxmox_version: $(pveversion 2>/dev/null | head -1 || echo "unknown")
lxc_list: $(pct list 2>/dev/null | tail -n+2 | awk '{print $1}' | tr '\n' ' ')
vm_list: $(qm list 2>/dev/null | tail -n+2 | awk '{print $1}' | tr '\n' ' ')
EOF

# ── tar.gz packen ────────────────────────────────────────────────────────────
log "  → Archiv erstellen..."
ARCHIVE="${TEMP_DIR}/${BACKUP_NAME}.tar.gz"
tar -czf "$ARCHIVE" -C "$TEMP_DIR" "$BACKUP_NAME"
ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
log_ok "Archiv: $ARCHIVE ($ARCHIVE_SIZE)"

# ── age-Verschlüsselung ───────────────────────────────────────────────────────
log "  → Verschlüsseln mit age..."
ENCRYPTED="${TEMP_DIR}/${BACKUP_NAME}.tar.gz.age"
if [ -z "$AGE_PUBKEY" ]; then
  log_err "AGE_PUBKEY ist leer — bitte in config/backup.conf eintragen"
  log_err "  age-keygen -o /root/.age/key.txt && cat /root/.age/key.txt"
  ERRORS=$((ERRORS + 1))
  # Unverschlüsselt fortfahren (nur lokale USB, KEIN GitHub-Upload!)
  ENCRYPTED="${TEMP_DIR}/${BACKUP_NAME}.tar.gz"
  SKIP_GITHUB=true
else
  age --encrypt --recipient "$AGE_PUBKEY" -o "$ENCRYPTED" "$ARCHIVE"
  rm -f "$ARCHIVE"
  log_ok "Verschlüsselt: $(basename "$ENCRYPTED")"
  SKIP_GITHUB=false
fi

# ── Auf USB ablegen ───────────────────────────────────────────────────────────
if [ "$USB_OK" = "true" ]; then
  log "  → USB: Backup ablegen..."
  USB_CONFIG_DIR="${BACKUP_BASE_DIR_USB}/configs/${DATE_DIR}"
  mkdir -p "$USB_CONFIG_DIR"
  cp "$ENCRYPTED" "${USB_CONFIG_DIR}/"
  log_ok "USB: $(basename "$ENCRYPTED") gespeichert"

  # Retention: Alte Backups löschen
  log "  → USB: Retention ($RETENTION_CONFIG_DAYS Tage)..."
  find "${BACKUP_BASE_DIR_USB}/configs/" -maxdepth 2 -name "*.tar.gz*" \
    -mtime "+$RETENTION_CONFIG_DAYS" -delete 2>/dev/null || true
  find "${BACKUP_BASE_DIR_USB}/configs/" -maxdepth 1 -mindepth 1 -type d \
    -empty -delete 2>/dev/null || true
  log_ok "USB: Retention angewendet"
fi

# ── Auf Netzwerkfreigabe ablegen ──────────────────────────────────────────────
if [ "$NETWORK_OK" = "true" ]; then
  log "  → NAS: Backup ablegen..."
  NAS_CONFIG_DIR="${BACKUP_BASE_DIR_NETWORK}/configs/${DATE_DIR}"
  mkdir -p "$NAS_CONFIG_DIR"
  cp "$ENCRYPTED" "${NAS_CONFIG_DIR}/"
  log_ok "NAS: $(basename "$ENCRYPTED") gespeichert"

  find "${BACKUP_BASE_DIR_NETWORK}/configs/" -maxdepth 2 -name "*.tar.gz*" \
    -mtime "+$RETENTION_CONFIG_DAYS" -delete 2>/dev/null || true
  log_ok "NAS: Retention angewendet"
fi

# ── GitHub-Sync ────────────────────────────────────────────────────────────────
if [ "$TARGET_GITHUB" = "true" ] && [ "${SKIP_GITHUB:-false}" = "false" ]; then
  log "  → GitHub: Config-Backup pushen..."
  GITHUB_WORK_DIR="${TEMP_DIR}/github-configs"
  rm -rf "$GITHUB_WORK_DIR"

  # Repo klonen oder pullen
  if git clone --quiet "$GITHUB_REPO" "$GITHUB_WORK_DIR" 2>/dev/null; then
    log_ok "GitHub-Repo geklont"
  else
    log_err "GitHub-Repo konnte nicht geklont werden (SSH-Key konfiguriert?)"
    ERRORS=$((ERRORS + 1))
  fi

  if [ -d "$GITHUB_WORK_DIR" ]; then
    mkdir -p "${GITHUB_WORK_DIR}/latest"
    mkdir -p "${GITHUB_WORK_DIR}/archive/${DATE_DIR}"

    BACKUP_FILENAME="${BACKUP_NAME}.tar.gz.age"
    cp "$ENCRYPTED" "${GITHUB_WORK_DIR}/latest/config-backup.tar.gz.age"
    cp "$ENCRYPTED" "${GITHUB_WORK_DIR}/archive/${DATE_DIR}/${BACKUP_FILENAME}"

    # answer.toml separat verschlüsseln (falls vorhanden und noch nicht eingeschlossen)
    if [ -f "/root/openclaw-secrets/answer.toml" ] && [ -n "$AGE_PUBKEY" ]; then
      age --encrypt --recipient "$AGE_PUBKEY" \
        "/root/openclaw-secrets/answer.toml" \
        -o "${GITHUB_WORK_DIR}/latest/answer.toml.age"
      log_ok "answer.toml separat verschlüsselt auf GitHub"
    fi

    # README anlegen falls nicht vorhanden
    if [ ! -f "${GITHUB_WORK_DIR}/README.md" ]; then
      cat > "${GITHUB_WORK_DIR}/README.md" << 'EOF'
# openclaw-proxmox-configs

Automatisch generierte verschlüsselte Konfigurations-Backups für OpenClaw-Proxmox.

## Entschlüsseln

```bash
# age-Key muss vorhanden sein unter /root/.age/key.txt
age --decrypt -i /root/.age/key.txt latest/config-backup.tar.gz.age > config-backup.tar.gz
tar -xzf config-backup.tar.gz
```

## Restore

Siehe [backup-restore-guide.md](https://github.com/WaR10ck-2025/openclaw-proxmox/blob/main/docs/backup-restore-guide.md)
EOF
    fi

    cd "$GITHUB_WORK_DIR"
    git config user.email "proxmox-backup@openclaw"
    git config user.name "OpenClaw Backup"
    git add -A
    git diff --cached --quiet || git commit -m "backup: config ${TIMESTAMP}"
    git push --quiet origin main
    log_ok "GitHub: Config-Backup gepusht ($TIMESTAMP)"
  fi
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$ENCRYPTED" 2>/dev/null || true
rm -rf "${GITHUB_WORK_DIR:-}" 2>/dev/null || true

# ── Notification ──────────────────────────────────────────────────────────────
if [ "$ERRORS" -eq 0 ]; then
  MSG="Layer 1 OK: Config-Backup $TIMESTAMP abgeschlossen ($ARCHIVE_SIZE)"
  log_ok "Layer 1 abgeschlossen — $MSG"
  notify "success" "$MSG"
else
  MSG="Layer 1 mit $ERRORS Warnungen: Config-Backup $TIMESTAMP ($ARCHIVE_SIZE)"
  log_warn "$MSG"
  notify "warning" "$MSG"
fi

exit 0
