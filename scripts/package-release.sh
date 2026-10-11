#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 <Crux.app|Crux Beta.app> <version> <new-output-directory>"
}

if [[ $# -ne 3 ]]; then
    usage >&2
    exit 2
fi

readonly APP_PATH="$1"
readonly VERSION="$2"
readonly OUTPUT_DIRECTORY="$3"

if [[ ! -d "${APP_PATH}" || "${APP_PATH}" != *.app ]]; then
    echo "error: expected an existing .app bundle: ${APP_PATH}" >&2
    exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "error: version must contain only numeric dot-separated components" >&2
    exit 1
fi

identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
case "${identifier}" in
    com.zacharyhuo.Crux) APP_NAME='Crux'; FILE_PREFIX='Crux' ;;
    com.zacharyhuo.Crux.Beta) APP_NAME='Crux Beta'; FILE_PREFIX='Crux-Beta' ;;
    *) echo 'error: unknown application identity' >&2; exit 1 ;;
esac
if [[ "$(basename "${APP_PATH}")" != "${APP_NAME}.app" ]]; then
    echo 'error: bundle filename and identity disagree' >&2
    exit 1
fi
readonly ZIP_PATH="${OUTPUT_DIRECTORY}/${FILE_PREFIX}-${VERSION}-arm64.zip"
readonly DMG_PATH="${OUTPUT_DIRECTORY}/${FILE_PREFIX}-${VERSION}-arm64.dmg"
readonly EXECUTABLE="${APP_PATH}/Contents/MacOS/${APP_NAME}"
if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "error: application executable is missing" >&2
    exit 1
fi
if [[ "$(lipo -archs "${EXECUTABLE}")" != "arm64" ]]; then
    echo "error: release executable must contain exactly the arm64 slice" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
node "$(dirname "${BASH_SOURCE[0]}")/../tools/app-updates/runtime-signing.mjs" "${APP_PATH}"
mkdir -p "${OUTPUT_DIRECTORY}"
if [[ -e "${ZIP_PATH}" || -e "${DMG_PATH}" || -e "${OUTPUT_DIRECTORY}/SHA256SUMS.txt" ]]; then
    echo 'error: release output already exists; choose a fresh directory' >&2
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/crux-dmg.XXXXXX")"
cleanup() {
    rm -rf -- "${STAGING_DIRECTORY}"
}
trap cleanup EXIT

ditto "${APP_PATH}" "${STAGING_DIRECTORY}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIRECTORY}/Applications"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING_DIRECTORY}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

(cd "${OUTPUT_DIRECTORY}" && shasum -a 256 "$(basename "${ZIP_PATH}")" "$(basename "${DMG_PATH}")" > SHA256SUMS.txt)

echo "Created ${ZIP_PATH}"
echo "Created ${DMG_PATH}"
