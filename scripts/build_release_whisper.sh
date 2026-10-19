#!/usr/bin/env bash
# Build the pinned, portable universal runtime used by official releases.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="${1:?Usage: build_release_whisper.sh /path/to/whisper.cpp-v1.9.2}"
SOURCE="$(cd "$SOURCE" && pwd -P)"
PIN="306c88f4d1286aec1bf96e544632897886af5501"
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$PIN" ]] ||
   [[ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=normal)" ]]; then
  echo "Expected a clean whisper.cpp v1.9.2 checkout at $PIN" >&2
  exit 1
fi

BUILD_ROOT="$ROOT_DIR/Vendor/whisper-release-1.9.2"
OUTPUT="$BUILD_ROOT/bin/whisper-cli"
# __FILE__ diagnostics and debug information must not disclose the release
# machine's source/build paths. Quote each flag for CMake's shell command.
PREFIX_MAP_FLAGS="$(python3 - "$SOURCE" "$BUILD_ROOT" <<'PY'
import shlex, sys
print(' '.join('-ffile-prefix-map=' + shlex.quote(f'{path}={label}')
               for path, label in zip(sys.argv[1:], ('whisper.cpp', 'build'))))
PY
)"
for arch in arm64 x86_64; do
  cmake -S "$SOURCE" -B "$BUILD_ROOT/$arch" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
    "-DCMAKE_C_FLAGS=$PREFIX_MAP_FLAGS" "-DCMAKE_CXX_FLAGS=$PREFIX_MAP_FLAGS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON
  cmake --build "$BUILD_ROOT/$arch" --target whisper-cli --parallel 8
done
mkdir -p "$(dirname "$OUTPUT")"
CANDIDATE="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "$CANDIDATE"' EXIT
lipo -create "$BUILD_ROOT/arm64/bin/whisper-cli" \
  "$BUILD_ROOT/x86_64/bin/whisper-cli" -output "$CANDIDATE"
python3 - "$CANDIDATE" "$SOURCE" "$BUILD_ROOT" <<'PY'
from pathlib import Path
import subprocess, sys
architectures = set(subprocess.check_output(['/usr/bin/lipo', '-archs', sys.argv[1]], text=True).split())
if architectures != {'arm64', 'x86_64'}:
    raise SystemExit(f'Unexpected runtime architectures: {architectures}')
data = Path(sys.argv[1]).read_bytes()
if any(path.encode() in data for path in sys.argv[2:]):
    raise SystemExit('Runtime contains a private source/build path; do not distribute it')
PY
chmod 755 "$CANDIDATE"
mv -f "$CANDIDATE" "$OUTPUT"
echo "Built universal whisper.cpp v1.9.2: $OUTPUT"
