#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/HorseWhisprer.xcodeproj"
SCHEME="HorseWhisprer"
TARGET_NAME="HorseWhisprer"
CONFIGURATION="Release"
PRODUCT_NAME="Horse Whisprer"
TEAM_ID="${TEAM_ID:-}"
IDENTITY="${IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION_OVERRIDE="${VERSION_OVERRIDE:-}"
BUILD_OVERRIDE="${BUILD_OVERRIDE:-}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-}"
PRODUCT_PAGE_URL="${PRODUCT_PAGE_URL:-}"
RELEASE_NOTES_BASE_URL="${RELEASE_NOTES_BASE_URL:-}"
APPCAST_URL="${APPCAST_URL:-}"
APPCAST_CHANNEL="${APPCAST_CHANNEL:-}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-26.0}"
CUSTOM_DIST_DIR="${DIST_DIR:+1}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
ARCHIVE_PATH="${DIST_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_PATH="${DIST_DIR}/export"
APP_PATH="${EXPORT_PATH}/${PRODUCT_NAME}.app"
APP_NOTARY_ZIP_PATH="${DIST_DIR}/${PRODUCT_NAME}-notary.zip"
EXPORT_OPTIONS_PLIST_TEMPLATE="${ROOT_DIR}/scripts/export-options-developer-id.plist"
IN_APP_FEED_URL="${IN_APP_FEED_URL:-${APPCAST_URL}}"
HORSEWHISPRER_DISTRIBUTION_FLAVOR="${HORSEWHISPRER_DISTRIBUTION_FLAVOR:-official}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-${HOME}/.config/horse-whisprer/sparkle-private-key.txt}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-}"
EXPORT_OPTIONS_PLIST=""

usage() {
  cat <<EOF
Usage: ./scripts/distribute_macos.sh [options]

Builds an official Developer ID signed release with:
  - exported .app
  - notarized DMG
  - Sparkle update ZIP
  - production appcast XML

Options:
  --notarize <keychain-profile>  Submit app + DMG for notarization using notarytool
  --identity <name>              Override signing identity
  --team-id <id>                 Override team ID
  --version <version>            Override MARKETING_VERSION
  --build <number>               Override CURRENT_PROJECT_VERSION
  --download-base-url <url>      Base URL for published download assets
  --product-page-url <url>       Public product page URL
  --release-notes-base-url <url> Base URL for release note pages
  --appcast-url <url>            Published appcast URL
  --feed-url <url>               Embed this Sparkle feed URL in the signed app
  --sparkle-private-key-file <path>
                                  Sparkle private key file for signing update ZIPs
  --sparkle-key-account <account> Sparkle keychain account fallback when no key file exists
  -h, --help                     Show this help

Examples:
  TEAM_ID=<team-id> SPARKLE_PUBLIC_ED_KEY=<sparkle-public-ed-key> DOWNLOAD_BASE_URL=https://downloads.example.com/horse-whisprer PRODUCT_PAGE_URL=https://example.com/horse-whisprer RELEASE_NOTES_BASE_URL=https://example.com/horse-whisprer/release-notes APPCAST_URL=https://downloads.example.com/updates/horse-whisprer.xml ./scripts/distribute_macos.sh
  TEAM_ID=<team-id> SPARKLE_PUBLIC_ED_KEY=<sparkle-public-ed-key> DOWNLOAD_BASE_URL=https://downloads.example.com/horse-whisprer PRODUCT_PAGE_URL=https://example.com/horse-whisprer RELEASE_NOTES_BASE_URL=https://example.com/horse-whisprer/release-notes APPCAST_URL=https://downloads.example.com/updates/horse-whisprer.xml ./scripts/distribute_macos.sh --notarize YOUR_NOTARY_PROFILE
  TEAM_ID=<team-id> SPARKLE_PUBLIC_ED_KEY=<sparkle-public-ed-key> DOWNLOAD_BASE_URL=https://downloads.example.com/horse-whisprer PRODUCT_PAGE_URL=https://example.com/horse-whisprer RELEASE_NOTES_BASE_URL=https://example.com/horse-whisprer/release-notes APPCAST_URL=https://downloads.example.com/updates/horse-whisprer.xml ./scripts/distribute_macos.sh --version 1.0.1 --build 3
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --version)
      VERSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --build)
      BUILD_OVERRIDE="${2:-}"
      shift 2
      ;;
    --download-base-url)
      DOWNLOAD_BASE_URL="${2:-}"
      shift 2
      ;;
    --product-page-url)
      PRODUCT_PAGE_URL="${2:-}"
      shift 2
      ;;
    --release-notes-base-url)
      RELEASE_NOTES_BASE_URL="${2:-}"
      shift 2
      ;;
    --appcast-url)
      APPCAST_URL="${2:-}"
      shift 2
      ;;
    --feed-url)
      IN_APP_FEED_URL="${2:-}"
      shift 2
      ;;
    --sparkle-private-key-file)
      SPARKLE_PRIVATE_KEY_FILE="${2:-}"
      shift 2
      ;;
    --sparkle-key-account)
      SPARKLE_KEY_ACCOUNT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${IN_APP_FEED_URL}" ]]; then
  IN_APP_FEED_URL="${APPCAST_URL}"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required." >&2
    exit 1
  fi
}

