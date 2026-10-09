"""Data pipeline tests: RICO conversion, XY-cut, sanitizing, splits, and synthetic sample invariants."""

import json
from collections import Counter
from typing import Any

import numpy as np
import pytest
import yaml

from s2a.data.build_dataset import CONFIG, split_of
from s2a.data.download import hershey_dir
from s2a.data.hershey import parse_jhf
from s2a.data.rico_convert import Placed, convert_screen, label_from_id, sanitize, xy_cut
from s2a.paths import SPEC_DIR
from s2a.spec import canonical_json, validate

FONTS_PRESENT = (hershey_dir() / "futural.jhf").exists()
needs_fonts = pytest.mark.skipif(not FONTS_PRESENT, reason="run `python -m s2a.data.download hershey` first")


def _node(label: str, box: list[int], **kw: Any) -> dict[str, Any]:
    return {"componentLabel": label, "bounds": box, "class": kw.pop("cls", "android.widget.View"), **kw}


def _rico_screen() -> dict[str, Any]:
    """A small RICO-like hierarchy: toolbar, a 2-item list, a password input and a button."""
    item = lambda y: _node(  # noqa: E731
        "List Item",
        [0, y, 1440, y + 200],
        children=[
            _node("Image", [40, y + 20, 200, y + 180], cls="android.widget.ImageView"),
            _node("Text", [240, y + 60, 900, y + 120], text="Order #12"),
        ],
    )
    return {
        "bounds": [0, 0, 1440, 2560],
        "children": [
            _node(
                "Toolbar",
                [0, 0, 1440, 200],
                children=[
                    _node("Text", [200, 60, 700, 140], text="My Orders"),
                    _node("Icon", [1300, 60, 1400, 140], iconClass="search"),
                ],
            ),
            item(300),
            item(520),
            _node("Input", [40, 900, 1400, 1020], **{"resource-id": "com.x:id/et_login_password"}),
            _node("Text Button", [40, 1100, 1400, 1220], text="Sign in", cls="android.widget.Button"),
        ],
    }


def test_rico_conversion_recovers_structure() -> None:
    result = convert_screen(_rico_screen())
    assert result.reason == "ok", result.reason
    spec = result.spec
    assert spec is not None and validate(spec) == []
    screen = spec["screens"][0]
    assert screen["appbar"] == {
        "t": "appbar",
        "title": "My Orders",
        "icons": [{"t": "icon", "name": "search"}],
    }
    body = screen["body"]["c"]
    assert body[0]["t"] == "list" and body[0]["n"] == 2
    assert body[1] == {"t": "input", "label": "Login password", "secure": True}
    assert body[2] == {"t": "btn", "label": "Sign in"}


@pytest.mark.parametrize(
    ("mutate", "reason"),
    [
        (lambda s: s["children"].append(_node("Drawer", [0, 0, 800, 2560])), "overlay"),
        (lambda s: s.update(bounds=[0, 0, 2560, 1440]), "not_portrait"),
        (
            lambda s: s["children"].__setitem__(
                slice(0, None), [_node("Text", [0, 0, 100, 50], text="日本語テキスト")]
            ),
            "non_latin",
        ),
    ],
)
def test_rico_filters(mutate: Any, reason: str) -> None:
    screen = _rico_screen()
    mutate(screen)
    assert convert_screen(screen).reason == reason


def test_label_from_resource_id() -> None:
    assert label_from_id("et_new_login_password") == "Login password"
    assert label_from_id("editTextEmail") == "Email"


def test_xy_cut_nests_rows_and_columns() -> None:
    """Thumbnail left, title over description right -> row[img, col[text, para]]."""
    items = [
        Placed((0, 0, 100, 100), {"t": "img", "h": 10}, "Image"),
        Placed((120, 0, 500, 40), {"t": "text", "v": "Title"}, "Text"),
        Placed((120, 50, 500, 100), {"t": "para", "lines": 2}, "Text"),
        Placed((0, 150, 500, 200), {"t": "btn", "label": "Go"}, "Text Button"),
    ]
    out = xy_cut(items)
    assert out == [
        {
            "t": "row",
            "c": [
                {"t": "img", "h": 10},
                {"t": "col", "c": [{"t": "text", "v": "Title"}, {"t": "para", "lines": 2}]},
            ],
        },
        {"t": "btn", "label": "Go"},
    ]


def test_sanitize_enforces_schema_rules() -> None:
    tree = {
        "t": "col",
        "c": [
            {"t": "radio", "options": ["Only"]},
            {"t": "row", "c": [{"t": "text", "v": "solo"}]},
            {
                "t": "list",
                "n": 3,
                "item": {"t": "card", "c": [{"t": "list", "n": 2, "item": {"t": "text", "v": "x"}}]},
            },
        ],
    }
    out = sanitize(tree)
    assert out is not None
    spec = {"v": 1, "screens": [{"id": "a", "title": "A", "body": out}]}
    assert validate(spec) == []
    assert out["c"][0] == {"t": "check", "label": "Only"}
    assert out["c"][1] == {"t": "text", "v": "solo"}
    assert out["c"][2]["item"]["c"][0] == {"t": "text", "v": "x"}, "inner repeat unwrapped"


def test_split_by_app_is_stable_and_roughly_proportional() -> None:
    pct = {"train": 80, "val": 10, "test": 10}
    apps = [f"com.example.app{i}" for i in range(5000)]
    counts = Counter(split_of(a, pct) for a in apps)
    assert split_of("com.a.b", pct) == split_of("com.a.b", pct)
    assert 0.77 < counts["train"] / 5000 < 0.83
    assert 0.08 < counts["val"] / 5000 < 0.12


def test_parse_jhf_line() -> None:
    glyphs = parse_jhf("12345  3MWRFRT\n")
    g = glyphs[" "]
    assert (g.left, g.right) == (-5, 5)
    assert g.paths == (((0, -12), (0, 2)),)


@needs_fonts
@pytest.mark.parametrize("stem", ["01_login", "06_settings", "10_login_list_nav", "11_shop_3screen"])
def test_synthetic_sample_invariants(stem: str) -> None:
    from s2a.data.synth import STROKE_CLASSES, make_sample

    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    spec = json.loads((SPEC_DIR / "examples" / f"{stem}.json").read_text(encoding="utf-8"))
    screens = [{"v": 1, "screens": [s]} for s in spec["screens"]]
    sample = make_sample(np.random.default_rng(42), cfg, screens)
    assert sample is not None
    assert validate(sample.spec) == []
    n = len(sample.ink["strokes"])
    assert len(sample.stroke_cls) == len(sample.stroke_group) == n
    assert set(sample.stroke_cls) <= set(STROKE_CLASSES)
    # Element strokes partition exactly the strokes of element groups.
    owned = [i for e in sample.elements["elements"] for i in e["strokes"]]
    element_strokes = [i for i, g in enumerate(sample.stroke_group) if sample.groups[g]["kind"] == "element"]
    assert sorted(owned) == sorted(element_strokes)
    assert all(set(e.get("text_strokes", [])) <= set(e["strokes"]) for e in sample.elements["elements"])
    # Timestamps never go backwards in drawing order.
    times = [p[2] for s in sample.ink["strokes"] for p in s["pts"]]
    assert times == sorted(times)
    if len(spec["screens"]) > 1:
        assert sample.elements["arrows"], "multi-screen samples draw navigation arrows"
        assert '"go":' in canonical_json(sample.spec)
    again = make_sample(np.random.default_rng(42), cfg, screens)
    assert again is not None and again.ink == sample.ink, "same seed, same sample"
