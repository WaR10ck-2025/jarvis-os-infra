#!/bin/bash
# zfs-pool-create.sh — Verschlüsselten ZFS Datenpool interaktiv anlegen
#
# Erstellt einen neuen ZFS Pool mit nativer AES-256-GCM Verschlüsselung.
# Schlüssel: Passphrase (Standard) oder YubiKey HMAC-SHA1 (optional).
# Pool wird automatisch als Proxmox Storage registriert.
#
# Verwendung:
#   bash zfs-pool-create.sh                    # interaktiv
#   bash zfs-pool-create.sh single /dev/sdb    # schnell (single disk)
#   bash zfs-pool-create.sh mirror /dev/sdb /dev/sdc
#   bash zfs-pool-create.sh raidz  /dev/sdb /dev/sdc /dev/sdd
#
# Layouts:
#   single  — Keine Redundanz, volle Kapazität (1 Disk)
#   mirror  — Spiegel (2+ Disks, 50% Kapazität)
#   raidz   — RAID5-ähnlich (3+ Disks, N-1 Kapazität)
#   raidz2  — RAID6-ähnlich (4+ Disks, N-2 Kapazität)

set -e

# Root-Check
[ "$(id -u)" -ne 0 ] && { echo "✗ Root erforderlich."; exit 1; }

LAYOUT="${1:-}"
shift 2>/dev/null || true
DISKS=("$@")

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         ZFS Datenpool anlegen (verschlüsselt)           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── ZFS prüfen ────────────────────────────────────────────────────────────
if ! command -v zpool &>/dev/null; then
  echo "ZFS installieren..."
  apt-get install -y -qq zfsutils-linux
fi

# ── Verfügbare Disks anzeigen ──────────────────────────────────────────────
echo "Verfügbare Disks:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | grep -v "^loop\|^sr" | head -30
echo ""

# ── Interaktive Eingabe wenn Parameter fehlen ──────────────────────────────
if [ -z "$LAYOUT" ]; then
  echo "RAID-Layout wählen:"
  echo "  1) single  — Keine Redundanz (1 Disk)"
  echo "  2) mirror  — Spiegel (2+ Disks)"
  echo "  3) raidz   — RAID5-ähnlich (3+ Disks, empfohlen)"
  echo "  4) raidz2  — RAID6-ähnlich (4+ Disks)"
  read -rp "Auswahl [1-4]: " CHOICE
  case "$CHOICE" in
    1) LAYOUT="single" ;;
    2) LAYOUT="mirror" ;;
    3) LAYOUT="raidz"  ;;
    4) LAYOUT="raidz2" ;;
    *) echo "Ungültige Auswahl"; exit 1 ;;
  esac
fi

