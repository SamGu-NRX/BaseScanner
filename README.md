# House scanning

We're exploring a simpler way to survey a home for a Base Power battery.

A homeowner walks the outside of their house with a phone app. The app measures the wall around the electric meter, and our code decides whether a Base Power battery can be installed there and, if so, where. The homeowner sees the spot in AR before they put the phone away.

This is a four-person hackathon project for Base Power. Success means one capture session gives Base enough to decide, with no follow-up photos. A person can still review the result.

## Why measure instead of photograph

Base's site survey starts from a few customer photos, and three things go wrong with them:

- Distances are estimated by eye, so borderline clearances go to a reviewer.
- Unordered photos can't show whether two things are on the same wall or how far apart they are.
- Nobody knows what sits just outside the frame, so the homeowner gets asked for more photos.

An AR session tracks the phone's position as it moves. The app can measure the wall in feet, and it knows which stretches nobody has looked at yet. It asks for those while the homeowner is still standing there.

## How it works

1. The homeowner marks the electric meter, walks the wall to its end in each direction, and takes close-ups of the meter and the electrical panel. The app saves frames along with where the camera was for each one.
2. A server lays the walls out as one line, measured in feet from the meter. It slides the battery's footprint along that line and checks each clearance: gas equipment, driveways, doors and windows, room overhead, and the gap to a facing fence. Each check returns pass, fail, or unsure, with the measurement error counted.
3. The app shows the chosen spot, the battery, and the cable route from the meter in AR.

Plain code makes the placement decision. Vision models only recognize things, such as where a gas meter is or what the meter label says. Several clearance numbers are not final. Base still has to confirm the rules for driveways, pools, the fence gap, and cable length.

## What we're testing now

The plan targets iPhones, and a LiDAR iPhone makes some measurements easier. Most homeowners don't have one, so the experiments ask how far an ordinary phone gets:

- Can AR taps on the ground and the wall measure the wall line, the room overhead, and the gap to a fence without LiDAR?
- Can learned 3D models build accurate geometry from ordinary photos? We measure MapAnything, Depth Anything 3 and MoGe against the laser-scanned buildings in the ETH3D dataset, with and without one known distance.
- How far does phone AR tracking drift during a walk? We measure it on the ADVIO dataset's iPhone walks, which have a ground-truth track, then tape-measure one real house and compare every method against the tape.

A convincing 3D view can still miss an obstacle or get a distance wrong, so every result keeps its original photos beside it.

## Read next

| File | What it covers |
| --- | --- |
| [docs/00-overview.md](docs/00-overview.md) | The goal, decisions made so far, and open questions |
| [docs/01-feature-map.md](docs/01-feature-map.md) | The four work lanes, features by priority, the `scene.json` format, and the rules table |
| [docs/02-implementation-plan.md](docs/02-implementation-plan.md) | How each part gets built, the schedule, and risks |
| [docs/03-stack-research.md](docs/03-stack-research.md) | The open-source projects and libraries we build on, and the ones we skip |
| [docs/04-prior-art-and-codes.md](docs/04-prior-art-and-codes.md) | Base's public rules, similar products, and electrical-code citations |
| [docs/05-live-guided-survey-hld.md](docs/05-live-guided-survey-hld.md) | Proposed live guidance and automatic capture architecture, diagrams, evidence flow, and technical resources |
| [docs/eli5.html](docs/eli5.html) | A visual walkthrough with an interactive demo of the placement search |

Contributors and coding agents start with [AGENTS.md](AGENTS.md). This repository is public, so materials Base gave the team stay in the git-ignored `private/` folder.
