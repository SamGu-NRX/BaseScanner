"""Decide whether recognizer output contains a labelled string.

Meter numbers are compared through a SHA-256 digest of their normalized form, because
CONTRIBUTING.md forbids committing meter numbers; the digest in manifest.csv lets anyone
rerun the eval without the plaintext.
"""

import hashlib
import re
from collections.abc import Sequence

# Lenient mode maps letters Vision commonly returns for digits. Applied to both the label and
# the output, so it can only add matches.
DIGIT_FIXUPS = str.maketrans({"O": "0", "I": "1", "L": "1"})


def normalize(text: str) -> str:
    """Uppercase and keep only A-Z and 0-9."""
    return re.sub(r"[^A-Z0-9]", "", text.upper())


def normalize_class(text: str) -> str:
    """Uppercase, keep A-Z, 0-9 and parentheses, and read × as X.

    Separators are dropped because meters print them inconsistently and Vision returns them
    inconsistently ("0.1-10" read as "0.1,-10", "20(60)A" as "20(60)/A"); parentheses stay
    so 10(60)A and 1060A remain different. This rule was loosened after inspecting the first
    run's misses, which were all separator or × differences.
    """
    return re.sub(r"[^A-Z0-9()]", "", text.upper().replace("×", "X"))


def core(text: str) -> str:
    """The normalized text without a leading run of letters before a digit.

    "NO. 12345678", "ABC 123456" and "XYZW123456" become 12345678, 123456 and 123456, so a
    utility prefix or a label word printed apart from the number does not decide a match.
    """
    return re.sub(r"^[A-Z]+(?=\d)", "", normalize(text))


def digest(normalized: str) -> str:
    return hashlib.sha256(normalized.encode()).hexdigest()


def rows_of_text(lines: Sequence[dict]) -> list[tuple[str, list[list[float]]]]:
    """Each line's (text, [box]), plus lines sharing a row joined left to right.

    Vision sometimes splits one printed number into two observations ("123 45" and "678").
    Two boxes share a row when their vertical overlap is at least half the shorter box.
    """
    texts = [(line["text"], [line["box"]]) for line in lines]
    rows: list[list[dict]] = []
    for line in sorted(lines, key=lambda item: item["box"][1]):
        _, y, _, h = line["box"]
        for row in rows:
            _, ry, _, rh = row[0]["box"]
            overlap = min(y + h, ry + rh) - max(y, ry)
            if overlap >= 0.5 * min(h, rh):
                row.append(line)
                break
        else:
            rows.append([line])
    for row in rows:
        if len(row) > 1:
            ordered = sorted(row, key=lambda item: item["box"][0])
            texts.append((" ".join(item["text"] for item in ordered), [i["box"] for i in ordered]))
    return texts


def number_boxes(
    lines: Sequence[dict], target_digest: str, length: int, lenient: bool
) -> list[list[float]] | None:
    """Boxes of the first line or joined row containing the labelled number, else None."""
    for text, boxes in rows_of_text(lines):
        candidate = normalize(text)
        if lenient:
            candidate = candidate.translate(DIGIT_FIXUPS)
        for start in range(len(candidate) - length + 1):
            if digest(candidate[start : start + length]) == target_digest:
                return boxes
    return None


def number_read(lines: Sequence[dict], target_digest: str, length: int, lenient: bool) -> bool:
    return number_boxes(lines, target_digest, length, lenient) is not None


def class_read(lines: Sequence[dict], label: str) -> bool:
    target = normalize_class(label)
    return any(target in normalize_class(text) for text, _ in rows_of_text(lines))


def lenient_digest(number: str) -> str:
    return digest(normalize(number).translate(DIGIT_FIXUPS))
