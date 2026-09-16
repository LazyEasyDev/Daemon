#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
vm_memory_mib=${VM_MEMORY_MIB:-1536}
vm_vcpus=${VM_VCPUS:-2}
vm_disk_gib=${VM_DISK_GIB:-8}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-900}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
boot_mode=${UPSTART_BOOT_MODE:-direct}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-upstart-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/upstart-$run_id"
ssh_user=ubuntu
remote_ready=0
ip_address=

image_filename=${UPSTART_IMAGE_FILENAME:-ubuntu-14.04-server-cloudimg-arm64-uefi1.img}
image_url=${UPSTART_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/trusty/release/$image_filename}
base_image=${UPSTART_BASE_IMAGE:-$cache_dir/$image_filename}
kernel_version=${UPSTART_KERNEL_VERSION:-4.4.0-148-generic}
kernel_image=${UPSTART_KERNEL_IMAGE:-$cache_dir/$image_filename.vmlinuz-$kernel_version}
initrd_image=${UPSTART_INITRD_IMAGE:-$cache_dir/$image_filename.initrd.img-$kernel_version}

log() { printf '[upstart-vm] %s\n' "$*"; }
fail() { printf '[upstart-vm] ERROR: %s\n' "$*" >&2; return 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed"; }

host_arch=$(uname -m)
case "$host_arch" in
	aarch64|arm64) ;;
	*) fail "the Upstart lane currently requires an ARM64 host; found $host_arch" ;;
esac

virt_type=${VM_VIRT_TYPE:-}
if [[ -z "$virt_type" ]]; then
	if [[ -r /dev/kvm ]]; then virt_type=kvm; else virt_type=qemu; fi
fi
if [[ "$virt_type" == kvm ]]; then
	cpu_args=(--cpu host-passthrough)
else
	cpu_args=(--cpu cortex-a72)
	log 'KVM is unavailable or disabled; using QEMU software emulation with Cortex-A72 compatibility'
fi

for command in go qemu-img virsh virt-install uuidgen cloud-localds ssh scp ssh-keygen wget sha256sum; do
	require_command "$command"
done

case "$boot_mode" in
	direct)
		for command in fdisk dd debugfs; do require_command "$command"; done
		;;
	uefi)
		arm_uefi_code=${ARM_UEFI_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
		arm_uefi_vars=${ARM_UEFI_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}
		[[ -f "$arm_uefi_code" ]] || fail "ARM UEFI code image does not exist: $arm_uefi_code"
		[[ -f "$arm_uefi_vars" ]] || fail "ARM UEFI variables image does not exist: $arm_uefi_vars"
		;;
	*) fail "unsupported UPSTART_BOOT_MODE '$boot_mode' (expected direct or uefi)" ;;
esac

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

verify_image() {
	local image=$1 expected=${UPSTART_BASE_IMAGE_SHA256:-}
	if [[ -z "$expected" ]]; then
		local sums="$work_dir/SHA256SUMS"
		wget -q -O "$sums" "${image_url%/$image_filename}/SHA256SUMS"
		expected=$(awk -v file="$image_filename" '$2 == "*" file || $2 == file {print $1; exit}' "$sums")
	fi
	[[ -n "$expected" ]] || fail "could not obtain the SHA-256 for $image_filename"
	printf '%s  %s\n' "$expected" "$image" | sha256sum --check --status - || fail 'Trusty base image failed SHA-256 verification'
}

if [[ ! -f "$base_image" ]]; then
	if [[ -n "${UPSTART_BASE_IMAGE:-}" ]]; then
		fail "UPSTART_BASE_IMAGE does not exist: $base_image"
	fi
	log 'downloading official Ubuntu 14.04.5 ARM64 UEFI cloud image'
	temporary_image="$base_image.partial"
	rm -f "$temporary_image"
	wget --progress=dot:giga -O "$temporary_image" "$image_url"
	verify_image "$temporary_image"
	mv "$temporary_image" "$base_image"
else
	verify_image "$base_image"
fi
chmod 0644 "$base_image"
base_image=$(readlink -f "$base_image")

