# House scanning: overview and decisions

Hackathon project, 4-person team, started 2026-09-25. The goal: from a homeowner's phone, work out
**where a Base Power battery can be installed** against the outside of the house, and show the spot
back to them in AR.

> **This repo is public.** Materials Base gave the team live in `private/`, which is gitignored. Never commit,
> quote or summarize them here. Team-only notes are in `private/internal-notes.md`.

## The core insight (why AR)

Today homeowners submit photos and reviewers judge them. Three problems come up that ordinary photos can't solve:
1. **Measuring distance.** A single photo has no real scale, so gaps and clearances get estimated by eye, and the borderline cases go to a person.
2. **Fitting photos together.** A handful of unordered photos can't reliably say whether two things are on the same wall, or how far apart they are.
3. **Coverage.** If part of the wall wasn't photographed, nobody can say what's there, so the homeowner gets asked for more photos.

AR fixes all three. The recognition half (panel brand, meter text, rust, whether a window opens) stays with a
vision model. AR adds nothing there beyond better photos.

## Decisions made

- **AR-guided capture, not "upload a video and process it later."** Offline photogrammetry (COLMAP, splats) fails on
  blank siding and stucco, has no real scale, and is slow. ARKit already fuses the camera with the motion sensors on the phone.
- **The phone collects data; the server decides.** Swift app → zip upload → Python FastAPI server → result → AR preview.
- **The placement code is plain code, not AI.** Unroll the house walls into one straight line `s` (feet along the wall
  from the meter). Most rules become 1-D interval checks plus 2-D polygon distances. Sweep the battery footprint in small steps.
  Every check returns PASS / FAIL / UNSURE, with error bars on each measurement. See `02-implementation-plan.md`.
- **The vision model only recognises things.** Gemini boxes → SAM 2 → cast onto the wall using where the phone was.
  Recognition prompts run on the close-ups.
- **Native Swift + ARKit/RealityKit on iPhone, in `ios/`.** LiDAR is used when present, never required: most homeowners don't have it. Not Expo (no first-class ARKit), and not Android for v1.
- **Normal dev app for the hackathon; an App Clip is only the pitch's rollout story** (see the gotchas in `03-stack-research.md`).

## Corrections made after the research (supersede earlier drafts)

1. Use `worldAlignment = .gravity`, **not** `.gravityAndHeading`. The compass is unreliable near a house
   (developers report errors up to ~176°). Take one compass reading away from the meter as a rough hint. Which wall faces the
   street comes from map data: Overture building outline + osmnx nearest road.
2. **Place the battery relative to the meter's anchor**, not in raw world coordinates. ARKit corrects anchors as it goes,
   and drift is about 2 cm per second.
3. The battery is **39.5″ tall** (Base Core: 39.5 × 30.68 × 22 in), not 36″. Base's older units are 3 × 3 ft,
   so keep all dimensions in the rules config.
4. Claude is **not** the box detector; its docs say its coordinates are approximate. Gemini returns boxes natively as
   `[ymin, xmin, ymax, xmax]` on 0–1000.
5. **Never run ML on Google, Mapbox or Esri imagery.** Google's ToS §3.2.3(c) bans it outright. Use StratMap/NAIP (public domain).

## Open questions (team must decide)

- **Which clearance numbers to use.** The public baseline is Base's help page: within 20 ft of the meter, within 1 ft of the wall,
  and 3 ft from gas meters, fences, AC units and other batteries. Other numbers (driveway, pool, passage width, max cable run) are
  still TBD. The team's working notes are in `private/internal-notes.md`.
- **Whether the install includes a separate battery disconnect box** beside the meter. Base's public pages mention a wall-mounted
  transfer switch and a battery disconnect.
- **Test these in hours 0–4** (the unknowns everything depends on). See `03-stack-research.md` § Test first.

## Doc map

| File | What |
|---|---|
| `00-overview.md` | this file: goal, insight, decisions |
| `01-feature-map.md` | lanes A–D, feature list with priorities, data format, rules table |
| `02-implementation-plan.md` | how to build each part, code snippets, 24 h schedule, risks |
| `03-stack-research.md` | libraries and open-source projects per part, licenses, gotchas, what to skip |
| `04-prior-art-and-codes.md` | what Base does publicly, competitors, electrical-code citations, pitch angle |
| `05-live-guided-survey-hld.md` | live guided survey: automatic capture, coverage display, next-view planning, evidence flow |
| `eli5.html` | visual explainer for anyone new; step 4 is an interactive "slide the battery" demo |
