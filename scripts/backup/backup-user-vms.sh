#!/bin/bash
# backup-user-vms.sh — Layer 2 Erweiterung: User-VM Backup + ZFS-Snapshots
#
# Ergaenzt das bestehende 3-Layer-Backup-System um:
#   - ZFS-Snapshots fuer User-Daten (tank/users/*)
#   - vzdump fuer alle User-VMs (dynamisch ermittelt)
#   - Retention: 7 Tage ZFS-Snapshots, 3 vzdump-Versionen
#
# Wird von backup-all.sh oder standalone aufgerufen.
# Ausfuehren auf dem Proxmox-Host.
# Verwendung: bash scripts/backup/backup-user-vms.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"

# Config laden (falls vorhanden)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

LOG_DIR="${LOG_DIR:-/var/log/jarvis-os-backup}"
BACKUP_USB_MOUNT="${BACKUP_USB_MOUNT:-/mnt/backup-usb}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR_USB:-${BACKUP_USB_MOUNT}/jarvis-os-backups}"
ZFS_POOL="${ZFS_POOL_NAME:-tank}"
ADMIN_SERVICE_URL="${ADMIN_SERVICE_URL:-http://192.168.10.160:8300}"
RETENTION_ZFS_DAYS=7
RETENTION_VZDUMP_COUNT=${RETENTION_VZDUMP_COUNT:-3}

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
DATE_TAG=$(date +%Y%m%d)
LOG_FILE="${LOG_DIR}/backup-user-vms-$(date +%Y-%m-%d).log"

mkdir -p "$LOG_DIR"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

log "════════════════════════════════════════════════════════"
log "  J.A.R.V.I.S-OS User-VM Backup — Start: $TIMESTAMP"
log "════════════════════════════════════════════════════════"

ERRORS=0

# ═══════════════════════════════════════════════════════════════════════════
# TEIL 1: ZFS-Snapshots (User-Daten)
# ═══════════════════════════════════════════════════════════════════════════
log ""
log "► Teil 1: ZFS-Snapshots"

if zfs list "${ZFS_POOL}/users" &>/dev/null; then
    # Rekursiver Snapshot fuer alle User-Datasets
    SNAP_NAME="backup-${DATE_TAG}"

    log "  Erstelle Snapshot: ${ZFS_POOL}/users@${SNAP_NAME}"
    if zfs snapshot -r "${ZFS_POOL}/users@${SNAP_NAME}" 2>/dev/null; then
        log_ok "ZFS-Snapshot erstellt"

        # Alle Snapshots auflisten
        SNAP_COUNT=$(zfs list -t snapshot -r "${ZFS_POOL}/users" -H | wc -l)
        log "  Aktive Snapshots: ${SNAP_COUNT}"
    else
        # Snapshot existiert bereits (idempotent)
        log_warn "Snapshot ${SNAP_NAME} existiert bereits — uebersprungen"
    fi

    # Retention: Alte Snapshots loeschen
    log "  Retention: Loesche Snapshots aelter als ${RETENTION_ZFS_DAYS} Tage..."
    CUTOFF_DATE=$(date -d "-${RETENTION_ZFS_DAYS} days" +%Y%m%d 2>/dev/null || \
                  date -v-${RETENTION_ZFS_DAYS}d +%Y%m%d 2>/dev/null)

    if [ -n "$CUTOFF_DATE" ]; then
        zfs list -t snapshot -r "${ZFS_POOL}/users" -H -o name | while read snap; do
            SNAP_DATE=$(echo "$snap" | grep -oP 'backup-\K\d{8}' || true)
            if [ -n "$SNAP_DATE" ] && [ "$SNAP_DATE" -lt "$CUTOFF_DATE" ] 2>/dev/null; then
                log "  Loesche: $snap"
                zfs destroy "$snap" 2>/dev/null || log_warn "Konnte $snap nicht loeschen"
            fi
        done
        log_ok "ZFS-Retention abgeschlossen"
    fi
else
    log_warn "ZFS-Pool ${ZFS_POOL}/users nicht gefunden — ZFS-Backup uebersprungen"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEIL 2: vzdump fuer User-VMs
# ═══════════════════════════════════════════════════════════════════════════
log ""
log "► Teil 2: vzdump User-VMs"

# User-VMs dynamisch ermitteln (VM-IDs >= 1000, nicht Templates)
USER_VM_IDS=""

# Option A: Vom Admin-Service abfragen
if curl -sf --connect-timeout 5 "${ADMIN_SERVICE_URL}/api/v1/health" > /dev/null 2>&1; then
    log "  Lade VM-Liste vom Admin-Service..."
    USER_VM_IDS=$(curl -sf "${ADMIN_SERVICE_URL}/api/v1/vms" 2>/dev/null | \
        jq -r '.[].vm_id // empty' 2>/dev/null | tr '\n' ' ')
