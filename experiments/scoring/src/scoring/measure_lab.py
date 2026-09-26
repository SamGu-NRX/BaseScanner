"""Turn a Measure Lab session zip into a results file the scorer reads.

The rig's measurements carry app-generated ids and meter values. A map file, written by hand after
the walk, says which session measurement and which `values` key answers each survey measurement,
and with what uncertainty. The importer converts meters to feet, writes one results file, and
loads that file through the scorer before saving it, so an import that would not score is never
written.

The session format is Measure Lab's formatVersion 2, documented in experiments/measure-lab/README.md
("Session format") on branch t3/measure-lab. Only the fields used here are validated.
"""

import argparse
import hashlib
import json
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, localcontext
from pathlib import Path
from typing import Any

from scoring.inputs import (
    FORMAT,
    UNIT,
    InputError,
    MissingReason,
    Rules,
    Truth,
    _Fields,
    _parse_json,
    _read_json,
    load_rules,
    load_study,
    load_truth,
)
from scoring.metrics import decide

SESSION_FORMAT = "measure-lab-session"
SESSION_FORMAT_VERSION = 2
VALUE_KEYS = ("straight", "horizontal", "vertical", "alongWall", "gapToWall", "heightAboveGround")

# Exact by definition (international yard and pound agreement, 1959).
METERS_PER_FOOT = Decimal("0.3048")
# Feet are rounded to 6 decimal places (a millionth of a foot, about 0.3 micrometers). The rig's
# values are ARKit estimates good to centimeters at best, so this rounding changes nothing a tape
# could see, and it keeps every written value inside the scorer's 12-decimal-place limit. Division
# by 0.3048 rarely terminates (1 m is 3.28083989501312... ft), so some rounding is unavoidable.
FEET_PLACES = Decimal("0.000001")
# Capture time comes from the device-uptime clock, a Double of seconds. Milliseconds are finer
# than any walk timing needs and keep the value inside the same 12-decimal limit.
SECONDS_PLACES = Decimal("0.001")
# ARKit world tracking supplies metric scale from visual-inertial odometry; the rig uses no
# scale reference and no depth model, so every imported row declares AR camera poses.
SCALE_SOURCE = "ar_poses"
# Suffix for a row whose outcomes this importer computed with the survey's rule.
RULE_SUFFIX = "+rule"

MAP_ENTRY_FIELDS = {"session_measurement", "key", "plus_minus_ft", "refusal"}


def meters_to_feet(meters: Decimal) -> Decimal:
    """Exact division by 0.3048, then half-up rounding to FEET_PLACES."""
    with localcontext() as context:
        context.prec = 50
        return (meters / METERS_PER_FOOT).quantize(FEET_PLACES, rounding=ROUND_HALF_UP)


@dataclass(frozen=True)
class SessionMeasurement:
    id: str
    time: Decimal
    values: dict[str, Decimal]
    compared: str
    accepted: bool


@dataclass(frozen=True)
class Session:
    zip_path: Path
    zip_sha256: str
    member: str
    id: str
    started_at_uptime: Decimal
    measurements: dict[str, SessionMeasurement]
    refusals: set[str]


def _number(value: Any, where: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, int | Decimal):
        raise InputError(f"{where}: expected a number, got {value!r}")
    return Decimal(value)


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise InputError(f"{where}: expected a non-empty string, got {value!r}")
    return value


def _list(data: dict[str, Any], key: str, where: str) -> list[Any]:
    value = data.get(key)
    if not isinstance(value, list):
        raise InputError(f"{where}: expected a list in {key!r}, got {value!r}")
    return value


def _session_member(archive: zipfile.ZipFile, path: Path) -> str:
    """The one session.json, at the zip's root or inside its single session folder."""
    found = [
        name
        for name in archive.namelist()
        if not name.startswith("__MACOSX/")
        and name.split("/")[-1] == "session.json"
        and name.count("/") <= 1
    ]
    if len(found) != 1:
        where = "none" if not found else ", ".join(found)
        raise InputError(
            f"{path}: expected exactly one session.json at the top of the zip or in its session "
            f"folder, found {where}; share the session from Measure Lab's Session sheet"
        )
    return found[0]


