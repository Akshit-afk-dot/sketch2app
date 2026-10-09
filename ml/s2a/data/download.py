"""Fetch the raw inputs the data pipeline needs, and nothing more.

RICO: only the semantic annotations (JSON view hierarchies with component labels, 158 MB) and two small
metadata CSVs. The 6.5 GB screenshot archive is not needed because we never look at pixels.
Hershey: three single-stroke vector fonts used to draw synthetic handwriting.

    python -m s2a.data.download [rico|hershey|all]

By downloading RICO you accept its research terms (see LICENSES.md).
"""

import sys
import urllib.request
import zipfile
from pathlib import Path

from s2a.paths import data_root

RICO_BASE = "https://storage.googleapis.com/crowdstf-rico-uiuc-4540/rico_dataset_v0.1/"
RICO_FILES = {"semantic_annotations.zip": 157_800_634, "ui_details.csv": None, "app_details.csv": None}
HERSHEY_BASE = "https://raw.githubusercontent.com/kamalmostafa/hershey-fonts/master/hershey-fonts/"
HERSHEY_FILES = ["futural.jhf", "scripts.jhf", "cursive.jhf", "hershey.txt"]


def _fetch(url: str, dest: Path, expected_size: int | None = None) -> None:
    if dest.exists() and (expected_size is None or dest.stat().st_size == expected_size):
        print(f"have {dest.name}")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url, timeout=60) as r, tmp.open("wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    if expected_size is not None and tmp.stat().st_size != expected_size:
        raise RuntimeError(f"{dest.name}: got {tmp.stat().st_size} bytes, expected {expected_size}")
    tmp.replace(dest)
    print(f"got {dest.name} ({dest.stat().st_size} bytes)")


def rico_dir() -> Path:
    return data_root() / "raw" / "rico"


def rico() -> None:
    for name, size in RICO_FILES.items():
        _fetch(RICO_BASE + name, rico_dir() / name, size)
    out = rico_dir() / "semantic_annotations"
    if not out.exists():
        with zipfile.ZipFile(rico_dir() / "semantic_annotations.zip") as z:
            members = [m for m in z.namelist() if m.endswith(".json")]
            z.extractall(rico_dir(), members=members)
        print(f"extracted {len(members)} JSON files")


def hershey_dir() -> Path:
    return data_root() / "raw" / "hershey"


def hershey() -> None:
    for name in HERSHEY_FILES:
        _fetch(HERSHEY_BASE + name, hershey_dir() / name)


def main() -> None:
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("rico", "all"):
        rico()
    if what in ("hershey", "all"):
        hershey()


if __name__ == "__main__":
    main()
