"""
J.A.R.V.I.S-OS Portal (Per-VM Version)

Laeuft in jeder User-VM und Admin-VM als lokales Self-Service Portal.
Zwei Modi (gesteuert via VM_MODE Umgebungsvariable):

  - VM_MODE=user:  Nur eigene Apps verwalten, Ressourcen-Monitor, App-Store
  - VM_MODE=admin: Wie User, PLUS User/VM-Management via Admin-Service API

Kommuniziert mit:
  - Lokaler k3s (JarvisApp CRDs)
  - Admin-Service (LXC 160) fuer Katalog + Admin-Funktionen
"""

import json
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import kubernetes
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from auth import get_current_user, setup_auth

logger = logging.getLogger("jarvis-portal")

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

VM_MODE = os.getenv("VM_MODE", "user")  # "user" oder "admin"
VM_USERNAME = os.getenv("VM_USERNAME", "unknown")
VM_PROFILE = os.getenv("VM_PROFILE", "medium")
ADMIN_SERVICE_URL = os.getenv("ADMIN_SERVICE_URL", "http://192.168.10.160:8300")
ADMIN_API_KEY = os.getenv("ADMIN_API_KEY", "")
CATALOG_PATH = os.getenv("CATALOG_PATH", "/opt/jarvis/catalog.json")
APPS_NAMESPACE = os.getenv("APPS_NAMESPACE", "default")

# ---------------------------------------------------------------------------
# App-Katalog (Fallback falls catalog.json nicht vorhanden)
# ---------------------------------------------------------------------------

