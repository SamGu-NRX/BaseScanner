# House scanning: overview and decisions

Hackathon project, 4-person team, started 2026-09-25. The goal: from a homeowner's phone, work out
**where a Base Power battery can be installed** against the outside of the house, and show the spot
back to them in AR. Updated 2026-09-26 midday for the team split; where this file and a component's README disagree, the README wins.

> **This repo is public.** Materials Base gave the team live in `private/`, which is gitignored. Never commit,
> quote or summarize them here. Team-only notes are in `private/internal-notes.md`.

The MVP is three problems:

1. A phone with a live camera feed that routes the homeowner until everything the model needs is captured.
2. Photos and their metadata turned into a 3D model.
3. The 3D model evaluated against the placement criteria.

## The core insight (why AR)

Today homeowners submit photos and reviewers judge them. Three problems come up that ordinary photos can't solve:
1. **Measuring distance.** A single photo has no real scale, so gaps and clearances get estimated by eye, and the borderline cases go to a person.
2. **Fitting photos together.** A handful of unordered photos can't reliably say whether two things are on the same wall, or how far apart they are.
3. **Coverage.** If part of the wall wasn't photographed, nobody can say what's there, so the homeowner gets asked for more photos.

AR capture fixes all three: the phone's tracking and depth give every photo a known position and a real scale, which a 3D
model can build on, and the app knows what it hasn't seen yet. The recognition half (panel brand, meter text, rust, whether
a window opens) stays with a vision model. AR adds nothing there beyond better photos.

## Two teams (since 2026-09-26)

```
 client team (iPhone)                              server team
 ┌──────────────────────────┐   capture packet   ┌──────────────────────────┐
 │ guided scan              │ ─────────────────▶ │ 3D model or point cloud  │
 │ live 3D map, fog of war  │                    │           │              │
 │                          │                    │           ▼              │
 │ battery spot in AR       │ ◀───────────────── │ criteria: PASS/FAIL/     │
 │ (placed from the meter)  │      answer        │ UNSURE per check         │
 └──────────────────────────┘                    └──────────────────────────┘
```

- **Client team:** Sam with AI agents; Aiden films video and gathers sample datasets. The iOS app guides capture with a live
  on-device 3D map, and a haze ("fog of war") covers what the phone hasn't seen. Coverage aims at 100% of what the model needs,
  not the whole house. LiDAR and other depth sensors come first when present; the non-LiDAR path is built alongside. Guided capture
  is in PR #10; the live 3D map is on branch `t3/ios-map3d`, stacked on it. The output is the **capture packet**: photos, camera
  poses, intrinsics, IMU readings, LiDAR depth and mesh when present, and the homeowner's marks. It is being specified on branch `t3/packet`.
