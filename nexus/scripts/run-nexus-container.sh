#!/bin/bash
# Run Nexus with persistent data and optional systemd autostart (rootless-friendly)
set -euo pipefail
umask 027

IMAGE_NAME="${IMAGE_NAME:-localhost/nexus-ubi8:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-nexus}"

# Rootless-safe default (avoid writing to /)
HOST_DATA_DIR="${HOST_DATA_DIR:-${HOME}/tn_devops/nexus-data}"

# Default binding to localhost to avoid unintended exposure
HOST_BIND_ADDRESS="${HOST_BIND_ADDRESS:-127.0.0.1}"
HOST_PORT="${HOST_PORT:-18081}"
CONTAINER_PORT="${CONTAINER_PORT:-8081}"

# Defaults if UNSET; allow empty to disable
MEMORY_LIMIT="${MEMORY_LIMIT-2g}"
CPUS_LIMIT="${CPUS_LIMIT-2}"
PIDS_LIMIT="${PIDS_LIMIT-4096}"
NOFILES_LIMIT="${NOFILES_LIMIT-65536_65536}"

# Nexus runtime: use absolute work dir for persistent data (matches how launcher behaves in practice)
NEXUS_DATA_PATH="${NEXUS_DATA_PATH:-/opt/sonatype-work}"
JAVA_PREFS_ROOT="${JAVA_PREFS_ROOT:-/opt/sonatype-work/javaprefs}"

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
logInfo()    { printf "${YELLOW}>> %s\n" "$1"; }
logSuccess() { printf "${GREEN}>> %s OK!\n" "$1"; }
logWarn()    { printf "${YELLOW}>> WARNING: %s\n" "$1"; }
logError()   { printf "${RED}>> ERROR: %s\n" "$1"; }

checkCommand() { command -v "$1" >/dev/null 2>&1 || { logError "Missing required command: $1"; exit 1; }; }

validateInput() {
  [[ "${HOST_BIND_ADDRESS}" =~ ^[0-9.]+$ ]] || { logError "HOST_BIND_ADDRESS invalid: ${HOST_BIND_ADDRESS}"; exit 1; }
  [[ "${HOST_PORT}" =~ ^[0-9]+$ ]] && [ "${HOST_PORT}" -ge 1 ] && [ "${HOST_PORT}" -le 65535 ] || { logError "HOST_PORT invalid"; exit 1; }
  [[ "${CONTAINER_PORT}" =~ ^[0-9]+$ ]] && [ "${CONTAINER_PORT}" -ge 1 ] && [ "${CONTAINER_PORT}" -le 65535 ] || { logError "CONTAINER_PORT invalid"; exit 1; }

  if [ -n "${MEMORY_LIMIT}" ] && ! [[ "${MEMORY_LIMIT}" =~ ^[0-9]+[gGmM]$ ]]; then
    logError "MEMORY_LIMIT must be like 2g or 512m"
    exit 1
  fi
  if [ -n "${CPUS_LIMIT}" ] && ( ! [[ "${CPUS_LIMIT}" =~ ^[0-9]+$ ]] || [ "${CPUS_LIMIT}" -le 0 ] ); then
    logError "CPUS_LIMIT must be a positive integer"
    exit 1
  fi
  if [ -n "${PIDS_LIMIT}" ] && ( ! [[ "${PIDS_LIMIT}" =~ ^[0-9]+$ ]] || [ "${PIDS_LIMIT}" -le 0 ] ); then
    logError "PIDS_LIMIT must be a positive integer"
    exit 1
  fi
  if [ -n "${NOFILES_LIMIT}" ] && ! [[ "${NOFILES_LIMIT}" =~ ^[0-9]+_[0-9]+$ ]]; then
    logError "NOFILES_LIMIT must be soft_hard (e.g. 65536_65536)"
    exit 1
  fi
}

container_exists() { podman ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; }
container_running() { podman ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; }

install_systemd_service() {
  local service_file="container-${CONTAINER_NAME}.service"
  local temp_dir
  temp_dir="$(mktemp -d)"
  local source_path="${temp_dir}/${service_file}"

  if ! (cd "${temp_dir}" && podman generate systemd --new --name "${CONTAINER_NAME}" --files --restart-policy=always >/dev/null 2>&1); then
    logWarn "Cannot generate systemd unit; leaving --restart=always as fallback"
    rm -rf "${temp_dir}"
    return
  fi

  if [ ! -f "${source_path}" ]; then
    logWarn "Generated systemd unit not found; leaving --restart=always as fallback"
    rm -rf "${temp_dir}"
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/systemd/user"
    if install -m 0644 "${source_path}" "${HOME}/.config/systemd/user/${service_file}" \
      && systemctl --user daemon-reload \
      && systemctl --user enable --now "${service_file}"; then
      logSuccess "Enabled user systemd service ${service_file}"
      if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || logWarn "Could not enable linger; user service may require active session"
      fi
    else
      logWarn "User systemd setup failed; leaving --restart=always as fallback"
    fi
  else
    logWarn "systemctl not found; leaving --restart=always as fallback"
  fi

  rm -rf "${temp_dir}"
}

main() {
  checkCommand podman
  checkCommand mktemp
  checkCommand mkdir
  validateInput

  if ! podman image exists "${IMAGE_NAME}"; then
    logError "Image not found: ${IMAGE_NAME}. Build it with ./scripts/build-nexus-image.sh"
    exit 1
  fi

  logInfo "Preparing host volume ${HOST_DATA_DIR}"
  mkdir -p "${HOST_DATA_DIR}"
  chmod 750 "${HOST_DATA_DIR}" 2>/dev/null || logWarn "chmod not permitted on ${HOST_DATA_DIR}, continuing"

  if c
