"""Every input problem stops the run with a message naming the file, the field and the fix."""

from collections.abc import Callable
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from helpers import Files

from scoring.inputs import InputError, load_study
from scoring.metrics import score_run
from scoring.report import markdown, write_csvs


def study_error(tmp_path: Path, edit: Callable[[Files], Any]) -> str:
    files = Files(tmp_path)
    edit(files)
    rules, truth, results = files.write_all()
    with pytest.raises(InputError) as caught:
        load_study(rules, [truth], [results])
    return str(caught.value)


def surveyed(files: Files, measurement_id: str) -> dict[str, Any]:
    return next(m for m in files.truth["measurements"] if m["id"] == measurement_id)


def reported(files: Files, measurement_id: str) -> dict[str, Any]:
    return next(m for m in files.results["measurements"] if m["id"] == measurement_id)


def test_valid_inputs_load(tmp_path: Path):
    files = Files(tmp_path)
    rules, truth, results = files.write_all()
    study = load_study(rules, [truth], [results])
    (house,) = study.houses
    assert house.truth.house == "h1"
    assert house.truth.scale_reference == "scale"
    assert house.truth.measurements["c1-gas"].value_ft == Decimal("4.5")
    (run,) = house.runs
    assert run.measurements["c1-gas"].plus_minus_ft == Decimal("0.3")
    assert run.measurements["c1-route"].missing == "failed"
    assert run.outcomes == {("c1", "gas"): "pass", ("c1", "route"): "unsure"}
    assert run.capture_seconds == Decimal(300)


def test_error_names_file_field_and_problem(tmp_path: Path):
    message = study_error(tmp_path, lambda f: surveyed(f, "c1-gas").update(value_ft="4.5"))
    assert message == (
        f"{tmp_path / 'truth.json'}: measurements[1] (c1-gas).value_ft: "
        "expected a number, got the string '4.5'"
    )


def test_scale_reference_may_be_left_out_of_a_run(tmp_path: Path):
    files = Files(tmp_path)
    rules, truth, results = files.write_all()
    (house,) = load_study(rules, [truth], [results]).houses
    assert "scale" not in house.runs[0].measurements


def test_review_band_loads(tmp_path: Path):
    files = Files(tmp_path)
    files.truth["checks"][1]["review_threshold"] = "review_route_ft"
    rules, truth, results = files.write_all()
    (house,) = load_study(rules, [truth], [results]).houses
    assert house.truth.checks[1].review_threshold == "review_route_ft"
    assert house.truth.checks[0].review_threshold is None


def test_run_without_decisions_loads(tmp_path: Path):
    files = Files(tmp_path)
    files.results["outcomes"] = None
    rules, truth, results = files.write_all()
    (house,) = load_study(rules, [truth], [results]).houses
    assert house.runs[0].outcomes is None


def set_threshold(files: Files, **fields: Any) -> None:
    files.rules["thresholds"]["gas_clearance_ft"].update(fields)


def add_threshold(files: Files, name: str) -> None:
    files.rules["thresholds"][name] = {"value_ft": 3, "pass_when": "at_least", "source": "s"}


def make_route_absent(files: Files) -> None:
    route = surveyed(files, "c1-route")
    route.update(status="absent")
    del route["value_ft"], route["plus_minus_ft"]