FALLBACK_CATALOG = {
    "vaultwarden": {
        "name": "Vaultwarden", "description": "Passwort-Manager (Bitwarden-kompatibel)",
        "icon": "🔐", "image": "vaultwarden/server:latest", "port": 80,
        "persistence": {"enabled": True, "size": "5Gi", "mountPath": "/data"},
        "resources": {"requests": {"memory": "64Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "500m"}},
    },
    "filebrowser": {
        "name": "FileBrowser", "description": "Web-basierter Datei-Manager",
        "icon": "📁", "image": "filebrowser/filebrowser:latest", "port": 80,
        "persistence": {"enabled": True, "size": "10Gi", "mountPath": "/srv"},
        "resources": {"requests": {"memory": "32Mi", "cpu": "25m"}, "limits": {"memory": "128Mi", "cpu": "250m"}},
    },
    "uptime-kuma": {
        "name": "Uptime Kuma", "description": "Self-hosted Monitoring",
        "icon": "📊", "image": "louislam/uptime-kuma:1", "port": 3001,
        "persistence": {"enabled": True, "size": "2Gi", "mountPath": "/app/data"},
        "resources": {"requests": {"memory": "64Mi", "cpu": "50m"}, "limits": {"memory": "256Mi", "cpu": "500m"}},
    },
    "excalidraw": {
        "name": "Excalidraw", "description": "Whiteboard und Diagramme",
        "icon": "🖼️", "image": "excalidraw/excalidraw:latest", "port": 80,
        "persistence": {"enabled": False},
        "resources": {"requests": {"memory": "32Mi", "cpu": "25m"}, "limits": {"memory": "128Mi", "cpu": "250m"}},
    },
    "stirling-pdf": {
        "name": "Stirling PDF", "description": "PDF-Toolkit (Merge, Split, Convert)",
        "icon": "📄", "image": "stirlingtools/stirling-pdf:latest", "port": 8080,
        "persistence": {"enabled": False},
        "resources": {"requests": {"memory": "128Mi", "cpu": "100m"}, "limits": {"memory": "512Mi", "cpu": "1"}},
    },
    "it-tools": {
        "name": "IT-Tools", "description": "Nuetzliche Online-Tools fuer Entwickler",
        "icon": "🛠️", "image": "corentinth/it-tools:latest", "port": 80,
        "persistence": {"enabled": False},
        "resources": {"requests": {"memory": "32Mi", "cpu": "25m"}, "limits": {"memory": "128Mi", "cpu": "250m"}},
    },
}


def _load_catalog() -> dict:
    """Laedt App-Katalog aus catalog.json (vom Operator synchronisiert) oder Fallback."""
    try:
        if Path(CATALOG_PATH).exists():
            with open(CATALOG_PATH) as f:
                data = json.load(f)
            # Konvertiere Liste zu Dict (Admin-Service liefert Liste)
            if isinstance(data, list):
                return {a["app_id"]: a for a in data}
            return data
    except Exception as e:
        logger.warning("Katalog laden fehlgeschlagen: %s", e)
    return FALLBACK_CATALOG


# ---------------------------------------------------------------------------
# K8s Client
# ---------------------------------------------------------------------------

def _init_k8s():
    try:
        kubernetes.config.load_incluster_config()
    except kubernetes.config.ConfigException:
        kubeconfig = os.environ.get("KUBECONFIG", os.path.expanduser("~/.kube/config"))
        kubernetes.config.load_kube_config(config_file=kubeconfig)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _init_k8s()
    logger.info("Portal gestartet — User: %s, Modus: %s", VM_USERNAME, VM_MODE)
    yield


# ---------------------------------------------------------------------------
# FastAPI App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="J.A.R.V.I.S-OS Portal",
    version="2.0.0",
    description=f"Self-Service Portal (Modus: {VM_MODE})",
    lifespan=lifespan,
)

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

# OIDC-Authentifizierung registrieren (Session-Middleware + Login-Routen)
setup_auth(app)


# ---------------------------------------------------------------------------
# K8s API Helpers (lokaler k3s)
# ---------------------------------------------------------------------------

def _custom_api():
    return kubernetes.client.CustomObjectsApi()


def _get_apps(namespace: str = APPS_NAMESPACE) -> list:
    api = _custom_api()
    result = api.list_namespaced_custom_object("jarvis-os.io", "v1", namespace, "jarvisapps")
    return result.get("items", [])


def _get_pods(namespace: str = APPS_NAMESPACE) -> list:
    api = kubernetes.client.CoreV1Api()
    pods = api.list_namespaced_pod(namespace)
    return pods.items


def _get_pod_logs(namespace: str, pod_name: str, tail_lines: int = 100) -> str:
    api = kubernetes.client.CoreV1Api()
    return api.read_namespaced_pod_log(pod_name, namespace, tail_lines=tail_lines)


def _create_app(namespace: str, app_name: str, catalog_id: str):
    """JarvisApp-CRD erstellen (Operator reconciled automatisch)."""
    catalog = _load_catalog()
    app_def = catalog.get(catalog_id)
    if not app_def:
        raise HTTPException(status_code=404, detail=f"App '{catalog_id}' nicht im Katalog")

    # Host-Name fuer Ingress
    name = app_def.get("name", catalog_id)
    image = app_def.get("image", "")
    port = app_def.get("port", 8080)
    host = f"{catalog_id}.jarvis.local"

    body = {
        "apiVersion": "jarvis-os.io/v1",
        "kind": "JarvisApp",
        "metadata": {"name": app_name, "namespace": namespace},
        "spec": {
            "appId": name,
            "image": image,
            "port": port,
            "ingress": {"enabled": True, "host": host},
            "resources": app_def.get("resources", {}),
            "persistence": app_def.get("persistence", {"enabled": False}),
        },
    }

    api = _custom_api()
    api.create_namespaced_custom_object("jarvis-os.io", "v1", namespace, "jarvisapps", body)
    return body


def _delete_app(namespace: str, name: str):
    api = _custom_api()
    api.delete_namespaced_custom_object("jarvis-os.io", "v1", namespace, "jarvisapps", name)


# ---------------------------------------------------------------------------
# Admin-Service Client (nur im Admin-Modus)
# ---------------------------------------------------------------------------

async def _admin_api(method: str, path: str, data: dict | None = None) -> dict:
    """HTTP-Request an den Admin-Service (LXC 160)."""
    headers = {}
    if ADMIN_API_KEY:
        headers["X-API-Key"] = ADMIN_API_KEY
    async with httpx.AsyncClient(base_url=ADMIN_SERVICE_URL, timeout=15) as client:
        if method == "GET":
            resp = await client.get(path, headers=headers)
        elif method == "POST":
            resp = await client.post(path, json=data, headers=headers)
        elif method == "PUT":
            resp = await client.put(path, json=data, headers=headers)
        elif method == "DELETE":
            resp = await client.delete(path, headers=headers)
        else:
            raise ValueError(f"Unbekannte HTTP-Methode: {method}")
        resp.raise_for_status()
        return resp.json()


# ===========================================================================
# USER-ROUTEN (immer aktiv — sowohl User als auch Admin)
# ===========================================================================

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Startseite: App-Uebersicht + Ressourcen."""
    apps = _get_apps()
    catalog = _load_catalog()
    auth_user = get_current_user(request)
    display_name = auth_user["name"] if auth_user else VM_USERNAME
    return templates.TemplateResponse(request, "dashboard.html", {
        "apps": apps,
        "catalog": catalog,
        "username": display_name,
        "profile": VM_PROFILE,
        "mode": VM_MODE,
        "auth_user": auth_user,
    })


@app.get("/apps", response_class=HTMLResponse)
async def app_store(request: Request):
    """App-Store: Verfuegbare Apps durchsuchen."""
    catalog = _load_catalog()
    installed = {a["spec"]["appId"] for a in _get_apps()}
    auth_user = get_current_user(request)
    display_name = auth_user["name"] if auth_user else VM_USERNAME
    return templates.TemplateResponse(request, "apps.html", {
        "catalog": catalog,
        "installed": installed,
        "username": display_name,
        "mode": VM_MODE,
        "auth_user": auth_user,
    })


@app.get("/logs/{pod_name}", response_class=HTMLResponse)
async def pod_logs_page(request: Request, pod_name: str):
    try:
        logs = _get_pod_logs(APPS_NAMESPACE, pod_name)
    except kubernetes.client.exceptions.ApiException as e:
        logs = f"Fehler: {e.reason}"
    auth_user = get_current_user(request)
    display_name = auth_user["name"] if auth_user else VM_USERNAME
    return templates.TemplateResponse(request, "logs.html", {
        "pod_name": pod_name,
        "logs": logs,
        "username": display_name,
        "mode": VM_MODE,
        "auth_user": auth_user,
    })


@app.post("/deploy/{catalog_id}")
async def deploy_app(catalog_id: str):
    """App aus dem Katalog installieren."""
    try:
        _create_app(APPS_NAMESPACE, catalog_id, catalog_id)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 409:
            raise HTTPException(409, f"App '{catalog_id}' existiert bereits")
        raise HTTPException(500, str(e))
    return RedirectResponse(url="/", status_code=303)


@app.post("/delete/{app_name}")
async def delete_app_route(app_name: str):
    """App deinstallieren."""
    try:
        _delete_app(APPS_NAMESPACE, app_name)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 404:
            raise HTTPException(404, f"App '{app_name}' nicht gefunden")
        raise HTTPException(500, str(e))
    return RedirectResponse(url="/", status_code=303)


# ===========================================================================
# API-ENDPUNKTE (User)
# ===========================================================================

@app.get("/api/apps")
async def api_list_apps():
    return _get_apps()


@app.get("/api/catalog")
async def api_catalog():
    return _load_catalog()


@app.get("/api/health")
async def api_health():
    return {"status": "ok", "username": VM_USERNAME, "mode": VM_MODE}


# ===========================================================================
# ADMIN-ROUTEN (nur wenn VM_MODE=admin)
# ===========================================================================

if VM_MODE == "admin":

    @app.get("/admin/users", response_class=HTMLResponse)
    async def admin_users(request: Request):
        """Admin: User-Uebersicht."""
        try:
            users = await _admin_api("GET", "/api/v1/users")
        except Exception as e:
            users = []
            logger.warning("Admin-Service nicht erreichbar: %s", e)

        auth_user = get_current_user(request)
        display_name = auth_user["name"] if auth_user else VM_USERNAME
        return templates.TemplateResponse(request, "admin/users.html", {
            "users": users,
            "username": display_name,
            "mode": VM_MODE,
            "auth_user": auth_user,
        })

    @app.get("/admin/users/{user_id}", response_class=HTMLResponse)
    async def admin_user_detail(request: Request, user_id: int):
        """Admin: User-Detail + VM-Stats."""
        try:
            user = await _admin_api("GET", f"/api/v1/users/{user_id}")
            stats = await _admin_api("GET", f"/api/v1/users/{user_id}/status")
        except Exception as e:
            raise HTTPException(404, f"User nicht gefunden: {e}")

        auth_user = get_current_user(request)
        display_name = auth_user["name"] if auth_user else VM_USERNAME
        return templates.TemplateResponse(request, "admin/user_detail.html", {
            "user": user,
            "stats": stats,
            "username": display_name,
            "mode": VM_MODE,
            "auth_user": auth_user,
        })

    @app.get("/admin/capacity", response_class=HTMLResponse)
    async def admin_capacity(request: Request):
        """Admin: Cluster-Kapazitaet."""
        try:
            capacity = await _admin_api("GET", "/api/v1/stats/capacity")
            profiles = await _admin_api("GET", "/api/v1/profiles")
        except Exception as e:
            capacity = {}
            profiles = {}
            logger.warning("Admin-Service nicht erreichbar: %s", e)

        auth_user = get_current_user(request)
        display_name = auth_user["name"] if auth_user else VM_USERNAME
        return templates.TemplateResponse(request, "admin/capacity.html", {
            "capacity": capacity,
            "profiles": profiles,
            "username": display_name,
            "mode": VM_MODE,
            "auth_user": auth_user,
        })

    @app.post("/admin/users/create")
    async def admin_create_user(
        username: str = Form(...),
        profile: str = Form("medium"),
    ):
        """Admin: User anlegen (VM wird provisioniert)."""
        username = username.lower().strip()
        try:
            await _admin_api("POST", "/api/v1/users", {
                "username": username,
                "profile": profile,
            })
        except httpx.HTTPStatusError as e:
            raise HTTPException(e.response.status_code, e.response.text)
        return RedirectResponse(url="/admin/users", status_code=303)

    @app.post("/admin/users/delete/{user_id}")
    async def admin_delete_user(user_id: int):
        """Admin: User + VM entfernen."""
        try:
            await _admin_api("DELETE", f"/api/v1/users/{user_id}")
        except httpx.HTTPStatusError as e:
            raise HTTPException(e.response.status_code, e.response.text)
        return RedirectResponse(url="/admin/users", status_code=303)

    # Admin API Proxies
    @app.get("/admin/api/users")
    async def admin_api_users():
        return await _admin_api("GET", "/api/v1/users")

    @app.get("/admin/api/capacity")
    async def admin_api_capacity():
        return await _admin_api("GET", "/api/v1/stats/capacity")

    @app.get("/admin/api/stats")
    async def admin_api_stats():
        return await _admin_api("GET", "/api/v1/stats")
