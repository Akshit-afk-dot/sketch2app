"""Label vocabularies of the recognizer heads; torch-free so data workers can import them."""

STROKE_CLASSES = ("frame", "text", "shape", "arrow")
ELEMENT_TYPES = (
    "btn", "input", "text", "heading", "para", "img", "icon", "menu", "avatar", "check", "radio",
    "switch", "divider", "card", "appbar", "bottomnav", "fab", "listmark",
)  # fmt: skip
NONE_TYPE = len(ELEMENT_TYPES)  # frame and arrow strokes have no element type
