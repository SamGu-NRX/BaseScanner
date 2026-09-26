# server

The FastAPI server from `docs/02-implementation-plan.md` (lanes B and C). It will take a capture from the phone, build the wall geometry, run the recognition checks and pick a battery placement. Modules sit flat in this directory (`ingest.py`, `geometry.py`, `solver.py`, `rules.yaml` and so on) as the lanes add them.

For now it holds `units.py`. ARKit reports meters, while `scene.json` and the rules use feet and inches; convert with `units.py` and format lengths for people with `format_ft_in`.

## Requirements

[uv](https://docs.astral.sh/uv/) 0.11. It installs Python 3.12 (`.python-version`) and the locked dev tools.

## Commands

Run from `server/`:

| Command | What it does |
| --- | --- |
| `uv sync --locked` | Create `.venv` from `uv.lock` |
| `uv run ruff check .` | Lint |
| `uv run ruff format .` | Format; CI runs `ruff format --check .` |
| `uv run pytest -q` | Tests in `tests/` |

`make server` from the repository root runs what CI (`.github/workflows/server.yml`, job "Server checks") runs. Add dependencies with `uv add <package>` and commit `uv.lock`.

Recognition prompts go in `server/prompts/`, which git ignores; they are never committed.
