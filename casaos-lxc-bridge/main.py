"""
main.py — jarvis-lxc-bridge FastAPI

Endpunkte:
  GET    /                                   → Redirect zur Web-UI
  GET    /static/index.html                 Web-UI (One-Click App-Store)
  POST   /bridge/install?appid=<id>         App aus Store als LXC deployen
  DELETE /bridge/remove?appid=<id>          LXC stoppen + löschen
  GET    /bridge/list                        Alle bridge-verwalteten Apps
  GET    /bridge/status?appid=<id>          Status einer App
  POST   /bridge/sync                        DB-Status mit Proxmox abgleichen
  GET    /bridge/catalog                     Verfügbare Apps (alle Stores, filterbar)
  GET    /bridge/catalog/sources             Aktive Store-Quellen
  GET    /bridge/preconfigured               Freigeschaltete Apps (mit Live-Status)
  GET    /casaos-store/Apps                  GitHub-API-kompatibler App-Index (für CasaOS)
  GET    /casaos-store/{app_id}/docker-compose.yml  Compose mit x-casaos Block (für CasaOS)
  GET    /health                             Liveness-Check

  --- Admin-Endpoints (X-API-Key: $ADMIN_KEY erforderlich) ---
  POST   /admin/users?username=X&quota=100G&dashboard_type=casaos  User anlegen + provisionieren
  GET    /admin/users                        Alle User auflisten
  GET    /admin/users/{id}/status           User-Status + Zugangsdaten
  GET    /admin/users/{id}/quota            ZFS-Quota + Nutzung
  DELETE /admin/users/{id}                  User + alle Ressourcen entfernen
  POST   /admin/backup?layer=all             Backup auslösen (SSE Live-Log)
  GET    /admin/backup/status                Letzter Backup-Status
  GET    /admin/backup/usb-status            USB-Stick + Backup-Partition Status
  GET    /admin/backup/usb-contents          Backup-Inhalte + Größen pro Layer
  POST   /admin/backup/usb-cleanup           Retention-Bereinigung (SSE Live-Log)
"""
from __future__ import annotations
import asyncio
import os
import re
import time
import logging
import textwrap
import json
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Query, Depends, Request
import io
import zipfile
from fastapi.responses import JSONResponse, RedirectResponse, PlainTextResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
import httpx
import app_resolver
import lxc_manager
import casaos_client
import preconfigured_apps
import user_manager
from auth import require_admin, require_user_or_admin

logger = logging.getLogger("jarvis-lxc-bridge")
logging.basicConfig(level=logging.INFO)

BRIDGE_URL = os.getenv("BRIDGE_URL", "http://192.168.10.141:8200")
BRIDGE_LXC_ID = int(os.getenv("BRIDGE_LXC_ID", "120"))
STORE_AUTHOR = os.getenv("STORE_AUTHOR", "J.A.R.V.I.S-OS")

# ---------------------------------------------------------------------------
# Katalog-Cache: wird beim Start befüllt + alle 6h refreshed
# ---------------------------------------------------------------------------
_catalog_cache: dict = {"apps": [], "last_update": 0.0}
_store_zip_cache: dict = {"zip_bytes": b"", "last_update": 0.0}
_CACHE_TTL = 6 * 3600   # 6 Stunden


def _is_casaos_compatible(compose_yaml: str) -> bool:
    """
    Prüft ob ein Compose-File CasaOS-kompatibel ist.
    Umbrel-Apps verwenden app_proxy ohne Image → scheitern an CasaOS-Validierung.
    """
    if "app_proxy:" not in compose_yaml:
        return True
    # app_proxy-Service hat kein eigenes Image → Umbrel-Pattern, nicht CasaOS-kompatibel
    proxy_section = compose_yaml.split("app_proxy:")[1]
    next_service = proxy_section.find("\n  ") if "\n  " in proxy_section else len(proxy_section)
    return "image:" in proxy_section[:next_service]


def _build_store_zip_sync(apps: list) -> bytes:
    """
    Baut den Store-ZIP synchron im Memory. Für asyncio.to_thread().
    Schließt Umbrel-Apps mit app_proxy-Service aus (CasaOS-inkompatibel).
    """
    buf = io.BytesIO()
    included = 0
    skipped = 0
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for app_entry in apps:
            app_id = app_entry.get("app_id")
            if not app_id:
                continue
            try:
                meta = app_resolver.resolve(app_id)
                compose = _to_casaos_format(meta)
                if not _is_casaos_compatible(compose):
                    skipped += 1
                    continue
                # Root-level x-casaos author überschreiben (2-Space-Indent)
                compose = re.sub(r'^  author:.*$', f'  author: {STORE_AUTHOR}', compose, flags=re.MULTILINE)
                zf.writestr(f"casaos-store/Apps/{app_id}/docker-compose.yml", compose)
                included += 1
            except Exception:
                skipped += 1
    logger.info(f"Store-ZIP: {included} Apps eingeschlossen, {skipped} übersprungen")
    return buf.getvalue()


async def _refresh_catalog_cache() -> None:
    """Befüllt den Katalog-Cache + ZIP-Cache async im Hintergrund."""
    try:
        all_apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)
        _catalog_cache["apps"] = all_apps
        _catalog_cache["last_update"] = time.time()
        logger.info(f"Katalog-Cache aktualisiert: {len(all_apps)} Apps")
    except Exception as e:
        logger.warning(f"Katalog-Cache-Refresh fehlgeschlagen: {e}")
        return

    # ZIP-Cache nach Katalog-Refresh neu bauen
    try:
        zip_bytes = await asyncio.to_thread(_build_store_zip_sync, _catalog_cache["apps"])
        _store_zip_cache["zip_bytes"] = zip_bytes
        _store_zip_cache["last_update"] = time.time()
        logger.info(f"Store-ZIP-Cache aktualisiert: {len(zip_bytes)} Bytes")
    except Exception as e:
        logger.warning(f"Store-ZIP-Cache-Refresh fehlgeschlagen: {e}")


async def _schedule_cache_refresh() -> None:
    """Loop: Katalog alle 6h aktualisieren."""
    while True:
        await _refresh_catalog_cache()
        await asyncio.sleep(_CACHE_TTL)


# ---------------------------------------------------------------------------
# CasaOS Custom Store: Pseudo-Store-API (GitHub-API-kompatibel)
# ---------------------------------------------------------------------------

def _to_casaos_format(meta: app_resolver.AppMeta) -> str:
    """
    Gibt CasaOS-kompatibles docker-compose.yml zurück.

    Für CasaOS-Apps: bestehendes Compose (hat bereits x-casaos Block).
    Für Umbrel-Apps: generiert synthetischen x-casaos Block.
    """
    compose = meta.compose_yaml
    if meta.store_type == "umbrel":
        # x-casaos Block synthetisch generieren (Umbrel hat keinen eigenen)
        xcasaos = textwrap.dedent(f"""

            x-casaos:
              architectures: ["amd64", "arm64"]
              main: {meta.app_id}
              category: {meta.category}
              description:
                en_US: "{(meta.description or meta.name).strip().splitlines()[0]}"
              icon: "{meta.icon}"
              tagline:
                en_US: "{meta.tagline}"
              title:
                en_US: "{meta.name}"
              port_map: "{meta.port}"
              developer: "{meta.developer}"
              author: "{meta.developer}"
        """)
        compose = compose + xcasaos
    return compose


# ---------------------------------------------------------------------------
# Lifespan: Startup-Event für CasaOS Store-Registrierung + Cache
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(fastapi_app: FastAPI):
    # Katalog-Cache im Hintergrund starten
    cache_task = asyncio.create_task(_schedule_cache_refresh())

    # Bridge als CasaOS Custom Store registrieren (idempotent)
    store_url = f"{BRIDGE_URL}/casaos-store.zip"
    try:
        from proxmox_client import ProxmoxClient
        proxmox = ProxmoxClient()
        proxmox.exec_in_lxc(
            BRIDGE_LXC_ID,
            f"casaos-cli app-management register app-store {store_url} || true"
        )
        logger.info(f"CasaOS Custom Store registriert: {store_url}")
    except Exception as e:
        logger.warning(f"CasaOS Store-Registrierung fehlgeschlagen (ggf. manuell): {e}")

    yield

    cache_task.cancel()
    try:
        await cache_task
    except asyncio.CancelledError:
        pass


# ---------------------------------------------------------------------------
# FastAPI App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="jarvis-lxc-bridge",
    description="CasaOS App-Store + Umbrel → Proxmox LXC Bridge",
    version="2.0.0",
    lifespan=lifespan,
)

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/static/index.html")


@app.get("/admin", include_in_schema=False)
def admin_ui():
    return RedirectResponse("/static/admin.html")


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "jarvis-lxc-bridge",
        "catalog_cached": len(_catalog_cache["apps"]),
        "cache_age_s": int(time.time() - _catalog_cache["last_update"]) if _catalog_cache["last_update"] else None,
    }


# ---------------------------------------------------------------------------
# Preconfigured Apps
# ---------------------------------------------------------------------------

@app.get("/bridge/preconfigured")
async def get_preconfigured(request: Request):
    """Freigeschaltete Apps mit Live-Status aus der Bridge-DB."""
    # Admin-Check: nur Admins sehen admin_only Apps
    is_admin = False
    api_key = request.headers.get("x-api-key", "") or request.query_params.get("admin_key", "")
    if api_key and api_key == os.getenv("ADMIN_API_KEY", ""):
        is_admin = True

    installed = {a.app_id: a for a in lxc_manager.list_apps()}
    result = []
    for app_def in preconfigured_apps.PRECONFIGURED_APPS:
        if app_def.get("admin_only") and not is_admin:
            continue
        entry = dict(app_def)
        if entry["app_id"] in installed:
            rec = installed[entry["app_id"]]
            entry["status"] = rec.status
            entry["url"] = f"http://{rec.ip}:{rec.port}"
            entry["lxc_id"] = rec.lxc_id
        else:
            entry["status"] = "not_installed"
            entry["url"] = None
        result.append(entry)
    return {"apps": result}


# ---------------------------------------------------------------------------
# Install / Remove / List / Status / Sync
# ---------------------------------------------------------------------------

