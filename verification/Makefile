# Independent verification. Every target runs from this folder; reports go to
# ~/house-scanning-data/reports/ (outside git) because runs can show dataset frames.

REF ?= origin/t3/ios-mvf
ARGS ?=

.PHONY: test sim sim-probe e2e scoreboard

test:
	uv run ruff check .
	uv run ruff format --check .
	uv run pytest -q

# Build REF for the Simulator, run it with ARGS (e.g. ARGS="--replay <dir> --autopilot"),
# screenshot every STATE.
sim:
	uv run python -m hsverify.simrun --ref $(REF) $(ARGS)

# Self-test of the runner against a fixture app that logs a known STATE sequence.
sim-probe:
	uv run python -m hsverify.simrun --ref HEAD --project verification/fixtures/state-probe/StateProbe.xcodeproj \
		--scheme StateProbe --until probe_done --extra-arg -probeArg --label probe
