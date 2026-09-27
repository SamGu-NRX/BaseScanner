"""Controlled degradations of a real photo, scaled to the height of its meter-number line.

Levels are fractions of the number's line height h in pixels, so one level means the same
thing on a 3840 px close-up and a 1024 px snapshot. The label box is normalized [x, y, w, h]
with a top-left origin.
"""

import numpy as np
from PIL import Image, ImageFilter
from scipy.ndimage import uniform_filter1d

# Each family: the levels swept, in the unit its function takes.
LEVELS = {
    # Gaussian blur, sigma as a fraction of h (out-of-focus).
    "blur": [0.02, 0.04, 0.06, 0.08, 0.10, 0.13, 0.16, 0.20, 0.25, 0.30],
    # Horizontal motion blur, streak length as a fraction of h (hand shake).
    "motion": [0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.70, 1.0],
    # Downscale the whole photo so the number's line is this many pixels tall.
    "scale": [48, 40, 32, 26, 22, 18, 15, 12, 10, 8, 6],
    # Specular glare: a white Gaussian patch centred on the number, blended in with this peak
    # opacity (values above 1 widen the fully white core).
    "glare": [0.3, 0.5, 0.7, 0.85, 1.0, 1.5, 2.5, 4.0],
    # Framing: crop so the number's right edge sits this many line heights inside the frame
    # (negative values cut into the number).
    "edge": [2.0, 1.0, 0.5, 0.25, 0.1, 0.0, -0.5, -1.0, -2.0],
}


def gaussian_blur(image: Image.Image, box: list[float], fraction: float) -> Image.Image:
    sigma = fraction * box[3] * image.height
    return image.filter(ImageFilter.GaussianBlur(radius=sigma))


def motion_blur(image: Image.Image, box: list[float], fraction: float) -> Image.Image:
    length = max(1, round(fraction * box[3] * image.height))
    pixels = np.asarray(image, dtype=np.float32)
    streaked = uniform_filter1d(pixels, size=length, axis=1, mode="nearest")
    return Image.fromarray(np.clip(streaked + 0.5, 0, 255).astype(np.uint8))


def applicable(family: str, box: list[float], width: int, height: int, level: float) -> bool:
    """Whether a photo of this size can take this level. `apply` skips exactly the rest.

    Downscaling cannot enlarge a number already smaller than the target line height, and an
    edge crop needs room to the right of the number for the requested margin.
    """
    if family == "scale":
        return level < box[3] * height
    if family == "edge":
        right = (box[0] + box[2]) * width + level * box[3] * height
        return box[0] * width < right <= width
    if family in LEVELS:
        return True
    raise ValueError(f"unknown degradation family {family!r}; expected one of {list(LEVELS)}")


def expected_levels(box: list[float], width: int, height: int) -> set[tuple[str, float]]:
    """Every (family, level) the sweep runs on a photo of this size."""
    return {
        (family, level)
        for family, levels in LEVELS.items()
        for level in levels
        if applicable(family, box, width, height, level)
    }


def downscale(image: Image.Image, box: list[float], line_px: float) -> Image.Image | None:
    """None when the photo's number is already smaller than the target."""
    if not applicable("scale", box, image.width, image.height, line_px):
        return None
    scale = line_px / (box[3] * image.height)
    size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
    return image.resize(size, Image.LANCZOS)


def glare(image: Image.Image, box: list[float], strength: float) -> Image.Image:
    """Blend toward white with opacity min(1, strength * gaussian), centred on the box.

    The patch's sigma is 35% of the box width, so at strength 1 the middle of the number
    is fully white and its ends are partly washed out.
    """
    pixels = np.asarray(image, dtype=np.float32)
    height, width = pixels.shape[:2]
    cx = (box[0] + box[2] / 2) * width
    cy = (box[1] + box[3] / 2) * height
    sigma = 0.35 * box[2] * width
    ys, xs = np.ogrid[:height, :width]
    weight = np.exp(-(((xs - cx) ** 2 + (ys - cy) ** 2) / (2 * sigma**2)))
    alpha = np.minimum(1.0, strength * weight)[..., None]
    washed = pixels * (1 - alpha) + 255.0 * alpha
    return Image.fromarray(np.clip(washed + 0.5, 0, 255).astype(np.uint8))


def edge_crop(
    image: Image.Image, box: list[float], margin: float
) -> tuple[Image.Image, list[float]] | None:
    """Crop the right side so the box's right edge sits `margin` line heights from the frame.

    Returns the crop and the box in the crop's normalized coordinates, or None when the photo
    has less room to the right than the requested margin.
    """
    if not applicable("edge", box, image.width, image.height, margin):
        return None
    right = (box[0] + box[2]) * image.width + margin * box[3] * image.height
    cropped = image.crop((0, 0, round(right), image.height))
    new_box = [box[0] * image.width / cropped.width, box[1], 0.0, box[3]]
    new_box[2] = min(1.0, (box[0] + box[2]) * image.width / cropped.width) - new_box[0]
    return cropped, new_box


def apply(family: str, image: Image.Image, box: list[float], level: float):
    """Degraded image and the number's box in its coordinates, or None if not applicable."""
    if family == "blur":
        return gaussian_blur(image, box, level), box
    if family == "motion":
        return motion_blur(image, box, level), box
    if family == "scale":
        scaled = downscale(image, box, level)
        return None if scaled is None else (scaled, box)
    if family == "glare":
        return glare(image, box, level), box
    if family == "edge":
        return edge_crop(image, box, level)
    raise ValueError(f"unknown degradation family {family!r}; expected one of {list(LEVELS)}")
