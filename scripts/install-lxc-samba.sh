#!/bin/bash
# install-lxc-samba.sh — J.A.R.V.I.S-OS Samba File-Server LXC 130
#
# Zentraler Datei-Server fuer alle User-VMs.
# Jeder User bekommt ein eigenes Share (via ZFS-Dataset).
# Admin-Service erstellt Shares dynamisch bei User-Provisioning.
#
# Verwendung: bash scripts/install-lxc-samba.sh
set -e

LXC_ID=130
LXC_IP=192.168.10.130
LXC_HOSTNAME=jarvis-samba
LXC_STORAGE=${PROXMOX_STORAGE:-local-lvm}
LXC_MEMORY=256
LXC_CORES=1

TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

echo "=== J.A.R.V.I.S-OS Samba File-Server LXC ${LXC_ID} (${LXC_IP}) ==="

if pct status ${LXC_ID} &>/dev/null; then
    echo "WARNUNG: LXC ${LXC_ID} existiert bereits."
    exit 1
fi

# ── LXC anlegen ─────────────────────────────────────────────────────────────
pct create ${LXC_ID} "${TEMPLATE}" \
  --hostname ${LXC_HOSTNAME} \
  --storage ${LXC_STORAGE} \
  --rootfs ${LXC_STORAGE}:4 \
  --memory ${LXC_MEMORY} \
  --cores ${LXC_CORES} \
  --net0 name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1 \
  --nameserver "1.1.1.1 8.8.8.8" \
  --unprivileged 0 \
  --features nesting=1 \
  --start 1 \
  --onboot 1

# Privileged LXC fuer ZFS-Mount-Zugriff (Bind-Mounts vom Host)
# Alternativ: NFS statt Bind-Mount

echo "Warte auf LXC-Start..."
sleep 8

# ── Samba installieren ──────────────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  apt-get update -qq
  apt-get install -y -qq samba samba-common-bin

  systemctl enable smbd nmbd
"

# ── Samba Basis-Konfiguration ───────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  cat > /etc/samba/smb.conf << 'EOF'
[global]
   workgroup = JARVIS
   server string = J.A.R.V.I.S-OS File Server
   server role = standalone server
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   security = user
   map to guest = never

   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   read raw = yes
   write raw = yes
   use sendfile = yes
   aio read size = 16384
   aio write size = 16384

   # Sicherheit
   server min protocol = SMB3
   smb encrypt = desired

# Gemeinsamer Share (alle User)
[shared]
   comment = Gemeinsame Dateien
   path = /srv/shared
   browseable = yes
   read only = no
   valid users = @jarvis-users
   create mask = 0660
   directory mask = 0770

# Template fuer User-Shares (Admin-Service kopiert diesen Block pro User)
# [alice]
#    comment = Alice Home
#    path = /srv/users/alice
#    browseable = yes
#    read only = no
#    valid users = alice
#    create mask = 0600
#    directory mask = 0700
EOF

  # Verzeichnisse anlegen
  mkdir -p /srv/shared /srv/users
  chmod 770 /srv/shared

  # Samba-Gruppe fuer User
  groupadd -f jarvis-users

  systemctl restart smbd
"

echo ""
echo "=== Samba File-Server LXC ${LXC_ID} erstellt ==="
echo ""
echo "  IP:       ${LXC_IP}:445"
echo "  Config:   pct exec ${LXC_ID} -- nano /etc/samba/smb.conf"
echo "  Status:   pct exec ${LXC_ID} -- smbstatus"
echo ""
echo "User hinzufuegen (Admin-Service macht das automatisch):"
echo "  pct exec ${LXC_ID} -- useradd -M -s /sbin/nologin alice"
echo "  pct exec ${LXC_ID} -- smbpasswd -a alice"
echo "  pct exec ${LXC_ID} -- usermod -aG jarvis-users alice"
echo ""
echo "HINWEIS: ZFS-Datasets vom Host als Bind-Mount einhaengen:"
echo "  pct set ${LXC_ID} --mp0 /tank/users,mp=/srv/users"
echo ""
