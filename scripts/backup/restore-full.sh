#!/bin/bash
# restore-full.sh — Geführter Full-Restore-Assistent für neue Hardware
# Interaktiver Schritt-für-Schritt Restore der gesamten OpenClaw-Infrastruktur.
# Läuft auf dem frisch installierten Proxmox-Host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"

# Farben
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*"; }
info() { echo -e "${BLUE}  →${RESET} $*"; }
step() { echo ""; echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"; \
         echo -e "${BOLD}  Schritt $1: $2${RESET}"; \
         echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"; }

confirm() {
  local msg="$1"
  echo -e "${YELLOW}  ?${RESET} $msg [y/N]: \c"
  read -r REPLY
  [[ "${REPLY,,}" == "y" ]]
}

wait_confirm() {
  echo -e "${YELLOW}  →${RESET} $* ... Weiter mit ENTER wenn erledigt."
  read -r
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         OpenClaw Proxmox — Full-Restore-Assistent            ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║  Dieser Assistent stellt die gesamte Infrastruktur auf       ║${RESET}"
echo -e "${BOLD}║  neuer Hardware wieder her.                                   ║${RESET}"
echo -e "${BOLD}║  Geschätzte Dauer: 90–120 Minuten                            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Phase 1: Proxmox-Installation prüfen ─────────────────────────────────────
step "1/6" "Proxmox-Installation prüfen"

if command -v pveversion &>/dev/null; then
  ok "Proxmox VE installiert: $(pveversion 2>/dev/null | head -1)"
else
  err "Proxmox VE ist NICHT installiert!"
  echo ""
  info "Proxmox zuerst installieren:"
  info "  1. proxmox-openclaw.iso auf USB flashen (Balena Etcher)"
  info "  2. Von USB booten → Autoinstall läuft automatisch durch"
  info "  3. Warten bis System neugestartet ist (~10-20 Min)"
  info "  4. SSH: ssh root@192.168.10.147"
  info "  5. Dieses Script erneut ausführen"
  echo ""
  exit 1
fi

# ── Phase 2: Repo + Backup-Tools ─────────────────────────────────────────────
step "2/6" "Backup-Tools & Konfiguration einrichten"

if [ ! -f "$CONFIG_FILE" ]; then
  warn "config/backup.conf nicht gefunden"
  info "Bitte manuell einrichten:"
  echo ""
  echo "  git clone https://github.com/WaR10ck-2025/openclaw-proxmox.git /opt/openclaw"
  echo "  bash /opt/openclaw/scripts/backup/install-backup-deps.sh"
  echo ""
  wait_confirm "Repo klonen und install-backup-deps.sh ausführen"

  if [ ! -f "$CONFIG_FILE" ]; then
    err "config/backup.conf immer noch nicht gefunden. Abbruch."
    exit 1
  fi
fi

source "$CONFIG_FILE"

# age-Key prüfen
if [ ! -f "$AGE_KEY_FILE" ]; then
  warn "age-Key nicht gefunden: $AGE_KEY_FILE"
  echo ""
  info "age-Key auf diesen Host kopieren:"
  info "  Aus Passwort-Manager: den gespeicherten Key in /root/.age/key.txt einfügen"
  info "  Von USB: cp /mnt/usb-key/age-key.txt /root/.age/key.txt"
  info "  chmod 600 /root/.age/key.txt"
  echo ""
  wait_confirm "age-Key nach /root/.age/key.txt kopiert"

  if [ ! -f "$AGE_KEY_FILE" ]; then
    err "age-Key fehlt — Config-Backup kann nicht entschlüsselt werden"
    if ! confirm "Ohne Config-Restore fortfahren? (nur vzdump-Restore möglich)"; then
      exit 1
    fi
    SKIP_CONFIG_RESTORE=true
  fi
fi

ok "Backup-Tools bereit"

# ── Phase 3: Backup-Medium ermitteln ─────────────────────────────────────────
step "3/6" "Backup-Medium prüfen"

echo ""
echo "  Verfügbare Backup-Quellen:"
echo "  [1] USB-Festplatte (Label: $BACKUP_USB_LABEL)"
echo "  [2] Netzwerkfreigabe ($BACKUP_NETWORK_HOST/$BACKUP_NETWORK_SHARE)"
echo "  [3] GitHub ($GITHUB_REPO)"
echo ""
echo -e "${YELLOW}  ?${RESET} Backup-Quelle wählen [1/2/3]: \c"
read -r BACKUP_SOURCE_CHOICE

case "$BACKUP_SOURCE_CHOICE" in
  1) RESTORE_FROM="usb" ;;
  2) RESTORE_FROM="network" ;;
  3) RESTORE_FROM="github" ;;
  *) RESTORE_FROM="usb" ;;
