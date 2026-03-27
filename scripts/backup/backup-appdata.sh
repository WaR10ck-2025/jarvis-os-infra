#!/bin/bash
# backup-appdata.sh — Layer 3: Applikations-Daten sichern
# Sichert: MariaDB-Dumps, n8n-Workflows, Headscale-DB, Authentik-DB, Nextcloud-Daten
# Ziele: USB-Festplatte/NAS (lokal) und optional Backblaze B2 via rclone
# Läuft auf dem Proxmox-Host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
DATE_DIR=$(date +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/backup-appdata-${DATE_DIR}.log"

mkdir -p "$LOG_DIR" "$TEMP_DIR"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

ERRORS=0
notify() {
  local status="$1" msg="$2"
  if [ "$NTFY_ENABLED" = "true" ] && [ -n "$NTFY_URL" ]; then
    local prio="default"; local tags="file_cabinet"
    [ "$status" = "error" ] && prio="urgent" && tags="warning"
    curl -s -X POST "$NTFY_URL" \
      -H "Title: OpenClaw Backup L3 ${status^^}" \
      -H "Priority: $prio" -H "Tags: $tags" \
      -d "$msg" -o /dev/null 2>/dev/null || true
  fi
}

log "► Layer 3: App-Data-Backup starten ($TIMESTAMP)"

# ── Ziel-Ermittlung ───────────────────────────────────────────────────────────
ACTIVE_BASE_DIR=""

IFS=',' read -ra TARGETS <<< "$BACKUP_TARGETS"
for t in "${TARGETS[@]}"; do
  case "$(echo "$t" | tr -d ' ')" in
    usb)
      USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
      if [ -n "$USB_DEV" ]; then
        mountpoint -q "$BACKUP_USB_MOUNT" || mount "$USB_DEV" "$BACKUP_USB_MOUNT"
        ACTIVE_BASE_DIR="$BACKUP_BASE_DIR_USB"
        log_ok "USB-Festplatte aktiv"
      fi
      ;;
    network)
      if [ "$BACKUP_NETWORK_ENABLED" = "true" ] && ping -c1 -W3 "$BACKUP_NETWORK_HOST" &>/dev/null; then
        if ! mountpoint -q "$BACKUP_NETWORK_MOUNT"; then
          if [ "$BACKUP_NETWORK_TYPE" = "smb" ]; then
            mount -t cifs "//${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}" \
              "$BACKUP_NETWORK_MOUNT" \
              -o "credentials=/etc/backup-credentials,uid=0,gid=0,vers=3.0"
          else
            mount -t nfs "${BACKUP_NETWORK_HOST}:/${BACKUP_NETWORK_SHARE}" "$BACKUP_NETWORK_MOUNT"
          fi
        fi
        [ -z "$ACTIVE_BASE_DIR" ] && ACTIVE_BASE_DIR="$BACKUP_BASE_DIR_NETWORK"
        log_ok "Netzwerkfreigabe aktiv: ${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}"
      fi
      ;;
  esac
done

if [ -z "$ACTIVE_BASE_DIR" ]; then
  log_err "Kein lokales Backup-Ziel verfügbar für App-Daten"
  notify "error" "Layer 3 fehlgeschlagen: Kein Backup-Medium verfügbar"
  exit 1
fi

APPDATA_DIR="${ACTIVE_BASE_DIR}/appdata/${DATE_DIR}"
mkdir -p "$APPDATA_DIR"

# ── Helper: Script in LXC ausführen via pct exec ─────────────────────────────
run_in_lxc() {
  local lxc_id="$1"; shift
  pct exec "$lxc_id" -- bash -c "$@" 2>>"$LOG_FILE"
}

lxc_running() {
  pct status "$1" 2>/dev/null | grep -q "running"
}

