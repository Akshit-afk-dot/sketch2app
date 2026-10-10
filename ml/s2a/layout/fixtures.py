"""Write spec/fixtures/prompt/*.json (element list -> expected prompt) for the Python/Dart parity tests.

python -m s2a.layout.fixtures
"""

import json
from typing import Any

from s2a.data.build_dataset import out_root
from s2a.layout.prompt import build_prompt
from s2a.paths import SPEC_DIR

OUT = SPEC_DIR / "fixtures" / "prompt"


def main() -> None:
    golds = sorted((out_root() / "eval" / "val" / "gold").glob("*.json"))
    picked: list[tuple[str, dict[str, Any]]] = []
    multi = 0
    for p in golds:
        g = json.loads(p.read_text(encoding="utf-8"))
        has_arrows = bool(g["elements"]["arrows"])
        if (has_arrows and multi < 3) or (not has_arrows and len(picked) - multi < 3):
            multi += has_arrows
            picked.append((p.stem, g["elements"]))
        if len(picked) >= 6:
            break
    OUT.mkdir(parents=True, exist_ok=True)
    for stem, el in picked:
        (OUT / f"{stem}.json").write_text(
            json.dumps({"elements": el, "prompt": build_prompt(el)}), encoding="utf-8"
        )
        print(f"wrote {stem} ({len(el['elements'])} elements, {len(el['arrows'])} arrows)")


if __name__ == "__main__":
    main()
