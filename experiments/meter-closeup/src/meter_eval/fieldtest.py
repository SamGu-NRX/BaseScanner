"""Score a folder of real close-ups against the retake checks and the number finder.

    uv run python -m meter_eval.fieldtest PHOTO_DIR --number "12 345 678"

For each photo: whether Vision read the number, where the number-finding ranking put it, the
checks the app would run, and whether they would have asked for a retake. As in the app, the
checks use the ranking's top candidate, not the true number; --number only scores the
outcome. The summary counts the two costly outcomes: a retake asked for a photo that read (a
wasted retake) and a photo accepted that did not read (a re-request later). The meter number
is taken from the command line and is never written to disk.
"""

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageOps

from meter_eval import retake
from meter_eval.locate import candidates, ranked, top_candidate
from meter_eval.match import core, digest, normalize, number_boxes
from meter_eval.ocr import Reader
from meter_eval.quality import gray

SUFFIXES = {".jpg", ".jpeg", ".png", ".heic"}


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("folder", type=Path)
    parser.add_argument("--number", required=True, help="the meter number as printed")
    args = parser.parse_args()

    target, length = digest(normalize(args.number)), len(normalize(args.number))
    target_core = digest(core(args.number))
    photos = sorted(p for p in args.folder.iterdir() if p.suffix.lower() in SUFFIXES)
    if not photos:
        raise SystemExit(f"no .jpg, .png or .heic photos in {args.folder}")

    upright = args.folder / ".upright.jpg"
    print(
        "| Photo | Read | Rank | Top candidate is the number | Top line px | Sharpness | "
        "Retake because |"
    )
    print("|---|---|---|---|---|---|---|")
    wasted = missed = 0
    with Reader() as reader:
        for photo in photos:
            source = photo
            if photo.suffix.lower() == ".heic":
                # PIL cannot decode HEIC; macOS sips can, and keeps the orientation tag.
                source = args.folder / ".converted.jpg"
                subprocess.run(
                    ["sips", "-s", "format", "jpeg", str(photo), "--out", str(source)],
                    check=True,
                    capture_output=True,
                )
            with Image.open(source) as image:
                ImageOps.exif_transpose(image).convert("RGB").save(upright, quality=95)
            result = reader.read(upright, barcodes=True)
            read = number_boxes(result["lines"], target, length, lenient=False) is not None
            order = ranked(candidates(result))
            rank = next((i + 1 for i, c in enumerate(order) if digest(c) == target_core), None)
            with Image.open(upright) as image:
                g = gray(image)
            guess = top_candidate(result)
            box = guess and guess["box"]
            why = retake.reasons(g, box)
            wasted += read and bool(why)
            missed += not read and not why
            height_px = f"{retake.line_height_px(box, g.shape[0]):.0f}" if box else "–"
            print(
                f"| {photo.name} | {'yes' if read else 'no'} | {rank or '–'} | "
                f"{'yes' if rank == 1 else 'no'} | {height_px} | "
                f"{retake.whole_photo_sharpness(g):.1f} | {', '.join(why) or '–'} |"
            )
    upright.unlink(missing_ok=True)
    (args.folder / ".converted.jpg").unlink(missing_ok=True)
    print(
        f"\n{len(photos)} photos; {wasted} retakes asked for photos that read; "
        f"{missed} photos accepted that did not read."
    )


if __name__ == "__main__":
    main()