fi

# Option B: Fallback — direkt von Proxmox
if [ -z "$USER_VM_IDS" ]; then
    log "  Fallback: Ermittle VMs direkt von Proxmox..."
    USER_VM_IDS=$(qm list 2>/dev/null | awk '$1 >= 1000 && $1 < 9000 {print $1}' | tr '\n' ' ')
fi

# Admin-VM (155) immer mitsichern
ADMIN_VM_ID=155
ALL_VM_IDS="${ADMIN_VM_ID} ${USER_VM_IDS}"

if [ -z "$(echo $ALL_VM_IDS | tr -d ' ')" ]; then
    log_warn "Keine User-VMs gefunden — vzdump uebersprungen"
else
    log "  VMs zu sichern: ${ALL_VM_IDS}"

    for VM_ID in $ALL_VM_IDS; do
        # Pruefen ob VM existiert
        if ! qm status $VM_ID &>/dev/null; then
            log_warn "VM $VM_ID nicht gefunden — uebersprungen"
            continue
        fi

        VM_NAME=$(qm config $VM_ID 2>/dev/null | grep "^name:" | awk '{print $2}')
        log "  Sichere VM $VM_ID ($VM_NAME)..."

        # vzdump mit Snapshot-Modus (kein Shutdown noetig)
        if vzdump $VM_ID \
            --mode snapshot \
            --compress zstd \
            --storage ${PROXMOX_BACKUP_STORAGE_USB:-local} \
            --notes-template "J.A.R.V.I.S-OS Backup ${TIMESTAMP}" \
            2>&1 | tee -a "$LOG_FILE"; then
            log_ok "VM $VM_ID gesichert"
        else
            log_err "VM $VM_ID Backup fehlgeschlagen"
            ((ERRORS++))
        fi
    done

    # Retention: Alte vzdump-Backups loeschen
    log "  Retention: Behalte letzte ${RETENTION_VZDUMP_COUNT} Backups pro VM..."
    for VM_ID in $ALL_VM_IDS; do
        # Proxmox verwaltet Retention automatisch wenn ueber Storage konfiguriert
        # Manuell: aelteste Backups loeschen wenn mehr als RETENTION_VZDUMP_COUNT
        BACKUP_COUNT=$(find "${BACKUP_BASE_DIR}/dump/" -name "vzdump-qemu-${VM_ID}-*" -type f 2>/dev/null | wc -l)
        if [ "$BACKUP_COUNT" -gt "$RETENTION_VZDUMP_COUNT" ]; then
            DELETE_COUNT=$((BACKUP_COUNT - RETENTION_VZDUMP_COUNT))
            find "${BACKUP_BASE_DIR}/dump/" -name "vzdump-qemu-${VM_ID}-*" -type f 2>/dev/null | \
                sort | head -n "$DELETE_COUNT" | while read f; do
                    log "  Loesche: $(basename $f)"
                    rm -f "$f" "${f}.notes" 2>/dev/null
                done
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEIL 3: Admin-Service DB sichern
# ═══════════════════════════════════════════════════════════════════════════
log ""
log "► Teil 3: Admin-Service DB sichern"

ADMIN_DB_BACKUP="${BACKUP_BASE_DIR}/appdata/admin-service"
mkdir -p "$ADMIN_DB_BACKUP"

if pct status 160 &>/dev/null; then
    pct exec 160 -- sqlite3 /opt/jarvis-admin/data/jarvis.db ".backup /tmp/jarvis-backup.db" 2>/dev/null
    pct pull 160 /tmp/jarvis-backup.db "${ADMIN_DB_BACKUP}/jarvis-${DATE_TAG}.db" 2>/dev/null && \
        log_ok "Admin-Service DB gesichert" || \
        log_warn "Admin-Service DB Backup fehlgeschlagen"

    # Retention: Alte DB-Backups
    find "$ADMIN_DB_BACKUP" -name "jarvis-*.db" -mtime +14 -delete 2>/dev/null
else
    log_warn "Admin-Service LXC 160 nicht erreichbar"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Zusammenfassung
# ═══════════════════════════════════════════════════════════════════════════
DURATION=$((SECONDS))
log ""
log "════════════════════════════════════════════════════════"
log "  User-VM Backup abgeschlossen"
log "  Dauer: ${DURATION}s"
log "  Fehler: ${ERRORS}"
log "════════════════════════════════════════════════════════"

exit $ERRORS
