# IP-Plan — Proxmox Deployment

## Netzwerk: 192.168.10.0/24

| LXC/VM | ID | Hostname | IP | Dienst | Ports |
|---|---|---|---|---|---|
| Proxmox Host | — | proxmox | 192.168.10.147 | Proxmox VE 8.x | :8006 (Web-UI) |
| LXC 10 | 10 | reverse-proxy | 192.168.10.140 | Nginx Proxy Manager | :80 :443 :81 (Admin) |
| LXC 20 | 20 | casaos-dashboard | 192.168.10.141 | CasaOS Dashboard | :80 |
| LXC 101 | 101 | setup-repair-agent | 192.168.10.101 | Python FastAPI | :8007 |
| LXC 102 | 102 | pionex-mcp-server | 192.168.10.102 | Python FastAPI | :8000 |
| LXC 103 | 103 | voice-assistant | 192.168.10.103 | Python API | :8000 |
| LXC 104 | 104 | n8n | 192.168.10.104 | Node.js | :5678 |
| LXC 105 | 105 | sv-niederklein | 192.168.10.105 | Nginx + React | :3001 |
| LXC 106 | 106 | schuetzenverein | 192.168.10.106 | Nginx + React | :3002 |
| LXC 107 | 107 | deployment-hub | 192.168.10.107 | Node.js | :8100 |
| LXC 108 | 108 | yubikey-auth | 192.168.10.108 | Python + USB | :8110 |
| LXC 200 | 200 | wine-desktop | 192.168.10.200 | Wine + VNC | :5900 :8090 |
| LXC 201 | 201 | wine-api | 192.168.10.201 | FastAPI | :4000 |
| LXC 202 | 202 | wine-ui | 192.168.10.202 | Nginx React | :3000 |
| LXC 210 | 210 | usbipd | 192.168.10.210 | usbipd nativ | :3240 |
| VM 100 | 100 | windows-obd2 | 192.168.10.220 | Windows 10 KVM | :8006 (noVNC) :3389 (RDP) |

## Externe Geräte (nicht auf Proxmox)

| Gerät | IP | Beschreibung |
|---|---|---|
| GL.iNet Router | 192.168.10.194 | WiFi-Bridge, WLAN-IP (NanoPi) |
| NanoPi R5C (ETH) | 192.168.10.193 | Ethernet-IP NanoPi |
| WiCAN Pro | 192.168.10.200 | OBD2 WiFi-Adapter (ESP32-C3, SocketCAN TCP :3333) |
| Vgate iCar 2 | 192.168.10.201 | OBD2 WiFi-Adapter (ELM327 TCP :35000) |

> **Hinweis:** WiCAN Pro und Vgate haben die gleichen letzten Oktette wie LXC 200/201.
> Dies ist **kein Konflikt** — die Adapter-IPs sind im DHCP-Reservierungs-Bereich der Router,
> während LXC 200/201 feste Proxmox-Netzwerk-IPs haben. Bei Umbiguität Subnetz-Dokument prüfen.

## Gateway & DNS

| | Wert |
|---|---|
| Gateway | 192.168.10.1 |
| DNS | 192.168.10.1 (Router-DNS → NextDNS) |
| Subnet | /24 (255.255.255.0) |
| Bridge | vmbr0 (Proxmox Standard-Bridge) |

## URL-Übersicht (lokales Netz)

```
Proxmox Web-UI:       https://192.168.10.147:8006
Nginx Proxy Manager:  http://192.168.10.140:81
CasaOS Dashboard:     http://192.168.10.141
Wine Manager UI:      http://192.168.10.202:3000
Wine Manager API:     http://192.168.10.201:4000
n8n:                  http://192.168.10.104:5678
Pionex MCP:           http://192.168.10.102:8000
Deployment Hub:       http://192.168.10.107:8100
YubiKey Auth:         http://192.168.10.108:8110
SV Niederklein:       http://192.168.10.105:3001
Schützenverein:       http://192.168.10.106:3002
Windows VM noVNC:     http://192.168.10.220:8006
Windows VM RDP:       192.168.10.220:3389
usbipd:               192.168.10.210:3240
```
