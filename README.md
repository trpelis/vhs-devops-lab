# Nexus on Podman (Rocky Linux)

This folder contains solution for running Sonatype Nexus with Podman.

Included files:

- `nexus/Containerfile` (base image `ubi8/ubi:8.7`)
- `nexus/scripts/build-nexus-image.sh`
- `nexus/scripts/run-nexus-container.sh`


## Requirements

- Rocky Linux
- Podman
- curl
- sha256sum

## Build

```bash
cd /path/to/repo/nexus
chmod +x scripts/*.sh
./scripts/build-nexus-image.sh
```

Optional:

```bash
IMAGE_NAME=localhost/nexus-ubi8 IMAGE_TAG=3.30.1-01 ./scripts/build-nexus-image.sh
```

Optional manual checksum pinning:

```bash
NEXUS_SHA256=<sha256_value> ./scripts/build-nexus-image.sh
```

Security options in build:

- downloads Nexus only via HTTPS/TLS
- verifies SHA256 checksum (fails if checksum is missing)
- passes checksum into image build for in-build verification

If needed, checksum requirement can be bypassed:

```bash
ALLOW_MISSING_CHECKSUM=true ./scripts/build-nexus-image.sh
```

## Run

```bash
./scripts/run-nexus-container.sh
```

Script starts container with:

- name `nexus`
- background mode
- mount `/tn_devops/nexus-data:/opt/nexus/sonatype-work`
- port binding `18081:8081`
- restart policy `always`
- tries to generate and enable systemd service for OS startup
- hardening flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--tmpfs /tmp`)
- runtime limits (`--memory`, `--cpus`, `--pids-limit`, `--ulimit nofile`)

Optional runtime tuning:

```bash
HOST_BIND_ADDRESS=127.0.0.1 MEMORY_LIMIT=2g CPUS_LIMIT=2 ./scripts/run-nexus-container.sh
```

To use a different host data path:

```bash
HOST_DATA_DIR=/srv/nexus-data ./scripts/run-nexus-container.sh
```

To expose Nexus outside localhost:

```bash
HOST_BIND_ADDRESS=0.0.0.0 ./scripts/run-nexus-container.sh
```

## Login

1. Check logs:
   ```bash
   podman logs -f nexus
   ```
2. Open [http://localhost:18081](http://localhost:18081)
3. Read initial password:
   ```bash
   cat /tn_devops/nexus-data/nexus3/admin.password
   ```
4. Login with:
   - user: `admin`
   - password: from `admin.password`


## Useful commands

```bash
podman ps
podman stop nexus
podman start nexus
podman rm -f nexus
podman logs -f nexus
```

## Security notes

- Container runs as non-root user `nexus`
- `run_as_user` is set in Nexus runtime config
- Healthcheck is configured in image
- `sonatype-work` is externalized in host-mounted volume
- Host data directory is created with restricted permissions (`750`)
