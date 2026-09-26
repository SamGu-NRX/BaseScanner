import numpy as np
import pytest

from meter_eval import retake

# 200 x 100 image; box 40 px tall (0.4 of the height).
BOX = [0.25, 0.3, 0.5, 0.4]


def sharp():
    # Alternating 0/200 pixels: every interior Laplacian is +-800, far above any threshold.
    return (np.indices((100, 200)).sum(axis=0) % 2) * 200.0


def test_sharp_photo_with_a_tall_top_candidate_passes():
    assert retake.reasons(sharp(), BOX) == []


def test_flat_photo_is_out_of_focus():
    assert "out of focus" in retake.reasons(np.full((100, 200), 128.0), BOX)


def test_no_candidate_is_its_own_reason():
    assert retake.reasons(sharp(), None) == ["no number found"]


def test_top_candidate_below_the_threshold_is_too_small():
    # 33 px is under the 33.9 px threshold; 35 px is over it.
    assert "number too small" in retake.reasons(sharp(), [0.25, 0.3, 0.5, 0.33])
    assert "number too small" not in retake.reasons(sharp(), [0.25, 0.3, 0.5, 0.35])


def sine_rows(period: int, width: int, height: int):
    x = np.arange(width)
    return np.tile(128 + 100 * np.sin(2 * np.pi * x / period), (height, 1))


def test_whole_photo_sharpness_leaves_small_photos_at_their_size():
    # Below 1024 px nothing is resized. For a sine of amplitude A and period P the Laplacian
    # variance is (2(cos(2pi/P) - 1))^2 * A^2 / 2, about 115.9 at P = 16.
    assert retake.whole_photo_sharpness(sine_rows(16, 1024, 768)) == pytest.approx(115.9, rel=0.01)


def test_whole_photo_sharpness_after_halving_is_pinned():
    # A 2048 px photo is halved, turning 32 px stripes into 16 px ones. The antialiasing
    # filter softens them slightly, so the value lands a little under 115.9. This pins the
    # implementation (PIL bilinear on a float image); a port should land within about 2%.
    assert retake.whole_photo_sharpness(sine_rows(32, 2048, 1536)) == pytest.approx(
        112.68, rel=1e-3
    )
