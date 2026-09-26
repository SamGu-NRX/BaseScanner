import json

import pytest

from hsverify.statelog import (
    CATEGORY,
    SUBSYSTEM,
    RedactedStateError,
    parse_bundle_line,
    parse_ndjson_line,
    parse_plain_line,
)


def entry(message: str, subsystem: str = SUBSYSTEM, category: str = CATEGORY) -> str:
    return json.dumps(
        {
            "timestamp": "2026-09-26 02:50:00.123456-0500",
            "subsystem": subsystem,
            "category": category,
            "eventMessage": message,
        }
    )


def test_reads_state_name():
    event = parse_ndjson_line(entry("STATE=wall_walk"))
    assert event is not None
    assert event.name == "wall_walk"
    assert event.timestamp.startswith("2026-09-26")


def test_detail_after_the_name_is_not_part_of_it():
    event = parse_ndjson_line(entry("STATE=gap_request wall=w1 from=-4.0"))
    assert event is not None
    assert event.name == "gap_request"


@pytest.mark.parametrize(
    "line",
    [
        "Filtering the log data using ...",  # banner printed before the JSON lines
        "",
        "{not json",
        entry("STATE=x", subsystem="com.apple.arkit"),
        entry("STATE=x", category="network"),
        entry("tracking normal"),
    ],
)
def test_ignores_everything_else(line):
    assert parse_ndjson_line(line) is None


@pytest.mark.parametrize("message", ["<private>", "STATE=<private>"])
def test_redacted_marker_is_loud(message):
    with pytest.raises(RedactedStateError):
        parse_ndjson_line(entry(message))


def test_plain_line():
    assert parse_plain_line("2026 app[12] STATE=result_reveal") == "result_reveal"
    assert parse_plain_line("no marker here") is None


BUNDLE_PATH = "/Users/x/Library/Developer/CoreSimulator/Devices/D/data/Caches/Scans/S/scan.zip"


def test_reads_the_engine_bundle_line():
    line = entry(f"bundle {BUNDLE_PATH} with 77 keyframes", category="engine")
    assert parse_bundle_line(line) == (BUNDLE_PATH, 77)


@pytest.mark.parametrize(
    "line",
    [
        entry(f"bundle {BUNDLE_PATH} with 77 keyframes"),  # state category
        entry(f"bundle {BUNDLE_PATH} with 77 keyframes", subsystem="other", category="engine"),
        entry("bundle written", category="engine"),
        "Filtering the log data using ...",
    ],
)
def test_bundle_line_ignores_everything_else(line):
    assert parse_bundle_line(line) is None
