"""Cheap photo checks a phone could run on a close-up before accepting it.

Images are grayscale float arrays of 0-255 values; boxes are normalized [x, y, w, h] with a
top-left origin, as meterocr returns them.
"""

import numpy as np
from PIL import Image

SATURATED = 250


def gray(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("L"), dtype=np.float64)


def laplacian_variance(g: np.ndarray) -> float:
    """Variance of the 4-neighbour Laplacian over interior pixels (OpenCV's usual blur score)."""
    if g.shape[0] < 3 or g.shape[1] < 3:
        return 0.0
    lap = g[:-2, 1:-1] + g[2:, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:] - 4 * g[1:-1, 1:-1]
    return float(lap.var())


def saturated_fraction(g: np.ndarray, level: int = SATURATED) -> float:
    return float((g >= level).mean()) if g.size else 0.0


def rms_contrast(g: np.ndarray) -> float:
    return float(g.std() / 255.0) if g.size else 0.0


def crop_box(g: np.ndarray, box: list[float], pad: float = 0.0) -> np.ndarray:
    """Crop a normalized top-left-origin [x, y, w, h] box, padded by `pad` box heights."""
    height, width = g.shape
    x, y, w, h = box
    margin = pad * h
    x0 = round(max(0.0, x - margin * height / width) * width)
    x1 = round(min(1.0, x + w + margin * height / width) * width)
    y0 = round(max(0.0, y - margin) * height)
    y1 = round(min(1.0, y + h + margin) * height)
    return g[y0:y1, x0:x1]


def union_box(boxes: list[list[float]]) -> list[float]:
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    return [x0, y0, x1 - x0, y1 - y0]


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


def region_checks(g: np.ndarray, box: list[float]) -> dict[str, float]:
    """Checks on a text box: its height in pixels, and sharpness, glare and contrast inside it.

    lap_var_32 measures sharpness after resizing the box so its line is 32 px tall, which
    makes one threshold usable for labels photographed at any size.
    """
    region = crop_box(g, box, pad=0.25)
    return {
        "text_height_px": box[3] * g.shape[0],
        "lap_var": laplacian_variance(region),
        "lap_var_32": laplacian_variance(resample_to_height(g, box, 32)),
        "saturated": saturated_fraction(region),
        "contrast": rms_contrast(region),
    }


def resample_to_height(g: np.ndarray, box: list[float], text_height: int) -> np.ndarray:
    """The padded box region, resized so the text line is `text_height` pixels tall."""
    region = crop_box(g, box, pad=0.25)
    line_px = box[3] * g.shape[0]
    if region.size == 0 or line_px <= 0:
        return region
    scale = text_height / line_px
    size = (max(1, round(region.shape[1] * scale)), max(1, round(region.shape[0] * scale)))
    resized = Image.fromarray(region.astype(np.float32), mode="F").resize(size, Image.BILINEAR)
    return np.asarray(resized, dtype=np.float64)


def digit_lines(lines: list[dict], min_digits: int = 4) -> list[dict]:
    return [line for line in lines if sum(ch.isdigit() for ch in line["text"]) >= min_digits]


def tallest_digit_line(lines: list[dict]) -> dict | None:
    """The phone's guess at the meter number: the tallest line with at least 4 digits."""
    return max(digit_lines(lines), key=lambda line: line["box"][3], default=None)


def device_checks(g: np.ndarray, box: list[float] | None) -> dict[str, float]:
    """Checks a phone can compute without knowing the answer.

    `box` is the phone's guess at the number's line, the number-finding ranking's top
    candidate (locate.top_candidate). With no candidate the region checks are absent, which
    the analysis scores as the worst value: the app should treat that photo as failed.
    """
    checks = {
        "global_lap_var": laplacian_variance(downscale_long_side(g, 1024)),
        "global_saturated": saturated_fraction(g),
    }
    if box is None:
        return checks
    height, width = g.shape
    return checks | region_checks(g, box) | {"edge_margin": edge_gap(box, width, height)}


def downscale_long_side(g: np.ndarray, long_side: int) -> np.ndarray:
    """Shrink so the long side is `long_side` pixels (bilinear, antialiased); never enlarge."""
    scale = long_side / max(g.shape)
    if scale >= 1:
        return g
    size = (round(g.shape[1] * scale), round(g.shape[0] * scale))
    return np.asarray(Image.fromarray(g.astype(np.float32), mode="F").resize(size, Image.BILINEAR))
