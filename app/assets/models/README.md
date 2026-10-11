Model files are not committed (they are build outputs). Produce them with:

    python -m s2a.recognizer.export --ckpt <run>/best.pt                               # -> recognizer.onnx (pen ink)
    S2A_DATASET=v1-photo python -m s2a.recognizer.export --ckpt <photo run>/best.pt \
        --name recognizer_photo                                                           # -> recognizer_photo.onnx

Each export also writes a PyTorch-vs-ONNX parity report next to the model. Without recognizer_photo.onnx,
photos use the pen-ink model; without either, the app uses the rule-based recognizer.
