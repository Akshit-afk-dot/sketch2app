"""Spec validation: JSON Schema for structure, plus semantic rules a schema cannot express.

Every issue carries a stable ``code`` so the Python and Dart validators can be checked against the same
fixtures (spec/fixtures/invalid/<code>__*.json).

Codes:
    schema   structural violation (unknown key, wrong type, out-of-range value, unknown node type)
    dup_id   two screens share an id
    bad_go   a navigation target is not a screen id
    nesting  a list/grid inside a list/grid item (repetition of repetition is not representable)
    depth    body nesting deeper than MAX_DEPTH
"""

import json
from collections.abc import Iterator
from dataclasses import dataclass
from functools import cache
from typing import Any

from jsonschema import Draft202012Validator

from s2a.paths import SPEC_DIR
from s2a.spec.vocab import MAX_DEPTH, REPEAT_TYPES

SCHEMA_PATH = SPEC_DIR / "schema" / "ui_spec.v1.schema.json"


@dataclass(frozen=True)
class Issue:
    code: str
    path: str
    message: str


@cache
def _schema_validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def _pointer(parts: Any) -> str:
    return "/" + "/".join(str(p) for p in parts)


def validate(spec: Any) -> list[Issue]:
    """Return all issues; an empty list means the spec is valid.

    Semantic checks only run on structurally valid specs, because they assume the shape is right.
    """
    issues = [
        Issue("schema", _pointer(e.absolute_path), e.message)
        for e in sorted(_schema_validator().iter_errors(spec), key=lambda e: list(map(str, e.absolute_path)))
    ]
    if issues:
        return issues
    return _semantic_issues(spec)


def is_valid(spec: Any) -> bool:
    return not validate(spec)


def _semantic_issues(spec: dict[str, Any]) -> list[Issue]:
    issues: list[Issue] = []
    ids = [s["id"] for s in spec["screens"]]
    seen: set[str] = set()
    for i, sid in enumerate(ids):
        if sid in seen:
            issues.append(Issue("dup_id", f"/screens/{i}/id", f"duplicate screen id {sid!r}"))
        seen.add(sid)

    for i, screen in enumerate(spec["screens"]):
        base = f"/screens/{i}"
        for path, target in _go_targets(screen, base):
            if target not in seen:
                issues.append(Issue("bad_go", path, f"navigation target {target!r} is not a screen id"))
        issues.extend(_structure_issues(screen["body"], f"{base}/body", depth=1, in_repeat=False))
    return issues


def _go_targets(screen: dict[str, Any], base: str) -> Iterator[tuple[str, str]]:
    appbar = screen.get("appbar")
    if appbar:
        for j, icon in enumerate(appbar.get("icons", [])):
            if "go" in icon:
                yield f"{base}/appbar/icons/{j}/go", icon["go"]
    for path, node in _walk(screen["body"], f"{base}/body"):
        if "go" in node:
            yield f"{path}/go", node["go"]
    nav = screen.get("bottomnav")
    if nav:
        for j, item in enumerate(nav["items"]):
            if "go" in item:
                yield f"{base}/bottomnav/items/{j}/go", item["go"]
    fab = screen.get("fab")
    if fab and "go" in fab:
        yield f"{base}/fab/go", fab["go"]


def _children(node: dict[str, Any], path: str) -> Iterator[tuple[str, dict[str, Any]]]:
    for j, child in enumerate(node.get("c", [])):
        yield f"{path}/c/{j}", child
    if "item" in node:
        yield f"{path}/item", node["item"]


def _walk(node: dict[str, Any], path: str) -> Iterator[tuple[str, dict[str, Any]]]:
    yield path, node
    for child_path, child in _children(node, path):
        yield from _walk(child, child_path)


def _structure_issues(node: dict[str, Any], path: str, depth: int, in_repeat: bool) -> list[Issue]:
    if depth > MAX_DEPTH:
        return [Issue("depth", path, f"nesting deeper than {MAX_DEPTH}")]
    issues: list[Issue] = []
    is_repeat = node["t"] in REPEAT_TYPES
    if is_repeat and in_repeat:
        issues.append(Issue("nesting", path, f"{node['t']} inside a repeated item"))
    for child_path, child in _children(node, path):
        issues.extend(_structure_issues(child, child_path, depth + 1, in_repeat or is_repeat))
    return issues
