#!/bin/bash
# Build Nexus image from local Containerfile with verified checksum of downloaded archive
set -euo pipefail
umask 027

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXUS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NEXUS_VERSION="${NEXUS_VERSION:-3.30.1-01}"
NEXUS_ARCHIVE="${NEXUS_ARCHIVE:-nexus-${NEXUS_VERSION}-unix.tar.gz}"
NEXUS_DOWNLOAD_URL="${NEXUS_DOWNLOAD_URL:-https://download.sonatype.com/nexus/3/${NEXUS_ARCHIVE}}"
NEXUS_SHA256="${NEXUS_SHA256:-}"
ALLOW_MISSING_CHECKSUM="${ALLOW_MISSING_CHECKSUM:-false}"

IMAGE_NAME="${IMAGE_NAME:-localhost/nexus-ubi8}"
IMAGE_TAG="${IMAGE_TAG:-${NEXUS_VERSION}}"
IMAGE_FORMAT="${IMAGE_FORMAT:-docker}"
CONTAINERFILE="${CONTAINERFILE:-${NEXUS_DIR}/Containerfile}"

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'

logInfo()    { printf "${YELLOW}>> %s\n" "$1"; }
logSuccess() { printf "${GREEN}>> %s OK!\n" "$1"; }
logWarn()    { printf "${YELLOW}>> WARNING: %s\n" "$1"; }
logError()   { printf "${RED}>> ERROR: %s\n" "$1"; }

checkCommand() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { logError "Missing required command: ${cmd}"; exit 1; }
}

validateInput() {
  [[ "${NEXUS_ARCHIVE}" =~ ^[A-Za-z0-9._-]+$ ]] || { logError "NEXUS_ARCHIVE has invalid chars: ${NEXUS_ARCHIVE}"; exit 1; }
  [ -f "${CONTAINERFILE}" ] || { logError "Containerfile not found: ${CONTAINERFILE}"; exit 1; }
  [[ "${ALLOW_MISSING_CHECKSUM}" == "true" || "${ALLOW_MISSING_CHECKSUM}" == "false" ]] || { logError "ALLOW_MISSING_CHECKSUM must be true|false"; exit 1; }
  [[ "${IMAGE_FORMAT}" == "docker" || "${IMAGE_FORMAT}" == "oci" ]] || { logError "IMAGE_FORMAT must be docker|oci"; exit 1; }
}

downloadNexus() {
  local expected_sha="$1"
  local archive_path="${NEXUS_DIR}/${NEXUS_ARCHIVE}"
  local tmp_path="${archive_path}.tmp"

  if [ -f "${archive_path}" ]; then
    if [ -n "${expected_sha}" ] && echo "${expected_sha}  ${archive_path}" | sha256sum -c - >/dev/null 2>&1; then
      logInfo "Nexus archive exists and checksum is valid: ${archive_path}"
      return
    fi
    [ -n "${expected_sha}" ] && logWarn "Existing archive checksum mismatch. Re-downloading."
    rm -f "${archive_path}"
  fi

  logInfo "Downloading Nexus bundle from Sonatype: ${NEXUS_DOWNLOAD_URL}"
  curl -fL --retry 3 --retry-delay 2 --retry-connrefused --proto '=https' --tlsv1.2 "${NEXUS_DOWNLOAD_URL}" -o "${tmp_path}"
  mv -f "${tmp_path}" "${archive_path}"
}

fetchChecksum() {
  local checksum_url="${NEXUS_DOWNLOAD_URL}.sha256"
  if [ -n "${NEXUS_SHA256}" ]; then
    printf "%s\n" "${NEXUS_SHA256}"
    return
  fi
  curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused --proto '=https' --tlsv1.2 "${checksum_url}" \
    | awk '{print $1}' | head -n 1 || true
}

verifyChecksum() {
  local expected_sha="$1"
  local archive_path="${NEXUS_DIR}/${NEXUS_ARCHIVE}"

  if [ -z "${expected_sha}" ]; then
    if [ "${ALLOW_MISSING_CHECKSUM}" = "true" ]; then
      logWarn "Could not fetch checksum; continuing because ALLOW_MISSING_CHECKSUM=true"
      return
    fi
    logError "Could not fetch checksum. Set ALLOW_MISSING_CHECKSUM=true to bypass."
    exit 1
  fi

  logInfo "Validating SHA256 checksum"
  echo "${expected_sha}  ${archive_path}" | sha256sum -c -
}

buildImage() {
  local expected_sha="$1"

  logInfo "Building image ${IMAGE_NAME}:${IMAGE_TAG} (format: ${IMAGE_FORMAT})"
  podman build \
    --pull=always \
    --format "${IMAGE_FORMAT}" \
    --build-arg "NEXUS_ARCHIVE=${NEXUS_ARCHIVE}" \
    --build-arg "NEXUS_SHA256=${expected_sha}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -t "${IMAGE_NAME}:latest" \
    -f "${CONTAINERFILE}" \
    "${NEXUS_DIR}"
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
