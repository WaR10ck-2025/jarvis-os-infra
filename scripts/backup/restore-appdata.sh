#!/bin/bash
# restore-appdata.sh — App-Daten (DB-Dumps, n8n-Workflows) wiederherstellen
#
# Verwendung:
#   restore-appdata.sh --service nextcloud           # Neuestes Backup
#   restore-appdata.sh --service n8n --date 2026-03-27
#   restore-appdata.sh --service headscale
#   restore-appdata.sh --service authentik
#   restore-appdata.sh --service all                 # Alle Services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
LOG_FILE="${LOG_DIR}/restore-appdata-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

# ── Argument-Parsing ─────────────────────────────────────────────────────────
SERVICE=""
RESTORE_DATE="latest"

while [[ $# -gt 0 ]]; do
  case $1 in
    --service) SERVICE="$2"; shift 2 ;;
    --date)    RESTORE_DATE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$SERVICE" ]; then
  echo "Verwendung: $0 --service <nextcloud|n8n|headscale|authentik|all> [--date YYYY-MM-DD|latest]"
  exit 1
fi

log "► App-Data-Restore: $SERVICE ($RESTORE_DATE)"

# ── Backup-Verzeichnis ermitteln ──────────────────────────────────────────────
APPDATA_BASE=""

USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
if [ -n "$USB_DEV" ]; then
  mountpoint -q "$BACKUP_USB_MOUNT" || mount "$USB_DEV" "$BACKUP_USB_MOUNT"
  APPDATA_BASE="${BACKUP_BASE_DIR_USB}/appdata"
fi

if [ -z "$APPDATA_BASE" ] && [ "$BACKUP_NETWORK_ENABLED" = "true" ]; then
  if ping -c1 -W3 "$BACKUP_NETWORK_HOST" &>/dev/null; then
    mountpoint -q "$BACKUP_NETWORK_MOUNT" || {
      if [ "$BACKUP_NETWORK_TYPE" = "smb" ]; then
        mount -t cifs "//${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}" \
          "$BACKUP_NETWORK_MOUNT" \
          -o "credentials=/etc/backup-credentials,uid=0,gid=0,vers=3.0"
      else
        mount -t nfs "${BACKUP_NETWORK_HOST}:/${BACKUP_NETWORK_SHARE}" "$BACKUP_NETWORK_MOUNT"
      fi
    }
    APPDATA_BASE="${BACKUP_BASE_DIR_NETWORK}/appdata"
  fi
fi

if [ -z "$APPDATA_BASE" ]; then
  log_err "Kein Backup-Medium verfügbar"
  exit 1
fi

# Neuestes oder bestimmtes Datum finden
find_backup_dir() {
  if [ "$RESTORE_DATE" = "latest" ]; then
    find "$APPDATA_BASE" -maxdepth 1 -mindepth 1 -type d -name "????-??-??" \
      | sort -r | head -1
  else
    echo "${APPDATA_BASE}/${RESTORE_DATE}"
  fi
}

BACKUP_DIR=$(find_backup_dir)
if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  log_err "Backup-Verzeichnis nicht gefunden: $APPDATA_BASE"
  log_err "Vorhandene Backups:"
  ls -la "$APPDATA_BASE" 2>/dev/null || true
  exit 1
fi

log_ok "Backup-Verzeichnis: $BACKUP_DIR"

