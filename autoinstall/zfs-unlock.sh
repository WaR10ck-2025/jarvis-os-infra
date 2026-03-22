#!/bin/bash
# zfs-unlock.sh — ZFS verschlüsselte Pools entsperren
#
# Wird beim Boot automatisch von zfs-unlock.service aufgerufen.
# Entsperrt alle verschlüsselten ZFS Pools die noch nicht gemountet sind.
#
# Modus A (Standard — kein YubiKey):
#   Interaktiver Passphrase-Prompt für jeden Pool
#
# Modus B (Optional — YubiKey mit HMAC-SHA1):
#   Schlüssel wird aus YubiKey Challenge-Response abgeleitet (automatisch)
#   Voraussetzung: YubiKey mit HMAC-Slot 2 konfiguriert + yubikey-manager installiert
#
# Manuell ausführen: bash /usr/local/bin/zfs-unlock.sh

POOLS_UNLOCKED=0
POOLS_FAILED=0

# Prüfe ob ZFS überhaupt verfügbar ist
if ! command -v zpool &>/dev/null; then
  exit 0   # Kein ZFS installiert — nichts zu tun
fi

# Alle ZFS Pools durchgehen
while IFS= read -r POOL; do
  [ -z "$POOL" ] && continue

  # Nur verschlüsselte Pools die noch nicht entsperrt sind
  ENCRYPTION=$(zfs get -H encryption "$POOL" 2>/dev/null | awk '{print $3}')
  [ "$ENCRYPTION" = "off" ] || [ -z "$ENCRYPTION" ] && continue

  KEYSTATUS=$(zfs get -H keystatus "$POOL" 2>/dev/null | awk '{print $3}')
  [ "$KEYSTATUS" = "available" ] && continue  # Bereits entsperrt

  echo "Entsperre ZFS Pool: $POOL (Verschlüsselung: $ENCRYPTION)"

  # ── Modus B: YubiKey HMAC (optional) ──────────────────────────────────
  YUBIKEY_USED=false
  if command -v ykchalresp &>/dev/null 2>/dev/null; then
    # YubiKey eingesteckt?
    if ykinfo -q 2>/dev/null | grep -q "serial"; then
      echo "  YubiKey erkannt — verwende HMAC-SHA1..."
      CHALLENGE="openclaw-zfs-${POOL}"
      ZFS_KEY=$(echo "$CHALLENGE" | ykchalresp -2 -H 2>/dev/null | tr -d '\n')
      if [ -n "$ZFS_KEY" ]; then
        if echo "$ZFS_KEY" | zfs load-key "$POOL" 2>/dev/null; then
          echo "  ✓ Pool '$POOL' via YubiKey entsperrt"
          YUBIKEY_USED=true
        else
          echo "  ✗ YubiKey-Key falsch — versuche Passphrase..."
        fi
      fi
    fi
  fi

  # ── Modus A: Passphrase (Standard) ────────────────────────────────────
  if ! $YUBIKEY_USED; then
    echo "  Passphrase für Pool '$POOL' eingeben:"
    if zfs load-key "$POOL"; then
      echo "  ✓ Pool '$POOL' via Passphrase entsperrt"
    else
      echo "  ✗ Pool '$POOL' konnte nicht entsperrt werden"
      POOLS_FAILED=$((POOLS_FAILED + 1))
      continue
    fi
  fi

  # Pool mounten
  zfs mount -a 2>/dev/null || true
  POOLS_UNLOCKED=$((POOLS_UNLOCKED + 1))

done < <(zpool list -H -o name 2>/dev/null)

# Status
if [ "$POOLS_UNLOCKED" -eq 0 ] && [ "$POOLS_FAILED" -eq 0 ]; then
  echo "Keine verschlüsselten ZFS Pools gefunden."
else
  echo "ZFS Unlock: $POOLS_UNLOCKED entsperrt, $POOLS_FAILED fehlgeschlagen"
fi

exit "$POOLS_FAILED"
