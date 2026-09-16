#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
rocky_release=${ROCKY_RELEASE:-9.8}
rocky_build=${ROCKY_BUILD:-20260525.0}
distro_id=${DISTRO_ID:-rocky}
distro_name=${DISTRO_NAME:-Rocky Linux}
distro_version_major=${DISTRO_VERSION_MAJOR:-9}
distro_version_prefix=${DISTRO_VERSION_PREFIX:-$distro_version_major}
artifact_prefix=${DISTRO_ARTIFACT_PREFIX:-rocky}
domain_prefix=${DISTRO_DOMAIN_PREFIX:-daemon-rocky-itest}
service_prefix=${DISTRO_SERVICE_PREFIX:-rocky}
expect_selinux=${DISTRO_EXPECT_SELINUX:-1}
guest_group=${DISTRO_GUEST_GROUP:-wheel}
guest_assertion=${DISTRO_GUEST_ASSERTION:-}
enable_sshd=${DISTRO_ENABLE_SSHD:-0}
disable_firewall=${DISTRO_DISABLE_FIREWALL:-0}
cloud_init_package=${DISTRO_CLOUD_INIT_PACKAGE:-}
cloud_init_diagnostics=${DISTRO_CLOUD_INIT_DIAGNOSTICS:-0}
vm_arch=${VM_ARCH:-}
vm_memory_mib=${VM_MEMORY_MIB:-2048}
vm_vcpus=${VM_VCPUS:-2}
vm_disk_gib=${VM_DISK_GIB:-12}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-900}
vm_os_variant=${VM_OS_VARIANT:-rocky9}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-$domain_prefix-$run_id}
service_name=${SERVICE_NAME:-$service_prefix$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/$artifact_prefix-$run_id"
ssh_user=daemon-itest
remote_ready=0
ip_address=
serial_capture_pid=

log() {
	printf '[selinux-vm] %s\n' "$*"
}

fail() {
	printf '[selinux-vm] ERROR: %s\n' "$*" >&2
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
		rocky_arch=x86_64
		go_arch=amd64
		virt_arch=x86_64
		matching_host_arch=x86_64
		machine_args=()
		boot_args=()
		;;
	arm64|aarch64)
		rocky_arch=aarch64
		go_arch=arm64
		virt_arch=aarch64
		matching_host_arch=aarch64
		machine_args=(--machine virt)
		arm_uefi_code=${ARM_UEFI_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
		arm_uefi_vars=${ARM_UEFI_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}
		[[ -f "$arm_uefi_code" ]] || fail "ARM UEFI code image does not exist: $arm_uefi_code"
		[[ -f "$arm_uefi_vars" ]] || fail "ARM UEFI variables image does not exist: $arm_uefi_vars"
		boot_args=(--boot "loader=$arm_uefi_code,loader.readonly=yes,loader.type=pflash,nvram.template=$arm_uefi_vars")
		;;
	*) fail "VM_ARCH must be amd64 or arm64" ;;
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

for command in go qemu-img virsh virt-install uuidgen cloud-localds ssh scp ssh-keygen wget sha256sum script; do
	require_command "$command"
done

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

image_filename=${DISTRO_IMAGE_FILENAME:-Rocky-9-GenericCloud-Base-${rocky_release}-${rocky_build}.${rocky_arch}.qcow2}
default_image_url="https://download.rockylinux.org/pub/rocky/9/images/${rocky_arch}/${image_filename}"
image_url=${DISTRO_IMAGE_URL:-${ROCKY_IMAGE_URL:-$default_image_url}}
base_image=${DISTRO_BASE_IMAGE:-${ROCKY_BASE_IMAGE:-$cache_dir/${image_url##*/}}}
checksum_url=${DISTRO_IMAGE_CHECKSUM_URL:-${ROCKY_IMAGE_CHECKSUM_URL:-$image_url.CHECKSUM}}

verify_image() {
	local image=$1 expected=${DISTRO_IMAGE_SHA256:-${ROCKY_BASE_IMAGE_SHA256:-}}
	if [[ -z "$expected" ]]; then
		local checksum_file="$work_dir/rocky-image.CHECKSUM"
		wget -q -O "$checksum_file" "$checksum_url"
		expected=$(awk '/^SHA256[[:space:]]*\(/ {print $NF; exit} /^[0-9a-fA-F]{64}[[:space:]]/ {print $1; exit}' "$checksum_file")
	fi
	[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail "could not parse the published $distro_name image SHA-256"
	printf '%s  %s\n' "$expected" "$image" | sha256sum --check --status - || fail "$distro_name base image failed SHA-256 verification"
	printf '%s  %s\n' "$expected" "$image_filename" >"$artifact_dir/base-image.sha256"
}

if [[ ! -f "$base_image" ]]; then
	if [[ -n "${DISTRO_BASE_IMAGE:-${ROCKY_BASE_IMAGE:-}}" ]]; then
		fail "configured base image does not exist: $base_image"
	fi
	log "downloading $distro_name $distro_version_major $rocky_arch cloud image"
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

key_path="$work_dir/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$key_path"
public_key=$(cat "$key_path.pub")

user_data="$work_dir/user-data"
meta_data="$work_dir/meta-data"
network_data="$work_dir/network-config"
seed_image="$work_dir/cloud-init.iso"
overlay_image="$work_dir/root.qcow2"

{
	printf '%s\n' '#cloud-config'
	printf '%s\n' 'users:'
	printf '%s\n' '  - default'
	printf '  - name: %s\n' "$ssh_user"
	printf '%s\n' '    gecos: daemon-util integration test'
	printf '    groups: [%s]\n' "$guest_group"
	printf '%s\n' '    shell: /bin/bash'
	printf '%s\n' '    sudo: ALL=(ALL) NOPASSWD:ALL'
	printf '%s\n' '    lock_passwd: true'
	printf '%s\n' '    ssh_authorized_keys:'
	printf '      - %s\n' "$public_key"
	printf '%s\n' 'ssh_pwauth: false'
	printf '%s\n' 'disable_root: true'
} >"$user_data"

if [[ -n "$cloud_init_package" ]]; then
	cat >>"$user_data" <<EOF
package_update: false
packages:
  - $cloud_init_package
EOF
fi

if [[ "$enable_sshd" == 1 || "$disable_firewall" == 1 || "$cloud_init_diagnostics" == 1 ]]; then
	printf 'runcmd:\n' >>"$user_data"
	if [[ "$enable_sshd" == 1 ]]; then
		printf '  - [systemctl, enable, --now, sshd.service]\n' >>"$user_data"
	fi
	if [[ "$disable_firewall" == 1 ]]; then
		printf '  - [systemctl, disable, --now, firewalld.service]\n' >>"$user_data"
	fi
	if [[ "$cloud_init_diagnostics" == 1 ]]; then
		printf "  - [sh, -c, 'echo DAEMON-ITEST-CLOUD-INIT-DIAGNOSTICS >/dev/ttyAMA0; id daemon-itest >/dev/ttyAMA0 2>&1; command -v sshd >/dev/ttyAMA0 2>&1; systemctl --no-pager --full status sshd.service >/dev/ttyAMA0 2>&1; ss -lntp >/dev/ttyAMA0 2>&1']\\n" >>"$user_data"
	fi
fi

cat >"$meta_data" <<EOF
instance-id: $domain_name
local-hostname: $domain_name
EOF

cat >"$network_data" <<'EOF'
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: true
EOF

cloud-localds --network-config="$network_data" "$seed_image" "$user_data" "$meta_data"
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
cp "$repo_dir/integration_tests/systemd/guest-test.sh" "$build_dir/guest-test.sh"
cat >"$build_dir/image-source" <<EOF
Distribution: $distro_name $distro_version_major
Image: $image_url
Architecture: $rocky_arch
EOF
chmod 0755 "$build_dir/daemon" "$build_dir/test-app" "$build_dir/guest-test.sh"

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
	local attempt
	for (( attempt=1; attempt<=attempts; attempt++ )); do
		if ssh_guest "$@"; then
			return
		fi
		if (( attempt < attempts )); then
			sleep "$delay"
		fi
	done
	fail "guest command failed after $attempts attempts: $*"
}

lease_addresses() {
	local mac
	mac=$(virsh_command domiflist "$domain_uuid" 2>/dev/null | awk '$2 == "network" {print $5; exit}' || true)
	{
		virsh_command domifaddr "$domain_uuid" --source lease 2>/dev/null | awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4}' || true
		if [[ -n "$mac" ]]; then
			virsh_command net-dhcp-leases "$vm_network" --mac "$mac" 2>/dev/null | awk '$5 == "ipv4" {sub(/\/.*/, "", $6); print $6}' || true
		fi
	} | awk 'NF && !seen[$0]++'
}

wait_for_ssh() {
	local timeout_seconds=$1 description=$2
	local deadline=$((SECONDS + timeout_seconds))
	local started=$SECONDS next_progress=$SECONDS candidates candidate
	while (( SECONDS < deadline )); do
		candidates=$(lease_addresses)
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			ip_address=$candidate
			if ssh_guest true >/dev/null 2>&1; then
				remote_ready=1
				log "$description is reachable at $ip_address"
				return
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
	local started=$SECONDS next_progress=$SECONDS candidates candidate current_boot_id
	while (( SECONDS < deadline )); do
		candidates=$(lease_addresses)
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
	if [[ -n "$serial_capture_pid" ]]; then
		kill "$serial_capture_pid" >/dev/null 2>&1 || true
		wait "$serial_capture_pid" >/dev/null 2>&1 || true
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
	--serial pty
	--noautoconsole
	--wait 0
)

log "creating $distro_name $distro_version_major libvirt domain $domain_name"
virt-install "${virt_install_args[@]}"
script -qefc "virsh --connect '$libvirt_uri' console '$domain_uuid' --force" "$artifact_dir/serial.log" </dev/null >/dev/null 2>&1 &
serial_capture_pid=$!
wait_for_ssh "$vm_boot_timeout" "$distro_name guest"

cloud_init_status=0
ssh_guest cloud-init status --wait >/dev/null || cloud_init_status=$?
if (( cloud_init_status != 0 && cloud_init_status != 2 )); then
	fail "cloud-init did not complete successfully (exit $cloud_init_status)"
fi
ssh_guest_retry sudo -n true
ssh_guest_retry ". /etc/os-release; test \"\$ID\" = '$distro_id'; case \"\$VERSION_ID\" in '$distro_version_prefix'*) exit 0 ;; *) exit 1 ;; esac"
if [[ -n "$guest_assertion" ]]; then
	ssh_guest_retry "$guest_assertion"
fi
if [[ "$expect_selinux" == 1 ]]; then
	ssh_guest_retry 'test "$(getenforce)" = Enforcing; test "$(cat /sys/fs/selinux/enforce)" = 1'
	ssh_guest_retry command -v matchpathcon >/dev/null
	ssh_guest_retry command -v restorecon >/dev/null
fi

log "copying $distro_name integration payload"
scp "${ssh_options[@]}" \
	"$build_dir/daemon" \
	"$build_dir/test-app" \
	"$build_dir/relative-path-test.txt" \
	"$build_dir/image-source" \
	"$build_dir/guest-test.sh" \
	"$ssh_user@$ip_address:/tmp/"
ssh_guest_retry sudo install -d -m 0755 /opt/daemon-itest
ssh_guest_retry sudo install -m 0755 /tmp/daemon /opt/daemon-itest/daemon
ssh_guest_retry sudo install -m 0755 /tmp/test-app /opt/daemon-itest/test-app
ssh_guest_retry sudo install -m 0644 /tmp/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest_retry sudo install -m 0644 /tmp/image-source /etc/daemon-itest-image-source
ssh_guest_retry sudo install -m 0755 /tmp/guest-test.sh /opt/daemon-itest/guest-test.sh
if [[ "$expect_selinux" == 1 ]]; then
	ssh_guest_retry sudo restorecon -RF /opt/daemon-itest
fi

log "running $distro_name pre-reboot lifecycle and security checks"
ssh_guest_retry sudo env DAEMON_ITEST_EXPECT_SELINUX="$expect_selinux" /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id)
log "rebooting $distro_name guest to verify service persistence"
ssh_guest sudo systemctl reboot >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log "running $distro_name post-reboot lifecycle, crash recovery, and security checks"
ssh_guest_retry sudo env DAEMON_ITEST_EXPECT_SELINUX="$expect_selinux" /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts

printf 'PASS %s %s\n' "$distro_name" "$distro_version_major" >"$artifact_dir/result.txt"
log "$distro_name $distro_version_major application-level test passed"
