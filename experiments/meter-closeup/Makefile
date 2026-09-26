# Each results table has one target. Images and raw recognizer output go to $(METER_DATA),
# default ~/house-scanning-data/meter; nothing from there is committed.

OCR := meterocr/.build/release/meterocr

.PHONY: check leakcheck images q1 q2 q45 sweep review

check:
	uv run ruff check .
	uv run ruff format --check .
	uv run pytest -q

# Needs the HMAC key (file or METER_HMAC_KEY), not the plaintext labels.
leakcheck:
	uv run python -m meter_eval.leakcheck

$(OCR): meterocr/Package.swift meterocr/Sources/meterocr/main.swift
	swift build -c release --package-path meterocr

# Downloads the 83 photos in manifest.csv (about 200 MB, one request per second).
images:
	uv run python -m meter_eval.commons fetch

# results/clean.md and results/clean_per_image.csv (about 1 minute).
q1: $(OCR)
	uv run python -m meter_eval.clean

# The degraded reads behind results/sweep.md, in two processes of up to 2 GB each
# (about 25 minutes). Needs results/clean_per_image.csv from q1.
sweep: $(OCR)
	uv run python -m meter_eval.sweep --shard 0 --shards 2 & \
	uv run python -m meter_eval.sweep --shard 1 --shards 2 & \
	wait

# results/sweep.md and results/sweep_rows.csv from the sweep rows.
q2:
	uv run python -m meter_eval.analyze

# results/locate.md and results/locate_per_image.csv: barcodes and number finding (Q4, Q5),
# about a minute. `--split dev` reproduces results/locate_dev.md, the half the rules came from.
q45: $(OCR)
	uv run python -m meter_eval.locate

# The label review page, outside git: ~/house-scanning-data/meter-closeup/review.html.
review:
	uv run python -m meter_eval.review build
