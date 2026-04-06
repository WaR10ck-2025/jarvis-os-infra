#!/bin/bash
# setup-network-isolation.sh — Netzwerk-Isolation fuer J.A.R.V.I.S-OS User-VMs
#
# Erstellt die Basis-iptables-Regeln auf dem Proxmox-Host.
# Per-User Bridges + Firewall werden vom Admin-Service dynamisch verwaltet
# (network_manager.py). Dieses Skript setzt nur die globalen Regeln.
#
# Ausfuehren auf dem Proxmox-Host (als root).
# Verwendung: bash scripts/setup-network-isolation.sh
set -e

echo "=== J.A.R.V.I.S-OS Netzwerk-Isolation Setup ==="

# ── Globale Variablen ───────────────────────────────────────────────────────
MGMT_NET="192.168.10.0/24"
PROXMOX_HOST="192.168.10.147"

# Erlaubte Admin-Services fuer User-VMs
HEADSCALE_IP="192.168.10.115"
HEADSCALE_PORT=8080
AUTHENTIK_IP="192.168.10.125"
AUTHENTIK_PORT=9000
ADMIN_SERVICE_IP="192.168.10.160"
ADMIN_SERVICE_PORT=8300
NPM_IP="192.168.10.140"

# ── IP-Forwarding aktivieren ────────────────────────────────────────────────
echo "[1/4] IP-Forwarding aktivieren..."
sysctl -w net.ipv4.ip_forward=1

# Persistent machen
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# ── Globale FORWARD-Chains ──────────────────────────────────────────────────
echo "[2/4] Globale iptables-Chains erstellen..."

# Chain fuer User-VM-Traffic (wird von network_manager.py befuellt)
iptables -N JARVIS-FORWARD 2>/dev/null || true
iptables -t nat -N JARVIS-NAT-PRE 2>/dev/null || true
iptables -t nat -N JARVIS-NAT-POST 2>/dev/null || true

# In Haupt-Chains einhaengen (idempotent)
iptables -C FORWARD -j JARVIS-FORWARD 2>/dev/null || \
    iptables -I FORWARD 1 -j JARVIS-FORWARD

iptables -t nat -C PREROUTING -j JARVIS-NAT-PRE 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -j JARVIS-NAT-PRE

iptables -t nat -C POSTROUTING -j JARVIS-NAT-POST 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 -j JARVIS-NAT-POST

# ── Globale Regeln (gelten fuer ALLE User-VMs) ─────────────────────────────
echo "[3/4] Globale Firewall-Regeln..."

# DNS erlauben (alle User-VMs → Gateway DNS)
iptables -C JARVIS-FORWARD -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -A JARVIS-FORWARD -p udp --dport 53 -j ACCEPT
iptables -C JARVIS-FORWARD -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -A JARVIS-FORWARD -p tcp --dport 53 -j ACCEPT

# Established/Related erlauben (Antwort-Traffic)
iptables -C JARVIS-FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A JARVIS-FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── INPUT-Regeln (Proxmox-Host vor User-VMs schuetzen) ────────────────────
# Traffic von User-VMs zum Host selbst geht durch INPUT, nicht FORWARD!
# Per-User INPUT-Regeln werden vom Admin-Service verwaltet (network_manager.py).
# Hier: Dokumentation der Logik. Jede User-Bridge (vmbrN) braucht:
#   1. ACCEPT: DNS (udp/tcp 53), DHCP (udp 67:68), ICMP, ESTABLISHED
#   2. DROP: alles andere (verhindert Zugriff auf Proxmox WebUI, SSH, etc.)

# ── Persistent machen ──────────────────────────────────────────────────────
echo "[4/4] Regeln persistent machen..."
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
elif command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
    iptables-save > /etc/iptables.rules 2>/dev/null || true
fi

echo ""
echo "=== Netzwerk-Isolation Setup abgeschlossen ==="
echo ""
echo "Globale Chains erstellt:"
echo "  JARVIS-FORWARD   — Forward-Regeln fuer User-VM-Traffic"
echo "  JARVIS-NAT-PRE   — DNAT (Management-IP → VM-IP)"
echo "  JARVIS-NAT-POST  — SNAT/Masquerade (VM → Internet)"
echo ""
echo "Per-User Regeln werden dynamisch vom Admin-Service verwaltet"
echo "(network_manager.py, bei User-Provisioning/Deprovision)."
echo ""
echo "Aktuelle Regeln pruefen:"
echo "  iptables -L JARVIS-FORWARD -n -v"
echo "  iptables -t nat -L JARVIS-NAT-PRE -n -v"
echo "  iptables -t nat -L JARVIS-NAT-POST -n -v"
echo ""
echo "HINWEIS: iptables-persistent installieren fuer Boot-Persistenz:"
echo "  apt-get install -y iptables-persistent netfilter-persistent"
echo ""