require_value() {
  local value="$1"
  local name="$2"

  if [[ -z "${value}" ]]; then
    echo "${name} is required." >&2
    exit 1
  fi
}

validate_notary_profile() {
  local profile="$1"

  if [[ -z "${profile}" ]]; then
    return
  fi

  echo "Validating notary profile ${profile}..."
  if ! xcrun notarytool history --keychain-profile "${profile}" --output-format json >/dev/null; then
    echo "Unable to validate notary profile: ${profile}" >&2
    echo "Create it with: xcrun notarytool store-credentials ${profile} --apple-id <apple-id> --team-id ${TEAM_ID}" >&2
    exit 1
  fi
}

submit_for_notarization() {
  local artifact="$1"
  local profile="$2"
  local result_path

  result_path="$(mktemp /tmp/horse-whisprer-notary.XXXXXX.log)"
  if ! xcrun notarytool submit "${artifact}" --keychain-profile "${profile}" --wait 2>&1 | tee "${result_path}"; then
    rm -f "${result_path}"
    exit 1
  fi

  if ! grep -Eq 'status:[[:space:]]+Accepted' "${result_path}"; then
    echo "Notarization was not accepted for ${artifact}." >&2
    rm -f "${result_path}"
    exit 1
  fi

  rm -f "${result_path}"
}

url_encode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1]))
PY
}

resolve_sparkle_tool() {
  local tool_name="$1"
  local search_root

  while IFS= read -r search_root; do
    if [[ -n "${search_root}" && -x "${search_root}" ]]; then
      printf '%s\n' "${search_root}"
      return 0
    fi
  done < <(
    find "${ROOT_DIR}" ~/Library/Developer/Xcode/DerivedData \
      \( -path "*/SourcePackages/artifacts/*/Sparkle/bin/${tool_name}" \
      -o -path "*/SourcePackages/checkouts/Sparkle/bin/${tool_name}" \
      -o -path "*/SourcePackages/checkouts/sparkle/bin/${tool_name}" \
      -o -path "*/SourcePackages/artifacts/*/sparkle/Sparkle/bin/${tool_name}" \
      -o -path "*/SourcePackages/artifacts/*/sparkle/bin/${tool_name}" \) \
      -type f 2>/dev/null | sort -u
  )

  return 1
}

build_setting() {
  local key="$1"
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -target "${TARGET_NAME}" \
    -configuration "${CONFIGURATION}" \
    -showBuildSettings |
    awk -F' = ' -v target="${key}" '$1 ~ target { print $2; exit }'
}

