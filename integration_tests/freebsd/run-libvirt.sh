#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
freebsd_release=${FREEBSD_RELEASE:-14.4-RELEASE}
vm_memory_mib=${VM_MEMORY_MIB:-2048}
vm_vcpus=${VM_VCPUS:-2}
vm_disk_gib=${VM_DISK_GIB:-8}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-900}
vm_os_variant=${VM_OS_VARIANT:-freebsd14.2}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-freebsd-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/freebsd-$run_id"
ssh_user=root
remote_ready=0
ip_address=

log() {
	printf '[freebsd-vm] %s\n' "$*"
}

fail() {
	printf '[freebsd-vm] ERROR: %s\n' "$*" >&2
	return 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed"
}

host_arch=$(uname -m)
if [[ "$host_arch" != aarch64 && "$host_arch" != arm64 ]]; then
	fail "the FreeBSD lane currently supports an ARM64 host; found $host_arch"
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

for command in go qemu-img virsh virt-install uuidgen genisoimage python3 ssh scp ssh-keygen wget sha256sum xz; do
	require_command "$command"
done

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

image_filename="FreeBSD-${freebsd_release}-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
image_directory="https://download.freebsd.org/releases/VM-IMAGES/${freebsd_release}/aarch64/Latest"
image_url=${FREEBSD_IMAGE_URL:-$image_directory/$image_filename}
compressed_image=${FREEBSD_COMPRESSED_IMAGE:-$cache_dir/$image_filename}
base_image=${FREEBSD_BASE_IMAGE:-$cache_dir/${image_filename%.xz}}

verify_compressed_image() {
	local image=$1
	local expected=${FREEBSD_IMAGE_SHA256:-}
	if [[ -z "$expected" ]]; then
		local checksums="$work_dir/CHECKSUM.SHA256"
		wget -qO "$checksums" "${image_url%/"$image_filename"}/CHECKSUM.SHA256"
		expected=$(awk -v file="$image_filename" '$0 ~ "^SHA256 \\(.*" file "\\) = " {print $NF; exit}' "$checksums")
	fi
	[[ -n "$expected" ]] || fail "could not obtain the FreeBSD image SHA-256 checksum"
	printf '%s  %s\n' "$expected" "$image" | sha256sum --check --status - || fail "FreeBSD compressed image failed SHA-256 verification"
}

if [[ ! -f "$base_image" ]]; then
	if [[ ! -f "$compressed_image" ]]; then
		if [[ -n "${FREEBSD_COMPRESSED_IMAGE:-}" ]]; then
			fail "FREEBSD_COMPRESSED_IMAGE does not exist: $compressed_image"
		fi
		log "downloading FreeBSD $freebsd_release ARM64 cloud image"
		temporary_compressed="$compressed_image.partial"
		rm -f "$temporary_compressed"
		wget --progress=dot:giga -O "$temporary_compressed" "$image_url"
		verify_compressed_image "$temporary_compressed"
		mv "$temporary_compressed" "$compressed_image"
	elif [[ -n "${FREEBSD_IMAGE_SHA256:-}" ]]; then
		verify_compressed_image "$compressed_image"
	fi
	log "decompressing FreeBSD cloud image"
	temporary_base="$base_image.partial"
	rm -f "$temporary_base"
	xz -dc "$compressed_image" >"$temporary_base"
	qemu-img check -q "$temporary_base"
	mv "$temporary_base" "$base_image"
elif [[ -n "${FREEBSD_BASE_IMAGE_SHA256:-}" ]]; then
	printf '%s  %s\n' "$FREEBSD_BASE_IMAGE_SHA256" "$base_image" | sha256sum --check --status - || fail "FreeBSD base image failed SHA-256 verification"
fi
chmod 0644 "$base_image"
base_image=$(readlink -f "$base_image")

key_path="$work_dir/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$key_path"
public_key=$(cat "$key_path.pub")

user_data="$work_dir/user-data"
seed_directory="$work_dir/config-drive"
seed_image="$work_dir/cloud-init.iso"
overlay_image="$work_dir/root.qcow2"

