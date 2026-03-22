#!/bin/bash
# yubikey-enroll.sh — [OPTIONAL] YubiKey als LUKS FIDO2 Schlüssel enrollen
#
# Dieses Skript ist OPTIONAL. Das System funktioniert vollständig mit Passphrase.
# YubiKey ermöglicht Touch-to-Unlock beim Boot anstelle der Passphrase-Eingabe.
#
# Voraussetzungen:
#   - YubiKey 5 (FIDO2 fähig) eingesteckt
#   - Proxmox läuft (LUKS bereits entsperrt)
#   - Originale LUKS-Passphrase bekannt
#
# Verwendung:
#   bash yubikey-enroll.sh             # auto-detects LUKS partition
#   bash yubikey-enroll.sh /dev/sda3   # explizite LUKS-Partition

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     [OPTIONAL] YubiKey LUKS FIDO2 Enrollment            ║"
echo "║     Passphrase bleibt als Fallback immer erhalten!       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Root-Check
[ "$(id -u)" -ne 0 ] && { echo "✗ Root erforderlich."; exit 1; }

# ── LUKS-Partition ermitteln ───────────────────────────────────────────────
LUKS_DEV="${1:-}"

if [ -z "$LUKS_DEV" ]; then
  echo "Auto-Detect LUKS-Partition..."
  LUKS_DEV=$(blkid 2>/dev/null | grep 'TYPE="crypto_LUKS"' | head -1 | cut -d: -f1)
  [ -z "$LUKS_DEV" ] && LUKS_DEV=$(lsblk -o NAME,FSTYPE | grep crypto_LUKS | head -1 | awk '{print "/dev/"$1}')
fi

if [ -z "$LUKS_DEV" ] || [ ! -b "$LUKS_DEV" ]; then
  echo "✗ Keine LUKS-Partition gefunden."
  echo "  Manuell angeben: bash yubikey-enroll.sh /dev/sda3"
  exit 1
fi

echo "LUKS-Partition: $LUKS_DEV"
echo ""

# ── YubiKey-Check ──────────────────────────────────────────────────────────
echo "YubiKey prüfen..."
if ! lsusb 2>/dev/null | grep -qi "yubico\|1050:"; then
  echo "✗ Kein YubiKey gefunden!"
  echo "  YubiKey einstecken und erneut ausführen."
  exit 1
fi

YUBIKEY_INFO=$(lsusb | grep -i "yubico\|1050:" | head -1)
echo "✓ YubiKey erkannt: $YUBIKEY_INFO"
echo ""

# ── Abhängigkeiten installieren ───────────────────────────────────────────
echo "Installiere FIDO2-Abhängigkeiten..."
apt-get install -y -qq libfido2-1 libfido2-dev fido2-tools 2>/dev/null || true

# Prüfe ob systemd-cryptenroll FIDO2 unterstützt
if ! systemd-cryptenroll --help 2>&1 | grep -q "fido2"; then
  echo "✗ systemd-cryptenroll unterstützt kein FIDO2 auf diesem System."
  echo "  Mindestens systemd 248 + libfido2 erforderlich."
  exit 1
fi

# ── FIDO2 Device-Test ─────────────────────────────────────────────────────
echo "FIDO2-Gerät testen..."
if ! fido2-token -L 2>/dev/null | grep -q "/dev/"; then
  echo "✗ YubiKey als FIDO2-Gerät nicht erkannt."
  echo "  Prüfe: fido2-token -L"
  exit 1
fi
FIDO2_DEV=$(fido2-token -L | head -1 | awk '{print $1}' | tr -d ':')
echo "✓ FIDO2 Gerät: $FIDO2_DEV"
echo ""

# ── Bestätigung ───────────────────────────────────────────────────────────
echo "WARNUNG: Existing LUKS passphrase wird benötigt um YubiKey zu enrollen."
echo "         Die Passphrase bleibt nach Enrollment als Fallback erhalten!"
echo ""
read -rp "Fortfahren? [j/N] " CONFIRM
[[ ! "$CONFIRM" =~ ^[jJyY]$ ]] && { echo "Abgebrochen."; exit 0; }
echo ""

# ── YubiKey FIDO2 enrollen ─────────────────────────────────────────────────
echo "Enrolle YubiKey FIDO2 in LUKS ($LUKS_DEV)..."
echo "(Bitte den YubiKey berühren wenn aufgefordert)"
echo ""

systemd-cryptenroll \
  --fido2-device=auto \
  --fido2-with-client-pin=no \
  --fido2-with-user-presence=yes \
  "$LUKS_DEV"

echo ""
echo "✓ YubiKey enrollt!"

# ── crypttab aktualisieren ────────────────────────────────────────────────
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV")
CRYPTTAB_FILE="/etc/crypttab"

if grep -q "$LUKS_UUID" "$CRYPTTAB_FILE" 2>/dev/null; then
  # Bestehenden Eintrag aktualisieren: fido2-device=auto hinzufügen
  if ! grep "$LUKS_UUID" "$CRYPTTAB_FILE" | grep -q "fido2-device"; then
    sed -i "/$LUKS_UUID/ s/$/ fido2-device=auto,discard/" "$CRYPTTAB_FILE" 2>/dev/null || \
    sed -i "/$LUKS_UUID/ s/none$/- fido2-device=auto,discard/" "$CRYPTTAB_FILE"
    echo "✓ /etc/crypttab aktualisiert"
  else
    echo "✓ /etc/crypttab bereits konfiguriert"
  fi
fi

# ── initramfs neu erstellen ────────────────────────────────────────────────
echo ""
echo "initramfs mit FIDO2-Unterstützung neu erstellen..."
update-initramfs -u -k all
echo "✓ initramfs aktualisiert"

# ── LUKS-Slots anzeigen ───────────────────────────────────────────────────
echo ""
echo "Aktuelle LUKS-Schlüssel-Slots:"
cryptsetup luksDump "$LUKS_DEV" | grep -A2 "Keyslots\|FIDO2\|systemd-fido2"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Enrollment abgeschlossen!            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Nächster Boot:"
echo "    → YubiKey einstecken + berühren wenn aufgefordert"
echo "    → LUKS öffnet sich automatisch"
echo ""
echo "  Ohne YubiKey (Fallback):"
echo "    → Passphrase eingeben (weiterhin gültig)"
echo ""
echo "  Recovery-Passphrase ändern/hinzufügen:"
echo "    systemd-cryptenroll --password $LUKS_DEV"
