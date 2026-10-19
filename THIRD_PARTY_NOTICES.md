# Third-party notices for optional CLAP support

Optional semantic support is not included in WaveSearch distributions. Users
who explicitly agree to the Settings download or invoke
`scripts/install-clap-model.sh` obtain these components directly:

- **muzaiten/clap-htsat-base-onnx**, pinned commit
  `d4d4372c9894b975ec118589b4f4328103796e15`. The repository identifies the
  exported model pack and its upstream LAION CLAP checkpoint. Review the model
  repository license and model card before use:
  <https://huggingface.co/muzaiten/clap-htsat-base-onnx>
- **LAION CLAP**, upstream source/model implementation, Apache License 2.0:
  <https://github.com/LAION-AI/CLAP>
- **ONNX Runtime 1.29.0**, MIT License. Its release archive contains `LICENSE`
  and `ThirdPartyNotices.txt`, which the installer preserves:
  <https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0>

WaveSearch does not relicense these works. Model weights may have dataset,
content, or use restrictions beyond source-code licensing; installation is an
explicit user decision.

The optional semantic relevance harness downloads a pinned 40-file subset of
**ESC-50** at commit `33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6`.
ESC-50 is distributed under CC BY-NC 3.0. The explicit fixture installer
preserves the dataset license, source filenames, fold/category metadata, and
per-file hashes; no ESC-50 audio is distributed with WaveSearch.
