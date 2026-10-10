"""Local LoRA fine-tuning of a small layout model (Qwen3.5-0.8B fits the 4 GB laptop GPU with QLoRA).

Mirrors notebooks/layout_sft.ipynb (same data files, prompt format, LoRA r=16/alpha=32 on all linear
layers, lr 2e-4, cosine schedule, early stopping on validation tree similarity), so local and Colab runs
are comparable.

Why a plain loop instead of TRL here: TRL 1.15's SFTTrainer always installs a fused LM-head loss that
needs Triton, which PyTorch ships on Linux only (the Colab notebook does use TRL). The loop also applies
the output layer to completion positions only, so the 248k-entry vocabulary logits are never built for
the prompt tokens; that is what makes 4 GB of VRAM enough.

    python -m s2a.layout.train_local --examples 4000 --epochs 2
    python -m s2a.layout.train_local --eval-only --adapter <run>/adapter     # test predictions only

Writes $S2A_DATA_ROOT/runs/layout/<name>/: adapter/, val_history.json, train_log.json,
predictions_<cond>.jsonl, config.json.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import time
from pathlib import Path
from typing import Any

import torch
from peft import LoraConfig, PeftModel, get_peft_model
from torch.utils.checkpoint import checkpoint
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

from s2a.layout.metrics import mean_scores, score
from s2a.layout.sft_data import llm_dir
from s2a.paths import data_root

WARMUP_STEPS = 20
LOSS_CHUNK = 256


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.open(encoding="utf-8") if line.strip()]


class Runner:
    def __init__(self, model_name: str, load_4bit: bool) -> None:
        self.tok = AutoTokenizer.from_pretrained(model_name)
        self.tok.padding_side = "left"
        kwargs: dict[str, Any] = {"dtype": torch.bfloat16, "device_map": {"": 0}}
        if load_4bit:
            kwargs["quantization_config"] = BitsAndBytesConfig(
                load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=torch.bfloat16
            )
        self.model: Any = AutoModelForCausalLM.from_pretrained(model_name, **kwargs)

    def prompt_text(self, prompt: str) -> str:
        # Non-thinking chat template: the model answers directly with JSON.
        text: str = self.tok.apply_chat_template(
            [{"role": "user", "content": prompt}],
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        return text

    @torch.no_grad()
    def generate(
        self, prompts: list[str], batch: int = 8, max_new_tokens: int = 1024
    ) -> tuple[list[str], float]:
        model = self.model
        was_training = model.training
        model.eval()
        outs: list[str] = []
        t0 = time.time()
        for i in range(0, len(prompts), batch):
            enc = self.tok(
                [self.prompt_text(p) for p in prompts[i : i + batch]], return_tensors="pt", padding=True
            )
            enc = enc.to(model.device)
            gen = model.generate(**enc, max_new_tokens=max_new_tokens, do_sample=False, use_cache=True)
            outs += self.tok.batch_decode(gen[:, enc["input_ids"].shape[1] :], skip_special_tokens=True)
        model.train(was_training)
        return outs, (time.time() - t0) * 1000 / max(1, len(prompts))


def evaluate(rows: list[dict[str, Any]], outputs: list[str]) -> dict[str, float]:
    return mean_scores(
        [score(o, r.get("gold") or json.loads(r["completion"])) for r, o in zip(rows, outputs, strict=True)]
    )


def _chunk_loss(lm_head: Any, hidden: torch.Tensor, targets: torch.Tensor) -> torch.Tensor:
    return torch.nn.functional.cross_entropy(lm_head(hidden).float(), targets, reduction="sum")


def completion_loss(model: Any, prompt_ids: list[int], completion_ids: list[int]) -> torch.Tensor:
    """Next-token cross-entropy on the completion only.

    Logits are computed for completion positions only, in checkpointed chunks: a 900-token completion
    times the 248k vocabulary is ~0.9 GB of float32 logits, too much to keep around on a 4 GB GPU.
    """
    device = model.get_input_embeddings().weight.device
    ids = torch.tensor([prompt_ids + completion_ids], device=device)
    causal_lm = model.get_base_model()  # LoRA layers are injected in place, so they still apply
    hidden = causal_lm.model(input_ids=ids).last_hidden_state[0]
    start = len(prompt_ids) - 1  # the hidden state at position t predicts token t+1
    hidden = hidden[start : start + len(completion_ids)]
    targets = torch.tensor(completion_ids, device=device)
    chunks = [
        checkpoint(
            _chunk_loss,
            causal_lm.lm_head,
            hidden[i : i + LOSS_CHUNK],
            targets[i : i + LOSS_CHUNK],
            use_reentrant=False,
        )
        for i in range(0, len(completion_ids), LOSS_CHUNK)
    ]
    return torch.stack(chunks).sum() / len(completion_ids)


def train(runner: Runner, args: argparse.Namespace, out: Path) -> None:
    tok = runner.tok
    rows = read_jsonl(llm_dir() / "sft_train.jsonl")
    random.shuffle(rows)
    data: list[tuple[list[int], list[int]]] = []
    for r in rows[: args.examples]:
        p = tok(runner.prompt_text(r["prompt"]), add_special_tokens=False)["input_ids"]
        c = tok(r["completion"] + tok.eos_token, add_special_tokens=False)["input_ids"]
        if len(p) + len(c) <= args.max_len:
            data.append((p, c))
    val = read_jsonl(llm_dir() / "sft_val.jsonl")[: args.eval_samples]

    # Frozen 4-bit base kept in bf16 (no fp32 upcast of the 254M-parameter embedding), LoRA adapters on
    # every linear layer, non-reentrant checkpointing so inputs need no requires_grad hook.
    base = runner.model
    for p in base.parameters():
        p.requires_grad_(False)
    base.config.use_cache = False
    base.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model = get_peft_model(
        base,
        LoraConfig(r=16, lora_alpha=32, lora_dropout=0.0, target_modules="all-linear", task_type="CAUSAL_LM"),
    )
    runner.model = model
    params = [p for p in model.parameters() if p.requires_grad]
    print(f"{len(data)} examples, {sum(p.numel() for p in params):,} trainable parameters", flush=True)

    order = [i for _ in range(math.ceil(args.epochs)) for i in random.sample(range(len(data)), len(data))]
    order = order[: round(len(data) * args.epochs)]
    total = math.ceil(len(order) / args.grad_accum)
    opt = torch.optim.AdamW(params, lr=args.lr, weight_decay=0.0)

    def lr_scale(step: int) -> float:
        if step < WARMUP_STEPS:
            return (step + 1) / WARMUP_STEPS
        return 0.5 * (1 + math.cos(math.pi * (step - WARMUP_STEPS) / max(1, total - WARMUP_STEPS)))

    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_scale)
    history: list[dict[str, Any]] = []
    log: list[dict[str, Any]] = []
    best, bad, step, loss_sum, n_sum = -1.0, 0, 0, 0.0, 0
    t0 = time.time()
    model.train()
    for k, i in enumerate(order):
        with torch.autocast("cuda", dtype=torch.bfloat16):
            loss = completion_loss(model, *data[i])
        (loss / args.grad_accum).backward()
        loss_sum, n_sum = loss_sum + loss.item(), n_sum + 1
        last = k == len(order) - 1
        if (k + 1) % args.grad_accum and not last:
            continue
        torch.nn.utils.clip_grad_norm_(params, 1.0)
        opt.step()
        sched.step()
        opt.zero_grad(set_to_none=True)
        step += 1
        if step % 10 == 0 or last:
            log.append(
                {
                    "step": step,
                    "of": total,
                    "loss": round(loss_sum / n_sum, 4),
                    "lr": sched.get_last_lr()[0],
                    "seconds": round(time.time() - t0),
                    "max_mem_gb": round(torch.cuda.max_memory_allocated() / 2**30, 2),
                }
            )
            print(json.dumps(log[-1]), flush=True)
            loss_sum, n_sum = 0.0, 0
        if step % args.eval_every and not last:
            continue
        outs, ms = runner.generate([r["prompt"] for r in val])
        m = evaluate(val, outs)
        history.append({"step": step, "ms_per_sample": ms, **m})
        print("val", json.dumps(history[-1]), flush=True)
        if m["tree_similarity"] > best:
            best, bad = m["tree_similarity"], 0
            model.save_pretrained(out / "adapter")
        else:
            bad += 1
        (out / "val_history.json").write_text(json.dumps(history, indent=1), encoding="utf-8")
        (out / "train_log.json").write_text(json.dumps(log, indent=1), encoding="utf-8")
        if bad >= args.patience:
            print(f"early stop after {bad} checks without improvement", flush=True)
            break
    print(f"best val tree similarity {best:.4f}", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen3.5-0.8B")
    ap.add_argument("--name", default=time.strftime("qwen-%Y%m%d-%H%M%S"))
    ap.add_argument("--examples", type=int, default=4000)
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--max-len", type=int, default=2048)
    ap.add_argument("--grad-accum", type=int, default=16, help="examples per optimizer step")
    ap.add_argument("--eval-every", type=int, default=50, help="optimizer steps between validation checks")
    ap.add_argument("--eval-samples", type=int, default=32)
    ap.add_argument("--patience", type=int, default=3)
    ap.add_argument("--test-samples", type=int, default=300)
    ap.add_argument("--no-4bit", action="store_true")
    ap.add_argument("--eval-only", action="store_true")
    ap.add_argument("--adapter", type=Path)
    args = ap.parse_args()
    out = data_root() / "runs" / "layout" / args.name
    out.mkdir(parents=True, exist_ok=True)
    (out / "config.json").write_text(json.dumps(vars(args), default=str, indent=1), encoding="utf-8")
    random.seed(1234)
    torch.manual_seed(1234)

    runner = Runner(args.model, load_4bit=not args.no_4bit)
    if not args.eval_only:
        train(runner, args, out)
        args.adapter = out / "adapter"
        del runner
        torch.cuda.empty_cache()
        runner = Runner(args.model, load_4bit=not args.no_4bit)  # fresh base, then the best adapter
    if args.adapter is not None:
        runner.model = PeftModel.from_pretrained(runner.model, str(args.adapter))
    for cond in ("gold", "recognizer"):
        path = llm_dir() / f"eval_test_{cond}.jsonl"
        if not path.exists():
            continue
        rows = read_jsonl(path)[: args.test_samples]
        outs, ms = runner.generate([r["prompt"] for r in rows])
        with (out / f"predictions_{cond}.jsonl").open("w", encoding="utf-8") as f:
            for r, o in zip(rows, outs, strict=True):
                f.write(json.dumps({"id": r["id"], "output": o, "ms": ms}) + "\n")
        print(cond, json.dumps(evaluate(rows, outs)), f"{ms:.0f} ms/sample", flush=True)


if __name__ == "__main__":
    main()
