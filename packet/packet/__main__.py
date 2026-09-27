"""python -m packet validate <folder or zip> [--json]"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from packet.validate import validate


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m packet")
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("validate", help="check a packet folder or zip against the spec")
    check.add_argument("packet", type=Path)
    check.add_argument("--json", action="store_true", help="print the report as JSON")
    args = parser.parse_args(argv)

    report = validate(args.packet)
    if args.json:
        print(
            json.dumps(
                {
                    "ok": report.ok,
                    "problems": report.problems,
                    "warnings": report.warnings,
                    "summary": report.summary,
                },
                indent=2,
            )
        )
    else:
        print(f"{args.packet}: {'valid' if report.ok else 'INVALID'}")
        for key, value in report.summary.items():
            print(f"  {key}: {value}")
        for w in report.warnings:
            print(f"  warning: {w}")
        for p in report.problems:
            print(f"  problem: {p}")
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
