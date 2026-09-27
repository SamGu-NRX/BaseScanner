# House scanning

Walk one wall with an iPhone. Find out whether a home battery fits, and where.

[Live site](https://house-scanning.vercel.app/) · [How it works](docs/how-it-works.html) · [Demo API](https://house-scanning-server.vercel.app/health)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/readme/pipeline-dark.gif">
  <img alt="Five steps arrive left to right: walk and mark, the capture packet, the placement rules, a spot or one more view, and the result in AR. A dashed loop runs from the fourth step back to the first." src="docs/readme/pipeline-light.gif" width="100%">
</picture>

Today a person at Base Power decides where a battery goes by looking at a homeowner's photos. Photos have no scale, and they miss whatever sits just out of frame, so the answer often waits on another round of pictures.

We're trying to make it one walk. The homeowner scans the outside wall around their electric meter. The app guides them until it has seen everything the placement rules need, then sends what it captured. The server builds a 3D model, decides in plain code whether a battery fits and where, and the app shows the spot in AR.

This is a four-person hackathon project for Base Power, started 2026-09-25. Sam, with AI agents, builds the iPhone app, and Aiden films video and gathers sample data. Hunter, with his own agents, owns the 3D model and the rule checks.

## Quick start

You need [uv](https://docs.astral.sh/uv/), Node 24 with pnpm, and Xcode 26 or newer.

```bash
git clone --recurse-submodules https://github.com/SamGu-NRX/house-scanning-master.git
cd house-scanning-master
make check
```

`make check` runs the server, web and iOS suites that CI runs. On a machine without Xcode, run `make server web`.

No setup at all? The demo server is live:

```bash
curl -s https://house-scanning-server.vercel.app/health
```

## How it fits together

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 480, "nodeSpacing": 40, "rankSpacing": 50}}}%%
flowchart TB
  subgraph phone["iPhone app · ios/ · Swift, ARKit, RealityKit"]
    direction TB
    walk["<b>Guided walk</b><br/>ARKit tracks the phone. The homeowner taps the meter<br/>and marks gas meters, doors, windows and AC units.<br/>Haze lifts wherever the camera has seen."]
    packet["<b>Capture packet</b><br/>Keyframe photos, poses, intrinsics, motion data,<br/>LiDAR depth when the phone has it, and <code>scene.json</code>"]
    walk --> packet
  end

  subgraph srv["Server · Python"]
    direction TB
    recon["<b>Reconstruction worker</b> · recon/<br/>MoGe-2 depth scaled with the ARKit poses, or LiDAR.<br/>Fits the wall and ground, and records what was seen."]
    api["<b>Placement API</b> · server/ · FastAPI<br/><code>POST /v1/placements</code>"]
    rules["<b>Rules engine</b><br/>Plain code tries every spot along the wall against<br/><code>rules.yaml</code>, where every value cites its source.<br/>Each check returns PASS, FAIL or UNSURE."]
    recon -- "rebuilt scene.json" --> api
    api --> rules
  end

  result["<b>Result in AR</b> · back on the phone<br/>The spot, pinned to the meter's anchor, with each check's reason.<br/>An installer reviews every result."]

  packet -- "scene.json" --> api
  packet -. "photos and poses" .-> recon
  rules -- "spot, or views needed" --> result
  result -. "UNSURE: one more view" .-> walk
```

Models build the geometry and recognize things. Plain code passes or fails each check, so every answer points back to a rule and a measurement. The clearance numbers live in a rules file with their sources, never in code.

| Part | Built with | Where |
| --- | --- | --- |
| iPhone app | Swift 6, SwiftUI, ARKit, RealityKit, XcodeGen | `ios/` |
| Rules engine and API | Python 3.12, FastAPI, uv, pytest, deployed on Vercel | `server/` |
| 3D reconstruction | MoGe-2 learned depth scaled with the ARKit poses, LiDAR depth, Open3D, shapely | `recon/` (PR #20) |
| Reviewer view | TypeScript, Vite, Vitest, Biome | `web/` |
| Landing page | Static site on Vercel | `sites/landing` |

## Unseen means unsure

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/readme/unseen-dark.gif">
  <img alt="A wall with the left side hazed over. Three checks read Not seen. The haze sweeps away, the checks turn Unsure, then settle: wall and ground pass, clear space fails, and the spot reads Not here." src="docs/readme/unseen-light.gif" width="100%">
</picture>

This is the rule we care about most. A gap in the scan could hide a gas meter, so ground nobody saw never counts as clear. Here the walk went right and never saw the left side. The closer spot stays "Not seen yet" until the view sweeps across. Then there isn't enough clear space in front of it, so it's out.

The same idea covers error. The phone tracks itself by dead reckoning, so its error grows the farther you walk. A check passes only when the margin beats the error, and fails only when it misses by more. Everything in between is UNSURE, and the app names the view that would settle it. The values in the animation are illustrative.

## Reproduce the demo

Most of the working system is still in open pull requests. `main` has an AR session that shows tracking and a server skeleton. Check out the PR you need with the [GitHub CLI](https://cli.github.com).

**Ask the demo server for a placement.** It runs the engine from PR #11 with public rules only, and every answer says so.

```bash
gh pr checkout 11
curl -s https://house-scanning-server.vercel.app/v1/placements \
  -H 'Content-Type: application/json' \
  --data-binary @server/tests/fixtures/example-scene.json