if [ ${#DISKS[@]} -eq 0 ]; then
  echo ""
  echo "Disks eingeben (z.B. /dev/sdb oder /dev/disk/by-id/...):"
  echo "Leer lassen zum Beenden der Eingabe."
  while true; do
    read -rp "  Disk: " DISK
    [ -z "$DISK" ] && break
    [ ! -b "$DISK" ] && echo "  ✗ $DISK nicht gefunden" && continue
    DISKS+=("$DISK")
    echo "  ✓ $DISK hinzugefügt"
  done
fi

[ ${#DISKS[@]} -eq 0 ] && { echo "✗ Keine Disks angegeben."; exit 1; }

# ── Pool-Name ─────────────────────────────────────────────────────────────
read -rp "Pool-Name [data]: " POOL_NAME
POOL_NAME="${POOL_NAME:-data}"

# Bereits vorhanden?
if zpool list "$POOL_NAME" &>/dev/null; then
  echo "✗ Pool '$POOL_NAME' existiert bereits."
  exit 1
fi

# ── Schlüssel-Modus wählen ────────────────────────────────────────────────
echo ""
echo "Verschlüsselungs-Schlüssel:"
echo "  1) Passphrase (Standard — empfohlen)"
if command -v ykchalresp &>/dev/null && ykinfo -q 2>/dev/null | grep -q "serial"; then
  echo "  2) YubiKey HMAC-SHA1 (YubiKey erkannt!)"
  YK_AVAILABLE=true
else
  echo "  2) YubiKey HMAC-SHA1 (YubiKey nicht erkannt)"
  YK_AVAILABLE=false
fi
read -rp "Auswahl [1]: " KEY_MODE
KEY_MODE="${KEY_MODE:-1}"

ZFS_KEY_OPTS=""
ZFS_KEY=""

if [ "$KEY_MODE" = "2" ] && $YK_AVAILABLE; then
  echo ""
  echo "YubiKey HMAC-SHA1 Slot 2 wird für Schlüssel-Ableitung genutzt."
  echo "Challenge: openclaw-zfs-${POOL_NAME}"
  read -rp "YubiKey berühren zum Fortfahren..." _DUMMY
  ZFS_KEY=$(echo "openclaw-zfs-${POOL_NAME}" | ykchalresp -2 -H 2>/dev/null | tr -d '\n')
  if [ -z "$ZFS_KEY" ]; then
    echo "✗ YubiKey HMAC fehlgeschlagen — verwende Passphrase."
    KEY_MODE=1
  else
    echo "✓ Schlüssel abgeleitet"
    ZFS_KEY_OPTS="-O keyformat=hex -O keylocation=prompt"
  fi
fi

if [ "$KEY_MODE" = "1" ] || [ -z "$ZFS_KEY" ]; then
  ZFS_KEY_OPTS="-O keyformat=passphrase -O keylocation=prompt"
fi

# ── Zusammenfassung ───────────────────────────────────────────────────────
echo ""
echo "Pool-Konfiguration:"
echo "  Name:        $POOL_NAME"
echo "  Layout:      $LAYOUT"
echo "  Disks:       ${DISKS[*]}"
echo "  Schlüssel:   $([ "$KEY_MODE" = "2" ] && echo 'YubiKey HMAC' || echo 'Passphrase')"
echo "  Verschl.:    AES-256-GCM (ZFS nativ)"
echo ""
read -rp "ZFS Pool anlegen? [j/N] " CONFIRM
[[ ! "$CONFIRM" =~ ^[jJyY]$ ]] && { echo "Abgebrochen."; exit 0; }

# ── ZFS Pool erstellen ─────────────────────────────────────────────────────
echo ""
echo "Erstelle ZFS Pool '$POOL_NAME'..."

# VDEV-String aufbauen
VDEV=""
case "$LAYOUT" in
  single) VDEV="${DISKS[*]}" ;;
  mirror) VDEV="mirror ${DISKS[*]}" ;;
  raidz)  VDEV="raidz ${DISKS[*]}" ;;
  raidz2) VDEV="raidz2 ${DISKS[*]}" ;;
esac

if [ "$KEY_MODE" = "2" ] && [ -n "$ZFS_KEY" ]; then
  # YubiKey: Schlüssel über stdin übergeben
  echo "$ZFS_KEY" | zpool create \
    -O encryption=aes-256-gcm \
    $ZFS_KEY_OPTS \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    "$POOL_NAME" $VDEV
else
  # Passphrase: interaktiv
  zpool create \
    -O encryption=aes-256-gcm \
    $ZFS_KEY_OPTS \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    "$POOL_NAME" $VDEV
fi

echo "✓ ZFS Pool '$POOL_NAME' erstellt"

# ── Standard-Datasets anlegen ─────────────────────────────────────────────
echo "Standard-Datasets anlegen..."
zfs create "$POOL_NAME/backups" 2>/dev/null || true
zfs create "$POOL_NAME/data"    2>/dev/null || true

# ── Als Proxmox Storage registrieren ──────────────────────────────────────
echo ""
read -rp "Pool als Proxmox Storage registrieren? [J/n] " REG_CONFIRM
if [[ ! "$REG_CONFIRM" =~ ^[nN]$ ]]; then
  pvesm add zfspool "${POOL_NAME}-zfs" --pool "$POOL_NAME" --sparse 1 2>/dev/null || \
    echo "  (Storage-Registrierung manuell: pvesm add zfspool ${POOL_NAME}-zfs --pool $POOL_NAME)"

  pvesm add dir "${POOL_NAME}-backup" \
    --path "/${POOL_NAME}/backups" \
    --content backup,iso,vztmpl 2>/dev/null || \
    echo "  (Backup-Storage manuell: pvesm add dir ${POOL_NAME}-backup --path /${POOL_NAME}/backups)"

  echo "✓ Proxmox Storage registriert"
fi

# ── Abschluss ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Pool erstellt!                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
zpool status "$POOL_NAME"
echo ""
echo "  ZFS Pool:      $POOL_NAME"
echo "  Verfügbar:     $(zfs get -H available $POOL_NAME | awk '{print $3}')"
echo "  Verschlüsselt: $(zfs get -H encryption $POOL_NAME | awk '{print $3}')"
echo ""
echo "  Pool wird beim nächsten Boot automatisch entsperrt:"
echo "  → Passphrase-Prompt ODER YubiKey (via zfs-unlock.service)"
echo ""
echo "  Manuell entsperren: zfs load-key $POOL_NAME && zfs mount -a"
