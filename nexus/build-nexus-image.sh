#!/bin/bash

# Building Nexus image from local Containerfile with verified checksum of downloaded archive
set -euo pipefail
umask 027

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NEXUS_VERSION="${NEXUS_VERSION:-3.30.1-01}"
NEXUS_ARCHIVE="${NEXUS_ARCHIVE:-nexus-${NEXUS_VERSION}-unix.tar.gz}"
NEXUS_DOWNLOAD_URL="${NEXUS_DOWNLOAD_URL:-https://download.sonatype.com/nexus/3/${NEXUS_ARCHIVE}}"
NEXUS_SHA256="${NEXUS_SHA256:-}"
ALLOW_MISSING_CHECKSUM="${ALLOW_MISSING_CHECKSUM:-false}"
IMAGE_NAME="${IMAGE_NAME:-localhost/nexus-ubi8}"
IMAGE_TAG="${IMAGE_TAG:-${NEXUS_VERSION}}"
CONTAINERFILE="${CONTAINERFILE:-${SCRIPT_DIR}/Containerfile}"

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1:31m'

logInfo() {
    printf "${YELLOW}>> %s\n" "$1"
}

logSuccess() {
    printf "${GREEN}>> %s OK! \n" "$1"
}

logWarn() {
    printf "${YELLOW}>> WARNING: %s\n" "$1"
}

logError() {
    printf "${RED}>> ERROR: %s \n" "$1"
}

checkCommand() {
    local cmd="$1"
    if ! command -v "$cmd" > /dev/null 2>&1; then
        logError "Missing req. command: ${cmd}"
        exit 1
    fi
}

validateInput() {
    if [[ ! "${NEXUS_ARCHIVE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        logError "NEXUS_ARCHIVE has invalid char(s): ${NEXUS_ARCHIVE}"
        exit 1
    fi

    if [ ! -f "${CONTAINERFILE}" ]; then
        logError "Containerfile not found: ${CONTAINERFILE}"
        exit 1
    fi

    if [[ "${ALLOW_MISSING_CHECKSUM}" != "true" && "${ALLOW_MISSING_CHECKSUM}" != "false" ]]; then
        logError "ALLOW_MISSING_CHECKSUM must be either true or false"
        exit 1
    fi

} 

downloadNexus() {
    local expected_sha="$1"
    local archive_path="${SCRIPT_DIR}/${NEXUS_ARCHIVE}"
    local tmp_path="${archive_path}.tmp"

    if [ -f "${archive_path}" ]; then
        if [ -n "${expected_sha}" ]; then
            if echo "${expected_sha}  ${archive_path}" | sha256sum -c - >/dev/null 2>&1; then
                logInfo "Nexus archive already exists and checksum is valid: ${archive_path}"
                return
            fi
            logWarn "Existing Nexus archive checksum mismatch. Re-downloading."
            rm -f "${archive_path}"
        else
            logInfo "Nexus archive already exists: ${archive_path}"
            return
        fi
    fi

    logInfo "Downloading Nexus bundle from Sonatype"
    curl -fL --retry 3 --retry-delay 2 --retry-connrefused --proto '=https' --tlsv1.2 "${NEXUS_DOWNLOAD_URL}" -o "${tmp_path}"
    mv -f "${tmp_path}" "${archive_path}"
}


fetchChecksum() {
    local checksum_url="${NEXUS_DOWNLOAD_URL}.sha256"

    if [ -n "${NEXUS_SHA256}" ]; then
        printf "%s\n" "${NEXUS_SHA256}"
        return 
    fi

    curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused --proto '=https' --tlsv1.2 "${checksum_url}" | awk ' {print $1}' | head -n 1 || true
}

verifyChecksum() {
    local expected_sha="$1"
    local archive_path="${SCRIPT_DIR}/${NEXUS_ARCHIVE}"

    if [ -z "${expected_sha}" ]; then
        if [ "${ALLOW_MISSING_CHECKSUM}" = "true" ]; then
            logWarn "Cant get Nexus checksum, continuing because of ALLOW_MISSING_CHEKSUM=true"
            return
        fi
        logError "Cant get Nexus checksu, set ALLOW_MISSING_CHECKSUM=true to bypass this"
        exit 1
    fi

    logInfo "Validating SHA256 checksum"
    echo "${expected_sha} ${archive_path}" | sha256sum -c -
}

buildImage() {
    local expected_sha="$1"

    logInfo "Building image ${IMAGE_NAME}:${IMAGE_TAG}"
    podman build \
        --pull=always \
        --build-arg "NEXUS_ARCHIVE=${NEXUS_ARCHIVE}" \
        --build-arg "NEXUS_SHA256=${expected_sha}" \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        -t "${IMAGE_NAME}:latest" \
        -f "${CONTAINERFILE}" \
        "${SCRIPT_DIR}"
}

main() {
    checkCommand podman
    checkCommand curl
    checkCommand sha256sum
    validateInput

    local expected_sha
    expected_sha="$(fetchChecksum)"
    downloadNexus "${expected_sha}"
    verifyChecksum "${expected_sha}"
    buildImage "${expected_sha}"

    logSuccess "Image build finished: ${IMAGE_NAME}:${IMAGE_TAG}"
}

main "$@"