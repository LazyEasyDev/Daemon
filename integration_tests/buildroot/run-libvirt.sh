#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
profile=${BUILDROOT_PROFILE:-baseline}
image_dir=${BUILDROOT_IMAGE_DIR:-/var/tmp/daemon-buildroot-matrix/$profile/images}
kernel_image=${BUILDROOT_KERNEL:-$image_dir/Image}
rootfs_image=${BUILDROOT_ROOTFS:-$image_dir/rootfs.ext2}
vm_memory_mib=${VM_MEMORY_MIB:-1024}
vm_vcpus=${VM_VCPUS:-2}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-300}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-buildroot-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/buildroot-$run_id"
ip_address=
remote_ready=0

log() { printf '[buildroot-vm] %s\n' "$*"; }
fail() { printf '[buildroot-vm] ERROR: %s\n' "$*" >&2; return 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed"; }

collect_boot_diagnostics() {
	log 'collecting boot diagnostics'
	virsh_command domstate "$domain_uuid" >"$artifact_dir/domain-state.txt" 2>/dev/null || true
	virsh_command domifaddr "$domain_uuid" --source lease >"$artifact_dir/domain-addresses.txt" 2>/dev/null || true
	virsh_command net-dhcp-leases "$vm_network" >"$artifact_dir/network-leases.txt" 2>/dev/null || true
	timeout 12s virsh --connect "$libvirt_uri" console "$domain_uuid" --force >"$artifact_dir/console-timeout.txt" 2>&1 || true
}

host_arch=$(uname -m)
case "$host_arch" in
	aarch64|arm64) ;;
	*) fail "Buildroot runner currently requires an ARM64 host; found $host_arch" ;;
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

for command in go virsh virt-install uuidgen ssh scp ssh-keygen qemu-img debugfs e2fsck; do
	require_command "$command"
done
[[ -f "$kernel_image" ]] || fail "Buildroot kernel image not found: $kernel_image"
[[ -f "$rootfs_image" ]] || fail "Buildroot rootfs image not found: $rootfs_image"

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$work_dir" "$artifact_dir"
key_path="$work_dir/id_ecdsa"
vm_rootfs="$work_dir/rootfs.ext2"
build_dir="$work_dir/build"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "$key_path"

log 'preparing Buildroot rootfs image'
cp --reflink=auto "$rootfs_image" "$vm_rootfs"
printf '%s\n' "$(cat "$key_path.pub")" >"$work_dir/authorized_keys"
cat >"$work_dir/network-retry" <<'EOF'
#!/bin/sh

ip addr show eth0 2>/dev/null | grep -q 'inet ' && exit 0

attempt=1
while [ "$attempt" -le 5 ]; do
	udhcpc -n -q -i eth0 && exit 0
	attempt=$((attempt + 1))
	sleep 2
done

exit 0
EOF
debugfs -w -R 'mkdir /root/.ssh' "$vm_rootfs" >/dev/null 2>&1 || true
debugfs -w -R 'rm /root/.ssh/authorized_keys' "$vm_rootfs" >/dev/null 2>&1 || true
debugfs -w -R "write $work_dir/authorized_keys /root/.ssh/authorized_keys" "$vm_rootfs" >/dev/null
debugfs -w -R 'set_inode_field /root/.ssh/authorized_keys mode 0100600' "$vm_rootfs" >/dev/null
debugfs -w -R 'rm /etc/init.d/S41daemon-network-retry' "$vm_rootfs" >/dev/null 2>&1 || true
debugfs -w -R "write $work_dir/network-retry /etc/init.d/S41daemon-network-retry" "$vm_rootfs" >/dev/null
debugfs -w -R 'set_inode_field /etc/init.d/S41daemon-network-retry mode 0100755' "$vm_rootfs" >/dev/null
if e2fsck -pf "$vm_rootfs" >/dev/null; then
	fsck_status=0
else
	fsck_status=$?
fi
if [[ "$fsck_status" -gt 1 ]]; then
	log "preen fsck returned status $fsck_status; attempting full auto-repair"
	if e2fsck -fy "$vm_rootfs" >/dev/null; then
		repair_status=0
	else
		repair_status=$?
	fi
	if [[ "$repair_status" -gt 1 ]]; then
		fail 'rootfs filesystem repair failed'
	fi