# ── Nextcloud (LXC 109) ───────────────────────────────────────────────────────
backup_nextcloud() {
  local LXC=109
  log "  → Nextcloud (LXC $LXC) sichern..."
  mkdir -p "${APPDATA_DIR}/nextcloud"

  if ! lxc_running "$LXC"; then
    log_warn "LXC $LXC nicht laufend — Nextcloud übersprungen"
    ERRORS=$((ERRORS + 1)); return
  fi

  # Maintenance-Mode aktivieren
  run_in_lxc "$LXC" "cd /opt/nextcloud && docker compose exec -T nextcloud php occ maintenance:mode --on" \
    2>/dev/null || log_warn "Nextcloud: maintenance:mode --on fehlgeschlagen (läuft Nextcloud?)"

  # MariaDB-Dump
  local DB_PASS
  DB_PASS=$(run_in_lxc "$LXC" "grep DB_ROOT_PASSWORD /opt/nextcloud/.env | cut -d= -f2" 2>/dev/null || echo "")
  if [ -n "$DB_PASS" ]; then
    run_in_lxc "$LXC" "cd /opt/nextcloud && docker compose exec -T db \
      mysqldump -u root -p${DB_PASS} nextcloud 2>/dev/null" \
      | gzip > "${APPDATA_DIR}/nextcloud/nextcloud-db-${DATE_DIR}.sql.gz"
    log_ok "Nextcloud DB-Dump: nextcloud-db-${DATE_DIR}.sql.gz"
  else
    log_warn "Nextcloud: DB-Passwort nicht gefunden"
    ERRORS=$((ERRORS + 1))
  fi

  # Nextcloud-Daten per rsync (Bind-Mount /opt/nextcloud/data ist direkt zugänglich)
  mkdir -p "${APPDATA_DIR}/nextcloud/data"
  pct exec "$LXC" -- bash -c "
    rsync -a --delete --quiet /opt/nextcloud/data/ /tmp/nc-data-staging/
  " 2>/dev/null || true
  # Aus dem LXC auf den Host kopieren via tar-over-ssh-ähnliches Muster
  pct exec "$LXC" -- bash -c "
    tar -czf /tmp/nextcloud-data-${DATE_DIR}.tar.gz -C /opt/nextcloud data/ 2>/dev/null
  " && {
    pct pull "$LXC" "/tmp/nextcloud-data-${DATE_DIR}.tar.gz" \
      "${APPDATA_DIR}/nextcloud/nextcloud-data-${DATE_DIR}.tar.gz"
    pct exec "$LXC" -- bash -c "rm -f /tmp/nextcloud-data-${DATE_DIR}.tar.gz" || true
    log_ok "Nextcloud Daten: nextcloud-data-${DATE_DIR}.tar.gz"
  } || log_warn "Nextcloud: Daten-Backup übersprungen"

  # Maintenance-Mode deaktivieren
  run_in_lxc "$LXC" "cd /opt/nextcloud && docker compose exec -T nextcloud php occ maintenance:mode --off" \
    2>/dev/null || log_warn "Nextcloud: maintenance:mode --off fehlgeschlagen"

  log_ok "Nextcloud gesichert"
}

# ── n8n (LXC 104) ────────────────────────────────────────────────────────────
backup_n8n() {
  local LXC=104
  log "  → n8n (LXC $LXC) sichern..."
  mkdir -p "${APPDATA_DIR}/n8n"

  if ! lxc_running "$LXC"; then
    log_warn "LXC $LXC nicht laufend — n8n übersprungen"
    ERRORS=$((ERRORS + 1)); return
  fi

  # Workflows exportieren via n8n CLI
  run_in_lxc "$LXC" "
    docker exec n8n n8n export:workflow --all \
      --output=/tmp/n8n-workflows-${DATE_DIR}.json 2>/dev/null || true
  "
  if pct exec "$LXC" -- bash -c "test -s /tmp/n8n-workflows-${DATE_DIR}.json" 2>/dev/null; then
    pct pull "$LXC" "/tmp/n8n-workflows-${DATE_DIR}.json" \
      "${APPDATA_DIR}/n8n/n8n-workflows-${DATE_DIR}.json"
    pct exec "$LXC" -- bash -c "rm -f /tmp/n8n-workflows-${DATE_DIR}.json" || true
    log_ok "n8n Workflows exportiert"
  else
    log_warn "n8n: Workflow-Export leer oder fehlgeschlagen"
  fi

  # n8n Docker-Volume sichern (enthält SQLite DB mit Credentials)
  run_in_lxc "$LXC" "
    docker run --rm \
      -v n8n_n8n_data:/data \
      -v /tmp:/backup \
      debian:bookworm-slim \
      tar -czf /backup/n8n-volume-${DATE_DIR}.tar.gz -C /data . 2>/dev/null
  " && {
    pct pull "$LXC" "/tmp/n8n-volume-${DATE_DIR}.tar.gz" \
      "${APPDATA_DIR}/n8n/n8n-volume-${DATE_DIR}.tar.gz"
    pct exec "$LXC" -- bash -c "rm -f /tmp/n8n-volume-${DATE_DIR}.tar.gz" || true
    log_ok "n8n Volume gesichert: n8n-volume-${DATE_DIR}.tar.gz"
  } || log_warn "n8n: Volume-Backup fehlgeschlagen"

  log_ok "n8n gesichert"
}

