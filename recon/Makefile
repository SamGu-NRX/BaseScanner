# The reconstruction worker. `make test` is what CI runs; the others need the MoGe-2 environment
# (models/, installed on first use) and local data under ~/house-scanning-data.

.PHONY: test run accept

test:
	uv sync --locked
	uv run ruff check .
	uv run ruff format --check .
	uv run pytest -q

# BUNDLE: the app's scan bundle (zip or folder with scene.json) or a Measure Lab session.
# ARGS: extra flags, for example --no-server, --depth moge, --move-meter.
run:
	uv run python -m recon "$(BUNDLE)" --out "$(OUT)" $(ARGS)

# ETH3D electro against its laser scan; needs `make recon-data` from experiments/evals (t3/evals).
accept:
	uv run python -m recon.eth3d electro