def load_session(path: Path) -> Session:
    try:
        raw_zip = path.read_bytes()
    except OSError as error:
        raise InputError(f"{path}: cannot read ({error.strerror})") from None
    try:
        with zipfile.ZipFile(path) as archive:
            member = _session_member(archive, path)
            raw = archive.read(member)
    except zipfile.BadZipFile:
        raise InputError(f"{path}: not a zip file") from None
    where = f"{path}!{member}"
    data = _parse_json(raw, where)
    if not isinstance(data, dict):
        raise InputError(f"{where}: expected a JSON object")

    if data.get("format") != SESSION_FORMAT:
        raise InputError(f"{where}: format is {data.get('format')!r}, not {SESSION_FORMAT!r}")
    version = data.get("formatVersion")
    if type(version) is not int or version != SESSION_FORMAT_VERSION:
        raise InputError(
            f"{where}: formatVersion is {version!r}; this importer reads Measure Lab session "
            f"format {SESSION_FORMAT_VERSION} only, whose value fields may differ in other versions"
        )
    units = data.get("units")
    if not isinstance(units, dict) or units.get("length") != "meters":
        raise InputError(f"{where}: units.length must be 'meters'")

    info = data.get("session")
    if not isinstance(info, dict):
        raise InputError(f"{where}: session: expected an object")
    session_id = _text(info.get("id"), f"{where}: session.id")
    started = _number(info.get("startedAtUptime"), f"{where}: session.startedAtUptime")

    measurements: dict[str, SessionMeasurement] = {}
    for index, entry in enumerate(_list(data, "measurements", where)):
        at = f"{where}: measurements[{index}]"
        if not isinstance(entry, dict):
            raise InputError(f"{at}: expected an object")
        measurement_id = _text(entry.get("id"), f"{at}.id")
        if measurement_id in measurements:
            raise InputError(f"{at}.id: measurement {measurement_id!r} is listed twice")
        values = entry.get("values")
        if not isinstance(values, dict):
            raise InputError(f"{at} ({measurement_id}).values: expected an object")
        accepted = entry.get("accepted")
        if not isinstance(accepted, bool):
            raise InputError(f"{at} ({measurement_id}).accepted: expected true or false")
        measurements[measurement_id] = SessionMeasurement(
            id=measurement_id,
            time=_number(entry.get("time"), f"{at} ({measurement_id}).time"),
            values={
                key: _number(value, f"{at} ({measurement_id}).values.{key}")
                for key, value in values.items()
            },
            compared=_text(entry.get("compared"), f"{at} ({measurement_id}).compared"),
            accepted=accepted,
        )

    refusals: set[str] = set()
    for index, entry in enumerate(_list(data, "refusals", where)):
        if not isinstance(entry, dict):
            raise InputError(f"{where}: refusals[{index}]: expected an object")
        refusals.add(_text(entry.get("id"), f"{where}: refusals[{index}].id"))

    return Session(
        zip_path=path,
        zip_sha256=hashlib.sha256(raw_zip).hexdigest(),
        member=member,
        id=session_id,
        started_at_uptime=started,
        measurements=measurements,
        refusals=refusals,
    )


@dataclass(frozen=True)
class FromSession:
    measurement: str
    key: str
    plus_minus_ft: Decimal


@dataclass(frozen=True)
class FromRefusal:
    refusal: str


@dataclass(frozen=True)
class Map:
    path: Path
    pipeline: str
    session: str
    entries: dict[str, FromSession | FromRefusal | MissingReason]


def load_map(path: Path) -> Map:
    data, _ = _read_json(path)
    top = _Fields(
        data,
        path,
        "",
        {"format", "unit", "pipeline", "session", "notes", "plus_minus_ft_by_key", "measurements"},
    )
    top.header()
    if top.has("notes"):
        top.text("notes")  # free text for people, such as where an uncertainty comes from
    by_key: dict[str, Decimal] = {}
    if top.has("plus_minus_ft_by_key"):
        table = top.raw("plus_minus_ft_by_key")
        keys = top.child(table, "plus_minus_ft_by_key", VALUE_KEYS)
        by_key = {key: keys.length(key) for key in keys.data}

    table = top.raw("measurements")
    if not isinstance(table, dict) or not table:
        raise top.error("expected an object keyed by survey measurement id", "measurements")
    entries: dict[str, FromSession | FromRefusal | MissingReason] = {}
    for survey_id, entry in table.items():
        where = f"measurements.{survey_id}"
        if entry in ("absent", "unsupported"):
            entries[survey_id] = entry
            continue
        if isinstance(entry, str):
            raise top.error(f'expected "absent", "unsupported" or an object, got {entry!r}', where)
        fields = top.child(entry, where, MAP_ENTRY_FIELDS)
        if fields.has("refusal"):
            extra = sorted(set(fields.data) - {"refusal"})
            if extra:
                raise fields.error(f"a refusal entry takes no {', '.join(extra)}")
            entries[survey_id] = FromRefusal(fields.text("refusal"))
            continue
        key = fields.choice("key", VALUE_KEYS)
        if fields.has("plus_minus_ft"):
            plus_minus = fields.length("plus_minus_ft")
        elif key in by_key:
            plus_minus = by_key[key]
        else:
            raise fields.error(
                f"no uncertainty for values key {key!r}; state plus_minus_ft here or in "
                "plus_minus_ft_by_key"
            )
        entries[survey_id] = FromSession(fields.text("session_measurement"), key, plus_minus)

    return Map(path, top.text("pipeline"), top.text("session"), entries)