fi
chmod 0644 "$vm_rootfs" "$kernel_image"

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
ssh_guest() { ssh "${ssh_options[@]}" "root@$ip_address" "$@"; }

copy_artifacts() {
	[[ "$remote_ready" == 1 && -n "$ip_address" ]] || return
	mkdir -p "$artifact_dir/guest"
	ssh_guest 'cat /etc/os-release; cat /proc/1/comm; cat /etc/init.d/rcS; ps w' >"$artifact_dir/guest/environment.txt" 2>&1 || true
	ssh_guest "tar -C '/var/tmp/daemon-itest-$service_name' -cf - artifacts" 2>/dev/null |
		tar -C "$artifact_dir/guest" --strip-components=1 -xf - 2>/dev/null || true
}
cleanup() {
	local status=$?
	trap - EXIT
	copy_artifacts
	virsh_command dumpxml "$domain_uuid" >"$artifact_dir/domain.xml" 2>/dev/null || true
	virsh_command domifaddr "$domain_uuid" --source lease >"$artifact_dir/domain-addresses.txt" 2>/dev/null || true
	if [[ "$keep_vm" == 1 ]]; then
		log "keeping VM $domain_name and work directory $work_dir"
	else
		remove_owned_domain "$domain_uuid"
		rm -rf "$work_dir"
	fi
	log "artifacts: $artifact_dir"
	exit "$status"
}
trap cleanup EXIT

wait_for_ssh() {
	local deadline=$((SECONDS + vm_boot_timeout)) next_progress=$SECONDS
	while (( SECONDS < deadline )); do
		ip_address=$(virsh_command domifaddr "$domain_uuid" --source lease 2>/dev/null | awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4; exit}' || true)
		if [[ -n "$ip_address" ]] && ssh_guest true >/dev/null 2>&1; then remote_ready=1; return; fi
		if (( SECONDS >= next_progress )); then log "waiting for Buildroot SSH (${SECONDS}s elapsed)"; next_progress=$((SECONDS + 15)); fi
		sleep 2
	done
	collect_boot_diagnostics
	fail 'timed out waiting for Buildroot SSH'
}
wait_for_new_boot() {
	local previous=$1 deadline=$((SECONDS + vm_boot_timeout)) current
	while (( SECONDS < deadline )); do
		current=$(ssh_guest cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
		[[ -n "$current" && "$current" != "$previous" ]] && return
		sleep 2
	done
	fail 'timed out waiting for Buildroot reboot'
}

virsh_command net-info "$vm_network" >/dev/null || fail "libvirt network '$vm_network' does not exist"
if [[ "$(virsh_command net-info "$vm_network" | awk '/^Active:/ {print $2}')" != yes ]]; then virsh_command net-start "$vm_network" >/dev/null; fi

log "creating Buildroot domain $domain_name"
virt-install --connect "$libvirt_uri" --name "$domain_name" --uuid "$domain_uuid" --memory "$vm_memory_mib" --vcpus "$vm_vcpus" \
	--virt-type "$virt_type" --arch aarch64 --machine virt "${cpu_args[@]}" --import \
	--boot "kernel=$kernel_image,kernel_args=console=ttyAMA0 root=/dev/vda rw" \
	--disk "path=$vm_rootfs,format=raw,bus=virtio" --network "network=$vm_network,model=virtio" \
	--os-variant generic --features acpi=off --graphics none --noautoconsole --wait 0

wait_for_ssh
log "Buildroot guest is reachable at $ip_address"
tar -C "$build_dir" -cf - daemon test-app relative-path-test.txt guest-test.sh interpreted-app-test.sh | ssh_guest 'mkdir -p /opt/daemon-itest && tar -C /opt/daemon-itest -xf -'
ssh_guest chmod 0755 /opt/daemon-itest/daemon /opt/daemon-itest/test-app /opt/daemon-itest/guest-test.sh /opt/daemon-itest/interpreted-app-test.sh
ssh_guest /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id)
log 'rebooting Buildroot guest'
ssh_guest reboot >/dev/null 2>&1 || true
wait_for_new_boot "$boot_id"
ssh_guest /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
printf 'PASS %s\n' "$profile" >"$artifact_dir/result.txt"
log 'Buildroot VM integration test passed'
