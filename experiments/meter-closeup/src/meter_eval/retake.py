"""The retake checks the app should port, with the thresholds this experiment measured.

Every check runs on the full-resolution photo after EXIF rotation, converted to 8-bit luma
(L = 0.299 R + 0.587 G + 0.114 B, as PIL's "L" mode). `box` is the number's line as Vision
returns it, normalized [x, y, w, h] with a top-left origin. Each threshold is the value at or
below (or above) which 95% of the 71 swept photos had stopped reading; see
results/sweep.md, "Retake thresholds from each photo's break point".
"""

import numpy as np

from meter_eval.quality import crop_box, downscale_long_side, laplacian_variance, saturated_fraction

# results/sweep.md, scale: label line height, 95% column. 15 px read on 96% of photos.
MIN_LINE_PX = 12.0
# results/sweep.md, blur: whole-photo sharpness at 1024 px, 95% column; rejected 0 of 75 good
# photos (same file, last table).
MIN_SHARPNESS = 6.63
# results/sweep.md, glare: label share of pixels >= 250, 95% column; rejected 2 of 75.
MAX_SATURATED = 0.0729
# results/sweep.md, edge: label gap to the frame edge. A box touching the edge cannot show
# whether digits continue past it.
MIN_EDGE_GAP = 0.0


def line_height_px(box: list[float], image_height: int) -> float:
    return box[3] * image_height


def whole_photo_sharpness(g: np.ndarray) -> float:
    """Laplacian variance of the luma image resized to a 1024 px long side (bilinear)."""
    return laplacian_variance(downscale_long_side(g, 1024))


def label_saturated(g: np.ndarray, box: list[float]) -> float:
    """Share of luma >= 250 in the box padded by 0.25 line heights on every side."""
    return saturated_fraction(crop_box(g, box, pad=0.25))


def edge_gap(box: list[float], width: int, height: int) -> float:
    """Distance from the box to the nearest frame edge, in line heights."""
    line = box[3] * height
    gaps = [
        box[0] * width,
        box[1] * height,
        (1 - box[0] - box[2]) * width,
        (1 - box[1] - box[3]) * height,
    ]
    return min(gaps) / line


def reasons(g: np.ndarray, box: list[float] | None) -> list[str]:
    """Why the app should ask for a retake; empty when the photo passes every check."""
    height, width = g.shape
    found = []
    if whole_photo_sharpness(g) <= MIN_SHARPNESS:
        found.append("out of focus")
    if box is None:
        return found + ["no number found"]
    if line_height_px(box, height) <= MIN_LINE_PX:
        found.append("number too small")
    if label_saturated(g, box) >= MAX_SATURATED:
        found.append("glare on the number")
    if edge_gap(box, width, height) <= MIN_EDGE_GAP:
        found.append("number touches the frame edge")
    return found
