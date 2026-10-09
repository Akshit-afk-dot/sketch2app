"""Canonical form: fixed key order, defaults dropped, no whitespace.

One spec has exactly one canonical string. That matters for three reasons: SFT targets are deterministic
(the model never has to guess key order), exact-match metrics are meaningful, and the Dart serializer can
be tested byte-for-byte against this one.
"""

import json
from typing import Any

from s2a.spec.vocab import DEFAULTS, KEY_ORDER


def _scalar(value: Any) -> Any:
    # JSON Schema accepts 2.0 as an integer; emit it as 2 so Python and Dart agree byte-for-byte.
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def _ordered(obj: dict[str, Any], kind: str) -> dict[str, Any]:
    defaults = DEFAULTS.get(kind, {})
    out: dict[str, Any] = {}
    for key in KEY_ORDER[kind]:
        if key in obj and not (key in defaults and obj[key] == defaults[key]):
            out[key] = _scalar(obj[key])
    return out


def _node(node: dict[str, Any]) -> dict[str, Any]:
    out = _ordered(node, node["t"])
    if "c" in out:
        out["c"] = [_node(child) for child in out["c"]]
    if "item" in out:
        out["item"] = _node(out["item"])
    if node["t"] == "appbar" and "icons" in out:
        out["icons"] = [_node(icon) for icon in out["icons"]]
    return out


def _screen(screen: dict[str, Any]) -> dict[str, Any]:
    out = _ordered(screen, "screen")
    if "appbar" in out:
        out["appbar"] = _node(out["appbar"])
    out["body"] = _node(out["body"])
    if "bottomnav" in out:
        nav = _ordered(out["bottomnav"], "bottomnav")
        nav["items"] = [_ordered(item, "navitem") for item in nav["items"]]
        out["bottomnav"] = nav
    if "fab" in out:
        out["fab"] = _ordered(out["fab"], "fab")
    return out


def canonicalize(spec: dict[str, Any]) -> dict[str, Any]:
    """Return a new spec in canonical key order with default values removed. Input must be valid."""
    out = _ordered(spec, "spec")
    out["screens"] = [_screen(s) for s in spec["screens"]]
    return out


def canonical_json(spec: dict[str, Any]) -> str:
    """Serialize a valid spec to its unique canonical string."""
    return json.dumps(canonicalize(spec), ensure_ascii=False, separators=(",", ":"))
