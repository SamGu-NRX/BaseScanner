"""Depth Anything 3 metric (DA3METRIC-LARGE): one image plus its focal length to metric depth.

The network predicts depth for a canonical camera. The repository's rule for metres
(README.md:235 at the pinned commit) is `metric_depth = focal * net_output / 300`, with `focal` the
mean of fx and fy in pixels. Its own code applies it with the intrinsics of the image the network
saw, after resizing (`apply_metric_scaling`, src/depth_anything_3/utils/alignment.py:118-133, called
from model/da3.py:379 with the processed-resolution intrinsics). So the focal here is the known focal
scaled to the network image. The model predicts no intrinsics, so it needs known ones.

Sky pixels are invalid. The model marks non-sky as `sky < 0.3` (model/da3.py:161) and fills sky
with the 99th-percentile depth, so those depths are not measurements.

The network is built from the package's own config and weights rather than through
`depth_anything_3.api`, which imports export code (pycolmap, evo, moviepy) at module load.
Preprocessing is the package's `InputProcessor` with its default `upper_bound_resize`: the whole
image is resized, longest side 504 unless --max-side is given, each side rounded to a multiple of
14; nothing is cropped.
"""

from __future__ import annotations

import time
from collections.abc import Iterator

import numpy as np

from models.common import (
    ImageResult,
    RunInputs,
    depth_to_input,
    load_rgb,
    matrix,
    stretch_resample,
)

REPO = "depth-anything/DA3METRIC-LARGE"
FILENAME = "model.safetensors"
REVISION = "4010e39f3634a45bc60553321fb49fb760bd594e"
SHA256 = "bbea5b0b3ee389849cffa7ddae89de064a90abd2b055fc5aa99aac68db324776"  # LFS sha256 Hugging Face lists for REVISION
CODE = {
    "repo": "https://github.com/ByteDance-Seed/Depth-Anything-3",
    "commit": "3d835ec1a5802d64a8b8b15f817a1ab54809bfe4",
}
LICENSE = "Apache-2.0"
CANONICAL_FOCAL_PX = 300.0
DEFAULT_PROCESS_RES = 504
NON_SKY_BELOW = 0.3


def load(device):
    import torch
    from depth_anything_3.cfg import create_object, load_config
    from depth_anything_3.registry import MODEL_REGISTRY
    from huggingface_hub import hf_hub_download
    from safetensors.torch import load_file

    net = create_object(load_config(MODEL_REGISTRY["da3metric-large"]))
    weights = load_file(hf_hub_download(REPO, FILENAME, revision=REVISION))
    # The checkpoint is saved from the `DepthAnything3` wrapper, which holds the network as `.model`.
    prefix = "model."
    if not all(k.startswith(prefix) for k in weights):
        raise RuntimeError(f"{REPO}: expected every weight key to start with {prefix!r}")
    net.load_state_dict({k[len(prefix) :]: v for k, v in weights.items()}, strict=True)
    net.eval()
    return net.to(device=torch.device(device))


def run(net, inputs: RunInputs) -> Iterator[ImageResult]:
    import torch
    from depth_anything_3.utils.io.input_processor import InputProcessor

    if inputs.intrinsics_mode != "known":
        raise ValueError(
            "da3metric needs known intrinsics: metres = focal * output / 300 and the model does not "
            "predict a focal. Pass --intrinsics."
        )
    processor = InputProcessor()
    process_res = inputs.max_side or DEFAULT_PROCESS_RES
    device = next(net.parameters()).device
    for i, path in enumerate(inputs.images):
        rgb = load_rgb(path)
        h, w = rgb.shape[:2]
        k = inputs.intrinsics[i]
        batch, _, k_proc = processor(
            [rgb],
            intrinsics=matrix(k)[None].astype(np.float32),
            process_res=process_res,
            process_res_method="upper_bound_resize",
            num_workers=1,
        )
        net_h, net_w = batch.shape[-2:]
        r = stretch_resample(w, h, net_w, net_h)
        focal_net = (k[0] * r.sx + k[1] * r.sy) / 2
        focal_theirs = float((k_proc[0, 0, 0] + k_proc[0, 1, 1]) / 2)
        if abs(focal_net - focal_theirs) > 1e-3 * focal_net:
            raise RuntimeError(
                f"{path.name}: focal at network size {focal_net} != InputProcessor's {focal_theirs}"
            )

        start = time.perf_counter()
        x = batch[None].to(device)  # (1, N=1, 3, H, W)
        # Same autocast as DepthAnything3.forward (api.py): fp16 unless CUDA has bf16. The depth
        # head runs in fp32 inside the network regardless.
        with (
            torch.inference_mode(),
            torch.autocast(device_type=device.type, dtype=torch.float16, enabled=not inputs.fp32),
        ):
            out = net(x, None, None, export_feat_layers=[])
        raw = out["depth"].float().reshape(net_h, net_w).cpu().numpy()
        sky = out["sky"].float().reshape(net_h, net_w).cpu().numpy()
        if device.type == "mps":
            torch.mps.synchronize()
        seconds = time.perf_counter() - start

        metric = (raw * (focal_net / CANONICAL_FOCAL_PX)).astype(np.float32)
        non_sky = sky < NON_SKY_BELOW
        depth_in, valid_in = depth_to_input(metric, non_sky, r)
        yield ImageResult(
            path=path,
            depth=depth_in,
            valid=valid_in,
            intrinsics=k.copy(),
            seconds=seconds,
            resample=r,
            network_wh=(net_w, net_h),
            extra={
                "focal_network_px": round(focal_net, 3),
                "sky_fraction": round(float(1 - non_sky.mean()), 4),
            },
        )
        del out, x
        if device.type == "mps":
            torch.mps.empty_cache()