extract_boot_files() {
	local raw_disk="$work_dir/trusty.raw" rootfs="$work_dir/trusty-root.ext4"
	local geometry start sectors

	[[ -f "$kernel_image" && -f "$initrd_image" ]] && return
	log "extracting Trusty kernel $kernel_version and initrd for direct boot"
	qemu-img convert -q -O raw -S 4k "$base_image" "$raw_disk"
	geometry=$(fdisk -l "$raw_disk" 2>/dev/null | awk '$0 ~ / Linux$/ {print $2, $4; exit}')
	read -r start sectors <<<"$geometry"
	[[ "$start" =~ ^[0-9]+$ && "$sectors" =~ ^[0-9]+$ ]] || fail 'could not locate the Trusty Linux root partition'
	dd if="$raw_disk" of="$rootfs" bs=512 skip="$start" count="$sectors" conv=sparse status=none
	debugfs -R "dump -p /boot/vmlinuz-$kernel_version $kernel_image" "$rootfs" >/dev/null 2>&1
	debugfs -R "dump -p /boot/initrd.img-$kernel_version $initrd_image" "$rootfs" >/dev/null 2>&1
	[[ -s "$kernel_image" ]] || fail "failed to extract Trusty kernel $kernel_version"
	[[ -s "$initrd_image" ]] || fail "failed to extract Trusty initrd $kernel_version"
	chmod 0644 "$kernel_image" "$initrd_image"
	rm -f "$raw_disk" "$rootfs"
}

if [[ "$boot_mode" == direct ]]; then
	extract_boot_files
fi

key_path="$work_dir/id_ecdsa"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "$key_path"
public_key=$(cat "$key_path.pub")
user_data="$work_dir/user-data"
meta_data="$work_dir/meta-data"
seed_image="$work_dir/cloud-init.img"
overlay_image="$work_dir/root.qcow2"

cat >"$user_data" <<EOF
#cloud-config
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
log 'building Linux/arm64 integration binaries'
(
	cd "$repo_dir"
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$build_dir/daemon" .
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$build_dir/test-app" ./test_app
)
printf '%s\n' 'daemon-util relative path test passed' >"$build_dir/relative-path-test.txt"
cp "$script_dir/guest-test.sh" "$build_dir/guest-test.sh"
cp "$repo_dir/integration_tests/interpreted-app-test.sh" "$build_dir/interpreted-app-test.sh"
chmod 0755 "$build_dir/daemon" "$build_dir/test-app" "$build_dir/guest-test.sh" "$build_dir/interpreted-app-test.sh"

