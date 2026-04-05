---
project: jarvis-os-infra
status: active
last_updated: 2026-03-22
concept_version: v1.0
complexity_score: 13
complexity_size: L
complexity_factors: "Stack:3 Integr:3 Arch:3 Scope:2 Unknowns:2"
token_estimate_per_phase: ~80k
complexity_last_updated: 2026-03-22
---

# jarvis-os-infra — Project Concept

## Purpose & Goal
Proxmox VE 8.x Homelab-Infrastruktur — vollautomatische Installation via Custom ISO (LUKS2 + YubiKey optional). Jeder Service läuft in einem eigenen LXC-Container. **Basis-Infrastruktur für das gesamte J.A.R.V.I.S-OS-Ökosystem.**

## Current Status
Active. Autoinstall-ISO bereits gebaut (`proxmox-jarvis.iso`). Alle LXC-Deploy-Skripte vorhanden. Migration von Umbrel zu Proxmox läuft (MIGRATION.md).

## Komplexität & Token-Schätzung
| Faktor | Score | Bewertung |
|--------|-------|-----------|
| Stack-Tiefe | 3/3 | Proxmox VE + LXC + LUKS2 + ZFS + systemd + autoinstall |
| Integrationen | 3/3 | 12+ LXC-Services + GitHub Deployment + USB/IP + Windows VM |
| Architektur | 3/3 | Infrastructure-as-Code: ISO-Build + first-boot + LXC-Skripte |
| Scope | 2/3 | Skripte + Config, kein Anwendungs-Code |
| Unbekannte | 2/3 | Migration laufend, IP-Plan vollständig dokumentiert |
| **Gesamt** | **13/15 (L)** | **~80k Token/Haupt-Phase — max. 1 Phase/Session** |

## Tech Stack
| Layer | Technology | Notes |
|-------|-----------|-------|
| Hypervisor | Proxmox VE 8.x | Bare-Metal auf Homelab-Hardware |
| Isolation | LXC Container | Ein Service = Ein LXC |
| Verschlüsselung | LUKS2 (Pflicht) | YubiKey FIDO2 optional (yubikey-enroll.sh) |
| Storage | ZFS (optional) | zfs-pool-create.sh für verschlüsselte Datenpools |
| Netzwerk | 192.168.10.x/24 | IP-Plan: config/ip-plan.md |
| Autoinstall | answer.toml + build-iso.sh | Proxmox Autoinstall Spec |

## Architecture Overview — LXC-Infrastruktur
```
Proxmox VE 8.x (192.168.10.x)
├── LXC  10: Nginx Proxy Manager   192.168.10.140  :80 :443 :81
├── LXC  20: CasaOS Dashboard      192.168.10.141  :80
├── LXC 101: Setup-Repair Agent    192.168.10.101  :8007
├── LXC 102: Pionex MCP Server     192.168.10.102  :8000
├── LXC 103: Voice Assistant       192.168.10.103  :8000
├── LXC 104: n8n                   192.168.10.104  :5678
├── LXC 105: SV Niederklein        192.168.10.105  :3001
├── LXC 106: Schützenverein        192.168.10.106  :3002
├── LXC 107: Deployment Hub        192.168.10.107  :8100
├── LXC 108: YubiKey Auth          192.168.10.108  :8110
├── LXC 109: Nextcloud             192.168.10.109  :80
├── LXC 200: Wine Desktop          192.168.10.200  :5900 :8090
├── LXC 201: Wine API              192.168.10.201  :4000
├── LXC 202: Wine UI               192.168.10.202  :3000
├── LXC 210: usbipd                192.168.10.210  :3240
├── LXC 300: CasaOS LXC-Bridge    192.168.10.180  :8200
│   └── LXC 301–399: AppStore-Apps 192.168.10.181+ (dynamisch)
└── VM  100: Windows OBD2          192.168.10.220  :3389
```

**Ressourcen:** ~13.25 GB RAM | ~199 GB Disk gesamt

## Kunden & Ansprechpartner
_(kein externer Kunde — persönliche Homelab-Infrastruktur)_

## Applied Global Conventions
| Convention | Version Applied | Date Applied | Status |
|-----------|----------------|-------------|--------|
| _(kein Docker-Deploy — LXC-basiert)_ | — | — | — |

## Project-Specific Patterns & Gotchas
- **KRITISCH**: Proxmox ZUERST installieren — alle anderen Services hängen von der LXC-Infrastruktur ab
- `answer.toml` anpassen (Passwörter!) BEVOR ISO gebaut wird — nicht im Repo committen
- YubiKey LUKS-Enrollment nachträglich via `yubikey-enroll.sh` — Passphrase bleibt als Fallback
- `install-all.sh` deployt alle LXCs auf einmal (~10-15 Min) — idempotent
- Kein Docker / jarvis-net auf dieser Ebene — jeder LXC hat eigenen Netzwerk-Namespace
- **CasaOS App-Store-Bridge:** LXC App-Template (ID 9000) muss VOR Schritt 2 existieren — `install-all.sh` erledigt das automatisch via `install-lxc-app-template.sh` (Schritt 1b)
- **Proxmox API-Token** für Bridge wird automatisch in `install-all.sh` Schritt 2b erstellt und in `.env` von LXC 20 injiziert — kein manueller Eingriff nötig
- LXC-Range 300–399 reserviert für dynamisch installierte CasaOS App-Store-Apps (IP: 192.168.10.181–249)

## Known Tech Debt
- MIGRATION.md-Fortschritt unklar (Umbrel → Proxmox noch laufend?)
- Keine automatisierten Tests für LXC-Deploy-Skripte

## Open TODOs
- Migration von Umbrel abschließen (Status in MIGRATION.md prüfen)
- LXC 106 (Schützenverein) — welches Website-Projekt ist das?
- Alle install-lxc-*.sh auf Vollständigkeit prüfen

## Links & References
- Retrospective: [none yet]
- IP-Plan: [config/ip-plan.md](config/ip-plan.md)
- Autoinstall-Anleitung: [autoinstall/README.md](autoinstall/README.md)
- Migration: [MIGRATION.md](MIGRATION.md)
- Related projects: ALLE — diese Infrastruktur betreibt alle LXC-Services
