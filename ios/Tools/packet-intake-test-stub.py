#!/usr/bin/env python3
"""A local stand-in for a packet intake, for tests only. It is not any server's API.

The app's Debug-only `LocalTestIntake` (HouseScan/Runtime/PacketUpload/PacketIntakes.swift)
calls it with `-packetUploadURL http://127.0.0.1:<port> -packetIntake localTest`. Its three
calls mirror `PacketIntake` (begin, commit, finish) with HouseScanKit's own types as JSON, and it
takes the uploads itself at URLs it hands out, checking each file's size and SHA-256. Everything
stays in memory; nothing is forwarded. Binds 127.0.0.1 only.

    python3 ios/Tools/packet-intake-test-stub.py --port 8791 --put-delay 0.4

`GET /_log` returns what it received; `POST /_reset` forgets everything.
"""

import argparse
import hashlib
import json
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
STATE = {}


def reset():
    STATE.clear()
    STATE.update(files={}, stored={}, generation=0, begins=[], puts=[], commits=[], finishes=[], scan_id=None)


reset()


class Handler(BaseHTTPRequestHandler):
    put_delay = 0.0

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} {fmt % args}", flush=True)

    def reply(self, status, body=None):
        data = json.dumps(body if body is not None else {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def do_GET(self):
        if self.path != "/_log":
            return self.reply(404)
        with LOCK:
            self.reply(200, {
                "files": len(STATE["files"]),
                "stored": sorted(STATE["stored"]),
                "begins": STATE["begins"],
                "puts": STATE["puts"],
                "commits": STATE["commits"],
                "finishes": STATE["finishes"],
                "completed": any(f["complete"] for f in STATE["finishes"]),
                "scan_id": STATE["scan_id"],
            })

    def do_POST(self):
        if self.path == "/_reset":
            with LOCK:
                reset()
            return self.reply(200)
        try:
            body = json.loads(self.body() or b"{}")
        except ValueError:
            return self.reply(400, {"error": "not JSON"})
        if self.path == "/test-intake/begin":
            request = body.get("request") or {}
            files = {f["path"]: f for f in request.get("files", [])}
            if not files or not request.get("consent", {}).get("textID"):
                return self.reply(400, {"error": "no files or no consent"})
            with LOCK:
                STATE["generation"] += 1
                generation = STATE["generation"]
                STATE["files"] = files
                STATE["scan_id"] = request.get("scanID")
                stored = sorted(p for p in files if p in STATE["stored"])
                STATE["begins"].append({"generation": generation, "resuming": body.get("resuming"), "stored": stored,
                                        "at": time.time(), "consent": request["consent"]})
            host = self.headers.get("Host")
            expires = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
            targets = [{"path": p, "method": "PUT", "url": f"http://{host}/bucket/g{generation}/{p}",
                        "headers": {"Content-Type": f["contentType"]}}
                       for p, f in files.items() if p not in stored]
            return self.reply(200, {"id": "test-session", "expiresAt": expires, "stored": stored, "targets": targets})
        if self.path == "/test-intake/commit":
            paths = body.get("paths", [])
            with LOCK:
                taken = sorted(p for p in paths if p in STATE["stored"])
                STATE["commits"].append({"paths": len(paths), "taken": len(taken), "at": time.time()})
            return self.reply(200, {"session": "test-session", "paths": taken})
        if self.path == "/test-intake/finish":
            with LOCK:
                missing = sorted(p for p in STATE["files"] if p not in STATE["stored"])
                STATE["finishes"].append({"complete": not missing, "missing": missing, "at": time.time()})
            if missing:
                return self.reply(200, {"complete": False, "missing": missing})
            return self.reply(200, {"complete": True, "reference": "test-reference"})
        self.reply(404)

    def do_PUT(self):
        parts = self.path.split("/", 3)  # "", "bucket", "g<n>", "<path>"
        if len(parts) != 4 or parts[1] != "bucket" or self.headers.get("Authorization"):
            return self.reply(403, {"error": "not an upload URL, or an API key sent to storage"})
        body = self.body()
        time.sleep(self.put_delay)
        path, generation = parts[3], int(parts[2][1:])
        with LOCK:
            expected = STATE["files"].get(path)
            ok = expected is not None and len(body) == expected["bytes"] \
                and hashlib.sha256(body).hexdigest() == expected["sha256"]
            if ok:
                STATE["stored"][path] = True
            STATE["puts"].append({"path": path, "generation": generation, "ok": ok, "bytes": len(body), "at": time.time()})
        self.reply(200 if ok else 400)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8791)
    parser.add_argument("--put-delay", type=float, default=0.0, help="seconds each upload takes, to leave time to kill the app")
    args = parser.parse_args()
    Handler.put_delay = args.put_delay
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"packet intake test stub on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
