"""The input <-> network image geometry has one right answer, so it is tested on synthetic cameras."""

from __future__ import annotations

import json

import numpy as np
import pytest

from models.common import (
    cover_crop_resample,
    depth_to_input,
    identity_resample,
    intrinsics_to_input,
    intrinsics_to_network,
    longest_side_resample,
    patch_aligned_size,
    read_intrinsics,
    stretch_resample,
    to_network_image,
)

K = np.array([1082.1, 1081.1, 640.79, 359.41])  # OpenCV pixels of a 1280x720 image


def project(k: np.ndarray, points: np.ndarray) -> np.ndarray:
    return np.stack(
        [k[0] * points[:, 0] / points[:, 2] + k[2], k[1] * points[:, 1] / points[:, 2] + k[3]],
        axis=1,
    )


@pytest.mark.parametrize(
    "r",
    [
        cover_crop_resample(1280, 720, 518, 294),
        stretch_resample(1280, 720, 504, 280),
        longest_side_resample(1280, 720, 1000),
    ],
)
def test_network_intrinsics_project_like_the_resampled_image(r):
    rng = np.random.default_rng(0)
    points = np.column_stack(
        [rng.uniform(-3, 3, 50), rng.uniform(-2, 2, 50), rng.uniform(2, 20, 50)]
    )
    uv_in = project(K, points)
    uv_net_expected = np.column_stack(
        [r.sx * (uv_in[:, 0] + 0.5) - r.x0 - 0.5, r.sy * (uv_in[:, 1] + 0.5) - r.y0 - 0.5]
    )
    np.testing.assert_allclose(
        project(intrinsics_to_network(K, r), points), uv_net_expected, atol=1e-9
    )
    np.testing.assert_allclose(intrinsics_to_input(intrinsics_to_network(K, r), r), K, atol=1e-9)


def test_cover_crop_for_16_9_into_518x294():
    r = cover_crop_resample(1280, 720, 518, 294)
    assert (r.resized_w, r.resized_h, r.x0, r.y0) == (523, 294, 2, 0)
    image = np.zeros((720, 1280, 3), np.uint8)
    assert to_network_image(image, r).shape == (294, 518, 3)


def test_patch_aligned_size():
    assert patch_aligned_size(6048, 4032, 518, 14) == (518, 350)


def test_constant_depth_survives_resampling_and_crop_is_invalid():
    r = cover_crop_resample(1280, 720, 518, 294)
    depth, valid = depth_to_input(
        np.full((294, 518), 4.0, np.float32), np.ones((294, 518), bool), r
    )
    assert depth.shape == (720, 1280) and depth.dtype == np.float32
    np.testing.assert_allclose(depth[valid], 4.0, rtol=1e-6)
    # The crop removed 2 resized columns on the left and 3 on the right. Input column c lies at
    # 523/1280 * (c + 0.5) - 2.5 in the network image, inside [-0.5, 517.5] for c = 5 ... 1272.
    assert not valid[:, :5].any()
    assert valid[:, 5:1273].all()
    assert not valid[:, 1273:].any()
    assert np.isnan(depth[~valid]).all()


def test_depth_is_interpolated_linearly_and_invalid_neighbours_propagate():
    r = stretch_resample(1280, 720, 640, 360)
    u = np.arange(640, dtype=np.float32)
    ramp = np.broadcast_to(1.0 + 0.01 * u, (360, 640)).astype(np.float32)
    valid_net = np.ones((360, 640), bool)
    valid_net[100, 300] = False
    depth, valid = depth_to_input(ramp, valid_net, r)
    # Input column c sits at network column (c + 0.5) / 2 - 0.5.
    cols = np.arange(10, 1270)
    expected = 1.0 + 0.01 * ((cols + 0.5) / 2 - 0.5)
    np.testing.assert_allclose(depth[400, cols], expected, atol=1e-3)
    # Every input pixel that interpolates from network pixel (row 100, col 300) is invalid.
    assert not valid[199:203, 599:603].any()
    assert valid[195, 590] and valid[210, 610]


def test_identity_resample_keeps_values():
    r = identity_resample(8, 4)
    d = np.arange(32, dtype=np.float32).reshape(4, 8) + 1
    depth, valid = depth_to_input(d, np.ones((4, 8), bool), r)
    np.testing.assert_array_equal(depth, d)
    assert valid.all()


def test_intrinsics_json_must_cover_every_image(tmp_path):
    images = []
    for name in ("a.jpg", "b.jpg"):
        (tmp_path / name).write_bytes(b"")
        images.append(tmp_path / name)
    path = tmp_path / "k.json"
    path.write_text(json.dumps({"a": [1, 1, 0, 0]}))
    with pytest.raises(ValueError, match=r"no intrinsics keyed by path or stem for images \['b'\]"):
        read_intrinsics(path, images)
    path.write_text(json.dumps({str(images[0]): [1, 1, 0, 0], "b": [2, 2, 0, 0]}))
    assert [k[0] for k in read_intrinsics(path, images)] == [1, 2]
    path.write_text(json.dumps([[1, 1, 0, 0]]))
    with pytest.raises(ValueError, match="1 intrinsics entries for 2 images"):
        read_intrinsics(path, images)
