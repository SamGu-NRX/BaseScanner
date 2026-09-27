"""OWLv2 (google/owlv2-base-patch16-ensemble, Apache-2.0) zero-shot detection through the ONNX
fp16 export in Xenova/owlv2-base-patch16-ensemble, on onnxruntime's CPU provider.

onnxruntime's CPU provider runs this graph at 7 to 27 s an image on this shared Mac (fp16, or
upcast to fp32 in memory), and its Core ML provider fails to compile it. So the bulk runs load the
same ONNX weights into transformers' Owlv2ForObjectDetection on the GPU (MPS): named weights copy
across, and each unnamed MatMul weight takes the module path of the node that consumes it,
transposed. The export omits the objectness head, visual projection and logit scale, none of which
feed the text-query logits or boxes. `parity` checks the two runtimes agree on one image.

Preprocessing follows transformers' Owlv2ImageProcessor: scale to [0, 1], pad bottom and right
with zeros to a square, resize to 960 x 960, normalize with CLIP's mean and std. Predicted boxes
are (cx, cy, w, h) relative to the padded square. Queries are the fixed list in config.

Usage: python -m autodetect.owl [set ...]    # default: every set, on MPS
       python -m autodetect.owl parity <image>
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

from . import config
from .nms import postprocess
from .paths import WEIGHTS
from .sets import SETS, ground_truth, image_path, save_preds

DIR = WEIGHTS / "owlv2"
MODEL = DIR / "model_fp16.onnx"
URL = "https://huggingface.co/Xenova/owlv2-base-patch16-ensemble/resolve/main/onnx/model_fp16.onnx"
SIZE = 960
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)
MAX_TOKENS = 16  # OWLv2's text position embeddings


def upcast_fp16(path: Path) -> bytes:
    """Serialized copy of an fp16 ONNX graph with every fp16 tensor and cast turned into fp32."""
    import onnx
    from onnx import TensorProto, numpy_helper

    m = onnx.load(str(path))
    g = m.graph

    def up(t: TensorProto) -> TensorProto:
        return numpy_helper.from_array(numpy_helper.to_array(t).astype(np.float32), t.name)

    for k, t in enumerate(g.initializer):
        if t.data_type == TensorProto.FLOAT16:
            g.initializer[k].CopyFrom(up(t))
    for n in g.node:
        for a in n.attribute:
            if a.type == onnx.AttributeProto.TENSOR and a.t.data_type == TensorProto.FLOAT16:
                a.t.CopyFrom(up(a.t))
            if n.op_type == "Cast" and a.name == "to" and a.i == TensorProto.FLOAT16:
                a.i = TensorProto.FLOAT
    for v in list(g.value_info) + list(g.input) + list(g.output):
        if v.type.tensor_type.elem_type == TensorProto.FLOAT16:
            v.type.tensor_type.elem_type = TensorProto.FLOAT
    return m.SerializeToString()


def torch_model(device: str):
    """transformers OWLv2 carrying the ONNX export's weights, in fp32, in eval mode."""
    import onnx
    import torch
    from onnx import numpy_helper
    from transformers import Owlv2Config, Owlv2ForObjectDetection

    m = onnx.load(str(MODEL))
    weights = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}
    by_node = {}
    for n in m.graph.node:
        if n.op_type == "MatMul":
            for x in n.input:
                if x.startswith("onnx::") and x in weights:
                    by_node[n.name.strip("/").rsplit("/", 1)[0].replace("/", ".") + ".weight"] = weights[x].T
    del m
    model = Owlv2ForObjectDetection(Owlv2Config.from_pretrained(str(DIR)))
    sd = model.state_dict()
    unused = {"owlv2.logit_scale", "owlv2.visual_projection.weight"} | {k for k in sd if k.startswith("objectness_head.")}
    loaded = {}
    for k, v in sd.items():
        src = weights.get(k, by_node.get(k))
        if src is None:
            if k not in unused:
                raise KeyError(f"no ONNX weight for {k}")
            continue
        if tuple(src.shape) != tuple(v.shape):
            raise ValueError(f"{k}: ONNX {src.shape} vs model {tuple(v.shape)}")
        loaded[k] = torch.from_numpy(src.astype(np.float32))
    missing = model.load_state_dict(loaded, strict=False).missing_keys
    if set(missing) - unused:
        raise KeyError(f"unloaded: {set(missing) - unused}")
    return model.eval().to(device)


