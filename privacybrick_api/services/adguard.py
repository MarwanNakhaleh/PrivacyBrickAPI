"""AdGuard Home — proxied via its local REST API (http://127.0.0.1:3000).

Presented to the app as "Ad Blocking". The API credentials are the AdGuard
Home admin credentials, configured in /etc/privacybrick/.env at install time;
the phone never sees them.
"""

from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..auth import require_token
from ..config import settings
from ..models import ActionResponse, ServiceHealth

router = APIRouter(prefix="/adguard", tags=["adguard"], dependencies=[Depends(require_token)])


def _client() -> httpx.AsyncClient:
    auth = None
    if settings.adguard_username:
        auth = (settings.adguard_username, settings.adguard_password)
    return httpx.AsyncClient(base_url=settings.adguard_url, auth=auth, timeout=10.0)


async def health() -> ServiceHealth:
    try:
        async with _client() as client:
            resp = await client.get("/control/status")
            resp.raise_for_status()
            data = resp.json()
        return ServiceHealth(
            id="adguard",
            name="Ad Blocking",
            running=data.get("running", False) and data.get("protection_enabled", False),
            detail="protecting" if data.get("protection_enabled") else "paused",
        )
    except httpx.HTTPError as exc:
        return ServiceHealth(id="adguard", name="Ad Blocking", running=False, installed=False, detail=str(exc))


@router.get("/status")
async def get_status() -> dict:
    try:
        async with _client() as client:
            resp = await client.get("/control/status")
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"AdGuard Home unreachable: {exc}")


@router.get("/stats")
async def get_stats() -> dict:
    """Friendly stats: queries today, ads blocked, percent blocked, top blocked."""
    try:
        async with _client() as client:
            resp = await client.get("/control/stats")
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"AdGuard Home unreachable: {exc}")
    total = data.get("num_dns_queries", 0)
    blocked = data.get("num_blocked_filtering", 0)
    return {
        "total_queries": total,
        "blocked": blocked,
        "blocked_percent": round(100 * blocked / total, 1) if total else 0.0,
        "avg_processing_ms": data.get("avg_processing_time", 0) * 1000,
        "top_blocked_domains": data.get("top_blocked_domains", []),
        "top_clients": data.get("top_clients", []),
    }


class ProtectionRequest(BaseModel):
    enabled: bool


@router.post("/protection")
async def set_protection(body: ProtectionRequest) -> ActionResponse:
    """The big friendly on/off switch for ad blocking."""
    try:
        async with _client() as client:
            resp = await client.post("/control/protection", json={"enabled": body.enabled})
            resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"AdGuard Home unreachable: {exc}")
    return ActionResponse(
        ok=True, message="Ad blocking on" if body.enabled else "Ad blocking paused"
    )


@router.get("/querylog")
async def get_querylog(limit: int = 25) -> dict:
    try:
        async with _client() as client:
            resp = await client.get("/control/querylog", params={"limit": limit})
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"AdGuard Home unreachable: {exc}")
