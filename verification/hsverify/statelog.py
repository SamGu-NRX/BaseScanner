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
LOG_PREDICATE = f'subsystem == "{SUBSYSTEM}" AND category == "{CATEGORY}"'

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


def parse_ndjson_line(line: str) -> StateEvent | None:
    """Return the STATE event on one `log stream --style ndjson` line, or None.

    Lines that are not JSON (the stream prints a banner first), entries from other
    subsystems or categories, and messages without a marker all return None.
    Raises RedactedStateError when the message is the redaction placeholder, because
    silently dropping it would make a working app look like it logs nothing.
    """
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        return None
    if entry.get("subsystem") != SUBSYSTEM or entry.get("category") != CATEGORY:
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
