import os
from pathlib import Path

EXPERIMENT_DIR = Path(__file__).resolve().parents[2]
MANIFEST = EXPERIMENT_DIR / "manifest.csv"
RESULTS_DIR = EXPERIMENT_DIR / "results"
# Images and raw recognizer output stay outside the repository.
DATA_DIR = Path(os.environ.get("METER_DATA", Path.home() / "house-scanning-data" / "meter"))
