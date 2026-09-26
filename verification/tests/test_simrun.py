import datetime as dt
import io
import json
import queue
from pathlib import Path

from hsverify.simrun import (
    ShotRecord,
    compiling,
    copy_app_export,
    missing_required,
    pump_log,
    seconds_since,
    slug,
    wait_for_log_stream,
)
from hsverify.statelog import SUBSYSTEM

BANNER = 'Filtering the log data using "subsystem == "dev.housescanning.housescan""\n'


def log_line(message: str, category: str = "state") -> str:
    return (
        json.dumps(
            {
                "timestamp": "2026-09-26 02:50:00.123456-0500",
                "subsystem": SUBSYSTEM,
                "category": category,
                "eventMessage": message,
            }
        )
        + "\n"
    )


def test_state_time_uses_the_log_clock():
    stamp = "2026-09-26 02:47:25.977214-0500"
    logged = dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    assert seconds_since(logged - 2.5, stamp, fallback=9.0) == 2.5


def test_unparseable_timestamp_falls_back_to_arrival_time():
    assert seconds_since(0.0, "", fallback=1.234) == 1.23


def test_slug_is_filename_safe():
    assert slug("origin/t3/ios-mvf") == "origin-t3-ios-mvf"
    assert slug("wall walk: gap!") == "wall-walk-gap"


def test_only_compiling_xcodebuilds_block_a_build():
    assert compiling("/Applications/Xcode.app/.../xcodebuild -project a.xcodeproj build")
    assert compiling("xcodebuild test -project a.xcodeproj -scheme A")
    assert not compiling("xcodebuild -project a.xcodeproj test-without-building")


# --- log stream readiness --------------------------------------------------------------------


def drain(events: queue.Queue) -> list:
    items = []
    while not events.empty():
        items.append(events.get_nowait())
    return items


def test_ready_is_signalled_by_the_first_line_then_states_follow():
    events: queue.Queue = queue.Queue()
    sink = io.StringIO()
    pump_log(iter([BANNER, log_line("STATE=onboarding")]), events, sink)
    kinds = [(kind, getattr(payload, "name", payload)) for kind, payload in drain(events)]
    assert kinds == [("ready", BANNER.strip()), ("state", "onboarding")]
    assert sink.getvalue() == BANNER + log_line("STATE=onboarding")


def test_a_silent_log_stream_never_signals_ready_and_times_out():
    events: queue.Queue = queue.Queue()
    pump_log(iter([]), events, io.StringIO())
    assert events.empty()
    assert wait_for_log_stream(events, 0.01) == (
        "log stream printed nothing within 0 s; the app was not launched"
    )


def test_wait_for_log_stream_passes_once_ready():
    events: queue.Queue = queue.Queue()
    pump_log(iter([BANNER]), events, io.StringIO())
    assert wait_for_log_stream(events, 1.0) is None


# --- required states -------------------------------------------------------------------------


def shot(state: str) -> ShotRecord:
    return ShotRecord(1, state, 0.0, "01.png", False, f"STATE={state}")


def test_missing_required_state_is_a_problem():
    states = [shot("onboarding"), shot("uploading")]
    assert missing_required(["result"], states) == ["required state result never appeared"]
    assert missing_required(["result"], [*states, shot("result")]) == []
    assert missing_required([], []) == []


def test_sim_app_requires_the_result_state():
    makefile = (Path(__file__).resolve().parents[1] / "Makefile").read_text()
    recipe = makefile.split("\nsim-app:\n", 1)[1].split("\n\n", 1)[0]
    assert "--require result" in recipe


# --- app export ------------------------------------------------------------------------------


def write_log(out: Path, *lines: str) -> None:
    (out / "state.ndjson").write_text(BANNER + "".join(lines))


def test_last_logged_bundle_is_copied_as_scan_zip(tmp_path):
    first, last = tmp_path / "first.zip", tmp_path / "last.zip"
    first.write_bytes(b"old")
    last.write_bytes(b"PK new")
    out = tmp_path / "report"
    out.mkdir()
    write_log(
        out,
        log_line(f"bundle {first} with 3 keyframes", category="engine"),
        log_line("STATE=result"),
        log_line(f"bundle {last} with 77 keyframes", category="engine"),
    )
    assert copy_app_export(out) == ("scan.zip", [])
    assert (out / "scan.zip").read_bytes() == b"PK new"


def test_no_bundle_logged_means_no_export_and_no_problem(tmp_path):
    write_log(tmp_path, log_line("STATE=onboarding"))
    assert copy_app_export(tmp_path) == (None, [])
    assert not (tmp_path / "scan.zip").exists()


def test_logged_bundle_that_is_gone_is_a_problem(tmp_path):
    gone = tmp_path / "gone.zip"
    write_log(tmp_path, log_line(f"bundle {gone} with 5 keyframes", category="engine"))
    export, problems = copy_app_export(tmp_path)
    assert export is None
    assert len(problems) == 1
    assert problems[0].startswith(f"the app logged bundle {gone} with 5 keyframes; copy failed")
