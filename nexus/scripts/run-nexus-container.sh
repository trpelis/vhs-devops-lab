#!/bin/bash

# Run Nexus with persistent data and optional systemd autostart
set -euo pipefail
umask 027

IMAGE_NAME="${IMAGE_NAME:-localhost/nexus-ubi8}"
CONTAINER_NAME="${CONTAINER_NAME:-nexus}"
HOST_DATA_DIR="${HOST_DATA_DIR:-/tn_devops/nexus-data}"

# Default binding to localhost to avoid unintended exposure
HOST_BIND_ADDRESS="${HOST_BIND_ADDRESS:-127.0.0.1}"
HOST_PORT="${HOST_PORT:-18081}"
CONTAINER_PORT="${CONTAINER_PORT:-8081}"
MEMORY_LIMIT="${MEMORY_LIMIT:-2g}"
CPUS_LIMIT="${CPUS_LIMIT:-2}"
PIDS_LIMIT="${PIDS_LIMIT:-4096}"
NOFILES_LIMIT="${NOFILES_LIMIT:-65536_65536}"

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'

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
    if [[ ! "${HOST_BIND_ADDRESS}" =~ ^[0-9.]+$ ]]; then
        logError "HOST_BIND_ADDRESS has invalid char(s): ${HOST_BIND_ADDRESS}"
        exit 1
    fi

    if ! [[ "${HOST_PORT}" =~ ^[0-9]+$ ]] || [ "${HOST_PORT}" -le 0 ] || [ "${HOST_PORT}" -gt 65535 ]; then
        logError "HOST_PORT must be a valid port number (1-65535)"
        exit 1
    fi

    if ! [[ "${CONTAINER_PORT}" =~ ^[0-9]+$ ]] || [ "${CONTAINER_PORT}" -le 0 ] || [ "${CONTAINER_PORT}" -gt 65535 ]; then
        logError "CONTAINER_PORT must be a valid port number (1-65535)"
        exit 1
    fi

    if ! [[ "${MEMORY_LIMIT}" =~ ^[0-9]+[gGmM]$ ]]; then
        logError "MEMORY_LIMIT must be a number followed by 'g' or 'm' (e.g. 2g, 512m)"
        exit 1
    fi

    if ! [[ "${CPUS_LIMIT}" =~ ^[0-9]+$ ]] || [ "${CPUS_LIMIT}" -le 0 ]; then
        logError "CPUS_LIMIT must be a positive integer"
        exit 1
    fi

    if ! [[ "${PIDS_LIMIT}" =~ ^[0-9]+$ ]] || [ "${PIDS_LIMIT}" -le 0 ]; then
        logError "PIDS_LIMIT must be a positive integer"
        exit 1
    fi

    if ! [[ "${NOFILES_LIMIT}" =~ ^[0-9]+_[0-9]+$ ]]; then
        logError "NOFILES_LIMIT must be in the format 'soft_hard' (e.g. 65536_65536)"
        exit 1
    fi

    if [ ! -d "${HOST_DATA_DIR}" ]; then
        logWarn "Host data directory does not exist, creating: ${HOST_DATA_DIR}"
        mkdir -p "${HOST_DATA_DIR}"
    fi
}

container_exists() {
    podman ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"
}

install_systemd_service() {
    local service_file="container-${CONTAINER_NAME}.service"
    local temp_dir="$(mktemp -d)"
    local source_path="${temp_dir}/${service_file}"

    if ! (cd "${temp_dir}" && podman generate systemd --new --name "${CONTAINER_NAME}" --files --restart-policy=always > /dev/null 2>&1); then
        logWarn "Cannot generate systemd service, container restart policy is active"
        rm -rf "${temp_dir}"
        return
    fi

    if [ ! -f "${source_path}" ]; then
        logWarn "Generated systemd file not found, container restart policy still active"
        rm -rf "${temp_dir}"
        return
    fi

    if [ "$(id -u)" -eq 0 ]; then
        if install -m 0644 "${source_path}" "/etc/systemd/system/${service_file}" && systemctl daemon-reload && systemctl enable --now "${service_file}"; then
            logSuccess "Enabled system startup with ${service_file}"
        else
            logWarn "Root systemd setup failed, container restart policy active"
        fi
        rm -rf "${temp_dir}"
        return 
    fi

    if command -v systemctl > /dev/null 2>&1; then
        mkdir -p "${HOME}/.config/systemd/user"
        if install -m 0644 "${source_path}" "${HOME}/.config/systemd/user/${service_file}" && systemctl --user daemon-reload && \
            systemctl --user enable --now "${service_file}"; then
                logSuccess "Enabled user systemd service ${service_file}"
                if command -v loginctl > /dev/null 2>&1; then
                    loginctl enable-linger "$(id -un)" > /dev/null 2>&1 || logWarn "Cannot enable linger, user service may need active session."
                fi
        else
            logWarn "User systemd setup failed, container restart policy active"
        fi
        rm -rf "${temp_dir}"
        return
    fi

    rm -rf "${temp_dir}"
    logWarn "systemctl not found, autostart with OS wasnt configured"
    return

}

 main () {
    checkCommand podman
    checkCommand mkdir
    checkCommand mktemp
    checkCommand chmod
    validateInput

    if ! podman image exists "${IMAGE_NAME}"; then
        logError "Image not found ${IMAGE_NAME}, build it with ./scripts/build-nexus-image.sh"
        exit 1
    fi

    logInfo "Preparing host volume ${HOST_DATA_DIR}"
    mkdir -p "${HOST_DATA_DIR}"
    chmod 750 "${HOST_DATA_DIR}"

    if container_exists; then
        logInfo "Removing existing container ${CONTAINER_NAME}"
        podman rm -f "${CONTAINER_NAME}" > /dev/null
    fi

    logInfo "Starting Nexus container in bg"
    # Runtime privileges minimal
    local nofiles_ulimit
    nofiles_ulimit="${NOFILES_LIMIT/_/:}"

    podman run -d \
        --name "${CONTAINER_NAME}" \
        --restart=always \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --pids-limit="${PIDS_LIMIT}" \
        --memory="${MEMORY_LIMIT}" \
        --cpus="${CPUS_LIMIT}" \
        --ulimit "nofile=${nofiles_ulimit}" \
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=512m \
        -p "${HOST_BIND_ADDRESS}:${HOST_PORT}:${CONTAINER_PORT}" \
        -v "${HOST_DATA_DIR}:/opt/nexus/sonatype-work:Z,U" \
        "${IMAGE_NAME}" >/dev/null

    install_systemd_service

    logSuccess "Container ${CONTAINER_NAME} is up and running!"
    logInfo "Open Nexus@http://localhost:${HOST_PORT}"
    
 }

 main "$@"