@app.post("/bridge/install")
async def install_app(
    appid: str = Query(..., description="App-ID (z.B. 'N8n', 'vaultwarden')"),
    caller_user_id: int | None = Depends(require_user_or_admin),
):
    """
    Installiert eine App aus CasaOS- oder Umbrel-Store als isolierten Proxmox-LXC.
    Mit User-Key: App wird im User-Subnetz installiert (User-Scope).
    Mit Admin-Key oder ohne Auth: Admin-Modus (vmbr0, bestehende Range 300–399).
    """
    try:
        meta = app_resolver.resolve(appid)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    if caller_user_id is not None:
        # User-Scope: App in User-Subnetz + User-LXC-Range
        try:
            rec = await asyncio.to_thread(lxc_manager.install_for_user, meta, caller_user_id)
        except RuntimeError as e:
            raise HTTPException(409 if "bereits installiert" in str(e) else 500, detail=str(e))
        return {
            "success": True,
            "app_id": rec.app_id,
            "lxc_id": rec.lxc_id,
            "ip": rec.ip,
            "port": rec.port,
            "url": f"http://{rec.ip}:{rec.port}",
            "store_type": meta.store_type,
            "user_id": caller_user_id,
        }

    # Admin-Modus: klassische Installation in vmbr0
    fixed_lxc_id, fixed_ip = preconfigured_apps.get_fixed_params(appid)
    try:
        rec = await asyncio.to_thread(lxc_manager.install, meta, fixed_lxc_id, fixed_ip)
    except RuntimeError as e:
        raise HTTPException(409 if "bereits installiert" in str(e) else 500, detail=str(e))

    casaos_msg = "CasaOS-Registrierung übersprungen (kein Token)"
    try:
        casaos_msg = await asyncio.to_thread(casaos_client.register, meta, rec)
    except RuntimeError as e:
        casaos_msg = f"Warnung: {e}"

    return {
        "success": True,
        "app_id": rec.app_id,
        "lxc_id": rec.lxc_id,
        "ip": rec.ip,
        "port": rec.port,
        "url": f"http://{rec.ip}:{rec.port}",
        "store_type": meta.store_type,
        "casaos": casaos_msg,
    }


@app.delete("/bridge/remove")
async def remove_app(
    appid: str = Query(..., description="App-ID"),
    _: None = Depends(require_admin),
):
    """Admin: Stoppt und zerstört den LXC-Container. Entfernt den CasaOS-Dashboard-Eintrag."""
    try:
        await asyncio.to_thread(casaos_client.unregister, appid)
    except Exception:
        pass

    try:
        await asyncio.to_thread(lxc_manager.remove, appid)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(500, detail=str(e))

    return {"success": True, "app_id": appid, "message": "LXC gestoppt und zerstört"}


@app.delete("/bridge/apps/remove")
async def user_remove_app(
    appid: str = Query(..., description="App-ID aus dem Katalog"),
    user=Depends(require_user_or_admin),
):
    """User: Eigene App deinstallieren (LXC zerstören + DB-Eintrag entfernen)."""
    from lxc_manager import _get_db
    user_id = user if isinstance(user, int) else None
    if user_id is None:
        raise HTTPException(400, detail="Nur für User mit API-Key verfügbar")

    conn = _get_db()
    # Finde die App mit User-Prefix (u{id}__{appid})
    prefixed_id = f"u{user_id}__{appid}"
    row = conn.execute(
        "SELECT * FROM apps WHERE app_id=? AND user_id=?", (prefixed_id, user_id)
    ).fetchone()
    if not row:
        # Fallback: ohne Prefix suchen
        row = conn.execute(
            "SELECT * FROM apps WHERE app_id=? AND user_id=?", (appid, user_id)
        ).fetchone()
    if not row:
        raise HTTPException(404, detail=f"App '{appid}' nicht gefunden oder gehört dir nicht")

    actual_app_id = row["app_id"]
    try:
        await asyncio.to_thread(lxc_manager.remove, actual_app_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(500, detail=str(e))

    # Auch zugehörige app_requests aufräumen
    conn.execute(
        "DELETE FROM app_requests WHERE user_id=? AND app_id=?", (user_id, appid)
    )
    conn.commit()

    return {"success": True, "app_id": appid, "message": "App deinstalliert"}


@app.get("/bridge/list")
async def list_apps(
    caller_user_id: int | None = Depends(require_user_or_admin),
):
    """Alle bridge-verwalteten Apps. User sieht nur eigene Apps."""
    await asyncio.to_thread(lxc_manager.sync_status)
    if caller_user_id is not None:
        apps = lxc_manager.list_apps_for_user(caller_user_id)
    else:
        apps = lxc_manager.list_apps()
    return {
        "count": len(apps),
        "apps": [
            {
                "app_id": a.app_id,
                "lxc_id": a.lxc_id,
                "ip": a.ip,
                "hostname": a.hostname,
                "port": a.port,
                "url": f"http://{a.ip}:{a.port}",
                "status": a.status,
            }
            for a in apps
        ],
    }


@app.get("/bridge/status")
async def app_status(appid: str = Query(...)):
    apps = lxc_manager.list_apps()
    for a in apps:
        if a.app_id == appid:
            return {"app_id": a.app_id, "lxc_id": a.lxc_id, "ip": a.ip, "status": a.status}
    raise HTTPException(404, detail=f"App '{appid}' nicht gefunden")


@app.post("/bridge/sync")
async def sync():
    """Synchronisiert DB-Status mit tatsächlichem Proxmox-LXC-Status."""
    await asyncio.to_thread(lxc_manager.sync_status)
    return {"success": True, "message": "Status synchronisiert"}


# ---------------------------------------------------------------------------
# Katalog
# ---------------------------------------------------------------------------

@app.get("/bridge/catalog")
async def catalog(
    source: str = Query("all", description="'all', 'casaos', 'umbrel', 'custom'"),
    category: str = Query("", description="Kategorie-Filter (case-insensitiv)"),
    q: str = Query("", description="Suchbegriff"),
):
    """
    Verfügbare Apps aus allen Stores.
    Gibt gecachte Ergebnisse zurück (Cache-TTL: 6h).
    """
    apps = _catalog_cache["apps"]
    if not apps:
        # Fallback: synchron laden wenn Cache noch leer
        apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)

    if source != "all":
        apps = [a for a in apps if a.get("source") == source]
    if category:
        apps = [a for a in apps if a.get("category", "").lower() == category.lower()]
    if q:
        q_lower = q.lower()
        apps = [a for a in apps if q_lower in a.get("app_id", "").lower() or q_lower in a.get("name", "").lower()]

    return {
        "count": len(apps),
        "apps": apps,
        "cached_at": _catalog_cache["last_update"] or None,
    }


@app.post("/bridge/catalog/refresh")
async def catalog_refresh():
    """Erzwingt sofortigen Katalog-Cache-Refresh."""
    await _refresh_catalog_cache()
    return {"success": True, "count": len(_catalog_cache["apps"])}


@app.get("/bridge/catalog/sources")
async def catalog_sources():
    """Aktive Store-Quellen und ihre Konfiguration."""
    return {
        "casaos_official": True,
        "umbrel_official": app_resolver.UMBREL_STORE_ENABLED,
        "custom_stores": app_resolver._parse_custom_stores(),
    }


# ---------------------------------------------------------------------------
# CasaOS Pseudo-Store-API (/casaos-store/)
# ---------------------------------------------------------------------------

@app.get("/casaos-store/Apps")
async def casaos_store_index():
    """
    GitHub-API-kompatibler App-Index.
    CasaOS liest diesen Endpoint wenn die Bridge als Custom Store registriert ist.
    """
    apps = _catalog_cache["apps"]
    if not apps:
        apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)

    all_ids = sorted({a["app_id"] for a in apps})
    return [{"name": app_id, "type": "dir"} for app_id in all_ids]


@app.get("/casaos-store/{app_id}/docker-compose.yml")
async def casaos_store_app(app_id: str):
    """
    Liefert CasaOS-kompatibles docker-compose.yml (mit x-casaos Block).
    Für Umbrel-Apps wird ein synthetischen x-casaos Block generiert.
    """
    try:
        meta = await asyncio.to_thread(app_resolver.resolve, app_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    compose = _to_casaos_format(meta)
    return PlainTextResponse(compose, media_type="text/plain")


@app.api_route("/casaos-store.zip", methods=["GET", "HEAD"])
async def casaos_store_zip(request: Request):
    """
    GitHub-Archive-kompatibler ZIP-Download des Custom Stores.
    CasaOS v0.4.15+ erwartet eine ZIP-URL beim Registrieren von Custom Stores.
    HEAD antwortet sofort aus dem Cache (CasaOS-Timeout-sicher).
    Struktur: casaos-store/Apps/{app_id}/docker-compose.yml
    """
    zip_bytes = _store_zip_cache["zip_bytes"]

    # Fallback: ZIP synchron bauen wenn Cache noch leer (Erststart)
    if not zip_bytes:
        apps = _catalog_cache["apps"]
        if not apps:
            apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)
            _catalog_cache["apps"] = apps
        zip_bytes = await asyncio.to_thread(_build_store_zip_sync, apps)
        _store_zip_cache["zip_bytes"] = zip_bytes
        _store_zip_cache["last_update"] = time.time()

    headers = {
        "Content-Disposition": "attachment; filename=casaos-store.zip",
        "Content-Length": str(len(zip_bytes)),
    }
    if request.method == "HEAD":
        return Response(headers=headers, media_type="application/zip")
    return Response(content=zip_bytes, media_type="application/zip", headers=headers)


# ---------------------------------------------------------------------------
# Admin-Endpoints — nur mit X-API-Key: $ADMIN_KEY
# ---------------------------------------------------------------------------

@app.post("/admin/users")
async def create_user(
    username: str = Query(..., description="Eindeutiger Username"),
    quota: str = Query("100G", description="ZFS-Quota z.B. '50G', '200G'"),
    storage_tier: str = Query("premium", description="'premium' (SSD) | 'standard' (HDD)"),
    dashboard_type: str = Query("casaos", description="'casaos' (LXC) | 'ugos' (VM)"),
    _: None = Depends(require_admin),
):
    """
    Legt einen neuen User an und startet die vollständige Provisionierung.
    Gibt user_id + api_key zurück. Provisionierung dauert ~5–10 Minuten.
    """
    try:
        result = await asyncio.to_thread(
            user_manager.provision_user, username, quota, storage_tier, dashboard_type
        )
    except RuntimeError as e:
        raise HTTPException(409 if "vergeben" in str(e) else 500, detail=str(e))
    return result


@app.get("/admin/users")
async def admin_list_users(_: None = Depends(require_admin)):
    """Alle User mit Status auflisten."""
    users = user_manager.list_users()
    return {"count": len(users), "users": users}