# ── Nextcloud-Restore ─────────────────────────────────────────────────────────
restore_nextcloud() {
  local LXC=109
  log "  → Nextcloud (LXC $LXC) wiederherstellen..."

  if ! pct status "$LXC" 2>/dev/null | grep -q "running"; then
    log_err "LXC $LXC nicht laufend — erst LXC starten: pct start $LXC"
    return 1
  fi

  # Maintenance-Mode aktivieren
  pct exec "$LXC" -- bash -c "cd /opt/nextcloud && docker compose exec -T nextcloud php occ maintenance:mode --on" \
    2>/dev/null || log_warn "Maintenance-Mode nicht gesetzt (Nextcloud läuft?)"

  # MariaDB-Dump importieren
  local DB_FILE
  DB_FILE=$(find "${BACKUP_DIR}/nextcloud" -name "nextcloud-db-*.sql.gz" 2>/dev/null | sort -r | head -1)
  if [ -f "$DB_FILE" ]; then
    local DB_PASS
    DB_PASS=$(pct exec "$LXC" -- bash -c "grep DB_ROOT_PASSWORD /opt/nextcloud/.env | cut -d= -f2" 2>/dev/null || echo "")
    if [ -n "$DB_PASS" ]; then
      log "    → Datenbank importieren: $(basename "$DB_FILE")..."
      pct push "$LXC" "$DB_FILE" "/tmp/nextcloud-db-restore.sql.gz"
      pct exec "$LXC" -- bash -c "
        cd /opt/nextcloud
        gunzip -c /tmp/nextcloud-db-restore.sql.gz | \
          docker compose exec -T db mysql -u root -p${DB_PASS} nextcloud
        rm -f /tmp/nextcloud-db-restore.sql.gz
      "
      log_ok "Nextcloud Datenbank importiert"
    fi
  else
    log_warn "Kein Nextcloud DB-Dump gefunden"
  fi

  # Nextcloud-Daten zurückspielen
  local DATA_FILE
  DATA_FILE=$(find "${BACKUP_DIR}/nextcloud" -name "nextcloud-data-*.tar.gz" 2>/dev/null | sort -r | head -1)
  if [ -f "$DATA_FILE" ]; then
    log "    → Nextcloud-Daten entpacken: $(basename "$DATA_FILE")..."
    pct push "$LXC" "$DATA_FILE" "/tmp/nextcloud-data-restore.tar.gz"
    pct exec "$LXC" -- bash -c "
      tar -xzf /tmp/nextcloud-data-restore.tar.gz -C /opt/nextcloud/ 2>/dev/null
      rm -f /tmp/nextcloud-data-restore.tar.gz
    "
    log_ok "Nextcloud Daten wiederhergestellt"
  fi

  # Maintenance-Mode deaktivieren
  pct exec "$LXC" -- bash -c "cd /opt/nextcloud && docker compose exec -T nextcloud php occ maintenance:mode --off" \
    2>/dev/null || log_warn "Maintenance-Mode nicht deaktiviert"
  pct exec "$LXC" -- bash -c "cd /opt/nextcloud && docker compose exec -T nextcloud php occ files:scan --all" \
    2>/dev/null || true

  log_ok "Nextcloud wiederhergestellt"
}

# ── n8n-Restore ───────────────────────────────────────────────────────────────
restore_n8n() {
  local LXC=104
  log "  → n8n (LXC $LXC) wiederherstellen..."

  if ! pct status "$LXC" 2>/dev/null | grep -q "running"; then
    log_err "LXC $LXC nicht laufend"
    return 1
  fi

  # Volume-Backup zurückspielen
  local VOL_FILE
  VOL_FILE=$(find "${BACKUP_DIR}/n8n" -name "n8n-volume-*.tar.gz" 2>/dev/null | sort -r | head -1)
  if [ -f "$VOL_FILE" ]; then
    log "    → n8n Volume zurückspielen: $(basename "$VOL_FILE")..."
    pct exec "$LXC" -- bash -c "cd /root/docker/n8n && docker compose stop n8n" 2>/dev/null || true
    pct push "$LXC" "$VOL_FILE" "/tmp/n8n-volume-restore.tar.gz"
    pct exec "$LXC" -- bash -c "
      docker run --rm \
        -v n8n_n8n_data:/data \
        -v /tmp:/backup \
        debian:bookworm-slim \
        tar -xzf /backup/n8n-volume-restore.tar.gz -C /data/ 2>/dev/null
      rm -f /tmp/n8n-volume-restore.tar.gz
    "
    pct exec "$LXC" -- bash -c "cd /root/docker/n8n && docker compose start n8n" 2>/dev/null || true
    log_ok "n8n Volume wiederhergestellt"
  else
    # Fallback: Workflows importieren
    local WF_FILE
    WF_FILE=$(find "${BACKUP_DIR}/n8n" -name "n8n-workflows-*.json" 2>/dev/null | sort -r | head -1)
    if [ -f "$WF_FILE" ]; then
      pct push "$LXC" "$WF_FILE" "/tmp/n8n-workflows-restore.json"
      pct exec "$LXC" -- bash -c "
        docker exec n8n n8n import:workflow --input=/tmp/n8n-workflows-restore.json 2>/dev/null || true
        rm -f /tmp/n8n-workflows-restore.json
      "
      log_ok "n8n Workflows importiert"
    else
      log_warn "Kein n8n Backup gefunden"
    fi
  fi
  log_ok "n8n wiederhergestellt"
}

