#!/usr/bin/env python3
"""A local stand-in for the capture API, for the integration UI tests (IntegrationUITests).

It runs on this Mac's loopback, where the Simulator app can reach it, and answers the calls the
app's uploader makes: create, register, the storage PUT (Content-MD5 checked), commit, finalize,
events and result. Every request is appended as one JSON line to <log dir>/<run>.jsonl, where the
UI test reads it back. A run is the first path segment, so each test gets its own endpoint
(http://127.0.0.1:<port>/<run>/v1) and its own log. Nothing is forwarded anywhere, and only request
shapes are logged, never file bytes.

    python3 ios/Tools/capture-receiver.py --port 8767 --log-dir /Users/Shared/hsi-capture-receiver

The log folder is a path on this Mac that the Simulator's test runner can read too.
"""

import argparse
import base64
import hashlib
import json
import os
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
CAPTURES = {}  # (run, captureId) -> {"packetId", "createBody", "registered": {path: reg}, "stored": {path: sha256}, "committed": set()}
BY_PACKET = {}  # (run, packetId) -> captureId
TOKENS = {}  # token -> (run, captureId, path)


def route(parts, method):
    """'POST captures/files'-style names, ids replaced, as the tests query them."""
    if len(parts) >= 2 and parts[1] == "upload":
        return f"{method} upload"
    rest = parts[2:]  # after <run>/v1
    if rest == ["captures"]:
        return f"{method} captures"
    if len(rest) >= 3 and rest[0] == "captures":
        return f"{method} captures/{'/'.join(rest[2:])}"
    return f"{method} {'/'.join(rest)}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    log_dir = "/Users/Shared/hsi-capture-receiver"

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, code):
        self.reply(status, {"errors": [{"code": code, "pointer": "/", "message": code}]})

    def record(self, run, name, body):
        entry = {
            "at": datetime.now(timezone.utc).isoformat(),
            "run": run,
            "route": name,
            "authorization": "Authorization" in self.headers,
            "contentMD5": "Content-MD5" in self.headers,
            "bytes": len(body),
        }
        if name == "POST captures/files:commit":
            try:
                entry["commitFiles"] = len(json.loads(body)["files"])
            except (ValueError, KeyError, TypeError):
                pass
        with LOCK, open(os.path.join(self.log_dir, f"{run}.jsonl"), "a") as log:
            log.write(json.dumps(entry) + "\n")

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if parts == ["health"]:
            return self.reply(200, {"status": "ok"})
        if len(parts) < 2:
            return self.error(404, "route")
        run = parts[0]
        name = route(parts, method)
        self.record(run, name, body)
        with LOCK:
            return self.answer(run, parts, method, name, body)

    def answer(self, run, parts, method, name, body):
        port = self.server.server_address[1]
        if name == "PUT upload":
            found = TOKENS.get(parts[-1])
            if not found:
                return self.reply(403, b"token_invalid")
            _, capture_id, path = found
            capture = CAPTURES[(run, capture_id)]
            reg = capture["registered"][path]
            md5 = base64.b64encode(hashlib.md5(body).digest()).decode()
            if self.headers.get("Content-MD5") != reg["md5"] or md5 != reg["md5"]:
                return self.reply(400, b"<Error><Code>BadDigest</Code></Error>")
            capture["stored"][path] = hashlib.sha256(body).hexdigest()
            return self.reply(200, b"")
        if "Authorization" in self.headers:
            return self.error(400, "unexpected_authorization")
        if name == "POST captures":
            request = json.loads(body or b"{}")
            packet_id = request.get("packetId")
            if self.headers.get("Idempotency-Key") != packet_id:
                return self.error(422, "idempotency_key_mismatch")
            existing = BY_PACKET.get((run, packet_id))
            if existing:
                if CAPTURES[(run, existing)]["createBody"] != body:
                    return self.error(409, "idempotency_conflict")
                capture_id, status = existing, 200
            else:
                capture_id, status = f"cap_{uuid.uuid4().hex[:12]}", 201
                BY_PACKET[(run, packet_id)] = capture_id
                CAPTURES[(run, capture_id)] = {"packetId": packet_id, "createBody": body, "registered": {}, "stored": {}, "committed": set()}
            return self.reply(status, {
                "captureId": capture_id, "status": "uploading", "eventsUrl": f"/v1/captures/{capture_id}/events",
                "finalizeBy": "2099-01-01T00:00:00Z", "upload": {"maxBatch": 50, "maxSinglePutBytes": 16777216, "urlTtlS": 3600, "maxFiles": 2000},
            })
        capture = CAPTURES.get((run, parts[3])) if len(parts) > 3 else None
        if capture is None:
            return self.error(404, "capture_not_found")
        if name == "POST captures/files":
            out = []
            for f in json.loads(body)["files"]:
                capture["registered"][f["path"]] = {"sha256": f["sha256"], "md5": f["md5"], "contentType": f["contentType"]}
                if f["path"] in capture["committed"]:
                    out.append({"path": f["path"], "state": "committed"})
                    continue
                token = uuid.uuid4().hex
                TOKENS[token] = (run, parts[3], f["path"])
                out.append({"path": f["path"], "state": "pending", "upload": {
                    "method": "PUT", "url": f"http://127.0.0.1:{port}/{run}/upload/{token}",
                    "headers": {"Content-Type": f["contentType"], "Content-MD5": f["md5"]}, "expiresAt": "2099-01-01T00:00:00Z"}})
            return self.reply(200, {"files": out})
        if name == "POST captures/files:commit":
            committed, not_found, mismatch = [], [], []
            for f in json.loads(body)["files"]:
                stored = capture["stored"].get(f["path"])
                if stored is None:
                    not_found.append(f["path"])
                elif stored != f["sha256"]:
                    mismatch.append(f["path"])
                else:
                    committed.append(f["path"])
                    capture["committed"].add(f["path"])
            return self.reply(200, {"committed": committed, "notFound": not_found, "mismatch": mismatch})
        if name == "POST captures/finalize":
            return self.reply(202, {"status": "awaiting_files", "missing": [], "runId": "run_local", "etaS": 1})
        if name == "GET captures/events":
            return self.reply(200, {"status": "processing", "next": 0, "events": []})
        return self.error(404, "result_not_ready")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--log-dir", default="/Users/Shared/hsi-capture-receiver")
    args = parser.parse_args()
    os.makedirs(args.log_dir, exist_ok=True)
    Handler.log_dir = args.log_dir
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"capture receiver on http://127.0.0.1:{args.port}, logs in {args.log_dir}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