create_dmg() {
  local source_app="$1"
  local dmg_path="$2"
  local volume_name="$3"
  local temp_dir

  temp_dir="$(mktemp -d "/tmp/horse-whisprer-dmg.XXXXXX")"
  cp -R "${source_app}" "${temp_dir}/"
  ln -s /Applications "${temp_dir}/Applications"

  hdiutil create \
    -volname "${volume_name}" \
    -srcfolder "${temp_dir}" \
    -ov \
    -format UDZO \
    "${dmg_path}" >/dev/null

  rm -rf "${temp_dir}"
}

sign_dmg() {
  local dmg_path="$1"

  codesign --force --sign "${IDENTITY}" --timestamp "${dmg_path}"
}

generate_appcast() {
  local appcast_path="$1"
  local version="$2"
  local build="$3"
  local zip_url="$4"
  local zip_size="$5"
  local signature="$6"
  local release_notes_url="$7"
  local pub_date="$8"
  local channel_snippet=""

  if [[ -n "${APPCAST_CHANNEL}" ]]; then
    channel_snippet="      <sparkle:channel>${APPCAST_CHANNEL}</sparkle:channel>"
  fi

  cat > "${appcast_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Horse Whisprer Updates</title>
    <link>${PRODUCT_PAGE_URL}</link>
    <description>Production releases for Horse Whisprer.</description>
    <language>en</language>
    <item>
      <title>Horse Whisprer ${version}</title>
      <pubDate>${pub_date}</pubDate>
${channel_snippet}
      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${release_notes_url}</sparkle:releaseNotesLink>
      <enclosure
        url="${zip_url}"
        sparkle:version="${build}"
        sparkle:shortVersionString="${version}"
        sparkle:edSignature="${signature}"
        length="${zip_size}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
}

