#!/bin/bash
# restore-lxc.sh — Einzelne LXC oder VM aus vzdump-Backup wiederherstellen
#
# Verwendung:
#   restore-lxc.sh --lxc 109                          # Neuestes Backup für LXC 109
#   restore-lxc.sh --lxc 109 --date 2026-03-27        # Vom bestimmten Datum
#   restore-lxc.sh --vm 100                            # VM 100 wiederherstellen
#   restore-lxc.sh --lxc 109 --file /path/to/dump.vma.zst  # Direkte Datei
#   restore-lxc.sh --lxc 109 --storage local-zfs      # Storage-Ziel angeben

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
LOG_FILE="${LOG_DIR}/restore-lxc-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

# ── Argument-Parsing ─────────────────────────────────────────────────────────
RESTORE_ID=""
RESTORE_TYPE="lxc"  # lxc | vm
RESTORE_DATE=""
RESTORE_FILE=""
TARGET_STORAGE="${STORAGE:-local-zfs}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --lxc)     RESTORE_ID="$2"; RESTORE_TYPE="lxc"; shift 2 ;;
    --vm)      RESTORE_ID="$2"; RESTORE_TYPE="vm"; shift 2 ;;
    --date)    RESTORE_DATE="$2"; shift 2 ;;
    --file)    RESTORE_FILE="$2"; shift 2 ;;
    --storage) TARGET_STORAGE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$RESTORE_ID" ]; then
  echo "Verwendung: $0 --lxc <ID> [--date YYYY-MM-DD] [--storage <storage>]"
  echo "       oder: $0 --vm <ID> [--date YYYY-MM-DD] [--storage <storage>]"
  echo "       oder: $0 --lxc <ID> --file /path/to/dump.vma.zst"
  exit 1
fi

log "► ${RESTORE_TYPE^^} $RESTORE_ID: Restore starten ($TIMESTAMP)"

# ── Backup-Medium ermitteln ───────────────────────────────────────────────────
DUMP_DIR=""

# USB prüfen
USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
if [ -n "$USB_DEV" ]; then
  mountpoint -q "$BACKUP_USB_MOUNT" || mount "$USB_DEV" "$BACKUP_USB_MOUNT"
  DUMP_DIR="${BACKUP_BASE_DIR_USB}/dump"
  log_ok "USB-Festplatte gemountet"
fi

# Netzwerk-Fallback
if [ -z "$DUMP_DIR" ] && [ "$BACKUP_NETWORK_ENABLED" = "true" ]; then
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
    DUMP_DIR="${BACKUP_BASE_DIR_NETWORK}/dump"
    log_ok "Netzwerkfreigabe gemountet"
  fi
fi

# ── Backup-Datei finden ───────────────────────────────────────────────────────
BACKUP_FILE=""

if [ -n "$RESTORE_FILE" ]; then
  BACKUP_FILE="$RESTORE_FILE"
elif [ -n "$DUMP_DIR" ]; then
  VMTYPE="lxc"
  [ "$RESTORE_TYPE" = "vm" ] && VMTYPE="qemu"

  if [ -n "$RESTORE_DATE" ]; then
    BACKUP_FILE=$(find "$DUMP_DIR" \
      -name "vzdump-${VMTYPE}-${RESTORE_ID}-${RESTORE_DATE}*.vma.zst" \
      2>/dev/null | sort -r | head -1)
  else
    BACKUP_FILE=$(find "$DUMP_DIR" \
      -name "vzdump-${VMTYPE}-${RESTORE_ID}-*.vma.zst" \
      2>/dev/null | sort -r | head -1)
  fi
fi

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  log_err "Kein Backup für ${RESTORE_TYPE^^} $RESTORE_ID gefunden"
  if [ -n "$DUMP_DIR" ]; then
    log_err "Vorhandene Backups:"
    ls -la "$DUMP_DIR"/vzdump-*-${RESTORE_ID}-*.vma.zst 2>/dev/null | \
      awk '{print "  " $9 " (" $5 " bytes)"}' | tee -a "$LOG_FILE" || \
      log_err "  Keine vorhanden"
  fi
  exit 1
fi

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log_ok "Backup gefunden: $(basename "$BACKUP_FILE") ($BACKUP_SIZE)"

