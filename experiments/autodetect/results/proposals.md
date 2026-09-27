# Proposals: window and door detection

Generated 2026-09-26 by `uv run python -m autodetect.score` from cached predictions
(see each model's run command below). Criteria are in `../README.md`, settings in
`../autodetect/config.py`. IoU 0.5; Open Images rules for unverified classes and group-of boxes.
The threshold is chosen on the 150-image OI tune set and applied unchanged to both held-out sets.

## Operating point

Pass needs recall >= 80% and precision >= 60% at the operating threshold, judged per set.

| Model | Class | Threshold | Set | Images | GT | TP | FP | Precision | Recall | AP50 | Pass |
|---|---|---|---|---|---|---|---|---|---|---|---|
| owlv2 | window | 0.162 | Open Images eval | 289 | 3398 | 768 | 631 | 54.9% | 22.6% | 26.0% | no |
| owlv2 | window | 0.162 | CMP base | 378 | 12222 | 4287 | 1153 | 78.8% | 35.1% | 58.3% | no |
| owlv2 | door | 0.318 | Open Images eval | 112 | 102 | 59 | 20 | 74.7% | 57.8% | 69.6% | no |
| owlv2 | door | 0.318 | CMP base | 378 | 398 | 66 | 22 | 75.0% | 16.6% | 40.3% | no |
| owlv2 | window_or_door | 0.221 | Open Images eval | 101 | 318 | 169 | 117 | 59.1% | 53.1% | 59.5% | no |
| owlv2 | window_or_door | 0.221 | CMP base | 378 | 12620 | 1536 | 305 | 83.4% | 12.2% | 56.8% | no |
| vision_rects | window | 1.000 | Open Images eval | 289 | 3398 | 517 | 7460 | 6.5% | 15.2% | 1.1% | no |
| vision_rects | window | 1.000 | CMP base | 378 | 12222 | 4043 | 15103 | 21.1% | 33.1% | 7.8% | no |
| vision_rects | window_or_door | 1.000 | Open Images eval | 101 | 318 | 125 | 2576 | 4.6% | 39.3% | 3.4% | no |
| vision_rects | window_or_door | 1.000 | CMP base | 378 | 12620 | 4219 | 14927 | 22.0% | 33.4% | 8.1% | no |

## Tune-set operating point (where each threshold came from)

| Model | Class | Threshold | Rule | Tune precision | Tune recall |
|---|---|---|---|---|---|
| owlv2 | window | 0.162 | lowest score with precision >= 0.6 | 60.0% | 21.3% |
| owlv2 | door | 0.318 | lowest score with precision >= 0.6 | 60.0% | 50.0% |
| owlv2 | window_or_door | 0.221 | lowest score with precision >= 0.6 | 60.1% | 56.0% |
| vision_rects | window | 1.000 | best F1 (no score reaches the precision bar) | 6.6% | 12.9% |
| vision_rects | window_or_door | 1.000 | best F1 (no score reaches the precision bar) | 4.0% | 28.3% |

## Diagnostic: near-sized objects only

Not a pass criterion. Ground-truth boxes narrower or shorter than 10% of the image
are treated as difficult (a detection on one is ignored, a miss is not counted), and detections
that small are dropped, to approximate the large objects in a 1 to 3 m phone frame. Same
thresholds. Dropping small detections was added after the first scored run showed that
without it the small false positives alone kept precision under 25%.

| Model | Class | Set | GT | Precision | Recall | AP50 |
|---|---|---|---|---|---|---|
| owlv2 | window | Open Images eval | 206 | 51.9% | 52.4% | 49.9% |
| owlv2 | window | CMP base | 282 | 44.6% | 57.1% | 46.7% |
| owlv2 | door | Open Images eval | 63 | 72.5% | 58.7% | 69.9% |
| owlv2 | door | CMP base | 74 | 55.6% | 6.8% | 35.3% |
| owlv2 | window_or_door | Open Images eval | 132 | 62.0% | 64.4% | 65.3% |
| owlv2 | window_or_door | CMP base | 356 | 71.7% | 37.1% | 44.4% |
| vision_rects | window | Open Images eval | 206 | 8.8% | 35.0% | 4.8% |
| vision_rects | window | CMP base | 282 | 8.8% | 43.6% | 6.4% |
| vision_rects | window_or_door | Open Images eval | 132 | 12.8% | 38.6% | 6.7% |
| vision_rects | window_or_door | CMP base | 356 | 10.9% | 42.4% | 8.5% |

## Model, license and Mac latency

Latency is per image on this Mac (Apple M4 Pro, 24 GB), inference call only, excluding JPEG
decode, preprocessing and the first (warm-up) image. It is not an iPhone number; a phone is
slower. Other agents shared the Mac throughout: the load average column is the 1, 5 and 15
minute load when the OI eval predictions were saved (12 cores), and loads of 100 to 490 were
seen during the OWLv2 run, so every timing here is likely slower than on an idle Mac.

| Model | License | Size | Runtime | Input | OI eval median ms | OI eval p90 ms | CMP median ms | CPU-only median / p90 ms | Load average | Speed class (Mac, p90) | Command |
|---|---|---|---|---|---|---|---|---|---|---|---|
| owlv2 | Apache-2.0 | 308 MB (fp16 ONNX) | PyTorch MPS (GPU), Mac, fp32 | 960 x 960 (padded square) | 480.7 | 526.9 | 453.8 | n/a | not recorded | keyframe | `uv run python -m autodetect.owl` |
| vision_rects | OS API (no weights shipped) | 0 (in the OS) | Vision, Mac | image as stored (OI 1024 px, CMP about 1024 px) | 12.1 | 32.6 | 10.6 | n/a | [433.1, 278.1, 223.6] | live | `uv run python -m autodetect.run_vision` |
