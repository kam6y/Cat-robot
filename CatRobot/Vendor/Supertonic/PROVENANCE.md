# Supertonic Swift helper

Source: https://github.com/supertone-oss-archive/supertonic
Commit: 1e9799e964ea4c0dad7cde993b65c3c813a7b373
Path: swift/Sources/Helper.swift
Code license: MIT (LICENSE alongside this file).
Model: supertone-oss-archive/supertonic-3, revision aafc6e32416a594460b32413efc49d7fe4ce6d46, OpenRAIL-M (downloaded assets/LICENSE).
ONNX Runtime SPM: exact 1.24.2, CPU only, intra-op threads 2.

Local changes: set ORT session intra-op threads to 2. Wrapper validates assets, input and PCM separately.
The upstream project is archived; no upstream support is assumed.

Imported into the production app from CatRobot comparison commit 68e9765. No inference changes during migration.
