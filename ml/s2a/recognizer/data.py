"""Training batches for the recognizer from the feature cache (see cache.py)."""

from __future__ import annotations

from typing import Any

import numpy as np
import torch
from torch.utils.data import Dataset

from s2a.recognizer.cache import cache_dir
from s2a.recognizer.features import GEOM_DIM, RESAMPLE


class StrokeDataset(Dataset[dict[str, Any]]):
    """All samples of a split in memory (a few hundred MB as float16)."""

    def __init__(self, split: str, max_strokes: int = 512, limit: int = 0) -> None:
        self.items: list[dict[str, Any]] = []
        for path in sorted((cache_dir() / split).glob("shard_*.npz")):
            # Read each array once: indexing the NpzFile decompresses the whole array on every access.
            with np.load(path) as z:
                arrays = {k: z[k] for k in ("shape", "geom", "cls", "group", "type", "offsets", "ids")}
            off = arrays["offsets"]
            for k in range(len(off) - 1):
                a, b = int(off[k]), int(off[k + 1])
                if b - a == 0 or b - a > max_strokes:
                    continue  # empty or exceptionally long sketches are skipped in training only
                item: dict[str, Any] = {
                    key: arrays[key][a:b] for key in ("shape", "geom", "cls", "group", "type")
                }
                item["id"] = str(arrays["ids"][k])
                self.items.append(item)
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


class BucketBatchSampler(torch.utils.data.Sampler[list[int]]):
    """Batches of similar length (sketches range from ~10 to 500 strokes): shuffle, sort within chunks
    of 50 batches, then shuffle the batches. Cuts padding, and with it GPU time, several-fold."""

    def __init__(self, lengths: list[int], batch_size: int, seed: int) -> None:
        self.lengths = lengths
        self.batch_size = batch_size
        self.rng = np.random.default_rng(seed)

    def __iter__(self):  # type: ignore[no-untyped-def]
        order = self.rng.permutation(len(self.lengths))
        chunk = self.batch_size * 50
        batches: list[list[int]] = []
        for start in range(0, len(order), chunk):
            part = sorted(order[start : start + chunk].tolist(), key=lambda i: self.lengths[i])
            batches += [part[k : k + self.batch_size] for k in range(0, len(part), self.batch_size)]
        self.rng.shuffle(batches)
        return iter(batches)

    def __len__(self) -> int:
        return (len(self.lengths) + self.batch_size - 1) // self.batch_size
