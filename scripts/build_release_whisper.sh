#!/usr/bin/env bash
# Build the pinned, portable universal runtime used by official releases.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:?Usage: build_release_whisper.sh /path/to/whisper.cpp-v1.9.2}"
PIN="306c88f4d1286aec1bf96e544632897886af5501"
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$PIN" ]] ||
   [[ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=normal)" ]]; then
  echo "Expected a clean whisper.cpp v1.9.2 checkout at $PIN" >&2
  exit 1
fi

BUILD_ROOT="$ROOT_DIR/Vendor/whisper-release-1.9.2"
OUTPUT="$BUILD_ROOT/bin/whisper-cli"
for arch in arm64 x86_64; do
  cmake -S "$SOURCE" -B "$BUILD_ROOT/$arch" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON
  cmake --build "$BUILD_ROOT/$arch" --target whisper-cli --parallel 8
done
mkdir -p "$(dirname "$OUTPUT")"
lipo -create "$BUILD_ROOT/arm64/bin/whisper-cli" \
  "$BUILD_ROOT/x86_64/bin/whisper-cli" -output "$OUTPUT"
python3 - "$OUTPUT" <<'PY'
import subprocess, sys
architectures = set(subprocess.check_output(['/usr/bin/lipo', '-archs', sys.argv[1]], text=True).split())
if architectures != {'arm64', 'x86_64'}:
    raise SystemExit(f'Unexpected runtime architectures: {architectures}')
PY
echo "Built universal whisper.cpp v1.9.2: $OUTPUT"
