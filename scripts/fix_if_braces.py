"""Add braces to `if` statements flagged by `flutter analyze` (curly_braces_in_flow_control_structures).

`dart format` splits long one-line ifs over two lines, which the lint then flags. This uses the
analyzer's reported line numbers, so collection-ifs inside literals are never touched.

    cd app && flutter analyze | python ../scripts/fix_if_braces.py
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

PATTERN = re.compile(r"- (\S+\.dart):(\d+):\d+ - curly_braces_in_flow_control_structures")


def fix(path: Path, body_lines: list[int]) -> None:
    lines = path.read_text(encoding="utf-8").split("\n")
    for start in sorted(body_lines, reverse=True):  # bottom-up keeps earlier line numbers valid
        i = start - 1
        head = i - 1
        indent = re.match(r"\s*", lines[head]).group(0)  # type: ignore[union-attr]
        while not lines[head].lstrip().startswith(("if ", "} else", "else")) and head > 0:
            head -= 1
            indent = re.match(r"\s*", lines[head]).group(0)  # type: ignore[union-attr]
        end = i
        while not lines[end].rstrip().endswith(";"):
            end += 1
        lines.insert(end + 1, indent + "}")
        lines[i - 1] = lines[i - 1].rstrip() + " {"
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main() -> None:
    hits: dict[str, list[int]] = defaultdict(list)
    for line in sys.stdin:
        m = PATTERN.search(line)
        if m:
            hits[m.group(1).replace("\\", "/")].append(int(m.group(2)))
    for file, nums in hits.items():
        fix(Path(file), nums)
        print(f"fixed {len(nums)} in {file}")


if __name__ == "__main__":
    main()
