# 3D extent: detected door edges lifted onto the wall

Generated 2026-09-26 by `uv run python -m autodetect.extent` (ground truth first:
`uv run python -m autodetect.extent_gt save`). Data: the ETH3D electro packet, 8 DSLR photos
with depth rendered from the laser scan, standing in for LiDAR. Door centres are 3.3 to 12.7 m
from the camera (median 7.6 m) and seen 5 to 43 degrees off the wall's normal (median 16).

Ground truth is each door's edges measured once in the laser scan, independent of any photo or
detector (method in `autodetect/extent_gt.py`). Four doors: two gray metal doors in recesses and
two glass double doors. Heights are above the ground at the meter; the doors' thresholds sit
0 to 0.12 m above it.

| Door | Width (ft) | Height (ft) | Edges read by eye only |
|---|---|---|---|
| B_open_niche | 6.92 | 9.84 | none |
| C_gray_double | 6.79 | 9.78 | none |
| E_glass_64 | 8.60 | 10.01 | none |
| F_glass_double | 7.26 | 10.04 | left |

Pass: p90 absolute edge error at most 0.5 ft over all scored edges. Each detector
uses its door operating threshold from the OI tune set (Vision rectangles: its only threshold).

Primary: doors wholly inside the photo. The last two columns are the doors the photo cuts off,
for their edges that are in view (not part of the pass).

| Boxes from | Lifting | Threshold | Whole door views matched / in view | Edges scored | p50 ft | p90 ft | max ft | Pass | Cut-off views matched | Cut-off edges p90 ft |
|---|---|---|---|---|---|---|---|---|---|---|
| projected ground truth | mid-side | n/a | 10 / 10 | 40 | 0.24 | 0.59 | 1.01 | n/a | 5 / 5 | 0.65 (10) |
| projected ground truth | inner corner | n/a | 10 / 10 | 40 | 0.00 | 0.11 | 0.30 | n/a | 5 / 5 | 0.20 (10) |
| owlv2 | mid-side | 0.318 | 2 / 10 | 8 | 0.33 | 1.73 | 4.04 | no | 1 / 5 | 0.83 (3) |
| owlv2 | inner corner | 0.318 | 2 / 10 | 8 | 0.31 | 1.62 | 4.30 | no | 1 / 5 | 0.43 (3) |
| owlv2 (any score) | mid-side | 0.010 | 7 / 10 | 28 | 0.40 | 3.28 | 4.04 | n/a | 5 / 5 | 0.75 (10) |
| owlv2 (any score) | inner corner | 0.010 | 7 / 10 | 28 | 0.44 | 2.78 | 4.30 | n/a | 5 / 5 | 0.52 (10) |
| student_transfer | mid-side | 0.976 | 0 / 10 | 0 | n/a | n/a | n/a | no | 0 / 5 | n/a (0) |
| student_transfer | inner corner | 0.976 | 0 / 10 | 0 | n/a | n/a | n/a | no | 0 / 5 | n/a (0) |
| student_transfer (any score) | mid-side | 0.010 | 10 / 10 | 40 | 0.72 | 2.08 | 3.07 | n/a | 4 / 5 | 1.89 (9) |
| student_transfer (any score) | inner corner | 0.010 | 10 / 10 | 40 | 0.60 | 1.81 | 2.77 | n/a | 4 / 5 | 1.70 (9) |
| vision_rects | mid-side | 1.000 | 4 / 10 | 16 | 0.33 | 1.78 | 2.45 | no | 2 / 5 | 2.23 (5) |
| vision_rects | inner corner | 1.000 | 4 / 10 | 16 | 0.38 | 1.18 | 2.34 | no | 2 / 5 | 1.43 (5) |
| vision_rects (any score) | mid-side | 0.010 | 4 / 10 | 16 | 0.33 | 1.78 | 2.45 | n/a | 2 / 5 | 2.23 (5) |
| vision_rects (any score) | inner corner | 0.010 | 4 / 10 | 16 | 0.38 | 1.18 | 2.34 | n/a | 2 / 5 | 1.43 (5) |

## By edge (p90 absolute error, ft; count in brackets)

| Boxes from | Lifting | Left | Right | Bottom | Top |
|---|---|---|---|---|---|
| projected ground truth | mid-side | 0.23 (10) | 0.33 (10) | 0.72 (10) | 0.77 (10) |
| projected ground truth | inner corner | 0.13 (10) | 0.01 (10) | 0.00 (10) | 0.22 (10) |
| owlv2 | mid-side | 3.71 (2) | 0.12 (2) | 0.12 (2) | 0.65 (2) |
| owlv2 | inner corner | 3.92 (2) | 0.44 (2) | 0.10 (2) | 0.33 (2) |
| owlv2 (any score) | mid-side | 3.59 (7) | 0.28 (7) | 0.55 (7) | 3.08 (7) |
| owlv2 (any score) | inner corner | 3.86 (7) | 0.47 (7) | 0.34 (7) | 1.42 (7) |
| student_transfer | mid-side | n/a (0) | n/a (0) | n/a (0) | n/a (0) |
| student_transfer | inner corner | n/a (0) | n/a (0) | n/a (0) | n/a (0) |
| student_transfer (any score) | mid-side | 1.53 (10) | 2.62 (10) | 1.22 (10) | 1.41 (10) |
| student_transfer (any score) | inner corner | 1.61 (10) | 2.69 (10) | 1.37 (10) | 0.98 (10) |
| vision_rects | mid-side | 1.89 (4) | 0.49 (4) | 0.24 (4) | 2.05 (4) |
| vision_rects | inner corner | 1.77 (4) | 0.68 (4) | 0.46 (4) | 1.28 (4) |
| vision_rects (any score) | mid-side | 1.89 (4) | 0.49 (4) | 0.24 (4) | 2.05 (4) |
| vision_rects (any score) | inner corner | 1.77 (4) | 0.68 (4) | 0.46 (4) | 1.28 (4) |

