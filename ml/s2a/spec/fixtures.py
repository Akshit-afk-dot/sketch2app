"""Regenerate the expected canonical strings that both language test suites compare against.

Run after an intentional spec change:  python -m s2a.spec.fixtures
"""

import json
from pathlib import Path

from s2a.paths import SPEC_DIR
from s2a.spec.canonical import canonical_json
from s2a.spec.validate import validate

CANONICAL_DIR = SPEC_DIR / "fixtures" / "canonical"


def valid_inputs() -> list[Path]:
    """Every spec that must validate: the hand-written examples plus the valid edge-case fixtures."""
    return sorted((SPEC_DIR / "examples").glob("*.json")) + sorted(
        (SPEC_DIR / "fixtures" / "valid").glob("*.json")
    )


def main() -> None:
    CANONICAL_DIR.mkdir(parents=True, exist_ok=True)
    for path in valid_inputs():
        spec = json.loads(path.read_text(encoding="utf-8"))
        issues = validate(spec)
        if issues:
            raise SystemExit(f"{path.name} is invalid: {issues}")
        (CANONICAL_DIR / path.name).write_text(canonical_json(spec) + "\n", encoding="utf-8", newline="\n")
        print(f"wrote {path.name}")


if __name__ == "__main__":
    main()
