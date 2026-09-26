# Each target regenerates one result from a clean checkout. Data goes to ~/house-scanning-data/
# (override with HOUSE_SCANNING_DATA); results/ holds only numbers.

DATA ?= $(or $(HOUSE_SCANNING_DATA),$(HOME)/house-scanning-data)
ETH3D := $(DATA)/evals/eth3d
PRED := $(DATA)/evals/predictions
SCENES := facade electro
MODELS := uv run --project models python -m

.PHONY: test drift replay recon recon-data recon-models recon-score

test:
	uv run ruff check .
	uv run ruff format --check .
	uv run pytest -q

drift:
	uv run python -m evals.datasets advio
	uv run python -m evals.drift

replay:
	uv run python -m evals.datasets advio
	uv run python -m evals.replay --sequence 20 --start 40 --end 75
	uv run python -m evals.check_replay $(DATA)/replays/advio-20-0040-0075

recon: recon-data recon-models recon-score

recon-data:
	uv run python -m evals.datasets eth3d
	uv run python -m evals.recon prepare

# One model at a time: the Mac is shared and each model fills most of the GPU memory.
recon-models:
	uv sync --project models
	for s in $(SCENES); do \
	  for m in moge2 da3metric; do \
	    $(MODELS) models.run --model $$m --images $(ETH3D)/$$s/model_inputs/images.txt \
	      --intrinsics $(ETH3D)/$$s/model_inputs/intrinsics.json --out $(PRED)/$$s/$$m || exit 1; \
	  done; \
	  $(MODELS) models.run_groups --scene-dir $(ETH3D)/$$s --out $(PRED)/$$s/mapanything || exit 1; \
	done

recon-score:
	uv run python -m evals.recon score
