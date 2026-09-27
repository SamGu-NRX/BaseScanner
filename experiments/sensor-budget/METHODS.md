# Sensor budget: methods and full results

The README is the front door. This file keeps the method as it was pre-registered in 397507f, and the full result as the run reported it.

## Question

Some candidate signals can't be tested on data we have: dual-camera disparity, focus distance, barometer, ultra-wideband ranging to a second phone, known-size objects (meter cover, brick courses, siding, a Letter sheet), measuring both ends of a span in one photo, and the 4032 × 3024 still. What error does physics allow each one at the range it would be used? Each gets a formula, parameters at the optimistic and conservative ends of published values, and a Monte Carlo where the parts combine non-linearly.

## Pass criteria, fixed before the run

- **Worth a device test:** with conservative parameters, p90 error at the operating range is at most 2 in for a position or length, or at most 1% for a scale.
- **Drop:** even optimistic parameters exceed 4 in, or 3% for a scale.
- **In between:** listed with the parameter that decides it.

## Result

[results/budget.md](results/budget.md) has every formula, parameter and source.

- **Drop** (optimistic p90 over 4 in or 3%):
  - dual-camera disparity, 4 to 42 in per pixel at 2.5 m, and Apple labels it relative depth;
  - focus distance, 8 to 37 in;
  - the barometer, 5 to 34 in on a height;
  - a meter cover whose maker is unknown, 4.8% (covers run 6.29 to 6.95 in).
- **Worth a device test:**
  - an ID-1 card or a Letter sheet at the meter, 1% or better;
  - one photo holding both ends of a 6 ft span on a LiDAR phone, 0.5 to 1.3 in;
  - the phone pressed to a corner as a probe, 0.3 to 1.9 in, which hinges on tracking while the camera faces the wall;
  - a tap snapped to an image edge. This passes only on localization noise. Snapping to the wrong edge is the real risk, and edge-geometry's snap test couldn't measure it.
- **In between, and the parameter that decides each:**
  - UWB needs σ ≤ 3 cm;
  - one photo without LiDAR needs ARKit scale within 1%;
  - brick, the door and a meter whose maker is read from the nameplate need their tolerance confirmed;
  - acoustic echo needs outdoor range noise.
  - The app's one-normal wall plane gives 3.1 to 9.8 in for an edge 6 ft away seen 35° off face-on. Its yaw range was updated after the run from edge-geometry's measured proxy. It had assumed 1 to 5°.

A scale reference at the meter corrects ARKit only near the meter. Drift anatomy found scale wandering about 1 to 2% within a walk.

**Run:** `uv run python budget.py`. It needs no data.

**What it changes:** there are no new sensors to build. The candidates are a card at the meter, a wider photo, and fixing the wall plane.
