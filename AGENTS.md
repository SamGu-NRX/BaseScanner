# House scanning: agent guide

Hackathon project (4-person team, started 2026-09-25). Homeowners walk the outside of their house with an iPhone.
The AR session measures the wall, a server works out where a **Base Power battery** can be installed, and the spot
is shown back in AR.

## Read before doing anything non-trivial

1. `docs/00-overview.md`: goal, the core insight, decisions made, **corrections that supersede earlier drafts**, open questions.
2. `docs/01-feature-map.md`: lanes A–D, features with priorities, the `scene.json` data format, the **rules table (numbers still TBD)**.
3. `docs/02-implementation-plan.md`: how each part gets built, code snippets, schedule, risks.
4. `docs/03-stack-research.md`: which library or open-source project for each part, licenses, gotchas, what to skip.
5. `docs/04-prior-art-and-codes.md`: Base's public rules, competitors, NEC / IRC / Austin Energy citations, pitch angle.
6. `docs/eli5.html`: a visual explainer to open in a browser. Step 4 is an interactive demo of how the solver works.

## Hard rules

- **This repo is PUBLIC.** `private/` holds materials Base gave the team and is gitignored. Never commit, quote or summarize them
  in tracked files: prompt text, prompt names, output field names, internal thresholds. Team notes go in `private/internal-notes.md`.
- **The placement decision is plain code, not AI.** Vision models only recognise things (object boxes, panel brand, meter text).
  Every clearance number lives in `rules.yaml` with a code citation, never hardcoded.
- **Never run ML on Google Maps/Street View, Mapbox or Esri imagery.** Their terms forbid it. Use StratMap/NAIP.
- **Place AR results relative to the meter's anchor**, not in raw world coordinates. Use `.gravity` world alignment, not `.gravityAndHeading`.
- The camera image is landscape and the intrinsics match it. Rotate one and you must rotate the other.

## ⚠️ Open conflict: native Swift vs Expo

The research plan (`docs/00-overview.md`) chose **native Swift + ARKit/RealityKit**. Expo has no first-class ARKit support,
and the capture needs LiDAR mesh export, per-frame position and lens data, and mesh raycasts.
On 2026-09-25 an Expo app was scaffolded at `apps/mobile/` (Expo SDK 57). **The team hasn't decided yet.**
Options: (a) drop Expo for native Swift; (b) Expo shell + a custom native Swift module for the whole AR capture;
(c) Expo for the non-AR screens only. Don't build AR capture in either place until the team picks one.

`apps/mobile/AGENTS.md` has the Expo-specific rules for that folder.
