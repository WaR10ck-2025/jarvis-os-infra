"""
app_resolver.py — CasaOS + Umbrel App-Store Katalog-Resolver

Lädt docker-compose.yml und App-Metadaten direkt aus GitHub-Repos.
Unterstützt:
  - Offiziellen CasaOS-AppStore (IceWhaleTech/CasaOS-AppStore)
  - Offiziellen Umbrel App Store (getumbrel/umbrel-apps)
  - Custom-Stores via CUSTOM_STORES env: "casaos:URL,umbrel:URL"
  - Legacy CASAOS_CUSTOM_STORES (backward-compat, bare URLs = casaos-Typ)
"""
from __future__ import annotations
import os
import json
import urllib.request
import urllib.error
from dataclasses import dataclass, field

OFFICIAL_STORE_RAW = "https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps"
OFFICIAL_STORE_API = "https://api.github.com/repos/IceWhaleTech/CasaOS-AppStore/contents/Apps"

UMBREL_STORE_RAW = "https://raw.githubusercontent.com/getumbrel/umbrel-apps/master"
UMBREL_STORE_API = "https://api.github.com/repos/getumbrel/umbrel-apps/contents"
UMBREL_STORE_ENABLED = os.getenv("UMBREL_STORE_ENABLED", "true").lower() == "true"

# Legacy: CASAOS_CUSTOM_STORES (bare URLs → casaos-Typ)
_LEGACY_CUSTOM = os.getenv("CASAOS_CUSTOM_STORES", "")
# Neu: CUSTOM_STORES mit Typ-Präfix (casaos:URL oder umbrel:URL)
_CUSTOM_STORES_RAW = os.getenv("CUSTOM_STORES", "")


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
    store_type: str = "casaos"   # "casaos" | "umbrel"


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
            for key in ("title", "tagline", "description"):
                if stripped.startswith(f"{key}:"):
                    pass  # Kommt im Unter-Block
                if stripped.startswith("en_US:") and in_xcasaos:
                    val = stripped.split(":", 1)[1].strip().strip('"')
                    if not meta["name"] and "title" in compose_yaml[:compose_yaml.find("en_US:")]:
                        meta["name"] = val
                    elif not meta["tagline"]:
                        meta["tagline"] = val
                    elif not meta["description"]:
                        meta["description"] = val
    return meta


def _parse_umbrel_manifest(content: str, app_id: str, store_base: str) -> dict:
    """Parsed umbrel-app.yml zeilenweise (kein YAML-Lib nötig — flache Key: Value Struktur)."""
    meta = {
        "name": app_id,
        "tagline": "",
        "description": "",
        "category": "Utilities",
        "port": 80,
        "developer": "",
        "icon": f"{store_base}/{app_id}/icon.svg",
    }
    in_description = False
    desc_lines: list[str] = []

    for line in content.splitlines():
        stripped = line.strip()

        # description: Mehrzeiliger Block
        if stripped.startswith("description:"):
            in_description = True
            rest = stripped[len("description:"):].strip().lstrip("|").strip()
            if rest and rest not in ("|", ">"):
                desc_lines.append(rest)
            continue
        if in_description:
            if stripped and not line.startswith(" "):
                in_description = False
            else:
                if stripped:
                    desc_lines.append(stripped)
                continue

        # Einfache Key: Value Paare
        for key, mkey in [("name:", "name"), ("tagline:", "tagline"),
                           ("category:", "category"), ("developer:", "developer")]:
            if stripped.startswith(key):
                val = stripped[len(key):].strip().strip('"').strip("'")
                if val:
                    meta[mkey] = val
        if stripped.startswith("port:"):
            try:
                meta["port"] = int(stripped[5:].strip())
            except ValueError:
                pass

    if desc_lines:
        meta["description"] = " ".join(desc_lines[:3])
    return meta


def _parse_custom_stores() -> list[tuple[str, str]]:
    """Gibt Liste von (store_type, url) Tupeln zurück."""
    stores: list[tuple[str, str]] = []
    for entry in _CUSTOM_STORES_RAW.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if entry.startswith("umbrel:"):
            stores.append(("umbrel", entry[7:]))
        elif entry.startswith("casaos:"):
            stores.append(("casaos", entry[7:]))
        else:
            stores.append(("casaos", entry))
    # Legacy CASAOS_CUSTOM_STORES
    for entry in _LEGACY_CUSTOM.split(","):
        entry = entry.strip()
        if entry:
            stores.append(("casaos", entry))
    return stores


