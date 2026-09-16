#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
openwrt_version=${OPENWRT_VERSION:-25.12.5}
vm_memory_mib=${VM_MEMORY_MIB:-512}
vm_vcpus=${VM_VCPUS:-2}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-300}
vm_os_variant=${VM_OS_VARIANT:-linux2024}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-openwrt-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/openwrt-$run_id"
ssh_user=root
remote_ready=0
ip_address=

log() {
	printf '[openwrt-vm] %s\n' "$*"
}

fail() {
	printf '[openwrt-vm] ERROR: %s\n' "$*" >&2
	return 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed"
}

host_arch=$(uname -m)
if [[ "$host_arch" != aarch64 && "$host_arch" != arm64 ]]; then
	fail "the OpenWrt lane currently supports an ARM64 host; found $host_arch"
fi

virt_type=${VM_VIRT_TYPE:-}
if [[ -z "$virt_type" ]]; then
	if [[ -r /dev/kvm ]]; then
		virt_type=kvm
	else
		virt_type=qemu
	fi
fi

if [[ "$virt_type" == kvm ]]; then
	cpu_args=(--cpu host-passthrough)
else
	cpu_args=(--cpu cortex-a72)
	log "KVM is unavailable or disabled; using QEMU software emulation with Cortex-A72 compatibility"
fi