# ── Sicherheitsabfrage ────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║               ${RESTORE_TYPE^^} $RESTORE_ID — Restore"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Backup:  $(basename "$BACKUP_FILE")"
echo "  ║  Größe:   $BACKUP_SIZE"
echo "  ║  Storage: $TARGET_STORAGE"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Vorhandene ${RESTORE_TYPE^^} wird GELÖSCHT und neu erstellt!   ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
read -r -p "  Fortfahren? [y/N]: " CONFIRM
[ "${CONFIRM,,}" != "y" ] && { log "Abgebrochen."; exit 0; }

# ── LXC/VM stoppen und löschen ────────────────────────────────────────────────
if [ "$RESTORE_TYPE" = "lxc" ]; then
  if pct status "$RESTORE_ID" 2>/dev/null | grep -q "running"; then
    log "  → LXC $RESTORE_ID stoppen..."
    pct stop "$RESTORE_ID" --timeout 30 2>/dev/null || pct stop "$RESTORE_ID" --forceStop 1
    log_ok "LXC $RESTORE_ID gestoppt"
  fi
  if pct status "$RESTORE_ID" &>/dev/null; then
    log "  → LXC $RESTORE_ID löschen..."
    pct destroy "$RESTORE_ID" 2>/dev/null
    log_ok "LXC $RESTORE_ID gelöscht"
  fi
else
  if qm status "$RESTORE_ID" 2>/dev/null | grep -q "running"; then
    log "  → VM $RESTORE_ID stoppen..."
    qm stop "$RESTORE_ID" --timeout 30 2>/dev/null
    log_ok "VM $RESTORE_ID gestoppt"
  fi
  if qm status "$RESTORE_ID" &>/dev/null; then
    log "  → VM $RESTORE_ID löschen..."
    qm destroy "$RESTORE_ID" 2>/dev/null
    log_ok "VM $RESTORE_ID gelöscht"
  fi
fi

# ── Restore ───────────────────────────────────────────────────────────────────
log "  → Restore starten..."
START_TIME=$SECONDS

if [ "$RESTORE_TYPE" = "lxc" ]; then
  pct restore "$RESTORE_ID" "$BACKUP_FILE" \
    --storage "$TARGET_STORAGE" \
    --start 0 \
    2>&1 | tee -a "$LOG_FILE"
else
  qm restore "$RESTORE_ID" "$BACKUP_FILE" \
    --storage "$TARGET_STORAGE" \
    2>&1 | tee -a "$LOG_FILE"
fi

DURATION=$((SECONDS - START_TIME))
log_ok "Restore abgeschlossen in ${DURATION}s"

# ── LXC/VM starten ────────────────────────────────────────────────────────────
log "  → ${RESTORE_TYPE^^} $RESTORE_ID starten..."
if [ "$RESTORE_TYPE" = "lxc" ]; then
  pct start "$RESTORE_ID"
  # Warten bis LXC bootbereit
  for i in $(seq 1 30); do
    pct exec "$RESTORE_ID" -- test -f /etc/hostname 2>/dev/null && break
    sleep 1
  done
  log_ok "LXC $RESTORE_ID läuft"
else
  qm start "$RESTORE_ID"
  log_ok "VM $RESTORE_ID gestartet"
fi

# ── Health-Check ─────────────────────────────────────────────────────────────
log "  → Health-Check..."
if [ "$RESTORE_TYPE" = "lxc" ]; then
  STATUS=$(pct status "$RESTORE_ID" 2>/dev/null)
  log "  Status: $STATUS"
  if echo "$STATUS" | grep -q "running"; then
    log_ok "LXC $RESTORE_ID läuft"
  else
    log_warn "LXC $RESTORE_ID nicht laufend"
  fi
fi

log ""
log_ok "${RESTORE_TYPE^^} $RESTORE_ID: Restore abgeschlossen"
echo ""
echo "  ✓ ${RESTORE_TYPE^^} $RESTORE_ID wiederhergestellt aus: $(basename "$BACKUP_FILE")"
echo "  ✓ Dauer: ${DURATION}s"
echo ""
echo "  Tipp: .env-Files aus Config-Backup zurückspielen:"
echo "    bash restore-config.sh --from-usb"
echo ""