ssh_options=(-i "$key_path" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_guest() { ssh "${ssh_options[@]}" "$ssh_user@$ip_address" "$@"; }

copy_guest_artifacts() {
	[[ "$remote_ready" == 1 && -n "$ip_address" ]] || return
	mkdir -p "$artifact_dir/guest"
	scp "${ssh_options[@]}" -r "$ssh_user@$ip_address:/var/tmp/daemon-itest-$service_name/artifacts/." "$artifact_dir/guest/" >/dev/null 2>&1 || true
}

collect_boot_diagnostics() {
	virsh_command domstate "$domain_uuid" >"$artifact_dir/domain-state.txt" 2>/dev/null || true
	virsh_command domifaddr "$domain_uuid" --source lease >"$artifact_dir/domain-addresses.txt" 2>/dev/null || true
	virsh_command net-dhcp-leases "$vm_network" >"$artifact_dir/network-leases.txt" 2>/dev/null || true
	timeout 15s virsh --connect "$libvirt_uri" console "$domain_uuid" --force >"$artifact_dir/console-timeout.txt" 2>&1 || true
}

cleanup() {
	local status_code=$?
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
	if (( status_code == 0 )); then log "artifacts: $artifact_dir"; else log "test failed; artifacts: $artifact_dir" >&2; fi
	exit "$status_code"
}
trap cleanup EXIT

virsh_command net-info "$vm_network" >/dev/null 2>&1 || fail "libvirt network '$vm_network' does not exist"
if [[ "$(virsh_command net-info "$vm_network" | awk '/^Active:/ {print $2}')" != yes ]]; then
	virsh_command net-start "$vm_network" >/dev/null
fi

log "creating Upstart domain $domain_name"
if [[ "$boot_mode" == direct ]]; then
	boot_args=(--boot "kernel=$kernel_image,initrd=$initrd_image,kernel_args=console=ttyAMA0 root=LABEL=cloudimg-rootfs rw")
else
	boot_args=(--boot "loader=$arm_uefi_code,loader.readonly=yes,loader.type=pflash,nvram.template=$arm_uefi_vars")
fi
virt-install --connect "$libvirt_uri" --name "$domain_name" --uuid "$domain_uuid" --memory "$vm_memory_mib" --vcpus "$vm_vcpus" \
	--virt-type "$virt_type" --arch aarch64 --machine virt "${cpu_args[@]}" --import \
	"${boot_args[@]}" \
	--disk "path=$overlay_image,format=qcow2,bus=virtio" --disk "path=$seed_image,device=cdrom" \
	--network "network=$vm_network,model=virtio" --os-variant generic --features acpi=off \
	--graphics none --noautoconsole --wait 0

wait_for_ip() {
	local deadline=$((SECONDS + vm_boot_timeout)) next_progress=$SECONDS
	while (( SECONDS < deadline )); do
		ip_address=$(virsh_command domifaddr "$domain_uuid" --source lease 2>/dev/null | awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4; exit}' || true)
		[[ -n "$ip_address" ]] && return
		if (( SECONDS >= next_progress )); then log "waiting for Trusty DHCP address (${SECONDS}s elapsed)"; next_progress=$((SECONDS + 15)); fi
		sleep 2
	done
	collect_boot_diagnostics
	fail 'timed out waiting for Trusty DHCP address'
}

wait_for_ssh() {
	local deadline=$((SECONDS + vm_boot_timeout)) next_progress=$SECONDS
	while (( SECONDS < deadline )); do
		if ssh_guest true >/dev/null 2>&1; then remote_ready=1; return; fi
		if (( SECONDS >= next_progress )); then log "waiting for Trusty SSH at $ip_address (${SECONDS}s elapsed)"; next_progress=$((SECONDS + 15)); fi
		sleep 2
	done
	collect_boot_diagnostics
	fail "timed out waiting for Trusty SSH at $ip_address"
}

wait_for_cloud_init() {
	local deadline=$((SECONDS + vm_boot_timeout))
	while (( SECONDS < deadline )); do
		ssh_guest test -f /var/lib/cloud/instance/boot-finished >/dev/null 2>&1 && return
		sleep 2
	done
	fail 'timed out waiting for Trusty cloud-init completion'
}

wait_for_new_boot() {
	local previous=$1 deadline=$((SECONDS + vm_boot_timeout)) current
	while (( SECONDS < deadline )); do
		current=$(ssh_guest cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
		[[ -n "$current" && "$current" != "$previous" ]] && return
		sleep 2
	done
	fail 'timed out waiting for Trusty reboot'
}

wait_for_ip
log "Trusty guest address: $ip_address"
wait_for_ssh
wait_for_cloud_init
ssh_guest sudo -n true
[[ "$(ssh_guest cat /proc/1/comm)" == init ]] || fail 'init is not PID 1 in the Trusty guest'
ssh_guest initctl version 2>&1 | grep -qi upstart || fail 'guest PID 1 is not Upstart'

log 'copying integration payload'
scp "${ssh_options[@]}" "$build_dir/daemon" "$build_dir/test-app" "$build_dir/relative-path-test.txt" "$build_dir/guest-test.sh" "$build_dir/interpreted-app-test.sh" "$ssh_user@$ip_address:/tmp/"
ssh_guest sudo install -d -m 0755 /opt/daemon-itest
ssh_guest sudo install -m 0755 /tmp/daemon /opt/daemon-itest/daemon
ssh_guest sudo install -m 0755 /tmp/test-app /opt/daemon-itest/test-app
ssh_guest sudo install -m 0644 /tmp/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest sudo install -m 0755 /tmp/guest-test.sh /opt/daemon-itest/guest-test.sh
ssh_guest sudo install -m 0755 /tmp/interpreted-app-test.sh /opt/daemon-itest/interpreted-app-test.sh

log 'running pre-reboot Upstart application checks'
ssh_guest sudo /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id)
log 'rebooting Trusty guest to verify Upstart auto-start'
ssh_guest sudo reboot >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log 'running post-reboot Upstart application checks'
ssh_guest sudo /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts
log 'Upstart VM integration test passed'
