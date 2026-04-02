#!/bin/bash
# first-boot.sh — OpenClaw Basis-Plattform Setup
#
# Läuft EINMAL nach dem ersten Proxmox-Boot (via first-boot.service).
# Deployt die drei Basis-LXCs: Nginx Proxy Manager, CasaOS, Deployment Hub.
# Alle weiteren Services über CasaOS App-Store installierbar.
#
# Voraussetzungen:
#   - Proxmox VE 8.x installiert + gebootet
#   - LUKS entsperrt (System läuft)
#   - Internetzugang (DHCP aktiv)
#
# Logs: journalctl -u openclaw-first-boot -f

set -e

LOG_FILE="/var/log/openclaw-first-boot.log"
DONE_FLAG="/etc/openclaw-setup.done"
REPO_URL="https://github.com/WaR10ck-2025/openclaw-proxmox.git"
REPO_DIR="/opt/openclaw-proxmox"
SCRIPTS="$REPO_DIR/scripts"
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"

# Remote-Logging via ntfy.sh (kostenlos, kein Setup, kein Account)
NTFY_TOPIC="openclaw-first-boot-$(cat /etc/machine-id 2>/dev/null | head -c 8 || echo 'default')"
NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"

# Logging-Helper
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_section() { log ""; log "══════════════════════════════════════════════"; log "  $*"; log "══════════════════════════════════════════════"; }

# Remote-Log: schickt jede Zeile an ntfy.sh (non-blocking, Fehler ignoriert)
log_remote() {
  local msg="$*"
  log "$msg"
  curl -s -d "$msg" "$NTFY_URL" >/dev/null 2>&1 &
}
# Sammel-Push: komplettes Logfile am Ende senden
log_remote_dump() {
  local status="${1:-done}"
  curl -s \
    -H "Title: OpenClaw First-Boot: ${status}" \
    -H "Priority: high" \
    -d "$(tail -100 "$LOG_FILE")" \
    "$NTFY_URL" >/dev/null 2>&1 || true
}

# TTY fuer interaktive Ausgabe (Modus A: --on-first-boot hat kein TTY)
TTY_DEV="/dev/tty1"
tty_write() { echo "$*" | tee -a "$LOG_FILE" > "$TTY_DEV" 2>/dev/null || log "$*"; }
tty_read() {
  local secs=$1
  # Terminal in sauberen Zustand versetzen (nach getty-Stop)
  stty sane < "$TTY_DEV" 2>/dev/null || true
  # timeout + head statt read -t (read -t funktioniert nicht mit Device-File-Redirect)
  timeout "$secs" head -n1 < "$TTY_DEV" 2>/dev/null || true
}

# getty auf tty1 stoppen (sonst frisst es unsere Eingabe als Login-Versuch)
systemctl stop getty@tty1.service 2>/dev/null || true
# Terminal zuruecksetzen und leeren
stty sane < "$TTY_DEV" 2>/dev/null || true
echo -e "\033c" > "$TTY_DEV" 2>/dev/null || true

# Bei Fehler/Crash: Log automatisch an ntfy senden
trap 'log_remote_dump "CRASHED (exit $?)"' ERR

log_section "OpenClaw First-Boot Setup startet"
log_remote "=== FIRST-BOOT GESTARTET === Topic: $NTFY_TOPIC | $(hostname) | $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1 || echo 'keine IP')"

# ── Schritt 1: Warten bis Netzwerk bereit ─────────────────────────────────
log "Warte auf Netzwerkverbindung..."
for i in $(seq 1 30); do
  if ping -c1 -W2 1.1.1.1 &>/dev/null; then
    log "✓ Netzwerk erreichbar"
    break
  fi
  [ "$i" -eq 30 ] && { log "✗ Kein Netzwerk nach 60s — abbruch"; exit 1; }
  sleep 2
done

# ── Schritt 1b: APT Repos fixen + Basis-Pakete (VOR Menü — restore-hook.sh braucht Repo)
log_section "APT Repos konfigurieren"
tty_write "  APT Repos konfigurieren..."
# Enterprise-Repos deaktivieren (kein Abo → 401 Fehler bei apt-get update)
for f in /etc/apt/sources.list.d/pve-enterprise.sources \
          /etc/apt/sources.list.d/ceph.sources; do
  if [ -f "$f" ] && ! grep -q "^Enabled: no" "$f"; then
    echo "Enabled: no" >> "$f"
    log "  Deaktiviert: $f"
  fi
