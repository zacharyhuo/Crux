#!/bin/bash

set -euo pipefail

# Crux builds libarchive itself instead of depending on a small Swift wrapper
# or a Homebrew installation. The source identity below is part of our supply-
# chain boundary: changing any value requires a reviewed planning update.
readonly LIBARCHIVE_VERSION="3.8.9"
readonly LIBARCHIVE_TAG="v3.8.9"
readonly LIBARCHIVE_COMMIT="27cbc7827172698143e440801fc0ba39ccb4f1f5"
readonly LIBARCHIVE_SOURCE_SHA256="888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde"
readonly LIBARCHIVE_SOURCE_URL="https://github.com/libarchive/libarchive/releases/download/${LIBARCHIVE_TAG}/libarchive-${LIBARCHIVE_VERSION}.tar.xz"
readonly MACOS_DEPLOYMENT_TARGET="26.0"

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly ARTIFACTS_DIRECTORY="${REPOSITORY_ROOT}/Artifacts"
readonly XCFRAMEWORK_PATH="${ARTIFACTS_DIRECTORY}/CLibArchive.xcframework"
readonly ARCHIVE_PATH="${ARTIFACTS_DIRECTORY}/CLibArchive.xcframework.zip"
readonly MANIFEST_PATH="${ARTIFACTS_DIRECTORY}/libarchive-build.json"

WORK_DIRECTORY=""

cleanup() {
    if [[ -n "${WORK_DIRECTORY}" && -d "${WORK_DIRECTORY}" ]]; then
        rm -rf -- "${WORK_DIRECTORY}"
    fi
}

usage() {
    echo "Usage: $0 [--verify-source | --build]"
    echo "  --verify-source  Download and verify the pinned upstream archive only."
    echo "  --build          Build an arm64 static XCFramework (default)."
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command '$1' was not found" >&2
        exit 1
    fi
}

verify_sha256() {
    local file_path="$1"
    local actual_sha256
    actual_sha256="$(shasum -a 256 "${file_path}" | awk '{print $1}')"

    if [[ "${actual_sha256}" != "${LIBARCHIVE_SOURCE_SHA256}" ]]; then
        echo "error: libarchive source checksum mismatch" >&2
        echo "expected: ${LIBARCHIVE_SOURCE_SHA256}" >&2
        echo "actual:   ${actual_sha256}" >&2
        exit 1
    fi
}

download_source() {
    local destination="$1"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "${destination}" \
        "${LIBARCHIVE_SOURCE_URL}"
    verify_sha256 "${destination}"
}

build_architecture() {
    local architecture="$1"
    local host_triple="$2"
    local source_directory="$3"
    local build_root="$4"
    local build_directory="${build_root}/build-${architecture}"
    local install_directory="${build_root}/install-${architecture}"
    local clang_path
    local sdk_path
    local minimum_version_flag="-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"

    clang_path="$(xcrun --sdk macosx --find clang)"
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    mkdir -p "${build_directory}" "${install_directory}"

    (
        cd "${build_directory}"
        env \
            CC="${clang_path}" \
            SDKROOT="${sdk_path}" \
            CFLAGS="-arch ${architecture} -isysroot ${sdk_path} ${minimum_version_flag} -O2" \
            CPPFLAGS="-arch ${architecture} -isysroot ${sdk_path} ${minimum_version_flag}" \
            LDFLAGS="-arch ${architecture} -isysroot ${sdk_path} ${minimum_version_flag}" \
            "${source_directory}/configure" \
                --host="${host_triple}" \
                --prefix="${install_directory}" \
                --disable-shared \
                --enable-static \
                --disable-bsdtar \
                --disable-bsdcat \
                --disable-bsdcpio \
                --disable-bsdunzip \
                --disable-xattr \
                --without-bz2lib \
                --without-lz4 \
                --without-lzma \
                --without-lzo2 \
                --without-nettle \
                --without-openssl \
                --without-xml2 \
                --without-expat \
                --without-zstd
        make -j"$(sysctl -n hw.logicalcpu)"
        make install
    )
}

