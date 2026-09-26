# server

The placement server. It takes a scan of the wall around the electric meter and answers whether a Base Power battery fits, where, and why. The decision is plain code; every threshold lives in `rules.yaml` with its citation.

## Run

Needs [uv](https://docs.astral.sh/uv/) 0.11. From `server/`:

| Command | What it does |
| --- | --- |
| `uv sync --locked` | Install |
| `uv run uvicorn api:app --host 0.0.0.0 --port 8000` | Serve the API |
| `uv run python siteplan.py scene.json plan.svg` | Solve one scene and write its site plan |
| `uv run pytest -q`, `uv run ruff check .`, `uv run ruff format .` | Test and lint (`make server` runs what CI runs) |

Without the web layer: `loaded = load_rules()`, then `solve(parse_scene(raw, loaded.rules), loaded)` (from `rules`, `scene` and `solver`).

## API

| Endpoint | Body | Returns |
| --- | --- | --- |
| `GET /health` | | Which rules are loaded, and their hash |
| `POST /v1/placements` | a scene | The result, `schemas/result.schema.json` |
| `POST /v1/placements/site-plan.svg` | a scene | The site plan, `image/svg+xml` |

A scene is bare `scene.json` (`application/json`), a zip holding `scene.json` and the JPEGs it names (`application/zip`), or either one as the multipart field `bundle`. `/openapi.json` declares all three.

```sh
curl -s localhost:8000/v1/placements -H 'Content-Type: application/json' \
  --data-binary @tests/fixtures/example-scene.json | jq .decision
```

A refusal is `{"error": {"code", "message", "path"}}`, where `path` is the JSON pointer of the field at fault:

| Status | When |
| --- | --- |
| 400 | The body or zip can't be read, or a zip entry has an absolute or `..` path |
| 413 | Over `HOUSESCAN_MAX_UPLOAD_MB` (default 256) or, unzipped, `HOUSESCAN_MAX_UNZIPPED_MB` (default 512) |
| 415 | Not JSON, zip or multipart |
| 422 | The scene breaks `schemas/scene.schema.json`, names an image the zip lacks, or can't be placed (for example the meter is far from its wall) |

## Writing a scene

`schemas/scene.schema.json` is the contract; it only gains optional fields. Lengths are feet.

- Wall `baseline` points run **left to right as seen from outside**, and walls are listed in that order. That fixes each wall's outward side.
- `s` is feet along the walls from the meter, negative to the left. `span_ft` and coverage use it.
- `coverage` lists what the capture actually saw, and whether each end of the walk is a real `limit` or `unexplored`. Anything unseen makes the checks that depend on it UNSURE, so a scene without `coverage` can't pass.
- Give an object a plan `footprint` when it stands off the wall (a regulator, an AC unit), or clearances are measured to its stretch of wall line.
- Omit `plus_minus_ft` and AR-placed positions get `rules.yaml`'s default error for their source plus 0.16 ft per foot along the walls from the meter, from measured ARKit drift. Send your own when you know better.

## Reading a result

`decision` is `pass`, `manual_review` or `reject`. `spot` gives the battery's plan footprint and `meter_offset_ft`, its offset from the meter for AR; `route` is the cable run. Each entry in `checks` has an outcome, a reason, the measurement, its error and the rule it was held to:

| Check | Means |
| --- | --- |
| `wall_backing` | Flush on one straight, observed stretch of wall |
| `ground_surface` | Standing on an allowed surface |
| `meter_working_space` | Clear of the NEC 110.26 space in front of the meter |
| `gas_clearance`, `ac_clearance`, `pool_clearance`, `drive_clearance`, `opening_clearance` | Far enough from every part of each object, and the area in between was seen |
| `wall_equipment_above` | No box or vent on the wall above |
| `facing_gap`, `headroom` | Enough room in front and above |
| `route_path`, `route_length` | The cable runs along continuous wall, and isn't too long |

A check passes only when its margin exceeds its error and fails only when it misses by more than its error; anything else is UNSURE with an `unsure_cause`. `missing_evidence` lists the views that would settle an unseen area. A reject needs every spot within cable reach to fail and both ends of the walk known.

## Rules

`rules.yaml` holds the public values. `placeholder: true` marks a value with no public source; because it has some, it sets `auto_approve: false`, which turns every pass or reject into manual review. At startup the server merges a git-ignored `private/rules.yaml` over it when one exists (path: `HOUSESCAN_PRIVATE_RULES`, else `<repo root>/private/rules.yaml`). Never commit Base's values. Base-derived tests live beside them in `private/tests/`: `uv run pytest ../private/tests -q`.