CASES: list[tuple[str, Callable[[Files], Any], str]] = [
    ("rules unit", lambda f: f.rules.update(unit="m"), 'every length must be in feet ("ft")'),
    ("rules format", lambda f: f.rules.update(format=2), "this scorer reads format 1, got 2"),
    (
        "boolean format",
        lambda f: f.rules.update(format=True),
        "reads format 1, got the boolean true",
    ),
    ("unknown field", lambda f: f.rules.update(extra=1), "unknown field 'extra'"),
    ("threshold name", lambda f: add_threshold(f, "gas_clearance"), "ending in _ft"),
    (
        "pass_when",
        lambda f: set_threshold(f, pass_when="above"),
        "thresholds.gas_clearance_ft.pass_when: expected one of at_least, at_most",
    ),
    ("negative", lambda f: set_threshold(f, value_ft=-3), "must not be negative, got -3"),
    ("boolean value", lambda f: set_threshold(f, value_ft=True), "got the boolean true"),
    (
        "measured without a value",
        lambda f: surveyed(f, "c1-gas").pop("value_ft"),
        "measurements[1] (c1-gas): missing required field 'value_ft'",
    ),
    (
        "absent with a value",
        lambda f: surveyed(f, "c1-gas").update(status="absent"),
        "measurements[1] (c1-gas).value_ft: status 'absent' has no value",
    ),
    (
        "survey status",
        lambda f: surveyed(f, "c1-gas").update(status="guessed"),
        "expected one of measured, absent, not_measured, got the string 'guessed'",
    ),
    (
        "duplicate measurement",
        lambda f: f.truth["measurements"].append(dict(surveyed(f, "c1-gas"))),
        "measurements[3].id: measurement 'c1-gas' is listed twice",
    ),
    (
        "unknown candidate",
        lambda f: surveyed(f, "c1-gas").update(candidate="c9"),
        "measurements[1] (c1-gas).candidate: no candidate 'c9'; candidates are c1",
    ),
    (
        "nobody measured",
        lambda f: surveyed(f, "c1-gas").update(measured_by=[]),
        "measured_by: expected a non-empty list",
    ),
    (
        "scale reference id",
        lambda f: f.truth.update(scale_reference="S"),
        "scale_reference: 'S' is not a measurement id",
    ),
    (
        "scale reference unmeasured",
        lambda f: [
            surveyed(f, "scale").update(status="not_measured"),
            surveyed(f, "scale").pop("value_ft"),
            surveyed(f, "scale").pop("plus_minus_ft"),
        ],
        "scale_reference: 'scale' must be measured, but its status is 'not_measured'",
    ),
    (
        "check on the scale reference",
        lambda f: f.truth["checks"][0].update(measurement="scale"),
        "checks[0].measurement: 'scale' is the scale reference, which is never scored",
    ),
    (
        "check threshold",
        lambda f: f.truth["checks"][0].update(threshold="gas_ft"),
        "checks[0].threshold: 'gas_ft' is not in",
    ),
    (
        "check candidate",
        lambda f: [
            f.truth["candidates"].append({"id": "c2", "marker": "chalk", "location": "wall"}),
            f.truth["checks"][0].update(candidate="c2"),
        ],
        "the check is at candidate 'c2' but measurement 'c1-gas' belongs to 'c1'",
    ),
    (
        "spot missing a check",
        lambda f: [
            f.truth["candidates"].append({"id": "c2", "marker": "chalk", "location": "wall"}),
            f.truth["measurements"].append(
                dict(surveyed(f, "c1-gas"), id="c2-gas", candidate="c2")
            ),
            f.truth["checks"].append(
                {
                    "candidate": "c2",
                    "check": "gas",
                    "measurement": "c2-gas",
                    "threshold": "gas_clearance_ft",
                }
            ),
        ],
        "candidate 'c2' has no route check; every spot needs the same checks",
    ),
    (
        "unknown review threshold",
        lambda f: f.truth["checks"][1].update(review_threshold="review_ft"),
        "checks[1].review_threshold: 'review_ft' is not in",
    ),
    (
        "review threshold equal to threshold",
        lambda f: f.truth["checks"][1].update(review_threshold="max_route_ft"),
        "checks[1].review_threshold: must differ from threshold",
    ),
    (
        "review threshold in the other direction",
        lambda f: f.truth["checks"][1].update(review_threshold="gas_clearance_ft"),
        "passes at_least but 'max_route_ft' passes at_most",
    ),
    (
        "review threshold past the fail line",
        lambda f: [
            f.rules["thresholds"]["review_route_ft"].update(value_ft=25),
            f.truth["checks"][1].update(review_threshold="review_route_ft"),
        ],
        "'review_route_ft' (25 ft) must be on the passing side of 'max_route_ft' (20 ft, at_most)",
    ),
    ("absent at_most", make_route_absent, "only a clearance (at_least) passes"),
    (
        "duplicate check",
        lambda f: f.truth["checks"].append(dict(f.truth["checks"][0])),
        "checks[2]: check 'gas' at 'c1' is listed twice",
    ),
    (
        "rules hash",
        lambda f: f.results.update(rules_sha256="a" * 64),
        "every run must use the same frozen rules",
    ),
    (
        "malformed hash",
        lambda f: f.results.update(rules_sha256="abc"),
        "rules_sha256: expected the 64 lowercase hex digits",
    ),
    (
        "unreported measurement",
        lambda f: f.results["measurements"].pop(),
        "no entry for measurements 'c1-route'",
    ),
    (
        "unknown measurement",
        lambda f: f.results["measurements"].append(
            {"id": "c1-door", "value_ft": 4, "plus_minus_ft": None}
        ),
        "measurements 'c1-door' are not in",
    ),
    (
        "null without a reason",
        lambda f: reported(f, "c1-route").pop("missing"),
        "measurements[1] (c1-route): missing required field 'missing'",
    ),
    (
        "value with a reason",
        lambda f: reported(f, "c1-gas").update(missing="failed"),
        "missing: only a null value_ft gives a reason it is missing",
    ),
    (
        "null with an uncertainty",
        lambda f: reported(f, "c1-route").update(plus_minus_ft=0.3),
        "plus_minus_ft: a null value has no uncertainty",
    ),
    (
        "value without an uncertainty key",
        lambda f: reported(f, "c1-gas").pop("plus_minus_ft"),
        "missing required field 'plus_minus_ft'",
    ),
    (
        "missing reason",
        lambda f: reported(f, "c1-route").update(missing="timeout"),
        "expected one of unsupported, failed, absent",
    ),
    (
        "missing outcome",
        lambda f: f.results["outcomes"].pop(),
        "no outcome for route at c1",
    ),
    (
        "extra outcome",
        lambda f: f.results["outcomes"].append(
            {"candidate": "c1", "check": "pool", "outcome": "pass"}
        ),
        "outcomes for checks not in the survey: pool at c1",
    ),
    (
        "outcome value",
        lambda f: f.results["outcomes"][0].update(outcome="maybe"),
        "outcomes[0].outcome: expected one of pass, unsure, fail",
    ),
    (
        "scale source",
        lambda f: f.results.update(scale_source="guess"),
        "scale_source: expected one of native_metric, scale_reference, ar_poses",
    ),
    (
        "unknown capture",
        lambda f: f.results.update(capture="cap-2"),
        "no survey lists capture 'cap-2'",
    ),
    (
        "negative timing",
        lambda f: f.results["timing"].update(processing_s=-1),
        "timing.processing_s: must not be negative",
    ),
]


