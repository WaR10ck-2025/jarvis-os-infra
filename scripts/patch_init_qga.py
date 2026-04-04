#!/usr/bin/env python3
"""Patch UGOS initrd init script.

v3: Fix overlay mount (ext4 without prjquota instead of broken tmpfs),
    enable qemu-guest-agent, network, serial console.
"""
import sys

init_path = sys.argv[1] if len(sys.argv) > 1 else "init"

with open(init_path, "r") as f:
    content = f.read()

# Remove old OpenClaw patches if present
if "OpenClaw Patch" in content:
    lines = content.split("\n")
    new_lines = []
    skip = False
    for line in lines:
        if "=== OpenClaw Patch" in line and "===" in line and "End" not in line:
            skip = True
            continue
        if "=== End OpenClaw Patch ===" in line:
            skip = False
            continue
        if not skip:
            new_lines.append(line)
    content = "\n".join(new_lines)
    print("Removed old patch")

# ── Patch 1: Fix overlay mount (replace tmpfs with ext4 without prjquota) ──
# Find the mount_overlayfs function and replace tmpfs line with ext4
if "mount -t tmpfs" in content and "tmpfs /overlay" in content:
    content = content.replace(
        "mount -t tmpfs -o size=2G tmpfs /overlay",
        "mount -t ext4 -o rw,noatime ${BLK_DEV}7 /overlay"
    )
    print("Fixed overlay mount: tmpfs -> ext4 (without prjquota)")
elif "prjquota" in content:
    # Original UGOS mount with prjquota - replace with simple ext4
    import re
    content = re.sub(
        r'mount -t ext4 -o\s+rw,noatime,quota,usrquota,grpquota,prjquota,stripe=256\s+\$\{BLK_DEV\}7\s+/overlay',
        'mount -t ext4 -o rw,noatime ${BLK_DEV}7 /overlay',
        content
    )
    print("Fixed overlay mount: removed prjquota/stripe options")
else:
    print("WARNING: overlay mount line not found - no overlay fix applied")

# ── Patch 2: Services (after mount --move /rootfs /root/rootfs) ──
lines = content.split("\n")
idx = None
for i, line in enumerate(lines):
    if "mount --move /rootfs" in line and "/root/rootfs" in line:
        idx = i
        break

if idx is None:
    print("ERROR: injection point 'mount --move /rootfs /root/rootfs' not found")
    sys.exit(1)

patch = r"""
# === OpenClaw Patch v3: qemu-guest-agent + network + serial getty ===

# 1) Enable qemu-guest-agent via systemd
mkdir -p /root/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/qemu-guest-agent.service \
  /root/etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service 2>/dev/null

# 2) Serial console getty on ttyS0
mkdir -p /root/etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  /root/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service 2>/dev/null

# 3) Network + qemu-ga startup via rc.local
cat > /root/etc/rc.local << 'RCEOF'
#!/bin/sh
# OpenClaw: ensure network + qemu-guest-agent on every boot

# Find first en* interface
IFACE=$(ip -o link show | awk -F': ' '/en[a-z]/{print $2; exit}')
if [ -n "$IFACE" ]; then
  ip link set "$IFACE" up
  if command -v dhclient >/dev/null 2>&1; then
    dhclient -1 -timeout 10 "$IFACE" 2>/dev/null &
  elif command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i "$IFACE" -t 5 -n 2>/dev/null &
  else
    ip addr add 192.168.10.250/24 dev "$IFACE" 2>/dev/null
    ip route add default via 192.168.10.1 2>/dev/null
  fi
fi

# Start qemu-guest-agent if not running
if [ -x /usr/sbin/qemu-ga ] && ! pidof qemu-ga >/dev/null 2>&1; then
  /usr/sbin/qemu-ga -d 2>/dev/null
fi

exit 0
RCEOF
chmod 755 /root/etc/rc.local

# 4) Enable rc-local.service
ln -sf /usr/lib/systemd/system/rc-local.service \
  /root/etc/systemd/system/multi-user.target.wants/rc-local.service 2>/dev/null

# === End OpenClaw Patch ==="""

lines.insert(idx + 1, patch)
content = "\n".join(lines)

with open(init_path, "w") as f:
    f.write(content)

print(f"Patch v3 injected after line {idx + 1} (mount --move /rootfs)")
