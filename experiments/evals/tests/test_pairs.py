"""Hand-computed cases for the point-pair metric."""

import numpy as np
import pytest

from evals.pairs import (
    INCH,
    Points,
    evaluate_fixed,
    length_errors,
    pool,
    sample_pairs,
    scale_for_known_distance,
    summarize,
)


def _line_points(xs, pred_scale=1.0, c=None):
    gt = np.array([[x, 0.0, 0.0] for x in xs])
    r = gt * pred_scale
    c = np.zeros_like(gt) if c is None else c
    return Points(gt=gt, c=c, r=r)


def test_sample_pairs_respects_bin():
    gt = np.array([[0.0, 0, 0], [2.0, 0, 0], [5.0, 0, 0], [5.5, 0, 0]])
    rng = np.random.default_rng(1)
    pairs = sample_pairs(gt, 1.0, 3.0, 50, rng)
    d = np.linalg.norm(gt[pairs[:, 0]] - gt[pairs[:, 1]], axis=1)
    assert len(pairs) == 50
    assert np.all((d >= 1.0) & (d < 3.0))
    # Only {0,1} (2 m) and {1,2} (3 m, excluded: upper bound open) qualify, so only 0-1 pairs appear.
    assert set(map(frozenset, pairs.tolist())) == {frozenset({0, 1})}


def test_length_error_of_a_scaled_reconstruction():
    pts = _line_points([0.0, 2.0, 7.0], pred_scale=1.1)
    pairs = np.array([[0, 1], [0, 2]])
    np.testing.assert_allclose(length_errors(pts, pairs), [0.2, 0.7])
    # Rescaled by 1/1.1 the errors vanish.
    np.testing.assert_allclose(length_errors(pts, pairs, s=1 / 1.1), [0.0, 0.0], atol=1e-12)


def test_known_distance_scale_without_centres():
    pts = _line_points([0.0, 2.0], pred_scale=1.25)
    assert scale_for_known_distance(pts, np.array([0, 1])) == pytest.approx(0.8)


def test_known_distance_scale_with_camera_centres():
    # Cameras at x = 0 and x = 3 m see points (1, 0, 2) and (2, 0, 2), 1 m apart, with depth
    # predicted 1.2x too far. Predicted separation along x is |-3 + 2.4 s|, so s = 2/2.4 or 4/2.4
    # both give 1 m; the root nearer 1 (0.833 = 1/1.2) is the right one and is chosen.
    c = np.array([[0.0, 0, 0], [3.0, 0, 0]])
    gt = np.array([[1.0, 0, 2], [2.0, 0, 2]])
    pts = Points(gt=gt, c=c, r=(gt - c) * 1.2)
    s = scale_for_known_distance(pts, np.array([0, 1]))
    assert s == pytest.approx(1 / 1.2)
    np.testing.assert_allclose(pts.predicted(s), gt, atol=1e-12)


def test_known_distance_picks_root_nearer_one_not_smaller():
    # Same cameras, depth predicted 0.6x (too near): roots are 2/1.2 = 1.667 and 4/1.2 = 3.333.
    # "Nearest 1" gives 1.667 (= 1/0.6, correct); "smallest positive" would too, so also check a
    # case where the smaller root is wrong: depth 2.4x too far gives roots 0.417 and 0.833; the
    # true scale 1/2.4 = 0.417 is the smaller one, and nearer-to-1 picks 0.833. That is the
    # documented behaviour: without other evidence the model's own scale is trusted.
    c = np.array([[0.0, 0, 0], [3.0, 0, 0]])
    gt = np.array([[1.0, 0, 2], [2.0, 0, 2]])
    near = Points(gt=gt, c=c, r=(gt - c) * 0.6)
    assert scale_for_known_distance(near, np.array([0, 1])) == pytest.approx(1 / 0.6)
    far = Points(gt=gt, c=c, r=(gt - c) * 2.4)
    assert scale_for_known_distance(far, np.array([0, 1])) == pytest.approx(2 / 2.4)


def test_summarize_in_inches_and_scale_error():
    e = np.array([1, -2, 3, -4, 5], dtype=float) * INCH
    ratios = np.array([1.00, 1.02, 1.04, 1.06, 1.08])
    s = summarize(e, ratios)
    assert s["median_in"] == pytest.approx(3.0)
    assert s["p90_in"] == pytest.approx(4.6)  # numpy linear percentile of [1,2,3,4,5]
    assert s["scale_error_pct"] == pytest.approx(4.0)
    assert s["failed_pct"] == 0.0
    # With 2 of 5 pairs failed the p90 is a failure (infinite), not NaN.
    e2 = np.array([1, 2, 3, np.inf, np.inf]) * INCH
    s2 = summarize(e2)
    assert s2["median_in"] == pytest.approx(3.0)
    assert s2["p90_in"] == float("inf")
    assert s2["failed_pct"] == pytest.approx(40.0)


