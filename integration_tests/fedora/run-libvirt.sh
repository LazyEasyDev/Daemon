#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
integration_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)

export DISTRO_ID=${DISTRO_ID:-fedora}
export DISTRO_NAME=${DISTRO_NAME:-Fedora}
export DISTRO_VERSION_MAJOR=${DISTRO_VERSION_MAJOR:-44}
export DISTRO_ARTIFACT_PREFIX=${DISTRO_ARTIFACT_PREFIX:-fedora}
export DISTRO_DOMAIN_PREFIX=${DISTRO_DOMAIN_PREFIX:-daemon-fedora-itest}
export DISTRO_SERVICE_PREFIX=${DISTRO_SERVICE_PREFIX:-fedora}
export DISTRO_IMAGE_FILENAME=${DISTRO_IMAGE_FILENAME:-Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2}
export DISTRO_IMAGE_URL=${DISTRO_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/$DISTRO_IMAGE_FILENAME}
export DISTRO_IMAGE_SHA256=${DISTRO_IMAGE_SHA256:-55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b}
export VM_ARCH=${VM_ARCH:-arm64}
export VM_OS_VARIANT=${VM_OS_VARIANT:-generic}
# Keep device discovery within Fedora's boot deadlines under software emulation.
export VM_MEMORY_MIB=${VM_MEMORY_MIB:-3072}
export VM_VCPUS=${VM_VCPUS:-4}
export VM_BOOT_TIMEOUT=${VM_BOOT_TIMEOUT:-1200}

exec "$integration_dir/rocky/run-libvirt.sh" "$@"
