"""Regenerating the e2e cases replaces only the files the generator owns."""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "e2e" / "cases" / "generate.py"
spec = importlib.util.spec_from_file_location("generate_cases", SCRIPT)
generate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = generate  # dataclasses look their module up there
spec.loader.exec_module(generate)


def test_hand_written_cases_survive_and_stale_generated_ones_go(tmp_path):
    hand = tmp_path / "manually-added-regression.json"
    hand.write_text(json.dumps({"id": "manually-added-regression", "scene": {}}))
    stale = tmp_path / "renamed-away.json"
    stale.write_text(json.dumps({"generated_by": generate.GENERATED_BY, "id": "renamed-away"}))
    generate.main(tmp_path)
    assert hand.exists()
    assert not stale.exists()
    written = {p.stem for p in tmp_path.glob("*.json")} - {hand.stem}
    assert written == {c["id"] for c in generate.CASES}


def test_a_hand_written_file_with_a_generated_id_is_refused(tmp_path):
    taken = generate.CASES[0]["id"]
    (tmp_path / f"{taken}.json").write_text(json.dumps({"id": taken}))
    with pytest.raises(SystemExit, match="written by hand"):
        generate.main(tmp_path)
    assert json.loads((tmp_path / f"{taken}.json").read_text()) == {"id": taken}


def test_the_committed_cases_are_what_the_generator_writes(tmp_path):
    generate.main(tmp_path)
    committed = SCRIPT.parent
    for f in tmp_path.glob("*.json"):
        assert f.read_text() == (committed / f.name).read_text(), f.name
