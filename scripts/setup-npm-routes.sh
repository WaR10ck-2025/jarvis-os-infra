#!/bin/bash
# setup-npm-routes.sh — NPM Proxy-Host-Eintraege fuer J.A.R.V.I.S-OS
#
# Konfiguriert Nginx Proxy Manager (LXC 10, 192.168.10.140:81) mit
# Proxy-Hosts fuer Admin-Portal, User-Portale und Admin-Service.
#
# NPM-API Dokumentation: https://nginxproxymanager.com/advanced-config/
#
# Voraussetzung: NPM laeuft auf LXC 10, Admin-Login bekannt.
# Verwendung: bash scripts/setup-npm-routes.sh
set -e

NPM_URL="http://192.168.10.140:81"
NPM_EMAIL="${NPM_EMAIL:-elias.boos.000@gmail.com}"
NPM_PASSWORD="${NPM_PASSWORD:-test1234567890}"

echo "=== J.A.R.V.I.S-OS NPM Route-Setup ==="

# ── NPM Login ──────────────────────────────────────────────────────────────
echo "Login bei NPM..."
TOKEN=$(curl -sf "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASSWORD}\"}" \
  | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "FEHLER: NPM-Login fehlgeschlagen!"
    echo "  URL: ${NPM_URL}"
    echo "  Email: ${NPM_EMAIL}"
    echo "  Manuell: http://192.168.10.140:81 → Proxy Hosts"
    exit 1
fi

echo "Login erfolgreich."

# ── Helper: Proxy-Host erstellen ────────────────────────────────────────────
create_proxy_host() {
    local domain="$1"
    local forward_host="$2"
    local forward_port="$3"
    local websocket="${4:-false}"

    echo "  Erstelle: ${domain} → ${forward_host}:${forward_port}"

    curl -sf "${NPM_URL}/api/nginx/proxy-hosts" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"domain_names\": [\"${domain}\"],
        \"forward_scheme\": \"http\",
        \"forward_host\": \"${forward_host}\",
        \"forward_port\": ${forward_port},
        \"block_exploits\": true,
        \"allow_websocket_upgrade\": ${websocket},
        \"access_list_id\": 0,
        \"advanced_config\": \"\",
        \"meta\": {\"letsencrypt_agree\": false, \"dns_challenge\": false}
      }" > /dev/null 2>&1 || echo "    (existiert evtl. bereits)"
}

# ── Zentrale Services ───────────────────────────────────────────────────────
echo ""
echo "Zentrale Service-Routen:"

# Admin-Service API (LXC 160)
create_proxy_host "admin-api.jarvis.local" "192.168.10.160" 8300

# Admin-Portal (Admin-VM, NodePort 30080)
create_proxy_host "admin.jarvis.local" "192.168.10.155" 30080 true

# Mail Web-Admin
create_proxy_host "mail.jarvis.local" "192.168.10.135" 443

# Samba WebDAV (falls spaeter eingerichtet)
# create_proxy_host "files.jarvis.local" "192.168.10.130" 8080

# ── Bestehende Services (bereits konfiguriert, hier als Referenz) ───────────
echo ""
echo "Bestehende Routen (nur Referenz — nicht erneut erstellt):"
echo "  authentik.jarvis.local   → 192.168.10.125:9000  (bereits vorhanden)"
echo "  headscale.jarvis.local   → 192.168.10.115:8080  (bereits vorhanden)"
echo "  nextcloud.jarvis.local   → 192.168.10.109:80    (bereits vorhanden)"
echo "  n8n.jarvis.local         → 192.168.10.104:5678  (bereits vorhanden)"

# ── User-Portal-Routen (dynamisch — vom Admin-Service bei User-Erstellung) ──
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  User-Portal-Routen werden dynamisch erstellt!           ║"
echo "║  Der Admin-Service ruft NPM-API bei User-Provisioning.   ║"
echo "║                                                          ║"
echo "║  Beispiel:                                               ║"
echo "║    alice.jarvis.local → 192.168.10.150:30080 (DNAT)     ║"
echo "║    bob.jarvis.local   → 192.168.10.151:30080 (DNAT)     ║"
echo "╚═══════════════════════════════════════════════════════════╝"

echo ""
echo "=== NPM Route-Setup abgeschlossen ==="
echo ""
echo "NPM Admin: http://192.168.10.140:81"
echo "Alle Proxy-Hosts pruefen: ${NPM_URL}/api/nginx/proxy-hosts"
echo ""
