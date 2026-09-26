"""Cheap photo checks a phone could run on a close-up before accepting it.

All take a grayscale image as a float array of 0-255 values.
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


def region_checks(g: np.ndarray, box: list[float]) -> dict[str, float]:
    """Checks on a text box: its height in pixels, and sharpness, glare and contrast inside it."""
    region = crop_box(g, box, pad=0.25)
    return {
        "text_height_px": box[3] * g.shape[0],
        "lap_var": laplacian_variance(region),
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


def device_checks(g: np.ndarray, lines: list[dict]) -> dict[str, float]:
    """Checks a phone can compute without knowing the answer.

    The candidate label is the tallest recognized line holding at least 4 digits, which is
    how the app would find a meter number before reading it. With no such line every
    region check is 0, which the app should treat as a failed photo.
    """
    candidates = digit_lines(lines)
    checks = {
        "digit_lines": float(len(candidates)),
        "global_lap_var": laplacian_variance(downscale_long_side(g, 1024)),
        "global_saturated": saturated_fraction(g),
    }
    if not candidates:
        return checks | {
            "text_height_px": 0.0,
            "lap_var": 0.0,
            "lap_var_32": 0.0,
            "saturated": 0.0,
            "contrast": 0.0,
            "confidence": 0.0,
        }
    tallest = max(candidates, key=lambda line: line["box"][3])
    return (
        checks
        | region_checks(g, tallest["box"])
        | {
            "lap_var_32": laplacian_variance(resample_to_height(g, tallest["box"], 32)),
            "confidence": float(tallest["confidence"]),
        }
    )


def downscale_long_side(g: np.ndarray, long_side: int) -> np.ndarray:
    scale = long_side / max(g.shape)
    if scale >= 1:
        return g
    size = (round(g.shape[1] * scale), round(g.shape[0] * scale))
    return np.asarray(Image.fromarray(g.astype(np.float32), mode="F").resize(size, Image.BILINEAR))
