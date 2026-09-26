# server

The placement server (docs/02 lane C). It takes the phone's scan of the wall around the electric meter, decides whether a Base Power battery fits and where, and explains why. The app, the website and a future SDK all call the same HTTP API.

The decision is plain code, not AI. Every threshold lives in `rules.yaml` with its citation.

## Requirements

[uv](https://docs.astral.sh/uv/) 0.11. It installs Python 3.12 (`.python-version`) and the locked dependencies.

## Commands

Run from `server/`:

| Command | What it does |
| --- | --- |
| `uv sync --locked` | Create `.venv` from `uv.lock` |
| `uv run uvicorn api:app --host 0.0.0.0 --port 8000` | Serve the API; `--reload` while developing |
| `uv run python siteplan.py scene.json plan.svg` | Solve one scene and write its site plan |
| `uv run ruff check .` | Lint |
| `uv run ruff format .` | Format; CI runs `ruff format --check .` |
| `uv run pytest -q` | Tests in `tests/` |

`make server` from the repository root runs what CI (`.github/workflows/server.yml`, job "Server checks") runs.

## API

| Endpoint | Body | Returns |
| --- | --- | --- |
| `GET /health` | | `{"status": "ok", "schema_version", "policy"}`: which rules are loaded |
| `POST /v1/placements` | a scene | The result JSON (`schemas/result.schema.json`) |
| `POST /v1/placements/site-plan.svg` | a scene | The site plan as `image/svg+xml` |

A scene is either bare `scene.json` (`Content-Type: application/json`) or a zip bundle (`application/zip`) holding `scene.json` plus the keyframe and close-up JPEGs it names. A browser form can also send either one as a multipart file field named `bundle`. The server reads a bundle in memory and refuses it if any image named in `scene.json` is missing.

```sh
curl -s localhost:8000/v1/placements -H 'Content-Type: application/json' \
  --data-binary @tests/fixtures/example-scene.json | jq .decision
```

Every refusal is JSON with the field at fault:

```json
{"error": {"code": "invalid_scene", "message": "Additional properties are not allowed ('plusminus_ft' was unexpected)", "path": "/objects/0"}}
```

| Status | When |
| --- | --- |
| 400 | The body or zip can't be read, or a zip entry has an absolute or `..` path |
| 413 | The body or unzipped bundle is over the limit (`HOUSESCAN_MAX_UPLOAD_MB`, default 256; `HOUSESCAN_MAX_UNZIPPED_MB`, default 512) |
| 415 | The content type is neither JSON, zip nor multipart |
| 422 | The scene breaks `schemas/scene.schema.json` or can't be placed (for example the meter is far from its wall) |

## Contracts

- `schemas/scene.schema.json` (C1): what the app uploads. It is docs/01's `scene.json` in feet with optional additions (`schema_version`, `coverage`, `plus_minus_ft`, `tape` as a source, a plan `footprint` per object). Unknown fields are refused, so a misspelled field fails loudly instead of being ignored.
- `schemas/result.schema.json` (C2): what the server answers. Both files change only by adding optional fields; `schema_version` goes up when they do.

Three conventions matter to anyone producing a scene:

1. Wall `baseline` points run **left to right as seen from outside**, and walls are listed in that order. The outward side of each wall segment follows from its point order. The server refuses a scene whose keyframe cameras sit mostly on the inward side.
2. `s` is feet along the unrolled walls from the meter, negative to the left. Spans (`span_ft`) and coverage use it.
3. `coverage` says what the capture actually saw. A check that depends on something unseen is UNSURE, never PASS. A scene without `coverage` can't pass.

## How a decision is made

`solve(parse_scene(raw, rules), loaded_rules)` is a pure function; `api.py` only adds HTTP.

1. **Unroll the walls** (`scene.py`). The walls are chained left to right. Every straight segment keeps its outward direction, and s is measured from the meter's projection onto its wall. Stretches between walls that don't meet are gaps: nothing backs onto them, and no cable crosses them.
2. **Sweep the footprint** (`solver.py`). The battery (31 × 22 in from `rules.yaml`) slides along every straight segment. Start positions are a 2 in grid plus every position where a check can change outcome: an opening's clearance edge, a ground patch edge, a coverage boundary, the start at which the footprint comes exactly the clearance distance from a gas meter's corner. Midpoints between those positions are added too, so a legal stretch narrower than 2 in is still found. A footprint never bends round a corner.
3. **Check each position.** Distances are measured in plan (x, z) with shapely, so a gas meter just round an inside corner is as close as it really is. Each check is strict (contract C5): with a measured gap d ± e and a minimum T, PASS needs d − e > T, FAIL needs d + e < T, and anything else, including exact equality, is UNSURE. Errors add up: a gap between two tapped positions that are each ±0.3 ft is ±0.6 ft. A recognition confidence is never used as a distance error.

   | Check | Measures |
   | --- | --- |
   | `wall_backing` | Footprint flush on one straight, observed segment |
   | `ground_surface` | Ground under the footprint is an allowed surface; patch edges count only where they meet a disallowed or unrecorded surface |
   | `meter_working_space` | Clear of the NEC 110.26 space in front of the meter |
   | `gas_clearance`, `ac_clearance`, `pool_clearance`, `drive_clearance` | Distance to every part of each object, and everything within the clearance was seen |
   | `opening_clearance` | Distance to doors and windows; an unknown attribute that could exempt a window gives UNSURE, never a pass |
   | `wall_equipment_above` | No box or vent on the wall above the battery |
   | `facing_gap`, `headroom` | The smallest measurement over the battery's stretch of wall |
   | `route_path` | The cable runs along continuous, observed wall; doors, garages and gaps block it; windows it detours round |
   | `route_length` | Routed length, including detours and corners: PASS under the confident reach, FAIL clearly over the maximum |

4. **Decide.** A spot passes when every check passes. With at least one passing spot the result is **pass**, choosing the shortest cable run. With none, the best spot without a failing check gives **manual_review**, with its reasons and the exact stretches still unseen. **reject** needs every spot to fail by a clear margin *and* both ends of the walk known: each end must be a real limit, or so far away that no spot beyond it could pass the route-length check. Otherwise the result asks for the walk to continue. A policy with `auto_approve: false` turns every pass or reject into manual review.

## Rules

`rules.yaml` holds every number, each with a `source`. `placeholder: true` marks a demo value that has no public source (driveway, pool, confident reach). The public file sets `auto_approve: false` for that reason.

At startup the server deep-merges a git-ignored `private/rules.yaml` over it when one exists. The path comes from `HOUSESCAN_PRIVATE_RULES`, or else `<repo root>/private/rules.yaml`. `GET /health` shows which files are loaded and the hash of the merged rules. Every result records the same hash. Never commit Base's values: `private/` is git-ignored.

## Tests

- `tests/test_golden_public.py`: the 14 golden tests from `docs/research/t3-lane-c-review.md` (branch `t3/research`). Every result is validated against the result schema.
- `tests/test_properties.py`: property tests. Missing coverage never passes, equality is unsure, left and right mirror, and a larger clearance never turns a pass into a fail.
- `tests/test_api.py`, `tests/test_schemas.py`, `tests/test_siteplan.py`: the HTTP layer, the published schemas, the SVG.

Base-derived tests live in `private/tests/` (git-ignored). Run them with `uv run pytest ../private/tests -q`.

Recognition prompts go in `server/prompts/`, which git ignores; they are never committed.
