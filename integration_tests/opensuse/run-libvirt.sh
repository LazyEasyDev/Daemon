#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
integration_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)

snapshot=${OPENSUSE_SNAPSHOT:-20260830}
image_name=${OPENSUSE_IMAGE_NAME:-openSUSE-Tumbleweed-Minimal-VM.aarch64-1.0.0-Cloud-Snapshot${snapshot}.qcow2}
image_url=${OPENSUSE_IMAGE_URL:-https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/$image_name}

export DISTRO_ID=${DISTRO_ID:-opensuse-tumbleweed}
export DISTRO_NAME=${DISTRO_NAME:-openSUSE Tumbleweed}
export DISTRO_VERSION_MAJOR=${DISTRO_VERSION_MAJOR:-2026}
export DISTRO_VERSION_PREFIX=${DISTRO_VERSION_PREFIX:-2026}
export DISTRO_ARTIFACT_PREFIX=${DISTRO_ARTIFACT_PREFIX:-opensuse}
export DISTRO_DOMAIN_PREFIX=${DISTRO_DOMAIN_PREFIX:-daemon-opensuse-itest}
export DISTRO_SERVICE_PREFIX=${DISTRO_SERVICE_PREFIX:-opensuse}
export DISTRO_IMAGE_FILENAME=$image_name
export DISTRO_IMAGE_URL=$image_url
export DISTRO_IMAGE_SHA256=${DISTRO_IMAGE_SHA256:-2576399b3a1425b600e6a67ba42edbbb2895e755df9ac43423d369ab273c6527}
export DISTRO_IMAGE_CHECKSUM_URL=${DISTRO_IMAGE_CHECKSUM_URL:-$image_url.sha256}
export DISTRO_EXPECT_SELINUX=0
export DISTRO_GUEST_GROUP=${DISTRO_GUEST_GROUP:-users}
export DISTRO_GUEST_ASSERTION=${DISTRO_GUEST_ASSERTION:-'test -d /sys/module/apparmor && findmnt -n -o FSTYPE / | grep -Eq "^(btrfs|xfs)$"'}
export DISTRO_CLOUD_INIT_DIAGNOSTICS=1
export DISTRO_ENABLE_SSHD=1
export DISTRO_DISABLE_FIREWALL=1
export VM_ARCH=${VM_ARCH:-arm64}
export VM_OS_VARIANT=${VM_OS_VARIANT:-generic}
export VM_BOOT_TIMEOUT=${VM_BOOT_TIMEOUT:-1200}

exec "$integration_dir/rocky/run-libvirt.sh" "$@"
