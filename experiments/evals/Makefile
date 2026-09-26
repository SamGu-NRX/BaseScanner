# Each target regenerates one result from a clean checkout. Data goes to ~/house-scanning-data/
# (override with HOUSE_SCANNING_DATA); results/ holds only numbers.

DATA ?= $(or $(HOUSE_SCANNING_DATA),$(HOME)/house-scanning-data)
ETH3D := $(DATA)/evals/eth3d
PRED := $(DATA)/evals/predictions
SCENES := facade electro
MODELS := uv run --project models python -m

.PHONY: test drift replay recon recon-data recon-models recon-score frames sensitivity pose-priors field modern-arkit coverage coverage-options

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
	done

recon-score:
	uv run python -m evals.recon score

frames:
	uv run python -m evals.frames

sensitivity:
	uv run python -m evals.recon sensitivity

# After recon: AR-like poses, MapAnything with and without them (392 px, 2 and 4 views: the most
# that fits the shared machine's per-process memory), then triangulation and scoring.
pose-priors:
	uv run python -m evals.pose_priors prepare
	for s in $(SCENES); do \
	  $(MODELS) models.run_groups --scene-dir $(ETH3D)/$$s --sizes 2 4 --max-side 392 \
	    --out $(PRED)/$$s/ma392_images || exit 1; \
	  for p in exact advio_2018 modern_assumed; do \
	    $(MODELS) models.run_groups --scene-dir $(ETH3D)/$$s --sizes 2 4 --max-side 392 \
	      --poses-file $(ETH3D)/$$s/ar_poses/$$p.json --out $(PRED)/$$s/ma392_$$p || exit 1; \
	  done; \
	done
	uv run python -m evals.pose_priors score

# One Measure Lab field session. SESSION is the zip shared from the app; with TRUTH, MAP and RULES
# (the tape survey, the team's map for `score import-measure-lab`, the rules file) it also writes
# the learned-depth results files, imports the rig's own row with the scoring harness at SCORING
# (experiments/scoring, PR #4) and scores every row in one table.
FIELD_OUT ?= $(DATA)/evals/field/results/$(basename $(notdir $(SESSION)))
SCORING ?= ../scoring
field:
	uv sync --project models
	W=$$(uv run python -m evals.field prepare $(SESSION)) && \
	$(MODELS) models.run --model moge2 --images $$W/images.txt --intrinsics $$W/intrinsics.json \
	  --out $$W/moge2 && \
	uv run python -m evals.field score $(SESSION) --out-dir $(FIELD_OUT) \
	  $(if $(TRUTH),--truth $(TRUTH) --map $(MAP) --rules $(RULES))
	$(if $(TRUTH),cd $(SCORING) && \
	  uv run score import-measure-lab $(abspath $(SESSION)) --map $(abspath $(MAP)) \
	    --rules $(abspath $(RULES)) --truth $(abspath $(TRUTH)) --out $(abspath $(FIELD_OUT))/measure-lab.json && \
	  uv run score --rules $(abspath $(RULES)) --truth $(abspath $(TRUTH)) \
	    --results $(abspath $(FIELD_OUT))/*.json --out $(abspath $(FIELD_OUT))/scored)

# A current iPhone's ARKit scale on MARViN's outdoor walks (pose and GPS text files only, ~3 MB).
modern-arkit:
	uv run python -m evals.modern_arkit

# After recon-data. HouseScanKit (ios/, owned by the app lane) is checked out read-only at the
# commit pinned in evals/coverage.py, outside the repo, and never edited.
coverage:
	uv run python -m evals.coverage prepare
	uv run python -m evals.coverage

coverage-options:
	uv run python -m evals.coverage prepare
	uv run python -m evals.coverage_options
