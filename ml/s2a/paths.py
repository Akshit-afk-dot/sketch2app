"""Filesystem locations.

Heavy artefacts (datasets, checkpoints, caches) live under ``S2A_DATA_ROOT`` so they never
bloat the git repo; on the dev laptop that is a separate drive with free space.
"""

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC_DIR = REPO_ROOT / "spec"


def data_root() -> Path:
    """Root for large generated or downloaded files; defaults to the gitignored ``<repo>/artifacts``."""
    root = Path(os.environ.get("S2A_DATA_ROOT", REPO_ROOT / "artifacts"))
    root.mkdir(parents=True, exist_ok=True)
    return root