class Owl:
    def __init__(self, runtime: str = "mps") -> None:
        from tokenizers import Tokenizer

        if not MODEL.exists():
            raise FileNotFoundError(f"{MODEL} missing; download it from {URL}")
        self.runtime = runtime
        if runtime == "onnx-cpu":
            import onnxruntime as ort

            self.session = ort.InferenceSession(upcast_fp16(MODEL), providers=["CPUExecutionProvider"])
        else:
            self.model = torch_model(runtime)
        tok = Tokenizer.from_file(str(DIR / "tokenizer.json"))
        self.labels = list(config.OWL_QUERIES)
        ids = np.zeros((len(self.labels), MAX_TOKENS), dtype=np.int64)  # pad token "!" is id 0
        mask = np.zeros_like(ids)
        for k, q in enumerate(config.OWL_QUERIES.values()):
            enc = tok.encode(q).ids
            if len(enc) > MAX_TOKENS:
                raise ValueError(f"query {q!r} is {len(enc)} tokens; OWLv2 takes {MAX_TOKENS}")
            ids[k, : len(enc)] = enc
            mask[k, : len(enc)] = 1
        self.ids, self.mask = ids, mask

    def forward(self, pixels: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        if self.runtime == "onnx-cpu":
            feeds = {"input_ids": self.ids, "attention_mask": self.mask, "pixel_values": pixels}
            return tuple(self.session.run(["logits", "pred_boxes"], feeds))
        import torch

        dev = self.runtime
        with torch.inference_mode():
            out = self.model(
                input_ids=torch.from_numpy(self.ids).to(dev),
                attention_mask=torch.from_numpy(self.mask).to(dev),
                pixel_values=torch.from_numpy(pixels).to(dev),
            )
            return out.logits.float().cpu().numpy(), out.pred_boxes.float().cpu().numpy()

    @staticmethod
    def preprocess(im: Image.Image) -> np.ndarray:
        w, h = im.size
        s = max(w, h)
        square = Image.new("RGB", (s, s), (0, 0, 0))
        square.paste(im, (0, 0))
        x = np.asarray(square.resize((SIZE, SIZE), Image.Resampling.BILINEAR), dtype=np.float32) / 255.0
        x = (x - MEAN) / STD
        return x.transpose(2, 0, 1)[None]

    def detect(self, path: Path) -> tuple[list[dict], float, float]:
        """Detections in image-normalized [x0, y0, x1, y1]; preprocess ms; inference ms."""
        im = Image.open(path).convert("RGB")
        w, h = im.size
        t0 = time.perf_counter()
        pixels = self.preprocess(im)
        t1 = time.perf_counter()
        logits, boxes = self.forward(pixels)
        t2 = time.perf_counter()
        scores = 1 / (1 + np.exp(-logits[0]))  # (3600, queries)
        label = scores.argmax(1)
        score = scores.max(1)
        cx, cy, bw, bh = boxes[0].T
        s = max(w, h)
        xyxy = np.stack([(cx - bw / 2) * s / w, (cy - bh / 2) * s / h, (cx + bw / 2) * s / w, (cy + bh / 2) * s / h], 1)
        dets = postprocess(np.clip(xyxy, 0, 1), score, [self.labels[i] for i in label])
        return dets, 1000 * (t1 - t0), 1000 * (t2 - t1)


def meta() -> dict:
    return {
        "model": "OWLv2 base patch16 ensemble, ONNX fp16",
        "queries": config.OWL_QUERIES,
        "license": "Apache-2.0",
        "size": f"{MODEL.stat().st_size / 1e6:.0f} MB (fp16 ONNX)",
        "runtime": "PyTorch MPS (GPU), Mac, fp32",
        "input": "960 x 960 (padded square)",
        "command": "uv run python -m autodetect.owl",
    }


def run(owl: Owl, name: str) -> None:
    images = {}
    for k, i in enumerate(sorted(ground_truth(name))):
        dets, pre_ms, ms = owl.detect(image_path(name, i))
        images[i] = {"elapsed_ms": ms, "preprocess_ms": pre_ms, "dets": dets}
        if k % 50 == 0:
            print(f"{name}: {k} images, last {ms:.0f} ms", file=sys.stderr)
    save_preds("owlv2", name, meta(), images)


def parity(path: Path) -> None:
    im = Image.open(path).convert("RGB")
    x = Owl.preprocess(im)
    ref = Owl("onnx-cpu")
    a = ref.forward(x)
    del ref
    b = Owl("mps").forward(x)
    print(f"max |logit diff| {np.abs(a[0] - b[0]).max():.4f} (logit range {a[0].min():.1f}..{a[0].max():.1f}), "
          f"max |box diff| {np.abs(a[1] - b[1]).max():.5f}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["parity"]:
        parity(Path(sys.argv[2]))
    else:
        owl = Owl()
        for s in sys.argv[1:] or SETS:
            run(owl, s)
