"""Training data for the recognizer: shards -> cached feature arrays -> padded batches.

Features are computed once per shard and cached as compressed .npz (float16 shapes), so epochs read
arrays instead of re-resampling ink.

    python -m s2a.recognizer.data            # build the cache for all splits
"""

from __future__ import annotations

import gzip
import json
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.utils.data import Dataset

from s2a.data.build_dataset import SPLITS, out_root
from s2a.recognizer.features import GEOM_DIM, RESAMPLE, ink_features
from s2a.recognizer.model import ELEMENT_TYPES, NONE_TYPE, STROKE_CLASSES


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


class StrokeDataset(Dataset[dict[str, Any]]):
    """All samples of a split in memory (a few hundred MB as float16)."""

    def __init__(self, split: str, max_strokes: int = 512, limit: int = 0) -> None:
        self.items: list[dict[str, Any]] = []
        for path in sorted((cache_dir() / split).glob("shard_*.npz")):
            z = np.load(path)
            off = z["offsets"]
            for k in range(len(off) - 1):
                a, b = int(off[k]), int(off[k + 1])
                if b - a == 0 or b - a > max_strokes:
                    continue  # empty or exceptionally long sketches are skipped in training only
                self.items.append(
                    {
                        "id": str(z["ids"][k]),
                        "shape": z["shape"][a:b],
                        "geom": z["geom"][a:b],
                        "cls": z["cls"][a:b],
                        "group": z["group"][a:b],
                        "type": z["type"][a:b],
                    }
                )
                if limit and len(self.items) >= limit:
                    return

    def __len__(self) -> int:
        return len(self.items)

    def __getitem__(self, i: int) -> dict[str, Any]:
        return self.items[i]


def collate(batch: list[dict[str, Any]]) -> dict[str, torch.Tensor]:
    """Pad to the longest sketch in the batch; mask marks real strokes."""
    n = max(len(b["cls"]) for b in batch)
    bsz = len(batch)
    shape = torch.zeros(bsz, n, RESAMPLE, 4)
    geom = torch.zeros(bsz, n, GEOM_DIM)
    mask = torch.zeros(bsz, n, dtype=torch.bool)
    cls = torch.full((bsz, n), -100, dtype=torch.long)
    types = torch.full((bsz, n), -100, dtype=torch.long)
    group = torch.full((bsz, n), -1, dtype=torch.long)
    for i, b in enumerate(batch):
        s = len(b["cls"])
        shape[i, :s] = torch.from_numpy(b["shape"].astype(np.float32))
        geom[i, :s] = torch.from_numpy(b["geom"])
        mask[i, :s] = True
        cls[i, :s] = torch.from_numpy(b["cls"].astype(np.int64))
        types[i, :s] = torch.from_numpy(b["type"].astype(np.int64))
        group[i, :s] = torch.from_numpy(b["group"].astype(np.int64))
    return {"shape": shape, "geom": geom, "mask": mask, "cls": cls, "type": types, "group": group}


if __name__ == "__main__":
    build_cache(int(sys.argv[1]) if len(sys.argv) > 1 else 8)
