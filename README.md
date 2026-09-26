# House scanning

We're exploring a simpler way to survey a home for a Base Power battery.

A homeowner walks the outside of their house with a phone app. The app measures the wall around the electric meter, and our code decides whether a Base Power battery can be installed there and, if so, where. The homeowner sees the spot in AR before they put the phone away.

This is a four-person hackathon project for Base Power. Success means one capture session gives Base enough to decide, with no follow-up photos. A person can still review the result.

Since 2026-09-26 the work is split between two teams. The client team builds the iPhone app, which guides the scan with a live 3D map and sends a capture packet. The server team turns the packet into a 3D model and evaluates the placement rules on it. [docs/00-overview.md](docs/00-overview.md) has the details.

## Why measure instead of photograph

Base's site survey starts from a few customer photos, and three things go wrong with them:

- Distances are estimated by eye, so borderline clearances go to a reviewer.
- Unordered photos can't show whether two things are on the same wall or how far apart they are.
- Nobody knows what sits just outside the frame, so the homeowner gets asked for more photos.

An AR session tracks the phone's position as it moves. The app can measure the wall in feet, and it knows which stretches nobody has looked at yet. It asks for those while the homeowner is still standing there.

## How it works

1. The homeowner marks the electric meter, walks the wall to its end in each direction, and takes close-ups of the meter and the electrical panel. A live 3D map on the phone shows what has been seen, and the app guides the homeowner until everything the rules need is covered. The app sends a capture packet: photos, where the camera was for each one, lens data, motion-sensor readings, LiDAR depth when the phone has it, and the homeowner's marks.
2. The server builds a 3D model from the packet and lays the walls out as one line, measured in feet from the meter. It slides the battery's footprint along that line and checks each clearance: gas equipment, driveways, doors and windows, room overhead, and the gap to a facing fence. Each check returns pass, fail, or unsure, with the measurement error counted. Anything the phone never saw counts as unsure.
3. The app shows the chosen spot, the battery, and the cable route from the meter in AR.

Plain code makes the placement decision. Models build the geometry and recognize things, such as where a gas meter is or what the meter label says. The public demo uses public rule values plus two labeled placeholders (pool 10 ft, driveway 5 ft); Base's own values load from a private file.

## What we've tested so far

The plan targets iPhones, and a LiDAR iPhone makes some measurements easier. Most homeowners don't have one, so the experiments ask how far an ordinary phone gets.

- **Can AR taps on the ground and the wall measure the wall line, the room overhead, and the gap to a fence without LiDAR?** Measure Lab (PR #7) is the test rig. A field session against a tape survey is the remaining measurement.
- **Can learned 3D models build accurate geometry from ordinary photos?** We measured MapAnything, Depth Anything 3 and MoGe against the laser-scanned buildings in the ETH3D dataset (PR #12). MapAnything's scale shifted with input resolution. A model's own scale is 4 to 12% off. Rescaled with the phone's poses, walls come within about 5 in (p90) at a realistic phone error, but edges stay at 8 in or worse. The reconstruction worker (PR #20) gets walls to 2.1 in with a laser scan standing in for LiDAR, and 2.8 in from photos only. World models are not evaluated yet.
- **How far does phone AR tracking drift during a walk?** On ADVIO's 2018 iPhone walks it ran 2 to 3 times over the server's error allowance, partly because of noise in the dataset's own reference. A current iPhone, on the MARViN dataset, stayed inside it, though that phone has LiDAR and the reference may be scaled to its tracking. The field test measures our own phone.

A convincing 3D view can still miss an obstacle or get a distance wrong, so every result keeps its original photos beside it.

## Repository map

| Path | What it is | State on 2026-09-26 |
| --- | --- | --- |
| `ios/` | The native iPhone app (Swift, ARKit, RealityKit) | On `main`: an AR session skeleton. Guided capture is in PR #10; the live 3D map is on branch `t3/ios-map3d`, stacked on it |
| `packet/` | The capture packet the app sends | Being specified on branch `t3/packet` |
| `server/` | The deterministic rules engine and API | On `main`: a skeleton. The engine is in PR #11 and runs as a public demo |
| `recon/` | A worker that turns photos and depth into a 3D model and a coverage map | Draft PR #20, handed to the server team |
| `experiments/` | One folder per experiment | Accuracy evals in PR #12, Measure Lab in PR #7 |
| `web/` | Browser toolchain for the reviewer view and zero-install capture experiments | The review page (PR #15) is parked |
| `docs/` | The overview, explainers, the day-1 plan and dated briefings | |
| `sites/landing` | The landing page, a submodule | Change it in its own repository |

The public demo server, with public rules only, is at https://house-scanning-server.vercel.app. A second deployment loads Base's rules and requires a key. TestFlight builds are started by hand; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Read next

| File | What it covers |
| --- | --- |
| [docs/how-it-works.html](docs/how-it-works.html) | A visual explainer of the current system: the two-team pipeline, error bars, coverage and the 3D path options |
| [docs/00-overview.md](docs/00-overview.md) | The goal, the team split, decisions made so far, evidence and open questions |
| [docs/01-feature-map.md](docs/01-feature-map.md) | Day-1 plan: the four work lanes, features by priority, the `scene.json` format, and the rules table |
| [docs/02-implementation-plan.md](docs/02-implementation-plan.md) | Day-1 plan: how each part gets built, the schedule, and risks |
| [docs/03-stack-research.md](docs/03-stack-research.md) | The open-source projects and libraries we build on, and the ones we skip |
| [docs/04-prior-art-and-codes.md](docs/04-prior-art-and-codes.md) | Base's public rules, similar products, and electrical-code citations |
| [docs/05-live-guided-survey-hld.md](docs/05-live-guided-survey-hld.md) | Proposed live guidance and automatic capture architecture, diagrams, evidence flow, and technical resources |
| [docs/eli5.html](docs/eli5.html) | The day-1 visual walkthrough, with an interactive demo of the placement search |

Contributors and coding agents start with [AGENTS.md](AGENTS.md). This repository is public, so materials Base gave the team stay in the git-ignored `private/` folder.
