"""Builders for small synthetic inputs. Numbers are strings so each one is an exact Decimal."""

import copy
import hashlib
import json
from decimal import Decimal
from pathlib import Path
from typing import Any

from scoring.inputs import PipelineMeasurement, SurveyMeasurement, Threshold

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def survey(
    value: str | None = "4",
    plus_minus: str | None = "0",
    *,
    status: str = "measured",
    id: str = "m",
    candidate: str | None = "c1",
) -> SurveyMeasurement:
    return SurveyMeasurement(
        id=id,
        candidate=candidate,
        start="footprint edge",
        end="gas regulator",
        status=status,  # type: ignore[arg-type]
        value_ft=None if value is None else Decimal(value),
        plus_minus_ft=None if plus_minus is None else Decimal(plus_minus),
        method="tape",
        measured_by=("surveyor-a",),
    )


def reported(
    value: str | None, plus_minus: str | None = None, *, missing: str | None = None, id: str = "m"
) -> PipelineMeasurement:
    return PipelineMeasurement(
        id=id,
        value_ft=None if value is None else Decimal(value),
        plus_minus_ft=None if plus_minus is None else Decimal(plus_minus),
        missing=missing,  # type: ignore[arg-type]
    )


def threshold(value: str = "3", pass_when: str = "at_least") -> Threshold:
    return Threshold("gas_clearance_ft", Decimal(value), pass_when, "synthetic")  # type: ignore[arg-type]


RULES: dict[str, Any] = {
    "format": 1,
    "unit": "ft",
    "name": "synthetic test rules",
    "thresholds": {
        "gas_clearance_ft": {"value_ft": 3, "pass_when": "at_least", "source": "synthetic"},
        "max_route_ft": {"value_ft": 20, "pass_when": "at_most", "source": "synthetic"},
    },
}

TRUTH: dict[str, Any] = {
    "format": 1,
    "unit": "ft",
    "house": "h1",
    "captures": ["cap-1"],
    "scale_reference": "scale",
    "candidates": [{"id": "c1", "marker": "blue tape", "location": "south wall"}],
    "measurements": [
        {
            "id": "scale",
            "candidate": None,
            "from": "mark A",
            "to": "mark B",
            "status": "measured",
            "value_ft": 5.0,
            "plus_minus_ft": 0.01,
            "method": "tape",
            "measured_by": ["a", "b"],
        },
        {
            "id": "c1-gas",
            "candidate": "c1",
            "from": "footprint edge",
            "to": "gas regulator",
            "status": "measured",
            "value_ft": 4.5,
            "plus_minus_ft": 0.01,
            "method": "tape",
            "measured_by": ["a", "b"],
        },
        {
            "id": "c1-route",
            "candidate": "c1",
            "from": "meter",
            "to": "battery",
            "status": "measured",
            "value_ft": 12,
            "plus_minus_ft": 0.05,
            "method": "tape",
            "measured_by": ["a"],
        },
    ],
    "checks": [
        {
            "candidate": "c1",
            "check": "gas",
            "measurement": "c1-gas",
            "threshold": "gas_clearance_ft",
        },
        {
            "candidate": "c1",
            "check": "route",
            "measurement": "c1-route",
            "threshold": "max_route_ft",
        },
    ],
}

RESULTS: dict[str, Any] = {
    "format": 1,
    "unit": "ft",
    "pipeline": "p1",
    "capture": "cap-1",
    "rules_sha256": "",  # filled in by Files.write_all
    "scale_source": "ar_poses",
    "measurements": [
        {"id": "c1-gas", "value_ft": 4.7, "plus_minus_ft": 0.3},
        {"id": "c1-route", "value_ft": None, "missing": "failed"},
    ],
    "outcomes": [
        {"candidate": "c1", "check": "gas", "outcome": "pass"},
        {"candidate": "c1", "check": "route", "outcome": "unsure"},
    ],
    "timing": {"capture_s": 300, "processing_s": 10},
}


class Files:
    """Writes editable copies of RULES, TRUTH and RESULTS into a temporary directory."""

    def __init__(self, root: Path):
        self.root = root
        self.rules = copy.deepcopy(RULES)
        self.truth = copy.deepcopy(TRUTH)
        self.results = copy.deepcopy(RESULTS)

    def write(self, name: str, data: Any) -> Path:
        path = self.root / name
        path.write_text(json.dumps(data, indent=2))
        return path

    def write_all(self, *, fill_hash: bool = True) -> tuple[Path, Path, Path]:
        rules = self.write("rules.json", self.rules)
        if fill_hash and not self.results["rules_sha256"]:
            self.results["rules_sha256"] = hashlib.sha256(rules.read_bytes()).hexdigest()
        return rules, self.write("truth.json", self.truth), self.write("results.json", self.results)
