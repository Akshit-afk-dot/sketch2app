"""Train the stroke recognizer.

    python -m s2a.recognizer.train [--config ml/configs/recognizer.yaml] [--smoke] [--name NAME]

--smoke trains a few hundred samples for one epoch (works on CPU) to check the whole loop end to end.
Model selection uses typed element F1 on decoded val sketches, the metric we report, not the loss.
Runs go to $S2A_DATA_ROOT/runs/recognizer/<name>/ (config, metrics per epoch, best.pt, last.pt).
"""

from __future__ import annotations

import argparse
import json
import math
import random
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
import yaml
from torch import Tensor, nn
from torch.utils.data import DataLoader

from s2a.data.build_dataset import out_root
from s2a.paths import REPO_ROOT, data_root
from s2a.recognizer.data import StrokeDataset, collate
from s2a.recognizer.decode import decode
from s2a.recognizer.features import ink_features
from s2a.recognizer.metrics import DetectionStats
from s2a.recognizer.model import STROKE_CLASSES, RecognizerConfig, StrokeRecognizer, count_parameters

CONFIG = REPO_ROOT / "ml" / "configs" / "recognizer.yaml"


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def compute_losses(
    out: tuple[Tensor, Tensor, Tensor], batch: dict[str, Tensor], cfg: dict[str, Any]
) -> tuple[Tensor, dict[str, float]]:
    cls_logits, type_logits, aff = out
    ce = nn.functional.cross_entropy
    l_cls = ce(
        cls_logits.reshape(-1, cls_logits.shape[-1]).float(), batch["cls"].reshape(-1), ignore_index=-100
    )
    l_type = ce(
        type_logits.reshape(-1, type_logits.shape[-1]).float(), batch["type"].reshape(-1), ignore_index=-100
    )
    mask, group = batch["mask"], batch["group"]
    pair = mask[:, :, None] & mask[:, None, :]
    pair &= ~torch.eye(mask.shape[1], dtype=torch.bool, device=mask.device)[None]
    target = (group[:, :, None] == group[:, None, :]).float()
    pos_weight = torch.tensor(cfg["affinity_pos_weight"], device=aff.device)
    l_aff = nn.functional.binary_cross_entropy_with_logits(
        aff[pair].float(), target[pair], pos_weight=pos_weight
    )
    total = cfg["cls"] * l_cls + cfg["type"] * l_type + cfg["affinity"] * l_aff
    return total, {"cls": l_cls.item(), "type": l_type.item(), "aff": l_aff.item()}


