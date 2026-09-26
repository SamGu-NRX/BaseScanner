Swept photos: 71; degraded reads: 3309.

### Read rate by degradation level

**Gaussian blur, σ as a fraction of the number's line height**

| Level | 0.02 | 0.04 | 0.06 | 0.08 | 0.1 | 0.13 | 0.16 | 0.2 | 0.25 | 0.3 |
|---|---|---|---|---|---|---|---|---|---|---|
| Read correctly (photos) | 99% (71) | 94% (71) | 85% (71) | 68% (71) | 38% (71) | 4% (71) | 0% (71) | 0% (71) | 0% (71) | 0% (71) |

**Horizontal motion blur, streak length as a fraction of line height**

| Level | 0.05 | 0.1 | 0.15 | 0.2 | 0.3 | 0.4 | 0.5 | 0.7 | 1 |
|---|---|---|---|---|---|---|---|---|---|
| Read correctly (photos) | 99% (71) | 96% (71) | 94% (71) | 93% (71) | 69% (71) | 39% (71) | 10% (71) | 0% (71) | 0% (71) |

**Downscaled so the number's line is this many pixels tall**

| Level | 48 | 40 | 32 | 26 | 22 | 18 | 15 | 12 | 10 | 8 | 6 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Read correctly (photos) | 96% (57) | 95% (64) | 93% (69) | 94% (70) | 93% (70) | 94% (71) | 96% (71) | 77% (71) | 61% (71) | 30% (71) | 6% (71) |

**White glare patch on the number, peak opacity**

| Level | 0.3 | 0.5 | 0.7 | 0.85 | 1 | 1.5 | 2.5 | 4 |
|---|---|---|---|---|---|---|---|---|
| Read correctly (photos) | 99% (71) | 97% (71) | 97% (71) | 97% (71) | 23% (71) | 4% (71) | 4% (71) | 4% (71) |

**Right frame edge this many line heights past the number (negative cuts it)**

| Level | 2 | 1 | 0.5 | 0.25 | 0.1 | 0 | -0.5 | -1 | -2 |
|---|---|---|---|---|---|---|---|---|---|
| Read correctly (photos) | 100% (70) | 96% (70) | 99% (71) | 97% (71) | 99% (71) | 100% (71) | 17% (71) | 14% (71) | 13% (70) |

### Retake thresholds from each photo's break point

| Degradation | Check | Retake when (95% of photos) | Retake when (80%) | Median break | AUC |
|---|---|---|---|---|---|
| blur | degradation level (σ / line height) | ≥ 0.06 | ≥ 0.08 | 0.1 | – |
| blur | label sharpness, resized to a 32 px line | ≤ 39.1 | ≤ 4.92 | 1.99 | 0.96 |
| blur | label sharpness at native size | ≤ 4.88 | ≤ 2.31 | 1.64 | 0.87 |
| blur | detected-line sharpness, 32 px line | ≤ 338 | ≤ 25.1 | 1.94 | 0.95 |
| blur | whole-photo sharpness at 1024 px | ≤ 6.63 | ≤ 2.89 | 1.31 | 0.96 |
| motion | degradation level (streak / line height) | ≥ 0.3 | ≥ 0.3 | 0.4 | – |
| motion | label sharpness, resized to a 32 px line | ≤ 701 | ≤ 320 | 132 | 0.69 |
| motion | label sharpness at native size | ≤ 208 | ≤ 110 | 29.3 | 0.70 |
| motion | detected-line sharpness, 32 px line | ≤ 721 | ≤ 369 | 111 | 0.85 |
| motion | whole-photo sharpness at 1024 px | ≤ 190 | ≤ 107 | 52.4 | 0.75 |
| scale | degradation level (line height px) | ≤ 12 | ≤ 10 | 8 | – |
| scale | label line height in pixels | ≤ 12 | ≤ 10 | 8 | 0.88 |
| scale | detected-line height in pixels | ≤ 38 | ≤ 17.9 | 9.94 | 0.88 |
| glare | degradation level (peak opacity) | ≥ 1 | ≥ 1 | 1 | – |
| glare | label RMS contrast | ≤ 0.156 | ≤ 0.14 | 0.104 | 0.83 |
| glare | label share of pixels ≥ 250 | ≥ 0.0729 | ≥ 0.133 | 0.242 | 0.95 |
| glare | detected-line RMS contrast | ≤ 0.215 | ≤ 0.189 | 0.142 | 0.48 |
| glare | whole-photo share of pixels ≥ 250 | ≥ 0.0009 | ≥ 0.0025 | 0.00915 | 0.85 |
| edge | degradation level (line heights) | ≤ -0.5 | ≤ -0.5 | -0.5 | – |
| edge | label gap to the frame edge, in line heights | ≤ 0 | ≤ 0 | 0 | 0.90 |
| edge | detected-line gap to the frame edge, in line heights | ≤ 3.03 | ≤ 1.14 | 0.212 | 0.61 |

- blur: 71 photos, 0 never broke; 2 of 277 reads above the break failed anyway (0.7%).
- motion: 71 photos, 0 never broke; 6 of 361 reads above the break failed anyway (1.7%).
- scale: 71 photos, 4 never broke; 15 of 584 reads above the break failed anyway (2.6%).
- glare: 71 photos, 3 never broke; 3 of 305 reads above the break failed anyway (1.0%).
- edge: 71 photos, 9 never broke; 9 of 457 reads above the break failed anyway (2.0%).

### Real photos that read correctly but a threshold would reject

| Check | Rejected at the 95% threshold | Rejected at the 80% threshold |
|---|---|---|
| label sharpness, resized to a 32 px line (blur) | 0/75 | 0/75 |
| label sharpness at native size (blur) | 0/75 | 0/75 |
| detected-line sharpness, 32 px line (blur) | 14/75 | 1/75 |
| whole-photo sharpness at 1024 px (blur) | 0/75 | 0/75 |
| label sharpness, resized to a 32 px line (motion) | 32/75 | 14/75 |
| label sharpness at native size (motion) | 27/75 | 13/75 |
| detected-line sharpness, 32 px line (motion) | 37/75 | 15/75 |
| whole-photo sharpness at 1024 px (motion) | 21/75 | 8/75 |
| label line height in pixels (scale) | 0/75 | 0/75 |
| detected-line height in pixels (scale) | 1/75 | 0/75 |
| label RMS contrast (glare) | 31/75 | 27/75 |
| label share of pixels ≥ 250 (glare) | 2/75 | 2/75 |
| detected-line RMS contrast (glare) | 61/75 | 54/75 |
| whole-photo share of pixels ≥ 250 (glare) | 47/75 | 37/75 |

### Second pass on failed reads

| Degradation | Failed reads | Crop re-read recovers | Crop 2x re-read recovers | Either |
|---|---|---|---|---|
| blur | 435 | 8 (2%) | 6 (1%) | 9 (2%) |
| motion | 284 | 5 (2%) | 5 (2%) | 7 (2%) |
| scale | 187 | 12 (6%) | 22 (12%) | 23 (12%) |
| glare | 266 | 6 (2%) | 9 (3%) | 9 (3%) |
| edge | 188 | 4 (2%) | 6 (3%) | 6 (3%) |