generate_release_metadata() {
  local output_path="$1"
  local version="$2"
  local build="$3"
  local app_path="$4"
  local dmg_path="$5"
  local zip_path="$6"
  local appcast_path="$7"
  local appcast_url="$8"
  local zip_url="$9"
  local dmg_url="${10}"
  local release_notes_url="${11}"
  local signature="${12}"
  local zip_size="${13}"

  python3 - "$output_path" "$version" "$build" "$app_path" "$dmg_path" "$zip_path" "$appcast_path" "$appcast_url" "$zip_url" "$dmg_url" "$release_notes_url" "$signature" "$zip_size" <<'PY'
import json
import sys

(
    output_path,
    version,
    build,
    app_path,
    dmg_path,
    zip_path,
    appcast_path,
    appcast_url,
    zip_url,
    dmg_url,
    release_notes_url,
    signature,
    zip_size,
) = sys.argv[1:]

payload = {
    "channel": "stable",
    "version": version,
    "build": build,
    "artifacts": {
        "app": {"path": app_path},
        "dmg": {"path": dmg_path, "url": dmg_url},
        "zip": {
            "path": zip_path,
            "url": zip_url,
            "sparkleEdSignature": signature,
            "length": int(zip_size),
        },
        "appcast": {"path": appcast_path, "url": appcast_url},
    },
    "releaseNotesURL": release_notes_url,
}

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

require_command xcodebuild
require_command xcodegen
require_command ditto
require_command xcrun
require_command hdiutil
require_command python3

require_value "${TEAM_ID}" "TEAM_ID"
require_value "${DOWNLOAD_BASE_URL}" "DOWNLOAD_BASE_URL"
require_value "${PRODUCT_PAGE_URL}" "PRODUCT_PAGE_URL"
require_value "${RELEASE_NOTES_BASE_URL}" "RELEASE_NOTES_BASE_URL"
require_value "${APPCAST_URL}" "APPCAST_URL"

validate_notary_profile "${NOTARY_PROFILE}"

if ! security find-identity -v -p codesigning | grep -F "${IDENTITY}" >/dev/null; then
  echo "Signing identity not found: ${IDENTITY}" >&2
  echo "Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

cd "${ROOT_DIR}"

echo "Generating Xcode project..."
xcodegen generate >/dev/null

echo "Resolving Swift packages..."
xcodebuild -resolvePackageDependencies -project "${PROJECT_PATH}" -scheme "${SCHEME}" >/dev/null

SPARKLE_SIGN_UPDATE_PATH="$(resolve_sparkle_tool sign_update || true)"
if [[ -z "${SPARKLE_SIGN_UPDATE_PATH}" ]]; then
  echo "Unable to locate Sparkle sign_update. Run ./scripts/setup_sparkle_keys.sh after resolving package dependencies." >&2
  exit 1
fi

PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(build_setting "SPARKLE_PUBLIC_ED_KEY")}"
if [[ -z "${PUBLIC_ED_KEY}" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY is empty. Export it in the environment or provide it from private release config before releasing." >&2
  exit 1
fi

VERSION="${VERSION_OVERRIDE:-$(build_setting "MARKETING_VERSION")}"
BUILD_NUMBER="${BUILD_OVERRIDE:-$(build_setting "CURRENT_PROJECT_VERSION")}"
ZIP_FILENAME="${PRODUCT_NAME}-${VERSION}.zip"
DMG_FILENAME="${PRODUCT_NAME}-${VERSION}.dmg"
APPCAST_FILENAME="horse-whisprer.xml"
RELEASE_METADATA_FILENAME="horse-whisprer-release.json"
UPDATE_ZIP_PATH="${DIST_DIR}/${ZIP_FILENAME}"
DMG_PATH="${DIST_DIR}/${DMG_FILENAME}"
APPCAST_PATH="${DIST_DIR}/${APPCAST_FILENAME}"
RELEASE_METADATA_PATH="${DIST_DIR}/${RELEASE_METADATA_FILENAME}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-${RELEASE_NOTES_BASE_URL}/${VERSION}}"
ZIP_URL="${DOWNLOAD_BASE_URL}/$(url_encode "${ZIP_FILENAME}")"
DMG_URL="${DOWNLOAD_BASE_URL}/$(url_encode "${DMG_FILENAME}")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

EXPORT_OPTIONS_PLIST="$(mktemp /tmp/horse-whisprer-export-options.XXXXXX.plist)"
sed "s/__TEAM_ID__/${TEAM_ID}/g" "${EXPORT_OPTIONS_PLIST_TEMPLATE}" > "${EXPORT_OPTIONS_PLIST}"

cleanup() {
  if [[ -n "${EXPORT_OPTIONS_PLIST}" && -f "${EXPORT_OPTIONS_PLIST}" ]]; then
    rm -f "${EXPORT_OPTIONS_PLIST}"
  fi
}

trap cleanup EXIT

if [[ -n "${CUSTOM_DIST_DIR}" ]]; then
  # A caller-selected directory must be new. Never recursively clear an
  # arbitrary path supplied through the environment.
  mkdir -p "$(dirname "${DIST_DIR}")"
  mkdir "${DIST_DIR}"
else
  rm -rf "${DIST_DIR}"
  mkdir -p "${DIST_DIR}"
fi

echo "Archiving ${PRODUCT_NAME} ${VERSION} (${BUILD_NUMBER})..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -archivePath "${ARCHIVE_PATH}" \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${IDENTITY}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  HORSEWHISPRER_DISTRIBUTION_FLAVOR="${HORSEWHISPRER_DISTRIBUTION_FLAVOR}" \
  SPARKLE_FEED_URL="${IN_APP_FEED_URL}" \
  SPARKLE_PUBLIC_ED_KEY="${PUBLIC_ED_KEY}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

echo "Exporting signed app..."
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Export did not produce ${APP_PATH}" >&2
  exit 1
fi

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "Creating app notarization zip..."
  rm -f "${APP_NOTARY_ZIP_PATH}"
  ditto -c -k --keepParent "${APP_PATH}" "${APP_NOTARY_ZIP_PATH}"

  echo "Submitting app for notarization with profile ${NOTARY_PROFILE}..."
  submit_for_notarization "${APP_NOTARY_ZIP_PATH}" "${NOTARY_PROFILE}"

  echo "Stapling app notarization ticket..."
  xcrun stapler staple "${APP_PATH}"
fi

echo "Creating Sparkle update ZIP..."
rm -f "${UPDATE_ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${UPDATE_ZIP_PATH}"

echo "Signing update ZIP with Sparkle..."
SPARKLE_SIGN_ARGS=()
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE}" && -f "${SPARKLE_PRIVATE_KEY_FILE}" ]]; then
  SPARKLE_SIGN_ARGS+=(--ed-key-file "${SPARKLE_PRIVATE_KEY_FILE}")
elif [[ -n "${SPARKLE_KEY_ACCOUNT}" ]]; then
  SPARKLE_SIGN_ARGS+=(--account "${SPARKLE_KEY_ACCOUNT}")
fi
SIGN_OUTPUT="$("${SPARKLE_SIGN_UPDATE_PATH}" "${SPARKLE_SIGN_ARGS[@]}" "${UPDATE_ZIP_PATH}")"
ED_SIGNATURE="$(printf '%s\n' "${SIGN_OUTPUT}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ZIP_SIZE="$(stat -f%z "${UPDATE_ZIP_PATH}")"

if [[ -z "${ED_SIGNATURE}" ]]; then
  echo "Failed to parse Sparkle signature from sign_update output:" >&2
  printf '%s\n' "${SIGN_OUTPUT}" >&2
  exit 1
fi

echo "Creating installer DMG..."
create_dmg "${APP_PATH}" "${DMG_PATH}" "${PRODUCT_NAME} ${VERSION}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "Signing DMG..."
  sign_dmg "${DMG_PATH}"

  echo "Submitting DMG for notarization with profile ${NOTARY_PROFILE}..."
  submit_for_notarization "${DMG_PATH}" "${NOTARY_PROFILE}"

  echo "Stapling DMG notarization ticket..."
  xcrun stapler staple "${DMG_PATH}"
fi

echo "Generating production appcast..."
generate_appcast \
  "${APPCAST_PATH}" \
  "${VERSION}" \
  "${BUILD_NUMBER}" \
  "${ZIP_URL}" \
  "${ZIP_SIZE}" \
  "${ED_SIGNATURE}" \
  "${RELEASE_NOTES_URL}" \
  "${PUB_DATE}"

echo "Writing release metadata..."
generate_release_metadata \
  "${RELEASE_METADATA_PATH}" \
  "${VERSION}" \
  "${BUILD_NUMBER}" \
  "${APP_PATH}" \
  "${DMG_PATH}" \
  "${UPDATE_ZIP_PATH}" \
  "${APPCAST_PATH}" \
  "${APPCAST_URL}" \
  "${ZIP_URL}" \
  "${DMG_URL}" \
  "${RELEASE_NOTES_URL}" \
  "${ED_SIGNATURE}" \
  "${ZIP_SIZE}"

echo "Verifying code signing..."
codesign -dv --verbose=4 "${APP_PATH}" >/dev/null

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "Verifying notarization..."
  spctl -a -vvv "${APP_PATH}"
fi

echo
echo "Done."
echo "App: ${APP_PATH}"
echo "DMG: ${DMG_PATH}"
echo "Update ZIP: ${UPDATE_ZIP_PATH}"
echo "Appcast: ${APPCAST_PATH}"
echo "Release metadata: ${RELEASE_METADATA_PATH}"
echo "Publish appcast to: ${APPCAST_URL}"
echo "Embedded Sparkle feed URL: ${IN_APP_FEED_URL}"
echo "Sparkle signature: ${ED_SIGNATURE}"
if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "Notarization: completed for app and DMG"
else
  echo "Notarization: skipped"
fi
