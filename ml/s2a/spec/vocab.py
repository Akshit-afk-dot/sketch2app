"""Closed vocabulary of the UI spec.

These tables are the contract shared with the Dart side (app/lib/spec/vocab.dart). The cross-language
fixtures in spec/fixtures fail if the two drift apart.
"""

from typing import Final

VERSION: Final = 1

# Canonical key order per object kind. Fixed order makes serialization unique, which keeps LLM targets
# deterministic and lets us compare specs byte-for-byte.
KEY_ORDER: Final[dict[str, tuple[str, ...]]] = {
    "spec": ("v", "screens"),
    "screen": ("id", "title", "appbar", "body", "bottomnav", "fab"),
    "appbar": ("t", "title", "icons"),
    "bottomnav": ("t", "items"),
    "navitem": ("icon", "label", "go"),
    "fab": ("t", "icon", "go"),
    "col": ("t", "c"),
    "row": ("t", "c"),
    "card": ("t", "go", "c"),
    "list": ("t", "n", "item"),
    "grid": ("t", "cols", "n", "item"),
    "text": ("t", "v", "s", "go"),
    "para": ("t", "lines"),
    "btn": ("t", "label", "variant", "go"),
    "input": ("t", "label", "secure", "multiline"),
    "check": ("t", "label"),
    "radio": ("t", "options"),
    "switch": ("t", "label"),
    "img": ("t", "h"),
    "icon": ("t", "name", "go"),
    "avatar": ("t", "go"),
    "divider": ("t",),
    "spacer": ("t",),
}

# Body node types (screen slots appbar/bottomnav/fab are not allowed inside a body).
BODY_TYPES: Final = frozenset(
    k for k in KEY_ORDER if k not in {"spec", "screen", "appbar", "bottomnav", "navitem", "fab"}
)
CONTAINER_TYPES: Final = frozenset({"col", "row", "card"})
REPEAT_TYPES: Final = frozenset({"list", "grid"})

# Values equal to these are dropped by the canonicalizer: shorter targets, one spelling per meaning.
DEFAULTS: Final[dict[str, dict[str, object]]] = {
    "text": {"s": "body"},
    "btn": {"variant": "primary"},
    "input": {"secure": False, "multiline": False},
}

ICON_NAMES: Final = (
    "circle", "menu", "search", "home", "person", "settings", "add", "back", "forward", "close",
    "more", "favorite", "share", "bell", "chat", "camera", "cart", "star", "edit", "delete",
    "info", "mail", "phone", "location", "calendar", "check", "play", "image", "list", "filter",
    "lock", "logout", "send", "mic", "download", "refresh", "map", "music", "help",
)  # fmt: skip

MAX_DEPTH: Final = 10
