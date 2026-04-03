#!/bin/bash
# phase9-adapt-hardware.sh — Post-Restore Hardware-Adaptation
#
# Erkennt die aktuelle Hardware und passt alle Konfigurationen an:
#   - Proxmox Node-Name, Storage, Host-IP
#   - API-User + Token (casaos@pve)
#   - Bridge .env (LXC 120) mit korrekten IPs und Werten
#   - Authentik Domain-Tabelle + Application (LXC 125)
#   - Bridge-Container neu erstellen (docker compose down/up)
#
# Aufruf:
#   bash phase9-adapt-hardware.sh              (standalone)
#   (wird auch von restore-hook.sh Phase 9 aufgerufen)
#
# Voraussetzungen:
#   - Proxmox VE installiert + LXCs gestartet (Phase 1-7 abgeschlossen)
#   - LXC 120 (Bridge), 125 (Authentik) vorhanden und laufend

set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/openclaw-first-boot.log}"

# Logging (kompatibel mit restore-hook.sh)
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_section() { log ""; log "══════════════════════════════════════════════"; log "  $*"; log "══════════════════════════════════════════════"; }

# Remote-Logging via ntfy.sh (falls konfiguriert)
NTFY_TOPIC="${NTFY_TOPIC:-openclaw-first-boot-$(cat /etc/machine-id 2>/dev/null | head -c 8 || echo 'default')}"
NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"
log_remote() {
  local msg="$*"
  log "$msg"
  curl -s -d "$msg" "$NTFY_URL" >/dev/null 2>&1 &
}

ERRORS=0

# ── Schritt 1: Hardware erkennen ─────────────────────────────────────────────
log_section "Schritt 1: Hardware erkennen"

NODE_NAME=$(hostname -s)
log "  Node-Name:  ${NODE_NAME}"

HOST_IP=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1 || echo "")
if [ -z "$HOST_IP" ]; then
  # Fallback: erste nicht-localhost IP
  HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
log "  Host-IP:    ${HOST_IP}"

# Storage erkennen (Reihenfolge: local-lvm > local-zfs > local)
if pvesm status 2>/dev/null | grep -q "^local-lvm"; then
  STORAGE="local-lvm"
elif pvesm status 2>/dev/null | grep -q "^local-zfs"; then
  STORAGE="local-zfs"
else
  STORAGE="local"
  log "  ⚠ Nur 'local' (dir) verfuegbar — Container-Storage eingeschraenkt"
fi
log "  Storage:    ${STORAGE}"

# LXC-IPs auslesen
get_lxc_ip() {
  local lxc_id=$1
  local default_ip=$2
  pct config "$lxc_id" 2>/dev/null | grep -oP 'ip=\K[^/]+' || echo "$default_ip"
}

LXC_120_IP=$(get_lxc_ip 120 "192.168.10.141")
LXC_115_IP=$(get_lxc_ip 115 "192.168.10.115")
LXC_125_IP=$(get_lxc_ip 125 "192.168.10.125")
LXC_130_IP=$(get_lxc_ip 130 "192.168.10.130")

log "  LXC 120 (Bridge):    ${LXC_120_IP}"
log "  LXC 115 (Headscale): ${LXC_115_IP}"
log "  LXC 125 (Authentik): ${LXC_125_IP}"
log "  LXC 130 (Portainer): ${LXC_130_IP}"

log_remote "Phase 9: Hardware erkannt — ${NODE_NAME} / ${STORAGE} / ${HOST_IP}"

# ── Schritt 2: Proxmox API-User + Token ──────────────────────────────────────
log_section "Schritt 2: Proxmox API-User + Token"

PROXMOX_TOKEN=""

