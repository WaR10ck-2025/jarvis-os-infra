#!/bin/bash
# backup-vzdump.sh — Layer 2: LXC/VM vollständige Archive via vzdump
# Ziele: USB-Festplatte oder Netzwerkfreigabe (GitHub wegen Größe ungeeignet)
# Läuft auf dem Proxmox-Host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
DATE_DIR=$(date +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/backup-vzdump-${DATE_DIR}.log"

mkdir -p "$LOG_DIR"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

ERRORS=0
TOTAL_SIZE=0
notify() {
  local status="$1" msg="$2"
  if [ "$NTFY_ENABLED" = "true" ] && [ -n "$NTFY_URL" ]; then
    local prio="default"; local tags="package"
    [ "$status" = "error" ] && prio="urgent" && tags="warning"
    curl -s -X POST "$NTFY_URL" \
      -H "Title: OpenClaw Backup L2 ${status^^}" \
      -H "Priority: $prio" -H "Tags: $tags" \
      -d "$msg" -o /dev/null 2>/dev/null || true
  fi
}

log "► Layer 2: vzdump-Backup starten ($TIMESTAMP)"

# ── Backup-Ziel ermitteln ─────────────────────────────────────────────────────
ACTIVE_STORAGE=""
ACTIVE_BASE_DIR=""

# USB zuerst prüfen
if echo "$BACKUP_TARGETS" | grep -q "usb"; then
  USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
  if [ -n "$USB_DEV" ]; then
    # Stale-Mount-Schutz: obersten Mount prüfen
    TOP_MOUNT=$(findmnt -n -o SOURCE "$BACKUP_USB_MOUNT" 2>/dev/null | tail -1)
    if [ -n "$TOP_MOUNT" ] && [ "$TOP_MOUNT" = "$USB_DEV" ]; then
      : # Korrektes Device bereits gemountet
    else
      [ -n "$TOP_MOUNT" ] && log_warn "Mount-Mismatch: $BACKUP_USB_MOUNT → $TOP_MOUNT statt $USB_DEV — mount drüber"
      mount "$USB_DEV" "$BACKUP_USB_MOUNT" 2>/dev/null || true
    fi
    mkdir -p "${BACKUP_BASE_DIR_USB}/dump"
    ACTIVE_STORAGE="$PROXMOX_BACKUP_STORAGE_USB"
    ACTIVE_BASE_DIR="$BACKUP_BASE_DIR_USB"
    log_ok "USB-Festplatte aktiv: $BACKUP_USB_MOUNT"
  else
    log_warn "USB nicht gefunden — prüfe Netzwerkfreigabe..."
  fi
fi

# Netzwerkfreigabe als Fallback (oder primär wenn konfiguriert)
if [ -z "$ACTIVE_STORAGE" ] && echo "$BACKUP_TARGETS" | grep -q "network"; then
  if [ "$BACKUP_NETWORK_ENABLED" = "true" ]; then
    if ping -c1 -W3 "$BACKUP_NETWORK_HOST" &>/dev/null; then
      if ! mountpoint -q "$BACKUP_NETWORK_MOUNT"; then
        if [ "$BACKUP_NETWORK_TYPE" = "smb" ]; then
          mount -t cifs "//${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}" \
            "$BACKUP_NETWORK_MOUNT" \
            -o "credentials=/etc/backup-credentials,uid=0,gid=0,vers=3.0"
        else
          mount -t nfs "${BACKUP_NETWORK_HOST}:/${BACKUP_NETWORK_SHARE}" \
            "$BACKUP_NETWORK_MOUNT"
        fi
      fi
      mkdir -p "${BACKUP_BASE_DIR_NETWORK}/dump"
      ACTIVE_STORAGE="$PROXMOX_BACKUP_STORAGE_NAS"
      ACTIVE_BASE_DIR="$BACKUP_BASE_DIR_NETWORK"
      log_ok "Netzwerkfreigabe aktiv: ${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}"
    else
      log_warn "NAS nicht erreichbar: $BACKUP_NETWORK_HOST"
    fi
  fi
fi

if [ -z "$ACTIVE_STORAGE" ]; then
  log_err "Kein vzdump-Ziel verfügbar (USB nicht eingesteckt, NAS nicht erreichbar)"
  log_err "Layer 2 übersprungen — Konfiguration prüfen"
  notify "error" "Layer 2 fehlgeschlagen: Kein Backup-Medium verfügbar"
  exit 1
fi

# ── Proxmox Storage registrieren (falls noch nicht vorhanden) ────────────────
STORAGE_PATH="${ACTIVE_BASE_DIR}"
if ! pvesm status 2>/dev/null | grep -q "$ACTIVE_STORAGE"; then
  log "  → Proxmox-Storage '$ACTIVE_STORAGE' registrieren..."
  pvesm add dir "$ACTIVE_STORAGE" --path "$STORAGE_PATH" --content backup --shared 0
  log_ok "Proxmox-Storage '$ACTIVE_STORAGE' registriert"
fi

# ── Freispeicher prüfen ───────────────────────────────────────────────────────
FREE_GB=$(df -BG "$STORAGE_PATH" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
log "  → Freispeicher auf Ziel: ${FREE_GB} GB"

# ── vzdump-Funktion ───────────────────────────────────────────────────────────
dump_lxc() {
  local lxc_id="$1"
  if ! pct status "$lxc_id" &>/dev/null; then
    log_warn "LXC $lxc_id nicht gefunden — übersprungen"
    return 0
  fi

  log "  → LXC $lxc_id sichern..."
  local start_time=$SECONDS

  # vzdump mit snapshot-Modus (LXC bleibt laufend)
  if vzdump "$lxc_id" \
    --compress zstd \
    --storage "$ACTIVE_STORAGE" \
    --mode snapshot \
    --quiet 1 \
    2>>"$LOG_FILE"; then
    local duration=$((SECONDS - start_time))
    # Größe der neuesten Backup-Datei ermitteln (LXC=.tar.zst)
    local backup_file
    backup_file=$(find "${ACTIVE_BASE_DIR}/dump" -name "vzdump-lxc-${lxc_id}-*.tar.zst" \
      -newer /tmp/.vzdump_marker 2>/dev/null | sort -r | head -1)
    local size="?"
    [ -n "$backup_file" ] && size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)
    log_ok "LXC $lxc_id: $size in ${duration}s"
  else
    log_err "LXC $lxc_id: vzdump fehlgeschlagen"
    ERRORS=$((ERRORS + 1))
  fi
}

dump_vm() {
  local vm_id="$1"
  if ! qm status "$vm_id" &>/dev/null; then
    log_warn "VM $vm_id nicht gefunden — übersprungen"
    return 0
  fi

  log "  → VM $vm_id sichern..."
  local start_time=$SECONDS

  # VMs: suspend-Modus (kurze Pause) für konsistentes Backup
  if vzdump "$vm_id" \
    --compress zstd \
    --storage "$ACTIVE_STORAGE" \
    --mode suspend \
    --quiet 1 \
    2>>"$LOG_FILE"; then
    local duration=$((SECONDS - start_time))
    log_ok "VM $vm_id: ${duration}s"
  else
    log_err "VM $vm_id: vzdump fehlgeschlagen"
    ERRORS=$((ERRORS + 1))
  fi
}

# Marker für Größenermittlung
touch /tmp/.vzdump_marker

# ── Prioritäre LXCs sichern ───────────────────────────────────────────────────
log "  → Prioritäre LXCs sichern: $PRIORITY_LXCS"
for LXC_ID in $PRIORITY_LXCS; do
  dump_lxc "$LXC_ID"
done

# ── VMs sichern ───────────────────────────────────────────────────────────────
if [ -n "$BACKUP_VMS" ]; then
  log "  → VMs sichern: $BACKUP_VMS"
  for VM_ID in $BACKUP_VMS; do
    dump_vm "$VM_ID"
  done
fi

# ── Optionale LXCs (nur wenn genug Platz) ─────────────────────────────────────
if [ "$FREE_GB" -gt 20 ] && [ -n "$OPTIONAL_LXCS" ]; then
  log "  → Optionale LXCs sichern: $OPTIONAL_LXCS"
  for LXC_ID in $OPTIONAL_LXCS; do
    # Freispeicher erneut prüfen
    CURRENT_FREE=$(df -BG "$STORAGE_PATH" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ "$CURRENT_FREE" -lt 10 ]; then
      log_warn "Freispeicher < 10 GB — optionale LXCs stoppen"
      break
    fi
    dump_lxc "$LXC_ID"
  done
else
  log_warn "Freispeicher < 20 GB oder keine optionalen LXCs — übersprungen"
fi

# ── Checksum-Manifest ─────────────────────────────────────────────────────────
log "  → SHA256-Manifest erstellen..."
MANIFEST="${ACTIVE_BASE_DIR}/dump/manifest-${DATE_DIR}.sha256"
find "${ACTIVE_BASE_DIR}/dump" -name "*.zst" -newer /tmp/.vzdump_marker \
  -exec sha256sum {} \; > "$MANIFEST" 2>/dev/null || true
MANIFEST_ENTRIES=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)
log_ok "Manifest: $MANIFEST_ENTRIES Einträge → $(basename "$MANIFEST")"

