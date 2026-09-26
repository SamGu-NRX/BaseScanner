# House scanning

A homeowner scans the outside of their house around the electric meter with an iPhone. The system works out whether a Base Power battery fits there and where, and the app shows the spot in AR. It is a hackathon project for Base Power.

The work splits in two. The client team builds the iPhone app, which guides the scan with a live 3D map and sends a capture packet. The server team turns the packet into a 3D model and evaluates the placement rules on it. [docs/00-overview.md](docs/00-overview.md) explains the whole system.

## Repository map

| Path | What it is | State on 2026-09-26 |
| --- | --- | --- |
| `ios/` | The native iPhone app (Swift, ARKit, RealityKit) | On `main`: an AR session skeleton. Guided capture is in PR #10; the live 3D map is on branch `t3/ios-map3d`, stacked on it |
| `packet/` | The capture packet: photos, poses, intrinsics, motion data, LiDAR depth and mesh, the homeowner's marks | Being specified on branch `t3/packet` |
| `server/` | The deterministic rules engine and API | On `main`: a skeleton. The engine is in PR #11 and runs as a public demo |
| `recon/` | A worker that turns photos and depth into a 3D model and a coverage map | Draft PR #20, handed to the server team |
| `experiments/` | One folder per experiment | Accuracy evals on public datasets in PR #12 |
| `web/` | Browser toolchain | The review page (PR #15) is parked |
| `docs/` | The overview, a visual explainer, the day-1 plan and dated briefings | |
| `sites/landing` | The landing page, a submodule | Change it in its own repository |

## What's live

- The public demo server, with public rules only: https://house-scanning-server.vercel.app. A second deployment loads Base's rules and requires a key.
- A TestFlight workflow, started by hand. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Where to start

- New to the project: [docs/eli5.html](docs/eli5.html), a picture-first explainer. Open it in a browser.
- Contributors and coding agents: [AGENTS.md](AGENTS.md), then [CONTRIBUTING.md](CONTRIBUTING.md).

This repository is public. Materials Base gave the team stay in the git-ignored `private/` folder.
