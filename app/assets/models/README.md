Model files are not committed (they are build outputs). Produce them with:

    python -m s2a.recognizer.export --ckpt <run>/best.pt        # -> recognizer.onnx (+ parity report)

The app falls back to the rule-based recognizer when recognizer.onnx is missing.
