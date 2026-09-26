# Agent guide

A homeowner scans the outside of their house around the electric meter with an iPhone. The system works out whether a Base Power battery fits there and where, and the app shows the spot in AR. It is a hackathon project that started on 2026-09-25. The MVP is three problems: a phone that guides the homeowner until everything the model needs is captured, photos and their metadata turned into a 3D model, and that model evaluated against the placement criteria.

## Who owns what

- **Client team.** Sam, working with AI agents, owns the iOS app in `ios/`: guided capture, the live on-device 3D map with fog of war, and the capture packet it sends to the server. Aiden films video and gathers sample datasets.
- **Server team.** Hunter, working with his own agents, owns everything after the packet: building a 3D model or point cloud, then evaluating the criteria on it.

Edit the other team's files only with that team's OK, and talk to the author before editing files that an open pull request also changes. Two writers on one file cost more time than asking does.

## Where to look

Read the row for your task. Files marked with a pull request exist only on that branch until it merges.

| Task | Read |
| --- | --- |
| What the system is, what's decided, what's open | `docs/00-overview.md` |
| The iOS app | `ios/README.md` |
| The capture packet the app sends | `packet/README.md` (coming on branch `t3/packet`) |
| The rules engine, API and capture contract | `server/README.md` (PR #11), especially "What settles each check" |
| Turning photos into a 3D model | `recon/HANDOFF.md` (PR #20) |
| Accuracy evals on public datasets | `experiments/evals/README.md` (PR #12) |
| Branches, checks and TestFlight | `CONTRIBUTING.md` |
| Rule citations and day-1 reasoning | `docs/01` to `05`; `docs/00` and the component READMEs win where they differ |

## Rules

- **Keep Base's materials in `private/`, which git ignores.** The repository is public. Don't commit, quote or summarize those materials in tracked files, including prompt text, prompt names, output field names and internal thresholds. Team notes go in `private/internal-notes.md`. Real captures, photos of homes and dataset images go in `captures/`, `fixtures/real/` or `data/`, which git also ignores.
- **Make placement decisions in deterministic code.** Models build the geometry and recognize things such as the meter's text or an object's outline. Plain code over that geometry makes the pass or fail decision, so every answer traces back to a rule and a measurement. Clearance numbers live in rules files with their sources, never in code: public values with citations in `server/rules.yaml` (PR #11), and Base's values in the git-ignored `private/rules.yaml`, which the server merges over them.
- **Treat unseen as unsure, never as clear.** A gap in the scan could hide a gas meter. When a check depends on an area nobody observed, return UNSURE and name the view that would settle it.
- **Use StratMap or NAIP for aerial imagery.** Google Maps, Street View, Mapbox and Esri forbid running ML on their imagery in their terms.
- **Place AR results relative to the meter's anchor, with `.gravity` world alignment.** ARKit corrects anchors as tracking improves, so a result tied to the meter moves with it while raw world coordinates drift. `.gravityAndHeading` depends on the compass, which is unreliable next to a house.
- **Rotate the intrinsics whenever you rotate a camera image.** Camera images are landscape sensor images and the intrinsics match that orientation. A rotated image with unrotated intrinsics produces wrong 3D geometry without any error.

Decided: the app is native iOS only (Swift, ARKit, RealityKit), because Expo has no first-class ARKit support. It uses LiDAR and other depth sensors when present and never requires them, since most homeowners' phones lack LiDAR.

## Working in the repository

- `make check` runs every suite; `make ios`, `make server` and `make web` run one each. `CONTRIBUTING.md` lists the matching CI checks.
- Branch from `main`, keep one writer per branch, and open a pull request. People merge. Agents never push to `main` or merge, so a person sees every change before it lands.
- Several agents share one Mac. Exit code 137 means the system killed the process, usually for memory. Find the large allocation before rerunning, because macOS swaps before it kills and one runaway process can freeze the whole machine.
- Set your signing team in `ios/Config/Local.xcconfig` (copy `Local.xcconfig.example`; see `ios/README.md`), not in Xcode's Signing & Capabilities pane. The pane writes into `project.pbxproj`, and CI fails on that drift.
- After editing `ios/project.yml`, run `make ios-project` (it needs XcodeGen 2.46.0) and commit the regenerated project, because CI regenerates it and fails on any difference.
- `sites/landing` is the landing page, a submodule. Change it in its own repository.
