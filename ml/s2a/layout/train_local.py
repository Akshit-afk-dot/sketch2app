"""Local LoRA fine-tuning of a small layout model (Qwen3.5-0.8B fits the 4 GB laptop GPU with QLoRA).

Mirrors notebooks/layout_sft.ipynb (same data files, prompt format, LoRA r=16/alpha=32 on all linear
layers, lr 2e-4, early stopping on validation tree similarity), so local and Colab runs are comparable.

    python -m s2a.layout.train_local --examples 4000 --epochs 2
    python -m s2a.layout.train_local --eval-only --adapter <run>/adapter     # test predictions only

Writes $S2A_DATA_ROOT/runs/layout/<name>/: adapter/, val_history.json, predictions_<cond>.jsonl, config.json.
"""

from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path
from typing import Any

import torch
from datasets import Dataset
from peft import LoraConfig, PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, TrainerCallback
from trl import SFTConfig, SFTTrainer

from s2a.layout.metrics import mean_scores, score
from s2a.layout.sft_data import llm_dir
from s2a.paths import data_root


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
        model.train()
        return outs, (time.time() - t0) * 1000 / max(1, len(prompts))


def evaluate(rows: list[dict[str, Any]], outputs: list[str]) -> dict[str, float]:
    return mean_scores(
        [score(o, r.get("gold") or json.loads(r["completion"])) for r, o in zip(rows, outputs, strict=True)]
    )


class TreeSimilarityEarlyStop(TrainerCallback):  # type: ignore[misc]
    """Every N steps: generate val specs, score tree similarity, keep the best adapter, stop on a plateau."""

    def __init__(
        self, runner: Runner, val: list[dict[str, Any]], out: Path, every: int, patience: int
    ) -> None:
        self.runner, self.val, self.out, self.every, self.patience = runner, val, out, every, patience
        self.best, self.bad = -1.0, 0
        self.history: list[dict[str, Any]] = []

    def on_step_end(self, args: Any, state: Any, control: Any, **kw: Any) -> None:
        if state.global_step % self.every:
            return
        outs, ms = self.runner.generate([r["prompt"] for r in self.val])
        m = evaluate(self.val, outs)
        self.history.append({"step": state.global_step, "ms_per_sample": ms, **m})
        print(json.dumps(self.history[-1]), flush=True)
        if m["tree_similarity"] > self.best:
            self.best, self.bad = m["tree_similarity"], 0
            kw["model"].save_pretrained(self.out / "adapter")
        else:
            self.bad += 1
            control.should_training_stop = self.bad >= self.patience
        (self.out / "val_history.json").write_text(json.dumps(self.history, indent=1), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen3.5-0.8B")
    ap.add_argument("--name", default=time.strftime("qwen-%Y%m%d-%H%M%S"))
    ap.add_argument("--examples", type=int, default=4000)
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--max-len", type=int, default=1536)
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--grad-accum", type=int, default=8)
    ap.add_argument("--eval-every", type=int, default=100)
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
    val = read_jsonl(llm_dir() / "sft_val.jsonl")[: args.eval_samples]
    if not args.eval_only:
        train = read_jsonl(llm_dir() / "sft_train.jsonl")
        random.shuffle(train)
        train = train[: args.examples]
        # Prompt/completion strings: TRL computes the loss on the completion (the JSON) only.
        ds = Dataset.from_list(
            [
                {
                    "prompt": runner.prompt_text(r["prompt"]),
                    "completion": r["completion"] + runner.tok.eos_token,
                }
                for r in train
            ]
        )
        early = TreeSimilarityEarlyStop(runner, val, out, args.eval_every, args.patience)
        trainer = SFTTrainer(
            model=runner.model,
            processing_class=runner.tok,
            train_dataset=ds,
            callbacks=[early],
            peft_config=LoraConfig(
                r=16, lora_alpha=32, lora_dropout=0.0, target_modules="all-linear", task_type="CAUSAL_LM"
            ),
            args=SFTConfig(
                output_dir=str(out / "trainer"),
                max_length=args.max_len,
                per_device_train_batch_size=args.batch,
                gradient_accumulation_steps=args.grad_accum,
                num_train_epochs=args.epochs,
                learning_rate=args.lr,
                warmup_steps=20,  # transformers 5 removed warmup_ratio
                lr_scheduler_type="cosine",
                gradient_checkpointing=True,
                bf16=True,
                logging_steps=10,
                save_strategy="no",
                report_to="none",
                seed=1234,
            ),
        )
        runner.model = trainer.model
        trainer.train()
        print(f"best val tree similarity {early.best:.4f}", flush=True)
        args.adapter = out / "adapter"
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
