"""Screen naming rule shared with the Dart layout builder (app/lib/layout/heuristic_layout.dart).

A gold spec's screen ids must be predictable from the sketch alone, otherwise the layout model is
trained to guess. Rule: title = app-bar title, else the first heading, else "Screen k"; id = slug of
the title, deduplicated with _2, _3. Checked against spec/fixtures/naming.json by both languages.
"""

import re

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
