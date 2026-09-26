"""Posting a scene to the placement server (server/README.md, "API", on t3/server)."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://house-scanning-server.vercel.app"
TIMEOUT_S = 60


def _post(url: str, body: bytes) -> tuple[int, bytes]:
    headers = {"Content-Type": "application/json"}
    if key := os.environ.get("HOUSESCAN_API_KEY"):  # the key-protected deployment, when it exists
        headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def place(scene: dict, base_url: str, out: Path) -> dict:
    """POSTs bare scene.json (the server reads no images, and Vercel caps bodies at 4.5 MB) and
    saves result.json and site-plan.svg. A refusal is saved too, then raised."""
    body = json.dumps(scene).encode()
    status, data = _post(f"{base_url.rstrip('/')}/v1/placements", body)
    (out / "result.json").write_bytes(data)
    if status != 200:
        raise RuntimeError(
            f"server refused the scene ({status}): {data[:500].decode(errors='replace')}"
        )
    status, svg = _post(f"{base_url.rstrip('/')}/v1/placements/site-plan.svg", body)
    if status == 200:
        (out / "site-plan.svg").write_bytes(svg)
    return json.loads(data)
