#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-horse-whisprer.sparkle}"
OUT_FILE="${1:-${HOME}/.config/horse-whisprer/sparkle-private-key.txt}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.1}"
GENERATOR_BIN="$(command -v generate_keys || true)"
TEMP_DIR=""

cleanup() {
  if [[ -n "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

trap cleanup EXIT

resolve_local_generator() {
  find "${ROOT_DIR}" "${HOME}/Library/Developer/Xcode/DerivedData" \
    \( -path "*/SourcePackages/artifacts/*/Sparkle/bin/generate_keys" \
    -o -path "*/SourcePackages/checkouts/Sparkle/generate_keys" \
    -o -path "*/SourcePackages/checkouts/sparkle/generate_keys" \) \
    -type f 2>/dev/null | sort -u | head -n 1
}

if [[ -z "${GENERATOR_BIN}" ]]; then
  GENERATOR_BIN="$(resolve_local_generator)"
fi

if [[ -z "${GENERATOR_BIN}" ]]; then
  TEMP_DIR="$(mktemp -d /tmp/horse-whisprer-sparkle.XXXXXX)"
  curl -fsSL -o "${TEMP_DIR}/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar -xf "${TEMP_DIR}/sparkle.tar.xz" -C "${TEMP_DIR}" ./bin/generate_keys
  GENERATOR_BIN="${TEMP_DIR}/bin/generate_keys"
fi

if ! "${GENERATOR_BIN}" --account "${ACCOUNT}" >/dev/null 2>&1; then
  echo "Failed to generate Sparkle keys." >&2
  exit 1
fi

PUBLIC_KEY="$("${GENERATOR_BIN}" --account "${ACCOUNT}" -p | tr -d '\r')"
if [[ -z "${PUBLIC_KEY}" ]]; then
  echo "Failed to read Sparkle public key." >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT_FILE}")"
if [[ ! -f "${OUT_FILE}" ]] && ! "${GENERATOR_BIN}" --account "${ACCOUNT}" -x "${OUT_FILE}" >/dev/null 2>&1; then
  echo "Failed to export Sparkle private key." >&2
  exit 1
fi

chmod 600 "${OUT_FILE}"

cat <<EOF
Sparkle public key (SUPublicEDKey):
${PUBLIC_KEY}

Private key saved to:
${OUT_FILE}

Provide the public key to your official release build via SPARKLE_PUBLIC_ED_KEY or private release config.
EOF
