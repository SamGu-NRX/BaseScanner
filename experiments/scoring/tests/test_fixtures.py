"""The committed synthetic fixtures, scored through the CLI and checked against hand-worked answers.

House synthetic-01 has two spots. Survey outcomes under fixtures/rules.json:
c1: gas pass (4.5 vs 3), facing_gap pass (5.0 vs 3), route pass (12 vs 20), pool pass (absent).
c2: gas borderline (3.02 +- 0.03 vs 3), facing_gap fail (2.5 vs 3), route pass (19.9 vs 20),
pool unknown (not measured).
"""

import csv
from pathlib import Path

import pytest
from helpers import FIXTURES

from scoring.cli import main

RUNS = ["ar-taps", "photo-depth", "mesh-scaled"]


def run_cli(tmp_path: Path, *extra: str) -> int:
    return main(
        [
            "--rules",
            str(FIXTURES / "rules.json"),
            "--truth",
            str(FIXTURES / "truth" / "synthetic-01.json"),
            "--results",
            *(str(FIXTURES / "results" / f"{name}.json") for name in RUNS),
            "--out",
            str(tmp_path),
            *extra,
        ]
    )


@pytest.fixture
def scored(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    assert run_cli(tmp_path) == 0
    output = capsys.readouterr()

    def table(name: str) -> list[dict[str, str]]:
        with (tmp_path / name).open(newline="") as handle:
            return list(csv.DictReader(handle))

    return output, table


def by_key(rows: list[dict[str, str]], *keys: str) -> dict[tuple[str, ...], dict[str, str]]:
    return {tuple(row[key] for key in keys): row for row in rows}


# Abs errors in inches, per run: see each results fixture.
# ar-taps:     wall 2.4, c1-gas 2.4, c1-facing 4.8, c1-route 3.0, c2-gas 3.96, c2-route 4.8
# photo-depth: wall 24, c1-gas 12, c1-facing 14.4, c2-gas 7.44, c2-facing 4.8, c2-route 13.2
# mesh-scaled: wall 1.2, c1-facing 1.2, c1-route 6, c2-gas 0.24, c2-facing 1.2
EXPECTED_RUNS = {
    "ar-taps": {
        "scored": "6",
        "median_abs_error_in": "3.48",  # (3.0 + 3.96) / 2
        "max_abs_error_in": "4.80",  # the 12 in scale-reference error is excluded
        "within_reported": "3",
        "with_reported_uncertainty": "6",
        "missing_unsupported": "0",
        "missing_failed": "1",
        "false_absent": "0",
        "phantom": "0",
        "absent_agreed": "1",
        "not_surveyed": "1",
        "judged": "7",
        "agrees": "5",
        "unsafe_passes": "1",
        "false_rejections": "0",
        "abstentions_justified": "1",
        "abstentions_avoidable": "0",
        "could_flip": "2",
        "capture_s": "420.0",
        "processing_s": "12.5",
    },
    "photo-depth": {
        "scored": "6",
        "median_abs_error_in": "12.60",  # (12 + 13.2) / 2
        "max_abs_error_in": "24.00",
        "within_reported": "5",
        "with_reported_uncertainty": "6",
        "missing_unsupported": "1",
        "missing_failed": "0",
        "false_absent": "0",
        "phantom": "1",
        "absent_agreed": "0",
        "not_surveyed": "1",
        "judged": "7",
        "agrees": "2",
        "unsafe_passes": "0",
        "false_rejections": "1",
        "abstentions_justified": "1",
        "abstentions_avoidable": "2",
        "could_flip": "2",
        "capture_s": "420.0",
        "processing_s": "95.0",
    },
    "mesh-scaled": {
        "scored": "5",
        "median_abs_error_in": "1.20",
        "max_abs_error_in": "6.00",
        "within_reported": "4",
        "with_reported_uncertainty": "4",  # wall-length has no reported +-
        "missing_unsupported": "0",
        "missing_failed": "1",
        "false_absent": "1",
        "phantom": "0",
        "absent_agreed": "1",
        "not_surveyed": "1",
        "judged": "7",
        # No decisions: the decision counts are empty, not zero.
        "agrees": "",
        "unsafe_passes": "",
        "false_rejections": "",
        "abstentions_justified": "",
        "abstentions_avoidable": "",
        "could_flip": "0",
        "capture_s": "420.0",
        "processing_s": "",
    },
}


def test_run_summaries(scored):
    _, table = scored
    runs = by_key(table("runs.csv"), "pipeline")
    assert list(runs) == [(name,) for name in RUNS]
    for name, expected in EXPECTED_RUNS.items():
        row = runs[(name,)]
        assert row["measurements"] == "9"
        assert row["checks"] == "8"
        assert {key: row[key] for key in expected} == expected, name


def test_measurement_rows(scored):
    _, table = scored
    rows = by_key(table("measurements.csv"), "pipeline", "measurement")
    assert len(rows) == 30  # 3 runs x 10 survey measurements, scale reference included

    scale = rows[("ar-taps", "scale")]
    assert (scale["status"], scale["run_ft"], scale["signed_error_in"]) == (
        "scale_reference",
        "6.000",
        "",
    )
    assert rows[("photo-depth", "scale")]["run_ft"] == ""  # left out of that run

    facing = rows[("ar-taps", "c1-facing")]
    assert (facing["signed_error_in"], facing["abs_error_in"]) == ("-4.80", "4.80")
    assert facing["truth_within_reported"] == "false"

    edge = rows[("mesh-scaled", "c1-route")]  # 0.5 ft error, 0.5 ft reported
    assert (edge["signed_error_in"], edge["truth_within_reported"]) == ("-6.00", "true")

    assert rows[("mesh-scaled", "wall-length")]["truth_within_reported"] == ""
    assert rows[("mesh-scaled", "c1-gas")]["status"] == "false_absent"
    assert rows[("photo-depth", "c1-pool")]["status"] == "phantom"
    assert rows[("ar-taps", "c2-facing")]["status"] == "missing_failed"
    assert rows[("ar-taps", "c2-pool")]["status"] == "not_surveyed"


def test_check_rows(scored):
    _, table = scored
    rows = by_key(table("checks.csv"), "pipeline", "candidate", "check")
    assert len(rows) == 24

    unsafe = rows[("ar-taps", "c2", "gas")]
    assert unsafe["truth_outcome"] == "borderline"
    assert unsafe["margin_ft"] == "0.020"
    assert unsafe["error_to_margin"] == "11.00"  # 0.33 / max(0.02, 0.03)
    assert (unsafe["could_flip"], unsafe["unsafe_pass"], unsafe["agrees"]) == (
        "true",
        "true",
        "false",
    )

    route = rows[("ar-taps", "c2", "route")]
    assert (route["margin_ft"], route["error_to_margin"], route["agrees"]) == (
        "0.100",
        "4.00",  # 0.4 / max(0.1, 0.05)
        "true",
    )

    rejection = rows[("photo-depth", "c2", "route")]
    assert (rejection["false_rejection"], rejection["error_to_margin"]) == ("true", "11.00")

    assert rows[("ar-taps", "c2", "facing_gap")]["abstention"] == "justified"
    assert rows[("photo-depth", "c1", "route")]["abstention"] == "justified"
    assert rows[("photo-depth", "c1", "facing_gap")]["abstention"] == "avoidable"

    unknown = rows[("ar-taps", "c2", "pool")]
    assert (unknown["truth_outcome"], unknown["run_outcome"], unknown["agrees"]) == (
        "unknown",
        "unsure",
        "",
    )
    assert rows[("mesh-scaled", "c2", "gas")]["error_to_margin"] == "0.67"  # 0.02 / 0.03


def test_markdown_summary(scored):
    (stdout, stderr), _ = scored
    assert stdout.startswith("# Capture pipeline scores\n")
    assert "left out of every error figure" in stdout
    assert "Scale reference `scale` (5.000 ft), excluded." in stdout
    assert "| `ar-taps` | ar_poses | 6/9 | 3.48 | 4.80 | 3/6 | 0 | 1 | 0 | 0 | 1 | 1 |" in stdout
    assert "| `mesh-scaled` | no decisions | n/a | n/a | n/a | n/a | 0 |" in stdout
    assert "| `mesh-scaled` | 420.0 | not recorded |" in stdout
    assert (
        "- `ar-taps` passed `gas` at `c2`; the survey is borderline at 3.020 ± 0.030 ft against "
        "`gas_clearance_ft` at_least 3.000 ft (run measured 3.350 ft)."
    ) in stdout
    assert "case series" in stdout
    assert "wrote" in stderr and "runs.csv" in stderr


def test_bad_input_exits_2_with_the_reason(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    code = main(
        [
            "--rules",
            str(FIXTURES / "rules.json"),
            "--truth",
            str(FIXTURES / "truth" / "synthetic-01.json"),
            "--results",
            str(tmp_path / "missing.json"),
            "--out",
            str(tmp_path),
        ]
    )
    assert code == 2
    assert "cannot read" in capsys.readouterr().err
    assert not (tmp_path / "runs.csv").exists()