done
# No-Subscription Repo hinzufügen falls nicht vorhanden
if [ ! -f /etc/apt/sources.list.d/pve-no-subscription.list ]; then
  echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-no-subscription.list
  log "  No-Subscription Repo hinzugefügt"
fi
log "✓ APT Repos konfiguriert"

log_section "Basis-Pakete installieren"
tty_write "  Pakete installieren (git, curl)..."
apt-get update -qq
apt-get install -y -qq git curl
log "✓ Basis-Pakete installiert"

log_section "openclaw-proxmox Repo klonen"
tty_write "  Repo klonen..."
if [ -d "$REPO_DIR/.git" ]; then
  log "Repo bereits vorhanden — aktualisiere..."
  cd "$REPO_DIR" && git pull --quiet
else
  git clone --quiet "$REPO_URL" "$REPO_DIR"
  log "✓ Repo geklont: $REPO_DIR"
fi

# ── Schritt 1c: BOOT-MENÜ (Restore vs. Fresh-Install) ──────────────────────
#
# Sucht nach Backup-Daten in zwei Stufen:
#   1. Dedizierte Partition (Label=OPENCLAW-BAK) — Standard + Ventoy Modus C
#   2. Ventoy-Partition (Label=Ventoy) mit openclaw-backups/ Unterordner — Ventoy Modus B
#
# Zeigt Menü mit Backup-Info + 30s Countdown.
# Headless (stdin=/dev/null): read schlägt sofort fehl → Standard greift.

BACKUP_USB_MOUNT="/mnt/backup-usb"

# ── USB-Backup-Quelle suchen (2-stufig) ─────────────────────────────────────
find_backup_source() {
  mkdir -p "$BACKUP_USB_MOUNT"

  # Stufe 1: Dedizierte OPENCLAW-BAK Partition
  local dev
  dev=$(blkid -L "OPENCLAW-BAK" 2>/dev/null || true)
  if [ -n "$dev" ]; then
    mountpoint -q "$BACKUP_USB_MOUNT" || mount "$dev" "$BACKUP_USB_MOUNT" 2>/dev/null || true
    if [ -d "${BACKUP_USB_MOUNT}/openclaw-backups" ]; then
      echo "$dev"
      return 0
    fi
    umount "$BACKUP_USB_MOUNT" 2>/dev/null || true
  fi

  # Stufe 2: Ventoy-Partition mit openclaw-backups/ Ordner
  dev=$(blkid -L "Ventoy" 2>/dev/null || true)
  if [ -n "$dev" ]; then
    mountpoint -q "$BACKUP_USB_MOUNT" || mount "$dev" "$BACKUP_USB_MOUNT" 2>/dev/null || true
    if [ -d "${BACKUP_USB_MOUNT}/openclaw-backups/dump" ]; then
      echo "$dev"
      return 0
    fi
    umount "$BACKUP_USB_MOUNT" 2>/dev/null || true
  fi

  return 1
}

# ── Menü anzeigen + Modus bestimmen ──────────────────────────────────────────
show_boot_menu() {
  local backup_dev backup_found=false
  local lxc_count=0 vm_count=0 cfg_count=0 free_gb="?"

  backup_dev=$(find_backup_source 2>/dev/null || true)
  if [ -n "$backup_dev" ] && mountpoint -q "$BACKUP_USB_MOUNT"; then
    lxc_count=$(ls "${BACKUP_USB_MOUNT}/openclaw-backups/dump/"*.tar.zst 2>/dev/null | wc -l || echo 0)
    vm_count=$(ls "${BACKUP_USB_MOUNT}/openclaw-backups/dump/"*.vma.zst 2>/dev/null | wc -l || echo 0)
    cfg_count=$(find "${BACKUP_USB_MOUNT}/openclaw-backups/configs/" -name "*.age" 2>/dev/null | wc -l || echo 0)
    free_gb=$(df -BG "$BACKUP_USB_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "?")
    [ "$((lxc_count + vm_count + cfg_count))" -gt 0 ] && backup_found=true
  fi

  tty_write ""
  tty_write "============================================================"
  tty_write "           OpenClaw Proxmox -- Willkommen                   "
  tty_write "============================================================"
  tty_write "  [1]  Fresh-Install      Neue Installation                 "
  if [ "$backup_found" = "true" ]; then
    tty_write "  [2]  Disaster Recovery  Backup von USB wiederherstellen   "
    tty_write "------------------------------------------------------------"
    tty_write "  Backup erkannt:  ${lxc_count} LXCs  ${vm_count} VMs  ${cfg_count} Configs  |  Frei: ${free_gb}GB"
    tty_write "============================================================"
    local default_mode=2
    tty_write ""
    tty_write "  Auswahl [1/2] (Standard: ${default_mode} -- Disaster Recovery -- in 30s):"
  else
    tty_write "  [2]  Disaster Recovery  (kein Backup erkannt -- inaktiv)  "
    tty_write "============================================================"
    local default_mode=1
    tty_write ""
    tty_write "  Auswahl [1] (Standard: Fresh-Install -- in 30s):"
  fi

  # Eingabe von tty1 mit Timeout — bei headless sofortiger EOF -> Standard
  local choice=""
  choice=$(tty_read 30)
  choice="${choice:-$default_mode}"

  case "$choice" in
    2)
      if [ "$backup_found" = "true" ]; then
        echo "restore"
      else
        log "  Kein Backup verfügbar — starte Fresh-Install"
        echo "fresh"
      fi
      ;;
    *) echo "fresh" ;;
  esac
}

