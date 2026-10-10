"""Layout-stage tests: metrics, noise model, LAN server contract."""

import json
from typing import Any

import numpy as np

from s2a.layout.metrics import mean_scores, parse_output, score, tree_similarity
from s2a.layout.noise import corrupt
from s2a.layout.server import create_app, echo_backend
from s2a.paths import SPEC_DIR
from s2a.spec import canonical_json


def _spec(stem: str) -> dict[str, Any]:
    return json.loads((SPEC_DIR / "examples" / f"{stem}.json").read_text(encoding="utf-8"))  # type: ignore[no-any-return]


def test_perfect_prediction_scores_one() -> None:
    gold = _spec("10_login_list_nav")
    s = score(canonical_json(gold), gold)
    assert s == {
        "json_valid": 1.0, "schema_valid": 1.0, "tree_similarity": 1.0, "type_f1": 1.0, "link_f1": 1.0,
        "label_accuracy": 1.0, "screens_correct": 1.0,
    }  # fmt: skip


def test_invalid_outputs_score_zero_and_link_metric_only_when_defined() -> None:
    gold = _spec("01_login")
    assert score("not json", gold)["json_valid"] == 0.0
    s = score('{"v": 2}', gold)
    assert s["json_valid"] == 1.0 and s["schema_valid"] == 0.0 and s["tree_similarity"] == 0.0
    assert s["link_f1"] is None, "gold has no links: metric undefined, not a free 1.0"
    m = mean_scores([score(canonical_json(gold), gold), s])
    assert m["schema_valid"] == 0.5 and "link_f1" in m


def test_tree_similarity_degrades_with_structural_errors() -> None:
    gold = _spec("01_login")
    pred = json.loads(canonical_json(gold))
    pred["screens"][0]["body"]["c"].pop()  # one element missing
    sim = tree_similarity(pred, gold)
    assert 0.8 < sim < 1.0


def test_parse_output_tolerates_prose() -> None:
    assert parse_output('Sure! {"a": 1} hope that helps') == {"a": 1}
    assert parse_output("no braces") is None


def test_noise_model_applies_measured_rates() -> None:
    el = {
        "v": 1,
        "frames": [{"id": 0, "box": [0, 0, 360, 720]}],
        "elements": [
            {"id": i, "type": "btn", "box": [10, 10 + 60 * i, 300, 40], "frame": 0, "text": "Sign in"}
            for i in range(200)
        ],
        "arrows": [],
    }
    stats = {
        "miss_rate": {"btn": 0.25},
        "confusion": {"btn": {"btn": 0.5, "card": 0.5}},
        "false_positives_per_sketch": 3.0,
        "false_positive_types": {"text": 1.0},
        "box_offset_std": 0.01,
        "cer": 0.0,
        "missing_text": 0.0,
    }
    out = corrupt(el, stats, np.random.default_rng(0))
    btn_like = [e for e in out["elements"] if e["id"] < 10_000]
    assert 120 < len(btn_like) < 180, "about 25% missed"
    types = {e["type"] for e in btn_like}
    assert types == {"btn", "card"}
    clean = corrupt(el, stats, np.random.default_rng(0), strength=0.0)
    assert clean["elements"] == el["elements"]


def test_server_generate_contract() -> None:
    client = create_app(echo_backend(), "echo", "none").test_client()
    assert client.get("/health").get_json() == {"backend": "echo", "model": "none"}
    r = client.post("/generate", json={"prompt": "Convert...\nS1\n1 btn 1,2,3,4", "temperature": 0.3})
    assert r.status_code == 200 and r.get_json()["output"] == "1 btn 1,2,3,4"
    assert client.post("/generate", json={"temperature": 0}).status_code == 400
