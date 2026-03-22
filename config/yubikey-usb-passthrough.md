# YubiKey USB-Passthrough in LXC 108

YubiKey-Geräte präsentieren sich als HID-Gerät (`/dev/hidraw*`), nicht als USB-Massenspeicher.
LXC-Container brauchen dafür spezifische cgroup-Regeln und bind-mounts.

## YubiKey USB-IDs

| Modell | VendorID | ProductID | HID Name |
|---|---|---|---|
| YubiKey 5 NFC | 1050 | 0407 | Yubico YubiKey OTP+FIDO+CCID |
| YubiKey 5C | 1050 | 0407 | Yubico YubiKey OTP+FIDO+CCID |
| YubiKey 5 Nano | 1050 | 0407 | Yubico YubiKey OTP+FIDO+CCID |

## Schritt 1 — YubiKey auf Host erkennen

```bash
# Auf Proxmox-Host, YubiKey einstecken, dann:
lsusb | grep Yubico
# Output: Bus 001 Device 005: ID 1050:0407 Yubico.com Yubikey 4/5 OTP+U2F+CCID

# HID Device-Node ermitteln
ls -la /dev/hidraw*
# /dev/hidraw0 → c 239:0

# Major:Minor prüfen
stat -c "%t:%T" /dev/hidraw0
# Ausgabe z.B.: ef:0  (hex → decimal: 239:0)
```

## Schritt 2 — LXC 108 Konfiguration auf Proxmox-Host

```bash
# Konfigurationsdatei öffnen
nano /etc/pve/lxc/108.conf
```

Folgende Zeilen hinzufügen (am Ende der Datei):

```ini
# YubiKey HID Passthrough
lxc.cgroup2.devices.allow: c 239:* rwm
lxc.mount.entry: /dev/hidraw0 dev/hidraw0 none bind,optional,create=file 0 0
```

> **Hinweis:** `/dev/hidraw0` muss die korrekte Device-Node sein.
> Falls mehrere HID-Geräte vorhanden: `udevadm info /dev/hidraw0 | grep ID_VENDOR_ID` prüfen.

## Schritt 3 — Udev-Regel für persistente Benennung (Proxmox Host)

```bash
cat > /etc/udev/rules.d/99-yubikey.rules << 'EOF'
# YubiKey — persistente Benennung als /dev/yubikey
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", ATTRS{idProduct}=="0407", \
  SYMLINK+="yubikey", MODE="0660", GROUP="plugdev"
EOF

udevadm control --reload-rules
udevadm trigger
```

Dann in `/etc/pve/lxc/108.conf` besser:

```ini
lxc.mount.entry: /dev/yubikey dev/yubikey none bind,optional,create=file 0 0
```

## Schritt 4 — Im LXC 108 verifizieren

```bash
pct exec 108 -- bash -c "
  ls -la /dev/hidraw* /dev/yubikey 2>/dev/null
  python3 -c \"
import hid
devices = hid.enumerate(0x1050, 0x0407)
print('YubiKey gefunden:', len(devices), 'Interface(s)')
for d in devices:
    print(' -', d['path'], d['usage_page'])
\"
"
```

## Schritt 5 — FIDO2/WebAuthn im LXC testen

```bash
pct exec 108 -- bash -c "
  pip install fido2 --quiet
  python3 -c \"
from fido2.hid import CtapHidDevice
devs = list(CtapHidDevice.list_devices())
print('CTAP2-Geräte:', len(devs))
for d in devs:
    print(' -', d.descriptor)
\"
"
```

## Troubleshooting

| Problem | Lösung |
|---|---|
| `/dev/hidraw*` fehlt im LXC | cgroup2 + mount.entry in 108.conf prüfen, LXC neu starten |
| `Permission denied` | `MODE="0660"` in udev-Regel, User zur `plugdev`-Gruppe |
| Falsches Gerät | `udevadm info /dev/hidrawX \| grep ID_VENDOR` zum Identifizieren |
| Nach Plug-/Unplug: neues hidraw | Udev-Symlink `/dev/yubikey` statt fest `/dev/hidraw0` nutzen |

## Sicherheitshinweis

LXC 108 benötigt `privileged: false` kann aber die cgroup-Regel nutzen (unprivileged LXC reicht für HID).
KEIN `privileged: true` nötig — nur `lxc.cgroup2.devices.allow`.
