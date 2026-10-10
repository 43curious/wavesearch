# Vendored ONNX Runtime C headers

This directory contains the minimum official header closure used by WaveSearch's
dynamically loaded C bridge:

- `onnxruntime_c_api.h`
- `onnxruntime_error_code.h`
- `onnxruntime_ep_c_api.h` (included by `onnxruntime_c_api.h`)

The files are unmodified copies from the official **ONNX Runtime 1.29.0**
`onnxruntime-osx-arm64-1.29.0` binary distribution. That distribution records
Git commit `2e2543fbe9fae542f921d47a72d21d5a4ef0b710`.

Source/project: <https://github.com/microsoft/onnxruntime>

`LICENSE` is ONNX Runtime's MIT license. `ThirdPartyNotices.txt` is copied from
the same 1.29.0 distribution. No ONNX Runtime binary is vendored or linked;
applications provide an explicit shared-library path at runtime.