if ! pveum user list 2>/dev/null | grep -q "casaos@pve"; then
  log "  API-User casaos@pve wird angelegt..."
  pveum user add casaos@pve 2>&1 | tee -a "$LOG_FILE"

  log "  Token wird erstellt (privsep=0)..."
  TOKEN_OUTPUT=$(pveum user token add casaos@pve casaos-bridge-token --privsep 0 2>&1)
  echo "$TOKEN_OUTPUT" >> "$LOG_FILE"

  # Token-Wert aus tabellarischer Ausgabe extrahieren
  TOKEN_VALUE=$(echo "$TOKEN_OUTPUT" | grep -E "│ value" | sed 's/.*│ *//;s/ *│.*//' | tr -d ' ')
  if [ -z "$TOKEN_VALUE" ]; then
    # Fallback: letzte UUID-artige Zeichenkette
    TOKEN_VALUE=$(echo "$TOKEN_OUTPUT" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)
  fi

  if [ -n "$TOKEN_VALUE" ]; then
    PROXMOX_TOKEN="PVEAPIToken=casaos@pve!casaos-bridge-token=${TOKEN_VALUE}"
    log "  ✓ Token erstellt: casaos@pve!casaos-bridge-token"
  else
    log "  ✗ Token-Wert konnte nicht extrahiert werden!"
    ERRORS=$((ERRORS + 1))
  fi

  log "  ACL: Administrator auf / ..."
  pveum acl modify / -user casaos@pve -role Administrator 2>&1 | tee -a "$LOG_FILE"
  log "  ✓ API-User + Token + ACL konfiguriert"
else
  log "  API-User casaos@pve existiert bereits"
  # Token-Wert aus bestehender .env lesen
  PROXMOX_TOKEN=$(pct exec 120 -- grep "^PROXMOX_TOKEN=" /opt/openclaw-proxmox/casaos-lxc-bridge/.env 2>/dev/null | cut -d= -f2- || echo "")
  if [ -n "$PROXMOX_TOKEN" ]; then
    log "  ✓ Token aus .env uebernommen"
  else
    log "  ⚠ Kein Token in .env gefunden — manuell setzen!"
    ERRORS=$((ERRORS + 1))
  fi
fi

# ── Schritt 3: Bridge .env aktualisieren (LXC 120) ──────────────────────────
log_section "Schritt 3: Bridge .env aktualisieren"

ENV_FILE="/opt/openclaw-proxmox/casaos-lxc-bridge/.env"

# Pruefen ob LXC 120 laeuft und .env existiert
if ! pct status 120 2>/dev/null | grep -q "running"; then
  log "  ✗ LXC 120 laeuft nicht — .env-Update uebersprungen"
  ERRORS=$((ERRORS + 1))
else
  if ! pct exec 120 -- test -f "$ENV_FILE" 2>/dev/null; then
    log "  ✗ ${ENV_FILE} nicht gefunden — Update uebersprungen"
    ERRORS=$((ERRORS + 1))
  else
    log "  Aktualisiere .env-Werte..."

    # Hauptwerte per sed ersetzen
    pct exec 120 -- sed -i \
      -e "s|^PROXMOX_HOST=.*|PROXMOX_HOST=https://${HOST_IP}:8006|" \
      -e "s|^PROXMOX_NODE=.*|PROXMOX_NODE=${NODE_NAME}|" \
      -e "s|^PROXMOX_STORAGE=.*|PROXMOX_STORAGE=${STORAGE}|" \
      -e "s|^AUTHENTIK_URL=.*|AUTHENTIK_URL=http://${LXC_125_IP}:9000|" \
      -e "s|^OIDC_ISSUER=.*|OIDC_ISSUER=http://${LXC_125_IP}:9000/application/o/openclaw-admin/|" \
      -e "s|^HEADSCALE_URL=.*|HEADSCALE_URL=http://${LXC_115_IP}:8080|" \
      -e "s|^HEADSCALE_LXC_IP=.*|HEADSCALE_LXC_IP=${LXC_115_IP}|" \
      -e "s|^PORTAINER_URL=.*|PORTAINER_URL=http://${LXC_130_IP}:9000|" \
      -e "s|^BRIDGE_HOST_IP=.*|BRIDGE_HOST_IP=${LXC_120_IP}|" \
      -e "s|^BRIDGE_URL=.*|BRIDGE_URL=http://${LXC_120_IP}:8200|" \
      "$ENV_FILE" 2>&1 | tee -a "$LOG_FILE"

    # Token separat (enthält Sonderzeichen)
    if [ -n "$PROXMOX_TOKEN" ]; then
      pct exec 120 -- sed -i "s|^PROXMOX_TOKEN=.*|PROXMOX_TOKEN=${PROXMOX_TOKEN}|" "$ENV_FILE"
    fi

    # STORAGE_TIER_PREMIUM/STANDARD: hinzufuegen falls fehlt, ersetzen falls vorhanden
    pct exec 120 -- bash -c "
      grep -q '^STORAGE_TIER_PREMIUM=' '$ENV_FILE' \
        && sed -i 's|^STORAGE_TIER_PREMIUM=.*|STORAGE_TIER_PREMIUM=${STORAGE}|' '$ENV_FILE' \
        || echo 'STORAGE_TIER_PREMIUM=${STORAGE}' >> '$ENV_FILE'
      grep -q '^STORAGE_TIER_STANDARD=' '$ENV_FILE' \
        && sed -i 's|^STORAGE_TIER_STANDARD=.*|STORAGE_TIER_STANDARD=${STORAGE}|' '$ENV_FILE' \
        || echo 'STORAGE_TIER_STANDARD=${STORAGE}' >> '$ENV_FILE'
    "

    log "  ✓ .env aktualisiert (${NODE_NAME} / ${STORAGE} / ${HOST_IP})"
  fi
