"""
preconfigured_apps.py — Registry freigeschalteter Apps für casaos-lxc-bridge

install_type:
  "fixed"   → feste LXC-ID + IP (wie Nextcloud LXC 109)
  "dynamic" → LXC-ID + IP dynamisch aus Bridge-Pool (301–399)
"""
from __future__ import annotations

PRECONFIGURED_APPS: list[dict] = [
    # ── Feste Apps (eigene LXC-ID + IP aus ip-plan.md) ─────────────────
    {
        "app_id": "Nextcloud",
        "name": "Nextcloud",
        "tagline": "Ihre Cloud, Ihre Regeln",
        "description": "Datei-Synchronisation, Kalender, Kontakte, Kollaboration und mehr. Vollständige Datenkontrolle auf Ihrem eigenen Server.",
        "icon": "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/Nextcloud/icon.png",
        "category": "Cloud",
        "port": 80,
        "install_type": "fixed",
        "lxc_id": 109,
        "ip": "192.168.10.109",
    },

    # ── Dynamische Apps (LXC-ID + IP aus Bridge-Pool 301–399) ───────────
    {
        "app_id": "Syncthing",
        "name": "Syncthing",
        "tagline": "Peer-to-Peer Datei-Synchronisation ohne Cloud",
        "description": "Synchronisiert Dateien direkt zwischen Geräten — verschlüsselt, dezentral, ohne Cloud-Dienst.",
        "icon": "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/Syncthing/icon.png",
        "category": "Backup",
        "port": 8384,
        "install_type": "dynamic",
        "lxc_id": None,
        "ip": None,
    },
    {
        "app_id": "Vaultwarden",
        "name": "Vaultwarden",
        "tagline": "Bitwarden-kompatibler Passwort-Manager",
        "description": "Leichtgewichtige Bitwarden-Server-Implementierung. Alle Bitwarden-Apps funktionieren damit.",
        "icon": "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/Vaultwarden/icon.png",
        "category": "Security",
        "port": 80,
        "install_type": "dynamic",
        "lxc_id": None,
        "ip": None,
    },
    {
        "app_id": "Gitea",
        "name": "Gitea",
        "tagline": "Self-hosted Git-Service",
        "description": "Leichtgewichtiger Git-Server mit Web-UI, Issues, Pull Requests und CI/CD-Integration.",
        "icon": "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/Gitea/icon.png",
        "category": "Developer Tools",
        "port": 3000,
        "install_type": "dynamic",
        "lxc_id": None,
        "ip": None,
    },
    {
        "app_id": "Jellyfin",
        "name": "Jellyfin",
        "tagline": "Media-Server — Filme, Serien, Musik",
        "description": "Freie Open-Source-Alternative zu Plex/Emby. Streamt Ihre lokale Mediathek auf alle Geräte.",
        "icon": "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/Jellyfin/icon.png",
        "category": "Media",
        "port": 8096,
        "install_type": "dynamic",
        "lxc_id": None,
        "ip": None,
    },
    {
        "app_id": "HomeAssistant",
        "name": "Home Assistant",
        "tagline": "Smart Home Automation Platform",
        "description": "Verbindet und automatisiert alle Smart-Home-Geräte. Lokal, privat, über 3000 Integrationen.",
        "icon": "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/HomeAssistant/icon.png",
        "category": "Smart Home",
        "port": 8123,
        "install_type": "dynamic",
        "lxc_id": None,
        "ip": None,
    },
]


def get_by_id(app_id: str) -> dict | None:
    """App-Definition anhand app_id suchen."""
    return next((a for a in PRECONFIGURED_APPS if a["app_id"] == app_id), None)


def get_fixed_params(app_id: str) -> tuple[int | None, str | None]:
    """Gibt (fixed_lxc_id, fixed_ip) zurück — None wenn dynamic."""
    app = get_by_id(app_id)
    if app and app["install_type"] == "fixed":
        return app["lxc_id"], app["ip"]
    return None, None
