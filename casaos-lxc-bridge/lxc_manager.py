"""
lxc_manager.py — LXC-Lifecycle-Management für CasaOS App-Store Apps

Koordiniert:
  1. LXC-Clone aus Template (Proxmox)
  2. Docker-Compose-Deployment im LXC
  3. Status-Tracking via SQLite (apps.db)
"""
from __future__ import annotations
import os
import time
import sqlite3
import textwrap
from dataclasses import dataclass
from proxmox_client import ProxmoxClient
from app_resolver import AppMeta

DB_PATH = os.getenv("BRIDGE_DB_PATH", "/data/apps.db")
DATA_DIR = os.getenv("CASAOS_DATA_DIR", "/DATA/AppData")


@dataclass
class AppRecord:
    app_id: str
    lxc_id: int
    ip: str
    hostname: str
    port: int
    status: str   # installing | running | stopped | error


def _get_db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH) if os.path.dirname(DB_PATH) else ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS apps (
            app_id   TEXT PRIMARY KEY,
            lxc_id   INTEGER,
            ip       TEXT,
            hostname TEXT,
            port     INTEGER,
            status   TEXT
        )
    """)
    conn.commit()
    return conn


def _upsert(conn: sqlite3.Connection, rec: AppRecord) -> None:
    conn.execute("""
        INSERT INTO apps (app_id, lxc_id, ip, hostname, port, status)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(app_id) DO UPDATE SET
            lxc_id=excluded.lxc_id, ip=excluded.ip,
            hostname=excluded.hostname, port=excluded.port,
            status=excluded.status
    """, (rec.app_id, rec.lxc_id, rec.ip, rec.hostname, rec.port, rec.status))
    conn.commit()


def install(
    meta: AppMeta,
    fixed_lxc_id: int | None = None,
    fixed_ip: str | None = None,
) -> AppRecord:
    """
    Vollständiger Install-Flow:
      1. Freie LXC-ID + IP ermitteln (oder fixed_lxc_id/fixed_ip für feste Apps)
      2. Template klonen
      3. LXC starten + auf Netzwerk warten
      4. docker-compose.yml schreiben + docker compose up

    fixed_lxc_id/fixed_ip: für vorkonfigurierte Apps mit fester IP (z.B. Nextcloud → LXC 109)
    """
    proxmox = ProxmoxClient()
    conn = _get_db()

    # Prüfen ob bereits installiert
    row = conn.execute("SELECT * FROM apps WHERE app_id=?", (meta.app_id,)).fetchone()
    if row and row["status"] in ("running", "installing"):
        raise RuntimeError(f"App '{meta.app_id}' ist bereits installiert (Status: {row['status']})")

    lxc_id = fixed_lxc_id or proxmox.next_free_id()
    ip = fixed_ip or proxmox.next_free_ip()
    hostname = f"casaos-{meta.app_id.lower().replace('_', '-')}"

    rec = AppRecord(
        app_id=meta.app_id, lxc_id=lxc_id, ip=ip,
        hostname=hostname, port=meta.port, status="installing"
    )
    _upsert(conn, rec)

    try:
        # 1. LXC aus Template klonen
        proxmox.clone_template(lxc_id, hostname, ip)

        # 2. LXC starten
        proxmox.start_lxc(lxc_id)
        _wait_for_network(ip)

        # 3. Compose-Datei im LXC ablegen (shell-sicher via pct push)
        app_dir = f"/opt/{meta.app_id}"
        compose_content = _patch_compose(meta)
        proxmox.exec_in_lxc(lxc_id, f"mkdir -p {app_dir}")
        proxmox.push_file_to_lxc(lxc_id, compose_content, f"{app_dir}/docker-compose.yml")

        # 4. Docker Compose starten
        proxmox.exec_in_lxc(lxc_id, f"cd {app_dir} && docker compose up -d")

        rec.status = "running"
        _upsert(conn, rec)

    except Exception as e:
        rec.status = "error"
        _upsert(conn, rec)
        raise RuntimeError(f"Install fehlgeschlagen: {e}") from e

    return rec


def remove(app_id: str) -> None:
    """Stoppt + zerstört den LXC und entfernt den DB-Eintrag."""
    conn = _get_db()
    row = conn.execute("SELECT * FROM apps WHERE app_id=?", (app_id,)).fetchone()
    if not row:
        raise FileNotFoundError(f"App '{app_id}' nicht gefunden")

    proxmox = ProxmoxClient()
    lxc_id = row["lxc_id"]
    try:
        proxmox.stop_lxc(lxc_id)
        time.sleep(3)
    except Exception:
        pass
    proxmox.destroy_lxc(lxc_id)
    conn.execute("DELETE FROM apps WHERE app_id=?", (app_id,))
    conn.commit()


def list_apps() -> list[AppRecord]:
    """Alle bridge-verwalteten Apps aus DB."""
    conn = _get_db()
    rows = conn.execute("SELECT * FROM apps").fetchall()
    return [AppRecord(**dict(r)) for r in rows]


def sync_status() -> None:
    """Synchronisiert DB-Status mit tatsächlichem Proxmox-LXC-Status."""
    proxmox = ProxmoxClient()
    conn = _get_db()
    for row in conn.execute("SELECT * FROM apps").fetchall():
        try:
            status = proxmox.get_lxc_status(row["lxc_id"])
            mapped = "running" if status == "running" else "stopped"
            conn.execute("UPDATE apps SET status=? WHERE app_id=?", (mapped, row["app_id"]))
        except Exception:
            conn.execute("UPDATE apps SET status='error' WHERE app_id=?", (row["app_id"],))
    conn.commit()


def _wait_for_network(ip: str, timeout: int = 60) -> None:
    """Wartet bis der LXC per TCP erreichbar ist (Port 22 = sshd)."""
    import socket
    for _ in range(timeout):
        try:
            with socket.create_connection((ip, 22), timeout=2):
                return
        except OSError:
            time.sleep(1)
    raise TimeoutError(f"LXC {ip} nicht im Netzwerk nach {timeout}s")


def _patch_compose(meta: AppMeta) -> str:
    """
    Ersetzt CasaOS-spezifische Magic-Variables in docker-compose.yml:
      ${WEBUI_PORT} → meta.port
      ${AppID}      → meta.app_id
      /DATA/AppData/${AppID} → /opt/<app_id>/data
    """
    compose = meta.compose_yaml
    compose = compose.replace("${WEBUI_PORT}", str(meta.port))
    compose = compose.replace("${WEBUI_PORT:-" + str(meta.port) + "}", str(meta.port))
    compose = compose.replace("${AppID}", meta.app_id)
    compose = compose.replace(f"/DATA/AppData/{meta.app_id}", f"/opt/{meta.app_id}/data")
    compose = compose.replace("/DATA/AppData/$AppID", f"/opt/{meta.app_id}/data")
    # PUID/PGID auf root setzen (vereinfacht, LXC ist isoliert)
    compose = compose.replace("${PUID}", "0")
    compose = compose.replace("${PGID}", "0")
    compose = compose.replace("${TZ}", "Europe/Berlin")
    return compose