def test_bilinear_depth_sampling():
    from evals.triangulate import sample_depth as _sample_depth

    # Rows are y, columns are x: d[y, x].
    d = np.array([[1.0, 2.0], [3.0, 4.0], [np.nan, 5.0]])
    uv = np.array([[0.5, 0.5], [0.0, 0.0], [0.25, 1.5], [1.5, 0.0], [0.25, 0.75]])
    out = _sample_depth(d, uv)
    assert out[0] == pytest.approx(2.5)
    assert out[1] == pytest.approx(1.0)
    assert np.isnan(out[2])  # touches the NaN pixel
    assert np.isnan(out[3])  # outside the image
    # x = 0.25 along a row adds 0.25, y = 0.75 down a column adds 1.5: 1 + 0.25 + 1.5.
    assert out[4] == pytest.approx(2.75)


def test_normals_from_depth_plane_cases():
    from evals.frames import normals_from_depth

    K = np.array([[100.0, 0, 20], [0, 100.0, 15], [0, 0, 1]])
    # A wall 5 m straight ahead: normal points back at the camera, (0, 0, -1).
    flat = np.full((31, 41), 5.0)
    n = normals_from_depth(flat, K)
    np.testing.assert_allclose(n[15, 20], [0, 0, -1], atol=1e-9)
    # A wall turned 45 degrees about the vertical axis: z = 5 + x, so the normal is (1, 0, -1)/sqrt2
    # (oriented to the camera). Depth along each pixel ray: z = 5 / (1 - (u - cx) / fx).
    u = np.arange(41, dtype=float)[None, :].repeat(31, axis=0)
    tilted = 5.0 / (1 - (u - 20) / 100.0)
    n = normals_from_depth(tilted, K)
    np.testing.assert_allclose(n[15, 20], np.array([1.0, 0, -1]) / np.sqrt(2), atol=1e-6)
    assert np.isnan(n[0, 0]).all()  # border pixels have no neighbours on both sides


def test_failures_count_against_the_metric():
    # Four points on a line, predicted 10% long; point 3 has no prediction.
    gt = np.array([[0.0, 0, 0], [2.0, 0, 0], [4.0, 0, 0], [6.0, 0, 0]])
    r = gt * 1.1
    r[3] = np.nan
    pts = Points(gt=gt, c=np.zeros_like(gt), r=r)
    pairs = {"1-3m": np.array([[0, 1], [1, 2], [2, 3]])}
    refs = np.array([[0, 1], [2, 3]])  # the second reference touches the missing point
    res = evaluate_fixed(pts, pairs, refs)
    assert res["refs"] == 2 and res["ref_failures"] == 1
    e_none = res["none"]["1-3m"][0]
    np.testing.assert_allclose(e_none[:2], [0.2, 0.2])
    assert np.isinf(e_none[2])
    # Taped: the good reference rescales by 1/1.1 (errors 0, 0, missing); the failed one fails all.
    e_tape = res["one_known_distance"]["1-3m"][0]
    np.testing.assert_allclose(e_tape[:2], [0.0, 0.0], atol=1e-12)
    assert np.isinf(e_tape[2:]).all()
    summary = pool([res])
    assert summary["tape_calibration_success_pct"] == 50.0
    assert summary["one_known_distance"]["1-3m"]["failed_pct"] == pytest.approx(
        100 * 4 / 6, abs=0.01
    )


def test_reference_with_no_positive_scale_fails():
    # Camera centres 5 m apart across the pair's direction: the predicted pair is (2s, 5, 0) apart,
    # at least 5 m for any scale s, so a 2 m tape cannot be matched.
    gt = np.array([[0.0, 0, 0], [2.0, 0, 0]])
    c = np.array([[0.0, 0, 0], [0.0, 5, 0]])
    pts = Points(gt=gt, c=c, r=np.array([[0.0, 0, 0], [2.0, 0, 0]]))
    with pytest.raises(ValueError):
        scale_for_known_distance(pts, np.array([0, 1]))
    res = evaluate_fixed(pts, {"1-3m": np.array([[0, 1]])}, np.array([[0, 1]]))
    assert res["ref_failures"] == 1
