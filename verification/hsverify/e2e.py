"""Send scenes through the placement server's HTTP API and judge every answer.

    uv run python -m hsverify.e2e --server-ref origin/t3/server            # cases/ + real scenes
    uv run python -m hsverify.e2e --server-url http://127.0.0.1:8000 --scene path/to/scene.json

The server under test is either started from a git ref (a detached worktree under /tmp,
`uv sync --locked`, then uvicorn on a free port) or reached at `--server-url`. Its scene
endpoint is read from its OpenAPI document; with more than one candidate the run stops and
asks for `--endpoint` instead of guessing.

Each scene is first validated against the scene schema published at the same ref, so a bad
input is reported as an input problem, not a server bug. Each response must validate against
the result schema and pass the invariants in `resultcheck`. Case files add the outcomes their
geometry forces. Every scene is also sent three more ways: again (the result must be
identical apart from timing), mirrored left to right (same decision, same length of passing,
unsure and failing wall), and without coverage (never a pass).

Reports go to ~/house-scanning-data/reports/e2e/<run>/ (outside git; real scenes can
reference dataset images).
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import io
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

from hsverify import gitref
from hsverify.resultcheck import (
    assumption_mismatches,
    comparable,
    expectation_problems,
    invariant_problems,
    mirror_scene,
    outcome_lengths,
    schema_errors,
)

HERE = Path(__file__).resolve().parents[1]
DEFAULT_CASES = HERE / "e2e" / "cases"
DEFAULT_REPORTS = Path.home() / "house-scanning-data" / "reports" / "e2e"
SCENE_SCHEMA = "server/schemas/scene.schema.json"
RESULT_SCHEMA = "server/schemas/result.schema.json"
# The plan's S2 metric: a real-derived scene returns a result in under 1 s.
LATENCY_BUDGET_MS = 1000.0
MIRROR_LENGTH_TOL_FT = 0.5


# --- Inputs ----------------------------------------------------------------------------------


@dataclass
class SceneInput:
    name: str
    scene: dict
    raw: bytes  # exactly the bytes sent, so the server's input hash can be checked
    images: dict[str, bytes] = field(default_factory=dict)
    expect: dict | None = None
    rules_assumed: dict[str, float] = field(default_factory=dict)
    real: bool = False
    source: str = ""
    skip_reason: str | None = None
    app_export: bool = False  # exported by the iOS app (from a replay), the S4 end-to-end path


def load_input(path: Path, real: bool = False) -> SceneInput:
    """A case file (scene + expect), a bare scene.json, or a C1 zip bundle."""
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as bundle:
            names = bundle.namelist()
            scene_name = next((n for n in names if n.endswith("scene.json")), None)
            if scene_name is None:
                raise SystemExit(f"{path}: no scene.json in the bundle")
            raw = bundle.read(scene_name)
            images = {Path(n).name: bundle.read(n) for n in names if n.lower().endswith(".jpg")}
        return SceneInput(path.stem, json.loads(raw), raw, images, real=real, source=str(path))
    data = json.loads(path.read_text())
    if "scene" in data and "expect" in data:
        raw = json.dumps(data["scene"], indent=1).encode()
        return SceneInput(
            data.get("id", path.stem),
            data["scene"],
            raw,
            expect=data["expect"],
            rules_assumed=data.get("rules_assumed", {}),
            real=bool(data.get("real", real)),
            source=data.get("source", str(path)),
            skip_reason=data.get("skip_reason"),
        )
    return SceneInput(path.stem, data, path.read_bytes(), real=real, source=str(path))


# --- Server ----------------------------------------------------------------------------------


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def find_app(server_dir: Path) -> str:
    """`module:variable` of the FastAPI app. Exactly one is required."""
    found = []
    for path in sorted(server_dir.glob("*.py")):
        for match in re.finditer(r"^(\w+)\s*=\s*FastAPI\(", path.read_text(), re.M):
            found.append(f"{path.stem}:{match.group(1)}")
    if len(found) != 1:
        raise SystemExit(
            f"Expected one `app = FastAPI(...)` in {server_dir}, found {found or 'none'}. "
            "Start the server yourself and pass --server-url."
        )
    return found[0]


SHIM = Path(__file__).with_name("solver_shim.py")


@contextlib.contextmanager
def server_from_ref(sha: str, log_path: Path, via_shim: bool = False) -> Iterator[str]:
    """The server at `sha` on a free port: its own FastAPI app, or `solver_shim` around `solve`."""
    with gitref.detached_worktree(sha) as tree:
        server_dir = tree / "server"
        subprocess.run(["uv", "sync", "--locked", "--quiet"], cwd=server_dir, check=True)
        port = free_port()
        url = f"http://127.0.0.1:{port}"
        if via_shim:
            target = ["python", str(SHIM), "--server-dir", str(server_dir), "--port", str(port)]
        else:
            target = ["uvicorn", find_app(server_dir), "--host", "127.0.0.1", "--port", str(port)]
        with log_path.open("w") as log:
            proc = subprocess.Popen(
                ["uv", "run", "--quiet", *target],
                cwd=server_dir,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                wait_until_up(url, proc)
                yield url
            finally:
                proc.terminate()
                proc.wait(timeout=10)


def wait_until_up(url: str, proc: subprocess.Popen, timeout_s: float = 60) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise SystemExit(f"The server exited with code {proc.returncode}; see server.log.")
        try:
            urllib.request.urlopen(f"{url}/openapi.json", timeout=2).read()
            return
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            time.sleep(0.5)
    raise SystemExit(f"The server did not answer at {url} within {timeout_s:.0f} s.")


@dataclass
class Endpoint:
    path: str
    content_type: str  # "application/json" or "multipart/form-data"
    file_field: str | None = None


def discover_endpoint(openapi: dict, override: str | None = None) -> Endpoint:
    """The POST operation that takes a scene: JSON body, or a multipart upload of the bundle."""
    candidates = []
    for path, ops in openapi.get("paths", {}).items():
        body = ops.get("post", {}).get("requestBody", {}).get("content", {})
        for kind in ("application/json", "multipart/form-data"):
            if kind in body:
                candidates.append((path, kind, body[kind].get("schema", {})))
    if override:
        declared = [c for c in candidates if c[0] == override]
        # An endpoint that reads the raw request body declares no body schema; the caller has
        # named it, so it takes the scene as JSON.
        if not declared and "post" in openapi.get("paths", {}).get(override, {}):
            declared = [(override, "application/json", {})]
        if not declared:
            raise SystemExit(f"--endpoint {override} is not a POST in the server's OpenAPI")
        candidates = declared
    elif len(candidates) > 1:
        named = [c for c in candidates if re.search(r"scene|place|solve|placement", c[0])]
        candidates = named if len(named) == 1 else candidates
    if len(candidates) != 1:
        listed = ", ".join(f"{p} ({k})" for p, k, _ in candidates) or "none"
        raise SystemExit(f"Cannot tell which endpoint takes a scene: {listed}. Pass --endpoint.")
    path, kind, schema = candidates[0]
    file_field = None
    if kind == "multipart/form-data":
        props = resolve_ref(openapi, schema).get("properties", {})
        binary = [
            k
            for k, v in props.items()
            if v.get("format") == "binary"
            or v.get("contentMediaType") == "application/octet-stream"
        ]
        if len(binary) != 1:
            raise SystemExit(f"{path}: expected one file field in the upload form, got {binary}")
        file_field = binary[0]
    return Endpoint(path, kind, file_field)


def resolve_ref(openapi: dict, schema: dict) -> dict:
    ref = schema.get("$ref")
    if not ref:
        return schema
    node = openapi
    for part in ref.removeprefix("#/").split("/"):
        node = node[part]
    return node


def bundle_zip(item: SceneInput) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("scene.json", item.raw)
        for name, data in item.images.items():
            z.writestr(name, data)
    return buf.getvalue()


def post(url: str, endpoint: Endpoint, item: SceneInput) -> tuple[int, bytes, float]:
    if endpoint.content_type == "application/json":
        body, ctype = item.raw, "application/json"
    else:
        boundary = uuid.uuid4().hex
        body = (
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="{endpoint.file_field}"; '
                f'filename="scene.zip"\r\nContent-Type: application/zip\r\n\r\n'
            ).encode()
            + bundle_zip(item)
            + f"\r\n--{boundary}--\r\n".encode()
        )
        ctype = f"multipart/form-data; boundary={boundary}"
    request = urllib.request.Request(
        url + endpoint.path, data=body, headers={"Content-Type": ctype}, method="POST"
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            status, payload = response.status, response.read()
    except urllib.error.HTTPError as exc:
        status, payload = exc.code, exc.read()
    return status, payload, (time.perf_counter() - start) * 1000


# --- Judging ---------------------------------------------------------------------------------


def variant(item: SceneInput, name: str, scene: dict) -> SceneInput:
    raw = json.dumps(scene, indent=1).encode()
    return SceneInput(f"{item.name}~{name}", scene, raw, real=item.real, source=item.source)


def judge(url: str, endpoint: Endpoint, item: SceneInput, schemas: dict) -> dict:
    record: dict = {
        "name": item.name,
        "source": item.source,
        "real": item.real,
        "app_export": item.app_export,
    }
    if item.skip_reason:
        return record | {"status": "skipped", "problems": [], "skip_reason": item.skip_reason}
    input_errors = schema_errors(item.scene, schemas["scene"])
    if input_errors:
        return record | {"status": "bad input", "problems": input_errors[:20]}

    status, payload, ms = post(url, endpoint, item)
    record |= {"http_status": status, "latency_ms": round(ms, 1)}
    if status != 200:
        failure = [f"HTTP {status} for a scene that validates: {payload[:500]!r}"]
        return record | {"status": "fail", "problems": failure, "contract_problems": failure}
    result = json.loads(payload)
    record["result"] = result
    problems = [f"result schema: {e}" for e in schema_errors(result, schemas["result"])]
    if problems:
        return record | {"status": "fail", "problems": problems[:20], "contract_problems": problems}

    # Contract problems hold for any scene; expectation problems depend on one case's geometry.
    contract = problems + invariant_problems(item.scene, result, sent=item.raw)
    contract += property_problems(url, endpoint, item, result)
    if item.real and ms > LATENCY_BUDGET_MS:
        contract.append(f"real-derived scene took {ms:.0f} ms, budget {LATENCY_BUDGET_MS:.0f}")
    mismatches = assumption_mismatches(item.rules_assumed, result)
    expected = expectation_problems(item.expect, result) if item.expect and not mismatches else []
    problems = contract + expected

    record["decision"] = result["decision"]
    record["outcome_lengths_ft"] = outcome_lengths(result)
    if mismatches:
        record["assumption_mismatches"] = mismatches
    record["contract_problems"] = contract
    record["expectation_problems"] = expected
    record["problems"] = problems
    record["status"] = "fail" if problems else "assumption mismatch" if mismatches else "pass"
    return record


def property_problems(url: str, endpoint: Endpoint, item: SceneInput, result: dict) -> list[str]:
    problems = []
    # 1. Same input, same answer.
    status, payload, _ = post(url, endpoint, item)
    if status != 200 or comparable(json.loads(payload)) != comparable(result):
        problems.append("sending the same scene twice gave different results")
    # 2. Mirrored left to right: same decision, same amount of each outcome along the wall.
    mirrored = variant(item, "mirror", mirror_scene(item.scene))
    status, payload, _ = post(url, endpoint, mirrored)
    if status != 200:
        problems.append(f"mirrored scene: HTTP {status}")
    else:
        other = json.loads(payload)
        if other["decision"] != result["decision"]:
            problems.append(
                f"mirrored scene decided {other['decision']}, original {result['decision']}"
            )
        a, b = outcome_lengths(result), outcome_lengths(other)
        for outcome in a:
            if abs(a[outcome] - b[outcome]) > MIRROR_LENGTH_TOL_FT:
                problems.append(
                    f"mirrored scene: {outcome} starts cover {b[outcome]:.2f} ft, "
                    f"original {a[outcome]:.2f} ft"
                )
    # 3. Without coverage nothing was observed, so nothing may pass.
    if "coverage" in item.scene:
        bare = {k: v for k, v in item.scene.items() if k != "coverage"}
        status, payload, _ = post(url, endpoint, variant(item, "no-coverage", bare))
        if status != 200:
            problems.append(f"scene without coverage: HTTP {status}")
        else:
            other = json.loads(payload)
            if other["decision"] == "pass" or any(
                r["outcome"] == "pass" for r in other.get("sweep", [])
            ):
                problems.append("scene without coverage still produced a pass")
    return problems


# --- Report ----------------------------------------------------------------------------------


def write_report(out: Path, meta: dict, records: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for r in records:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    real = [r["latency_ms"] for r in records if r.get("real") and "latency_ms" in r]
    exported = [r for r in records if r.get("app_export")]
    report = meta | {
        "counts": counts,
        "all_passed": all(r["status"] in ("pass", "skipped") for r in records) and bool(records),
        "latency_ms": max(real) if real else None,
        "scenes_answered": sum(1 for r in records if "decision" in r),
        # Invariants and properties broken, summed over every answered scene. Case
        # expectations are counted separately because a case can be wrong itself.
        "contract_problem_count": sum(len(r.get("contract_problems", [])) for r in records),
        "expectation_problem_count": sum(len(r.get("expectation_problems", [])) for r in records),
        "real_scene_passed": any(r.get("real") and r["status"] == "pass" for r in records),
        # Null when the run had no app export, so the scoreboard looks for an older run.
        "app_export_scene_valid": all(r["status"] != "bad input" for r in exported)
        if exported
        else None,
        "app_export_passed": all(r["status"] == "pass" for r in exported) if exported else None,
        "records": records,
    }
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = [
        f"# End-to-end run against `{meta['server_ref']}` at `{meta['server_sha'][:12]}`",
        "",
        f"{meta['started_at']}. Endpoint `{meta['endpoint']}` via {meta['transport']}. "
        f"Load average {meta['load_average_1_5_15']} on {os.cpu_count()} cores. "
        + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())),
        "",
        "| Scene | Status | Decision | ms | Problems |",
        "| --- | --- | --- | --- | --- |",
    ]
    for r in records:
        issues = "; ".join(r.get("problems", []) + r.get("assumption_mismatches", []))
        issues = issues or r.get("skip_reason", "")
        lines.append(
            f"| {r['name']}{' (real)' if r.get('real') else ''} | {r['status']} | "
            f"{r.get('decision', '')} | {r.get('latency_ms', '')} | {issues.replace('|', '/')} |"
        )
    (out / "report.md").write_text("\n".join(lines) + "\n")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    where = parser.add_mutually_exclusive_group()
    where.add_argument("--server-ref", default="origin/t3/server")
    where.add_argument("--server-url", help="use a running server instead of starting one")
    parser.add_argument("--schema-ref", help="ref for the schemas (default: --server-ref)")
    parser.add_argument("--endpoint", help="POST path, when discovery is ambiguous")
    parser.add_argument(
        "--via-shim",
        action="store_true",
        help="serve the ref's solver.solve through solver_shim (before the ref has an API)",
    )
    parser.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    parser.add_argument(
        "--scene",
        type=Path,
        action="append",
        default=[],
        help="extra case file, scene.json or scene.zip",
    )
    parser.add_argument(
        "--real",
        type=Path,
        action="append",
        default=[],
        help="scene derived from real data; held to the latency budget",
    )
    parser.add_argument(
        "--app-export",
        type=Path,
        action="append",
        default=[],
        help="scene.json or bundle the iOS app exported from a replay (real, latency budget)",
    )
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)

    gitref.fetch()
    schema_ref = args.schema_ref or (args.server_ref if not args.server_url else "origin/t3/server")
    schema_sha = gitref.resolve(schema_ref)
    schemas = {}
    for key, path in (("scene", SCENE_SCHEMA), ("result", RESULT_SCHEMA)):
        text = gitref.show(schema_sha, path)
        if text is None:
            raise SystemExit(f"{path} does not exist at {schema_ref}")
        schemas[key] = json.loads(text)

    items = (
        [load_input(p) for p in sorted(args.cases.glob("*.json"))] if args.cases.exists() else []
    )
    items += [load_input(p) for p in args.scene]
    items += [load_input(p, real=True) for p in args.real]
    for path in args.app_export:
        exported = load_input(path, real=True)
        exported.app_export = True
        items.append(exported)
    if not items:
        raise SystemExit("No scenes: add case files to e2e/cases or pass --scene/--real.")

    server_sha = "(running server)" if args.server_url else gitref.resolve(args.server_ref)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = (args.out or DEFAULT_REPORTS / f"{stamp}-{server_sha[:8]}").expanduser()
    out.mkdir(parents=True, exist_ok=True)

    with contextlib.ExitStack() as stack:
        url = args.server_url or stack.enter_context(
            server_from_ref(server_sha, out / "server.log", via_shim=args.via_shim)
        )
        openapi = json.loads(urllib.request.urlopen(f"{url}/openapi.json", timeout=10).read())
        endpoint = discover_endpoint(openapi, args.endpoint)
        print(f"Server {url}, endpoint POST {endpoint.path} ({endpoint.content_type})")
        records = []
        for item in items:
            record = judge(url, endpoint, item, schemas)
            records.append(record)
            print(
                f"  {record['status']:<20} {item.name}"
                + (
                    f"  [{record.get('decision')}, {record.get('latency_ms')} ms]"
                    if "decision" in record
                    else ""
                )
            )
            for problem in record.get("problems", [])[:6]:
                print(f"      - {problem}")

    meta = {
        "started_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "server_ref": args.server_url or args.server_ref,
        "server_sha": server_sha,
        "schema_ref": schema_ref,
        "schema_sha": schema_sha,
        "sha": server_sha,
        "endpoint": f"POST {endpoint.path} ({endpoint.content_type})",
        "transport": "solver shim (HTTP layer not tested)" if args.via_shim else "server API",
        "command": " ".join([sys.executable, "-m", "hsverify.e2e", *(argv or sys.argv[1:])]),
        # Latency on this shared Mac depends on what else runs; keep the load with the numbers.
        "load_average_1_5_15": [round(x, 1) for x in os.getloadavg()],
        "cases_sha256": hashlib.sha256(b"".join(i.raw for i in items)).hexdigest(),
    }
    report = write_report(out, meta, records)
    print(f"Report: {out / 'report.md'}")
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
