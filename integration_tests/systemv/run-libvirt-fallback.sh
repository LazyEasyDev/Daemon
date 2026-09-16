#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
debian_release=${DEBIAN_RELEASE:-12}
vm_arch=${VM_ARCH:-}
vm_memory_mib=${VM_MEMORY_MIB:-2048}
vm_vcpus=${VM_VCPUS:-2}
vm_disk_gib=${VM_DISK_GIB:-12}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-600}
vm_os_variant=${VM_OS_VARIANT:-debian12}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-systemv-fallback-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/systemv-fallback-$run_id"
ssh_user=daemon-itest
remote_ready=0
ip_address=

log() {
	printf '[systemv-fallback] %s\n' "$*"
}

fail() {
	printf '[systemv-fallback] ERROR: %s\n' "$*" >&2
	return 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed"
}

host_arch=$(uname -m)
if [[ -z "$vm_arch" ]]; then
	case "$host_arch" in
		x86_64) vm_arch=amd64 ;;
		aarch64|arm64) vm_arch=arm64 ;;
		*) fail "cannot infer a supported VM architecture from host architecture $host_arch" ;;
	esac
fi

case "$vm_arch" in
	amd64)
		image_arch=amd64
		go_arch=amd64
		virt_arch=x86_64
		machine_args=()
		boot_args=()
		matching_host_arch=x86_64
		;;
	arm64|aarch64)
		image_arch=arm64
		go_arch=arm64
		virt_arch=aarch64
		machine_args=(--machine virt)
		arm_uefi_code=${ARM_UEFI_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
		arm_uefi_vars=${ARM_UEFI_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}
		[[ -f "$arm_uefi_code" ]] || fail "ARM UEFI code image does not exist: $arm_uefi_code"
		[[ -f "$arm_uefi_vars" ]] || fail "ARM UEFI variables image does not exist: $arm_uefi_vars"
		boot_args=(--boot "loader=$arm_uefi_code,loader.readonly=yes,loader.type=pflash,nvram.template=$arm_uefi_vars")
		matching_host_arch=aarch64
		;;
	*)
		fail "VM_ARCH must be amd64 or arm64"
		;;
esac

if [[ -n "${VM_VIRT_TYPE:-}" ]]; then
	virt_type=$VM_VIRT_TYPE
elif [[ "$host_arch" == "$matching_host_arch" && -r /dev/kvm ]]; then
	virt_type=kvm
else
	virt_type=qemu
fi

if [[ "$virt_type" == kvm ]]; then
	cpu_args=(--cpu host-passthrough)
elif [[ "$virt_arch" == aarch64 ]]; then
	cpu_args=(--cpu cortex-a72)
	log "KVM is unavailable or disabled; using QEMU software emulation with Cortex-A72 compatibility"
else
	cpu_args=(--cpu max)
	log "KVM is unavailable or disabled; using QEMU software emulation"
fi

for command in go qemu-img virsh virt-install uuidgen cloud-localds ssh scp ssh-keygen wget sha512sum; do
	require_command "$command"
done

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

image_filename="debian-${debian_release}-genericcloud-${image_arch}.qcow2"
default_image_url="https://cloud.debian.org/images/cloud/bookworm/latest/${image_filename}"
base_image=${BASE_IMAGE:-$cache_dir/$image_filename}
image_url=${BASE_IMAGE_URL:-$default_image_url}

verify_image() {
	local image=$1
	if [[ -n "${BASE_IMAGE_SHA512:-}" ]]; then
		printf '%s  %s\n' "$BASE_IMAGE_SHA512" "$image" | sha512sum --check --status - || fail "base image SHA-512 does not match BASE_IMAGE_SHA512"
		return
	fi
	local sums="$work_dir/SHA512SUMS"
	wget -q -O "$sums" "${image_url%/"$image_filename"}/SHA512SUMS"
	local expected
	expected=$(awk -v file="$image_filename" '$2 == "*" file || $2 == file {print $1; exit}' "$sums")
	[[ -n "$expected" ]] || fail "could not find $image_filename in the published SHA512SUMS"
	printf '%s  %s\n' "$expected" "$image" | sha512sum --check --status - || fail "downloaded base image failed SHA-512 verification"
}

if [[ ! -f "$base_image" ]]; then
	if [[ -n "${BASE_IMAGE:-}" ]]; then
		fail "BASE_IMAGE does not exist: $base_image"
	fi
	log "downloading Debian $debian_release $image_arch cloud image"
	temporary_image="$base_image.partial"
	rm -f "$temporary_image"
	wget --progress=dot:giga -O "$temporary_image" "$image_url"
	verify_image "$temporary_image"
	mv "$temporary_image" "$base_image"
