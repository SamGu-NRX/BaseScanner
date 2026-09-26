"""MapAnything (Apache-2.0 checkpoint): N images, optionally with intrinsics and camera poses, to
per-view metric z-depth, intrinsics and camera-to-world poses in one shared metric frame.

All views run jointly in one `model.infer` call, so per-image seconds are the joint time divided by
the number of views. Outputs are metric already: the model predicts a metric scale factor and
applies it (README "Image-Only Inference": `metric_scaling_factor`), and `depth_z` is z-depth in
the OpenCV camera. Poses in and out are OpenCV camera-to-world (README, "Multi-Modal Inference").
The model's output frame is the first view's camera, with or without input poses; with --poses the
outputs are moved into the input poses' world frame.

The model always predicts its own rays. With known intrinsics, `intrinsics` in the npz is the known
set and `intrinsics_predicted` holds what the output rays imply; on the ADVIO smoke run the
predicted fx was 1-3% above the known 1081 px.

Every view must share one network size. By default it is MapAnything's own choice for the mean
aspect ratio (`find_closest_aspect_ratio`, resolution set 518; 1280x720 maps to 518x294). Each
image is scaled uniformly to cover that size and centre-cropped here rather than in
`preprocess_inputs`, so the crop is known exactly; `preprocess_inputs` then receives images already
at the target size and only normalises them. Input pixels the crop removed are invalid.
"""

from __future__ import annotations

import time
from pathlib import Path

import numpy as np

from models.common import (
    ImageResult,
    RunInputs,
    cover_crop_resample,
    depth_to_input,
    intrinsics_to_input,
    intrinsics_to_network,
    load_rgb,
    matrix,
    patch_aligned_size,
    to_network_image,
    vector,
)

REPO = "facebook/map-anything-apache"
FILENAME = "model.safetensors"
REVISION = "00f9c245bbcb60522d1ed7f9e9d88462c6e3f38a"
SHA256 = "fa06c0fdccefc5048e072c85935d5789b1e36b307f3859033c17f9dcb9fd5201"  # LFS sha256 Hugging Face lists for REVISION
CODE = {
    "repo": "https://github.com/facebookresearch/map-anything",
    "commit": "3d10cf7a3016fc0f9bb13a071ee66c47b10be0d9",
}
LICENSE = "Apache-2.0"
RESOLUTION_SET = 518
PATCH = 14


# The two transformer stacks hold 92% of the 1.23 B parameters and run under bf16 autocast. The
# small encoders and heads stay fp32: parts of them run outside autocast and reject bf16 weights.
BF16_MODULES = ("encoder.", "info_sharing.")


def load(device):
    """The model with its transformer weights in bf16, about 2.6 GB instead of 4.9.

    `from_pretrained` builds the 1.2 B-parameter model in fp32 (4.9 GB) and then reads the 4.9 GB
    fp32 checkpoint into it, more than one process may use on the shared machine. Here the model is
    built on the meta device (no memory) and each checkpoint tensor is moved to the device as it is
    read, cast to bf16 if it belongs to `BF16_MODULES`. Those already computed in bf16 under
    autocast, so only their stored weights lose precision.
    """
    import json

    import torch
    from huggingface_hub import hf_hub_download
    from mapanything.models import MapAnything
    from safetensors import safe_open

    config = json.loads(Path(hf_hub_download(REPO, "config.json", revision=REVISION)).read_text())
    # As MapAnything.from_pretrained does: skip DINOv2's own hub weights (4.5 GB of fp32 read and
    # thrown away), since the checkpoint replaces them.
    config["encoder_config"] = {**config["encoder_config"], "torch_hub_pretrained": False}
    with torch.device("meta"):
        model = MapAnything(**config)
    weights = {}
    # Read straight onto the device: CPU copies of fp32 tensors, once freed, stay counted against
    # the process by macOS's allocator.
    with safe_open(
        hf_hub_download(REPO, FILENAME, revision=REVISION), "pt", device=str(device)
    ) as f:
        for i, key in enumerate(f.keys()):
            tensor = f.get_tensor(key)
            if key.startswith(BF16_MODULES):
                tensor = tensor.to(torch.bfloat16)
            weights[key] = tensor
            if str(device).startswith("mps") and i % 50 == 49:
                # Copies to the GPU leave transfer buffers that are freed lazily; without this,
                # loading peaks at 4.4 GB of GPU memory for 2.6 GB of weights.
                torch.mps.synchronize()
                torch.mps.empty_cache()
    # strict=False: the checkpoint stores each shared tensor once (safetensors drops aliases).
    model.load_state_dict(weights, strict=False, assign=True)
    unset = [n for n, t in [*model.named_parameters(), *model.named_buffers()] if t.is_meta]
    if unset:
        raise RuntimeError(
            f"{len(unset)} MapAnything tensors missing from the checkpoint: {unset[:5]}"
        )
    return model.eval()


