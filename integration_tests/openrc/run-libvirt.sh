#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
alpine_version=${ALPINE_VERSION:-3.24.1}
alpine_branch=${ALPINE_BRANCH:-${alpine_version%.*}}
vm_memory_mib=${VM_MEMORY_MIB:-1024}
vm_vcpus=${VM_VCPUS:-2}
vm_disk_gib=${VM_DISK_GIB:-4}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-600}
vm_os_variant=${VM_OS_VARIANT:-alpinelinux3.21}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-openrc-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/openrc-$run_id"
ssh_user=alpine
remote_ready=0
ip_address=
metadata_host=${VM_METADATA_HOST:-192.168.122.1}
metadata_server_pid=
metadata_port=

log() {
	printf '[openrc-vm] %s\n' "$*"
}

fail() {
	printf '[openrc-vm] ERROR: %s\n' "$*" >&2
	return 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed"
}

host_arch=$(uname -m)
if [[ "$host_arch" != aarch64 && "$host_arch" != arm64 ]]; then
	fail "the OpenRC lane currently supports an ARM64 host; found $host_arch"
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

for command in go qemu-img virsh virt-install uuidgen python3 ssh scp ssh-keygen wget sha512sum; do
	require_command "$command"
done

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

image_filename="generic_alpine-${alpine_version}-aarch64-uefi-cloudinit-r0.qcow2"
default_image_url="https://dl-cdn.alpinelinux.org/alpine/v${alpine_branch}/releases/cloud/${image_filename}"
base_image=${ALPINE_BASE_IMAGE:-$cache_dir/$image_filename}
image_url=${ALPINE_BASE_IMAGE_URL:-$default_image_url}

verify_image() {
	local image=$1
	local expected=${ALPINE_BASE_IMAGE_SHA512:-}
	if [[ -z "$expected" ]]; then
		expected=$(wget -qO- "${image_url}.sha512" | awk 'NR == 1 {print $1}')
	fi
	[[ -n "$expected" ]] || fail "could not obtain the Alpine image SHA-512 checksum"
	printf '%s  %s\n' "$expected" "$image" | sha512sum --check --status - || fail "Alpine base image failed SHA-512 verification"
}

if [[ ! -f "$base_image" ]]; then
	if [[ -n "${ALPINE_BASE_IMAGE:-}" ]]; then
		fail "ALPINE_BASE_IMAGE does not exist: $base_image"
	fi
	log "downloading Alpine $alpine_version ARM64 cloud image"
	temporary_image="$base_image.partial"
	rm -f "$temporary_image"
	wget --progress=dot:giga -O "$temporary_image" "$image_url"
	verify_image "$temporary_image"
	mv "$temporary_image" "$base_image"
elif [[ -n "${ALPINE_BASE_IMAGE_SHA512:-}" ]]; then
	verify_image "$base_image"
fi
chmod 0644 "$base_image"
base_image=$(readlink -f "$base_image")

key_path="$work_dir/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$key_path"
public_key=$(cat "$key_path.pub")

metadata_dir="$work_dir/nocloud"
user_data="$metadata_dir/user-data"
meta_data="$metadata_dir/meta-data"
overlay_image="$work_dir/root.qcow2"
mkdir -p "$metadata_dir"

python3 - "$user_data" "$public_key" <<'PY'
import json
import sys

path, public_key = sys.argv[1:]
config = {
		"users": ["default"],
		"ssh_authorized_keys": [public_key],
		"packages": ["bash", "openssh-server-pam"],
		"write_files": [{
				"path": "/etc/ssh/sshd_config.d/99-cloud-init-pam.conf",
				"permissions": "0644",
				"content": "UsePAM yes\n",
		}],
		"runcmd": [["rc-service", "sshd", "restart"]],
		"ssh_pwauth": False,
		"disable_root": True,
}
with open(path, "w", encoding="utf-8") as output:
		output.write("#cloud-config\n")
		json.dump(config, output)
		output.write("\n")
PY

cat >"$meta_data" <<EOF
instance-id: $domain_name
local-hostname: $domain_name
EOF

qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" "$overlay_image" "${vm_disk_gib}G"
chmod 0644 "$overlay_image"

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
	if [[ -n "$metadata_server_pid" ]]; then
		kill "$metadata_server_pid" >/dev/null 2>&1 || true
		wait "$metadata_server_pid" 2>/dev/null || true
	fi
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

metadata_port_file="$work_dir/metadata-port"
python3 - "$metadata_dir" "$metadata_host" "$metadata_port_file" >"$artifact_dir/metadata-server.log" 2>&1 <<'PY' &
import http.server
import os
import sys

directory, host, port_file = sys.argv[1:]
handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
    *args, directory=directory, **kwargs
)
server = http.server.ThreadingHTTPServer((host, 0), handler)
with open(port_file, "w", encoding="ascii") as output:
    output.write(str(server.server_port))
    output.flush()
    os.fsync(output.fileno())
server.serve_forever()
PY
metadata_server_pid=$!
for _ in $(seq 1 50); do
	if [[ -s "$metadata_port_file" ]]; then
		metadata_port=$(cat "$metadata_port_file")
		break
	fi
	sleep 0.1
done
[[ -n "$metadata_port" ]] || fail "NoCloud-Net metadata server did not start"
kill -0 "$metadata_server_pid" 2>/dev/null || fail "NoCloud-Net metadata server exited unexpectedly"
log "serving NoCloud metadata at http://$metadata_host:$metadata_port/"

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
	--sysinfo "system.serial=ds=nocloud-net;s=http://$metadata_host:$metadata_port/"
	"${cpu_args[@]}"
	--import
	--disk "path=$overlay_image,format=qcow2,bus=virtio"
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
cloud_init_status=0
ssh_guest cloud-init status --wait >/dev/null || cloud_init_status=$?
if (( cloud_init_status != 0 && cloud_init_status != 2 )); then
	fail "cloud-init did not complete successfully (exit $cloud_init_status)"
fi
ssh_guest doas true
ssh_guest command -v bash >/dev/null
ssh_guest command -v supervise-daemon >/dev/null

log "copying integration payload"
scp "${ssh_options[@]}" \
	"$build_dir/daemon" \
	"$build_dir/test-app" \
	"$build_dir/relative-path-test.txt" \
	"$build_dir/guest-test.sh" \
	"$build_dir/interpreted-app-test.sh" \
	"$ssh_user@$ip_address:/tmp/"
ssh_guest doas install -d -m 0755 /opt/daemon-itest
ssh_guest doas install -m 0755 /tmp/daemon /opt/daemon-itest/daemon
ssh_guest doas install -m 0755 /tmp/test-app /opt/daemon-itest/test-app
ssh_guest doas install -m 0644 /tmp/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest doas install -m 0755 /tmp/guest-test.sh /opt/daemon-itest/guest-test.sh
ssh_guest doas install -m 0755 /tmp/interpreted-app-test.sh /opt/daemon-itest/interpreted-app-test.sh

log "running pre-reboot lifecycle checks"
ssh_guest doas /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id)
log "rebooting guest to verify service persistence"
ssh_guest doas reboot >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log "running post-reboot lifecycle checks"
ssh_guest doas /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts

log "OpenRC VM integration test passed"
