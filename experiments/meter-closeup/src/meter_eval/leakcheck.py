"""Fail if a transcribed meter identifier appears in any tracked file of this experiment.

identifier_digests.txt holds the keyed digest (match.digest) of every identifier either
reader transcribed, with and without a letter prefix. Every run of 5 to 24 letters and digits
with at least 5 digits in a tracked file is digested and looked up, so the check needs the
key but no plaintext, and runs in CI with the key from the METER_HMAC_KEY secret.
"""

import csv
import re
import subprocess

from meter_eval.match import digest, normalize
from meter_eval.paths import EXPERIMENT_DIR

DIGESTS = EXPERIMENT_DIR / "identifier_digests.txt"
SHORTEST, LONGEST = 5, 24


def pieces(name: str, text: str) -> list[str]:
    text = re.sub(r"\b[0-9a-f]{64}\b", "", text)  # the digests themselves
    if name.endswith(".csv"):
        # Cell by cell; decimal measurements such as 62.5152 are not identifiers.
        cells = [c for row in csv.reader(text.splitlines()) for c in row]
        return [c for c in cells if not re.fullmatch(r"-?\d+\.\d+", c)]
    return re.findall(r"[A-Za-z0-9][A-Za-z0-9 .\-]*", text)


def windows(token: str):
    for length in range(SHORTEST, min(LONGEST, len(token)) + 1):
        for start in range(len(token) - length + 1):
            part = token[start : start + length]
            if sum(ch.isdigit() for ch in part) >= SHORTEST:
                yield part


def main() -> None:
    known = set(DIGESTS.read_text().split())
    tracked = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "."],
        cwd=EXPERIMENT_DIR,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    leaks = []
    for name in tracked:
        if name.endswith(".lock") or name == DIGESTS.name:
            continue
        text = (EXPERIMENT_DIR / name).read_text(errors="ignore")
        tokens = {normalize(p) for p in pieces(name, text)}
        seen = {part for token in tokens for part in windows(token)}
        leaks += [(name, len(part)) for part in seen if digest(part) in known]
    for name, length in sorted(leaks):
        print(f"{name}: a transcribed identifier ({length} characters)")
    if leaks:
        raise SystemExit(f"{len(leaks)} meter identifiers in tracked files; use synthetic ones")
    print(f"no transcribed identifier in {len(tracked)} files")


if __name__ == "__main__":
    main()