arm_uefi_code=${ARM_UEFI_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
arm_uefi_vars=${ARM_UEFI_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}
[[ -f "$arm_uefi_code" ]] || fail "ARM UEFI code image does not exist: $arm_uefi_code"
[[ -f "$arm_uefi_vars" ]] || fail "ARM UEFI variables image does not exist: $arm_uefi_vars"

for command in go qemu-img virsh virt-install uuidgen python3 ssh ssh-keygen wget sha256sum gzip sfdisk debugfs dumpe2fs e2fsck dd tar; do
	require_command "$command"
done

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

image_filename="openwrt-${openwrt_version}-armsr-armv8-generic-ext4-combined-efi.img.gz"
image_directory="https://downloads.openwrt.org/releases/${openwrt_version}/targets/armsr/armv8"
image_url=${OPENWRT_IMAGE_URL:-$image_directory/$image_filename}
compressed_image=${OPENWRT_COMPRESSED_IMAGE:-$cache_dir/$image_filename}
base_image=${OPENWRT_BASE_IMAGE:-$cache_dir/${image_filename%.gz}}

verify_compressed_image() {
	local image=$1
	local expected=${OPENWRT_IMAGE_SHA256:-}
	if [[ -z "$expected" ]]; then
		local checksums="$work_dir/sha256sums"
		wget -qO "$checksums" "${image_url%/"$image_filename"}/sha256sums"
		expected=$(awk -v file="$image_filename" '{name=$2; sub(/^\*/, "", name); if (name == file) {print $1; exit}}' "$checksums")
	fi
	[[ -n "$expected" ]] || fail "could not obtain the OpenWrt image SHA-256 checksum"
	printf '%s  %s\n' "$expected" "$image" | sha256sum --check --status - || fail "OpenWrt compressed image failed SHA-256 verification"
}

if [[ ! -f "$base_image" ]]; then
	if [[ ! -f "$compressed_image" ]]; then
		if [[ -n "${OPENWRT_COMPRESSED_IMAGE:-}" ]]; then
			fail "OPENWRT_COMPRESSED_IMAGE does not exist: $compressed_image"
		fi
		log "downloading OpenWrt $openwrt_version ARM64 image"
		temporary_compressed="$compressed_image.partial"
		rm -f "$temporary_compressed"
		wget --progress=dot:giga -O "$temporary_compressed" "$image_url"
		verify_compressed_image "$temporary_compressed"
		mv "$temporary_compressed" "$compressed_image"
	elif [[ -n "${OPENWRT_IMAGE_SHA256:-}" ]]; then
		verify_compressed_image "$compressed_image"
	fi
	log "decompressing OpenWrt image"
	temporary_base="$base_image.partial"
	rm -f "$temporary_base"
	gzip -dc "$compressed_image" >"$temporary_base"
	mv "$temporary_base" "$base_image"
elif [[ -n "${OPENWRT_BASE_IMAGE_SHA256:-}" ]]; then
	printf '%s  %s\n' "$OPENWRT_BASE_IMAGE_SHA256" "$base_image" | sha256sum --check --status - || fail "OpenWrt base image failed SHA-256 verification"
fi
chmod 0644 "$base_image"
base_image=$(readlink -f "$base_image")

key_path="$work_dir/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$key_path"
public_key=$(cat "$key_path.pub")

vm_image="$work_dir/root.img"
root_filesystem="$work_dir/root.ext4"
key_file="$work_dir/authorized_keys"
defaults_script="$work_dir/99-daemon-itest"
cp --reflink=auto "$base_image" "$vm_image"
printf '%s\n' "$public_key" >"$key_file"
cat >"$defaults_script" <<'EOF'
#!/bin/sh

uci -q batch <<'UCI'
set network.lan=interface
set network.lan.device='eth0'
set network.lan.proto='dhcp'
delete network.lan.ipaddr
delete network.lan.netmask
set dhcp.lan=dhcp
set dhcp.lan.interface='lan'
set dhcp.lan.ignore='1'
commit network
commit dhcp
UCI

exit 0
EOF

read -r root_start root_size < <(
	sfdisk -J "$vm_image" 2>/dev/null | python3 -c '
import json
import sys
partition_table = json.load(sys.stdin)["partitiontable"]
for partition in partition_table["partitions"]:
    if partition.get("type", "").lower() == "0fc63daf-8483-4772-8e79-3d69d8477de4":
        print(partition["start"], partition["size"])
        break
else:
    raise SystemExit("OpenWrt Linux root partition was not found")
'
)
[[ -n "$root_start" && -n "$root_size" ]] || fail "could not identify the OpenWrt root partition"

dd if="$vm_image" of="$root_filesystem" bs=512 skip="$root_start" count="$root_size" status=none
{
	debugfs -w -R "write $key_file /etc/dropbear/authorized_keys" "$root_filesystem"
	debugfs -w -R 'set_inode_field /etc/dropbear/authorized_keys mode 0100600' "$root_filesystem"
	debugfs -w -R "write $defaults_script /etc/uci-defaults/99-daemon-itest" "$root_filesystem"
	debugfs -w -R 'set_inode_field /etc/uci-defaults/99-daemon-itest mode 0100755' "$root_filesystem"
} >"$artifact_dir/debugfs.log" 2>&1
fsck_status=0
e2fsck -fy "$root_filesystem" >"$artifact_dir/e2fsck.log" 2>&1 || fsck_status=$?
if (( fsck_status > 1 )); then
	fail "OpenWrt root filesystem check failed with exit $fsck_status"
fi
dd if="$root_filesystem" of="$vm_image" bs=512 seek="$root_start" count="$root_size" conv=notrunc status=none
chmod 0644 "$vm_image"

build_dir="$work_dir/build"
mkdir -p "$build_dir"
log "building Linux/arm64 integration binaries"
(
	cd "$repo_dir"
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$build_dir/daemon" .
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$build_dir/test-app" ./test_app
)
printf '%s\n' 'daemon-util relative path test passed' >"$build_dir/relative-path-test.txt"
cp "$script_dir/guest-test.sh" "$build_dir/guest-test.sh"
cp "$repo_dir/integration_tests/interpreted-app-test.sh" "$build_dir/interpreted-app-test.sh"
chmod 0755 "$build_dir/daemon" "$build_dir/test-app" "$build_dir/guest-test.sh" "$build_dir/interpreted-app-test.sh"

ssh_options=(
	-i "$key_path"
	-o BatchMode=yes
	-o ConnectTimeout=5
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
)

ssh_guest() {
	# Arguments are intentionally serialized by SSH for execution in the guest.
	# shellcheck disable=SC2029
	ssh "${ssh_options[@]}" "$ssh_user@$ip_address" "$@"
}

copy_guest_artifacts() {
	if [[ "$remote_ready" != 1 || -z "$ip_address" ]]; then
		return
	fi
	mkdir -p "$artifact_dir/guest"
	# shellcheck disable=SC2029
	ssh "${ssh_options[@]}" "$ssh_user@$ip_address" \
		"tar -C /opt/daemon-itest/state-$service_name/artifacts -cf - ." 2>/dev/null |
		tar -C "$artifact_dir/guest" -xf - 2>/dev/null || true
}

cleanup() {
	local status=$?
	trap - EXIT
	copy_guest_artifacts
	virsh_command dumpxml "$domain_uuid" >"$artifact_dir/domain.xml" 2>/dev/null || true
	virsh_command domstats "$domain_uuid" >"$artifact_dir/domain-stats.txt" 2>/dev/null || true
	virsh_command domifaddr "$domain_uuid" --source lease >"$artifact_dir/domain-addresses.txt" 2>/dev/null || true
	virsh_command net-dhcp-leases "$vm_network" >"$artifact_dir/network-leases.txt" 2>/dev/null || true
	if [[ "$keep_vm" == 1 ]]; then
		log "keeping VM $domain_name and work directory $work_dir"
	else
		remove_owned_domain "$domain_uuid"
		rm -rf "$work_dir" || true
	fi
	if (( status == 0 )); then
		log "artifacts: $artifact_dir"
	else
		log "test failed; artifacts: $artifact_dir" >&2
	fi
	exit "$status"
}
trap cleanup EXIT

if ! virsh_command net-info "$vm_network" >/dev/null 2>&1; then
	fail "libvirt network '$vm_network' does not exist"
fi
if [[ "$(virsh_command net-info "$vm_network" | awk '/^Active:/ {print $2}')" != yes ]]; then
	log "starting libvirt network $vm_network"
	virsh_command net-start "$vm_network" >/dev/null
fi

virt_install_args=(
	--connect "$libvirt_uri"
	--name "$domain_name"
	--uuid "$domain_uuid"
	--memory "$vm_memory_mib"
	--vcpus "$vm_vcpus"
	--virt-type "$virt_type"
	--arch aarch64
	--machine virt
	--boot "loader=$arm_uefi_code,loader.readonly=yes,loader.type=pflash,nvram.template=$arm_uefi_vars"
	"${cpu_args[@]}"
	--import
	--disk "path=$vm_image,format=raw,bus=virtio"
	--network "network=$vm_network,model=virtio"
	--os-variant "$vm_os_variant"
	--graphics none
	--noautoconsole
	--wait 0
)

log "creating libvirt domain $domain_name"
virt-install "${virt_install_args[@]}"

wait_for_ip() {
	local deadline=$((SECONDS + vm_boot_timeout))
	local started=$SECONDS
	local next_progress=$SECONDS
	while (( SECONDS < deadline )); do
		ip_address=$(virsh_command domifaddr "$domain_uuid" --source lease 2>/dev/null | awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4; exit}' || true)
		if [[ -z "$ip_address" ]]; then
			ip_address=$(virsh_command domifaddr "$domain_uuid" --source agent 2>/dev/null | awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4; exit}' || true)
		fi
		if [[ -n "$ip_address" ]]; then
			return
		fi
		if (( SECONDS >= next_progress )); then
			log "waiting for guest DHCP address ($((SECONDS - started))s elapsed)"
			next_progress=$((SECONDS + 15))
		fi
		sleep 2
	done
	fail "timed out waiting for a guest IPv4 address"
}

wait_for_ssh() {
	local deadline=$((SECONDS + vm_boot_timeout))
	local started=$SECONDS
	local next_progress=$SECONDS
	while (( SECONDS < deadline )); do
		if ssh_guest true >/dev/null 2>&1; then
			remote_ready=1
			return
		fi
		if (( SECONDS >= next_progress )); then
			log "waiting for SSH at $ip_address ($((SECONDS - started))s elapsed)"
			next_progress=$((SECONDS + 15))
		fi
		sleep 2
	done
	fail "timed out waiting for SSH at $ip_address"
}

wait_for_new_boot() {
	local previous_boot_id=$1
	local deadline=$((SECONDS + vm_boot_timeout))
	local started=$SECONDS
	local next_progress=$SECONDS
	local current_boot_id
	while (( SECONDS < deadline )); do
		current_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
		if [[ -n "$current_boot_id" && "$current_boot_id" != "$previous_boot_id" ]]; then
			return
		fi
		if (( SECONDS >= next_progress )); then
			log "waiting for guest reboot ($((SECONDS - started))s elapsed)"
			next_progress=$((SECONDS + 15))
		fi
		sleep 2
	done
	fail "timed out waiting for the guest to reboot"
}

wait_for_ip
log "guest address: $ip_address"
wait_for_ssh

log "copying integration payload"
tar -C "$build_dir" -cf - daemon test-app relative-path-test.txt guest-test.sh interpreted-app-test.sh |
	ssh "${ssh_options[@]}" "$ssh_user@$ip_address" \
		'mkdir -p /tmp/daemon-payload && tar -C /tmp/daemon-payload -xf -'
ssh_guest mkdir -p /opt/daemon-itest
ssh_guest cp /tmp/daemon-payload/daemon /opt/daemon-itest/daemon
ssh_guest cp /tmp/daemon-payload/test-app /opt/daemon-itest/test-app
ssh_guest cp /tmp/daemon-payload/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest cp /tmp/daemon-payload/guest-test.sh /opt/daemon-itest/guest-test.sh
ssh_guest cp /tmp/daemon-payload/interpreted-app-test.sh /opt/daemon-itest/interpreted-app-test.sh
ssh_guest chmod 0755 /opt/daemon-itest/daemon /opt/daemon-itest/test-app /opt/daemon-itest/guest-test.sh /opt/daemon-itest/interpreted-app-test.sh
ssh_guest chmod 0644 /opt/daemon-itest/relative-path-test.txt

log "running pre-reboot lifecycle checks"
ssh_guest /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id)
log "rebooting guest to verify service persistence"
ssh_guest reboot >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log "running post-reboot lifecycle checks"
ssh_guest /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts

log "OpenWrt VM integration test passed"