# ── Headscale-Restore ────────────────────────────────────────────────────────
restore_headscale() {
  local LXC=115
  log "  → Headscale (LXC $LXC) wiederherstellen..."

  if ! pct status "$LXC" 2>/dev/null | grep -q "running"; then
    log_err "LXC $LXC nicht laufend"
    return 1
  fi

  # Config + Keys zurückspielen
  local CFG_FILE
  CFG_FILE=$(find "${BACKUP_DIR}/headscale" -name "headscale-config-*.tar.gz" 2>/dev/null | sort -r | head -1)
  if [ -f "$CFG_FILE" ]; then
    pct exec "$LXC" -- bash -c "systemctl stop headscale 2>/dev/null || true"
    pct push "$LXC" "$CFG_FILE" "/tmp/headscale-config-restore.tar.gz"
    pct exec "$LXC" -- bash -c "
      tar -xzf /tmp/headscale-config-restore.tar.gz -C / --overwrite 2>/dev/null
      rm -f /tmp/headscale-config-restore.tar.gz
      systemctl start headscale 2>/dev/null || true
    "
    log_ok "Headscale Config + Keys wiederhergestellt"
  fi

  # SQLite DB
  local DB_FILE
  DB_FILE=$(find "${BACKUP_DIR}/headscale" -name "headscale-*.sqlite" 2>/dev/null | sort -r | head -1)
  if [ -f "$DB_FILE" ]; then
    pct exec "$LXC" -- bash -c "systemctl stop headscale 2>/dev/null || true"
    pct push "$LXC" "$DB_FILE" "/var/lib/headscale/db.sqlite"
    pct exec "$LXC" -- bash -c "systemctl start headscale 2>/dev/null || true"
    log_ok "Headscale DB wiederhergestellt"
  fi

  log_ok "Headscale wiederhergestellt"
}

# ── Authentik-Restore ────────────────────────────────────────────────────────
restore_authentik() {
  local LXC=125
  log "  → Authentik (LXC $LXC) wiederherstellen..."

  if ! pct status "$LXC" 2>/dev/null | grep -q "running"; then
    log_err "LXC $LXC nicht laufend"
    return 1
  fi

  local DB_FILE
  DB_FILE=$(find "${BACKUP_DIR}/authentik" -name "authentik-db-*.sql.gz" 2>/dev/null | sort -r | head -1)
  if [ -f "$DB_FILE" ]; then
    pct push "$LXC" "$DB_FILE" "/tmp/authentik-db-restore.sql.gz"
    pct exec "$LXC" -- bash -c "
      PG_CONTAINER=\$(docker ps --filter name=postgresql --format '{{.Names}}' | head -1)
      gunzip -c /tmp/authentik-db-restore.sql.gz | \
        docker exec -i \$PG_CONTAINER psql -U authentik authentik 2>/dev/null || true
      rm -f /tmp/authentik-db-restore.sql.gz
    "
    log_ok "Authentik DB wiederhergestellt"
  else
    log_warn "Kein Authentik DB-Dump gefunden"
  fi

  log_ok "Authentik wiederhergestellt"
}

# ── Services wiederherstellen ─────────────────────────────────────────────────
case "$SERVICE" in
  nextcloud) restore_nextcloud ;;
  n8n)       restore_n8n ;;
  headscale) restore_headscale ;;
  authentik) restore_authentik ;;
  all)
    restore_nextcloud
    restore_n8n
    restore_headscale
    restore_authentik
    ;;
  *)
    log_err "Unbekannter Service: $SERVICE (nextcloud|n8n|headscale|authentik|all)"
    exit 1
    ;;
esac

log ""
log_ok "App-Data-Restore abgeschlossen: $SERVICE"
