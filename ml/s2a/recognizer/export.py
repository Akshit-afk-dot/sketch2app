"""Export the recognizer to ONNX, check PyTorch-vs-ONNX Runtime parity, and write Dart parity fixtures.

    python -m s2a.recognizer.export --ckpt <run>/best.pt [--out app/assets/models]

The ONNX graph takes one sketch (batch 1, no padding, so no mask input) with a dynamic stroke axis:
    shape (1, S, 32, 4) float32, geom (1, S, 16) float32 -> cls (1, S, 4), type (1, S, 19), affinity (1, S, S)
Fixtures (app/test/fixtures/recognizer/*.json) hold ink, Python features, model logits and the decoded
element list, so the Dart port of features + decoder is tested against this exact implementation.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import torch
from torch import Tensor, nn

from s2a.data.build_dataset import out_root
from s2a.paths import REPO_ROOT
from s2a.recognizer.decode import decode
from s2a.recognizer.features import GEOM_DIM, RESAMPLE, ink_features
from s2a.recognizer.model import RecognizerConfig, StrokeRecognizer

FIXTURES = REPO_ROOT / "app" / "test" / "fixtures" / "recognizer"


class Single(nn.Module):
    """Batch-of-one wrapper: every stroke is real, so the padding mask is all true."""

    def __init__(self, model: StrokeRecognizer) -> None:
        super().__init__()
        self.model = model

    def forward(self, shape: Tensor, geom: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        mask = torch.ones(shape.shape[:2], dtype=torch.bool, device=shape.device)
        out: tuple[Tensor, Tensor, Tensor] = self.model(shape, geom, mask)
        return out


def load(ckpt: Path | None) -> StrokeRecognizer:
    if ckpt is None:
        torch.manual_seed(0)
        return StrokeRecognizer().eval()
    state = torch.load(ckpt, map_location="cpu", weights_only=False)
    model = StrokeRecognizer(RecognizerConfig(**state["config"]["model"]))
    model.load_state_dict(state["model"])
    return model.eval()


def export(model: StrokeRecognizer, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    wrapper = Single(model).eval()
    s = 23  # arbitrary; the stroke axis is exported as dynamic
    example = (torch.randn(1, s, RESAMPLE, 4), torch.randn(1, s, GEOM_DIM))
    torch.backends.mha.set_fastpath_enabled(False)  # fused kernels have no ONNX equivalent
    strokes = torch.export.Dim("strokes", min=1, max=4096)
    torch.onnx.export(
        wrapper,
        example,
        str(path),
        input_names=["shape", "geom"],
        output_names=["cls", "type", "affinity"],
        dynamic_shapes={"shape": {1: strokes}, "geom": {1: strokes}},
        opset_version=18,  # the exporter's native opset; ORT 1.28 supports up to 23
        dynamo=True,
        external_data=False,
    )


def parity(model: StrokeRecognizer, path: Path, inks: list[dict[str, Any]]) -> dict[str, Any]:
    """Max abs difference PyTorch vs ONNX Runtime (CPU, the same version the Android plugin ships)."""
    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    worst, times = 0.0, []
    for ink in inks:
        shape, geom = ink_features(ink)
        with torch.no_grad():
            ref = Single(model)(torch.from_numpy(shape)[None], torch.from_numpy(geom)[None])
        t0 = time.perf_counter()
        got = sess.run(None, {"shape": shape[None], "geom": geom[None]})
        times.append((time.perf_counter() - t0) * 1000)
        for r, g in zip(ref, got, strict=True):
            worst = max(worst, float(np.abs(r.numpy() - g).max()))
    return {"max_abs_diff": worst, "ort_version": ort.__version__, "laptop_cpu_ms_median": float(np.median(times))}


def write_fixtures(model: StrokeRecognizer, inks: list[tuple[str, dict[str, Any]]]) -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for name, ink in inks:
        shape, geom = ink_features(ink)
        with torch.no_grad():
            c, t, a = (x[0].numpy() for x in Single(model)(torch.from_numpy(shape)[None], torch.from_numpy(geom)[None]))
        fixture = {
            "ink": ink,
            "shape": np.round(shape, 6).tolist(),
            "geom": np.round(geom, 6).tolist(),
            "cls": np.round(c, 5).tolist(),
            "type": np.round(t, 5).tolist(),
            "affinity": np.round(a, 5).tolist(),
            "decoded": decode(ink, np.round(c, 5), np.round(t, 5), np.round(a, 5)),
        }
        (FIXTURES / f"{name}.json").write_text(json.dumps(fixture), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", type=Path)
    ap.add_argument("--out", type=Path, default=REPO_ROOT / "app" / "assets" / "models")
    ap.add_argument("--fixtures", type=int, default=3)
    args = ap.parse_args()
    model = load(args.ckpt)
    path = args.out / "recognizer.onnx"
    export(model, path)
    files = sorted((out_root() / "eval" / "val" / "ink").glob("*.json"))[:50]
    inks = [json.loads(f.read_text(encoding="utf-8")) for f in files]
    inks = [i for i in inks if i["strokes"]]
    report = parity(model, path, inks)
    report["size_mb"] = round(path.stat().st_size / 2**20, 2)
    small = sorted(zip(files, inks, strict=False), key=lambda fi: len(fi[1]["strokes"]))[: args.fixtures]
    write_fixtures(model, [(f.stem, ink) for f, ink in small])
    print(json.dumps(report, indent=1))
    (path.with_suffix(".parity.json")).write_text(json.dumps(report, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
