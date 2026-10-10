"""LAN mode: serve the fine-tuned layout model from the laptop over local Wi-Fi.

    python -m s2a.layout.server --backend llamacpp --model D:/sketch2app-data/llm/model-q4_k_m.gguf
    python -m s2a.layout.server --backend transformers --model D:/sketch2app-data/llm/merged [--load-4bit]

POST /generate {"prompt": str, "temperature": float, "max_tokens": int} -> {"output": str, "ms": float}
GET  /health -> {"backend": ..., "model": ...}

The server only hosts the model: the app builds the prompt (the format it was trained on) and does
validation, repair, retries and the rule-based fallback itself, identically in LAN and on-device mode.
With llama.cpp the output is grammar-constrained to JSON matching the UI spec schema (json-schema to
GBNF), so syntax errors and unknown node types are impossible by construction.
Bind to 0.0.0.0 so the tablet can reach it; there is no authentication, so use it on a private network.
"""

from __future__ import annotations

import argparse
import json
import time
from collections.abc import Callable
from typing import Any

from flask import Flask, jsonify, request

from s2a.spec.validate import SCHEMA_PATH

Generate = Callable[[str, float, int], str]


def echo_backend() -> Generate:
    """Test backend: returns the prompt's last line, so the HTTP contract can be tested without a model."""
    return lambda prompt, temperature, max_tokens: prompt.splitlines()[-1]


def transformers_backend(model_dir: str, load_4bit: bool) -> Generate:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tok = AutoTokenizer.from_pretrained(model_dir)
    kwargs: dict[str, Any] = {"device_map": "auto", "torch_dtype": torch.bfloat16}
    if load_4bit:
        from transformers import BitsAndBytesConfig

        kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_compute_dtype=torch.bfloat16
        )
    model = AutoModelForCausalLM.from_pretrained(model_dir, **kwargs)

    def generate(prompt: str, temperature: float, max_tokens: int) -> str:
        text = tok.apply_chat_template(
            [{"role": "user", "content": prompt}], tokenize=False, add_generation_prompt=True
        )
        enc = tok(text, return_tensors="pt", add_special_tokens=False).to(model.device)
        sample = temperature > 0
        out = model.generate(
            **enc, max_new_tokens=max_tokens, do_sample=sample, temperature=temperature if sample else None
        )
        return str(tok.decode(out[0, enc["input_ids"].shape[1] :], skip_special_tokens=True))

    return generate


def llamacpp_backend(gguf: str, gpu_layers: int) -> Generate:
    from llama_cpp import Llama

    llm = Llama(model_path=gguf, n_ctx=4096, n_gpu_layers=gpu_layers, verbose=False)
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def generate(prompt: str, temperature: float, max_tokens: int) -> str:
        res: Any = llm.create_chat_completion(
            messages=[{"role": "user", "content": prompt}],
            temperature=temperature,
            max_tokens=max_tokens,
            response_format={"type": "json_object", "schema": schema},
        )
        return str(res["choices"][0]["message"]["content"])

    return generate


def create_app(generate: Generate, backend: str, model: str) -> Flask:
    app = Flask(__name__)

    @app.get("/health")
    def health() -> Any:
        return jsonify(backend=backend, model=model)

    @app.post("/generate")
    def gen() -> Any:
        body = request.get_json(force=True, silent=True) or {}
        prompt = body.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            return jsonify(error="prompt (string) required"), 400
        temperature = float(body.get("temperature", 0.0))
        max_tokens = int(body.get("max_tokens", 1536))
        t0 = time.perf_counter()
        output = generate(prompt, temperature, max_tokens)
        return jsonify(output=output, ms=round((time.perf_counter() - t0) * 1000, 1))

    return app


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["llamacpp", "transformers", "echo"], required=True)
    ap.add_argument("--model", default="")
    ap.add_argument("--load-4bit", action="store_true")
    ap.add_argument("--gpu-layers", type=int, default=-1, help="llama.cpp layers on GPU (-1 = all)")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    if args.backend == "llamacpp":
        generate = llamacpp_backend(args.model, args.gpu_layers)
    elif args.backend == "transformers":
        generate = transformers_backend(args.model, args.load_4bit)
    else:
        generate = echo_backend()
    create_app(generate, args.backend, args.model).run(host=args.host, port=args.port, threaded=False)


if __name__ == "__main__":
    main()
