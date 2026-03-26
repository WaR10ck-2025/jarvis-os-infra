"""
auth.py — Authentifizierung für casaos-lxc-bridge

Admin-Key:    Vollzugriff auf /admin/* (X-API-Key Header)
OIDC-Session: Vollzugriff auf /admin/* via Authentik SSO (Cookie)
User-Key:     Zugriff auf /bridge/* im eigenen User-Scope
"""
from __future__ import annotations
import os
import time
import secrets
from fastapi import HTTPException, Header, Request

ADMIN_API_KEY = os.getenv("ADMIN_API_KEY", "")

# ── OIDC Session-Store ────────────────────────────────────────────────────────
# session_id → {username, is_admin, expires}
_oidc_sessions: dict[str, dict] = {}


def create_oidc_session(username: str, is_admin: bool) -> str:
    """Legt eine neue OIDC-Session an. Gibt session_id zurück."""
    sid = secrets.token_urlsafe(32)
    _oidc_sessions[sid] = {
        "username": username,
        "is_admin": is_admin,
        "expires": time.time() + 8 * 3600,   # 8h (wie Authentik-Token)
    }
    return sid


def get_oidc_session(session_id: str) -> dict | None:
    """Gibt Session-Daten zurück oder None wenn abgelaufen/unbekannt."""
    s = _oidc_sessions.get(session_id)
    if not s:
        return None
    if s["expires"] < time.time():
        _oidc_sessions.pop(session_id, None)
        return None
    return s


def delete_oidc_session(session_id: str) -> None:
    """Löscht eine Session (Logout)."""
    _oidc_sessions.pop(session_id, None)


def generate_api_key() -> str:
    """Generiert einen kryptographisch sicheren API-Key."""
    return secrets.token_urlsafe(32)


def require_admin(
    request: Request,
    x_api_key: str | None = Header(None, alias="X-API-Key"),
) -> None:
    """
    FastAPI-Dependency: Admin-Key (Header) ODER aktive OIDC-Session (Cookie).
    Wirft 403 wenn keines von beidem gültig ist.
    """
    # 1. API-Key prüfen
    if x_api_key and ADMIN_API_KEY and x_api_key == ADMIN_API_KEY:
        return
    # 2. OIDC-Session-Cookie prüfen
    sid = request.cookies.get("oidc_session")
    if sid:
        s = get_oidc_session(sid)
        if s and s.get("is_admin"):
            return
    if not ADMIN_API_KEY:
        raise HTTPException(500, detail="ADMIN_API_KEY nicht konfiguriert")
    raise HTTPException(403, detail="Admin-Authentifizierung erforderlich")


def require_user_or_admin(
    x_api_key: str = Header(..., alias="X-API-Key"),
) -> int | None:
    """
    FastAPI-Dependency: Admin-Key oder User-Key.

    Gibt user_id zurück (int) wenn User-Key.
    Gibt None zurück wenn Admin-Key (kein User-Scope).
    """
    if ADMIN_API_KEY and x_api_key == ADMIN_API_KEY:
        return None  # Admin → kein User-Scope

    # User-Key in DB nachschlagen (import hier um Zirkel-Import zu vermeiden)
    from lxc_manager import _get_db
    conn = _get_db()
    row = conn.execute(
        "SELECT user_id FROM users WHERE api_key=? AND status='ready'",
        (x_api_key,)
    ).fetchone()
    if not row:
        raise HTTPException(403, detail="Ungültiger API-Key oder User nicht bereit")
    return int(row["user_id"])
