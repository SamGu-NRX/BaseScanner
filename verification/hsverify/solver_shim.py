"""Serve the server branch's `solve` over HTTP until that branch has its own API.

Runs inside the server's own environment (`uv run --project <tree>/server python this.py`),
imports its `rules`, `scene` and `solver` modules unchanged, and exposes one POST endpoint
plus a minimal OpenAPI document so `hsverify.e2e` can discover it. Only the public rules load:
the worktree has no `private/` folder and the override variable is cleared.

Results through this shim test the solver and the ingest code, not the server's HTTP layer.
Stdlib only, because it runs in someone else's environment.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OPENAPI = {
    "openapi": "3.1.0",
    "info": {"title": "hsverify solver shim", "version": "1"},
    "paths": {
        "/shim/scene": {"post": {"requestBody": {"content": {"application/json": {"schema": {}}}}}}
    },
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-dir", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    os.environ.pop("HOUSESCAN_PRIVATE_RULES", None)
    sys.path.insert(0, args.server_dir)
    from rules import load_rules
    from scene import SceneError, parse_scene
    from solver import solve

    loaded = load_rules(None)

    class Handler(BaseHTTPRequestHandler):
        def _send(self, status: int, payload: object) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/openapi.json":
                self._send(200, OPENAPI)
            else:
                self._send(404, {"detail": "not found"})

        def do_POST(self) -> None:
            if self.path != "/shim/scene":
                self._send(404, {"detail": "not found"})
                return
            body = self.rfile.read(int(self.headers["Content-Length"]))
            try:
                scene = parse_scene(json.loads(body), loaded.rules, input_bytes=body)
                self._send(200, solve(scene, loaded))
            except (SceneError, ValueError) as exc:
                self._send(422, {"detail": str(exc)})
            except Exception as exc:  # a solver crash is a finding, not a shim failure
                self._send(500, {"detail": f"{type(exc).__name__}: {exc}"})

        def log_message(self, *args: object) -> None:
            pass

    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
