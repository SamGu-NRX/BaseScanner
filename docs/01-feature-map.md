# Feature map

**Priority:** **P0** = needed for the demo · **P1** = strong add · **P2** = stretch
**Lanes (one teammate each):** **A** capture app · **B** object detection and geometry · **C** rules + placement code · **D** output, testing, pitch

## Hour 1: agree on the data format (everyone)

Every lane reads or writes this, so lock it first. Then all four people can work in parallel against a hand-built
`fixtures/fake-01/scene.json` until real captures exist.

```json
{
  "meter": {"pos": [x,y,z], "wall_id": "w1"},
  "walls": [{"id": "w1", "baseline": [[x,z], ...], "height_ft": 9}],
  "objects": [{"type": "window|door|garage_door|ac|gas_meter|elec_box|vent|downspout|pool",
               "wall_id": "w1", "span_ft": [a, b], "bottom_ft": 3.1, "top_ft": 6.2,
               "attrs": {"operable": true, "well": false}, "source": "vlm|tap", "conf": 0.8}],
  "ground": [{"type": "drive|concrete|gravel|lawn|mulch|deck", "polygon": [[x,z], ...]}],
  "overheads": [{"wall_id": "w1", "span_ft": [a, b], "clearance_ft": 3.0}],
  "facing": [{"wall_id": "w1", "span_ft": [a, b], "depth_ft": 4.5}],
  "keyframes": [{"id": "k1", "pose": [...16 floats, column-major cam_to_world...], "intrinsics": [fx,fy,cx,cy],
                 "w": 1920, "h": 1440, "img": "k1.jpg"}],
  "stills": {"meter_close": "...", "meter_surround": "...", "panel_wall": "...", "panel_open": "..."},
  "gps": {"lat": 0, "lon": 0}, "heading": {"deg": 0, "accuracy_deg": 0}
}
```

- `facing` is the gap from the wall straight out to the nearest fence, hedge or wall.
- `span_ft` is the stretch along the wall an item covers, in feet from the meter (negative = left of the meter).
- Keyframe images are saved **unrotated** (landscape, as the sensor reads them), so `intrinsics` apply to them directly.

## A: Capture app (Swift, ARKit/RealityKit)

| # | Feature | Pri | Notes |
|---|---|---|---|
| A1 | Tap to mark the meter → anchor | P0 | The starting point; the result is later placed relative to it |
| A2 | Guided walk left/right, tap wall ends + corners | P0 | Can't finish until both ends are tapped, so nothing goes unphotographed |
| A3 | Wall + ground detection → wall line at ground level | P0 | Real feet |
| A4 | Save frames every ~0.5 m / 15° with position + lens data | P0 | Fork Stray Scanner's recorder |
| A5 | Tap-to-mark fallback: gas meter, door, window, AC, garage, driveway edge | **P0** | The demo never depends on detection. Also gives correct answers to test against |
| A6 | Guided close-ups: meter, panel wall, open panel, disconnect | P0 | Input for the recognition checks |
| A7 | Photo checks: sharpness, meter can fully in frame, text readable on the phone (Vision) | P1 | |
| A8 | One session from the meter outside to the panel inside | P1 | Answers "same wall?" and "directly behind the meter?" exactly |
| A9 | Mesh .ply export (anchor transform applied) + zip + foreground upload | P0 | |

## B: Object detection and geometry (server)

| # | Feature | Pri | Notes |
|---|---|---|---|
| B1 | Gemini boxes for window, door, garage door, AC, gas meter, electrical box, vent | P0 | Or tap marks from A5 |
| B2 | Cast each box onto the wall using the phone's position → s-range + height | P0 | Test first: tap a point, cast it back into a saved frame, check the pixel |
| B3 | Window details: ground-level from measured height, opens vs fixed, window well | P1 | |
| B4 | Passage width (wall out to the nearest fence/hedge) from mesh rays | P1 | LiDAR only; otherwise UNSURE |
| B5 | Overhead headroom (porch, eave, stairs) from mesh rays | P1 | LiDAR only |
| B6 | Ground surfaces + whether they connect to the driveway | P2 | Hardest. Demo uses a tapped driveway edge |
| B7 | Pool + pool-equipment detection | P2 | Also from the aerial photos |
| B8 | Street-facing wall from Overture outline + osmnx road (flag for homeowner approval of the look) | P2 | |

## C: Rules + placement code

| # | Feature | Pri | Notes |
|---|---|---|---|
| C1 | `rules.yaml`: every number, per-utility overrides (ComEd), a source per rule: code citation, Base's public help page, or a labeled demo placeholder | P0 | No hardcoded distances in the code |
| C2 | Sweep the 31″ × 22″ footprint along the unrolled wall, 2″ steps | P0 | |
| C3 | Clearance checks: gas, driveway, pool, openings, box above, vent, AC, passage width, headroom, ground | P0 | PASS / FAIL / UNSURE with error bars |
| C4 | Cable route along the wall: blocked by door, garage or a stretch with no wall; length ≤ max | P0 | |
| C5 | Result: pass / manual_review / reject + reasons + photos still needed | P0 | |
| C6 | Rank the valid spots: shortest run, prefer side walls | P1 | |
| C7 | Check the disconnect box's wall space + conduit route | P2 | Only if the current product still uses it |

## D: Output, testing, pitch

| # | Feature | Pri | Notes |
|---|---|---|---|
| D1 | AR preview: RealityKit box attached to the meter's anchor + cable line | P0 | The demo moment |
| D2 | 2D site plan (drawsvg): blue meter area, purple cable, red battery spot | P0 | |
| D3 | Tape-measure one real house: AR vs depth model vs the vision model's guesses | **P0** | The pitch's headline number |
| D4 | Baseline: Depth Anything 3 metric on plain photos | P1 | |
| D5 | Recognition prompts on the close-ups (prompts stay in `private/`) | P1 | |
| D6 | Meter type from the can's real height in inches | P2 | |
| D7 | Reviewer web view / JSON report | P2 | |

## Rules table (C1): CONFIRM THESE

Public sources only. The team's working numbers are in `private/internal-notes.md` (gitignored).

| Rule | Public source | Value | Use |
|---|---|---|---|
| Distance from meter | Base help page | within 20 ft | 20 ft, TBD |
| Distance from wall | Base help page | within 1 ft | 1 ft |
| Gas meter / regulator | Base help page; Austin Energy §1.9; Texas Gas Service | 3 ft | 3 ft |
| AC units, fences, other batteries | Base help page | 3 ft | 3 ft |
| Doors and windows | IRC R328 (batteries); Austin Energy §1.9.2 (meters, ≥ 1 ft) | 3 ft | 3 ft |
| Working space at meter / panel | NEC 110.26 | 30″ wide × 36″ deep × 6.5 ft headroom | as listed |
| Driveway | — | — | **TBD** |
| Pool | — | — | **TBD** |
| Passage width (wall to fence) | — | — | **TBD** |
| Battery footprint | Base Core spec | 39.5″ × 30.68″ × 22″ (older units 3 × 3 ft) | per model |

## Not doing

Android, Expo, rebuilding a 3D model from uploaded video, full-house or roof scans.