def network_size(sizes: list[tuple[int, int]], max_side: int | None) -> tuple[int, int]:
    from mapanything.utils.image import find_closest_aspect_ratio

    mean_aspect = sum(w / h for w, h in sizes) / len(sizes)
    if max_side is None:
        return find_closest_aspect_ratio(mean_aspect, RESOLUTION_SET)
    w, h = (
        (max_side, max_side / mean_aspect)
        if mean_aspect >= 1
        else (max_side * mean_aspect, max_side)
    )
    return patch_aligned_size(round(w), round(h), max_side, PATCH)


def run(model, inputs: RunInputs) -> list[ImageResult]:
    import torch
    from mapanything.utils.image import preprocess_inputs

    rgbs = [load_rgb(p) for p in inputs.images]
    net_w, net_h = network_size([(im.shape[1], im.shape[0]) for im in rgbs], inputs.max_side)
    resamples, views = [], []
    for i, rgb in enumerate(rgbs):
        r = cover_crop_resample(rgb.shape[1], rgb.shape[0], net_w, net_h)
        view = {"img": torch.from_numpy(to_network_image(rgb, r))}
        if inputs.intrinsics_mode == "known":
            k_net = intrinsics_to_network(inputs.intrinsics[i], r)
            view["intrinsics"] = torch.from_numpy(matrix(k_net).astype(np.float32))
        if inputs.poses is not None:
            view["camera_poses"] = torch.from_numpy(inputs.poses[i].astype(np.float32))
            view["is_metric_scale"] = torch.tensor([True])
        resamples.append(r)
        views.append(view)
    views = preprocess_inputs(views, resize_mode="fixed_size", size=(net_w, net_h))
    for v, r in zip(views, resamples, strict=True):
        if tuple(v["img"].shape[-2:]) != (r.net_h, r.net_w):
            raise RuntimeError(
                f"preprocess_inputs changed the image size to {tuple(v['img'].shape[-2:])}"
            )

    start = time.perf_counter()
    preds = model.infer(
        views,
        memory_efficient_inference=True,
        minibatch_size=1,
        use_amp=not inputs.fp32,
        amp_dtype="bf16",
        apply_mask=True,
        mask_edges=True,
    )
    unpacked = []
    for pred in preds:
        unpacked.append(
            {
                "depth": pred["depth_z"][0, ..., 0].float().cpu().numpy(),
                "mask": pred["mask"][0, ..., 0].cpu().numpy().astype(bool),
                "K": pred["intrinsics"][0].float().cpu().numpy().astype(np.float64),
                "pose": pred["camera_poses"][0].float().cpu().numpy().astype(np.float64),
                "scale": float(pred["metric_scaling_factor"].reshape(-1)[0]),
            }
        )
    if inputs.device.startswith("mps"):
        torch.mps.synchronize()
    seconds = (time.perf_counter() - start) / len(views)
    del preds
    if inputs.device.startswith("mps"):
        torch.mps.empty_cache()

    results = []
    for i, (path, r, u) in enumerate(zip(inputs.images, resamples, unpacked, strict=True)):
        depth_in, valid_in = depth_to_input(u["depth"], u["mask"], r)
        predicted_k = intrinsics_to_input(vector(u["K"]), r)
        # Output poses are relative to the first view's camera even when poses are given (checked on
        # the ADVIO smoke run: first_pose @ output reproduced the input poses to 2.3 cm and 0.11 deg),
        # so with input poses they are moved back into the caller's world frame.
        pose = inputs.poses[0] @ u["pose"] if inputs.poses is not None else u["pose"]
        known = inputs.intrinsics_mode == "known"
        results.append(
            ImageResult(
                path=path,
                depth=depth_in,
                valid=valid_in,
                intrinsics=inputs.intrinsics[i].copy() if known else predicted_k,
                seconds=seconds,
                resample=r,
                network_wh=(r.net_w, r.net_h),
                cam_to_world=pose,
                arrays={"intrinsics_predicted": predicted_k},
                extra={
                    "metric_scaling_factor": round(u["scale"], 5),
                    "intrinsics_predicted": [round(float(v), 4) for v in predicted_k],
                    "world_frame": "input poses"
                    if inputs.poses is not None
                    else "first image's camera",
                },
            )
        )
    return results
