"""Spec contract tests. The same fixtures are checked by app/test/spec_conformance_test.dart."""

import json
from pathlib import Path

import pytest

from s2a.paths import SPEC_DIR
from s2a.spec import canonical_json, canonicalize, validate
from s2a.spec.fixtures import CANONICAL_DIR, valid_inputs
from s2a.spec.validate import SCHEMA_PATH
from s2a.spec.vocab import BODY_TYPES, ICON_NAMES

INVALID = sorted((SPEC_DIR / "fixtures" / "invalid").glob("*.json"))


def _load(path: Path) -> dict:  # type: ignore[type-arg]
    return json.loads(path.read_text(encoding="utf-8"))  # type: ignore[no-any-return]


def test_vocab_matches_schema() -> None:
    schema = _load(SCHEMA_PATH)
    assert tuple(schema["$defs"]["iconName"]["enum"]) == ICON_NAMES
    node_refs = {ref["$ref"].rsplit("/", 1)[1] for ref in schema["$defs"]["node"]["oneOf"]}
    assert node_refs == BODY_TYPES


@pytest.mark.parametrize("path", valid_inputs(), ids=lambda p: p.name)
def test_valid_specs_have_no_issues(path: Path) -> None:
    assert validate(_load(path)) == []


@pytest.mark.parametrize("path", INVALID, ids=lambda p: p.name)
def test_invalid_specs_report_expected_code(path: Path) -> None:
    expected = path.name.split("__", 1)[0]
    codes = {issue.code for issue in validate(_load(path))}
    assert expected in codes, codes


@pytest.mark.parametrize("path", valid_inputs(), ids=lambda p: p.name)
def test_canonical_matches_committed_fixture(path: Path) -> None:
    expected = (CANONICAL_DIR / path.name).read_text(encoding="utf-8").removesuffix("\n")
    assert canonical_json(_load(path)) == expected


@pytest.mark.parametrize("path", valid_inputs(), ids=lambda p: p.name)
def test_canonical_is_idempotent_and_valid(path: Path) -> None:
    once = canonical_json(_load(path))
    again = json.loads(once)
    assert validate(again) == []
    assert canonical_json(again) == once


def test_canonical_drops_defaults_only() -> None:
    spec = _load(SPEC_DIR / "fixtures" / "valid" / "explicit_defaults.json")
    body = canonicalize(spec)["screens"][0]["body"]["c"]
    assert body[0] == {"t": "text", "v": "Hello"}
    assert body[1] == {"t": "btn", "label": "Go"}
    assert body[2] == {"t": "input", "label": "Name"}
    assert body[3] == {"t": "input", "label": "Bio", "multiline": True}


def test_canonical_key_order() -> None:
    spec = _load(SPEC_DIR / "fixtures" / "valid" / "key_order_scrambled.json")
    text = canonical_json(spec)
    assert text.startswith('{"v":1,"screens":[{"id":"a","title":"A","appbar":{"t":"appbar","title":"A"')
    assert '"bottomnav":{"t":"bottomnav","items":[{"icon":"home","label":"B","go":"b"}' in text
    assert '{"t":"grid","cols":2,"n":4,"item":{"t":"img","h":10}}' in text


def test_screen_naming_fixture() -> None:
    from s2a.spec.naming import screen_names

    for case in _load(SPEC_DIR / "fixtures" / "naming.json")["cases"]:
        assert [sid for sid, _ in screen_names(case["titles"])] == case["ids"]