fi

# ── Schritt 4: Authentik reparieren (LXC 125) ────────────────────────────────
log_section "Schritt 4: Authentik reparieren"

if ! pct status 125 2>/dev/null | grep -q "running"; then
  log "  ⚠ LXC 125 laeuft nicht — Authentik-Fix uebersprungen"
else
  # Warten bis Authentik erreichbar ist (max 90s)
  log "  Warte auf Authentik (max 90s)..."
  AK_READY=false
  for i in $(seq 1 18); do
    if curl -sk -o /dev/null -w "%{http_code}" "http://${LXC_125_IP}:9000/" 2>/dev/null | grep -qE "200|301|302"; then
      AK_READY=true
      break
    fi
    sleep 5
  done

  if [ "$AK_READY" = "false" ]; then
    log "  ⚠ Authentik nicht erreichbar nach 90s — Fix uebersprungen"
    ERRORS=$((ERRORS + 1))
  else
    log "  Authentik erreichbar"

    # 4a: Domain-Eintrag sicherstellen
    log "  Domain-Eintrag fuer ${LXC_125_IP}..."
    pct exec 125 -- docker exec -i authentik-postgresql-1 \
      psql -U authentik -d authentik -c \
      "INSERT INTO authentik_tenants_domain (domain, is_primary, tenant_id)
       SELECT '${LXC_125_IP}', true, tenant_uuid
       FROM authentik_tenants_tenant
       WHERE schema_name = 'public'
         AND NOT EXISTS (SELECT 1 FROM authentik_tenants_domain WHERE domain = '${LXC_125_IP}');" \
      2>&1 | tee -a "$LOG_FILE" || true
    log "  ✓ Domain-Eintrag geprueft"

    # 4b: Redis-Cache leeren
    log "  Redis-Cache leeren..."
    pct exec 125 -- docker exec authentik-redis-1 redis-cli FLUSHALL \
      2>&1 | tee -a "$LOG_FILE" || true

    # 4c: Application openclaw-admin erstellen (falls nicht vorhanden)
    AUTHENTIK_TOKEN=$(pct exec 120 -- grep "^AUTHENTIK_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")
    if [ -n "$AUTHENTIK_TOKEN" ]; then
      log "  Pruefe Application openclaw-admin..."

      # Warten nach Redis-Flush (Authentik braucht kurz)
      sleep 3

      APP_CHECK=$(curl -sk \
        -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
        "http://${LXC_125_IP}:9000/api/v3/core/applications/?search=openclaw-admin" 2>/dev/null || echo "")
      APP_COUNT=$(echo "$APP_CHECK" | grep -oP '"count":\K[0-9]+' || echo "0")

      if [ "$APP_COUNT" = "0" ]; then
        log "  Application fehlt — wird erstellt..."

        # Provider-ID ermitteln
        PROVIDER_ID=$(curl -sk \
          -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
          "http://${LXC_125_IP}:9000/api/v3/providers/oauth2/?search=OpenClaw" 2>/dev/null \
          | grep -oP '"pk":\K[0-9]+' | head -1 || echo "")

        if [ -n "$PROVIDER_ID" ]; then
          cat > /tmp/create-app.json << APPJSON
{"name":"OpenClaw Admin","slug":"openclaw-admin","provider":${PROVIDER_ID},"meta_launch_url":"http://${LXC_120_IP}:8200","policy_engine_mode":"any"}
APPJSON
          RESULT=$(curl -sk -X POST \
            -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d @/tmp/create-app.json \
            "http://${LXC_125_IP}:9000/api/v3/core/applications/" 2>&1)
          rm -f /tmp/create-app.json

          if echo "$RESULT" | grep -q "openclaw-admin"; then
            log "  ✓ Application openclaw-admin erstellt"
          else
            log "  ⚠ Application-Erstellung unklar: $(echo "$RESULT" | head -c 200)"
          fi
        else
          log "  ⚠ OAuth2-Provider nicht gefunden — Application nicht erstellt"
          ERRORS=$((ERRORS + 1))
        fi
      else
        log "  ✓ Application openclaw-admin existiert bereits"
      fi
    else
      log "  ⚠ Kein AUTHENTIK_TOKEN in .env — Application-Check uebersprungen"
    fi

    # 4d: Authentik neustarten (Domain-Eintrag aktivieren)
    log "  Authentik Server neustarten..."
    pct exec 125 -- docker restart authentik-server-1 authentik-worker-1 \
      2>&1 | tee -a "$LOG_FILE" || true
    log "  ✓ Authentik neugestartet"
  fi