log_section "Modus-Auswahl"
SELECTED_MODE=$(show_boot_menu)
log "  -> Modus: $SELECTED_MODE"
log_remote "Modus: $SELECTED_MODE"

# WICHTIG: getty NICHT hier starten — erst ganz am Ende!
# Sonst übernimmt getty tty1 und der User sieht nur den Login-Prompt statt Status.

# ── Modus-Weiche ─────────────────────────────────────────────────────────────
if [ "$SELECTED_MODE" = "restore" ]; then
  tty_write ""
  tty_write "============================================================"
  tty_write "  DISASTER RECOVERY: Vollstaendige Wiederherstellung        "
  tty_write "============================================================"
  tty_write ""
  log_section "DISASTER RECOVERY: Vollständige Wiederherstellung"
  log_remote "DISASTER RECOVERY gestartet"
  HOOK_SCRIPT="/root/openclaw-restore-hook.sh"
  [ ! -f "$HOOK_SCRIPT" ] && HOOK_SCRIPT="${REPO_DIR}/autoinstall/restore-hook.sh"
  if [ -f "$HOOK_SCRIPT" ]; then
    tty_write "  Starte restore-hook.sh ..."
    log_remote "restore-hook.sh gefunden: $HOOK_SCRIPT"
    bash "$HOOK_SCRIPT" 2>&1 | while IFS= read -r line; do
      tty_write "  $line"
    done
  else
    tty_write "  [!!] restore-hook.sh nicht gefunden!"
    log "✗ restore-hook.sh nicht gefunden — Restore abgebrochen"
    log "  Gesucht: /root/openclaw-restore-hook.sh"
    log_remote "FEHLER: restore-hook.sh nicht gefunden!"
    log_remote_dump "FAILED"
    systemctl start getty@tty1.service 2>/dev/null || true
    exit 1
  fi
  touch "$DONE_FLAG"
  tty_write ""
  tty_write "============================================================"
  tty_write "       Disaster Recovery abgeschlossen!                     "
  tty_write "============================================================"
  tty_write ""
  log "✓ Disaster Recovery abgeschlossen. Flag: $DONE_FLAG"
  log_remote_dump "RESTORE OK"
  # getty erst jetzt starten — User sieht alle Status-Meldungen
  systemctl start getty@tty1.service 2>/dev/null || true
  exit 0
fi

# Ab hier: normaler Fresh-Install ────────────────────────────────────────────

# ── Schritt 1c: NAT/Masquerade für LXC-Netzwerk aktivieren ──────────────────
# Stellt sicher dass LXCs Internet-Zugang haben, auch wenn der upstream Router
# das 192.168.10.x Subnetz nicht kennt (z.B. VirtualBox NAT, einfache Router).
log "Aktiviere IP-Masquerade für LXC-Netzwerk..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || \
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Falls kein Router bei 192.168.10.1 vorhanden (z.B. VirtualBox NAT):
# Proxmox-Host selbst als Gateway einrichten, damit LXC-Pakete den Host erreichen.
if ! ping -c1 -W2 192.168.10.1 &>/dev/null; then
  log "  Kein Router bei 192.168.10.1 — setze Host als LXC-Gateway (NAT-Modus)"
  ip addr show vmbr0 | grep -q '192.168.10.1/24' || \
    ip addr add 192.168.10.1/24 dev vmbr0
