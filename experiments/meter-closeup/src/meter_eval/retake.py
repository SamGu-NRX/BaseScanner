"""The retake checks the app should port: the ones that survive without knowing the answer.

The phone cannot know where the true number is, so every check here uses either the whole
photo or the number-finding ranking's top candidate (locate.top_candidate). Checks measured
on the true number's box (results/sweep.md, "label" rows) are not ported: on the top candidate
the glare check has an AUC of 0.55 and the framing check 0.61, because a washed-out or cut
number usually stops being the top candidate.

Every check runs on the full-resolution photo after EXIF rotation, converted to 8-bit luma
(L = 0.299 R + 0.587 G + 0.114 B, as PIL's "L" mode). `box` is normalized [x, y, w, h] with
a top-left origin, as meterocr returns Vision's boxes. Each threshold is the value at or below
which 95% of the 71 swept photos had stopped reading; see results/sweep.md, "Retake
thresholds from each photo's break point".
"""

import numpy as np

from meter_eval.quality import downscale_long_side, laplacian_variance

# results/sweep.md, blur, "whole-photo sharpness at up to 1024 px", 95% column. AUC 0.96;
# rejects 0 of 75 good photos, whose lowest score is 58.7 (weak evidence: none is near 6.63).
MIN_SHARPNESS = 6.63
# results/sweep.md, scale, "top-candidate line height in pixels", 95% column. AUC 0.86;
# rejects 2 of 75 good photos. On the true number's box the cut would be 12 px; the top
# candidate likely needs more because once the number is too small, a larger line takes
# its place.
MIN_TOP_LINE_PX = 33.9


def line_height_px(box: list[float], image_height: int) -> float:
    return box[3] * image_height


def whole_photo_sharpness(g: np.ndarray) -> float:
    """Laplacian variance of the luma image shrunk to a 1024 px long side (bilinear,
    antialiased). Photos already that small are used as they are."""
    return laplacian_variance(downscale_long_side(g, 1024))


def reasons(g: np.ndarray, top_box: list[float] | None) -> list[str]:
    """Why the app should ask for a retake; empty when the photo passes every check."""
    found = []
    if whole_photo_sharpness(g) <= MIN_SHARPNESS:
        found.append("out of focus")
    if top_box is None:
        found.append("no number found")
    elif line_height_px(top_box, g.shape[0]) <= MIN_TOP_LINE_PX:
        found.append("number too small")
    return found