python3 - "$user_data" "$public_key" <<'PY'
import json
import sys

path, public_key = sys.argv[1:]
with open(path, "w", encoding="utf-8") as output:
	output.write(
		"#cloud-config\n"
		"disable_root: false\n"
		"write_files:\n"
		"  - path: /etc/rc.conf.d/firstboot_freebsd_update\n"
		"    permissions: '0644'\n"
		"    content: |\n"
		"      firstboot_freebsd_update_enable=\"NO\"\n"
		"  - path: /etc/rc.conf.d/firstboot_pkg_upgrade\n"
		"    permissions: '0644'\n"
		"    content: |\n"
		"      firstboot_pkg_upgrade_enable=\"NO\"\n"
		"  - path: /etc/ssh/daemon-itest-authorized_keys\n"
		"    owner: root:wheel\n"
		"    permissions: '0600'\n"
		f"    content: {json.dumps(public_key + chr(10))}\n"
		"  - path: /etc/ssh/sshd_config\n"
		"    permissions: '0600'\n"
		"    content: |\n"
		"      PermitRootLogin prohibit-password\n"
		"      PasswordAuthentication no\n"
		"      UsePAM no\n"
		"      AuthorizedKeysFile /etc/ssh/daemon-itest-authorized_keys\n"
		"      Subsystem sftp internal-sftp\n"
	)
PY

mkdir -p "$seed_directory/openstack/latest"
cp "$user_data" "$seed_directory/openstack/latest/user_data"
chmod 0755 "$seed_directory/openstack/latest/user_data"
python3 - "$seed_directory/openstack/latest/meta_data.json" "$domain_name" <<'PY'
import json
import sys

path, name = sys.argv[1:]
with open(path, "w", encoding="utf-8") as output:
	json.dump({"uuid": name, "hostname": name, "name": name}, output)
	output.write("\n")
PY
genisoimage -quiet -output "$seed_image" -volid config-2 -joliet -rock "$seed_directory"
qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" "$overlay_image" "${vm_disk_gib}G"
chmod 0644 "$seed_image" "$overlay_image"

build_dir="$work_dir/build"
mkdir -p "$build_dir"
log "building FreeBSD/arm64 integration binaries"
(
	cd "$repo_dir"
	CGO_ENABLED=0 GOOS=freebsd GOARCH=arm64 go build -trimpath -o "$build_dir/daemon" .
	CGO_ENABLED=0 GOOS=freebsd GOARCH=arm64 go build -trimpath -o "$build_dir/test-app" ./test_app
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
	--disk "path=$overlay_image,format=qcow2,bus=virtio"
	--disk "path=$seed_image,format=raw,bus=virtio"
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
		current_boot_id=$(ssh_guest sysctl -n kern.boottime 2>/dev/null || true)
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
ssh_guest 'while [ -e /var/run/booting ]; do sleep 1; done'

log "copying integration payload"
scp "${ssh_options[@]}" \
	"$build_dir/daemon" \
	"$build_dir/test-app" \
	"$build_dir/relative-path-test.txt" \
	"$build_dir/guest-test.sh" \
	"$build_dir/interpreted-app-test.sh" \
	"$ssh_user@$ip_address:/tmp/"
ssh_guest install -d -m 0755 /opt/daemon-itest
ssh_guest install -m 0755 /tmp/daemon /opt/daemon-itest/daemon
ssh_guest install -m 0755 /tmp/test-app /opt/daemon-itest/test-app
ssh_guest install -m 0644 /tmp/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest install -m 0755 /tmp/guest-test.sh /opt/daemon-itest/guest-test.sh
ssh_guest install -m 0755 /tmp/interpreted-app-test.sh /opt/daemon-itest/interpreted-app-test.sh

log "running pre-reboot lifecycle checks"
ssh_guest /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest sysctl -n kern.boottime)
log "rebooting guest to verify service persistence"
ssh_guest shutdown -r now >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log "running post-reboot lifecycle checks"
ssh_guest /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts

printf '%s\n' 'PASS' >"$artifact_dir/result.txt"
log "FreeBSD VM integration test passed"