def _check_map(mapping: Map, session: Session, truth: Truth) -> None:
    where = str(mapping.path)
    if mapping.session != session.id:
        raise InputError(
            f"{where}: session is {mapping.session!r}, but {session.zip_path} holds session "
            f"{session.id!r}; this map was written for another walk"
        )
    unknown = sorted(set(mapping.entries) - set(truth.measurements))
    if unknown:
        raise InputError(
            f"{where}: measurements {', '.join(map(repr, unknown))} are not survey measurement "
            f"ids in {truth.path}"
        )
    # The scale reference may be left out, as in a results file: the rig does not use it.
    left_out = sorted(set(truth.measurements) - set(mapping.entries) - {truth.scale_reference})
    if left_out:
        raise InputError(
            f"{where}: no entry for survey measurements {', '.join(map(repr, left_out))}; map "
            'each to a session measurement, a refusal, "absent" or "unsupported"'
        )
    for survey_id, entry in mapping.entries.items():
        at = f"{where}: measurements.{survey_id}"
        if isinstance(entry, FromRefusal) and entry.refusal not in session.refusals:
            raise InputError(f"{at}.refusal: {session.member} has no refusal {entry.refusal!r}")
        if not isinstance(entry, FromSession):
            continue
        measurement = session.measurements.get(entry.measurement)
        if measurement is None:
            raise InputError(
                f"{at}.session_measurement: {session.member} has no measurement "
                f"{entry.measurement!r}"
            )
        if entry.key not in measurement.values:
            raise InputError(
                f"{at}.key: measurement {entry.measurement!r} has no {entry.key!r} value; it has "
                f"{', '.join(measurement.values) or 'none'}"
            )
        if entry.key != measurement.compared:
            raise InputError(
                f"{at}.key: {entry.key!r} was not the validated quantity for measurement "
                f"{entry.measurement!r}; its compared field is {measurement.compared!r}"
            )
        if measurement.accepted and measurement.values[entry.key] < 0:
            raise InputError(
                f"{at}: measurement {entry.measurement!r} is accepted but its {entry.key} is "
                f"{measurement.values[entry.key]} m; format 2 only allows a negative "
                "heightAboveGround, and marks it belowGround and not accepted"
            )


def _measurement_entry(
    survey_id: str, entry: FromSession | FromRefusal | MissingReason, session: Session
) -> dict[str, Any]:
    if isinstance(entry, str):
        return {"id": survey_id, "value_ft": None, "missing": entry}
    if isinstance(entry, FromRefusal):
        return {"id": survey_id, "value_ft": None, "missing": "failed"}
    measurement = session.measurements[entry.measurement]
    if not measurement.accepted:
        # The rig's own abstention: a value with warnings that its scoring counts as no answer.
        return {"id": survey_id, "value_ft": None, "missing": "failed"}
    return {
        "id": survey_id,
        "value_ft": meters_to_feet(measurement.values[entry.key]),
        "plus_minus_ft": entry.plus_minus_ft,
    }


def _outcomes(
    truth: Truth, rules: Rules, measurements: dict[str, dict[str, Any]]
) -> list[dict[str, Any]]:
    """Apply the survey's strict rule to the run's own value and uncertainty for every check."""
    outcomes = []
    for check in truth.checks:
        threshold = rules.thresholds[check.threshold]
        review = (
            None if check.review_threshold is None else rules.thresholds[check.review_threshold]
        )
        entry = measurements[check.measurement]
        if entry["value_ft"] is not None:
            result = decide(entry["value_ft"], entry["plus_minus_ft"], threshold, review)
            outcome = {"pass": "pass", "fail": "fail"}.get(result, "unsure")
        elif entry["missing"] == "absent" and threshold.pass_when == "at_least":
            outcome = "pass"  # a feature that is not there clears a clearance, as in the survey
        else:
            outcome = "unsure"  # no evidence: the rule never decides without a value
        outcomes.append({"candidate": check.candidate, "check": check.check, "outcome": outcome})
    return outcomes


