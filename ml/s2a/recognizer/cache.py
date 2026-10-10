"""Feature cache for recognizer training: shards -> compressed .npz arrays (float16 shapes).

Torch-free on purpose: worker processes import only numpy (importing torch in every Windows worker
exhausts the page file).

    python -m s2a.recognizer.cache [workers]
"""

from __future__ import annotations

import gzip
import json
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np

from s2a.data.build_dataset import SPLITS, out_root
from s2a.recognizer.features import ink_features
from s2a.recognizer.labels import ELEMENT_TYPES, NONE_TYPE, STROKE_CLASSES


def cache_dir() -> Path:
    return out_root() / "features"


def sample_labels(rec: dict[str, Any]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(stroke class idx, group idx, element type idx) per stroke."""
    cls = np.array([STROKE_CLASSES.index(c) for c in rec["stroke_cls"]], np.int8)
    group = np.array(rec["stroke_group"], np.int16)
    types = np.array(
        [
            ELEMENT_TYPES.index(rec["groups"][g]["type"])
            if rec["groups"][g]["kind"] == "element"
            else NONE_TYPE
            for g in rec["stroke_group"]
        ],
        np.int8,
    )
    return cls, group, types


def _cache_shard(path: Path) -> str:
    out = cache_dir() / path.parent.name / path.name.replace(".jsonl.gz", ".npz")
    if out.exists():
        return str(out)
    shapes, geoms, cls, groups, types, offsets, ids = [], [], [], [], [], [0], []
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            rec = json.loads(line)
            s, g = ink_features(rec["ink"])
            c, gr, t = sample_labels(rec)
            shapes.append(s.astype(np.float16))
            geoms.append(g)
            cls.append(c)
            groups.append(gr)
            types.append(t)
            offsets.append(offsets[-1] + len(c))
            ids.append(rec["id"])
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        out,
        shape=np.concatenate(shapes),
        geom=np.concatenate(geoms),
        cls=np.concatenate(cls),
        group=np.concatenate(groups),
        type=np.concatenate(types),
        offsets=np.array(offsets, np.int64),
        ids=np.array(ids),
    )
    return str(out)


def build_cache(workers: int = 8) -> None:
    shards = [p for s in SPLITS for p in sorted((out_root() / s).glob("shard_*.jsonl.gz"))]
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for done in pool.map(_cache_shard, shards):
            print(done, flush=True)


if __name__ == "__main__":
    build_cache(int(sys.argv[1]) if len(sys.argv) > 1 else 6)