fi

# Masquerade: LXC-Traffic über Host-Uplink NATen
iptables -t nat -C POSTROUTING -s 192.168.10.0/24 ! -d 192.168.10.0/24 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 192.168.10.0/24 ! -d 192.168.10.0/24 -j MASQUERADE
log "✓ IP-Masquerade aktiv"

# (APT Repos bereits in Schritt 1b konfiguriert)

# ── Schritt 2: Subscription-Popup deaktivieren ───────────────────────────
log_section "Subscription-Popup deaktivieren"
PROXMOX_LIB="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [ -f "$PROXMOX_LIB" ]; then
  PATCHED=0
  # PVE 7.x Variante
  if grep -q "data.status !== 'Active'" "$PROXMOX_LIB"; then
    sed -i.bak "s/data.status !== 'Active'/false/g" "$PROXMOX_LIB"
    log "✓ Subscription-Popup deaktiviert (PVE 7.x)"
    PATCHED=1
  fi
  # PVE 8/9.x Variante
  if grep -q "res.data.status.toLowerCase() !== 'active'" "$PROXMOX_LIB"; then
    sed -i.bak "s/res.data.status.toLowerCase() !== 'active'/false/g" "$PROXMOX_LIB"
    log "✓ Subscription-Popup deaktiviert (PVE 8/9.x)"
    PATCHED=1
  fi
  [ "$PATCHED" -eq 0 ] && log "✓ proxmoxlib.js bereits gepatcht oder unbekannte PVE-Version"
  systemctl restart pveproxy 2>/dev/null && log "✓ pveproxy neugestartet" || true
else
  log "⚠ proxmoxlib.js nicht gefunden — Popup-Fix übersprungen"
fi

# ── Schritt 3: Debian 12 LXC Template ────────────────────────────────────
# (Basis-Pakete + Repo bereits in Schritt 1b installiert/geklont)
log_section "Debian 12 Template herunterladen"
pveam update 2>&1 | tail -1 || log "⚠ pveam update fehlgeschlagen — fahre mit bestehendem Cache fort"
if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
  pveam download local "$TEMPLATE"
  log "✓ Template heruntergeladen"
else
  log "✓ Template bereits vorhanden"
fi

# ── Schritt 4c: Storage auto-detektieren (local-lvm oder local-zfs) ──────────
LXC_STORAGE="local-lvm"
if ! pvesm status 2>/dev/null | grep -q "^local-lvm"; then
  if pvesm status 2>/dev/null | grep -q "^local-zfs"; then
    LXC_STORAGE="local-zfs"
    log "  Storage: local-zfs erkannt (ZFS-Installation)"
  elif pvesm status 2>/dev/null | grep -q "^local "; then
    LXC_STORAGE="local"
    log "  Storage: local erkannt (dir-Storage)"
  fi
else
  log "  Storage: local-lvm erkannt"
fi
# STORAGE als Umgebungsvariable exportieren (install-lxc-*.sh nutzen ${STORAGE:-local-zfs})
export STORAGE="$LXC_STORAGE"
log "✓ Storage konfiguriert: $LXC_STORAGE"

# ── Schritt 5: Basis-LXCs anlegen (parallel) ──────────────────────────────
log_section "LXC 110 + 120 + 170: Parallel-Installation"
log "Starte alle drei LXCs gleichzeitig..."

bash "$SCRIPTS/install-lxc-reverse-proxy.sh"   > /tmp/lxc-110.log 2>&1 & PID_110=$!
bash "$SCRIPTS/install-lxc-casaos.sh"           > /tmp/lxc-120.log 2>&1 & PID_120=$!
bash "$SCRIPTS/install-lxc-deployment-hub.sh"   > /tmp/lxc-170.log 2>&1 & PID_170=$!

INSTALL_FAIL=0
wait $PID_110 || { log "✗ LXC 110 fehlgeschlagen (Exit: $?)"; INSTALL_FAIL=1; }
wait $PID_120 || { log "✗ LXC 120 fehlgeschlagen (Exit: $?)"; INSTALL_FAIL=1; }
wait $PID_170 || { log "✗ LXC 170 fehlgeschlagen (Exit: $?)"; INSTALL_FAIL=1; }

