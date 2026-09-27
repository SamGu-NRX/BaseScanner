"""Where things live. Code and results are in git; images, weights and predictions are not."""

from pathlib import Path

HERE = Path(__file__).resolve().parent.parent  # experiments/autodetect
RESULTS = HERE / "results"
MANIFESTS = HERE / "manifests"

# Outside git: downloaded images, weights, cached predictions on real images.
DATA = Path.home() / "house-scanning-data" / "autodetect"
OI = DATA / "oi"
CMP = DATA / "cmp"
WEIGHTS = DATA / "weights"
PREDS = DATA / "preds"

ELECTRO = Path.home() / "house-scanning-data" / "packets" / "eth3d-electro"
