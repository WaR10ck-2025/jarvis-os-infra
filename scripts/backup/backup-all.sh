#!/bin/bash
# backup-all.sh — Master-Backup-Script
# Ruft alle Layer auf, schreibt Gesamt-Log, sendet Notification.
# Cron-Einstiegspunkt: /etc/cron.d/openclaw-backup
#
# Verwendung:
#   backup-all.sh                    # Alle Layer (1, 2, 3)
#   backup-all.sh --layer 1,3        # Nur Layer 1 + 3
#   backup-all.sh --layer 2          # Nur Layer 2 (vzdump)
#   backup-all.sh --layer all        # Alle Layer

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
source "$CONFIG_FILE"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
DATE_DIR=$(date +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/backup-all-${DATE_DIR}.log"

mkdir -p "$LOG_DIR"

# ── Argument-Parsing ─────────────────────────────────────────────────────────
RUN_LAYERS="1,2,3"  # Standard: alle
while [[ $# -gt 0 ]]; do
  case $1 in
    --layer) RUN_LAYERS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# "all" → "1,2,3"
[ "$RUN_LAYERS" = "all" ] && RUN_LAYERS="1,2,3"

log()      { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo "[$(date +%H:%M:%S)]   ✓ $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date +%H:%M:%S)]   ⚠  $*" | tee -a "$LOG_FILE"; }
log_err()  { echo "[$(date +%H:%M:%S)]   ✗ $*" | tee -a "$LOG_FILE"; }

LAYER1_STATUS="skipped"
LAYER2_STATUS="skipped"
LAYER3_STATUS="skipped"
START_TIME=$SECONDS

log "════════════════════════════════════════════════════════"
log "  OpenClaw Backup-System — Start: $TIMESTAMP"
log "  Layer: $RUN_LAYERS"
log "════════════════════════════════════════════════════════"

# ── Layer 1: Config-Backup ───────────────────────────────────────────────────
if echo "$RUN_LAYERS" | grep -q "1"; then
  log "► Layer 1: Config-Backup..."
  if bash "${SCRIPT_DIR}/backup-config.sh" >> "$LOG_FILE" 2>&1; then
    LAYER1_STATUS="ok"
    log_ok "Layer 1 abgeschlossen"
  else
    LAYER1_STATUS="error"
    log_err "Layer 1 fehlgeschlagen"
  fi
fi

# ── Layer 3: App-Data-Backup (vor Layer 2 — schneller, LXCs laufen) ──────────
if echo "$RUN_LAYERS" | grep -q "3"; then
  log "► Layer 3: App-Data-Backup..."
  if bash "${SCRIPT_DIR}/backup-appdata.sh" >> "$LOG_FILE" 2>&1; then
    LAYER3_STATUS="ok"
    log_ok "Layer 3 abgeschlossen"
  else
    LAYER3_STATUS="error"
    log_err "Layer 3 fehlgeschlagen"
  fi
fi

# ── Layer 2: vzdump (zuletzt — zeitintensiv, kann LXCs kurz einfrieren) ──────
if echo "$RUN_LAYERS" | grep -q "2"; then
  log "► Layer 2: vzdump-Backup..."
  if bash "${SCRIPT_DIR}/backup-vzdump.sh" >> "$LOG_FILE" 2>&1; then
    LAYER2_STATUS="ok"
    log_ok "Layer 2 abgeschlossen"
  else
    LAYER2_STATUS="error"
    log_err "Layer 2 fehlgeschlagen"
  fi
fi

# ── Zusammenfassung ───────────────────────────────────────────────────────────
DURATION=$((SECONDS - START_TIME))
DURATION_MIN=$((DURATION / 60))

log "════════════════════════════════════════════════════════"
log "  Backup abgeschlossen in ${DURATION_MIN} Min (${DURATION}s)"
log "  L1 Config:   $LAYER1_STATUS"
log "  L2 vzdump:   $LAYER2_STATUS"
log "  L3 App-Data: $LAYER3_STATUS"
log "════════════════════════════════════════════════════════"

# ── Gesamt-Notification ───────────────────────────────────────────────────────
if [ "$NTFY_ENABLED" = "true" ] && [ -n "$NTFY_URL" ]; then
  ERRORS=0
  [[ "$LAYER1_STATUS" == "error" ]] && ERRORS=$((ERRORS + 1))
  [[ "$LAYER2_STATUS" == "error" ]] && ERRORS=$((ERRORS + 1))
  [[ "$LAYER3_STATUS" == "error" ]] && ERRORS=$((ERRORS + 1))

  if [ "$ERRORS" -eq 0 ]; then
    STATUS_ICON="✅"; PRIO="default"; STATUS_TEXT="OK"
  else
    STATUS_ICON="⚠"; PRIO="high"; STATUS_TEXT="$ERRORS Fehler"
  fi

  MSG="${STATUS_ICON} Backup ${STATUS_TEXT} | ${DURATION_MIN}Min | L1:${LAYER1_STATUS} L2:${LAYER2_STATUS} L3:${LAYER3_STATUS}"

  curl -s -X POST "$NTFY_URL" \
    -H "Title: OpenClaw Backup Gesamt: $STATUS_TEXT" \
    -H "Priority: $PRIO" \
    -H "Tags: backup" \
    -d "$MSG" -o /dev/null 2>/dev/null || true
fi

# ── Log rotieren (> 30 Tage alte Logs löschen) ───────────────────────────────
find "$LOG_DIR" -name "backup-*.log" -mtime +30 -delete 2>/dev/null || true

# Exit-Code basierend auf Layer-Status
if [[ "$LAYER1_STATUS" == "error" ]] || [[ "$LAYER2_STATUS" == "error" ]] || [[ "$LAYER3_STATUS" == "error" ]]; then
  exit 1
fi

exit 0
