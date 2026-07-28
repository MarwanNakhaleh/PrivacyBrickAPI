"""Smoke tests that run anywhere (no Pi services required)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("PRIVACYBRICK_STATE_DIR", str(tmp_path))
    monkeypatch.setenv("PRIVACYBRICK_MDNS_ENABLED", "false")
    # Re-import with a clean state dir.
    import importlib

    from privacybrick_api import config

    importlib.reload(config)
    from privacybrick_api import auth, main

    importlib.reload(auth)
    importlib.reload(main)
    with TestClient(main.app) as test_client:
        yield test_client, auth


def test_ping_is_unauthenticated(client):
    test_client, _ = client
    resp = test_client.get("/api/v1/ping")
    assert resp.status_code == 200
    assert resp.json()["app"] == "privacybrick"


def test_overview_requires_token(client):
    test_client, _ = client
    assert test_client.get("/api/v1/overview").status_code == 401


def test_pairing_flow(client):
    test_client, auth = client
    code = auth.open_pairing_window()

    wrong = test_client.post("/api/v1/pair", json={"code": "000000", "client_name": "t"})
    # A wrong guess must not consume the window unless it matched.
    if code != "000000":
        assert wrong.status_code == 403

    resp = test_client.post("/api/v1/pair", json={"code": code, "client_name": "test"})
    assert resp.status_code == 200
    token = resp.json()["token"]

    # Token unlocks authenticated endpoints (overview may 200 even when the
    # underlying services are absent — health() degrades gracefully).
    resp = test_client.get(
        "/api/v1/overview", headers={"Authorization": f"Bearer {token}"}
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "services" in body and isinstance(body["services"], list)

    # Codes are single-use.
    resp = test_client.post("/api/v1/pair", json={"code": code, "client_name": "again"})
    assert resp.status_code == 403
