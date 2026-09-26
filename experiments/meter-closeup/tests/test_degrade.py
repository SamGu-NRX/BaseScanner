import numpy as np
import pytest
from PIL import Image

from meter_eval.degrade import downscale, edge_crop, glare
from meter_eval.sweep import crop_around, edge_margin

BOX = [0.25, 0.4, 0.5, 0.1]  # on a 200 x 100 image: x 50-150, y 40-50, line height 10 px


def grey_image(width=200, height=100, value=100):
    return Image.fromarray(np.full((height, width, 3), value, dtype=np.uint8))


def test_downscale_hits_the_target_line_height():
    scaled = downscale(grey_image(), BOX, 5)
    assert scaled.size == (100, 50)  # 10 px line -> 5 px is a factor of 0.5


def test_downscale_refuses_to_enlarge():
    assert downscale(grey_image(), BOX, 12) is None


def test_glare_whitens_the_box_centre_and_spares_far_pixels():
    out = np.asarray(glare(grey_image(), BOX, 1.0))
    assert out[45, 100, 0] == 255  # centre: opacity 1
    # Corner (0, 0) is 100 px from the centre along x and 45 along y; sigma is 35 px.
    weight = np.exp(-(100**2 + 45**2) / (2 * 35**2))
    assert out[0, 0, 0] == round(100 * (1 - weight) + 255 * weight)


def test_edge_crop_places_the_right_edge_at_the_margin():
    cropped, box = edge_crop(grey_image(), BOX, 1.0)
    assert cropped.size == (160, 100)  # right edge 150 + 1 line (10 px)
    assert box[0] * 160 == pytest.approx(50)
    assert (box[0] + box[2]) * 160 == pytest.approx(150)


def test_edge_crop_with_negative_margin_cuts_the_box():
    cropped, box = edge_crop(grey_image(), BOX, -2.0)
    assert cropped.size == (130, 100)
    assert box[0] + box[2] == pytest.approx(1.0)


def test_edge_crop_needs_room_in_the_photo():
    assert edge_crop(grey_image(), BOX, 6.0) is None  # 150 + 60 > 200


def test_edge_margin_in_line_heights():
    # Gaps: left 50, top 40, right 50, bottom 50 px; nearest is 40 px = 4 line heights.
    assert edge_margin(BOX, 200, 100) == pytest.approx(4.0)


def test_crop_around_pads_one_line_height():
    x, y, w, h = crop_around(BOX, 200, 100)
    assert (x * 200, y * 100, w * 200, h * 100) == pytest.approx((40, 30, 120, 30))
