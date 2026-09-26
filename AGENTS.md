# Agent guide

A homeowner scans the wall around their electric meter with an iPhone; the server decides whether a Base Power battery fits and where, and the app shows the spot in AR. [README.md](README.md) maps the repository; [docs/00-overview.md](docs/00-overview.md) holds the plan, decisions and evidence.

## Who owns what

- **Client team.** Sam, working with AI agents, owns the iOS app in `ios/` and the capture packet it sends. Aiden films video and gathers sample datasets.
- **Server team.** Hunter, working with his own agents, owns everything after the packet: the 3D model and the rule checks, in `server/` and `recon/`.

Edit the other team's files only with that team's OK, and talk to the author before editing files that an open pull request also changes. Two writers on one file cost more time than asking does.

## Where to look

A component's README wins over the docs. Files marked with a pull request exist only on that branch until it merges.

| Task | Read |
| --- | --- |
| The iOS app | `ios/README.md` (PR #10 for guided capture) |
| The capture packet | `packet/README.md` (PR #22) |
| The rules engine, API and scene contract | `server/README.md` (PR #11), especially "What settles each check" |
| Photos to a 3D model | `recon/HANDOFF.md` (PR #20) |
| Accuracy evals and the field test | `experiments/evals/README.md` (PR #12) |
| Measurement conventions the code relies on | `docs/00-overview.md` |
| Public rule values, code citations, model and imagery licenses | `docs/04-prior-art-and-codes.md` |
| The live guided-survey design | `docs/05-live-guided-survey-hld.md` |
| Branches, CI checks and TestFlight | `CONTRIBUTING.md` |

## Rules

- **Keep Base's materials in `private/`, which git ignores.** The repository is public. Don't commit, quote or summarize those materials in tracked files, including prompt text, prompt names, output field names and internal thresholds. Team notes go in `private/internal-notes.md`. Real captures, photos of homes and dataset images go in `captures/`, `fixtures/real/` or `data/`, which git also ignores.
- **Make placement decisions in deterministic code.** Models build geometry and recognize things; plain code passes or fails each check, so every answer traces to a rule and a measurement. Clearance numbers live in rules files with their sources, never in code.
- **Treat unseen as unsure, never as clear.** A gap in the scan could hide a gas meter. When a check depends on an area nobody observed, return UNSURE and name the view that would settle it.
- **Use StratMap or NAIP for aerial imagery.** Google's and Mapbox's terms forbid running ML on their imagery, and Esri allows it only inside ArcGIS for non-commercial use.
- **Place AR results relative to the meter's anchor, with `.gravity` world alignment.** ARKit corrects anchors as tracking improves, so a result tied to the meter moves with it while raw world coordinates drift. `.gravityAndHeading` depends on the compass, which is unreliable next to a house.
- **Rotate the intrinsics whenever you rotate a camera image.** Camera images are landscape sensor images and the intrinsics match that orientation. A rotated image with unrotated intrinsics produces wrong 3D geometry without any error.
- **Use LiDAR when present, never require it.** Most homeowners' phones lack LiDAR, so every check must also work from the camera and the phone's poses.

## Working in the repository

- `make check` runs every suite; `make ios`, `make server` and `make web` run one each.
- Branch from `main`, keep one writer per branch, and open a pull request. People merge. Agents never push to `main` or merge, so a person sees every change before it lands.
- Several agents share one Mac. Exit code 137 means the system killed the process, usually for memory. Find the large allocation before rerunning, because one runaway process can freeze the whole machine.
- Put `DEVELOPMENT_TEAM` in `ios/Config/Local.xcconfig` (copy `Local.xcconfig.example`), not in Xcode's Signing & Capabilities pane. The pane writes into `project.pbxproj`, and CI fails on that drift.
- After editing `ios/project.yml`, run `make ios-project` (it needs XcodeGen 2.46.0) and commit the regenerated project, because CI regenerates it and fails on any difference.
- `sites/landing` is a submodule; change the landing page in its own repository.