def build_results(
    session: Session, mapping: Map, rules: Rules, truth: Truth, *, decide_outcomes: bool
) -> dict[str, Any]:
    _check_map(mapping, session, truth)
    if session.zip_sha256 not in truth.captures:
        raise InputError(
            f"{truth.path}: captures does not list {session.zip_sha256}, the sha256 of "
            f"{session.zip_path}; add it so this run is scored against this survey"
        )
    measurements = {
        survey_id: _measurement_entry(survey_id, mapping.entries[survey_id], session)
        for survey_id in truth.measurements
        if survey_id in mapping.entries
    }
    times = [measurement.time for measurement in session.measurements.values()]
    capture_s = None
    if times:
        capture_s = (max(times) - session.started_at_uptime).quantize(
            SECONDS_PLACES, rounding=ROUND_HALF_UP
        )
        if capture_s < 0:
            raise InputError(f"{session.zip_path}: a measurement predates startedAtUptime")
    return {
        "format": FORMAT,
        "unit": UNIT,
        "pipeline": mapping.pipeline + (RULE_SUFFIX if decide_outcomes else ""),
        "capture": session.zip_sha256,
        "rules_sha256": rules.sha256,
        "scale_source": SCALE_SOURCE,
        "measurements": list(measurements.values()),
        "outcomes": _outcomes(truth, rules, measurements) if decide_outcomes else None,
        # capture_s: session start to its last measurement, on the rig's uptime clock.
        # processing_s: null. The rig shows each value when it is tapped, so there is no
        # processing stage after the walk, and session.json records no time for one; writing 0
        # would claim a measurement nobody took. The importer's own run time is not the rig's.
        "timing": {"capture_s": capture_s, "processing_s": None},
    }


def dumps(value: Any, indent: str = "") -> str:
    """JSON text with every Decimal written exactly, never through a float."""
    inner = indent + "  "
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [f"{inner}{_string(key)}: {dumps(item, inner)}" for key, item in value.items()]
        return "{\n" + ",\n".join(items) + f"\n{indent}}}"
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[\n" + ",\n".join(inner + dumps(item, inner) for item in value) + f"\n{indent}]"
    if isinstance(value, Decimal):
        return format(value, "f")
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _string(value)
    raise TypeError(f"cannot write {type(value).__name__} as JSON")


def _string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def import_session(
    session_path: Path,
    map_path: Path,
    rules_path: Path,
    truth_path: Path,
    out_path: Path,
    *,
    decide_outcomes: bool,
) -> dict[str, Any]:
    rules = load_rules(rules_path)
    truth = load_truth(truth_path, rules)
    session = load_session(session_path)
    results = build_results(
        session, load_map(map_path), rules, truth, decide_outcomes=decide_outcomes
    )
    text = dumps(results) + "\n"
    # Score the output before saving it, so a file that would not load is never written.
    with tempfile.TemporaryDirectory() as scratch:
        candidate = Path(scratch) / "results.json"
        candidate.write_text(text, encoding="utf-8")
        load_study(rules_path, [truth_path], [candidate])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text, encoding="utf-8")
    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="score import-measure-lab",
        description="Convert a Measure Lab session zip (format 2) into a results file, using a "
        "map file that ties session measurements to survey measurement ids.",
    )
    parser.add_argument("session", type=Path, help="session zip shared from Measure Lab")
    parser.add_argument("--map", type=Path, required=True, help="map file (JSON)")
    parser.add_argument("--rules", type=Path, required=True, help="rules file (JSON)")
    parser.add_argument("--truth", type=Path, required=True, help="survey file for this house")
    parser.add_argument("--out", type=Path, required=True, help="results file to write")
    parser.add_argument(
        "--decide",
        action="store_true",
        help=f"compute pass/unsure/fail with the survey's strict rule and add {RULE_SUFFIX} "
        "to the pipeline id; without it the row makes no decisions",
    )
    args = parser.parse_args(argv)
    try:
        results = import_session(
            args.session,
            args.map,
            args.rules,
            args.truth,
            args.out,
            decide_outcomes=args.decide,
        )
    except InputError as error:
        print(f"score import-measure-lab: {error}", file=sys.stderr)
        return 2
    print(
        f"score import-measure-lab: wrote {args.out} (pipeline {results['pipeline']}, "
        f"capture {results['capture']})",
        file=sys.stderr,
    )
    return 0
