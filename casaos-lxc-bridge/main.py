"""
main.py — casaos-lxc-bridge FastAPI

Endpunkte:
  GET    /                            → Redirect zur Web-UI
  GET    /static/index.html          Web-UI (One-Click App-Store)
  POST   /bridge/install?appid=<id>  App aus CasaOS-Store als LXC deployen
  DELETE /bridge/remove?appid=<id>   LXC stoppen + löschen
  GET    /bridge/list                Alle bridge-verwalteten Apps
  GET    /bridge/status?appid=<id>   Status einer App
  POST   /bridge/sync                DB-Status mit Proxmox abgleichen
  GET    /bridge/catalog             Verfügbare Apps im offiziellen CasaOS-Store
  GET    /bridge/preconfigured       Freigeschaltete Apps (mit Live-Status)
  GET    /health                     Liveness-Check
"""
from __future__ import annotations
import asyncio
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
import app_resolver
import lxc_manager
import casaos_client
import preconfigured_apps

app = FastAPI(
    title="casaos-lxc-bridge",
    description="CasaOS App-Store → Proxmox LXC Bridge",
    version="1.0.0",
)

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/static/index.html")


@app.get("/health")
def health():
    return {"status": "ok", "service": "casaos-lxc-bridge"}


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


@app.post("/bridge/install")
async def install_app(appid: str = Query(..., description="CasaOS App-ID (z.B. 'N8n', 'Syncthing')")):
    """
    Installiert eine App aus dem CasaOS-Store als isolierten Proxmox-LXC-Container.
    Für vorkonfigurierte Apps (preconfigured_apps.py) werden feste LXC-ID + IP verwendet.
    Registriert die App anschließend im CasaOS-Dashboard.
    """
    try:
        meta = app_resolver.resolve(appid)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    # Feste LXC-ID + IP für vorkonfigurierte Apps (z.B. Nextcloud → LXC 109)
    fixed_lxc_id, fixed_ip = preconfigured_apps.get_fixed_params(appid)

    try:
        rec = await asyncio.to_thread(lxc_manager.install, meta, fixed_lxc_id, fixed_ip)
    except RuntimeError as e:
        raise HTTPException(409 if "bereits installiert" in str(e) else 500, detail=str(e))

    # CasaOS-Registrierung (non-blocking — Dashboard-Fehler stoppen die App nicht)
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
        "casaos": casaos_msg,
    }


@app.delete("/bridge/remove")
async def remove_app(appid: str = Query(..., description="CasaOS App-ID")):
    """Stoppt und zerstört den LXC-Container. Entfernt den CasaOS-Dashboard-Eintrag."""
    # CasaOS zuerst abmelden
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


@app.get("/bridge/catalog")
async def catalog():
    """Verfügbare Apps im offiziellen CasaOS-AppStore."""
    apps = await asyncio.to_thread(app_resolver.list_official_apps)
    return {"count": len(apps), "apps": sorted(apps)}
