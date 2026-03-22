"""
app_resolver.py — CasaOS App-Store Katalog-Resolver

Lädt docker-compose.yml und App-Metadaten direkt aus GitHub-Repos.
Unterstützt:
  - Offiziellen CasaOS-AppStore (IceWhaleTech/CasaOS-AppStore)
  - Custom-Stores (eigene GitHub-Repos, gleiche Verzeichnisstruktur)
"""
from __future__ import annotations
import os
import json
import urllib.request
import urllib.error
from dataclasses import dataclass, field

OFFICIAL_STORE_RAW = "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps"

# Zusätzliche Custom-Stores (URL zu Raw-GitHub-Verzeichnis)
CUSTOM_STORES: list[str] = [
    store.strip()
    for store in os.getenv("CASAOS_CUSTOM_STORES", "").split(",")
    if store.strip()
]


@dataclass
class AppMeta:
    app_id: str
    name: str
    tagline: str
    description: str
    icon: str
    category: str
    port: int
    developer: str
    architectures: list[str] = field(default_factory=lambda: ["amd64", "arm64"])
    compose_yaml: str = ""
    store_url: str = OFFICIAL_STORE_RAW


def _fetch(url: str) -> str:
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.read().decode()
    except urllib.error.HTTPError as e:
        raise FileNotFoundError(f"HTTP {e.code}: {url}") from e


def _parse_xcasaos(compose_yaml: str) -> dict:
    """Extrahiert x-casaos-Felder aus docker-compose.yml (rudimentär, ohne YAML-Parser)."""
    meta = {
        "name": "", "tagline": "", "description": "",
        "icon": "", "category": "Utilities", "port": 80,
        "developer": "", "architectures": ["amd64", "arm64"],
    }
    lines = compose_yaml.splitlines()
    in_xcasaos = False
    indent = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("x-casaos:"):
            in_xcasaos = True
            indent = len(line) - len(line.lstrip())
            continue
        if in_xcasaos:
            cur_indent = len(line) - len(line.lstrip())
            if cur_indent <= indent and stripped and not stripped.startswith("#"):
                in_xcasaos = False
                continue
            for key in ("icon", "category", "developer", "author"):
                if stripped.startswith(f"{key}:"):
                    val = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                    meta[key if key != "author" else "developer"] = val
            if stripped.startswith("port_map:"):
                try:
                    meta["port"] = int(stripped.split(":", 1)[1].strip().strip('"'))
                except ValueError:
                    pass
            # Mehrsprachige Felder: bevorzuge en_US
            for key in ("title", "tagline", "description"):
                if stripped.startswith(f"{key}:"):
                    pass  # Kommt im Unter-Block
                if stripped.startswith("en_US:") and in_xcasaos:
                    # Bestimme welches Feld aktuell aktiv ist anhand vorheriger Zeilen
                    val = stripped.split(":", 1)[1].strip().strip('"')
                    if not meta["name"] and "title" in compose_yaml[:compose_yaml.find("en_US:")]:
                        meta["name"] = val
                    elif not meta["tagline"]:
                        meta["tagline"] = val
                    elif not meta["description"]:
                        meta["description"] = val
    return meta


def resolve(app_id: str) -> AppMeta:
    """Lädt App-Metadaten + docker-compose.yml für eine App-ID."""
    stores = [OFFICIAL_STORE_RAW] + CUSTOM_STORES
    last_error = None

    for store_url in stores:
        compose_url = f"{store_url}/{app_id}/docker-compose.yml"
        try:
            compose_yaml = _fetch(compose_url)
        except FileNotFoundError as e:
            last_error = e
            continue

        meta = _parse_xcasaos(compose_yaml)
        return AppMeta(
            app_id=app_id,
            name=meta.get("name") or app_id,
            tagline=meta.get("tagline") or f"{app_id} via CasaOS AppStore",
            description=meta.get("description") or "",
            icon=meta.get("icon") or "",
            category=meta.get("category") or "Utilities",
            port=meta.get("port") or 80,
            developer=meta.get("developer") or "",
            architectures=meta.get("architectures") or ["amd64", "arm64"],
            compose_yaml=compose_yaml,
            store_url=store_url,
        )

    raise FileNotFoundError(f"App '{app_id}' in keinem Store gefunden. Letzter Fehler: {last_error}")


def list_official_apps() -> list[str]:
    """Gibt bekannte App-IDs aus dem offiziellen CasaOS-Store zurück (via GitHub API)."""
    api_url = "https://api.github.com/repos/IceWhaleTech/CasaOS-AppStore/contents/Apps"
    try:
        with urllib.request.urlopen(api_url, timeout=10) as resp:
            items = json.loads(resp.read())
        return [item["name"] for item in items if item["type"] == "dir"]
    except Exception:
        return []