@torch.no_grad()
def run_model(
    model: StrokeRecognizer, ink: dict[str, Any], device: torch.device
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    shape, geom = ink_features(ink)
    s = torch.from_numpy(shape)[None].to(device)
    g = torch.from_numpy(geom)[None].to(device)
    m = torch.ones(1, len(shape), dtype=torch.bool, device=device)
    c, t, a = model(s, g, m)
    return c[0].float().cpu().numpy(), t[0].float().cpu().numpy(), a[0].float().cpu().numpy()


def evaluate_elements(
    model: StrokeRecognizer, split: str, limit: int, device: torch.device, threshold: float
) -> dict[str, Any]:
    """Decode exported eval sketches and score them against their gold element lists."""
    model.eval()
    stats = DetectionStats()
    base = out_root() / "eval" / split
    files = sorted((base / "ink").glob("*.json"))[:limit]
    for f in files:
        ink = json.loads(f.read_text(encoding="utf-8"))
        gold = json.loads((base / "gold" / f.name).read_text(encoding="utf-8"))
        if not ink["strokes"]:
            continue
        c, t, a = run_model(model, ink, device)
        pred = decode(ink, c, t, a, threshold)
        stats.add(pred["elements"], gold["elements"]["elements"])
        stats.add_strokes([STROKE_CLASSES[i] for i in c.argmax(axis=1)], gold["stroke_cls"])
    return stats.summary()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, default=CONFIG)
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--name", default=time.strftime("%Y%m%d-%H%M%S"))
    args = ap.parse_args()
    cfg = yaml.safe_load(args.config.read_text(encoding="utf-8"))
    tcfg = cfg["train"]
    if args.smoke:
        tcfg.update(epochs=1, batch_size=8)
        cfg["eval"]["val_limit"] = 40
    set_seed(cfg["seed"])
    device = torch.device("cuda" if torch.cuda.is_available() and not args.smoke else "cpu")
    run_dir = data_root() / "runs" / "recognizer" / (f"smoke-{args.name}" if args.smoke else args.name)
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "config.yaml").write_text(yaml.safe_dump(cfg), encoding="utf-8")

    train = StrokeDataset("train", tcfg["max_strokes"], limit=256 if args.smoke else 0)
    loader = DataLoader(
        train, batch_size=tcfg["batch_size"], shuffle=True, collate_fn=collate, num_workers=tcfg["workers"]
    )
    model = StrokeRecognizer(RecognizerConfig(**cfg["model"])).to(device)
    print(f"train samples {len(train)}, params {count_parameters(model):,}, device {device}", flush=True)

    opt = torch.optim.AdamW(model.parameters(), lr=tcfg["lr"], weight_decay=tcfg["weight_decay"])
    total_steps = tcfg["epochs"] * len(loader)

    def lr_at(step: int) -> float:
        if step < tcfg["warmup_steps"]:
            return (step + 1) / float(tcfg["warmup_steps"])
        p = (step - tcfg["warmup_steps"]) / max(1, total_steps - tcfg["warmup_steps"])
        return float(0.5 * (1 + math.cos(math.pi * min(1.0, p))))

    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_at)
    use_amp = tcfg["amp"] and device.type == "cuda"
    amp_dtype = torch.bfloat16 if use_amp and torch.cuda.is_bf16_supported() else torch.float16
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp and amp_dtype == torch.float16)

    best, history, step = -1.0, [], 0
    for epoch in range(tcfg["epochs"]):
        model.train()
        t0, running = time.time(), {"loss": 0.0, "cls": 0.0, "type": 0.0, "aff": 0.0}
        for batch in loader:
            batch = {k: v.to(device, non_blocking=True) for k, v in batch.items()}
            with torch.autocast(device.type, dtype=amp_dtype, enabled=use_amp):
                out = model(batch["shape"], batch["geom"], batch["mask"])
            loss, parts = compute_losses(out, batch, cfg["loss"])
            opt.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()  # type: ignore[no-untyped-call]
            scaler.unscale_(opt)
            nn.utils.clip_grad_norm_(model.parameters(), tcfg["grad_clip"])
            scaler.step(opt)
            scaler.update()
            sched.step()
            step += 1
            running["loss"] += loss.item()
            for k, v in parts.items():
                running[k] += v
            if step % 200 == 0:
                print(
                    f"epoch {epoch} step {step}/{total_steps} "
                    + " ".join(f"{k} {v / 200:.4f}" for k, v in running.items()),
                    flush=True,
                )
                running = dict.fromkeys(running, 0.0)
        val = evaluate_elements(model, "val", cfg["eval"]["val_limit"], device, cfg["eval"]["threshold"])
        f1 = val["detection_typed"]["f1"]
        history.append(
            {
                "epoch": epoch,
                "seconds": round(time.time() - t0, 1),
                "val_typed_f1": f1,
                "val_any_f1": val["detection_any_type"]["f1"],
                "val_stroke_acc": val["stroke_accuracy"],
            }
        )
        print(json.dumps(history[-1]), flush=True)
        ckpt = {"model": model.state_dict(), "config": cfg, "epoch": epoch, "val": val}
        torch.save(ckpt, run_dir / "last.pt")
        if f1 > best:
            best = f1
            torch.save(ckpt, run_dir / "best.pt")
        (run_dir / "history.json").write_text(json.dumps(history, indent=1), encoding="utf-8")
    print(f"best val typed F1 {best:.4f} -> {run_dir / 'best.pt'}")


if __name__ == "__main__":
    main()