cat /tmp/lxc-110.log >> "$LOG_FILE"
cat /tmp/lxc-120.log >> "$LOG_FILE"
cat /tmp/lxc-170.log >> "$LOG_FILE"

[ "$INSTALL_FAIL" -eq 0 ] || { log "✗ LXC-Installation fehlgeschlagen — Setup abgebrochen"; exit 1; }

# ── Schritt 6: ZFS-Unlock Service aktivieren (falls noch nicht) ───────────
if [ -f "$REPO_DIR/autoinstall/zfs-unlock.service" ]; then
  cp "$REPO_DIR/autoinstall/zfs-unlock.sh" /usr/local/bin/
  chmod +x /usr/local/bin/zfs-unlock.sh
  cp "$REPO_DIR/autoinstall/zfs-unlock.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable zfs-unlock.service
  log "✓ ZFS-Unlock Service aktiviert (für spätere ZFS Pools)"
fi

# ── Schritt 7: Optional — YubiKey-Enrollment ──────────────────────────────
# YubiKey FIDO2 Enrollment ist optional und kann jederzeit manuell ausgeführt werden.
# Automatisch nur wenn YubiKey beim ersten Boot eingesteckt ist:
if command -v systemd-cryptenroll &>/dev/null; then
  if lsusb 2>/dev/null | grep -qi "yubico\|1050:"; then
    log "YubiKey erkannt — starte optionales LUKS FIDO2 Enrollment..."
    bash "$REPO_DIR/autoinstall/yubikey-enroll.sh" \
      2>&1 | tee -a "$LOG_FILE" || \
      log "YubiKey-Enrollment übersprungen (kann manuell wiederholt werden)"
  else
    log "Info: Kein YubiKey erkannt — Passphrase-only Modus aktiv"
    log "      Optional nachholen: bash $REPO_DIR/autoinstall/yubikey-enroll.sh"
  fi
fi

# ── Schritt 8: Verschlüsselte ZFS Datendisks prüfen ──────────────────────
log_section "Datendisks prüfen (LUKS/ZFS)"
# Alle Disks auflisten die NICHT die System-Disk sind
SYS_DISK=$(lsblk -no pkname $(findmnt -n -o SOURCE /) 2>/dev/null | head -1 || echo "sda")
EXTRA_DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}' | grep -v "^$SYS_DISK$" || true)

if [ -n "$EXTRA_DISKS" ]; then
  log "Zusätzliche Disks gefunden: $EXTRA_DISKS"
  log "  → Verschlüsselten ZFS Pool anlegen:"
  log "     bash $REPO_DIR/autoinstall/zfs-pool-create.sh"
else
  log "Info: Keine zusätzlichen Datendisks — ZFS Pool kann später hinzugefügt werden"
  log "      bash $REPO_DIR/autoinstall/zfs-pool-create.sh"
fi

# ── Schritt 9: Status-Ausgabe ─────────────────────────────────────────────
log_section "Setup abgeschlossen"
PROXMOX_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1)

tty_write ""
tty_write "============================================================"
tty_write "               OpenClaw Setup abgeschlossen                  "
tty_write "============================================================"
tty_write ""
tty_write "  LXC 110 (Nginx Proxy Manager): http://192.168.10.140:81"
tty_write "    Login: admin@example.com / changeme  <- SOFORT AENDERN!"
tty_write "  LXC 120 (CasaOS Dashboard):    http://192.168.10.141"
tty_write "  LXC 170 (Deployment Hub):      http://192.168.10.170:8100"
tty_write ""
tty_write "  Proxmox Web-UI: https://${PROXMOX_IP}:8006"
tty_write "  SSH:             ssh root@${PROXMOX_IP}"
tty_write ""
log "Weitere Services: CasaOS App-Store -> http://192.168.10.141"
log ""
log "Optional -- YubiKey nachtraeglich enrollen:"
log "  bash $REPO_DIR/autoinstall/yubikey-enroll.sh"
log ""
log "Optional -- Verschluesselten ZFS Datenpool anlegen:"
log "  bash $REPO_DIR/autoinstall/zfs-pool-create.sh"

# getty auf tty1 wieder starten (Login-Prompt nach Setup)
systemctl start getty@tty1.service 2>/dev/null || true

# Fertig — nie wieder starten
touch "$DONE_FLAG"
log "✓ First-Boot abgeschlossen. Flag: $DONE_FLAG"
log_remote_dump "FRESH-INSTALL OK"
