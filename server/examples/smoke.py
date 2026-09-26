"""Post each example scene to a placement server and print its decision.

    python3 server/examples/smoke.py URL [--key-file PATH]

The key file holds a line HOUSESCAN_API_KEY=<key> (server/.env.private.local for the private
deployment). Standard library only, so it runs without the server's environment. Exits 1 when a
request fails.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

EXAMPLES = Path(__file__).resolve().parent


def read_key(path: Path) -> str:
    for line in path.read_text().splitlines():
        name, _, value = line.partition("=")
        if name.strip() == "HOUSESCAN_API_KEY" and value.strip():
            return value.strip()
    raise SystemExit(f"{path}: no HOUSESCAN_API_KEY=<key> line")


def post(url: str, body: bytes, key: str | None) -> tuple[int, dict]:
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        text = error.read().decode(errors="replace")
        try:
            return error.code, json.loads(text)
        except json.JSONDecodeError:
            # Not the placement server's error format: another server, or its host.
            return error.code, {"error": {"code": "not_json", "message": text[:120]}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "url", help="server root, for example https://house-scanning-server.vercel.app"
    )
    parser.add_argument("--key-file", type=Path, help="file with HOUSESCAN_API_KEY=<key>")
    args = parser.parse_args()
    key = read_key(args.key_file) if args.key_file else None
    endpoint = args.url.rstrip("/") + "/v1/placements"
    failed = False
    for scene in sorted(EXAMPLES.glob("*.json")):
        status, body = post(endpoint, scene.read_bytes(), key)
        if status == 200:
            # Which rules answered, not the private policy's name.
            rules = "+".join(body["policy"]["sources"])
            print(f"{scene.stem:30} {body['decision']:14} rules {rules}: {body['summary']}")
        else:
            failed = True
            error = body.get("error", {})
            print(f"{scene.stem:30} HTTP {status}      {error.get('code')}: {error.get('message')}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
