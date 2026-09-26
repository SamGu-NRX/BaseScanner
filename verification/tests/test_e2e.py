import hashlib
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from hsverify.e2e import Endpoint, SceneInput, discover_endpoint, judge, load_input

SCENE = {
    "meter": {"pos": [0.0, 4.0, 0.0], "wall_id": "w1"},
    "walls": [{"id": "w1", "baseline": [[-10.0, 0.0], [10.0, 0.0]]}],
    "coverage": {"observed": [{"band": "wall", "span_ft": [-10.0, 10.0]}]},
}


def openapi(paths: dict) -> dict:
    return {
        "paths": paths,
        "components": {
            "schemas": {
                "Upload": {"properties": {"bundle": {"type": "string", "format": "binary"}}}
            }
        },
    }


def json_op() -> dict:
    return {"post": {"requestBody": {"content": {"application/json": {"schema": {}}}}}}


def test_single_json_endpoint_is_found():
    assert discover_endpoint(openapi({"/place": json_op()})) == Endpoint(
        "/place", "application/json"
    )


def test_multipart_endpoint_names_its_file_field():
    op = {
        "post": {
            "requestBody": {
                "content": {
                    "multipart/form-data": {"schema": {"$ref": "#/components/schemas/Upload"}}
                }
            }
        }
    }
    assert discover_endpoint(openapi({"/scenes": op})) == Endpoint(
        "/scenes", "multipart/form-data", "bundle"
    )


def test_a_scene_named_path_wins_among_several():
    found = discover_endpoint(openapi({"/login": json_op(), "/placement": json_op()}))
    assert found.path == "/placement"


def test_ambiguity_is_loud():
    with pytest.raises(SystemExit, match="Pass --endpoint"):
        discover_endpoint(openapi({"/a": json_op(), "/b": json_op()}))
    with pytest.raises(SystemExit, match="Pass --endpoint"):
        discover_endpoint(openapi({}))
    assert discover_endpoint(openapi({"/a": json_op(), "/b": json_op()}), "/b").path == "/b"


def test_case_file_is_loaded_with_its_expectations(tmp_path):
    path = tmp_path / "c.json"
    path.write_text(
        json.dumps(
            {
                "id": "c1",
                "scene": SCENE,
                "expect": {"decision_not": ["pass"]},
                "rules_assumed": {"gas": 3.0},
            }
        )
    )
    item = load_input(path)
    assert item.name == "c1"
    assert item.expect == {"decision_not": ["pass"]}
    assert json.loads(item.raw) == SCENE


class FakeServer(BaseHTTPRequestHandler):
    """Answers every scene with a consistent manual_review; `decide_pass` breaks C5."""

    decide_pass = False

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers["Content-Type"].startswith("multipart/"):
            start = body.index(b"PK")  # the zip starts after the part headers
            import io
            import zipfile

            raw = zipfile.ZipFile(io.BytesIO(body[start:])).read("scene.json")
        else:
            raw = body
        scene = json.loads(raw)
        passing = self.decide_pass
        result = {
            "schema_version": "1.0",
            "decision": "pass" if passing else "manual_review",
            "summary": "",
            "reasons": [{"code": "policy_not_approved", "message": ""}],
            "policy": {
                "id": None,
                "version": None,
                "auto_approve": passing,
                "sources": [],
                "rules_sha256": "0" * 64,
            },
            "spot": None,
            "route": None,
            "checks": [],
            "missing_evidence": [],
            "ends": {},
            "sweep": [
                {
                    "wall_id": scene["walls"][0]["id"],
                    "start_ft": [1.0, 2.0],
                    "outcome": "pass" if passing else "unsure",
                    "failing": [],
                    "unsure": [],
                }
            ],
            "stats": {
                "candidates": 1,
                "pass": int(passing),
                "unsure": int(not passing),
                "fail": 0,
                "elapsed_ms": 1.0,
                "input_sha256": hashlib.sha256(raw).hexdigest(),
            },
        }
        payload = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


@pytest.fixture
def fake_url():
    server = HTTPServer(("127.0.0.1", 0), FakeServer)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    FakeServer.decide_pass = False


SCHEMAS = {"scene": {}, "result": {}}


def item() -> SceneInput:
    raw = json.dumps(SCENE).encode()
    return SceneInput("fake", SCENE, raw, expect={"decision_not": ["pass"]})


@pytest.mark.parametrize(
    "endpoint",
    [Endpoint("/place", "application/json"), Endpoint("/place", "multipart/form-data", "file")],
)
def test_consistent_server_passes(fake_url, endpoint):
    record = judge(fake_url, endpoint, item(), SCHEMAS)
    assert record["status"] == "pass", record["problems"]
    assert record["decision"] == "manual_review"


def test_server_breaking_coverage_rule_fails(fake_url):
    FakeServer.decide_pass = True
    record = judge(fake_url, Endpoint("/place", "application/json"), item(), SCHEMAS)
    assert record["status"] == "fail"
    joined = "\n".join(record["problems"])
    assert "ruled out for this case" in joined
    assert "without coverage still produced a pass" in joined
    assert re.search(r"ground under .* was not observed", joined)


def test_a_result_breaking_its_schema_counts_against_the_contract(fake_url):
    strict = {"scene": {}, "result": {"required": ["nothing_has_this"]}}
    record = judge(fake_url, Endpoint("/place", "application/json"), item(), strict)
    assert record["status"] == "fail"
    assert record["contract_problems"] and record["contract_problems"] == record["problems"]


def test_bad_input_is_not_blamed_on_the_server(fake_url):
    strict = {"scene": {"required": ["nothing_has_this"]}, "result": {}}
    record = judge(fake_url, Endpoint("/place", "application/json"), item(), strict)
    assert record["status"] == "bad input"