@pytest.mark.parametrize(("edit", "expected"), [c[1:] for c in CASES], ids=[c[0] for c in CASES])
def test_invalid_input_is_rejected(tmp_path: Path, edit: Callable[[Files], Any], expected: str):
    assert expected in study_error(tmp_path, edit)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ('{"format": 1, "format": 1}', "key 'format' appears twice in one object"),
        ('{"value": NaN}', "NaN is not a measurement"),
        ('{"format": 1,', "not valid JSON"),
    ],
)
def test_ambiguous_json_is_rejected(tmp_path: Path, text: str, expected: str):
    rules = tmp_path / "rules.json"
    rules.write_text(text)
    with pytest.raises(InputError, match=expected):
        load_study(rules, [], [])


def test_same_house_twice(tmp_path: Path):
    files = Files(tmp_path)
    rules, truth, _ = files.write_all()
    files.truth["captures"] = ["cap-9"]
    again = files.write("truth-2.json", files.truth)
    with pytest.raises(InputError, match="house 'h1' is already surveyed"):
        load_study(rules, [truth, again], [])


def test_same_run_twice(tmp_path: Path):
    files = Files(tmp_path)
    rules, truth, results = files.write_all()
    again = files.write("results-2.json", files.results)
    with pytest.raises(InputError, match="pipeline 'p1' on capture 'cap-1' is already scored"):
        load_study(rules, [truth], [results, again])


def test_runs_on_one_recording_share_its_capture_time(tmp_path: Path):
    files = Files(tmp_path)
    rules, truth, results = files.write_all()
    files.results["pipeline"] = "p2"
    files.results["timing"]["capture_s"] = 120
    shorter = files.write("results-2.json", files.results)
    with pytest.raises(InputError, match="120 s differs from 300 s"):
        load_study(rules, [truth], [results, shorter])
    files.results["timing"]["capture_s"] = None
    unrecorded = files.write("results-3.json", files.results)
    assert len(load_study(rules, [truth], [results, unrecorded]).houses[0].runs) == 2


def test_unreadable_file(tmp_path: Path):
    with pytest.raises(InputError, match="cannot read"):
        load_study(tmp_path / "nope.json", [], [])