@app.get("/admin/users/{user_id}/status")
async def admin_user_status(
    user_id: int,
    _: None = Depends(require_admin),
):
    """Detaillierter User-Status inkl. CasaOS-URL, SMB-Shares, VPN-Infos."""
    try:
        return user_manager.get_user(user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))


@app.get("/admin/users/{user_id}/quota")
async def admin_user_quota(
    user_id: int,
    _: None = Depends(require_admin),
):
    """ZFS-Quota + aktueller Speicherverbrauch des Users."""
    try:
        return await asyncio.to_thread(user_manager.get_user_quota, user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.delete("/admin/users/{user_id}")
async def admin_delete_user(
    user_id: int,
    _: None = Depends(require_admin),
):
    """
    Löscht User + alle Ressourcen (LXCs, ZFS-Datasets, Bridge, iptables-Regeln).
    Fehler-tolerant: einzelne fehlschlagende Cleanup-Schritte werden geloggt.
    """
    try:
        await asyncio.to_thread(user_manager.deprovision_user, user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(500, detail=str(e))
    return {"success": True, "user_id": user_id, "message": "User + alle Ressourcen entfernt"}


# ---------------------------------------------------------------------------
# Ressourcen-Management-Endpoints
# ---------------------------------------------------------------------------

@app.get("/admin/users/{user_id}/resources")
async def admin_user_resources(
    user_id: int,
    _: None = Depends(require_admin),
):
    """CPU/RAM-Nutzung + ZFS-Quota eines Users (Live-Daten)."""
    from proxmox_client import ProxmoxClient
    from zfs_manager import get_dataset_usage
    try:
        user = user_manager.get_user(user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    proxmox = ProxmoxClient()
    lxc_id = user.get("casaos_lxc_id")
    dashboard_type = user.get("dashboard_type", "casaos")

    vm_stats = {}
    if lxc_id:
        if dashboard_type == "ugos":
            vm_stats = await asyncio.to_thread(proxmox.get_vm_resources, lxc_id)
        else:
            vm_stats = await asyncio.to_thread(proxmox.get_lxc_resources, lxc_id)

    zfs_stats = await asyncio.to_thread(get_dataset_usage, user["username"], proxmox)
    return {
        "user_id": user_id,
        "username": user["username"],
        "dashboard": vm_stats,
        "storage": zfs_stats,
    }


@app.put("/admin/users/{user_id}/resources")
async def admin_update_resources(
    user_id: int,
    quota: str | None = Query(None, description="Neue ZFS-Quota z.B. '200G'"),
    cores: int | None = Query(None, description="CPU-Kerne für Dashboard-VM/LXC"),
    memory: int | None = Query(None, description="RAM in MB für Dashboard-VM/LXC"),
    _: None = Depends(require_admin),
):
    """Ändert Ressourcen-Limits eines Users (Quota, CPU, RAM)."""
    from proxmox_client import ProxmoxClient
    from zfs_manager import set_dataset_quota
    try:
        user = user_manager.get_user(user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    proxmox = ProxmoxClient()
    changes = []

    if quota:
        await asyncio.to_thread(set_dataset_quota, user["username"], quota, proxmox)
        from lxc_manager import _get_db
        conn = _get_db()
        conn.execute("UPDATE users SET zfs_quota=? WHERE user_id=?", (quota, user_id))
        conn.commit()
        changes.append(f"quota={quota}")

    lxc_id = user.get("casaos_lxc_id")
    if lxc_id and cores and memory:
        dashboard_type = user.get("dashboard_type", "casaos")
        if dashboard_type == "ugos":
            await asyncio.to_thread(proxmox.set_vm_resources, lxc_id, cores, memory)
        else:
            await asyncio.to_thread(proxmox.set_lxc_resources, lxc_id, cores, memory)
        changes.append(f"cores={cores}, memory={memory}MB")

    return {"success": True, "user_id": user_id, "changes": changes}


@app.get("/admin/resources/overview")
async def admin_resources_overview(_: None = Depends(require_admin)):
    """Ressourcen-Übersicht aller User (CPU/RAM/Disk aggregiert)."""
    from proxmox_client import ProxmoxClient
    from zfs_manager import get_dataset_usage
    users = user_manager.list_users()
    proxmox = ProxmoxClient()
    overview = []
    for u in users:
        lxc_id = u.get("casaos_lxc_id")
        dashboard_type = u.get("dashboard_type", "casaos")
        vm_stats = {}
        if lxc_id:
            try:
                if dashboard_type == "ugos":
                    vm_stats = proxmox.get_vm_resources(lxc_id)
                else:
                    vm_stats = proxmox.get_lxc_resources(lxc_id)
            except Exception:
                pass
        zfs_stats = {}
        try:
            zfs_stats = get_dataset_usage(u["username"], proxmox)
        except Exception:
            pass
        overview.append({
            "user_id": u["user_id"],
            "username": u["username"],
            "status": u["status"],
            "dashboard_type": dashboard_type,
            "cpu_percent": vm_stats.get("cpu_percent", 0),
            "mem_used_bytes": vm_stats.get("mem_used_bytes", 0),
            "mem_total_bytes": vm_stats.get("mem_total_bytes", 0),
            "disk_used_gb": zfs_stats.get("used_gb", 0),
            "disk_quota_gb": zfs_stats.get("quota_gb", 0),
        })
    return {"count": len(overview), "users": overview}


# ---------------------------------------------------------------------------
# Service-Anfrage-Endpoints (User → Admin Approval Flow)
# ---------------------------------------------------------------------------

@app.post("/bridge/apps/request")
async def request_app(
    appid: str = Query(..., description="App-ID aus dem Katalog"),
    user=Depends(require_user_or_admin),
):
    """
    User beantragt App-Installation. Bridge prüft Ressourcen-Limits:
    - Genug freie Slots → direktes Installieren
    - Limit überschritten → Anfrage an Admin (pending)
    """
    # Admin-only Apps: nur Admins dürfen installieren
    import preconfigured_apps
    app_def = preconfigured_apps.get_by_id(appid)
    if app_def and app_def.get("admin_only"):
        raise HTTPException(403, detail=f"'{appid}' kann nur vom Admin installiert werden.")

    from lxc_manager import _get_db
    conn = _get_db()
    user_id = user if isinstance(user, int) else None
    if user_id is None:
        raise HTTPException(400, detail="Nur für User mit API-Key verfügbar")

    # Dauerhaft gesperrt?
    blocked = conn.execute(
        "SELECT id FROM app_requests WHERE user_id=? AND app_id=? AND status='blocked'",
        (user_id, appid)
    ).fetchone()
    if blocked:
        raise HTTPException(403, detail=f"'{appid}' wurde vom Admin dauerhaft gesperrt.")

    # Bereits laufende Anfrage?
    existing = conn.execute(
        "SELECT id FROM app_requests WHERE user_id=? AND app_id=? AND status='pending'",
        (user_id, appid)
    ).fetchone()
    if existing:
        raise HTTPException(409, detail=f"Anfrage für '{appid}' bereits offen")

    # Alte abgelehnte/genehmigte Anfragen entfernen (erneutes Anfragen erlauben)
    conn.execute(
        "DELETE FROM app_requests WHERE user_id=? AND app_id=? AND status IN ('denied','approved')",
        (user_id, appid)
    )
    conn.commit()

    # App-Slots im User-Bereich prüfen
    user_row = conn.execute("SELECT * FROM users WHERE user_id=?", (user_id,)).fetchone()
    used_slots = conn.execute(
        "SELECT COUNT(*) as cnt FROM apps WHERE user_id=? AND status='running'",
        (user_id,)
    ).fetchone()["cnt"]
    max_slots = int(os.getenv("USER_APP_SLOT_LIMIT", "10"))

    if used_slots < max_slots:
        # Direktes Installieren — Ressourcen verfügbar
        try:
            meta = await asyncio.to_thread(app_resolver.resolve, appid)
            rec = await asyncio.to_thread(lxc_manager.install_for_user, meta, user_id)
            return {"status": "installed", "app_id": appid, "ip": rec.ip}
        except FileNotFoundError:
            # App nicht in Store → Anfrage an Admin (manuelles Setup nötig)
            pass
        except Exception as e:
            raise HTTPException(500, detail=str(e))

    # Anfrage an Admin erstellen (Slot-Limit oder App nicht im Store)
    conn.execute(
        "INSERT INTO app_requests (user_id, app_id) VALUES (?, ?)",
        (user_id, appid)
    )
    conn.commit()
    reason = "App nicht automatisch verfügbar" if used_slots < max_slots else f"Slot-Limit ({max_slots}) erreicht"
    return {
        "status": "pending",
        "message": f"{reason}. Anfrage an Admin gesendet.",
        "app_id": appid,
    }


@app.get("/admin/apps/requests")
async def admin_list_requests(_: None = Depends(require_admin)):
    """Alle offenen Service-Anfragen von Usern."""
    from lxc_manager import _get_db
    conn = _get_db()
    rows = conn.execute("""
        SELECT r.*, u.username
        FROM app_requests r
        JOIN users u ON r.user_id = u.user_id
        WHERE r.status IN ('pending', 'blocked')
        ORDER BY r.requested_at ASC
    """).fetchall()
    return {
        "count": len(rows),
        "requests": [dict(r) for r in rows],
    }


@app.post("/admin/apps/requests/{request_id}/approve")
async def admin_approve_request(
    request_id: int,
    _: None = Depends(require_admin),
):
    """Genehmigt eine App-Anfrage und startet die Installation."""
    from lxc_manager import _get_db
    conn = _get_db()
    row = conn.execute(
        "SELECT * FROM app_requests WHERE id=? AND status='pending'", (request_id,)
    ).fetchone()
    if not row:
        raise HTTPException(404, detail="Anfrage nicht gefunden oder bereits bearbeitet")

    try:
        meta = await asyncio.to_thread(app_resolver.resolve, row["app_id"])
    except FileNotFoundError:
        # App nicht im Store → nur als approved markieren (manuelle Installation)
        conn.execute(
            "UPDATE app_requests SET status='approved', reviewed_at=CURRENT_TIMESTAMP, "
            "notes='Manuelle Installation erforderlich' WHERE id=?", (request_id,)
        )
        conn.commit()
        return {"success": True, "app_id": row["app_id"], "manual": True,
                "message": f"App '{row['app_id']}' genehmigt — nicht automatisch installierbar."}

    try:
        rec = await asyncio.to_thread(lxc_manager.install_for_user, meta, row["user_id"])
        conn.execute(
            "UPDATE app_requests SET status='approved', reviewed_at=CURRENT_TIMESTAMP "
            "WHERE id=?", (request_id,)
        )
        conn.commit()
        return {"success": True, "app_id": row["app_id"], "ip": rec.ip}
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.post("/admin/apps/requests/{request_id}/deny")
async def admin_deny_request(
    request_id: int,
    notes: str = Query("", description="Begründung"),
    _: None = Depends(require_admin),
):
    """Lehnt eine App-Anfrage ab."""
    from lxc_manager import _get_db
    conn = _get_db()
    result = conn.execute(
        "UPDATE app_requests SET status='denied', reviewed_at=CURRENT_TIMESTAMP, notes=? "
        "WHERE id=? AND status='pending'",
        (notes, request_id)
    )
    conn.commit()
    if result.rowcount == 0:
        raise HTTPException(404, detail="Anfrage nicht gefunden oder bereits bearbeitet")
    return {"success": True, "request_id": request_id}


@app.post("/admin/apps/requests/{request_id}/block")
async def admin_block_request(
    request_id: int,
    notes: str = Query("", description="Begründung"),
    _: None = Depends(require_admin),
):
    """Sperrt eine App-Anfrage dauerhaft — User kann nicht erneut anfragen."""
    from lxc_manager import _get_db
    conn = _get_db()
    result = conn.execute(
        "UPDATE app_requests SET status='blocked', reviewed_at=CURRENT_TIMESTAMP, notes=? "
        "WHERE id=? AND status IN ('pending','denied')",
        (notes, request_id)
    )
    conn.commit()
    if result.rowcount == 0:
        raise HTTPException(404, detail="Anfrage nicht gefunden oder bereits bearbeitet")
    return {"success": True, "request_id": request_id}


@app.post("/admin/apps/requests/{request_id}/unblock")
async def admin_unblock_request(
    request_id: int,
    _: None = Depends(require_admin),
):
    """Entsperrt eine gesperrte App-Anfrage — löscht den Eintrag, User kann erneut anfragen."""
    from lxc_manager import _get_db
    conn = _get_db()
    result = conn.execute(
        "DELETE FROM app_requests WHERE id=? AND status='blocked'",
        (request_id,)
    )
    conn.commit()
    if result.rowcount == 0:
        raise HTTPException(404, detail="Gesperrte Anfrage nicht gefunden")
    return {"success": True, "request_id": request_id}


@app.get("/bridge/apps/requests")
async def user_list_requests(
    user=Depends(require_user_or_admin),
):
    """Eigene App-Anfragen des Users (pending/approved/denied)."""
    from lxc_manager import _get_db
    user_id = user if isinstance(user, int) else None
    if user_id is None:
        raise HTTPException(400, detail="Nur für User mit API-Key verfügbar")
    conn = _get_db()
    rows = conn.execute(
        "SELECT id, app_id, status, requested_at, notes FROM app_requests "
        "WHERE user_id=? ORDER BY requested_at DESC",
        (user_id,)
    ).fetchall()
    return {
        "requests": [dict(r) for r in rows],
    }


# ---------------------------------------------------------------------------
# Backup-Endpoints (Admin-only)
# ---------------------------------------------------------------------------
from fastapi.responses import StreamingResponse

_backup_status: dict = {"running": False, "last_run": None, "last_result": None}


@app.post("/admin/backup")
async def admin_trigger_backup(
    layer: str = Query("all", description="Layer: 1, 2, 3, 1,3, oder all"),
    _: None = Depends(require_admin),
):
    """
    Löst backup-all.sh auf dem Proxmox-Host aus.
    Gibt SSE-Stream mit Live-Log-Output zurück.
    """
    if _backup_status["running"]:
        raise HTTPException(409, detail="Backup läuft bereits")

    from proxmox_client import ProxmoxClient
    proxmox = ProxmoxClient()

    def stream_backup():
        import subprocess, tempfile, shutil, stat
        _backup_status["running"] = True
        _backup_status["last_run"] = time.strftime("%Y-%m-%d %H:%M:%S")
        try:
            yield f"data: {json.dumps({'type': 'start', 'layer': layer})}\n\n"

            ssh_key_path = os.getenv("PROXMOX_SSH_KEY", "/app/proxmox_key")
            host = os.getenv("PROXMOX_HOST", "https://192.168.10.147:8006")
            host_ip = host.replace("https://", "").replace("http://", "").split(":")[0]

            # Temp-Key vorbereiten (wie _ssh_run)
            tmp_key = tempfile.mktemp(prefix="backup_key_")
            shutil.copy2(ssh_key_path, tmp_key)
            os.chmod(tmp_key, stat.S_IRUSR)

            cmd = [
                "ssh", "-i", tmp_key, "-o", "StrictHostKeyChecking=no",
                f"root@{host_ip}",
                f"stdbuf -oL bash /opt/jarvis-os-infra/scripts/backup/backup-all.sh --layer {layer} 2>&1"
            ]

            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(proc.stdout.readline, ''):
                line = line.rstrip()
                if not line:
                    continue
                yield f"data: {json.dumps({'type': 'log', 'line': line})}\n\n"

            proc.wait()
            os.unlink(tmp_key)

            success = proc.returncode == 0
            _backup_status["last_result"] = "ok" if success else "error"
            yield f"data: {json.dumps({'type': 'done', 'success': success, 'returncode': proc.returncode})}\n\n"
        except Exception as e:
            _backup_status["last_result"] = "error"
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        finally:
            _backup_status["running"] = False

    return StreamingResponse(stream_backup(), media_type="text/event-stream")


@app.get("/admin/backup/status")
async def admin_backup_status(_: None = Depends(require_admin)):
    """Letzter Backup-Status."""
    return _backup_status


@app.get("/admin/backup/usb-status")
async def admin_backup_usb_status(_: None = Depends(require_admin)):
    """
    Prüft ob der Backup-USB eingesteckt und die Partition entsperrt/gemountet ist.
    Führt blkid + df auf dem Proxmox-Host via SSH aus.
    """
    from proxmox_client import ProxmoxClient
    proxmox = ProxmoxClient()

    check_script = (
        'DEV=$(blkid -L "Backup" 2>/dev/null || true); '
        'if [ -n "$DEV" ]; then '
        '  echo "DEVICE:$DEV"; '
        '  DISK=$(echo "$DEV" | sed "s/[0-9]*$//"); '
        '  VENDOR=$(udevadm info --query=property "$DISK" 2>/dev/null | grep "^ID_VENDOR=" | cut -d= -f2 | xargs); '
        '  MODEL=$(udevadm info --query=property "$DISK" 2>/dev/null | grep "^ID_MODEL=" | cut -d= -f2 | sed "s/_/ /g" | xargs); '
        '  echo "VENDOR:${VENDOR:-unknown}"; '
        '  echo "MODEL:${MODEL:-unknown}"; '
        '  TOP_MOUNT=$(findmnt -n -o SOURCE /mnt/backup-usb 2>/dev/null | tail -1); '
        '  if [ "$TOP_MOUNT" = "$DEV" ]; then '
        '    echo "MOUNTED:yes"; '
        '    df -B1 /mnt/backup-usb 2>/dev/null | tail -1 | awk \'{print "SPACE:" $2 ":" $3 ":" $4}\'; '
        '  elif [ -n "$TOP_MOUNT" ]; then '
        '    echo "REMOUNT:stale $TOP_MOUNT -> $DEV"; '
        '    umount -l /mnt/backup-usb 2>/dev/null; '
        '    mkdir -p /mnt/backup-usb; '
        '    mount "$DEV" /mnt/backup-usb; '
        '    if mountpoint -q /mnt/backup-usb 2>/dev/null; then '
        '      echo "MOUNTED:yes"; '
        '      echo "REMOUNTED:true"; '
        '      df -B1 /mnt/backup-usb 2>/dev/null | tail -1 | awk \'{print "SPACE:" $2 ":" $3 ":" $4}\'; '
        '    else '
        '      echo "MOUNTED:stale:$TOP_MOUNT"; '
        '    fi; '
        '  else '
        '    mkdir -p /mnt/backup-usb; '
        '    mount "$DEV" /mnt/backup-usb 2>/dev/null; '
        '    if mountpoint -q /mnt/backup-usb 2>/dev/null; then '
        '      echo "MOUNTED:yes"; '
        '      echo "REMOUNTED:true"; '
        '      df -B1 /mnt/backup-usb 2>/dev/null | tail -1 | awk \'{print "SPACE:" $2 ":" $3 ":" $4}\'; '
        '    else '
        '      echo "MOUNTED:no"; '
        '    fi; '
        '  fi; '
        'else '
        # Fallback: USB-Gerät physisch verbunden aber Partition gesperrt (z.B. Fingerprint-USB)
        '  USB_HW=$(lsusb 2>/dev/null | grep -iE "Lexar|JumpDrive|F35|SanDisk|Kingston" | head -1); '
        '  if [ -n "$USB_HW" ]; then '
        '    echo "DEVICE:locked"; '
        '    USB_DESC=$(echo "$USB_HW" | sed "s/.*: ID [0-9a-f:]* //"); '
        '    HW_VENDOR=$(echo "$USB_DESC" | awk "{print \\$1}"); '
        '    HW_MODEL=$(echo "$USB_DESC" | sed "s/^[^ ]* //" | sed "s/^${HW_VENDOR} //"); '
        '    echo "VENDOR:${HW_VENDOR:-unknown}"; '
        '    echo "MODEL:${HW_MODEL:-unknown}"; '
        '    echo "MOUNTED:locked"; '
        '  else '
        '    echo "DEVICE:none"; '
        '  fi; '
        'fi'
    )

    try:
        result = proxmox._ssh_run(check_script, timeout=15)
        lines = result.stdout.strip().splitlines()

        status = {
            "connected": False,
            "mounted": False,
            "locked": False,
            "remounted": False,
            "stale_mount": None,
            "device": None,
            "vendor": None,
            "model": None,
            "label": "Backup",
            "total_gb": 0,
            "used_gb": 0,
            "free_gb": 0,
        }

        for line in lines:
            if line.startswith("DEVICE:") and line != "DEVICE:none":
                status["connected"] = True
                if line == "DEVICE:locked":
                    status["locked"] = True
                else:
                    status["device"] = line.split(":", 1)[1]
            elif line.startswith("VENDOR:"):
                v = line.split(":", 1)[1]
                if v != "unknown":
                    status["vendor"] = v
            elif line.startswith("MODEL:"):
                m = line.split(":", 1)[1]
                if m != "unknown":
                    status["model"] = m
            elif line.startswith("MOUNTED:yes"):
                status["mounted"] = True
            elif line.startswith("MOUNTED:locked"):
                pass  # locked-Zustand bereits über DEVICE:locked gesetzt
            elif line.startswith("MOUNTED:stale:"):
                status["stale_mount"] = line.split(":", 2)[2]
            elif line.startswith("REMOUNTED:true"):
                status["remounted"] = True
            elif line.startswith("SPACE:"):
                parts = line.split(":")
                if len(parts) >= 4:
                    try:
                        status["total_gb"] = round(int(parts[1]) / (1024**3), 1)
                        status["used_gb"] = round(int(parts[2]) / (1024**3), 1)
                        status["free_gb"] = round(int(parts[3]) / (1024**3), 1)
                    except ValueError:
                        pass

        return status
    except Exception as e:
        logger.warning(f"USB-Status-Check fehlgeschlagen: {e}")
        return {"connected": False, "mounted": False, "device": None,
                "label": "Backup", "total_gb": 0, "used_gb": 0, "free_gb": 0,
                "error": str(e)}


@app.get("/admin/backup/usb-contents")
async def admin_backup_usb_contents(_: None = Depends(require_admin)):
    """
    Listet Backup-Inhalte auf dem USB-Stick auf:
    - configs/ (Layer 1): Anzahl Tage, Gesamtgröße
    - dump/ (Layer 2): Anzahl Dateien pro LXC/VM, Gesamtgröße
    - appdata/ (Layer 3): Anzahl Tage, Gesamtgröße
    Gibt auch die Retention-Einstellungen aus backup.conf zurück.
    """
    from proxmox_client import ProxmoxClient
    proxmox = ProxmoxClient()

    scan_script = (
        'source /opt/jarvis-os/config/backup.conf 2>/dev/null; '
        'BASE="${BACKUP_BASE_DIR_USB:-/mnt/backup-usb/jarvis-os-backups}"; '
        'echo "RETENTION_CONFIG:${RETENTION_CONFIG_DAYS:-30}"; '
        'echo "RETENTION_VZDUMP:${RETENTION_VZDUMP_COUNT:-3}"; '
        'echo "RETENTION_APPDATA:${RETENTION_APPDATA_DAYS:-14}"; '
        # configs: Datum-Verzeichnisse zählen + Größe
        'if [ -d "$BASE/configs" ]; then '
        '  CCOUNT=$(find "$BASE/configs" -maxdepth 1 -mindepth 1 -type d | wc -l); '
        '  CSIZE=$(du -sb "$BASE/configs" 2>/dev/null | cut -f1); '
        '  COLDEST=$(find "$BASE/configs" -maxdepth 1 -mindepth 1 -type d -name "????-??-??" | sort | head -1 | xargs basename 2>/dev/null); '
        '  echo "CONFIGS:$CCOUNT:$CSIZE:$COLDEST"; '
        'else echo "CONFIGS:0:0:"; fi; '
        # dump: vzdump-Dateien nach VMID gruppieren
        'if [ -d "$BASE/dump" ]; then '
        '  DSIZE=$(du -sb "$BASE/dump" 2>/dev/null | cut -f1); '
        '  DCOUNT=$(find "$BASE/dump" -name "vzdump-*.zst" 2>/dev/null | wc -l); '
        '  echo "DUMP:$DCOUNT:$DSIZE"; '
        # Pro VMID: Typ, ID, Anzahl, Größe
        '  for F in $(find "$BASE/dump" -name "vzdump-*.zst" 2>/dev/null '
        '    | sed "s/.*vzdump-\\([a-z]*\\)-\\([0-9]*\\)-.*/\\1:\\2/" | sort -u); do '
        '    VMTYPE=$(echo "$F" | cut -d: -f1); VMID=$(echo "$F" | cut -d: -f2); '
        '    EXT="tar.zst"; [ "$VMTYPE" = "qemu" ] && EXT="vma.zst"; '
        '    VFILES=$(ls -1 "$BASE/dump/vzdump-${VMTYPE}-${VMID}-"*.${EXT} 2>/dev/null); '
        '    VCOUNT=$(echo "$VFILES" | grep -c . 2>/dev/null); '
        '    VSIZE=$(echo "$VFILES" | xargs du -cb 2>/dev/null | tail -1 | cut -f1); '
        '    echo "DUMP_VM:${VMTYPE}:${VMID}:${VCOUNT}:${VSIZE}"; '
        '  done; '
        'else echo "DUMP:0:0"; fi; '
        # appdata: Datum-Verzeichnisse zählen + Größe
        'if [ -d "$BASE/appdata" ]; then '
        '  ACOUNT=$(find "$BASE/appdata" -maxdepth 1 -mindepth 1 -type d | wc -l); '
        '  ASIZE=$(du -sb "$BASE/appdata" 2>/dev/null | cut -f1); '
        '  AOLDEST=$(find "$BASE/appdata" -maxdepth 1 -mindepth 1 -type d -name "????-??-??" | sort | head -1 | xargs basename 2>/dev/null); '
        '  echo "APPDATA:$ACOUNT:$ASIZE:$AOLDEST"; '
        'else echo "APPDATA:0:0:"; fi'
    )

    try:
        result = proxmox._ssh_run(scan_script, timeout=30)
        lines = result.stdout.strip().splitlines()

        contents = {
            "retention": {"config_days": 30, "vzdump_count": 3, "appdata_days": 14},
            "configs": {"count": 0, "size_bytes": 0, "oldest": None},
            "dump": {"count": 0, "size_bytes": 0, "vms": []},
            "appdata": {"count": 0, "size_bytes": 0, "oldest": None},
        }

        for line in lines:
            if line.startswith("RETENTION_CONFIG:"):
                contents["retention"]["config_days"] = int(line.split(":")[1])
            elif line.startswith("RETENTION_VZDUMP:"):
                contents["retention"]["vzdump_count"] = int(line.split(":")[1])
            elif line.startswith("RETENTION_APPDATA:"):
                contents["retention"]["appdata_days"] = int(line.split(":")[1])
            elif line.startswith("CONFIGS:"):
                parts = line.split(":")
                contents["configs"]["count"] = int(parts[1])
                contents["configs"]["size_bytes"] = int(parts[2]) if parts[2] else 0
                contents["configs"]["oldest"] = parts[3] if len(parts) > 3 and parts[3] else None
            elif line.startswith("DUMP:"):
                parts = line.split(":")
                contents["dump"]["count"] = int(parts[1])
                contents["dump"]["size_bytes"] = int(parts[2]) if parts[2] else 0
            elif line.startswith("DUMP_VM:"):
                parts = line.split(":")
                contents["dump"]["vms"].append({
                    "type": parts[1],        # lxc | qemu
                    "vmid": int(parts[2]),
                    "backups": int(parts[3]),
                    "size_bytes": int(parts[4]) if parts[4] else 0,
                })
            elif line.startswith("APPDATA:"):
                parts = line.split(":")
                contents["appdata"]["count"] = int(parts[1])
                contents["appdata"]["size_bytes"] = int(parts[2]) if parts[2] else 0
                contents["appdata"]["oldest"] = parts[3] if len(parts) > 3 and parts[3] else None

        return contents
    except Exception as e:
        logger.warning(f"USB-Contents-Scan fehlgeschlagen: {e}")
        raise HTTPException(500, detail=f"USB-Scan fehlgeschlagen: {e}")


@app.post("/admin/backup/usb-cleanup")
async def admin_backup_usb_cleanup(
    _: None = Depends(require_admin),
):
    """
    Führt Retention-Bereinigung auf dem USB-Stick aus:
    - configs: älter als RETENTION_CONFIG_DAYS löschen
    - dump: mehr als RETENTION_VZDUMP_COUNT pro LXC/VM löschen
    - appdata: älter als RETENTION_APPDATA_DAYS löschen
    Gibt SSE-Stream mit Live-Fortschritt zurück.
    """
    from proxmox_client import ProxmoxClient
    proxmox = ProxmoxClient()

    cleanup_script = r'''
source /opt/jarvis-os/config/backup.conf 2>/dev/null
BASE="${BACKUP_BASE_DIR_USB:-/mnt/backup-usb/jarvis-os-backups}"

# Vorher-Größe
BEFORE=$(du -sb "$BASE" 2>/dev/null | cut -f1)
echo "STATUS:start:$BEFORE"

# ── Layer 1: Configs — älter als RETENTION_CONFIG_DAYS ──
echo "LAYER:1:configs"
if [ -d "$BASE/configs" ]; then
  DELETED=0
  find "$BASE/configs/" -maxdepth 2 -name "*.tar.gz*" \
    -mtime "+${RETENTION_CONFIG_DAYS:-30}" 2>/dev/null | while read -r F; do
    SIZE=$(stat -c%s "$F" 2>/dev/null || echo 0)
    rm -f "$F"
    echo "DELETE:configs:$(basename "$F"):$SIZE"
  done
  find "$BASE/configs/" -maxdepth 1 -mindepth 1 -type d \
    -empty -delete 2>/dev/null || true
  echo "DONE:configs"
else
  echo "SKIP:configs:Verzeichnis nicht vorhanden"
fi

# ── Layer 2: Dump — nur letzte RETENTION_VZDUMP_COUNT behalten ──
echo "LAYER:2:dump"
if [ -d "$BASE/dump" ]; then
  RETENTION="${RETENTION_VZDUMP_COUNT:-3}"
  for VMTYPE in lxc qemu; do
    EXT="tar.zst"; [ "$VMTYPE" = "qemu" ] && EXT="vma.zst"
    for VMID in $(find "$BASE/dump" -name "vzdump-${VMTYPE}-*-*.${EXT}" 2>/dev/null \
        | sed "s/.*vzdump-[a-z]*-\([0-9]*\)-.*/\1/" | sort -u); do
      BACKUPS=$(ls -t "$BASE/dump/vzdump-${VMTYPE}-${VMID}-"*.${EXT} 2>/dev/null)
      COUNT=$(echo "$BACKUPS" | wc -l)
      if [ "$COUNT" -gt "$RETENTION" ]; then
        echo "$BACKUPS" | tail -n "+$((RETENTION + 1))" | while read -r OLD; do
          SIZE=$(stat -c%s "$OLD" 2>/dev/null || echo 0)
          rm -f "$OLD"
          rm -f "${OLD%.${EXT}}.log"
          echo "DELETE:dump:$(basename "$OLD"):$SIZE"
        done
      fi
    done
  done
  # Alte Manifeste aufräumen (älter als 30 Tage)
  find "$BASE/dump" -name "manifest-*.sha256" -mtime +30 -delete 2>/dev/null || true
  echo "DONE:dump"
else
  echo "SKIP:dump:Verzeichnis nicht vorhanden"
fi

# ── Layer 3: Appdata — älter als RETENTION_APPDATA_DAYS ──
echo "LAYER:3:appdata"
if [ -d "$BASE/appdata" ]; then
  RETENTION_DAYS="${RETENTION_APPDATA_DAYS:-14}"
  find "$BASE/appdata/" -maxdepth 1 -mindepth 1 -type d \
    -name "????-??-??" | sort | head -n "-${RETENTION_DAYS}" | while read -r OLD_DIR; do
    SIZE=$(du -sb "$OLD_DIR" 2>/dev/null | cut -f1)
    rm -rf "$OLD_DIR"
    echo "DELETE:appdata:$(basename "$OLD_DIR"):${SIZE:-0}"
  done
  echo "DONE:appdata"
else
  echo "SKIP:appdata:Verzeichnis nicht vorhanden"
fi

# Nachher-Größe
AFTER=$(du -sb "$BASE" 2>/dev/null | cut -f1)
echo "STATUS:done:$BEFORE:$AFTER"
'''

    async def stream_cleanup():
        import subprocess, tempfile, shutil, stat as stat_mod

        ssh_key_path = os.getenv("PROXMOX_SSH_KEY", "/app/proxmox_key")
        host = os.getenv("PROXMOX_HOST", "https://192.168.10.147:8006")
        host_ip = host.replace("https://", "").replace("http://", "").split(":")[0]

        tmp_key = tempfile.mktemp(prefix="cleanup_key_")
        shutil.copy2(ssh_key_path, tmp_key)
        os.chmod(tmp_key, stat_mod.S_IRUSR)

        try:
            yield f"data: {json.dumps({'type': 'start'})}\n\n"

            cmd = [
                "ssh", "-i", tmp_key, "-o", "StrictHostKeyChecking=no",
                f"root@{host_ip}",
                cleanup_script
            ]

            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )

            deleted_total = 0
            freed_bytes = 0

            for line in proc.stdout:
                line = line.rstrip()
                if line.startswith("STATUS:start:"):
                    yield f"data: {json.dumps({'type': 'log', 'line': 'Aufräumen gestartet...'})}\n\n"
                elif line.startswith("LAYER:"):
                    parts = line.split(":")
                    yield f"data: {json.dumps({'type': 'layer', 'layer': parts[1], 'name': parts[2]})}\n\n"
                    yield f"data: {json.dumps({'type': 'log', 'line': f'Layer {parts[1]}: {parts[2]} bereinigen...'})}\n\n"
                elif line.startswith("DELETE:"):
                    parts = line.split(":")
                    size = int(parts[3]) if len(parts) > 3 and parts[3] else 0
                    freed_bytes += size
                    deleted_total += 1
                    size_mb = round(size / (1024**2), 1)
                    yield f"data: {json.dumps({'type': 'delete', 'category': parts[1], 'file': parts[2], 'size_bytes': size, 'line': f'  ✗ {parts[2]} ({size_mb} MB)'})}\n\n"
                elif line.startswith("DONE:"):
                    cat = line.split(":")[1]
                    yield f"data: {json.dumps({'type': 'log', 'line': f'  ✓ {cat} bereinigt'})}\n\n"
                elif line.startswith("SKIP:"):
                    parts = line.split(":", 2)
                    yield f"data: {json.dumps({'type': 'log', 'line': f'  ⊘ {parts[1]}: {parts[2]}'})}\n\n"
                elif line.startswith("STATUS:done:"):
                    parts = line.split(":")
                    before = int(parts[2]) if parts[2] else 0
                    after = int(parts[3]) if len(parts) > 3 and parts[3] else 0
                    freed_bytes = before - after
                    freed_mb = round(freed_bytes / (1024**2), 1)
                    freed_gb = round(freed_bytes / (1024**3), 2)
                    yield f"data: {json.dumps({'type': 'done', 'success': True, 'deleted': deleted_total, 'freed_bytes': freed_bytes, 'freed_mb': freed_mb, 'freed_gb': freed_gb})}\n\n"

            proc.wait()
            if proc.returncode != 0:
                yield f"data: {json.dumps({'type': 'error', 'message': f'Script exit code: {proc.returncode}'})}\n\n"

        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        finally:
            os.unlink(tmp_key)

    return StreamingResponse(stream_cleanup(), media_type="text/event-stream")


# ---------------------------------------------------------------------------
# OIDC / Authentik SSO — Admin-Dashboard Login
# ---------------------------------------------------------------------------
import urllib.parse as _urlparse
import urllib.request as _urlreq
import urllib.error as _urlerr

OIDC_CLIENT_ID     = os.getenv("OIDC_CLIENT_ID", "")
OIDC_CLIENT_SECRET = os.getenv("OIDC_CLIENT_SECRET", "")
OIDC_ISSUER        = os.getenv("OIDC_ISSUER", "")   # z.B. http://192.168.10.125:9000/application/o/jarvis-admin/

# Authentik-Base aus Issuer ableiten (alles vor /application/o/)
_authentik_base = OIDC_ISSUER.split("/application/o/")[0] if "/application/o/" in OIDC_ISSUER else ""
_OIDC_AUTH_URL   = f"{_authentik_base}/application/o/authorize/"
_OIDC_TOKEN_URL  = f"{_authentik_base}/application/o/token/"

# CSRF-State-Store (kurzlebig, 10 Minuten)
_oidc_states: dict[str, float] = {}   # state → expires_ts


def _get_origin(request: Request) -> str:
    """Leitet die Origin-URL aus dem Request ab (Proxy-aware via X-Forwarded-*)."""
    proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host", request.headers.get("host", ""))
    if host:
        return f"{proto}://{host}"
    return BRIDGE_URL


@app.get("/auth/login")
async def auth_login(request: Request):
    """Startet den OIDC-Login-Flow → redirect zu Authentik."""
    if not OIDC_CLIENT_ID or not _authentik_base:
        raise HTTPException(501, detail="OIDC nicht konfiguriert (OIDC_CLIENT_ID fehlt)")
    import secrets as _sec
    origin = _get_origin(request)
    state = _sec.token_urlsafe(24)
    _oidc_states[state] = (time.time() + 600, origin)   # 10 min gültig + origin merken
    params = _urlparse.urlencode({
        "response_type": "code",
        "client_id":     OIDC_CLIENT_ID,
        "redirect_uri":  f"{origin}/auth/callback",
        "scope":         "openid email profile",
        "state":         state,
    })
    return RedirectResponse(f"{_OIDC_AUTH_URL}?{params}")


@app.get("/auth/callback")
async def auth_callback(request: Request, code: str = Query(...), state: str = Query(...)):
    """OIDC-Callback: tauscht Code gegen Token, setzt Session-Cookie."""
    # CSRF-State validieren (state enthält jetzt (expires, origin))
    entry = _oidc_states.pop(state, None)
    if not entry:
        raise HTTPException(400, detail="Ungültiger oder abgelaufener OIDC-State")
    expires, origin = entry if isinstance(entry, tuple) else (entry, BRIDGE_URL)
    if time.time() > expires:
        raise HTTPException(400, detail="OIDC-State abgelaufen")

    # Code gegen Token tauschen
    token_body = _urlparse.urlencode({
        "grant_type":    "authorization_code",
        "code":          code,
        "redirect_uri":  f"{origin}/auth/callback",
        "client_id":     OIDC_CLIENT_ID,
        "client_secret": OIDC_CLIENT_SECRET,
    }).encode()
    req = _urlreq.Request(
        _OIDC_TOKEN_URL,
        data=token_body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with _urlreq.urlopen(req, timeout=10) as resp:
            tokens = json.loads(resp.read())
    except _urlerr.HTTPError as e:
        raise HTTPException(502, detail=f"Token-Exchange fehlgeschlagen: {e.code}")

    access_token = tokens.get("access_token", "")
    if not access_token:
        raise HTTPException(502, detail="Kein access_token erhalten")

    # Username aus Userinfo holen
    ui_req = _urlreq.Request(
        f"{_authentik_base}/application/o/userinfo/",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    try:
        with _urlreq.urlopen(ui_req, timeout=10) as resp:
            userinfo = json.loads(resp.read())
    except _urlerr.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise HTTPException(502, detail=f"Userinfo HTTP {e.code}: {body[:200]}")
    except Exception as e:
        raise HTTPException(502, detail=f"Userinfo-Fehler: {type(e).__name__}: {e}")

    username = userinfo.get("preferred_username") or userinfo.get("sub", "unknown")

    # Admin-Status prüfen: akadmin ODER in jarvis-admins Gruppe
    is_admin = False
    try:
        import authentik_client as _ak
        if _ak._enabled():
            result = _ak._request("GET", f"/core/users/?username={_urlparse.quote(username)}")
            users_list = result.get("results", [])
            if users_list:
                user_pk = users_list[0]["pk"]
                groups  = _ak._request("GET", f"/core/users/{user_pk}/")
                user_groups = [g.get("name", "") for g in groups.get("groups_obj", [])]
                is_admin = username == "akadmin" or "jarvis-admins" in user_groups
    except Exception:
        # Fallback: nur akadmin darf rein
        is_admin = (username == "akadmin")

    if not is_admin:
        raise HTTPException(403, detail=f"User '{username}' hat keine Admin-Rechte")

    # Session anlegen + Cookie setzen
    from auth import create_oidc_session
    sid = create_oidc_session(username, is_admin=True)
    response = RedirectResponse("/static/admin.html", status_code=302)
    response.set_cookie(
        "oidc_session", sid,
        httponly=True, samesite="lax", max_age=8 * 3600,
    )
    logger.info(f"OIDC Login: '{username}' → Session {sid[:8]}…")
    return response


@app.get("/auth/me")
async def auth_me(request: Request):
    """Gibt aktuelle OIDC-Session-Info zurück (für JS-Auth-Check)."""
    from auth import get_oidc_session
    sid = request.cookies.get("oidc_session")
    if not sid:
        return {"authenticated": False}
    s = get_oidc_session(sid)
    if not s:
        return {"authenticated": False}
    return {"authenticated": True, "username": s["username"], "is_admin": s["is_admin"]}


@app.get("/auth/logout")
async def auth_logout(request: Request):
    """Löscht OIDC-Session und leitet zur Admin-Seite zurück."""
    from auth import delete_oidc_session
    sid = request.cookies.get("oidc_session")
    if sid:
        delete_oidc_session(sid)
    response = RedirectResponse("/static/admin.html", status_code=302)
    response.delete_cookie("oidc_session")
    return response


# ---------------------------------------------------------------------------
# WebAuthn / YubiKey MFA — Admin-Dashboard
# ---------------------------------------------------------------------------
WEBAUTHN_ENABLED = os.getenv("WEBAUTHN_ENABLED", "false").lower() == "true"
WEBAUTHN_RP_ID   = os.getenv("WEBAUTHN_RP_ID", "localhost")
WEBAUTHN_RP_NAME = os.getenv("WEBAUTHN_RP_NAME", "J.A.R.V.I.S-OS Admin")

# In-Memory Challenge-Store (kurzlebig, 5 Minuten)
_wn_challenges: dict[str, tuple[bytes, float]] = {}   # handle → (challenge, expires)

def _wn_db():
    """SQLite-Connection für WebAuthn-Credentials (in /data/apps.db)."""
    from lxc_manager import _get_db
    conn = _get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS webauthn_credentials (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_handle TEXT    NOT NULL,
            credential_id BLOB  NOT NULL UNIQUE,
            public_key  BLOB    NOT NULL,
            sign_count  INTEGER NOT NULL DEFAULT 0,
            aaguid      TEXT    DEFAULT NULL,
            device_name TEXT    DEFAULT NULL,
            created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    # Migration: aaguid + device_name Spalten hinzufügen (falls Tabelle schon existiert)
    try:
        conn.execute("ALTER TABLE webauthn_credentials ADD COLUMN aaguid TEXT DEFAULT NULL")
    except Exception:
        pass
    try:
        conn.execute("ALTER TABLE webauthn_credentials ADD COLUMN device_name TEXT DEFAULT NULL")
    except Exception:
        pass
    conn.commit()
    return conn


# AAGUID → Hersteller/Modell-Zuordnung (bekannte Security Keys)
_AAGUID_DB: dict[str, dict] = {
    # ── YubiKey 5 Series (USB-A) ──
    "cb69481e-8ff7-4039-93ec-0a2729a154a8": {"vendor": "Yubico", "model": "YubiKey 5 NFC"},
    "2fc0579f-8113-47ea-b116-bb5a8db9202a": {"vendor": "Yubico", "model": "YubiKey 5 NFC"},
    "d7781e5d-e353-46aa-afe2-3ca49f13332a": {"vendor": "Yubico", "model": "YubiKey 5 NFC"},
    "ee882879-721c-4913-9775-3dfcce97072a": {"vendor": "Yubico", "model": "YubiKey 5 Nano"},
    "fa2b99dc-9e39-4257-8f92-4a30d23c4118": {"vendor": "Yubico", "model": "YubiKey 5 NFC FIPS"},
    "73bb0cd4-e502-49b8-9c6f-b59445bf720b": {"vendor": "Yubico", "model": "YubiKey 5Ci FIPS"},
    # ── YubiKey 5 Series (USB-C) ──
    "b92c3f9a-c014-4056-887f-140a2501163b": {"vendor": "Yubico", "model": "YubiKey 5C NFC"},
    "85203421-48f9-4355-9bc8-8a53846e5083": {"vendor": "Yubico", "model": "YubiKey 5C Nano"},
    "c5ef55ff-ad9a-4b9f-b580-adebafe026d0": {"vendor": "Yubico", "model": "YubiKey 5Ci"},
    "a4e9fc6d-4cbe-4758-b8ba-37598bb5bbaa": {"vendor": "Yubico", "model": "YubiKey 5C"},
    # ── YubiKey Bio ──
    "d8522d9f-575b-4866-88a9-ba99fa02f35b": {"vendor": "Yubico", "model": "YubiKey Bio"},
    "83c47309-aabb-4108-8470-8be838b573cb": {"vendor": "Yubico", "model": "YubiKey Bio FIDO"},
    # ── Security Key by Yubico ──
    "f8a011f3-8c0a-4d15-8006-17111f9edc7d": {"vendor": "Yubico", "model": "Security Key NFC"},
    "6d44ba9b-f6ec-2e49-b930-0c8fe920cb73": {"vendor": "Yubico", "model": "Security Key"},
    "149a2021-8ef6-4133-96b8-81f8d5b7f1f5": {"vendor": "Yubico", "model": "Security Key NFC"},
    # ── Google Titan ──
    "42b4fb4a-2866-43b2-9bf7-6c6669c2e5d3": {"vendor": "Google", "model": "Titan Security Key"},
    # ── Feitian ──
    "3e22415d-7fdf-4ea4-8a0c-dd60c4249b9d": {"vendor": "Feitian", "model": "BioPass FIDO2"},
    "77010bd7-212a-4fc9-b236-d2ca5e9d4084": {"vendor": "Feitian", "model": "ePass FIDO2"},
    # ── SoloKeys ──
    "8876631b-d4a0-427f-5773-0ec71c9e0279": {"vendor": "SoloKeys", "model": "Solo 2"},
    # ── Nitrokey ──
    "2c0df832-92de-4be1-8412-88a8f074df4a": {"vendor": "Nitrokey", "model": "Nitrokey 3"},
}


def _resolve_aaguid(aaguid_hex: str) -> dict:
    """Löst AAGUID zu Vendor/Model auf. Fallback: 'Security Key'."""
    info = _AAGUID_DB.get(aaguid_hex)
    if info:
        return info
    return {"vendor": "Unknown", "model": "Security Key"}


@app.get("/auth/webauthn/enabled")
async def webauthn_status():
    """Gibt zurück ob WebAuthn aktiviert ist."""
    return {"enabled": WEBAUTHN_ENABLED}


@app.post("/auth/webauthn/register/begin")
async def webauthn_register_begin(_: None = Depends(require_admin)):
    """Startet WebAuthn-Registrierung: gibt PublicKeyCredentialCreationOptions zurück."""
    if not WEBAUTHN_ENABLED:
        raise HTTPException(501, detail="WebAuthn nicht aktiviert (WEBAUTHN_ENABLED=false)")
    try:
        from fido2.server import Fido2Server
        from fido2.webauthn import PublicKeyCredentialRpEntity, PublicKeyCredentialUserEntity
        from fido2 import cbor
        import base64

        rp = PublicKeyCredentialRpEntity(id=WEBAUTHN_RP_ID, name=WEBAUTHN_RP_NAME)
        server = Fido2Server(rp, attestation="direct")

        conn = _wn_db()
        existing = conn.execute(
            "SELECT credential_id FROM webauthn_credentials WHERE user_handle='admin'"
        ).fetchall()
        existing_creds = [row["credential_id"] for row in existing] if existing else []

        user = PublicKeyCredentialUserEntity(
            id=b"admin",
            name="admin",
            display_name="J.A.R.V.I.S-OS Admin",
        )
        options, state = server.register_begin(
            user,
            credentials=existing_creds,
            user_verification="discouraged",
            authenticator_attachment="cross-platform",
        )

        import secrets as _sec
        handle = _sec.token_hex(16)
        _wn_challenges[handle] = (state, time.time() + 300)

        # options als JSON-serialisierbares Dict aufbereiten
        opts_dict = options.to_dict() if hasattr(options, "to_dict") else dict(options)
        return {"options": opts_dict, "handle": handle}
    except ImportError:
        raise HTTPException(501, detail="fido2-Bibliothek nicht installiert")


@app.post("/auth/webauthn/register/complete")
async def webauthn_register_complete(
    body: dict,
    _: None = Depends(require_admin),
):
    """Schließt WebAuthn-Registrierung ab und speichert den Credential."""
    if not WEBAUTHN_ENABLED:
        raise HTTPException(501, detail="WebAuthn nicht aktiviert")
    try:
        from fido2.server import Fido2Server
        from fido2.webauthn import (
            PublicKeyCredentialRpEntity,
            AuthenticatorAttestationResponse,
            RegistrationResponse,
        )
        import base64

        handle = body.get("handle", "")
        entry = _wn_challenges.pop(handle, None)
        if not entry or time.time() > entry[1]:
            raise HTTPException(400, detail="Challenge abgelaufen oder ungültig")
        state = entry[0]

        rp = PublicKeyCredentialRpEntity(id=WEBAUTHN_RP_ID, name=WEBAUTHN_RP_NAME)
        server = Fido2Server(rp)

        credential_data = body.get("credential", {})
        auth_response = RegistrationResponse.from_dict(credential_data)
        auth_data = server.register_complete(state, auth_response)

        # fido2 2.x: credential_data enthält aaguid, credential_id, public_key
        cred_data = auth_data.credential_data

        # AAGUID extrahieren (identifiziert das Key-Modell)
        aaguid_hex = None
        device_name = None
        try:
            aaguid_bytes = cred_data.aaguid
            aaguid_hex = "-".join([
                aaguid_bytes[:4].hex(),
                aaguid_bytes[4:6].hex(),
                aaguid_bytes[6:8].hex(),
                aaguid_bytes[8:10].hex(),
                aaguid_bytes[10:].hex(),
            ])
            resolved = _resolve_aaguid(aaguid_hex)
            device_name = f"{resolved['vendor']} {resolved['model']}"
            logger.info(f"WebAuthn: AAGUID={aaguid_hex} → {device_name}")
        except Exception as e:
            logger.warning(f"WebAuthn: AAGUID-Extraktion fehlgeschlagen: {e}")

        conn = _wn_db()
        conn.execute(
            "INSERT OR REPLACE INTO webauthn_credentials "
            "(user_handle, credential_id, public_key, sign_count, aaguid, device_name) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                "admin",
                bytes(cred_data.credential_id),
                bytes(cred_data),
                getattr(auth_data, 'counter', 0),
                aaguid_hex,
                device_name,
            ),
        )
        conn.commit()
        logger.info(f"WebAuthn: Neuer Credential registriert für 'admin' ({device_name or 'unbekannt'})")
        return {"success": True, "device_name": device_name}
    except ImportError:
        raise HTTPException(501, detail="fido2-Bibliothek nicht installiert")
    except Exception as e:
        raise HTTPException(400, detail=f"Registrierung fehlgeschlagen: {e}")


@app.post("/auth/webauthn/authenticate/begin")
async def webauthn_authenticate_begin():
    """Startet WebAuthn-Authentifizierung: gibt PublicKeyCredentialRequestOptions zurück."""
    if not WEBAUTHN_ENABLED:
        raise HTTPException(501, detail="WebAuthn nicht aktiviert")
    try:
        from fido2.server import Fido2Server
        from fido2.webauthn import PublicKeyCredentialRpEntity

        rp = PublicKeyCredentialRpEntity(id=WEBAUTHN_RP_ID, name=WEBAUTHN_RP_NAME)
        server = Fido2Server(rp)

        conn = _wn_db()
        creds = conn.execute(
            "SELECT credential_id, public_key, sign_count FROM webauthn_credentials "
            "WHERE user_handle='admin'"
        ).fetchall()
        if not creds:
            raise HTTPException(404, detail="Kein YubiKey registriert")

        from fido2.webauthn import AttestedCredentialData
        credential_list = [
            AttestedCredentialData(row["public_key"])
            for row in creds
        ]

        options, state = server.authenticate_begin(
            credentials=credential_list,
            user_verification="discouraged",
        )

        import secrets as _sec
        handle = _sec.token_hex(16)
        _wn_challenges[handle] = (state, time.time() + 300)

        opts_dict = options.to_dict() if hasattr(options, "to_dict") else dict(options)
        return {"options": opts_dict, "handle": handle}
    except ImportError:
        raise HTTPException(501, detail="fido2-Bibliothek nicht installiert")


@app.post("/auth/webauthn/authenticate/complete")
async def webauthn_authenticate_complete(body: dict):
    """Schließt WebAuthn-Authentifizierung ab, setzt Session-Cookie bei Erfolg."""
    if not WEBAUTHN_ENABLED:
        raise HTTPException(501, detail="WebAuthn nicht aktiviert")
    try:
        from fido2.server import Fido2Server
        from fido2.webauthn import (
            PublicKeyCredentialRpEntity,
            AuthenticationResponse,
            AttestedCredentialData,
        )

        handle = body.get("handle", "")
        entry = _wn_challenges.pop(handle, None)
        if not entry or time.time() > entry[1]:
            raise HTTPException(400, detail="Challenge abgelaufen oder ungültig")
        state = entry[0]

        rp = PublicKeyCredentialRpEntity(id=WEBAUTHN_RP_ID, name=WEBAUTHN_RP_NAME)
        server = Fido2Server(rp)

        conn = _wn_db()
        creds = conn.execute(
            "SELECT id, credential_id, public_key, sign_count FROM webauthn_credentials "
            "WHERE user_handle='admin'"
        ).fetchall()
        credential_list = [
            AttestedCredentialData(row["public_key"])
            for row in creds
        ]

        credential_data = body.get("credential", {})
        auth_response = AuthenticationResponse.from_dict(credential_data)
        auth_data = server.authenticate_complete(state, credential_list, auth_response)

        # sign_count aktualisieren (fido2 2.x: counter statt new_sign_count)
        new_count = getattr(auth_data, 'new_sign_count', None) or getattr(auth_data, 'counter', 0)
        # credential_id aus der Response extrahieren (nicht aus auth_data)
        resp_cred_id = auth_response.id if hasattr(auth_response, 'id') else None
        if resp_cred_id and new_count:
            conn.execute(
                "UPDATE webauthn_credentials SET sign_count=? WHERE credential_id=?",
                (new_count, bytes(resp_cred_id)),
            )
        elif new_count:
            # Fallback: alle Admin-Credentials updaten
            conn.execute(
                "UPDATE webauthn_credentials SET sign_count=? WHERE user_handle='admin'",
                (new_count,),
            )
        conn.commit()

        # Session anlegen
        from auth import create_oidc_session
        sid = create_oidc_session("admin", is_admin=True)
        response = JSONResponse({"success": True})
        response.set_cookie(
            "oidc_session", sid,
            httponly=True, samesite="lax", max_age=8 * 3600,
        )
        logger.info("WebAuthn: Admin erfolgreich authentifiziert via YubiKey")
        return response
    except ImportError:
        raise HTTPException(501, detail="fido2-Bibliothek nicht installiert")
    except Exception as e:
        raise HTTPException(401, detail=f"Authentifizierung fehlgeschlagen: {e}")


@app.get("/auth/webauthn/credentials")
async def webauthn_list_credentials(_: None = Depends(require_admin)):
    """Listet registrierte WebAuthn-Credentials."""
    conn = _wn_db()
    rows = conn.execute(
        "SELECT id, user_handle, sign_count, aaguid, device_name, created_at "
        "FROM webauthn_credentials WHERE user_handle='admin'"
    ).fetchall()
    creds = []
    for r in rows:
        d = dict(r)
        # Vendor/Model aus AAGUID auflösen (falls device_name fehlt)
        if not d.get("device_name") and d.get("aaguid"):
            resolved = _resolve_aaguid(d["aaguid"])
            d["device_name"] = f"{resolved['vendor']} {resolved['model']}"
            d["vendor"] = resolved["vendor"]
            d["model"] = resolved["model"]
        elif d.get("device_name"):
            parts = d["device_name"].split(" ", 1)
            d["vendor"] = parts[0] if parts else "Unknown"
            d["model"] = parts[1] if len(parts) > 1 else d["device_name"]
        else:
            d["vendor"] = "Unknown"
            d["model"] = "Security Key"
        creds.append(d)
    return {
        "count": len(creds),
        "credentials": creds,
    }


@app.delete("/auth/webauthn/credentials/{cred_id}")
async def webauthn_delete_credential(cred_id: int, _: None = Depends(require_admin)):
    """Löscht einen registrierten WebAuthn-Credential."""
    conn = _wn_db()
    result = conn.execute(
        "DELETE FROM webauthn_credentials WHERE id=? AND user_handle='admin'", (cred_id,)
    )
    conn.commit()
    if result.rowcount == 0:
        raise HTTPException(404, detail="Credential nicht gefunden")
    return {"success": True, "deleted_id": cred_id}


# ── Reverse-Proxy für User-Apps ──────────────────────────────────────────────

_proxy_client = httpx.AsyncClient(timeout=30.0, follow_redirects=False)


@app.api_route("/proxy/{app_id}/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
@app.api_route("/proxy/{app_id}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
async def reverse_proxy(app_id: str, request: Request, path: str = ""):
    """Leitet HTTP-Anfragen an User-Apps weiter (LXC-Subnetze nicht direkt erreichbar)."""
    # Auth: API-Key aus Query, Header oder Cookie
    api_key = (
        request.query_params.get("key")
        or request.headers.get("x-api-key")
        or request.cookies.get(f"proxy_key_{app_id}")
    )
    if not api_key:
        raise HTTPException(401, detail="API-Key erforderlich")

    from lxc_manager import _get_db
    conn = _get_db()

    user_row = conn.execute("SELECT user_id FROM users WHERE api_key=?", (api_key,)).fetchone()
    if not user_row:
        raise HTTPException(403, detail="Ungültiger API-Key")
    user_id = user_row["user_id"]

    # App-Eintrag suchen (scoped: u{id}__{app_id})
    scoped_id = f"u{user_id}__{app_id}"
    app_row = conn.execute(
        "SELECT ip, port FROM apps WHERE app_id=? AND user_id=?",
        (scoped_id, user_id)
    ).fetchone()
    if not app_row:
        app_row = conn.execute(
            "SELECT ip, port FROM apps WHERE LOWER(app_id)=? AND user_id=?",
            (scoped_id.lower(), user_id)
        ).fetchone()
    if not app_row:
        raise HTTPException(404, detail=f"App '{app_id}' nicht gefunden")

    target_url = f"http://{app_row['ip']}:{app_row['port']}/{path}"
    if request.url.query:
        params = "&".join(
            f"{k}={v}" for k, v in request.query_params.items() if k != "key"
        )
        if params:
            target_url += f"?{params}"

    # Headers weiterleiten (ohne hop-by-hop und Auth)
    skip_headers = {"host", "x-api-key", "connection", "transfer-encoding"}
    fwd_headers = {
        k: v for k, v in request.headers.items() if k.lower() not in skip_headers
    }
    fwd_headers["host"] = f"{app_row['ip']}:{app_row['port']}"
    fwd_headers["x-forwarded-for"] = request.client.host if request.client else "unknown"
    fwd_headers["x-forwarded-proto"] = "http"

    body = await request.body()

    try:
        resp = await _proxy_client.request(
            method=request.method,
            url=target_url,
            headers=fwd_headers,
            content=body if body else None,
        )
    except httpx.ConnectError:
        raise HTTPException(502, detail=f"App '{app_id}' nicht erreichbar")
    except httpx.TimeoutException:
        raise HTTPException(504, detail=f"App '{app_id}' Timeout")

    # Response-Headers filtern (content-length wird neu berechnet)
    resp_headers = dict(resp.headers)
    for h in ("transfer-encoding", "connection", "content-encoding", "content-length"):
        resp_headers.pop(h, None)

    # Redirect-Location umschreiben: /foo → /proxy/{app_id}/foo
    proxy_prefix = f"/proxy/{app_id}"
    target_origin = f"http://{app_row['ip']}:{app_row['port']}"
    if "location" in resp_headers:
        loc = resp_headers["location"]
        if loc.startswith(target_origin):
            loc = loc[len(target_origin):]
        if loc.startswith("/"):
            loc = f"{proxy_prefix}{loc}"
        resp_headers["location"] = loc

    # HTML-Body: absolute Pfade umschreiben
    content = resp.content
    content_type = resp_headers.get("content-type", "")
    if "text/html" in content_type:
        text = content.decode("utf-8", errors="replace")
        for attr in ('href="/', 'src="/', 'action="/'):
            text = text.replace(attr, f'{attr[:-1]}{proxy_prefix}/')
        content = text.encode("utf-8")

    response = Response(
        content=content,
        status_code=resp.status_code,
        headers=resp_headers,
    )

    # Auth-Cookie setzen (damit Redirects und Assets ohne ?key= funktionieren)
    response.set_cookie(
        key=f"proxy_key_{app_id}",
        value=api_key,
        httponly=True,
        samesite="lax",
        max_age=86400,
    )
    return response