- **Server team:** Hunter with his agents. Packet in, a 3D model or point cloud out, then the criteria evaluated on it. They are
  comparing world models with traditional and newer reconstruction methods, broadly first, then in depth on the best paths.
  Starting points: `server/` (PR #11), the deterministic rules engine and API, live as a public demo at
  https://house-scanning-server.vercel.app plus a private deployment with Base's rules behind a key; `recon/` (draft PR #20),
  a working reconstruction worker; and the evals in `experiments/evals/` (PR #12).

## Decisions made

- **AR-guided capture, not "upload a video and process it later."** Offline photogrammetry alone (COLMAP, splats) struggles on
  blank siding and stucco, has no real scale, and is slow. ARKit already fuses the camera with the motion sensors on the phone,
  and the capture packet carries those poses and any LiDAR depth, so the server's 3D model starts at real scale.
- **The phone collects data; the server decides.** Swift app → capture packet → Python FastAPI server (3D model, then rule checks)
  → result → AR preview.
- **The placement code is plain code, not AI.** Models build the geometry and recognize things; the decision is ordinary code
  over that geometry. Today's rules engine (PR #11) unrolls the house walls into one straight line `s` (feet along the wall
  from the meter). Most rules become 1-D interval checks plus 2-D polygon distances. Sweep the battery footprint in small steps.
  Every check returns PASS / FAIL / UNSURE, with error bars on each measurement. See `02-implementation-plan.md`.
- **Unseen is never clear.** A check whose area nobody observed is UNSURE, and the server names the view that would settle it.
- **The vision model only recognises things.** Day-1 plan: Gemini boxes → SAM 2 → cast onto the wall using where the phone was.
  Recognition prompts run on the close-ups.
- **Native Swift + ARKit/RealityKit on iPhone, in `ios/`.** iOS only. LiDAR is used when present, never required: most homeowners
  don't have it. Not Expo (no first-class ARKit), and not Android.
- **3D modeling stays central.** Learned depth alone is too rough at edges, so LiDAR and the phone's poses supply the scale. See
  the evidence below.
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
6. **3D modeling is not ruled out** (2026-09-26). The morning briefing's Finding 2 first said "no photo-to-3D measurement pipeline".
   The evidence says learned depth *alone* is too rough; with LiDAR or the phone's poses supplying scale, a 3D model is the plan.

## Evidence so far (2026-09-26)

From public datasets with laser-scanned ground truth. Sources: `experiments/evals/README.md` (PR #12) and `recon/HANDOFF.md` (PR #20).

- A depth model's own scale is 4 to 12% wrong.
- Rescaled with the phone's poses, learned depth gets walls to about 5 in at p90 at a realistic phone error. Edges come out at
  8 in or worse, and clearances are measured from edges.
- The recon worker on the ETH3D building gets walls to p90 2.1 in with a laser scan standing in for LiDAR, and 2.8 in from photos only.
- Coverage tested against depth claims at most about 0.46 ft of wall that no photo saw.
- A current iPhone's tracking stays within the server's error allowance.
- World models have not been evaluated yet; the server team will.

## Open questions (team must decide)

- **Which clearance numbers to use.** The public baseline is Base's help page: within 20 ft of the meter, within 1 ft of the wall,
  and 3 ft from gas meters, fences, AC units and other batteries. The public demo fills the gaps with labeled placeholders
  (pool 10 ft, driveway 5 ft) in `server/rules.yaml` (PR #11). Base's own values load from the git-ignored private rules file.
  The team's working notes are in `private/internal-notes.md`.
- **Whether the install includes a separate battery disconnect box** beside the meter. Base's public pages mention a wall-mounted
  transfer switch and a battery disconnect.
- **Which 3D path.** Traditional reconstruction fused with LiDAR, learned depth rescaled with the phone's poses, or world models
  (large learned models that produce a whole 3D scene from photos or video). Whichever wins needs real scale, edges within the
  error allowance, and an honest account of which parts it observed and which it filled in.
- **Real-phone accuracy.** The evidence above comes from public datasets. A field session with a tape survey on a real wall
  measures our own phone.
- **The day-1 "test first" list** in `03-stack-research.md`: LiDAR on siding in midday sun, tap-to-pixel orientation,
  Gemini boxes on real photos, and compass accuracy at the meter. Check which the experiments have answered before relying on one.

## Doc map

| File | What |
|---|---|
| `00-overview.md` | this file: goal, insight, team split, decisions, evidence |
| `how-it-works.html` | the current visual explainer: the two-team pipeline, error bars, coverage, the 3D path options |
| `01-feature-map.md` | day-1 plan: lanes A–D, feature list with priorities, data format, rules table |
| `02-implementation-plan.md` | day-1 plan: how to build each part, code snippets, 24 h schedule, risks |
| `03-stack-research.md` | libraries and open-source projects per part, licenses, gotchas, what to skip |
| `04-prior-art-and-codes.md` | what Base does publicly, competitors, electrical-code citations, pitch angle |
| `05-live-guided-survey-hld.md` | live guided survey: automatic capture, coverage display, next-view planning, evidence flow |
| `eli5.html` | the day-1 visual explainer; step 4 is an interactive "slide the battery" demo that predates error bars |
| `briefings/` | dated team briefings |

Each component's own README is its source of truth: `ios/README.md`; `server/README.md` (PR #11), especially "What settles
each check"; `recon/HANDOFF.md` (PR #20); `experiments/evals/README.md` (PR #12); and `packet/README.md` (coming on branch
`t3/packet`). The web review page (PR #15) is parked.
