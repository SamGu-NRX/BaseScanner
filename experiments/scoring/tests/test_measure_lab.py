"""The Measure Lab importer on a synthetic format-2 session, with hand-computed feet.

The committed session (fixtures/measure-lab/synthetic-session-01) holds, in meters:
m1 scale 1.524 (5 ft), m2 wall 9.87552 (32.4 ft), m3 c1 gas 1.4 (4.593175853... ft, written
4.593176), m4 c1 facing gap 1.49352 (4.9 ft), m5 c1 route 3.71856 (12.2 ft), m6 c2 gas 0.95 with
heightAboveGround -0.04 and accepted false, m7 c2 route 6.00456 (19.7 ft), and refusal r1 for the
c2 facing gap. The session starts at uptime 1000.25 and the last measurement is at 1412.75.
"""

import copy
import csv
import hashlib
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from helpers import FIXTURES, MEASURE_LAB, SESSION_ZIP, committed_session, session_zip

from scoring.cli import main
from scoring.inputs import InputError, load_study
from scoring.measure_lab import import_session, meters_to_feet

D = Decimal
RULES = FIXTURES / "rules.json"
TRUTH = FIXTURES / "truth" / "synthetic-01.json"
MAP = MEASURE_LAB / "map.json"


def committed_map() -> dict[str, Any]:
    return json.loads(MAP.read_text())


class Setup:
    """Editable copies of the committed session, map and survey, written to a temp dir."""

    def __init__(self, root: Path):
        self.root = root
        self.session = committed_session()
        self.map = committed_map()
        self.truth = json.loads(TRUTH.read_text())

    def run(self, *, decide: bool = False) -> dict[str, Any]:
        zip_path = session_zip(self.session, self.root / "session.zip")
        capture = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        if capture not in self.truth["captures"]:
            self.truth["captures"].append(capture)
        map_path = self.root / "map.json"
        map_path.write_text(json.dumps(self.map))
        truth_path = self.root / "truth.json"
        truth_path.write_text(json.dumps(self.truth))
        return import_session(
            zip_path, map_path, RULES, truth_path, self.root / "out.json", decide_outcomes=decide
        )

    def error(self, **kwargs: Any) -> str:
        with pytest.raises(InputError) as caught:
            self.run(**kwargs)
        assert not (self.root / "out.json").exists()
        return str(caught.value)

    def measurement(self, measurement_id: str) -> dict[str, Any]:
        return next(m for m in self.session["measurements"] if m["id"] == measurement_id)


@pytest.fixture
def setup(tmp_path: Path) -> Setup:
    return Setup(tmp_path)