# ── Headscale (LXC 115) ───────────────────────────────────────────────────────
backup_headscale() {
  local LXC=115
  log "  → Headscale (LXC $LXC) sichern..."
  mkdir -p "${APPDATA_DIR}/headscale"

  if ! lxc_running "$LXC"; then
    log_warn "LXC $LXC nicht laufend — Headscale übersprungen"
    return
  fi

  # SQLite DB sichern (liegt in /etc/headscale/)
  run_in_lxc "$LXC" "
    sqlite3 /etc/headscale/db.sqlite \".backup /tmp/headscale-${DATE_DIR}.sqlite\" 2>/dev/null || true
  "
  if pct exec "$LXC" -- bash -c "test -f /tmp/headscale-${DATE_DIR}.sqlite" 2>/dev/null; then
    pct pull "$LXC" "/tmp/headscale-${DATE_DIR}.sqlite" \
      "${APPDATA_DIR}/headscale/headscale-${DATE_DIR}.sqlite"
    pct exec "$LXC" -- bash -c "rm -f /tmp/headscale-${DATE_DIR}.sqlite" || true
    log_ok "Headscale DB gesichert"
  fi

  # Config + Private Keys (alles in /etc/headscale/)
  run_in_lxc "$LXC" "
    tar -czf /tmp/headscale-config-${DATE_DIR}.tar.gz \
      /etc/headscale/ \
      2>/dev/null
  " && {
    pct pull "$LXC" "/tmp/headscale-config-${DATE_DIR}.tar.gz" \
      "${APPDATA_DIR}/headscale/headscale-config-${DATE_DIR}.tar.gz"
    pct exec "$LXC" -- bash -c "rm -f /tmp/headscale-config-${DATE_DIR}.tar.gz" || true
    log_ok "Headscale Config + Keys gesichert"
  } || log_warn "Headscale: Config-Backup fehlgeschlagen"

  log_ok "Headscale gesichert"
}

# ── Authentik (LXC 125) ───────────────────────────────────────────────────────
backup_authentik() {
  local LXC=125
  log "  → Authentik (LXC $LXC) sichern..."
  mkdir -p "${APPDATA_DIR}/authentik"

  if ! lxc_running "$LXC"; then
    log_warn "LXC $LXC nicht laufend — Authentik übersprungen"
    return
  fi

  # PostgreSQL Dump
  run_in_lxc "$LXC" "
    docker exec \$(docker ps --filter name=postgresql --format '{{.Names}}' | head -1) \
      pg_dump -U authentik authentik 2>/dev/null | gzip > /tmp/authentik-db-${DATE_DIR}.sql.gz
  " && {
    pct pull "$LXC" "/tmp/authentik-db-${DATE_DIR}.sql.gz" \
      "${APPDATA_DIR}/authentik/authentik-db-${DATE_DIR}.sql.gz"
    pct exec "$LXC" -- bash -c "rm -f /tmp/authentik-db-${DATE_DIR}.sql.gz" || true
    log_ok "Authentik DB gesichert"
  } || log_warn "Authentik: DB-Dump fehlgeschlagen"

  log_ok "Authentik gesichert"
}

# ── Alle Services sichern ─────────────────────────────────────────────────────
backup_nextcloud
backup_n8n
backup_headscale
backup_authentik

# ── Backup-Manifest ───────────────────────────────────────────────────────────
log "  → Manifest erstellen..."
find "$APPDATA_DIR" -type f -exec sha256sum {} \; \
  > "${APPDATA_DIR}/manifest.sha256" 2>/dev/null || true
TOTAL_SIZE=$(du -sh "$APPDATA_DIR" 2>/dev/null | cut -f1)
log_ok "Appdata-Backup: $TOTAL_SIZE gesamt"

# ── Retention ─────────────────────────────────────────────────────────────────
log "  → Retention ($RETENTION_APPDATA_DAYS Tage)..."
find "${ACTIVE_BASE_DIR}/appdata/" -maxdepth 1 -mindepth 1 -type d \
  -name "????-??-??" | sort | head -n "-$RETENTION_APPDATA_DAYS" | while read -r OLD_DIR; do
  rm -rf "$OLD_DIR"
  log_ok "Retention: $(basename "$OLD_DIR") gelöscht"
done

# ── Backblaze B2 Upload (optional) ────────────────────────────────────────────
if [ "$B2_ENABLED" = "true" ] && command -v rclone &>/dev/null; then
  log "  → Backblaze B2: App-Daten uploaden..."
  rclone sync "${ACTIVE_BASE_DIR}/appdata/" "${B2_RCLONE_REMOTE}:" \
    --transfers 4 \
    --log-file "$LOG_DIR/rclone-${DATE_DIR}.log" \
    --log-level INFO 2>/dev/null && \
    log_ok "B2: App-Daten hochgeladen" || \
    log_warn "B2: Upload fehlgeschlagen (rclone-Log prüfen)"
fi

# ── Notification ──────────────────────────────────────────────────────────────
if [ "$ERRORS" -eq 0 ]; then
  MSG="Layer 3 OK: App-Daten $TIMESTAMP | Gesamt: $TOTAL_SIZE"
  log_ok "Layer 3 abgeschlossen"
  notify "success" "$MSG"
else
  MSG="Layer 3: $ERRORS Warnungen | $TOTAL_SIZE gesichert"
  log_warn "$MSG"
  notify "warning" "$MSG"
fi

exit 0