esac

# USB mounten
if [ "$RESTORE_FROM" = "usb" ]; then
  USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
  if [ -z "$USB_DEV" ]; then
    warn "USB-Festplatte nicht gefunden"
    wait_confirm "USB-Festplatte einstecken (Label: $BACKUP_USB_LABEL)"
    USB_DEV=$(blkid -L "$BACKUP_USB_LABEL" 2>/dev/null || true)
  fi
  if [ -n "$USB_DEV" ]; then
    mountpoint -q "$BACKUP_USB_MOUNT" || mount "$USB_DEV" "$BACKUP_USB_MOUNT"
    ok "USB gemountet: $USB_DEV → $BACKUP_USB_MOUNT"

    # Backups anzeigen
    echo ""
    info "Vorhandene Config-Backups:"
    ls -lt "${BACKUP_BASE_DIR_USB}/configs/" 2>/dev/null | head -10 || \
      warn "Keine Config-Backups auf USB"
    echo ""
    info "Vorhandene vzdump-Backups:"
    ls -lt "${BACKUP_BASE_DIR_USB}/dump/" 2>/dev/null | grep ".vma.zst" | head -10 || \
      warn "Keine vzdump-Backups auf USB"
  else
    err "USB-Festplatte konnte nicht gemountet werden"
    exit 1
  fi

elif [ "$RESTORE_FROM" = "network" ]; then
  if ping -c1 -W3 "$BACKUP_NETWORK_HOST" &>/dev/null; then
    if [ "$BACKUP_NETWORK_TYPE" = "smb" ]; then
      mountpoint -q "$BACKUP_NETWORK_MOUNT" || \
        mount -t cifs "//${BACKUP_NETWORK_HOST}/${BACKUP_NETWORK_SHARE}" \
          "$BACKUP_NETWORK_MOUNT" \
          -o "credentials=/etc/backup-credentials,uid=0,gid=0,vers=3.0"
    else
      mountpoint -q "$BACKUP_NETWORK_MOUNT" || \
        mount -t nfs "${BACKUP_NETWORK_HOST}:/${BACKUP_NETWORK_SHARE}" "$BACKUP_NETWORK_MOUNT"
    fi
    ok "Netzwerkfreigabe gemountet"
  else
    err "NAS $BACKUP_NETWORK_HOST nicht erreichbar"
    exit 1
  fi
fi

# ZFS-Pool prüfen
echo ""
if confirm "ZFS-Pool importieren? (falls ZFS als Storage verwendet)"; then
  info "Vorhandene ZFS-Pools suchen..."
  zpool import 2>/dev/null | grep "pool:" | awk '{print $2}' || echo "  Keine importierbaren Pools"
  echo ""
  echo -e "${YELLOW}  ?${RESET} Pool-Name (leer = überspringen): \c"
  read -r ZFS_POOL
  if [ -n "$ZFS_POOL" ]; then
    zpool import -f "$ZFS_POOL" && ok "ZFS-Pool '$ZFS_POOL' importiert" || \
      warn "ZFS-Pool-Import fehlgeschlagen"
  fi
fi

# ── Phase 4: Config-Restore ──────────────────────────────────────────────────
step "4/6" "Proxmox-Konfiguration wiederherstellen"

if [ "${SKIP_CONFIG_RESTORE:-false}" = "true" ]; then
  warn "Config-Restore übersprungen (kein age-Key)"
else
  info "Neuesten Config-Backup wiederherstellen..."
  bash "${SCRIPT_DIR}/restore-config.sh" --from-${RESTORE_FROM}
fi

ok "Proxmox-Konfiguration wiederhergestellt"

# ── Phase 5: LXC-Restore ─────────────────────────────────────────────────────
step "5/6" "LXCs wiederherstellen"

echo ""
echo "  Restore-Reihenfolge (kritisch — Abhängigkeiten beachten):"
echo ""
echo "  Infrastruktur (zuerst):"
echo "    [1] LXC 10  — Nginx Proxy Manager (192.168.10.140)"
echo "    [2] LXC 115 — Headscale VPN (192.168.10.115)"
echo "    [3] LXC 125 — Authentik SSO (192.168.10.125)"
echo ""
echo "  Services:"
echo "    [4] LXC 109 — Nextcloud (192.168.10.109)"
echo "    [5] LXC 104 — n8n Automation (192.168.10.104)"
echo "    [6] LXC 120 — CasaOS Bridge (192.168.10.141)"
echo "    [7] Weitere (101-108, 130, 200-202, 210)"
echo ""
echo "  VM:"
echo "    [8] VM 100  — Windows OBD2 (192.168.10.220)"
echo ""
echo "  [a] Alle Prioritären automatisch wiederherstellen"
echo "  [s] Einzeln auswählen"
echo ""
echo -e "${YELLOW}  ?${RESET} Modus wählen [a/s]: \c"
read -r RESTORE_MODE

