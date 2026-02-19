# Nexus on Podman (Rocky Linux)

This folder contains solution for running Sonatype Nexus with Podman.

## Included files

- `nexus/Containerfile` (base image `ubi8/ubi:8.7`)
- `nexus/scripts/build-nexus-image.sh`
- `nexus/scripts/run-nexus-container.sh`

## Requirements

- Rocky Linux 9
- Podman (rootless)
- `curl`
- `sha256sum`

Recommended:

```bash
sudo dnf install -y podman curl coreutils
```

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

Optional image format (default is `docker`, so `HEALTHCHECK` is kept):

```bash
IMAGE_FORMAT=docker ./scripts/build-nexus-image.sh
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
- mount `${HOME}/tn_devops/nexus-data:/opt/sonatype-work`
- port binding `127.0.0.1:18081 -> 8081`
- restart policy `always`
- tries to generate and enable systemd user service
- hardening flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--tmpfs /tmp`)
- runtime limits (`--memory`, `--pids-limit`, `--ulimit nofile`)
- optional cpu limit (see note below)

Nexus may take 30-90 seconds to start (JVM warmup).

## Rootless CPU cgroup note

On some virtualized environments CPU controller is not delegated to rootless containers.
If container fails with:

```text
crun: controller `cpu` is not available
```

Run without CPU limit:

```bash
CPUS_LIMIT="" ./scripts/run-nexus-container.sh
```

## Shared folder / chmod note

If your home directory is a VM shared mount you may see:

```text
chmod not permitted
```

This is harmless.
You can alternatively use:

```bash
HOST_DATA_DIR=/var/lib/nexus-data ./scripts/run-nexus-container.sh
```

## Optional runtime tuning

```bash
HOST_BIND_ADDRESS=127.0.0.1 MEMORY_LIMIT=2g CPUS_LIMIT=2 ./scripts/run-nexus-container.sh
```

Expose Nexus externally:

```bash
HOST_BIND_ADDRESS=0.0.0.0 ./scripts/run-nexus-container.sh
```

## Login

Check logs:

```bash
podman logs -f nexus
```

Open:

`http://localhost:18081`

Read initial password:

```bash
cat ~/tn_devops/nexus-data/nexus3/admin.password
```

Login with:

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
- minimal capabilities (`--cap-drop=ALL`)
- no privilege escalation
- checksum-verified software supply chain

## How it was tested

Environment:

- Host: macOS
- VM: Rocky Linux 9
- Runtime: rootless Podman
- SELinux: enforcing

Build:

```bash
./scripts/build-nexus-image.sh
```

Verified image exists:

```bash
podman image inspect localhost/nexus-ubi8:latest
```

Container startup:

```bash
CPUS_LIMIT="" ./scripts/run-nexus-container.sh
```

Confirmed:

- container starts
- persistent storage created
- no privileged mode required

Runtime verification:

```bash
podman ps
curl -I http://localhost:18081
```

Expected result:

```text
HTTP/1.1 200 OK
Server: Nexus/3.30.1-01 (OSS)
```

Persistence test:

```bash
podman restart nexus
```

Verified:

- configuration preserved
- admin password unchanged
- data persisted

Security validation:

```bash
podman inspect nexus | grep -i privileged
```

Result:

- not privileged
- non-root user
- restricted capabilities

## Result

Nexus runs successfully in a hardened, rootless container with persistent storage and SELinux enabled.
<img width="2008" height="1206" alt="image" src="https://github.com/user-attachments/assets/9482c314-7b66-428b-9602-b44b168d339b" />

