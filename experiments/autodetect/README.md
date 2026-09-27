# Autodetect: can the phone propose windows and doors?

Today the homeowner draws each window box and taps its corners. This experiment asks which detector could propose windows and doors for the homeowner to confirm, how fast it runs, and whether a detected box, lifted onto the wall, is accurate enough to replace the taps.

## Pass criteria (fixed before any scored run)

1. **Proposals.** A candidate is good enough to propose window or door when, at its operating threshold, recall is at least 80% and precision at least 60% at IoU 0.5. The threshold is chosen per class on a 150-image Open Images tune set, then applied unchanged to each held-out set: 300 Open Images images and the 378 CMP Facade base images. The verdict is given per set. Open Images scoring follows its own rules for unverified classes and group-of boxes (`autodetect/oieval.py`). Both sets differ from the app's view: they show whole buildings from a distance, and CMP's facades are frontal and rectified. The app sees one wall at an angle from 1 to 3 m.
2. **Speed class**, from Mac (M4 Pro) timings: live (at most 100 ms a frame), keyframe (at most 1 s), or offline (over 1 s).
3. **3D extent.** A detected edge lifted to the wall replaces a tap when its p90 error is at most 0.5 ft. Ground truth is each door's or window's edges measured once in the ETH3D electro laser scan. Separately, the spread of one object's lifted edges across photos is reported.

Prompts, thresholds and detector settings are in `autodetect/config.py`.

## Rerun

Needs about 400 MB in `~/house-scanning-data/autodetect/` plus about 350 MB for one model's weights at a time, and the ETH3D electro packet and scan from the evals lane for the 3D step.

```sh
uv sync && uv run pytest
uv run python -m autodetect.openimages select && uv run python -m autodetect.openimages download
uv run python -m autodetect.cmp
swift build -c release --package-path vision   # copy rects, coremldet, trainod to ~/house-scanning-data/autodetect/bin
uv run python -m autodetect.run_vision oi_tune oi_eval cmp electro
uv run python -m autodetect.owl oi_tune oi_eval cmp electro      # needs weights/owlv2/model_fp16.onnx
uv run python -m autodetect.gdino                                # needs weights/gdino/model_fp16.onnx
uv run python -m autodetect.student prepare && uv run python -m autodetect.student train transfer
uv run python -m autodetect.student crop transfer && uv run python -m autodetect.student predict transfer <crop>
uv run python -m autodetect.score                                # results/proposals.md
uv run python -m autodetect.extent_gt save && uv run python -m autodetect.extent   # results/extent.md
```

## Result

To be written by the lead.
