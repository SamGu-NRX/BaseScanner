"""Fail if a transcribed meter identifier appears in any tracked file of the repository.

identifier_digests.txt holds the keyed digest (match.digest) of every identifier either
reader transcribed, with and without a letter prefix. Every run of 4 to 24 letters and digits
with at least 4 digits in a tracked file is digested and looked up, so the check needs the
key but no plaintext, and runs in CI with the key from the METER_HMAC_KEY secret.

Separators are dropped before comparing, so a decimal measurement such as 62.5152 can collide
with an identifier. Only cells in MEASUREMENT_COLUMNS, which the experiment's own code fills
with measured numbers, are exempt, and only when they hold numbers. Every other cell is
scanned whatever its shape, so an identifier printed with dots is still caught.
"""

import csv
import io
import re
import subprocess
from collections.abc import Iterator
from pathlib import Path

from meter_eval.labels import SHORTEST_IDENTIFIER
from meter_eval.match import digest, normalize
from meter_eval.paths import EXPERIMENT_DIR

DIGESTS = EXPERIMENT_DIR / "identifier_digests.txt"
SHORTEST, LONGEST = SHORTEST_IDENTIFIER, 24
# Columns of the generated results CSVs that hold image measurements or degradation levels.
MEASUREMENT_COLUMNS = {
    "contrast",
    "edge_margin",
    "global_lap_var",
    "global_saturated",
    "height",
    "label_contrast",
    "label_edge_margin",
    "label_lap_var",
    "label_lap_var_32",
    "label_saturated",
    "label_text_height_px",
    "lap_var",
    "lap_var_32",
    "level",
    "number_box",
    "saturated",
    "text_height_px",
    "width",
}
NUMBER = r"-?\d+(?:\.\d+)?"
MEASUREMENT = re.compile(rf"{NUMBER}|\[{NUMBER}(?:, {NUMBER})*\]")


def pieces(name: str, text: str) -> list[str]:
    text = re.sub(r"\b[0-9a-f]{64}\b", "", text)  # the digests themselves
    if not name.endswith(".csv"):
        # One piece: normalize() drops every character but A-Z and 0-9, so an identifier
        # written with any separator (space, dot, slash, colon, line break...) is found.
        return [text]
    reader = csv.reader(io.StringIO(text))
    header = next(reader, [])
    found = list(header)
    for row in reader:
        for index, cell in enumerate(row):
            # Cells beyond the header, or under an empty one, have no column and are scanned.
            column = header[index] if index < len(header) else None
            if column in MEASUREMENT_COLUMNS and MEASUREMENT.fullmatch(cell):
                continue
            found.append(cell)
    return found


def windows(token: str) -> Iterator[str]:
    """Every substring of SHORTEST to LONGEST characters holding at least SHORTEST digits."""
    digits_before = [0]
    for ch in token:
        digits_before.append(digits_before[-1] + ch.isdigit())
    for start in range(len(token)):
        for end in range(start + SHORTEST, min(start + LONGEST, len(token)) + 1):
            if digits_before[end] - digits_before[start] >= SHORTEST:
                yield token[start:end]


def find_leaks(files: dict[str, str], known: set[str]) -> list[tuple[str, int]]:
    """(file name, identifier length) for every known identifier found in the given texts."""
    leaks = []
    for name, text in files.items():
        tokens = {normalize(p) for p in pieces(name, text)}
        seen = {part for token in tokens for part in windows(token)}
        leaks += [(name, len(part)) for part in seen if digest(part) in known]
    return sorted(leaks)


def repository_root(start: Path) -> Path:
    found = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=start,
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(found.stdout.strip())


def repository_files(root: Path) -> dict[str, str]:
    """Every tracked or new untracked text file in the repository, by path from the root.

    A copied meter number can land anywhere (docs, READMEs, the app), so the whole repository
    is scanned. Skipped: lockfiles, which hold generated hashes; the digest list itself; paths
    that are not regular files, such as a submodule; and binary files.
    """
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split("\0")
    files = {}
    for name in filter(None, listed):
        path = root / name
        if name.endswith((".lock", "-lock.yaml")) or path == DIGESTS or not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        files[name] = data.decode(errors="ignore")
    return files


def main() -> None:
    known = set(DIGESTS.read_text().split())
    files = repository_files(repository_root(EXPERIMENT_DIR))
    leaks = find_leaks(files, known)
    for name, length in leaks:
        print(f"{name}: a transcribed identifier ({length} characters)")
    if leaks:
        raise SystemExit(f"{len(leaks)} meter identifiers in tracked files; use synthetic ones")
    print(f"no transcribed identifier in {len(files)} files across the repository")


if __name__ == "__main__":
    main()