TARGET_STORAGE="${STORAGE:-local-zfs}"
echo -e "${YELLOW}  ?${RESET} Ziel-Storage [${TARGET_STORAGE}]: \c"
read -r STORAGE_INPUT
[ -n "$STORAGE_INPUT" ] && TARGET_STORAGE="$STORAGE_INPUT"

if [ "${RESTORE_MODE,,}" = "a" ]; then
  # Alle prioritären LXCs in Reihenfolge
  for LXC_RESTORE in 10 115 125 109 104 120; do
    if confirm "LXC $LXC_RESTORE wiederherstellen?"; then
      bash "${SCRIPT_DIR}/restore-lxc.sh" --lxc "$LXC_RESTORE" --storage "$TARGET_STORAGE" || \
        warn "LXC $LXC_RESTORE: Restore fehlgeschlagen — manuell prüfen"
    fi
  done
else
  # Manuell
  while true; do
    echo -e "${YELLOW}  ?${RESET} LXC/VM ID (leer = fertig, 'vm:100' für VM): \c"
    read -r RESTORE_INPUT
    [ -z "$RESTORE_INPUT" ] && break

    if [[ "$RESTORE_INPUT" == vm:* ]]; then
      VM_ID="${RESTORE_INPUT#vm:}"
      bash "${SCRIPT_DIR}/restore-lxc.sh" --vm "$VM_ID" --storage "$TARGET_STORAGE" || \
        warn "VM $VM_ID: Restore fehlgeschlagen"
    else
      bash "${SCRIPT_DIR}/restore-lxc.sh" --lxc "$RESTORE_INPUT" --storage "$TARGET_STORAGE" || \
        warn "LXC $RESTORE_INPUT: Restore fehlgeschlagen"
    fi
  done
fi

ok "LXC-Restore-Phase abgeschlossen"

# ── Phase 6: App-Daten zurückspielen ─────────────────────────────────────────
step "6/6" "App-Daten zurückspielen"

echo ""
echo "  Welche App-Daten sollen zurückgespielt werden?"
echo "  [1] Alle (nextcloud, n8n, headscale, authentik)"
echo "  [2] Nur auswählen"
echo "  [3] Überspringen"
echo ""
echo -e "${YELLOW}  ?${RESET} Auswahl [1/2/3]: \c"
read -r APPDATA_CHOICE

case "$APPDATA_CHOICE" in
  1)
    bash "${SCRIPT_DIR}/restore-appdata.sh" --service all || \
      warn "Einige App-Daten konnten nicht wiederhergestellt werden"
    ;;
  2)
    for SVC in nextcloud n8n headscale authentik; do
      if confirm "  $SVC wiederherstellen?"; then
        bash "${SCRIPT_DIR}/restore-appdata.sh" --service "$SVC" || \
          warn "$SVC: Restore fehlgeschlagen"
      fi
    done
    ;;
  3) warn "App-Daten übersprungen" ;;
esac

# ── Abschluss-Validierung ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Validierung${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo ""

echo "  Laufende LXCs:"
pct list 2>/dev/null | tee /dev/null || true
echo ""
echo "  HTTP-Checks:"

check_http() {
  local name="$1" url="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "200" || "$code" == "302" || "$code" == "301" ]]; then
    ok "$name ($url) → HTTP $code"
  else
    warn "$name ($url) → HTTP $code (nicht erreichbar)"
  fi
}

check_http "Nginx PM"   "http://192.168.10.140:81"
check_http "Nextcloud"  "http://192.168.10.109"
check_http "n8n"        "http://192.168.10.104:5678"
check_http "CasaOS"     "http://192.168.10.141"

# ── Zusammenfassung ───────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║               Full-Restore abgeschlossen!                    ║${RESET}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}${BOLD}║  Proxmox Web-UI: https://192.168.10.147:8006                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  Nächste Schritte:                                            ║${RESET}"
echo -e "${GREEN}${BOLD}║  1. SSL-Zertifikate in Nginx PM neu ausstellen               ║${RESET}"
echo -e "${GREEN}${BOLD}║  2. Headscale: tailscale-Clients prüfen                      ║${RESET}"
echo -e "${GREEN}${BOLD}║  3. Authentik: OIDC-Provider-URLs prüfen                     ║${RESET}"
echo -e "${GREEN}${BOLD}║  4. Nextcloud: Admin-Login testen                            ║${RESET}"
echo -e "${GREEN}${BOLD}║  5. Backup-System aktivieren: install-backup-deps.sh         ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
