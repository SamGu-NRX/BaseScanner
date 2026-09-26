import numpy as np
import pytest

from meter_eval.match import (
    class_read,
    digest,
    lenient_digest,
    normalize,
    number_boxes,
    number_read,
    rows_of_text,
)
from meter_eval.quality import (
    crop_box,
    laplacian_variance,
    rms_contrast,
    saturated_fraction,
)
from meter_eval.stats import auc, wilson


def line(text, x, y, w=0.1, h=0.05):
    return {"text": text, "box": [x, y, w, h]}


# --- quality -----------------------------------------------------------------------------


def test_laplacian_variance_of_flat_image_is_zero():
    assert laplacian_variance(np.full((5, 5), 128.0)) == 0.0


def test_laplacian_variance_of_single_bright_pixel():
    # 5x5 zeros with one 1 in the centre; interior is the 3x3 block around it.
    # Laplacian there: centre -4, its four neighbours 1, four corners 0.
    # mean = 0, variance = (16 + 4) / 9.
    g = np.zeros((5, 5))
    g[2, 2] = 1.0
    assert laplacian_variance(g) == pytest.approx(20 / 9)


def test_laplacian_variance_of_linear_ramp_is_zero():
    g = np.tile(np.arange(6, dtype=float) * 10, (6, 1))
    assert laplacian_variance(g) == 0.0


def test_saturated_fraction_counts_pixels_at_or_above_level():
    g = np.array([[249.0, 250.0], [255.0, 0.0]])
    assert saturated_fraction(g) == 0.5


def test_rms_contrast_of_half_black_half_white():
    g = np.array([[0.0, 255.0], [0.0, 255.0]])
    assert rms_contrast(g) == pytest.approx(0.5)


def test_crop_box_pads_by_box_height():
    g = np.arange(100 * 100, dtype=float).reshape(100, 100)
    region = crop_box(g, [0.4, 0.4, 0.2, 0.1], pad=0.5)
    # 0.5 box heights = 0.05 of image height = 5 px on every side (square image).
    assert region.shape == (20, 30)
    assert region[0, 0] == g[35, 35]


# --- matching ----------------------------------------------------------------------------


def test_normalize_drops_everything_but_letters_and_digits():
    assert normalize("No. 12-345 678") == "NO12345678"


def test_number_found_inside_a_longer_line():
    lines = [line("ND. 1234567", 0.3, 0.6)]
    assert number_read(lines, digest("1234567"), 7, lenient=False)


def test_number_with_one_wrong_digit_is_not_read():
    lines = [line("ND. 1234563", 0.3, 0.6)]
    assert not number_read(lines, digest("1234567"), 7, lenient=False)


def test_number_split_across_two_boxes_on_one_row_is_joined():
    lines = [line("5678", 0.5, 0.52), line("123", 0.3, 0.5)]
    joined = dict(rows_of_text(lines))
    assert joined["123 5678"] == [[0.3, 0.5, 0.1, 0.05], [0.5, 0.52, 0.1, 0.05]]
    assert number_boxes(lines, digest("1235678"), 7, lenient=False) == joined["123 5678"]


def test_boxes_on_different_rows_are_not_joined():
    lines = [line("123", 0.3, 0.1), line("5678", 0.5, 0.5)]
    assert not number_read(lines, digest("1235678"), 7, lenient=False)


def test_lenient_mode_accepts_letter_o_for_zero():
    lines = [line("4O71I2", 0.3, 0.5)]
    assert not number_read(lines, digest("407112"), 6, lenient=False)
    assert number_read(lines, lenient_digest("407112"), 6, lenient=True)


def test_class_label_ignores_spacing_and_case():
    assert class_read([line("cl 200  240V", 0.1, 0.1)], "CL200")
    assert not class_read([line("CL20O", 0.1, 0.1)], "CL200")


def test_iec_rating_keeps_parentheses():
    assert class_read([line("10 (60) A", 0.1, 0.1)], "10(60)A")
    assert not class_read([line("1060A", 0.1, 0.1)], "10(60)A")


def test_rating_ignores_separators_and_reads_times_sign_as_x():
    assert class_read([line("20(60)/A", 0.1, 0.1)], "20(60)A")
    assert class_read([line("0.1,-10 AMP", 0.1, 0.1)], "0.1-10 AMP")
    assert class_read([line("3×25", 0.1, 0.1)], "3x25")


# --- stats -------------------------------------------------------------------------------


def test_wilson_interval_for_8_of_10():
    low, high = wilson(8, 10)
    assert low == pytest.approx(0.4902, abs=1e-4)
    assert high == pytest.approx(0.9433, abs=1e-4)


def test_auc_perfect_and_tied():
    assert auc([3, 2, 1, 0], [True, True, False, False]) == 1.0
    assert auc([1, 1], [True, False]) == 0.5


def test_digest_is_hmac_sha256_with_the_key():
    # RFC 4231-style check: HMAC-SHA256 of "1234567" under 32 zero bytes, computed with
    # Python's hmac module independently of meter_eval.
    import hashlib
    import hmac

    expected = hmac.new(bytes(32), b"1234567", hashlib.sha256).hexdigest()
    assert digest("1234567") == expected
    assert digest("1234567") != hashlib.sha256(b"1234567").hexdigest()
