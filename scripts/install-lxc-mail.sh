#!/bin/bash
# install-lxc-mail.sh — J.A.R.V.I.S-OS Mail-Server LXC 135
#
# Installiert Stalwart Mail Server als LXC auf Proxmox.
# Stalwart: All-in-One SMTP + IMAP + JMAP (Rust, schnell, einfach).
#
# Stellt bereit:
#   - SMTP :25 (Empfang), :587 (Submission TLS)
#   - IMAP :993 (TLS)
#   - Web-Admin :443
#
# Verwendung: bash scripts/install-lxc-mail.sh
set -e

LXC_ID=135
LXC_IP=192.168.10.135
LXC_HOSTNAME=jarvis-mail
LXC_STORAGE=${PROXMOX_STORAGE:-local-lvm}
LXC_MEMORY=512
LXC_CORES=1

TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
MAIL_DOMAIN="jarvis.local"

echo "=== J.A.R.V.I.S-OS Mail-Server LXC ${LXC_ID} (${LXC_IP}) ==="

if pct status ${LXC_ID} &>/dev/null; then
    echo "WARNUNG: LXC ${LXC_ID} existiert bereits."
    exit 1
fi

# ── LXC anlegen ─────────────────────────────────────────────────────────────
pct create ${LXC_ID} "${TEMPLATE}" \
  --hostname ${LXC_HOSTNAME} \
  --storage ${LXC_STORAGE} \
  --rootfs ${LXC_STORAGE}:8 \
  --memory ${LXC_MEMORY} \
  --cores ${LXC_CORES} \
  --net0 name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1 \
  --nameserver "1.1.1.1 8.8.8.8" \
  --unprivileged 1 \
  --features nesting=1 \
  --start 1 \
  --onboot 1

echo "Warte auf LXC-Start..."
sleep 8

# ── Stalwart Mail installieren ──────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates

  # Stalwart installieren (offizielles Install-Script)
  curl -fsSL https://get.stalw.art | sh

  # Datenverzeichnis
  mkdir -p /opt/stalwart-mail/data
"

# ── Basis-Konfiguration ────────────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  cat > /opt/stalwart-mail/etc/config.toml << EOF
[server]
hostname = \"mail.${MAIL_DOMAIN}\"

[server.listener.smtp]
bind = [\"0.0.0.0:25\"]
protocol = \"smtp\"

[server.listener.submission]
bind = [\"0.0.0.0:587\"]
protocol = \"smtp\"
tls.implicit = false

[server.listener.imaptls]
bind = [\"0.0.0.0:993\"]
protocol = \"imap\"
tls.implicit = true

[server.listener.https]
bind = [\"0.0.0.0:443\"]
protocol = \"http\"
tls.implicit = true

[storage]
data = \"rocksdb\"
blob = \"rocksdb\"
fts = \"rocksdb\"
lookup = \"rocksdb\"
directory = \"internal\"

[storage.rocksdb]
path = \"/opt/stalwart-mail/data\"

[certificate.default]
cert = \"%{file:/opt/stalwart-mail/etc/tls/cert.pem}%\"
private-key = \"%{file:/opt/stalwart-mail/etc/tls/key.pem}%\"
EOF

  # Self-Signed Zertifikat fuer lokalen Betrieb
  mkdir -p /opt/stalwart-mail/etc/tls
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout /opt/stalwart-mail/etc/tls/key.pem \
    -out /opt/stalwart-mail/etc/tls/cert.pem \
    -days 3650 \
    -subj '/CN=mail.${MAIL_DOMAIN}/O=J.A.R.V.I.S-OS' 2>/dev/null
"

# ── systemd Service ─────────────────────────────────────────────────────────
pct exec ${LXC_ID} -- bash -c "
  # Stalwart erstellt seinen eigenen Service bei der Installation.
  # Falls nicht vorhanden, manuell anlegen:
  if [ ! -f /etc/systemd/system/stalwart-mail.service ]; then
    cat > /etc/systemd/system/stalwart-mail.service << 'EOF'
[Unit]
Description=Stalwart Mail Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/stalwart-mail --config /opt/stalwart-mail/etc/config.toml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable stalwart-mail
  systemctl start stalwart-mail || echo 'HINWEIS: Service start — Logs pruefen: journalctl -u stalwart-mail'
"

echo ""
echo "=== Mail-Server LXC ${LXC_ID} erstellt ==="
echo ""
echo "  IP:        ${LXC_IP}"
echo "  SMTP:      :25 (Empfang), :587 (Submission)"
echo "  IMAP:      :993 (TLS)"
echo "  Web-Admin: https://${LXC_IP}:443"
echo "  Domain:    mail.${MAIL_DOMAIN}"
echo "  Logs:      pct exec ${LXC_ID} -- journalctl -u stalwart-mail -f"
echo ""
echo "Naechste Schritte:"
echo "  1. Web-Admin oeffnen → Admin-Account erstellen"
echo "  2. DNS-Records setzen (MX, SPF, DKIM, DMARC)"
echo "  3. Echte TLS-Zertifikate einrichten (Let's Encrypt via NPM)"
echo "  4. User-Mailboxen anlegen (oder via Authentik LDAP)"
echo ""
