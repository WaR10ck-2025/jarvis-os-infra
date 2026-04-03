#!/usr/bin/env python3
"""Patch UGOS initrd init script to enable qemu-guest-agent, network and serial console.

v2: Uses rc.local approach + direct systemd service enablement.
    Creates /etc/rc.local in the overlay upper dir which runs after systemd init.
    Also enables qemu-guest-agent and serial-getty via systemd symlinks.
"""
import sys

init_path = sys.argv[1] if len(sys.argv) > 1 else "init"

with open(init_path, "r") as f:
    content = f.read()

# Remove old patch if present
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

# Find injection point: after "mount --move /rootfs  /root/rootfs"
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
# === OpenClaw Patch v2: qemu-guest-agent + network + serial getty ===

# 1) Enable qemu-guest-agent via systemd (udev-triggered + explicit wants)
mkdir -p /root/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/qemu-guest-agent.service \
  /root/etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service 2>/dev/null

# 2) Serial console getty on ttyS0
mkdir -p /root/etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  /root/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service 2>/dev/null

# 3) Network + qemu-ga startup via rc.local (runs after all systemd services)
cat > /root/etc/rc.local << 'RCEOF'
#!/bin/sh
# OpenClaw: ensure network + qemu-guest-agent on every boot

# Find first en* interface
IFACE=$(ip -o link show | awk -F': ' '/en[a-z]/{print $2; exit}')
if [ -n "$IFACE" ]; then
  ip link set "$IFACE" up
  # Try DHCP first (wait max 10s)
  if command -v dhclient >/dev/null 2>&1; then
    dhclient -1 -timeout 10 "$IFACE" 2>/dev/null &
  elif command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i "$IFACE" -t 5 -n 2>/dev/null &
  else
    # Fallback: static IP
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

print(f"Patch v2 injected after line {idx + 1} (mount --move /rootfs)")