elif [[ -n "${BASE_IMAGE_SHA512:-}" ]]; then
	verify_image "$base_image"
fi
chmod 0644 "$base_image"
base_image=$(readlink -f "$base_image")

key_path="$work_dir/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$key_path"
public_key=$(cat "$key_path.pub")

user_data="$work_dir/user-data"
meta_data="$work_dir/meta-data"
seed_image="$work_dir/cloud-init.iso"
overlay_image="$work_dir/root.qcow2"

cat >"$user_data" <<EOF
#cloud-config
users:
  - default
  - name: $ssh_user
    gecos: daemon-util integration test
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
disable_root: true
EOF

cat >"$meta_data" <<EOF
instance-id: $domain_name
local-hostname: $domain_name
EOF

cloud-localds "$seed_image" "$user_data" "$meta_data"
qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" "$overlay_image" "${vm_disk_gib}G"
chmod 0644 "$seed_image" "$overlay_image"

build_dir="$work_dir/build"
mkdir -p "$build_dir"
log "building Linux/$go_arch integration binaries"
(
	cd "$repo_dir"
	CGO_ENABLED=0 GOOS=linux GOARCH="$go_arch" go build -trimpath -o "$build_dir/daemon" .
	CGO_ENABLED=0 GOOS=linux GOARCH="$go_arch" go build -trimpath -o "$build_dir/test-app" ./test_app
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

ssh_guest_retry() {
	local attempts=${SSH_RETRY_ATTEMPTS:-4}
	local delay=${SSH_RETRY_DELAY:-3}
	local i
	for (( i=1; i<=attempts; i++ )); do
		if ssh_guest "$@"; then
			return
		fi
		if (( i < attempts )); then
			sleep "$delay"
		fi
	done
	fail "guest command failed after $attempts attempts: $*"
}

lease_addresses() {
	local name=$1
	local mac
	mac=$(virsh_command domiflist "$name" 2>/dev/null | awk '$2 == "network" {print $5; exit}' || true)
	{
		virsh_command domifaddr "$name" --source lease 2>/dev/null | awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4}' || true
		if [[ -n "$mac" ]]; then
			virsh_command net-dhcp-leases "$vm_network" --mac "$mac" 2>/dev/null | awk '$5 == "ipv4" {sub(/\/.*/, "", $6); print $6}' || true
		fi
	} | awk 'NF && !seen[$0]++'
}

wait_for_ssh() {
	local name=$1
	local timeout_seconds=$2
	local description=$3
	local stable_successes=${4:-1}
	local deadline=$((SECONDS + timeout_seconds))
	local started=$SECONDS
	local next_progress=$SECONDS
	local candidates candidate stable_count
	while (( SECONDS < deadline )); do
		candidates=$(lease_addresses "$name")
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			ip_address=$candidate
			if ssh_guest true >/dev/null 2>&1; then
				stable_count=1
				while (( stable_count < stable_successes )); do
					sleep 1
					if ssh_guest true >/dev/null 2>&1; then
						stable_count=$((stable_count + 1))
					else
						break
					fi
				done
				if (( stable_count == stable_successes )); then
					log "$description is reachable at $ip_address"
					remote_ready=1
					return
				fi
			fi
		done <<<"$candidates"
		if (( SECONDS >= next_progress )); then
			log "waiting for $description SSH ($((SECONDS - started))s elapsed)"
			next_progress=$((SECONDS + 15))
		fi
		sleep 2
	done
	fail "timed out waiting for $description SSH"
}

wait_for_new_boot() {
	local previous_boot_id=$1
	local deadline=$((SECONDS + vm_boot_timeout))
	local started=$SECONDS
	local next_progress=$SECONDS
	local candidates candidate current_boot_id
	while (( SECONDS < deadline )); do
		candidates=$(lease_addresses "$domain_uuid")
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			ip_address=$candidate
			current_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
			if [[ -n "$current_boot_id" && "$current_boot_id" != "$previous_boot_id" ]]; then
				log "guest rebooted with address $ip_address"
				return
			fi
		done <<<"$candidates"
		if (( SECONDS >= next_progress )); then
			log "waiting for guest reboot ($((SECONDS - started))s elapsed)"
			next_progress=$((SECONDS + 15))
		fi
		sleep 2
	done
	fail "timed out waiting for the guest to reboot"
}