# ── Retention ─────────────────────────────────────────────────────────────────
log "  → Retention: letzte $RETENTION_VZDUMP_COUNT Versionen pro LXC..."
DUMP_DIR="${ACTIVE_BASE_DIR}/dump"
# Für jeden LXC/VM: alle außer den neuesten N Backups löschen
for VMTYPE in lxc qemu; do
  EXT="tar.zst"; [ "$VMTYPE" = "qemu" ] && EXT="vma.zst"
  for VMID_DIR in $(find "$DUMP_DIR" -name "vzdump-${VMTYPE}-*-*.${EXT}" \
      | sed 's/.*vzdump-[a-z]*-\([0-9]*\)-.*/\1/' | sort -u 2>/dev/null); do
    BACKUPS=$(ls -t "${DUMP_DIR}/vzdump-${VMTYPE}-${VMID_DIR}-"*.${EXT} 2>/dev/null)
    COUNT=$(echo "$BACKUPS" | wc -l)
    if [ "$COUNT" -gt "$RETENTION_VZDUMP_COUNT" ]; then
      echo "$BACKUPS" | tail -n "+$((RETENTION_VZDUMP_COUNT + 1))" | while read -r OLD_FILE; do
        rm -f "$OLD_FILE"
        rm -f "${OLD_FILE%.${EXT}}.log"
        log_ok "Retention: $(basename "$OLD_FILE") gelöscht"
      done
    fi
  done
done

# ── Abschluss-Statistik ───────────────────────────────────────────────────────
TOTAL_DUMP_SIZE=$(du -sh "${ACTIVE_BASE_DIR}/dump/" 2>/dev/null | cut -f1)
FREE_AFTER=$(df -BG "$STORAGE_PATH" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

if [ "$ERRORS" -eq 0 ]; then
  MSG="Layer 2 OK: vzdump abgeschlossen | Gesamt: $TOTAL_DUMP_SIZE | Frei: ${FREE_AFTER}GB"
  log_ok "$MSG"
  notify "success" "$MSG"
else
  MSG="Layer 2: $ERRORS Fehler | Gesamt: $TOTAL_DUMP_SIZE | Frei: ${FREE_AFTER}GB"
  log_warn "$MSG"
  notify "warning" "$MSG"
fi

rm -f /tmp/.vzdump_marker
exit 0