## Cross-view spread

For each door edge seen in two or more photos: the largest minus the smallest lifted position.

| Boxes from | Lifting | Door edges with 2+ views | Median spread ft | Max spread ft |
|---|---|---|---|---|
| projected ground truth | mid-side | 12 | 0.24 | 0.78 |
| projected ground truth | inner corner | 12 | 0.02 | 0.26 |
| owlv2 | mid-side | 0 | n/a | n/a |
| owlv2 | inner corner | 0 | n/a | n/a |
| owlv2 (any score) | mid-side | 8 | 0.25 | 1.39 |
| owlv2 (any score) | inner corner | 8 | 0.22 | 0.45 |
| student_transfer | mid-side | 0 | n/a | n/a |
| student_transfer | inner corner | 0 | n/a | n/a |
| student_transfer (any score) | mid-side | 12 | 0.98 | 3.32 |
| student_transfer (any score) | inner corner | 12 | 1.16 | 3.15 |
| vision_rects | mid-side | 4 | 0.32 | 0.35 |
| vision_rects | inner corner | 4 | 0.14 | 0.49 |
| vision_rects (any score) | mid-side | 4 | 0.32 | 0.35 |
| vision_rects (any score) | inner corner | 4 | 0.14 | 0.49 |

## Every scored edge