def by_id(results: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {entry["id"]: entry for entry in results["measurements"]}


class TestMetersToFeet:
    @pytest.mark.parametrize(
        ("meters", "feet"),
        [
            ("0.3048", "1.000000"),
            ("9.87552", "32.400000"),
            ("1.4", "4.593176"),  # 4.59317585301837...
            ("1", "3.280840"),  # 3.28083989501312...
            ("0.0000001524", "0.000001"),  # exactly 0.0000005 ft: half rounds up
            ("0.0000001523", "0.000000"),  # 0.00000049967... ft
            ("0", "0.000000"),
        ],
    )
    def test_exact_conversion_then_six_places(self, meters, feet):
        result = meters_to_feet(D(meters))
        assert str(result) == feet
        assert result.as_tuple().exponent == -6


def test_committed_zip_is_the_committed_session(tmp_path: Path):
    rebuilt = session_zip(
        (MEASURE_LAB / "synthetic-session-01" / "session.json").read_bytes(),
        tmp_path / "rebuilt.zip",
    )
    assert rebuilt.read_bytes() == SESSION_ZIP.read_bytes(), (
        "fixtures/measure-lab/synthetic-session-01.zip is stale; run "
        "`uv run python tests/helpers.py rebuild-session-zip` and put the printed sha256 in "
        "fixtures/truth/synthetic-01.json captures"
    )
    capture = hashlib.sha256(SESSION_ZIP.read_bytes()).hexdigest()
    assert capture in json.loads(TRUTH.read_text())["captures"]


class TestImport:
    def test_values_in_feet_with_the_mapped_uncertainty(self, setup: Setup):
        results = setup.run()
        entries = by_id(results)
        assert [entry["id"] for entry in results["measurements"]] == [
            "scale",
            "wall-length",
            "c1-gas",
            "c1-facing",
            "c1-route",
            "c1-pool",
            "c2-gas",
            "c2-facing",
            "c2-route",
            "c2-pool",
        ]
        assert entries["scale"]["value_ft"] == D("5.000000")
        assert entries["wall-length"]["value_ft"] == D("32.400000")
        assert entries["c1-gas"]["value_ft"] == D("4.593176")
        assert entries["c1-facing"]["value_ft"] == D("4.900000")
        assert entries["c1-route"]["value_ft"] == D("12.200000")
        assert entries["c2-route"]["value_ft"] == D("19.700000")
        assert {entry.get("plus_minus_ft") for entry in entries.values() if entry["value_ft"]} == {
            D("0.3")
        }

    def test_missing_entries(self, setup: Setup):
        entries = by_id(setup.run())
        assert entries["c1-pool"] == {"id": "c1-pool", "value_ft": None, "missing": "absent"}
        assert entries["c2-facing"] == {"id": "c2-facing", "value_ft": None, "missing": "failed"}
        assert entries["c2-pool"] == {"id": "c2-pool", "value_ft": None, "missing": "unsupported"}

    def test_not_accepted_becomes_failed(self, setup: Setup):
        # m6 has heightAboveGround -0.04 m, warning belowGround and accepted false.
        assert by_id(setup.run())["c2-gas"] == {
            "id": "c2-gas",
            "value_ft": None,
            "missing": "failed",
        }

    def test_not_accepted_with_a_positive_value_also_becomes_failed(self, setup: Setup):
        m3 = setup.measurement("m3")
        m3.update(accepted=False, warnings=["estimatedPlane"])
        assert by_id(setup.run())["c1-gas"]["missing"] == "failed"

    def test_accepted_straight_does_not_validate_unchecked_along_wall(self, setup: Setup):
        m5 = setup.measurement("m5")
        m5.update(compared="straight", accepted=True, warnings=[])
        setup.session["walls"][0].update(validations=[], warnings=["wallNotValidated"])
        error = setup.error()
        assert "map.json: measurements.c1-route.key" in error
        assert "'alongWall'" in error and "'straight'" in error

    def test_missing_compared_quantity_is_rejected(self, setup: Setup):
        del setup.measurement("m5")["compared"]
        assert "measurements[4] (m5).compared: expected a non-empty string" in setup.error()

    def test_header_timing_and_ids(self, setup: Setup):
        results = setup.run()
        zip_bytes = (setup.root / "session.zip").read_bytes()
        assert results["capture"] == hashlib.sha256(zip_bytes).hexdigest()
        assert results["rules_sha256"] == hashlib.sha256(RULES.read_bytes()).hexdigest()
        assert results["pipeline"] == "measure-lab"
        assert results["scale_source"] == "ar_poses"
        assert results["outcomes"] is None
        assert results["timing"] == {"capture_s": D("412.500"), "processing_s": None}

    def test_per_entry_uncertainty_overrides_the_key_default(self, setup: Setup):
        setup.map["measurements"]["c1-gas"]["plus_minus_ft"] = 0.25
        assert by_id(setup.run())["c1-gas"]["plus_minus_ft"] == D("0.25")

    def test_scale_reference_may_be_left_out(self, setup: Setup):
        del setup.map["measurements"]["scale"]
        assert "scale" not in by_id(setup.run())

    def test_written_file_loads_with_exact_numbers(self, setup: Setup):
        setup.run()
        text = (setup.root / "out.json").read_text()
        assert '"value_ft": 4.593176' in text
        assert '"capture_s": 412.500' in text


class TestDecide:
    def test_outcomes_follow_the_strict_rule(self, setup: Setup):
        results = setup.run(decide=True)
        assert results["pipeline"] == "measure-lab+rule"
        outcomes = {(o["candidate"], o["check"]): o["outcome"] for o in results["outcomes"]}
        assert outcomes == {
            ("c1", "gas"): "pass",  # 4.593176 - 3 = 1.593176 > 0.3
            ("c1", "facing_gap"): "pass",  # 4.9 - 3 = 1.9 > 0.3
            ("c1", "route"): "pass",  # 15 - 12.2 = 2.8 > 0.3
            ("c1", "pool"): "pass",  # the rig saw no pool: an absent feature clears it
            ("c2", "gas"): "unsure",  # not accepted: no value
            ("c2", "facing_gap"): "unsure",  # refused: no value
            ("c2", "route"): "unsure",  # 19.7: past 15 + 0.3, not past 20 + 0.3: review
            ("c2", "pool"): "unsure",  # unsupported
        }

    @pytest.mark.parametrize(
        ("meters", "outcome"),
        [
            ("1.00584", "unsure"),  # 3.3 ft: margin 0.3 equals the uncertainty
            ("1.00587", "pass"),  # 3.300098 ft
            ("0.82296", "unsure"),  # 2.7 ft: miss equals the uncertainty
            ("0.82293", "fail"),  # 2.699902 ft
        ],
    )
    def test_equality_is_unsure(self, setup: Setup, meters, outcome):
        setup.measurement("m3")["values"]["straight"] = float(meters)
        outcomes = {
            (o["candidate"], o["check"]): o["outcome"] for o in setup.run(decide=True)["outcomes"]
        }
        assert outcomes[("c1", "gas")] == outcome

    def test_absent_cannot_pass_an_at_most_rule(self, setup: Setup):
        setup.map["measurements"]["c1-route"] = "absent"
        outcomes = {
            (o["candidate"], o["check"]): o["outcome"] for o in setup.run(decide=True)["outcomes"]
        }
        assert outcomes[("c1", "route")] == "unsure"


def edit_session(key: str, value: Any):
    return lambda setup: setup.session.update({key: value})


ERRORS: list[tuple[str, Any, str]] = [
    (
        "unknown survey id",
        lambda s: s.map["measurements"].update({"c1-door": "absent"}),
        "measurements 'c1-door' are not survey measurement ids",
    ),
    (
        "missing session measurement",
        lambda s: s.map["measurements"]["c1-gas"].update(session_measurement="m99"),
        "measurements.c1-gas.session_measurement: synthetic-session-01/session.json has no "
        "measurement 'm99'",
    ),
    (
        "missing refusal",
        lambda s: s.map["measurements"].update({"c2-facing": {"refusal": "r9"}}),
        "measurements.c2-facing.refusal: synthetic-session-01/session.json has no refusal 'r9'",
    ),
    (
        "values key absent from the measurement",
        lambda s: s.map["measurements"]["c1-gas"].update(key="alongWall"),
        "measurements.c1-gas.key: measurement 'm3' has no 'alongWall' value; it has straight, "
        "horizontal, vertical, gapToWall, heightAboveGround",
    ),
    ("format version 1", edit_session("formatVersion", 1), "formatVersion is 1; this importer"),
    ("format version 3", edit_session("formatVersion", 3), "formatVersion is 3; this importer"),
    (
        "format name",
        edit_session("format", "something-else"),
        "format is 'something-else', not 'measure-lab-session'",
    ),
    (
        "survey measurement left out",
        lambda s: s.map["measurements"].pop("c2-pool"),
        "no entry for survey measurements 'c2-pool'",
    ),
    (
        "map for another session",
        lambda s: s.map.update(session="other-session"),
        "session is 'other-session', but",
    ),
    (
        "no uncertainty",
        lambda s: s.map.pop("plus_minus_ft_by_key"),
        "measurements.scale: no uncertainty for values key 'straight'",
    ),
    (
        "unknown values key",
        lambda s: s.map["measurements"]["c1-gas"].update(key="diagonal"),
        "measurements.c1-gas.key: expected one of straight, horizontal",
    ),
    (
        "unknown map string",
        lambda s: s.map["measurements"].update({"c2-pool": "failed"}),
        'measurements.c2-pool: expected "absent", "unsupported" or an object',
    ),
    (
        "refusal with extra fields",
        lambda s: s.map["measurements"].update({"c2-facing": {"refusal": "r1", "key": "straight"}}),
        "a refusal entry takes no key",
    ),
    (
        "accepted negative value",
        lambda s: s.measurement("m3")["values"].update(straight=-1.4),
        "measurement 'm3' is accepted but its straight is -1.4 m",
    ),
    (
        "length units",
        lambda s: s.session["units"].update(length="feet"),
        "units.length must be 'meters'",
    ),
]


@pytest.mark.parametrize(("edit", "expected"), [e[1:] for e in ERRORS], ids=[e[0] for e in ERRORS])
def test_errors(setup: Setup, edit, expected):
    edit(setup)
    assert expected in setup.error()


def test_zip_without_session_json(tmp_path: Path):
    path = tmp_path / "empty.zip"
    session_zip(b"{}", path, folder="a/b")  # session.json two folders down is not the session
    with pytest.raises(InputError, match=r"expected exactly one session\.json"):
        import_session(path, MAP, RULES, TRUTH, tmp_path / "out.json", decide_outcomes=False)


def test_not_a_zip(tmp_path: Path):
    path = tmp_path / "session.zip"
    path.write_text("not a zip")
    with pytest.raises(InputError, match="not a zip file"):
        import_session(path, MAP, RULES, TRUTH, tmp_path / "out.json", decide_outcomes=False)


def test_capture_must_be_in_the_survey(tmp_path: Path):
    session = copy.deepcopy(committed_session())
    session["session"]["appVersion"] = "changed"  # different bytes, different sha256
    path = session_zip(session, tmp_path / "session.zip")
    capture = hashlib.sha256(path.read_bytes()).hexdigest()
    with pytest.raises(InputError, match=f"captures does not list {capture}"):
        import_session(path, MAP, RULES, TRUTH, tmp_path / "out.json", decide_outcomes=False)


def test_end_to_end_scores_and_decide_row_lands_in_checks(tmp_path: Path, capsys):
    outputs = []
    for flag in ([], ["--decide"]):
        out = tmp_path / f"measure-lab{'-rule' if flag else ''}.json"
        args = [str(SESSION_ZIP), "--map", str(MAP), "--rules", str(RULES), "--truth", str(TRUTH)]
        assert main(["import-measure-lab", *args, *flag, "--out", str(out)]) == 0
        outputs.append(out)
    assert "wrote" in capsys.readouterr().err
    load_study(RULES, [TRUTH], outputs)  # both rows load without errors

    csv_dir = tmp_path / "csv"
    args = ["--rules", str(RULES), "--truth", str(TRUTH), "--out", str(csv_dir)]
    assert main([*args, "--results", *map(str, outputs)]) == 0
    stdout = capsys.readouterr().out
    assert (
        "| `measure-lab` | ar_poses | 5/9 | 1.20 | 2.40 | 5/5 | 0 | 2 | 0 | 0 | 1 | 1 |" in stdout
    )
    assert "| `measure-lab+rule` | 6/7 | 0 | 0 | 0 | 0 | 0 | 3 | 0 | 1 |" in stdout
    assert "| `measure-lab` | no decisions |" in stdout

    with (csv_dir / "checks.csv").open(newline="") as handle:
        rows = [r for r in csv.DictReader(handle) if r["pipeline"] == "measure-lab+rule"]
    assert len(rows) == 8
    route = next(r for r in rows if (r["candidate"], r["check"]) == ("c2", "route"))
    assert (route["truth_outcome"], route["run_outcome"], route["agrees"]) == (
        "review",
        "unsure",
        "true",
    )
    assert route["error_to_margin"] == "2.00"  # 0.2 / max(min(0.1, 4.9), 0.05)


def test_cli_reports_errors_with_exit_2(tmp_path: Path, capsys):
    args = [str(SESSION_ZIP), "--map", str(tmp_path / "nope.json"), "--rules", str(RULES)]
    code = main(["import-measure-lab", *args, "--truth", str(TRUTH), "--out", str(tmp_path / "o")])
    assert code == 2
    assert "score import-measure-lab:" in capsys.readouterr().err
    assert not (tmp_path / "o").exists()
