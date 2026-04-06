"""
auth.py — OIDC-Authentifizierung fuer das J.A.R.V.I.S-OS Portal

Verwendet Authentik als OIDC-Provider (LXC 125).
Flow: Authorization Code Grant (RFC 6749 Section 4.1)

Env-Variablen (aus ConfigMap jarvis-oidc-config):
  OIDC_CLIENT_ID       — OAuth2 Client-ID (pro Portal-Modus verschieden)
  OIDC_CLIENT_SECRET   — OAuth2 Client-Secret
  OIDC_AUTHORIZE_URL   — Authentik /application/o/authorize/
  OIDC_TOKEN_URL       — Authentik /application/o/token/
  OIDC_USERINFO_URL    — Authentik /application/o/userinfo/
  OIDC_REDIRECT_URI    — Callback-URL dieses Portals
  SESSION_SECRET       — Signing-Key fuer Session-Cookies
  OIDC_ENABLED         — "true" aktiviert OIDC (default: "false")
"""

import hashlib
import logging
import os
import secrets

import httpx
from authlib.integrations.starlette_client import OAuth
from fastapi import Request
from fastapi.responses import RedirectResponse
from starlette.middleware.sessions import SessionMiddleware

logger = logging.getLogger("jarvis-portal.auth")

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

OIDC_ENABLED = os.getenv("OIDC_ENABLED", "false").lower() == "true"
OIDC_CLIENT_ID = os.getenv("OIDC_CLIENT_ID", "")
OIDC_CLIENT_SECRET = os.getenv("OIDC_CLIENT_SECRET", "")
OIDC_AUTHORIZE_URL = os.getenv("OIDC_AUTHORIZE_URL", "")
OIDC_TOKEN_URL = os.getenv("OIDC_TOKEN_URL", "")
OIDC_USERINFO_URL = os.getenv("OIDC_USERINFO_URL", "")
OIDC_REDIRECT_URI = os.getenv("OIDC_REDIRECT_URI", "")
SESSION_SECRET = os.getenv("SESSION_SECRET", secrets.token_hex(32))

# Routen die ohne Login erreichbar sein muessen
PUBLIC_PATHS = {"/auth/login", "/auth/callback", "/auth/logout", "/api/health"}

# ---------------------------------------------------------------------------
# OAuth-Client Setup (authlib)
# ---------------------------------------------------------------------------

oauth = OAuth()

if OIDC_ENABLED and OIDC_CLIENT_ID:
    oauth.register(
        name="authentik",
        client_id=OIDC_CLIENT_ID,
        client_secret=OIDC_CLIENT_SECRET,
        authorize_url=OIDC_AUTHORIZE_URL,
        access_token_url=OIDC_TOKEN_URL,
        userinfo_endpoint=OIDC_USERINFO_URL,
        client_kwargs={"scope": "openid email profile"},
    )
    logger.info("OIDC aktiviert — Client: %s", OIDC_CLIENT_ID)
else:
    logger.info("OIDC deaktiviert — Portal ohne Login nutzbar")


# ---------------------------------------------------------------------------
# FastAPI Integration
# ---------------------------------------------------------------------------

def setup_auth(app):
    """Registriert Session-Middleware und Auth-Routen auf der FastAPI-App."""

    if not OIDC_ENABLED:
        # Session-Middleware trotzdem registrieren (fuer auth_user=None Template-Kontext)
        app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET)
        return

    @app.middleware("http")
    async def auth_middleware(request: Request, call_next):
        """Prueft ob User eingeloggt ist. Redirect zu /auth/login wenn nicht."""
        path = request.url.path

        # Statische Dateien und Public-Routen durchlassen
        if path.startswith("/static") or path in PUBLIC_PATHS:
            return await call_next(request)

        # Session pruefen
        user = request.session.get("user")
        if not user:
            return RedirectResponse(url="/auth/login")

        return await call_next(request)

    @app.get("/auth/login")
    async def auth_login(request: Request):
        """Startet den OIDC Authorization Code Flow."""
        client = oauth.create_client("authentik")
        redirect_uri = OIDC_REDIRECT_URI
        return await client.authorize_redirect(request, redirect_uri)

    @app.get("/auth/callback")
    async def auth_callback(request: Request):
        """Empfaengt den Authorization Code und tauscht ihn gegen Tokens."""
        client = oauth.create_client("authentik")

        try:
            token = await client.authorize_access_token(request)
        except Exception as e:
            logger.error("Token-Exchange fehlgeschlagen: %s", e)
            return RedirectResponse(url="/auth/login")

        # Userinfo abrufen
        userinfo = token.get("userinfo")
        if not userinfo:
            try:
                resp = await client.get(OIDC_USERINFO_URL, token=token)
                userinfo = resp.json()
            except Exception as e:
                logger.error("Userinfo-Abruf fehlgeschlagen: %s", e)
                return RedirectResponse(url="/auth/login")

        # Session setzen
        request.session["user"] = {
            "sub": userinfo.get("sub", ""),
            "username": userinfo.get("preferred_username", userinfo.get("sub", "")),
            "email": userinfo.get("email", ""),
            "name": userinfo.get("name", ""),
            "groups": userinfo.get("groups", []),
        }

        logger.info("Login erfolgreich: %s", userinfo.get("preferred_username", "?"))
        return RedirectResponse(url="/")

    @app.get("/auth/logout")
    async def auth_logout(request: Request):
        """Session loeschen und zu Authentik End-Session weiterleiten."""
        request.session.clear()

        # Authentik End-Session URL (optional)
        authentik_base = os.getenv("AUTHENTIK_BASE_URL", "")
        if authentik_base:
            return RedirectResponse(
                url=f"{authentik_base}/application/o/jarvis-admin-portal/end-session/"
            )

        return RedirectResponse(url="/auth/login")

    # SessionMiddleware MUSS nach auth_middleware registriert werden.
    # add_middleware() fuegt aussen hinzu → zuletzt hinzugefuegt = laeuft zuerst.
    # So ist die Reihenfolge: Request → SessionMiddleware → auth_middleware → App
    app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET)


def get_current_user(request: Request) -> dict | None:
    """Gibt den eingeloggten User aus der Session zurueck (oder None)."""
    if not OIDC_ENABLED:
        return None
    return request.session.get("user")