main() {
    local mode="${1:---build}"
    local source_archive
    local source_directory

    if [[ "${mode}" == "--help" || "${mode}" == "-h" ]]; then
        usage
        exit 0
    fi
    if [[ "${mode}" != "--build" && "${mode}" != "--verify-source" ]]; then
        usage >&2
        exit 2
    fi

    require_command curl
    require_command shasum
    WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/crux-libarchive.XXXXXX")"
    trap cleanup EXIT
    source_archive="${WORK_DIRECTORY}/libarchive-${LIBARCHIVE_VERSION}.tar.xz"

    download_source "${source_archive}"
    echo "Verified libarchive ${LIBARCHIVE_VERSION} source (${LIBARCHIVE_SOURCE_SHA256})."

    if [[ "${mode}" == "--verify-source" ]]; then
        exit 0
    fi

    require_command make
    require_command tar
    require_command xcodebuild
    require_command xcrun
    require_command ditto
    require_command swift

    tar -xJf "${source_archive}" -C "${WORK_DIRECTORY}"
    source_directory="${WORK_DIRECTORY}/libarchive-${LIBARCHIVE_VERSION}"

    build_architecture arm64 aarch64-apple-darwin "${source_directory}" "${WORK_DIRECTORY}"

    mkdir -p "${WORK_DIRECTORY}/arm64/include" "${WORK_DIRECTORY}/arm64/lib" "${ARTIFACTS_DIRECTORY}"
    cp "${WORK_DIRECTORY}/install-arm64/include/archive.h" "${WORK_DIRECTORY}/arm64/include/"
    cp "${WORK_DIRECTORY}/install-arm64/include/archive_entry.h" "${WORK_DIRECTORY}/arm64/include/"
    cp "${SCRIPT_DIRECTORY}/libarchive/module.modulemap" "${WORK_DIRECTORY}/arm64/include/"
    cp "${WORK_DIRECTORY}/install-arm64/lib/libarchive.a" "${WORK_DIRECTORY}/arm64/lib/libCLibArchive.a"

    if [[ -e "${XCFRAMEWORK_PATH}" || -L "${XCFRAMEWORK_PATH}" ]]; then
        rm -rf "${XCFRAMEWORK_PATH}"
    fi
    if [[ -e "${ARCHIVE_PATH}" || -L "${ARCHIVE_PATH}" ]]; then
        rm -f "${ARCHIVE_PATH}"
    fi

    xcodebuild -create-xcframework \
        -library "${WORK_DIRECTORY}/arm64/lib/libCLibArchive.a" \
        -headers "${WORK_DIRECTORY}/arm64/include" \
        -output "${XCFRAMEWORK_PATH}"
    ditto -c -k --sequesterRsrc --keepParent "${XCFRAMEWORK_PATH}" "${ARCHIVE_PATH}"

    local artifact_sha256
    local swiftpm_checksum
    artifact_sha256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
    swiftpm_checksum="$(swift package compute-checksum "${ARCHIVE_PATH}")"

    printf '{\n  "version": "%s",\n  "tag": "%s",\n  "commit": "%s",\n  "sourceURL": "%s",\n  "sourceSHA256": "%s",\n  "macOSDeploymentTarget": "%s",\n  "architectures": ["arm64"],\n  "artifactSHA256": "%s",\n  "swiftPMChecksum": "%s"\n}\n' \
        "${LIBARCHIVE_VERSION}" \
        "${LIBARCHIVE_TAG}" \
        "${LIBARCHIVE_COMMIT}" \
        "${LIBARCHIVE_SOURCE_URL}" \
        "${LIBARCHIVE_SOURCE_SHA256}" \
        "${MACOS_DEPLOYMENT_TARGET}" \
        "${artifact_sha256}" \
        "${swiftpm_checksum}" > "${MANIFEST_PATH}"

    echo "Created ${XCFRAMEWORK_PATH}"
    echo "Recorded checksums in ${MANIFEST_PATH}"
}

main "$@"
