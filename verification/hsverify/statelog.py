"""Reading the app's STATE markers (contract C4) out of `log stream --style ndjson` output.

The app logs `STATE=<name>` under subsystem `dev.housescanning.housescan`, category `state`.
Everything here is pure so the parsing rules can be tested without a Simulator.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

SUBSYSTEM = "dev.housescanning.housescan"
CATEGORY = "state"
# Every category of the app is streamed into the report (engine and autopilot lines explain what
# happened); only `state` lines are parsed as screens.
LOG_PREDICATE = f'subsystem == "{SUBSYSTEM}"'

ENGINE_CATEGORY = "engine"
# The engine logs `bundle <path> with <N> keyframes` once it has written a scan bundle; the path
# is on the Mac's disk, inside the Simulator's app container.
# "bundle <path>.zip with N keyframes", optionally followed by ", <details>" (app 194f2eb adds
# depth and mesh counts); from app f14947e, "bundle <path>.zip: packet 1.1 with N photos ...".
_BUNDLE_RE = re.compile(
    r"^bundle (.+\.zip)(?: with (\d+) keyframes(?:,.*)?|: .*?\bwith (\d+) photos\b.*)$"
)

# A state name is an identifier-like token. Anything after it on the line is detail.
_STATE_RE = re.compile(r"STATE=([A-Za-z0-9_.\-]+)")
_REDACTED = "<private>"


@dataclass(frozen=True)
class StateEvent:
    name: str
    timestamp: str  # as printed by `log stream`, kept verbatim for the report
    message: str


class RedactedStateError(ValueError):
    """The app logged the marker as a private string, so `log stream` shows `<private>`.

    The fix is on the app side: log the name with `privacy: .public`.
    """


def _app_entry(line: str, category: str) -> dict | None:
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        return None
    if entry.get("subsystem") != SUBSYSTEM or entry.get("category") != category:
        return None
    return entry


def parse_bundle_line(line: str) -> tuple[str, int] | None:
    """(zip path, keyframe or photo count) from the engine's bundle line, or None for any other
    line."""
    entry = _app_entry(line, ENGINE_CATEGORY)
    match = _BUNDLE_RE.match((entry or {}).get("eventMessage") or "")
    if not match:
        return None
    return match.group(1), int(match.group(2) or match.group(3))


def parse_ndjson_line(line: str) -> StateEvent | None:
    """Return the STATE event on one `log stream --style ndjson` line, or None.

    Lines that are not JSON (the stream prints a banner first), entries from other
    subsystems or categories, and messages without a marker all return None.
    Raises RedactedStateError when the message is the redaction placeholder, because
    silently dropping it would make a working app look like it logs nothing.
    """
    entry = _app_entry(line, CATEGORY)
    if entry is None:
        return None
    message = entry.get("eventMessage") or ""
    match = _STATE_RE.search(message)
    if match is None:
        if _REDACTED in message:
            raise RedactedStateError(message)
        return None
    return StateEvent(name=match.group(1), timestamp=entry.get("timestamp", ""), message=message)


def parse_plain_line(line: str) -> str | None:
    """Return the state name from a plain text line such as the app's stdout, or None."""
    match = _STATE_RE.search(line)
    return match.group(1) if match else None