copy_guest_artifacts() {
	if [[ "$remote_ready" != 1 || -z "$ip_address" ]]; then
		return
	fi
	mkdir -p "$artifact_dir/guest"
	scp "${ssh_options[@]}" -r \
		"$ssh_user@$ip_address:/var/tmp/daemon-itest-$service_name/artifacts/." \
		"$artifact_dir/guest/" >/dev/null 2>&1 || true
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
	--arch "$virt_arch"
	"${machine_args[@]}"
	"${boot_args[@]}"
	"${cpu_args[@]}"
	--import
	--disk "path=$overlay_image,format=qcow2,bus=virtio"
	--disk "path=$seed_image,device=cdrom"
	--network "network=$vm_network,model=virtio"
	--os-variant "$vm_os_variant"
	--graphics none
	--noautoconsole
	--wait 0
)

log "creating Debian fallback domain $domain_name"
virt-install "${virt_install_args[@]}"
wait_for_ssh "$domain_uuid" "$vm_boot_timeout" "Debian fallback guest" 3
ssh_guest_retry cloud-init status --wait >/dev/null

log "converting Debian guest to SysV init"
ssh_guest_retry "for attempt in 1 2 3; do sudo DEBIAN_FRONTEND=noninteractive apt-get update && exit 0; sleep 5; done; exit 1"
# On Debian cloud images under emulation, initscripts postinst can hang on
# `systemctl daemon-reload`. Prepend a no-op shim in /usr/local/sbin for the
# conversion command so maintainer scripts keep moving.
ssh_guest_retry "printf '%s\n' '#!/bin/sh' 'exit 0' | sudo tee /usr/local/sbin/systemctl >/dev/null; sudo chmod 0755 /usr/local/sbin/systemctl"
ssh_guest_retry "sudo env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sysvinit-core sysv-rc initscripts"
ssh_guest_retry "sudo rm -f /usr/local/sbin/systemctl"
# Debian cloud images often provide mountkernfs.sh while some tooling expects
# mountkernfs. Normalize after package installation to avoid duplicate providers
# during initscripts configuration.
ssh_guest_retry "if [ ! -e /etc/init.d/mountkernfs ] && [ -e /etc/init.d/mountkernfs.sh ]; then sudo ln -s /etc/init.d/mountkernfs.sh /etc/init.d/mountkernfs; fi"
ssh_guest_retry "if [ ! -e /etc/init.d/mountkernfs ] && [ ! -e /etc/init.d/mountkernfs.sh ]; then printf '%s\n' '#!/bin/sh' 'exit 0' | sudo tee /etc/init.d/mountkernfs >/dev/null; sudo chmod 0755 /etc/init.d/mountkernfs; fi"
ssh_guest_retry "test -e /etc/init.d/mountkernfs || test -e /etc/init.d/mountkernfs.sh || { ls -l /etc/init.d/mount* 2>/dev/null; exit 1; }"
ssh_guest_retry "if dpkg -s systemd-sysv >/dev/null 2>&1; then sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y systemd-sysv; fi"

previous_boot_id=$(ssh_guest_retry cat /proc/sys/kernel/random/boot_id)
log "rebooting converted SysV guest"
ssh_guest_retry sudo reboot >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"

[[ "$(ssh_guest_retry cat /proc/1/comm)" == init ]] || fail "guest is not running SysV init as PID 1 after conversion"

log "copying integration payload"
scp "${ssh_options[@]}" \
	"$build_dir/daemon" \
	"$build_dir/test-app" \
	"$build_dir/relative-path-test.txt" \
	"$build_dir/guest-test.sh" \
	"$build_dir/interpreted-app-test.sh" \
	"$ssh_user@$ip_address:/tmp/"
ssh_guest_retry sudo install -d -m 0755 /opt/daemon-itest
ssh_guest_retry sudo install -m 0755 /tmp/daemon /opt/daemon-itest/daemon
ssh_guest_retry sudo install -m 0755 /tmp/test-app /opt/daemon-itest/test-app
ssh_guest_retry sudo install -m 0644 /tmp/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest_retry sudo install -m 0755 /tmp/guest-test.sh /opt/daemon-itest/guest-test.sh
ssh_guest_retry sudo install -m 0755 /tmp/interpreted-app-test.sh /opt/daemon-itest/interpreted-app-test.sh

log "running pre-reboot lifecycle checks"
ssh_guest_retry sudo /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest_retry cat /proc/sys/kernel/random/boot_id)
log "rebooting guest to verify service persistence"
ssh_guest_retry sudo reboot >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log "running post-reboot lifecycle checks"
ssh_guest_retry sudo /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts

log "System V fallback VM integration test passed"