| Boxes from | Lifting | Photo | Door | Door in view | Edge | Error ft (lifted minus truth) |
|---|---|---|---|---|---|---|
| projected ground truth | mid-side | p00001 | B_open_niche | whole | left | -0.00 |
| projected ground truth | mid-side | p00001 | B_open_niche | whole | right | +0.14 |
| projected ground truth | mid-side | p00001 | B_open_niche | whole | bottom | -0.23 |
| projected ground truth | mid-side | p00001 | B_open_niche | whole | top | +0.46 |
| projected ground truth | mid-side | p00001 | C_gray_double | whole | left | -0.18 |
| projected ground truth | mid-side | p00001 | C_gray_double | whole | right | +0.32 |
| projected ground truth | mid-side | p00001 | C_gray_double | whole | bottom | -0.27 |
| projected ground truth | mid-side | p00001 | C_gray_double | whole | top | +0.47 |
| projected ground truth | mid-side | p00002 | B_open_niche | whole | left | -0.22 |
| projected ground truth | mid-side | p00002 | B_open_niche | whole | right | +0.33 |
| projected ground truth | mid-side | p00002 | B_open_niche | whole | bottom | -0.69 |
| projected ground truth | mid-side | p00002 | B_open_niche | whole | top | +0.75 |
| projected ground truth | mid-side | p00002 | C_gray_double | cut off | left | -0.35 |
| projected ground truth | mid-side | p00002 | C_gray_double | cut off | top | +0.90 |
| projected ground truth | mid-side | p00002 | F_glass_double | whole | left (eye-only truth) | -0.10 |
| projected ground truth | mid-side | p00002 | F_glass_double | whole | right | +0.01 |
| projected ground truth | mid-side | p00002 | F_glass_double | whole | bottom | -0.44 |
| projected ground truth | mid-side | p00002 | F_glass_double | whole | top | +0.21 |
| projected ground truth | mid-side | p00003 | B_open_niche | whole | left | -0.24 |
| projected ground truth | mid-side | p00003 | B_open_niche | whole | right | +0.34 |
| projected ground truth | mid-side | p00003 | B_open_niche | whole | bottom | -1.01 |
| projected ground truth | mid-side | p00003 | B_open_niche | whole | top | +0.94 |
| projected ground truth | mid-side | p00003 | C_gray_double | cut off | left | -0.38 |
| projected ground truth | mid-side | p00003 | F_glass_double | whole | left (eye-only truth) | -0.13 |
| projected ground truth | mid-side | p00003 | F_glass_double | whole | right | +0.04 |
| projected ground truth | mid-side | p00003 | F_glass_double | whole | bottom | -0.42 |
| projected ground truth | mid-side | p00003 | F_glass_double | whole | top | +0.25 |
| projected ground truth | mid-side | p00004 | B_open_niche | cut off | left | -0.63 |
| projected ground truth | mid-side | p00004 | E_glass_64 | cut off | right | +0.06 |
| projected ground truth | mid-side | p00004 | E_glass_64 | cut off | bottom | -0.36 |
| projected ground truth | mid-side | p00004 | E_glass_64 | cut off | top | +0.13 |
| projected ground truth | mid-side | p00004 | F_glass_double | whole | left (eye-only truth) | -0.04 |
| projected ground truth | mid-side | p00004 | F_glass_double | whole | right | +0.12 |
| projected ground truth | mid-side | p00004 | F_glass_double | whole | bottom | -0.24 |
| projected ground truth | mid-side | p00004 | F_glass_double | whole | top | +0.07 |
| projected ground truth | mid-side | p00005 | E_glass_64 | whole | left | -0.04 |
| projected ground truth | mid-side | p00005 | E_glass_64 | whole | right | +0.15 |
| projected ground truth | mid-side | p00005 | E_glass_64 | whole | bottom | -0.05 |
| projected ground truth | mid-side | p00005 | E_glass_64 | whole | top | +0.31 |
| projected ground truth | mid-side | p00005 | F_glass_double | whole | left (eye-only truth) | -0.23 |
| projected ground truth | mid-side | p00005 | F_glass_double | whole | right | +0.31 |
| projected ground truth | mid-side | p00005 | F_glass_double | whole | bottom | -0.02 |
| projected ground truth | mid-side | p00005 | F_glass_double | whole | top | +0.25 |
| projected ground truth | mid-side | p00006 | E_glass_64 | whole | left | -0.17 |
| projected ground truth | mid-side | p00006 | E_glass_64 | whole | right | +0.27 |
| projected ground truth | mid-side | p00006 | E_glass_64 | whole | bottom | -0.29 |
| projected ground truth | mid-side | p00006 | E_glass_64 | whole | top | +0.58 |
| projected ground truth | mid-side | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.32 |
| projected ground truth | mid-side | p00006 | F_glass_double | cut off | bottom | -0.13 |
| projected ground truth | mid-side | p00006 | F_glass_double | cut off | top | +0.35 |
| projected ground truth | inner corner | p00001 | B_open_niche | whole | left | +0.00 |
| projected ground truth | inner corner | p00001 | B_open_niche | whole | right | -0.00 |
| projected ground truth | inner corner | p00001 | B_open_niche | whole | bottom | -0.00 |
| projected ground truth | inner corner | p00001 | B_open_niche | whole | top | -0.04 |
| projected ground truth | inner corner | p00001 | C_gray_double | whole | left | +0.04 |
| projected ground truth | inner corner | p00001 | C_gray_double | whole | right | -0.00 |
| projected ground truth | inner corner | p00001 | C_gray_double | whole | bottom | -0.00 |
| projected ground truth | inner corner | p00001 | C_gray_double | whole | top | -0.11 |
| projected ground truth | inner corner | p00002 | B_open_niche | whole | left | +0.13 |
| projected ground truth | inner corner | p00002 | B_open_niche | whole | right | -0.00 |
| projected ground truth | inner corner | p00002 | B_open_niche | whole | bottom | -0.00 |
| projected ground truth | inner corner | p00002 | B_open_niche | whole | top | -0.21 |
| projected ground truth | inner corner | p00002 | C_gray_double | cut off | left | +0.15 |
| projected ground truth | inner corner | p00002 | C_gray_double | cut off | top | -0.00 |
| projected ground truth | inner corner | p00002 | F_glass_double | whole | left (eye-only truth) | -0.00 |
| projected ground truth | inner corner | p00002 | F_glass_double | whole | right | -0.01 |
| projected ground truth | inner corner | p00002 | F_glass_double | whole | bottom | +0.00 |
| projected ground truth | inner corner | p00002 | F_glass_double | whole | top | -0.02 |
| projected ground truth | inner corner | p00003 | B_open_niche | whole | left | +0.16 |
| projected ground truth | inner corner | p00003 | B_open_niche | whole | right | -0.00 |
| projected ground truth | inner corner | p00003 | B_open_niche | whole | bottom | -0.00 |
| projected ground truth | inner corner | p00003 | B_open_niche | whole | top | -0.30 |
| projected ground truth | inner corner | p00003 | C_gray_double | cut off | left | +0.03 |
| projected ground truth | inner corner | p00003 | F_glass_double | whole | left (eye-only truth) | -0.00 |
| projected ground truth | inner corner | p00003 | F_glass_double | whole | right | -0.01 |
| projected ground truth | inner corner | p00003 | F_glass_double | whole | bottom | +0.00 |
| projected ground truth | inner corner | p00003 | F_glass_double | whole | top | -0.02 |
| projected ground truth | inner corner | p00004 | B_open_niche | cut off | left | -0.63 |
| projected ground truth | inner corner | p00004 | E_glass_64 | cut off | right | -0.00 |
| projected ground truth | inner corner | p00004 | E_glass_64 | cut off | bottom | -0.00 |
| projected ground truth | inner corner | p00004 | E_glass_64 | cut off | top | +0.00 |
| projected ground truth | inner corner | p00004 | F_glass_double | whole | left (eye-only truth) | -0.00 |
| projected ground truth | inner corner | p00004 | F_glass_double | whole | right | -0.02 |
| projected ground truth | inner corner | p00004 | F_glass_double | whole | bottom | +0.01 |
| projected ground truth | inner corner | p00004 | F_glass_double | whole | top | -0.00 |
| projected ground truth | inner corner | p00005 | E_glass_64 | whole | left | +0.01 |
| projected ground truth | inner corner | p00005 | E_glass_64 | whole | right | -0.00 |
| projected ground truth | inner corner | p00005 | E_glass_64 | whole | bottom | -0.00 |
| projected ground truth | inner corner | p00005 | E_glass_64 | whole | top | -0.02 |
| projected ground truth | inner corner | p00005 | F_glass_double | whole | left (eye-only truth) | +0.03 |
| projected ground truth | inner corner | p00005 | F_glass_double | whole | right | +0.00 |
| projected ground truth | inner corner | p00005 | F_glass_double | whole | bottom | -0.00 |
| projected ground truth | inner corner | p00005 | F_glass_double | whole | top | -0.05 |
| projected ground truth | inner corner | p00006 | E_glass_64 | whole | left | +0.07 |
| projected ground truth | inner corner | p00006 | E_glass_64 | whole | right | +0.00 |
| projected ground truth | inner corner | p00006 | E_glass_64 | whole | bottom | +0.00 |
| projected ground truth | inner corner | p00006 | E_glass_64 | whole | top | -0.09 |
| projected ground truth | inner corner | p00006 | F_glass_double | cut off | left (eye-only truth) | +0.05 |
| projected ground truth | inner corner | p00006 | F_glass_double | cut off | bottom | +0.00 |
| projected ground truth | inner corner | p00006 | F_glass_double | cut off | top | -0.00 |
| owlv2 | mid-side | p00005 | F_glass_double | whole | left (eye-only truth) | -0.74 |
| owlv2 | mid-side | p00005 | F_glass_double | whole | right | -0.14 |
| owlv2 | mid-side | p00005 | F_glass_double | whole | bottom | -0.13 |
| owlv2 | mid-side | p00005 | F_glass_double | whole | top | +0.66 |
| owlv2 | mid-side | p00006 | E_glass_64 | whole | left | +4.04 |
| owlv2 | mid-side | p00006 | E_glass_64 | whole | right | +0.00 |
| owlv2 | mid-side | p00006 | E_glass_64 | whole | bottom | -0.07 |
| owlv2 | mid-side | p00006 | E_glass_64 | whole | top | +0.52 |
| owlv2 | mid-side | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.74 |
| owlv2 | mid-side | p00006 | F_glass_double | cut off | bottom | -0.22 |
| owlv2 | mid-side | p00006 | F_glass_double | cut off | top | +0.86 |
| owlv2 | inner corner | p00005 | F_glass_double | whole | left (eye-only truth) | -0.48 |
| owlv2 | inner corner | p00005 | F_glass_double | whole | right | -0.46 |
| owlv2 | inner corner | p00005 | F_glass_double | whole | bottom | -0.10 |
| owlv2 | inner corner | p00005 | F_glass_double | whole | top | +0.35 |
| owlv2 | inner corner | p00006 | E_glass_64 | whole | left | +4.30 |
| owlv2 | inner corner | p00006 | E_glass_64 | whole | right | -0.27 |
| owlv2 | inner corner | p00006 | E_glass_64 | whole | bottom | +0.08 |
| owlv2 | inner corner | p00006 | E_glass_64 | whole | top | +0.16 |
| owlv2 | inner corner | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.35 |
| owlv2 | inner corner | p00006 | F_glass_double | cut off | bottom | -0.08 |
| owlv2 | inner corner | p00006 | F_glass_double | cut off | top | +0.46 |
| owlv2 (any score) | mid-side | p00001 | C_gray_double | whole | left | +3.29 |
| owlv2 (any score) | mid-side | p00001 | C_gray_double | whole | right | +0.24 |
| owlv2 (any score) | mid-side | p00001 | C_gray_double | whole | bottom | -0.26 |
| owlv2 (any score) | mid-side | p00001 | C_gray_double | whole | top | +0.04 |
| owlv2 (any score) | mid-side | p00001 | B_open_niche | whole | left | -2.56 |
| owlv2 (any score) | mid-side | p00001 | B_open_niche | whole | right | +0.15 |
| owlv2 (any score) | mid-side | p00001 | B_open_niche | whole | bottom | -0.25 |
| owlv2 (any score) | mid-side | p00001 | B_open_niche | whole | top | +2.16 |
| owlv2 (any score) | mid-side | p00002 | C_gray_double | cut off | left | -0.16 |
| owlv2 (any score) | mid-side | p00002 | C_gray_double | cut off | top | +0.43 |
| owlv2 (any score) | mid-side | p00002 | B_open_niche | whole | left | -3.27 |
| owlv2 (any score) | mid-side | p00002 | B_open_niche | whole | right | +0.07 |
| owlv2 (any score) | mid-side | p00002 | B_open_niche | whole | bottom | -0.33 |
| owlv2 (any score) | mid-side | p00002 | B_open_niche | whole | top | +2.76 |
| owlv2 (any score) | mid-side | p00003 | C_gray_double | cut off | left | -0.38 |
| owlv2 (any score) | mid-side | p00003 | B_open_niche | whole | left | -3.16 |
| owlv2 (any score) | mid-side | p00003 | B_open_niche | whole | right | -0.06 |
| owlv2 (any score) | mid-side | p00003 | B_open_niche | whole | bottom | -0.87 |
| owlv2 (any score) | mid-side | p00003 | B_open_niche | whole | top | +3.55 |
| owlv2 (any score) | mid-side | p00004 | F_glass_double | whole | left (eye-only truth) | -0.46 |
| owlv2 (any score) | mid-side | p00004 | F_glass_double | whole | right | -0.35 |
| owlv2 (any score) | mid-side | p00004 | F_glass_double | whole | bottom | -0.28 |
| owlv2 (any score) | mid-side | p00004 | F_glass_double | whole | top | +0.58 |
| owlv2 (any score) | mid-side | p00004 | E_glass_64 | cut off | right | -0.16 |
| owlv2 (any score) | mid-side | p00004 | E_glass_64 | cut off | bottom | -0.35 |
| owlv2 (any score) | mid-side | p00004 | E_glass_64 | cut off | top | +0.66 |
| owlv2 (any score) | mid-side | p00004 | B_open_niche | cut off | left | -0.66 |
| owlv2 (any score) | mid-side | p00005 | F_glass_double | whole | left (eye-only truth) | -0.74 |
| owlv2 (any score) | mid-side | p00005 | F_glass_double | whole | right | -0.14 |
| owlv2 (any score) | mid-side | p00005 | F_glass_double | whole | bottom | -0.13 |
| owlv2 (any score) | mid-side | p00005 | F_glass_double | whole | top | +0.66 |
| owlv2 (any score) | mid-side | p00006 | E_glass_64 | whole | left | +4.04 |
| owlv2 (any score) | mid-side | p00006 | E_glass_64 | whole | right | +0.00 |
| owlv2 (any score) | mid-side | p00006 | E_glass_64 | whole | bottom | -0.07 |
| owlv2 (any score) | mid-side | p00006 | E_glass_64 | whole | top | +0.52 |
| owlv2 (any score) | mid-side | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.74 |
| owlv2 (any score) | mid-side | p00006 | F_glass_double | cut off | bottom | -0.22 |
| owlv2 (any score) | mid-side | p00006 | F_glass_double | cut off | top | +0.86 |
| owlv2 (any score) | inner corner | p00001 | C_gray_double | whole | left | +3.57 |
| owlv2 (any score) | inner corner | p00001 | C_gray_double | whole | right | -0.08 |
| owlv2 (any score) | inner corner | p00001 | C_gray_double | whole | bottom | -0.11 |
| owlv2 (any score) | inner corner | p00001 | C_gray_double | whole | top | -0.26 |
| owlv2 (any score) | inner corner | p00001 | B_open_niche | whole | left | -2.48 |
| owlv2 (any score) | inner corner | p00001 | B_open_niche | whole | right | -0.01 |
| owlv2 (any score) | inner corner | p00001 | B_open_niche | whole | bottom | +0.05 |
| owlv2 (any score) | inner corner | p00001 | B_open_niche | whole | top | +1.35 |
| owlv2 (any score) | inner corner | p00002 | C_gray_double | cut off | left | +0.30 |
| owlv2 (any score) | inner corner | p00002 | C_gray_double | cut off | top | -0.24 |
| owlv2 (any score) | inner corner | p00002 | B_open_niche | whole | left | -2.91 |
| owlv2 (any score) | inner corner | p00002 | B_open_niche | whole | right | -0.29 |
| owlv2 (any score) | inner corner | p00002 | B_open_niche | whole | bottom | +0.45 |
| owlv2 (any score) | inner corner | p00002 | B_open_niche | whole | top | +1.22 |
| owlv2 (any score) | inner corner | p00003 | C_gray_double | cut off | left | +0.03 |
| owlv2 (any score) | inner corner | p00003 | B_open_niche | whole | left | -2.73 |
| owlv2 (any score) | inner corner | p00003 | B_open_niche | whole | right | -0.46 |
| owlv2 (any score) | inner corner | p00003 | B_open_niche | whole | bottom | +0.27 |
| owlv2 (any score) | inner corner | p00003 | B_open_niche | whole | top | +1.51 |
| owlv2 (any score) | inner corner | p00004 | F_glass_double | whole | left (eye-only truth) | -0.42 |
| owlv2 (any score) | inner corner | p00004 | F_glass_double | whole | right | -0.49 |
| owlv2 (any score) | inner corner | p00004 | F_glass_double | whole | bottom | -0.04 |
| owlv2 (any score) | inner corner | p00004 | F_glass_double | whole | top | +0.49 |
| owlv2 (any score) | inner corner | p00004 | E_glass_64 | cut off | right | -0.23 |
| owlv2 (any score) | inner corner | p00004 | E_glass_64 | cut off | bottom | -0.01 |
| owlv2 (any score) | inner corner | p00004 | E_glass_64 | cut off | top | +0.51 |
| owlv2 (any score) | inner corner | p00004 | B_open_niche | cut off | left | -0.66 |
| owlv2 (any score) | inner corner | p00005 | F_glass_double | whole | left (eye-only truth) | -0.48 |
| owlv2 (any score) | inner corner | p00005 | F_glass_double | whole | right | -0.46 |
| owlv2 (any score) | inner corner | p00005 | F_glass_double | whole | bottom | -0.10 |
| owlv2 (any score) | inner corner | p00005 | F_glass_double | whole | top | +0.35 |
| owlv2 (any score) | inner corner | p00006 | E_glass_64 | whole | left | +4.30 |
| owlv2 (any score) | inner corner | p00006 | E_glass_64 | whole | right | -0.27 |
| owlv2 (any score) | inner corner | p00006 | E_glass_64 | whole | bottom | +0.08 |
| owlv2 (any score) | inner corner | p00006 | E_glass_64 | whole | top | +0.16 |
| owlv2 (any score) | inner corner | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.35 |
| owlv2 (any score) | inner corner | p00006 | F_glass_double | cut off | bottom | -0.08 |
| owlv2 (any score) | inner corner | p00006 | F_glass_double | cut off | top | +0.46 |
| student_transfer (any score) | mid-side | p00001 | C_gray_double | whole | left | +0.23 |
| student_transfer (any score) | mid-side | p00001 | C_gray_double | whole | right | -0.22 |
| student_transfer (any score) | mid-side | p00001 | C_gray_double | whole | bottom | +0.08 |
| student_transfer (any score) | mid-side | p00001 | C_gray_double | whole | top | +0.22 |
| student_transfer (any score) | mid-side | p00001 | B_open_niche | whole | left | +0.22 |
| student_transfer (any score) | mid-side | p00001 | B_open_niche | whole | right | +0.62 |
| student_transfer (any score) | mid-side | p00001 | B_open_niche | whole | bottom | -0.69 |
| student_transfer (any score) | mid-side | p00001 | B_open_niche | whole | top | +1.29 |
| student_transfer (any score) | mid-side | p00002 | F_glass_double | whole | left (eye-only truth) | -0.72 |
| student_transfer (any score) | mid-side | p00002 | F_glass_double | whole | right | -2.04 |
| student_transfer (any score) | mid-side | p00002 | F_glass_double | whole | bottom | -1.19 |
| student_transfer (any score) | mid-side | p00002 | F_glass_double | whole | top | +1.07 |
| student_transfer (any score) | mid-side | p00002 | C_gray_double | cut off | left | +0.67 |
| student_transfer (any score) | mid-side | p00002 | C_gray_double | cut off | top | +0.09 |
| student_transfer (any score) | mid-side | p00002 | B_open_niche | whole | left | -0.63 |
| student_transfer (any score) | mid-side | p00002 | B_open_niche | whole | right | +0.49 |
| student_transfer (any score) | mid-side | p00002 | B_open_niche | whole | bottom | -0.72 |
| student_transfer (any score) | mid-side | p00002 | B_open_niche | whole | top | +0.93 |
| student_transfer (any score) | mid-side | p00003 | F_glass_double | whole | left (eye-only truth) | -0.61 |
| student_transfer (any score) | mid-side | p00003 | F_glass_double | whole | right | -2.56 |
| student_transfer (any score) | mid-side | p00003 | F_glass_double | whole | bottom | -1.16 |
| student_transfer (any score) | mid-side | p00003 | F_glass_double | whole | top | +1.15 |
| student_transfer (any score) | mid-side | p00003 | B_open_niche | whole | left | -0.15 |
| student_transfer (any score) | mid-side | p00003 | B_open_niche | whole | right | -0.53 |
| student_transfer (any score) | mid-side | p00003 | B_open_niche | whole | bottom | -0.13 |
| student_transfer (any score) | mid-side | p00003 | B_open_niche | whole | top | +1.16 |
| student_transfer (any score) | mid-side | p00004 | E_glass_64 | cut off | right | +2.29 |
| student_transfer (any score) | mid-side | p00004 | E_glass_64 | cut off | bottom | -0.24 |
| student_transfer (any score) | mid-side | p00004 | E_glass_64 | cut off | top | +1.80 |
| student_transfer (any score) | mid-side | p00004 | F_glass_double | whole | left (eye-only truth) | -1.17 |
| student_transfer (any score) | mid-side | p00004 | F_glass_double | whole | right | -2.57 |
| student_transfer (any score) | mid-side | p00004 | F_glass_double | whole | bottom | -0.71 |
| student_transfer (any score) | mid-side | p00004 | F_glass_double | whole | top | +1.02 |
| student_transfer (any score) | mid-side | p00004 | B_open_niche | cut off | left | -0.59 |
| student_transfer (any score) | mid-side | p00005 | F_glass_double | whole | left (eye-only truth) | +0.09 |
| student_transfer (any score) | mid-side | p00005 | F_glass_double | whole | right | -0.49 |
| student_transfer (any score) | mid-side | p00005 | F_glass_double | whole | bottom | -1.45 |
| student_transfer (any score) | mid-side | p00005 | F_glass_double | whole | top | +0.78 |
| student_transfer (any score) | mid-side | p00005 | E_glass_64 | whole | left | +1.53 |
| student_transfer (any score) | mid-side | p00005 | E_glass_64 | whole | right | -0.25 |
| student_transfer (any score) | mid-side | p00005 | E_glass_64 | whole | bottom | +0.04 |
| student_transfer (any score) | mid-side | p00005 | E_glass_64 | whole | top | -0.54 |
| student_transfer (any score) | mid-side | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.30 |
| student_transfer (any score) | mid-side | p00006 | F_glass_double | cut off | bottom | -1.14 |
| student_transfer (any score) | mid-side | p00006 | F_glass_double | cut off | top | +1.10 |
| student_transfer (any score) | mid-side | p00006 | E_glass_64 | whole | left | +1.53 |
| student_transfer (any score) | mid-side | p00006 | E_glass_64 | whole | right | +3.07 |
| student_transfer (any score) | mid-side | p00006 | E_glass_64 | whole | bottom | +1.16 |
| student_transfer (any score) | mid-side | p00006 | E_glass_64 | whole | top | +2.40 |
| student_transfer (any score) | inner corner | p00001 | C_gray_double | whole | left | +0.45 |
| student_transfer (any score) | inner corner | p00001 | C_gray_double | whole | right | -0.51 |
| student_transfer (any score) | inner corner | p00001 | C_gray_double | whole | bottom | +0.30 |
| student_transfer (any score) | inner corner | p00001 | C_gray_double | whole | top | -0.27 |
| student_transfer (any score) | inner corner | p00001 | B_open_niche | whole | left | +0.22 |
| student_transfer (any score) | inner corner | p00001 | B_open_niche | whole | right | +0.45 |
| student_transfer (any score) | inner corner | p00001 | B_open_niche | whole | bottom | -0.42 |
| student_transfer (any score) | inner corner | p00001 | B_open_niche | whole | top | +0.71 |
| student_transfer (any score) | inner corner | p00002 | F_glass_double | whole | left (eye-only truth) | -0.60 |
| student_transfer (any score) | inner corner | p00002 | F_glass_double | whole | right | -2.10 |
| student_transfer (any score) | inner corner | p00002 | F_glass_double | whole | bottom | -0.78 |
| student_transfer (any score) | inner corner | p00002 | F_glass_double | whole | top | +0.84 |
| student_transfer (any score) | inner corner | p00002 | C_gray_double | cut off | left | +1.12 |
| student_transfer (any score) | inner corner | p00002 | C_gray_double | cut off | top | -0.51 |
| student_transfer (any score) | inner corner | p00002 | B_open_niche | whole | left | -0.27 |
| student_transfer (any score) | inner corner | p00002 | B_open_niche | whole | right | +0.15 |
| student_transfer (any score) | inner corner | p00002 | B_open_niche | whole | bottom | +0.01 |
| student_transfer (any score) | inner corner | p00002 | B_open_niche | whole | top | -0.11 |
| student_transfer (any score) | inner corner | p00003 | F_glass_double | whole | left (eye-only truth) | -0.45 |
| student_transfer (any score) | inner corner | p00003 | F_glass_double | whole | right | -2.66 |
| student_transfer (any score) | inner corner | p00003 | F_glass_double | whole | bottom | -0.81 |
| student_transfer (any score) | inner corner | p00003 | F_glass_double | whole | top | +0.90 |
| student_transfer (any score) | inner corner | p00003 | B_open_niche | whole | left | +0.21 |
| student_transfer (any score) | inner corner | p00003 | B_open_niche | whole | right | -0.85 |
| student_transfer (any score) | inner corner | p00003 | B_open_niche | whole | bottom | +0.60 |
| student_transfer (any score) | inner corner | p00003 | B_open_niche | whole | top | +0.03 |
| student_transfer (any score) | inner corner | p00004 | E_glass_64 | cut off | right | +2.25 |
| student_transfer (any score) | inner corner | p00004 | E_glass_64 | cut off | bottom | +0.15 |
| student_transfer (any score) | inner corner | p00004 | E_glass_64 | cut off | top | +1.56 |
| student_transfer (any score) | inner corner | p00004 | F_glass_double | whole | left (eye-only truth) | -1.14 |
| student_transfer (any score) | inner corner | p00004 | F_glass_double | whole | right | -2.69 |
| student_transfer (any score) | inner corner | p00004 | F_glass_double | whole | bottom | -0.50 |
| student_transfer (any score) | inner corner | p00004 | F_glass_double | whole | top | +0.93 |
| student_transfer (any score) | inner corner | p00004 | B_open_niche | cut off | left | -0.59 |
| student_transfer (any score) | inner corner | p00005 | F_glass_double | whole | left (eye-only truth) | +0.39 |
| student_transfer (any score) | inner corner | p00005 | F_glass_double | whole | right | -0.85 |
| student_transfer (any score) | inner corner | p00005 | F_glass_double | whole | bottom | -1.39 |
| student_transfer (any score) | inner corner | p00005 | F_glass_double | whole | top | +0.51 |
| student_transfer (any score) | inner corner | p00005 | E_glass_64 | whole | left | +1.59 |
| student_transfer (any score) | inner corner | p00005 | E_glass_64 | whole | right | -0.38 |
| student_transfer (any score) | inner corner | p00005 | E_glass_64 | whole | bottom | +0.07 |
| student_transfer (any score) | inner corner | p00005 | E_glass_64 | whole | top | -0.78 |
| student_transfer (any score) | inner corner | p00006 | F_glass_double | cut off | left (eye-only truth) | +0.13 |
| student_transfer (any score) | inner corner | p00006 | F_glass_double | cut off | bottom | -0.99 |
| student_transfer (any score) | inner corner | p00006 | F_glass_double | cut off | top | +0.76 |
| student_transfer (any score) | inner corner | p00006 | E_glass_64 | whole | left | +1.78 |
| student_transfer (any score) | inner corner | p00006 | E_glass_64 | whole | right | +2.77 |
| student_transfer (any score) | inner corner | p00006 | E_glass_64 | whole | bottom | +1.37 |
| student_transfer (any score) | inner corner | p00006 | E_glass_64 | whole | top | +1.40 |
| vision_rects | mid-side | p00001 | C_gray_double | whole | left | -0.66 |
| vision_rects | mid-side | p00001 | C_gray_double | whole | right | +0.16 |
| vision_rects | mid-side | p00001 | C_gray_double | whole | bottom | +0.21 |
| vision_rects | mid-side | p00001 | C_gray_double | whole | top | +1.14 |
| vision_rects | mid-side | p00001 | B_open_niche | whole | left | -2.42 |
| vision_rects | mid-side | p00001 | B_open_niche | whole | right | +0.05 |
| vision_rects | mid-side | p00001 | B_open_niche | whole | bottom | +0.16 |
| vision_rects | mid-side | p00001 | B_open_niche | whole | top | +2.45 |
| vision_rects | mid-side | p00002 | C_gray_double | cut off | left | -0.89 |
| vision_rects | mid-side | p00002 | C_gray_double | cut off | top | +2.67 |
| vision_rects | mid-side | p00004 | F_glass_double | whole | left (eye-only truth) | -0.26 |
| vision_rects | mid-side | p00004 | F_glass_double | whole | right | -0.60 |
| vision_rects | mid-side | p00004 | F_glass_double | whole | bottom | +0.04 |
| vision_rects | mid-side | p00004 | F_glass_double | whole | top | +0.40 |
| vision_rects | mid-side | p00005 | F_glass_double | whole | left (eye-only truth) | -0.61 |
| vision_rects | mid-side | p00005 | F_glass_double | whole | right | -0.26 |
| vision_rects | mid-side | p00005 | F_glass_double | whole | bottom | -0.26 |
| vision_rects | mid-side | p00005 | F_glass_double | whole | top | +0.53 |
| vision_rects | mid-side | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.76 |
| vision_rects | mid-side | p00006 | F_glass_double | cut off | bottom | -1.58 |
| vision_rects | mid-side | p00006 | F_glass_double | cut off | top | +0.69 |
| vision_rects | inner corner | p00001 | C_gray_double | whole | left | -0.46 |
| vision_rects | inner corner | p00001 | C_gray_double | whole | right | -0.15 |
| vision_rects | inner corner | p00001 | C_gray_double | whole | bottom | +0.47 |
| vision_rects | inner corner | p00001 | C_gray_double | whole | top | +0.45 |
| vision_rects | inner corner | p00001 | B_open_niche | whole | left | -2.34 |
| vision_rects | inner corner | p00001 | B_open_niche | whole | right | -0.11 |
| vision_rects | inner corner | p00001 | B_open_niche | whole | bottom | +0.42 |
| vision_rects | inner corner | p00001 | B_open_niche | whole | top | +1.63 |
| vision_rects | inner corner | p00002 | C_gray_double | cut off | left | -0.31 |
| vision_rects | inner corner | p00002 | C_gray_double | cut off | top | +1.46 |
| vision_rects | inner corner | p00004 | F_glass_double | whole | left (eye-only truth) | -0.23 |
| vision_rects | inner corner | p00004 | F_glass_double | whole | right | -0.73 |
| vision_rects | inner corner | p00004 | F_glass_double | whole | bottom | +0.26 |
| vision_rects | inner corner | p00004 | F_glass_double | whole | top | +0.32 |
| vision_rects | inner corner | p00005 | F_glass_double | whole | left (eye-only truth) | -0.35 |
| vision_rects | inner corner | p00005 | F_glass_double | whole | right | -0.58 |
| vision_rects | inner corner | p00005 | F_glass_double | whole | bottom | -0.23 |
| vision_rects | inner corner | p00005 | F_glass_double | whole | top | +0.23 |
| vision_rects | inner corner | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.32 |
| vision_rects | inner corner | p00006 | F_glass_double | cut off | bottom | -1.39 |
| vision_rects | inner corner | p00006 | F_glass_double | cut off | top | +0.33 |
| vision_rects (any score) | mid-side | p00001 | C_gray_double | whole | left | -0.66 |
| vision_rects (any score) | mid-side | p00001 | C_gray_double | whole | right | +0.16 |
| vision_rects (any score) | mid-side | p00001 | C_gray_double | whole | bottom | +0.21 |
| vision_rects (any score) | mid-side | p00001 | C_gray_double | whole | top | +1.14 |
| vision_rects (any score) | mid-side | p00001 | B_open_niche | whole | left | -2.42 |
| vision_rects (any score) | mid-side | p00001 | B_open_niche | whole | right | +0.05 |
| vision_rects (any score) | mid-side | p00001 | B_open_niche | whole | bottom | +0.16 |
| vision_rects (any score) | mid-side | p00001 | B_open_niche | whole | top | +2.45 |
| vision_rects (any score) | mid-side | p00002 | C_gray_double | cut off | left | -0.89 |
| vision_rects (any score) | mid-side | p00002 | C_gray_double | cut off | top | +2.67 |
| vision_rects (any score) | mid-side | p00004 | F_glass_double | whole | left (eye-only truth) | -0.26 |
| vision_rects (any score) | mid-side | p00004 | F_glass_double | whole | right | -0.60 |
| vision_rects (any score) | mid-side | p00004 | F_glass_double | whole | bottom | +0.04 |
| vision_rects (any score) | mid-side | p00004 | F_glass_double | whole | top | +0.40 |
| vision_rects (any score) | mid-side | p00005 | F_glass_double | whole | left (eye-only truth) | -0.61 |
| vision_rects (any score) | mid-side | p00005 | F_glass_double | whole | right | -0.26 |
| vision_rects (any score) | mid-side | p00005 | F_glass_double | whole | bottom | -0.26 |
| vision_rects (any score) | mid-side | p00005 | F_glass_double | whole | top | +0.53 |
| vision_rects (any score) | mid-side | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.76 |
| vision_rects (any score) | mid-side | p00006 | F_glass_double | cut off | bottom | -1.58 |
| vision_rects (any score) | mid-side | p00006 | F_glass_double | cut off | top | +0.69 |
| vision_rects (any score) | inner corner | p00001 | C_gray_double | whole | left | -0.46 |
| vision_rects (any score) | inner corner | p00001 | C_gray_double | whole | right | -0.15 |
| vision_rects (any score) | inner corner | p00001 | C_gray_double | whole | bottom | +0.47 |
| vision_rects (any score) | inner corner | p00001 | C_gray_double | whole | top | +0.45 |
| vision_rects (any score) | inner corner | p00001 | B_open_niche | whole | left | -2.34 |
| vision_rects (any score) | inner corner | p00001 | B_open_niche | whole | right | -0.11 |
| vision_rects (any score) | inner corner | p00001 | B_open_niche | whole | bottom | +0.42 |
| vision_rects (any score) | inner corner | p00001 | B_open_niche | whole | top | +1.63 |
| vision_rects (any score) | inner corner | p00002 | C_gray_double | cut off | left | -0.31 |
| vision_rects (any score) | inner corner | p00002 | C_gray_double | cut off | top | +1.46 |
| vision_rects (any score) | inner corner | p00004 | F_glass_double | whole | left (eye-only truth) | -0.23 |
| vision_rects (any score) | inner corner | p00004 | F_glass_double | whole | right | -0.73 |
| vision_rects (any score) | inner corner | p00004 | F_glass_double | whole | bottom | +0.26 |
| vision_rects (any score) | inner corner | p00004 | F_glass_double | whole | top | +0.32 |
| vision_rects (any score) | inner corner | p00005 | F_glass_double | whole | left (eye-only truth) | -0.35 |
| vision_rects (any score) | inner corner | p00005 | F_glass_double | whole | right | -0.58 |
| vision_rects (any score) | inner corner | p00005 | F_glass_double | whole | bottom | -0.23 |
| vision_rects (any score) | inner corner | p00005 | F_glass_double | whole | top | +0.23 |
| vision_rects (any score) | inner corner | p00006 | F_glass_double | cut off | left (eye-only truth) | -0.32 |
| vision_rects (any score) | inner corner | p00006 | F_glass_double | cut off | bottom | -1.39 |
| vision_rects (any score) | inner corner | p00006 | F_glass_double | cut off | top | +0.33 |

Limits: four doors on one building, seen by a DSLR from two to four times the app's 1 to 3 m, with
laser depth that is denser and cleaner than an iPhone's LiDAR and absent on phones without it.
No windows: the electro windows are curtain-wall glazing, not house windows.
