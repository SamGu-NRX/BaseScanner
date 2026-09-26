import numpy as np
import pytest

from meter_eval import retake

# 200 x 100 image; box x 50-150, y 40-55: a 15 px line, 40 px from the nearest edge.
BOX = [0.25, 0.4, 0.5, 0.15]


def checkerboard(height=100, width=200):
    # Alternating 0/255 pixels: every interior Laplacian is +-1020, so the variance is huge.
    return (np.indices((height, width)).sum(axis=0) % 2) * 255.0


def test_sharp_photo_with_a_clear_number_passes():
    g = checkerboard()
    g[:, :] = np.where(g > 0, 200.0, 0.0)  # no saturated pixels
    assert retake.reasons(g, BOX) == []


def test_flat_photo_is_out_of_focus():
    assert "out of focus" in retake.reasons(np.full((100, 200), 128.0), BOX)


def test_no_number_found_is_its_own_reason():
    assert retake.reasons(np.where(checkerboard() > 0, 200.0, 0.0), None) == ["no number found"]


def test_twelve_pixel_line_is_too_small_and_thirteen_is_not():
    g = np.where(checkerboard() > 0, 200.0, 0.0)
    assert "number too small" in retake.reasons(g, [0.25, 0.4, 0.5, 0.12])
    assert "number too small" not in retake.reasons(g, [0.25, 0.4, 0.5, 0.13])


def test_saturated_label_is_glare():
    g = np.where(checkerboard() > 0, 200.0, 0.0)
    g[38:57, 46:154] = 255.0  # the padded box, entirely white
    assert "glare on the number" in retake.reasons(g, BOX)


def test_box_touching_the_frame_edge_is_cut_off():
    g = np.where(checkerboard() > 0, 200.0, 0.0)
    assert "number touches the frame edge" in retake.reasons(g, [0.5, 0.4, 0.5, 0.15])
    assert retake.edge_gap([0.5, 0.4, 0.5, 0.15], 200, 100) == pytest.approx(0.0)
