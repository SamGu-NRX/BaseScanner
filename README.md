# House scanning

A homeowner walks the outside wall around their electric meter with an iPhone. The app guides the scan until it has seen everything the placement rules need, and sends what it captured. The server builds a 3D model, decides in plain code whether a Base Power battery fits and where, and the app shows the spot in AR.

This is a four-person hackathon project for Base Power, started 2026-09-25. Success means one capture session gives Base enough to decide, with no follow-up photos.

Two teams share the work. The client team (Sam with AI agents; Aiden on video and sample data) builds the iPhone app and the capture packet it sends. The server team (Hunter with his agents) turns the packet into a 3D model and checks the rules on it.

## Where to start

| Read | For |
| --- | --- |
| [docs/how-it-works.html](docs/how-it-works.html) | A picture-first walkthrough of the system, about fifteen minutes |
| [docs/00-overview.md](docs/00-overview.md) | The plan, the decisions and their reasons, the evidence so far, and open questions |
| [AGENTS.md](AGENTS.md) | The rules for anyone changing this repository, person or agent |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branches, CI checks and TestFlight |

## Repository map

Paths marked with a pull request exist only on that branch until it merges.

| Path | What it is | State |
| --- | --- | --- |
| `ios/` | The iPhone app (Swift, ARKit, RealityKit) | On `main`, an AR session that shows tracking. Guided capture is in PR #10; the live 3D map is in PR #21 |
| `packet/` | The capture packet's spec, validator and samples | PR #22 |
| `server/` | The rules engine and placement API (Python, uv) | On `main`, a skeleton. The engine is in PR #11 |
| `recon/` | Turns photos and depth into a 3D model and a coverage map | PR #20, handed to the server team |
| `experiments/` | One folder per experiment | Accuracy evals in PR #12, Measure Lab in PR #7, meter reading in PR #16 |
| `web/` | Browser toolchain for a reviewer view | The review page (PR #15) is parked |
| `docs/` | The overview, the walkthrough, public rules and code citations, and the live-survey design | |
| `sites/landing` | The landing page, a submodule | Change it in its own repository |

## What's live

- The demo server at https://house-scanning-server.vercel.app runs the engine from PR #11 with public rules only, and every answer says so. `GET /health` shows which rules are loaded. A second deployment loads Base's rules and requires a key.
- TestFlight builds of the app and Measure Lab start by hand from the Actions tab; see [CONTRIBUTING.md](CONTRIBUTING.md).
- `make check` runs the server, web and iOS suites that CI runs.

This repository is public. Materials Base gave the team stay in the git-ignored `private/` folder, and photos of real homes never enter git.