@pytest.mark.parametrize("different", ["threshold", "review_threshold"])
def test_check_policy_must_match_across_candidates(tmp_path: Path, different: str):
    files = Files(tmp_path)
    files.truth["candidates"].append({"id": "c2", "marker": "chalk", "location": "wall"})
    for check in list(files.truth["checks"]):
        measurement = dict(surveyed(files, check["measurement"]))
        measurement["id"] = check["measurement"].replace("c1", "c2")
        measurement["candidate"] = "c2"
        files.truth["measurements"].append(measurement)
        files.truth["checks"].append(dict(check, candidate="c2", measurement=measurement["id"]))
        files.results["measurements"].append(
            {"id": measurement["id"], "value_ft": None, "missing": "failed"}
        )
        files.results["outcomes"].append(
            {"candidate": "c2", "check": check["check"], "outcome": "unsure"}
        )
    if different == "threshold":
        files.truth["checks"][2]["threshold"] = "another_gas_ft"
        files.rules["thresholds"]["another_gas_ft"] = {
            "value_ft": 4,
            "pass_when": "at_least",
            "source": "synthetic",
        }
    else:
        files.truth["checks"][3]["review_threshold"] = "review_route_ft"
    rules, truth, results = files.write_all()
    with pytest.raises(InputError, match="every spot needs the same threshold mapping") as caught:
        load_study(rules, [truth], [results])
    assert str(truth) in str(caught.value)
    assert "checks" in str(caught.value)


@pytest.mark.parametrize("missing", ["failed", "unsupported"])
@pytest.mark.parametrize("outcome", ["pass", "fail"])
def test_decision_without_its_measurement_is_accepted(tmp_path: Path, missing: str, outcome: str):
    # The scorer records what the pipeline decided; metrics.py flags it instead of rejecting it.
    files = Files(tmp_path)
    reported(files, "c1-route")["missing"] = missing
    files.results["outcomes"][1]["outcome"] = outcome
    rules, truth, results = files.write_all()
    (run,) = load_study(rules, [truth], [results]).houses[0].runs
    assert run.outcomes[("c1", "route")] == outcome
    assert run.measurements["c1-route"].missing == missing


def test_absent_feature_can_pass_clearance(tmp_path: Path):
    files = Files(tmp_path)
    measurement = surveyed(files, "c1-gas")
    measurement["status"] = "absent"
    del measurement["value_ft"], measurement["plus_minus_ft"]
    files.results["measurements"][0] = {"id": "c1-gas", "value_ft": None, "missing": "absent"}
    rules, truth, results = files.write_all()
    assert load_study(rules, [truth], [results]).houses[0].runs[0].outcomes[("c1", "gas")] == "pass"


@pytest.mark.parametrize("field", ["value_ft", "plus_minus_ft"])
def test_unformattable_large_length_names_input_field(tmp_path: Path, field: str):
    def edit(files: Files) -> None:
        reported(files, "c1-gas")[field] = 1e100

    message = study_error(tmp_path, edit)
    assert str(tmp_path / "results.json") in message
    assert f"measurements[0] (c1-gas).{field}" in message
    assert "at most 1000000000" in message


def test_maximum_length_and_precision_format_in_reports(tmp_path: Path):
    files = Files(tmp_path)
    surveyed(files, "c1-gas").update(value_ft=3.000000000001, plus_minus_ft=0)
    reported(files, "c1-gas").update(value_ft=1e9, plus_minus_ft=0)
    rules, truth, results = files.write_all()
    study = load_study(rules, [truth], [results])
    house = study.houses[0]
    run = score_run(house.truth, house.runs[0], study.rules.thresholds)
    assert markdown(study, [run]).startswith("# Capture pipeline scores")
    paths = write_csvs([run], tmp_path / "out")
    assert len(paths) == 3
    assert "1000000000.000" in paths[0].read_text()
    assert "error_to_margin" in paths[1].read_text()


def test_unformattable_ratio_precision_names_input_field(tmp_path: Path):
    message = study_error(
        tmp_path, lambda files: surveyed(files, "c1-gas").update(value_ft=3.0000000000001)
    )
    assert str(tmp_path / "truth.json") in message
    assert "measurements[1] (c1-gas).value_ft" in message
    assert "at most 12 decimal places" in message