fi

# ── Schritt 5: Bridge-Container neu erstellen ────────────────────────────────
log_section "Schritt 5: Bridge-Container neu erstellen"

if pct status 120 2>/dev/null | grep -q "running"; then
  log "  docker compose down + up (neue .env laden)..."
  pct exec 120 -- bash -c \
    "cd /opt/openclaw-proxmox/casaos-lxc-bridge && docker compose down && docker compose up -d" \
    2>&1 | tee -a "$LOG_FILE" || true
  log "  ✓ Bridge-Container neu erstellt"
else
  log "  ✗ LXC 120 laeuft nicht — Container-Neustart uebersprungen"
  ERRORS=$((ERRORS + 1))
fi

# ── Schritt 6: Verifikation ──────────────────────────────────────────────────
log_section "Schritt 6: Verifikation"

# Warten bis Bridge hochgefahren ist (max 30s)
BRIDGE_READY=false
for i in $(seq 1 6); do
  if curl -sk -o /dev/null "http://${LXC_120_IP}:8200/" 2>/dev/null; then
    BRIDGE_READY=true
    break
  fi
  sleep 5
done

if [ "$BRIDGE_READY" = "true" ]; then
  log "  ✓ Bridge erreichbar auf http://${LXC_120_IP}:8200"
else
  log "  ⚠ Bridge nicht erreichbar nach 30s"
  ERRORS=$((ERRORS + 1))
fi

# ENV-Verifikation
VERIFY_NODE=$(pct exec 120 -- docker exec casaos-lxc-bridge-casaos-lxc-bridge-1 \
  printenv PROXMOX_NODE 2>/dev/null || echo "FEHLER")
VERIFY_STORAGE=$(pct exec 120 -- docker exec casaos-lxc-bridge-casaos-lxc-bridge-1 \
  printenv PROXMOX_STORAGE 2>/dev/null || echo "FEHLER")

if [ "$VERIFY_NODE" = "$NODE_NAME" ] && [ "$VERIFY_STORAGE" = "$STORAGE" ]; then
  log "  ✓ Container-ENV korrekt: NODE=${VERIFY_NODE}, STORAGE=${VERIFY_STORAGE}"
else
  log "  ⚠ Container-ENV Mismatch: NODE=${VERIFY_NODE} (erwartet: ${NODE_NAME}), STORAGE=${VERIFY_STORAGE} (erwartet: ${STORAGE})"
  ERRORS=$((ERRORS + 1))
fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
log ""
log "════════════════════════════════════════════════"
log "  Phase 9: Hardware-Adaptation abgeschlossen"
log "════════════════════════════════════════════════"
log ""
log "  Node:    ${NODE_NAME}"
log "  Storage: ${STORAGE}"
log "  Host-IP: ${HOST_IP}"
log "  LXC 120: ${LXC_120_IP} (Bridge)"
log "  LXC 115: ${LXC_115_IP} (Headscale)"
log "  LXC 125: ${LXC_125_IP} (Authentik)"
log "  LXC 130: ${LXC_130_IP} (Portainer)"
log ""

if [ "$ERRORS" -gt 0 ]; then
  log "  ⚠ ${ERRORS} Fehler aufgetreten — siehe Log oben"
  log_remote "Phase 9: ${ERRORS} Fehler — manuelle Pruefung noetig"
else
  log "  ✓ Alle Anpassungen erfolgreich"
  log_remote "Phase 9: Hardware-Adaptation OK (${NODE_NAME}/${STORAGE}/${HOST_IP})"
fi
