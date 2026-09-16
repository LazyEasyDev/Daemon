#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
libvirt_uri=${LIBVIRT_URI:-qemu:///system}
. "$script_dir/libvirt-domain.sh"

sentinel_name="daemon-ownership-$(date -u +%Y%m%dT%H%M%SZ)-$$"
sentinel_uuid=$(new_domain_uuid "$sentinel_name")
partial_name="$sentinel_name-partial"
partial_uuid=$(new_domain_uuid "$partial_name")
work=$(mktemp -d /var/tmp/daemon-ownership-test.XXXXXX)
artifact_dir=${OWNERSHIP_ARTIFACT_DIR:-$script_dir/artifacts/ownership-$(date -u +%Y%m%dT%H%M%SZ)-$$}
mkdir -p "$artifact_dir" "$work/existing-work"
printf '%s\n' 'must remain untouched' >"$work/existing-work/sentinel"
touch "$work/kernel" "$work/rootfs"

cleanup() {
	local status=$?
	trap - EXIT
	remove_owned_domain "$partial_uuid"
	remove_owned_domain "$sentinel_uuid"
	rm -rf "$work"
	exit "$status"
}
trap cleanup EXIT

case $(uname -m) in
	aarch64|arm64) arch=aarch64; machine=virt ;;
	x86_64|amd64) arch=x86_64; machine=pc ;;
	*) printf 'unsupported libvirt test architecture\n' >&2; exit 1 ;;
esac

# These diskless test definitions are never booted. Their generated UUIDs are
# the only identities this test may unregister.
cat >"$work/domain.xml" <<EOF
<domain type='qemu'>
  <name>$sentinel_name</name>
  <uuid>$sentinel_uuid</uuid>
  <memory unit='MiB'>128</memory>
  <vcpu>1</vcpu>
  <os><type arch='$arch' machine='$machine'>hvm</type></os>
</domain>
EOF
virsh_command define "$work/domain.xml" >/dev/null

for runner in systemd/run-libvirt.sh rocky/run-libvirt.sh fedora/run-libvirt.sh opensuse/run-libvirt.sh \
	openrc/run-libvirt.sh openwrt/run-libvirt.sh freebsd/run-libvirt.sh upstart/run-libvirt.sh \
	buildroot/run-libvirt.sh systemv/run-libvirt.sh systemv/run-libvirt-fallback.sh; do
	label=${runner//\//-}
	if VM_NAME="$sentinel_name" VM_WORK_DIR="$work/existing-work" KEEP_VM=0 \
		BUILDROOT_KERNEL="$work/kernel" BUILDROOT_ROOTFS="$work/rootfs" \
		INTEGRATION_ARTIFACT_DIR="$work/uncreated-artifacts" \
		bash "$script_dir/$runner" >"$artifact_dir/$label.log" 2>&1; then
		printf 'FAIL: %s accepted an existing domain\n' "$runner" >&2
		exit 1
	fi
	grep -Fq 'domain already exists:' "$artifact_dir/$label.log" || {
		cat "$artifact_dir/$label.log" >&2
		printf 'FAIL: %s did not reach the ownership check\n' "$runner" >&2
		exit 1
	}
	[[ "$(virsh_command domuuid "$sentinel_name")" == "$sentinel_uuid" ]]
	[[ "$(cat "$work/existing-work/sentinel")" == 'must remain untouched' ]]
	[[ ! -e "$work/uncreated-artifacts" ]]
	[[ $(find "$work/existing-work" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]
	printf 'PASS: %s refused the collision without changing the existing domain or workspace\n' "$runner"
done

cat >"$work/partial.xml" <<EOF
<domain type='qemu'>
  <name>$partial_name</name>
  <uuid>$partial_uuid</uuid>
  <memory unit='MiB'>128</memory>
  <vcpu>1</vcpu>
  <os><type arch='$arch' machine='$machine'>hvm</type></os>
</domain>
EOF
virsh_command define "$work/partial.xml" >/dev/null
remove_owned_domain "$partial_uuid"
if virsh_command dominfo "$partial_uuid" >/dev/null 2>&1; then
	printf 'FAIL: partially created owned domain was not cleaned up\n' >&2
	exit 1
fi
[[ "$(virsh_command domuuid "$sentinel_name")" == "$sentinel_uuid" ]]
printf '%s\n' 'PASS: UUID-only partial-creation cleanup preserved the unrelated domain'
printf '%s\n' 'PASS' >"$artifact_dir/result.txt"
