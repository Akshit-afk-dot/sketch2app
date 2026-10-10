"""Screen naming rule shared with the Dart layout builder (app/lib/layout/heuristic_layout.dart).

A gold spec's screen ids must be predictable from the sketch alone, otherwise the layout model is
trained to guess. Rule: title = app-bar title, else the first heading, else "Screen k"; id = slug of
the title, deduplicated with _2, _3. Checked against spec/fixtures/naming.json by both languages.
"""

import re
from typing import Any

DEFAULT_NAV_LABELS = ("Home", "Search", "Profile", "Settings", "More")


def slug(title: str) -> str:
    out = re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")
    if out and not re.match(r"[a-z]", out):
        out = f"s_{out}"
    return out


def screen_names(titles: list[str | None]) -> list[tuple[str, str]]:
    """(id, title) per screen, in screen order; None means the screen has no title or heading."""
    used: set[str] = set()
    out = []
    for k, t in enumerate(titles):
        title = t if t else f"Screen {k + 1}"
        base = slug(title) or f"screen{k + 1}"
        base = base[:28]
        sid, n = base, 2
        while sid in used:
            sid, n = f"{base}_{n}", n + 1
        used.add(sid)
        out.append((sid, title[:40]))
    return out


def screen_title(screen: dict[str, Any]) -> str | None:
    """The title the naming rule uses: app-bar title, else the first heading (h1/h2) in reading order."""
    if "appbar" in screen:
        return str(screen["appbar"]["title"])
    stack = [screen["body"]]
    while stack:
        n = stack.pop(0)
        if n["t"] == "text" and n.get("s") in ("h1", "h2"):
            return str(n["v"])
        stack.extend(n.get("c", []) + ([n["item"]] if "item" in n else []))
    return None
