#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xcodegen generate
xcodebuild \
  -project "${ROOT_DIR}/HorseWhisprer.xcodeproj" \
  -scheme HorseWhisprerDev \
  -configuration Dev \
  build
