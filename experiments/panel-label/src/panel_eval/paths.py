import os
from pathlib import Path

EXPERIMENT_DIR = Path(__file__).resolve().parents[2]
MANIFEST = EXPERIMENT_DIR / "manifest.csv"
RESULTS_DIR = EXPERIMENT_DIR / "results"
# Photos and raw recognizer output stay outside the repository.
DATA_DIR = Path(os.environ.get("PANEL_DATA", Path.home() / "house-scanning-data" / "panel"))
# The label review page and the HMAC key live here, outside the repository too.
REVIEW_DIR = DATA_DIR.parent / "panel-label"
KEY_PATH = REVIEW_DIR / "hmac.key"
