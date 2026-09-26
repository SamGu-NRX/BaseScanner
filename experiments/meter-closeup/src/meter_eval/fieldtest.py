"""Score a folder of real close-ups against the retake checks and the number finder.

    uv run python -m meter_eval.fieldtest PHOTO_DIR --number "12 345 678"

For each photo: whether Vision read the number, whether the number-finding ranking put it
first or in the top three, each check's value, and whether the checks would have asked for a
retake. The summary counts the two costly outcomes: a retake asked for a photo that read
(a wasted retake) and a photo accepted that did not read (a re-request later). The meter
number is taken from the command line and is never written to disk.
"""

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageOps

from meter_eval import retake
from meter_eval.locate import candidates, ranked
from meter_eval.match import core, digest, normalize, number_boxes
from meter_eval.ocr import Reader
from meter_eval.quality import gray, union_box

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
    print("| Photo | Read | Rank | Line px | Sharpness | Saturated | Edge gap | Retake because |")
    print("|---|---|---|---|---|---|---|---|")
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
            boxes = number_boxes(result["lines"], target, length, lenient=False)
            order = ranked(candidates(result))
            rank = next((i + 1 for i, c in enumerate(order) if digest(c) == target_core), None)
            with Image.open(upright) as image:
                g = gray(image)
            box = union_box(boxes) if boxes else None
            why = retake.reasons(g, box)
            read = boxes is not None
            wasted += read and bool(why)
            missed += not read and not why
            cells = ["–", "–", "–"]
            if box:
                height, width = g.shape
                cells = [
                    f"{retake.line_height_px(box, height):.0f}",
                    f"{retake.label_saturated(g, box):.3f}",
                    f"{retake.edge_gap(box, width, height):.2f}",
                ]
            print(
                f"| {photo.name} | {'yes' if read else 'no'} | {rank or '–'} | {cells[0]} | "
                f"{retake.whole_photo_sharpness(g):.1f} | {cells[1]} | {cells[2]} | "
                f"{', '.join(why) or '–'} |"
            )
    upright.unlink(missing_ok=True)
    (args.folder / ".converted.jpg").unlink(missing_ok=True)
    print(
        f"\n{len(photos)} photos; {wasted} retakes asked for photos that read; "
        f"{missed} photos accepted that did not read."
    )


if __name__ == "__main__":
    main()
