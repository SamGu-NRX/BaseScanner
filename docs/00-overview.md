# House scanning: system overview

Current as of 2026-09-26 midday. Where this file and the day-1 plan (`01` to `05`) disagree, this file wins. Where this file and a component's README disagree, the README wins.

## The problem

Base Power installs a home battery on the outside wall, close to the electric meter, because a cable runs from the meter to the battery. The battery is 31 in wide, 22 in deep and 39.5 in tall. Whether it fits depends on clearance rules: distance from the gas meter, from doors and windows, from AC units and fences, clear space in front, headroom above, and cable length from the meter. Today someone judges that from a few customer photos, and three things go wrong:

- A photo has no scale, so distances are guessed and borderline cases go to a reviewer.
- Loose photos can't show whether two things are on the same wall or how far apart they are.
- Nobody knows what sits just outside the frame, so the homeowner gets asked for more photos.

## The product

A homeowner scans the outside of the house around the meter with an iPhone. The system works out whether the battery fits and where, and the app shows the spot in AR on the real wall. One scan should give Base enough to decide without follow-up photos.

The MVP is three problems:

1. A phone with a live camera feed that routes the homeowner until everything the model needs is captured.
2. Photos and their metadata turned into a 3D model.
3. The 3D model evaluated against the placement criteria.

## How it fits together

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

**Client team.** Sam, working with AI agents, builds the iOS app. Aiden films video and gathers sample datasets. The app guides capture with a live on-device 3D map, and a haze ("fog of war") covers what the phone hasn't seen yet. Coverage aims at 100% of what the model needs, not the whole house. The app uses LiDAR and other depth sensors first when the phone has them, and the path without LiDAR is built alongside. Guided capture is in PR #10; the live 3D map is on branch `t3/ios-map3d`, stacked on it.

The app's output is the **capture packet**: photos, camera poses (where the camera was and which way it pointed), intrinsics (the lens's focal length and center), motion-sensor (IMU) readings, LiDAR depth and mesh when present, and the homeowner's marks such as the meter. It is being specified on branch `t3/packet`.

**Server team.** Hunter, working with his own agents, takes the packet and builds a 3D model or point cloud, then evaluates the criteria on it. They are comparing world models with traditional and newer reconstruction methods: first broadly, then in depth on the most promising paths. Their starting points:

- `server/` (PR #11): the deterministic rules engine and API. It runs as a public demo at https://house-scanning-server.vercel.app, and a second deployment loads Base's rules behind a key.
- `recon/` (draft PR #20): a working reconstruction worker. It fuses depth into a 3D model and tests coverage against it.
- `experiments/evals/` (PR #12): accuracy evals on public datasets with laser-scanned ground truth.

## Decided

- **Native iOS only**, in `ios/`: Swift, ARKit and RealityKit. Expo has no first-class ARKit support.
- **LiDAR first, never required.** Use depth sensors when present; most homeowners' phones lack LiDAR, so every check must also work without it.
- **Deterministic placement decisions.** Models build the geometry and recognize things. The pass or fail decision is plain code over that geometry, with each clearance number and its source in a rules file.
- **Error bars decide.** A check passes only when its margin beats the measurement error, fails only when it misses by more than the error, and is UNSURE otherwise.
- **Unseen is never clear.** A check whose area nobody observed is UNSURE, and the server names the view that would settle it.
- **AR results are placed relative to the meter's anchor**, with `.gravity` world alignment.

## What the evidence says so far

All numbers come from public datasets with laser-scanned ground truth. Sources are `experiments/evals/README.md` (PR #12) and `recon/HANDOFF.md` (PR #20).

- A depth model's own scale is 4 to 12% wrong.
- Rescaled with the phone's poses, learned depth gets walls to about 5 in at p90 (9 in 10 points are closer) at a realistic phone error. Edges come out at 8 in or worse, and clearances are measured from edges.
- The recon worker on the ETH3D building gets walls to p90 2.1 in with a laser scan standing in for LiDAR, and 2.8 in from photos only.
- Coverage tested against depth claims at most about 0.46 ft of wall that no photo saw.
- A current iPhone's tracking stays within the server's error allowance.
- World models have not been evaluated yet.

So learned depth alone is too rough for edge clearances. 3D modeling stays central, with LiDAR and the phone's poses supplying metric scale.

## Open

- **Which 3D path.** Candidates are traditional reconstruction fused with LiDAR, learned depth rescaled with the phone's poses, and world models (large learned models that produce a whole 3D scene from photos or video). The server team decides after evaluating them. Whichever path wins needs metric scale, edges within the error allowance, and an honest account of which parts it observed and which it filled in.
- **Real-phone accuracy.** The numbers above come from public datasets. A field session with a tape survey on a real wall measures our own phone.
- **Base's rules.** The public demo runs on public values plus labeled placeholders. Base's own values load only from the private rules file.

## Where each component's truth lives

| Component | Source of truth |
| --- | --- |
| iOS app | `ios/README.md` |
| Capture packet | `packet/README.md` (coming on branch `t3/packet`) |
| Rules engine, API, capture contract | `server/README.md` (PR #11), "What settles each check" |
| Reconstruction worker | `recon/HANDOFF.md` (PR #20) |
| Evals | `experiments/evals/README.md` (PR #12) |
| Agent rules | `AGENTS.md` |

The day-1 plan in `01` to `05` is kept for its reasoning and citations; the server's rule citations point at the rules table in `01-feature-map.md`. `docs/briefings/` holds dated team briefings. The web review page (PR #15) is parked.
