"""UI spec v1: vocabulary, validation and canonical serialization (mirrored in app/lib/spec)."""

from s2a.spec.canonical import canonical_json, canonicalize
from s2a.spec.validate import Issue, is_valid, validate

__all__ = ["Issue", "canonical_json", "canonicalize", "is_valid", "validate"]
