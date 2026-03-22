"""
main.py — casaos-lxc-bridge FastAPI

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
"""
from __future__ import annotations
import asyncio
import os
import time
import logging
import textwrap
import json
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, RedirectResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
import app_resolver
import lxc_manager
import casaos_client
import preconfigured_apps

logger = logging.getLogger("casaos-lxc-bridge")
logging.basicConfig(level=logging.INFO)

BRIDGE_URL = os.getenv("BRIDGE_URL", "http://192.168.10.141:8200")
BRIDGE_LXC_ID = int(os.getenv("BRIDGE_LXC_ID", "120"))

# ---------------------------------------------------------------------------
# Katalog-Cache: wird beim Start befüllt + alle 6h refreshed
# ---------------------------------------------------------------------------
_catalog_cache: dict = {"apps": [], "last_update": 0.0}
_CACHE_TTL = 6 * 3600   # 6 Stunden


async def _refresh_catalog_cache() -> None:
    """Befüllt den Katalog-Cache async im Hintergrund."""
    try:
        all_apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)
        _catalog_cache["apps"] = all_apps
        _catalog_cache["last_update"] = time.time()
        logger.info(f"Katalog-Cache aktualisiert: {len(all_apps)} Apps")
    except Exception as e:
        logger.warning(f"Katalog-Cache-Refresh fehlgeschlagen: {e}")


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
    store_url = f"{BRIDGE_URL}/casaos-store"
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
    title="casaos-lxc-bridge",
    description="CasaOS App-Store + Umbrel → Proxmox LXC Bridge",
    version="2.0.0",
    lifespan=lifespan,
)

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/static/index.html")


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "casaos-lxc-bridge",
        "catalog_cached": len(_catalog_cache["apps"]),
        "cache_age_s": int(time.time() - _catalog_cache["last_update"]) if _catalog_cache["last_update"] else None,
    }


# ---------------------------------------------------------------------------
# Preconfigured Apps
# ---------------------------------------------------------------------------

@app.get("/bridge/preconfigured")
async def get_preconfigured():
    """Freigeschaltete Apps mit Live-Status aus der Bridge-DB."""
    installed = {a.app_id: a for a in lxc_manager.list_apps()}
    result = []
    for app_def in preconfigured_apps.PRECONFIGURED_APPS:
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
async def install_app(appid: str = Query(..., description="App-ID (z.B. 'N8n', 'vaultwarden')")):
    """
    Installiert eine App aus CasaOS- oder Umbrel-Store als isolierten Proxmox-LXC.
    Für vorkonfigurierte Apps werden feste LXC-ID + IP verwendet.
    Registriert die App anschließend im CasaOS-Dashboard.
    """
    try:
        meta = app_resolver.resolve(appid)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

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
async def remove_app(appid: str = Query(..., description="App-ID")):
    """Stoppt und zerstört den LXC-Container. Entfernt den CasaOS-Dashboard-Eintrag."""
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


@app.get("/bridge/list")
async def list_apps():
    """Alle bridge-verwalteten Apps mit aktuellem Status."""
    await asyncio.to_thread(lxc_manager.sync_status)
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
    Für Umbrel-Apps wird ein synthetischer x-casaos Block generiert.
    """
    try:
        meta = await asyncio.to_thread(app_resolver.resolve, app_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    compose = _to_casaos_format(meta)
    return PlainTextResponse(compose, media_type="text/plain")