```

Post the same scene to `/v1/placements/site-plan.svg` to get a drawing of the wall with the chosen spot.

**Run the server yourself.**

```bash
gh pr checkout 11
cd server
uv sync --locked
uv run uvicorn api:app --host 0.0.0.0 --port 8000
```

**Run the app.** Guided capture is in PR #10. In the Simulator, build `ios/HouseScan.xcodeproj` and pass the launch arguments `-replay <capture folder> -autopilot -serverURL https://house-scanning-server.vercel.app`. On an iPhone, set up signing first:

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
```

Then set `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` in that file, plug the phone in, and run. Don't set the team in Xcode's Signing pane, because CI fails on the change it writes to the project.

### Environment variables

There are no third-party API keys. The server runs the public rules with nothing set. These are all optional:

```bash
# server/.env  (git ignores .env files; load it with: uv run --env-file .env uvicorn api:app)

# "strict" sends every would-be pass or fail to manual review instead of deciding.
# HOUSESCAN_POLICY=strict

# Base's rules, merged over the public ones. Set one of these two, never both.
# HOUSESCAN_PRIVATE_RULES=../private/rules.yaml
# HOUSESCAN_PRIVATE_RULES_B64=<the same YAML, base64-encoded, for Vercel>

# Required once private rules load. Every route but /health then asks for it.
# HOUSESCAN_API_KEY=<a long random string you choose>
```

The reconstruction worker in PR #20 reads `HOUSE_SCANNING_DATA` (default `~/house-scanning-data`) for public datasets and model caches, and `HOUSESCAN_SERVER` for the server to post to. TestFlight uploads use repository secrets described in [CONTRIBUTING.md](CONTRIBUTING.md).

## Data and where it came from

| Data | What we used it for | Source | In git? |
| --- | --- | --- | --- |
| [ADVIO](https://github.com/AaltoVision/ADVIO) | Tracking drift on a 2018 iPhone 6s | Public, CC BY-NC 4.0 | No |
| MARViN | Tracking drift on an iPhone 14 Pro Max | Public, no license stated | No |
| [ETH3D](https://www.eth3d.net) | Wall error against a laser scan | Public, CC BY-NC-SA 4.0 | No |
| Meter photos | Reading the meter number (PR #16) | Photos of real meters taken for this test | No, `data/` |
| Field runs | The app's first run on a phone (PR #23) | Our TestFlight build on a real wall | No, `captures/` |
| Rule values | The rules engine | Public pages and building codes, each cited in [docs/04](docs/04-prior-art-and-codes.md) | Yes |
| Test fixtures | Server and packet tests | Synthetic, written by hand | Yes |
| Drawings and animations | This README, the site, the walkthrough | Illustrations with example values, not a real house | Yes |

The public datasets are used only to measure accuracy and are never redistributed. Base's own rules and materials stay in the git-ignored `private/` folder. Photos of real homes never enter git.

## Known limitations

- **Most of it isn't merged.** Guided capture (PR #10), the engine (PR #11), reconstruction (PR #20) and the packet spec (PR #22) all live on branches.
- **The first phone run placed nothing.** It set both wall ends at the meter, so the server had no wall to search (PR #23).
- **The 3D method is still open.** Learned depth alone is about 20 in off. Rescaled with the phone's poses it gets to about 5 in (p90), but edges stay at 8 in or worse. With depth from a laser scan standing in for LiDAR, walls land within 2.1 in.
- **Our tracking evidence comes from a LiDAR phone.** A current iPhone stayed inside the error allowance, but it had LiDAR, and most homeowners' phones don't. A 2018 iPhone ran two to three times over.
- **Hidden wall has no owner.** Something standing in front of the wall can hide it, and nothing checks for that on phones without LiDAR yet.
- **Two rule values are placeholders.** No public value exists for the pool (10 ft) and the driveway (5 ft).
- **Meter reading picks the wrong line.** The phone reads the number but chose the right line on only 21 of 75 photos, so the app offers three candidates to tap.
- **The electrical panel is out of scope.** An electrician still reviews it.

## Next steps

1. Run the field test on a current iPhone without LiDAR, using `experiments/evals/field/FIELD_SHEET.md` (PR #12), and check the default error bars against a tape.
2. Pick the 3D path, and try world models, which nobody has tested yet.
3. Decide who checks for hidden wall. One idea is to show the homeowner the photo of the chosen spot and ask.
4. Load Base's values into the private deployment in place of the placeholders.

## Repository map

Paths marked with a pull request exist only on that branch until it merges.

| Path | What it is | State |
| --- | --- | --- |
| `ios/` | The iPhone app | On `main`, an AR session that shows tracking. Guided capture is in PR #10, and the live 3D map in PR #21 |
| `packet/` | The capture packet's spec, validator and samples | PR #22 |
| `server/` | The rules engine and placement API | On `main`, a skeleton. The engine is in PR #11 |
| `recon/` | Turns photos and depth into a 3D model and a coverage map | PR #20, handed to the server team |
| `experiments/` | One folder per experiment | Accuracy evals in PR #12, Measure Lab in PR #7, scoring in PR #4, meter reading in PR #16, the first device field test in PR #23 |
| `web/` | Browser toolchain for a reviewer view | No page on `main` |
| `docs/` | The overview, the walkthrough, public rules and code citations, and the live-survey design | |
| `.agents/skills/` | Shared agent skills for writing, planning and review, linked from `.claude/skills/` | |
| `sites/landing` | The landing page, a submodule | Change it in its own repository |

To go deeper, start with [the walkthrough](docs/how-it-works.html), about fifteen minutes with pictures. [docs/00-overview.md](docs/00-overview.md) has the plan, the decisions and the evidence, [AGENTS.md](AGENTS.md) the rules for anyone changing this repository, and [CONTRIBUTING.md](CONTRIBUTING.md) branches, CI and TestFlight.

This repository is public. The GIFs above were recorded from the [live site](https://house-scanning.vercel.app/).
