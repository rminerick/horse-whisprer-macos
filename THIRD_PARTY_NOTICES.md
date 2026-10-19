# Third-Party Notices

Horse Whisprer includes or depends on third-party software. Review the upstream projects for full license text and any additional notice requirements.

## whisper.cpp

- Project: `ggml-org/whisper.cpp`
- Use in this repo: local speech-to-text runtime and model/bootstrap workflow
- License: MIT
- Upstream: https://github.com/ggml-org/whisper.cpp

## Sparkle

- Project: `sparkle-project/Sparkle`
- Use in this repo: automatic updates for official signed builds
- License: MIT
- Upstream: https://github.com/sparkle-project/Sparkle

The app bundle also ships in-app credits via `Sources/HorseWhisprer/Credits.rtf`.

## FluidAudio and native speech models

- Runtime: FluidInference/FluidAudio 0.17.1 (Apache-2.0), https://github.com/FluidInference/FluidAudio
- Used for local Parakeet Unified and Nemotron streaming inference through Core ML.
- The app bundles FluidAudio and its dependency notices in `FluidAudio-Licenses.txt`.
- Model weights are downloaded separately from FluidInference on Hugging Face. Parakeet Unified and Nemotron English model terms are provided by NVIDIA:
  - https://huggingface.co/nvidia/parakeet-unified-en-0.6b
  - https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