def _resolve_casaos(app_id: str, store_url: str) -> AppMeta:
    """Lädt App aus CasaOS-formatiertem Store."""
    compose_yaml = _fetch(f"{store_url}/{app_id}/docker-compose.yml")
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
        store_type="casaos",
    )


def resolve_umbrel(app_id: str, store_base: str = UMBREL_STORE_RAW) -> AppMeta:
    """Lädt App aus Umbrel-formatiertem Store."""
    manifest = _fetch(f"{store_base}/{app_id}/umbrel-app.yml")
    compose_yaml = _fetch(f"{store_base}/{app_id}/docker-compose.yml")
    meta = _parse_umbrel_manifest(manifest, app_id, store_base)
    return AppMeta(
        app_id=app_id,
        name=meta["name"],
        tagline=meta["tagline"],
        description=meta["description"],
        icon=meta["icon"],
        category=meta["category"],
        port=meta["port"],
        developer=meta["developer"],
        compose_yaml=compose_yaml,
        store_url=store_base,
        store_type="umbrel",
    )


def resolve(app_id: str) -> AppMeta:
    """
    Lädt App-Metadaten + docker-compose.yml für eine App-ID.
    Suchreihenfolge: CasaOS Official → Umbrel Official → Custom Stores.
    """
    # 1. CasaOS Official Store
    try:
        return _resolve_casaos(app_id, OFFICIAL_STORE_RAW)
    except FileNotFoundError:
        pass

    # 2. Umbrel Official Store (wenn enabled)
    if UMBREL_STORE_ENABLED:
        try:
            return resolve_umbrel(app_id, UMBREL_STORE_RAW)
        except FileNotFoundError:
            pass

    # 3. Custom Stores
    for store_type, store_url in _parse_custom_stores():
        try:
            if store_type == "umbrel":
                return resolve_umbrel(app_id, store_url)
            else:
                return _resolve_casaos(app_id, store_url)
        except FileNotFoundError:
            continue

    raise FileNotFoundError(f"App '{app_id}' in keinem Store gefunden.")


def list_official_apps() -> list[str]:
    """Gibt bekannte App-IDs aus dem offiziellen CasaOS-Store zurück (via GitHub API)."""
    try:
        with urllib.request.urlopen(OFFICIAL_STORE_API, timeout=15) as resp:
            items = json.loads(resp.read())
        return sorted(item["name"] for item in items if item["type"] == "dir")
    except Exception:
        return []


def list_umbrel_apps() -> list[str]:
    """Gibt App-IDs aus dem offiziellen Umbrel Store zurück (via GitHub API)."""
    try:
        with urllib.request.urlopen(UMBREL_STORE_API, timeout=15) as resp:
            items = json.loads(resp.read())
        return sorted(item["name"] for item in items if item["type"] == "dir")
    except Exception:
        return []


def list_all_apps() -> dict[str, list[str]]:
    """Alle App-IDs gruppiert nach Store-Quelle."""
    result: dict[str, list[str]] = {"casaos": list_official_apps()}
    if UMBREL_STORE_ENABLED:
        result["umbrel"] = list_umbrel_apps()
    custom_stores = _parse_custom_stores()
    if custom_stores:
        custom_ids: list[str] = []
        for _store_type, store_url in custom_stores:
            # Custom Store Listing via GitHub API (URL muss API-Format sein)
            try:
                # Umbrel-Style: direkte Contents-URL
                api_url = (store_url
                           .replace("raw.githubusercontent.com", "api.github.com/repos")
                           .rstrip("/"))
                # CasaOS-Style: /Apps Unterverzeichnis
                if "/Apps" in api_url:
                    pass  # URL zeigt bereits auf Apps-Verzeichnis
                with urllib.request.urlopen(api_url, timeout=10) as resp:
                    items = json.loads(resp.read())
                custom_ids.extend(item["name"] for item in items if item["type"] == "dir")
            except Exception:
                pass
        result["custom"] = sorted(set(custom_ids))
    return result


def list_all_apps_with_meta() -> list[dict]:
    """
    Alle Apps mit Basis-Metadaten (app_id + source).
    Compose und Kategorie werden nicht einzeln gefetcht (zu langsam für 350+ Apps).
    Source-Tabs im UI ermöglichen trotzdem sinnvolle Filterung.
    """
    all_apps = list_all_apps()
    result = []
    for source, ids in all_apps.items():
        for app_id in ids:
            result.append({
                "app_id": app_id,
                "name": app_id,
                "icon": "",
                "category": "",
                "source": source,
            })
    return sorted(result, key=lambda x: x["app_id"].lower())
