#!/usr/bin/env bash

set -euo pipefail

MODEL_NAME="${1:-base.en}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/whisper.cpp"

mkdir -p "$ROOT_DIR/Vendor"

if [[ ! -d "$VENDOR_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$VENDOR_DIR"
fi

cd "$VENDOR_DIR"
cmake -B build
cmake --build build -j --config Release --target whisper-cli
./models/download-ggml-model.sh "$MODEL_NAME"

echo
echo "whisper-cli path:"
echo "  $VENDOR_DIR/build/bin/whisper-cli"
echo
echo "model directory:"
echo "  $VENDOR_DIR/models"
