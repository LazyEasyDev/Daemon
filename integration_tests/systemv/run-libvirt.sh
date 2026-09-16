#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

libvirt_uri=${LIBVIRT_URI:-qemu:///system}
devuan_suite=${DEVUAN_SUITE:-excalibur}
vm_arch=${VM_ARCH:-}
vm_memory_mib=${VM_MEMORY_MIB:-1536}
vm_vcpus=${VM_VCPUS:-2}
vm_disk_gib=${VM_DISK_GIB:-8}
vm_boot_timeout=${VM_BOOT_TIMEOUT:-600}
vm_install_timeout=${VM_INSTALL_TIMEOUT:-2400}
vm_os_variant=${VM_OS_VARIANT:-debian13}
vm_network=${VM_NETWORK:-default}
keep_vm=${KEEP_VM:-0}
port=${TEST_APP_PORT:-18080}
cache_dir=${INTEGRATION_CACHE_DIR:-/var/tmp/daemon-util-integration-cache-$(id -u)}
artifact_root=${INTEGRATION_ARTIFACT_DIR:-$repo_dir/integration_tests/artifacts}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
domain_name=${VM_NAME:-daemon-systemv-itest-$run_id}
service_name=${SERVICE_NAME:-itest$(date +%s)$$}
work_dir=${VM_WORK_DIR:-/var/tmp/$domain_name}
artifact_dir="$artifact_root/systemv-$run_id"
ssh_user=daemon-itest
builder_domain=
ip_address=
remote_ready=0

log() {
	printf '[systemv-vm] %s\n' "$*"
}

fail() {
	printf '[systemv-vm] ERROR: %s\n' "$*" >&2
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
		console_name=ttyS0
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
		console_name=ttyAMA0
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

for command in go openssl qemu-img virsh virt-install uuidgen ssh scp ssh-keygen wget sha256sum; do
	require_command "$command"
done

. "$repo_dir/integration_tests/libvirt-domain.sh"
domain_uuid=$(new_domain_uuid "$domain_name")
builder_uuid=$(new_domain_uuid "$domain_name-builder")

mkdir -p "$cache_dir" "$artifact_dir" "$work_dir"
chmod 0755 "$cache_dir" "$work_dir"

if ! virsh_command net-info "$vm_network" >/dev/null 2>&1; then
	fail "libvirt network '$vm_network' does not exist"
fi
if [[ "$(virsh_command net-info "$vm_network" | awk '/^Active:/ {print $2}')" != yes ]]; then
	log "starting libvirt network $vm_network"
	virsh_command net-start "$vm_network" >/dev/null
fi

ssh_options=()
set_ssh_identity() {
	local identity=$1
	ssh_options=(
		-i "$identity"
		-o BatchMode=yes
		-o ConnectTimeout=5
		-o StrictHostKeyChecking=no
		-o UserKnownHostsFile=/dev/null
		-o LogLevel=ERROR
	)
}

ssh_guest() {
	# Arguments are intentionally serialized by SSH for execution in the guest.
	# shellcheck disable=SC2029
	ssh "${ssh_options[@]}" "$ssh_user@$ip_address" "$@"
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
	local deadline=$((SECONDS + timeout_seconds))
	local started=$SECONDS
	local next_progress=$SECONDS
	local candidates candidate
	while (( SECONDS < deadline )); do
		candidates=$(lease_addresses "$name")
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			ip_address=$candidate
			if ssh_guest true >/dev/null 2>&1; then
				log "$description is reachable at $ip_address"
				remote_ready=1
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

wait_for_domain_off() {
	local name=$1
	local deadline=$((SECONDS + vm_boot_timeout))
	local state
	while (( SECONDS < deadline )); do
		state=$(virsh_command domstate "$name" 2>/dev/null || true)
		if [[ -z "$state" || "$state" == "shut off" ]]; then
			return
		fi
		sleep 2
	done
	fail "timed out waiting for $name to shut down"
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
	for uuid in "$domain_uuid" "$builder_uuid"; do
		[[ -n "$uuid" ]] || continue
		virsh_command dumpxml "$uuid" >"$artifact_dir/$uuid.xml" 2>/dev/null || true
		if [[ "$uuid" == "$domain_uuid" && "$keep_vm" == 1 ]]; then
			log "keeping VM $domain_name and work directory $work_dir"
			continue
		fi
		remove_owned_domain "$uuid"
	done
	virsh_command net-dhcp-leases "$vm_network" >"$artifact_dir/network-leases.txt" 2>/dev/null || true
	if [[ "$keep_vm" != 1 ]]; then
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

installer_root=${DEVUAN_INSTALLER_ROOT:-https://pkgmaster.devuan.org/devuan/dists/$devuan_suite/main/installer-$image_arch/current/images}
installer_image=${DEVUAN_INSTALLER_IMAGE:-$cache_dir/devuan-$devuan_suite-$image_arch-mini.iso}
installer_manifest="$work_dir/DEVUAN-SHA256SUMS"
wget -q -O "$installer_manifest" "$installer_root/SHA256SUMS"
installer_sha256=${DEVUAN_INSTALLER_SHA256:-$(awk '$2 == "./netboot/mini.iso" || $2 == "netboot/mini.iso" {print $1; exit}' "$installer_manifest")}
[[ -n "$installer_sha256" ]] || fail "could not find netboot/mini.iso in the Devuan SHA256SUMS"

if [[ ! -f "$installer_image" ]]; then
	log "downloading the official Devuan $devuan_suite $image_arch netboot installer"
	temporary_installer="$installer_image.partial"
	rm -f "$temporary_installer"
	wget --progress=dot:giga -O "$temporary_installer" "$installer_root/netboot/mini.iso"
	printf '%s  %s\n' "$installer_sha256" "$temporary_installer" | sha256sum --check --status - || fail "Devuan installer failed SHA-256 verification"
	mv "$temporary_installer" "$installer_image"
else
	printf '%s  %s\n' "$installer_sha256" "$installer_image" | sha256sum --check --status - || fail "cached Devuan installer failed SHA-256 verification"
fi
chmod 0644 "$installer_image"
installer_image=$(readlink -f "$installer_image")

if [[ -n "${BASE_IMAGE:-}" ]]; then
	base_image=$BASE_IMAGE
	bootstrap_key=${BASE_SSH_KEY:-}
	[[ -f "$base_image" ]] || fail "BASE_IMAGE does not exist: $base_image"
	[[ -f "$bootstrap_key" ]] || fail "BASE_SSH_KEY is required with a custom Devuan BASE_IMAGE"
else
	base_image="$cache_dir/devuan-$devuan_suite-systemv-$image_arch.qcow2"
	bootstrap_key="$base_image.id_ed25519"
fi

if [[ ! -f "$base_image" ]]; then
	[[ -z "${BASE_IMAGE:-}" ]] || fail "custom BASE_IMAGE does not exist: $base_image"
	log "creating a reusable native Devuan SysV base image"
	rm -f "$bootstrap_key"
	ssh-keygen -q -t ed25519 -N '' -f "$bootstrap_key"
	chmod 0600 "$bootstrap_key"
	bootstrap_public_key=$(cat "$bootstrap_key.pub")
	password_hash=$(openssl passwd -6 "$(openssl rand -hex 24)")
	preseed_file="$work_dir/preseed.cfg"
	cat >"$preseed_file" <<EOF
### Locale, keyboard, and network
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string devuan-systemv
d-i netcfg/get_domain string local

### Devuan package mirror
d-i mirror/country string manual
d-i mirror/http/hostname string deb.devuan.org
d-i mirror/http/directory string /merged
d-i mirror/http/proxy string

### Account and clock
d-i passwd/root-login boolean false
d-i passwd/user-fullname string daemon-util integration test
d-i passwd/username string $ssh_user
d-i passwd/user-password-crypted password $password_hash
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean true

### Automatic whole-disk installation
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-partitioning/choose_label string gpt
d-i partman-partitioning/default_label string gpt
d-i partman-efi/non_efi_system boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

### Minimal server with native SysV init
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string openssh-server sudo python3 ca-certificates
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false

### Bootloader and unattended finish
d-i grub-installer/only_debian boolean true
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note

### Key-only SSH and passwordless sudo for the disposable test account
d-i preseed/late_command string \
    in-target mkdir -p /home/$ssh_user/.ssh /etc/ssh/sshd_config.d /etc/sudoers.d; \
    echo '$bootstrap_public_key' > /target/home/$ssh_user/.ssh/authorized_keys; \
    in-target chown -R $ssh_user:$ssh_user /home/$ssh_user/.ssh; \
    in-target chmod 0700 /home/$ssh_user/.ssh; \
    in-target chmod 0600 /home/$ssh_user/.ssh/authorized_keys; \
    echo '$ssh_user ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/daemon-itest; \
    chmod 0440 /target/etc/sudoers.d/daemon-itest; \
    echo 'PasswordAuthentication no' > /target/etc/ssh/sshd_config.d/daemon-itest.conf
EOF

	builder_image="$work_dir/devuan-systemv-base.qcow2"
	qemu-img create -q -f qcow2 "$builder_image" "${vm_disk_gib}G"
	chmod 0644 "$builder_image"
	builder_domain="$domain_name-builder"
	set_ssh_identity "$bootstrap_key"
	remote_ready=0
	log "installing native Devuan; the first run can take several minutes under TCG"
	install_wait_minutes=$(((vm_install_timeout + 59) / 60))
	if ! virt-install \
		--connect "$libvirt_uri" \
		--name "$builder_domain" \
		--uuid "$builder_uuid" \
		--memory "$vm_memory_mib" \
		--vcpus "$vm_vcpus" \
		--virt-type "$virt_type" \
		--arch "$virt_arch" \
		"${machine_args[@]}" \
		"${boot_args[@]}" \
		"${cpu_args[@]}" \
		--disk "path=$builder_image,format=qcow2,bus=virtio" \
		--network "network=$vm_network,model=virtio" \
		--os-variant "$vm_os_variant" \
		--location "$installer_image,kernel=/linux,initrd=/initrd.gz" \
		--initrd-inject "$preseed_file" \
		--extra-args "auto=true priority=critical preseed/file=/preseed.cfg console=$console_name,115200n8" \
		--graphics none \
		--noautoconsole \
		--wait "$install_wait_minutes" \
		>"$artifact_dir/devuan-installer-virt-install.log" 2>&1; then
		tail -n 80 "$artifact_dir/devuan-installer-virt-install.log" >&2 || true
		fail "virt-install failed while building the native Devuan base"
	fi
	log "installer finished; finalizing cached base image"
	virsh_command shutdown "$builder_uuid" >/dev/null 2>&1 || true
	wait_for_domain_off "$builder_uuid"
	virsh_command undefine "$builder_uuid" --nvram >/dev/null 2>&1 || virsh_command undefine "$builder_uuid" >/dev/null 2>&1
	builder_domain=
	builder_uuid=
	qemu-img check "$builder_image" >"$artifact_dir/base-image-check.txt"
	mv "$builder_image" "$base_image"
	chmod 0644 "$base_image"
	log "cached native Devuan base image at $base_image"
fi

if [[ -n "${BASE_IMAGE_SHA256:-}" ]]; then
	printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$base_image" | sha256sum --check --status - || fail "base image SHA-256 does not match BASE_IMAGE_SHA256"
fi

[[ -f "$bootstrap_key" ]] || fail "cached Devuan base SSH key is missing: $bootstrap_key"
chmod 0600 "$bootstrap_key"
base_image=$(readlink -f "$base_image")

run_key="$work_dir/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$run_key"
run_public_key=$(cat "$run_key.pub")

overlay_image="$work_dir/root.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" "$overlay_image" "${vm_disk_gib}G"
chmod 0644 "$overlay_image"

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

set_ssh_identity "$bootstrap_key"
remote_ready=0
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
	--network "network=$vm_network,model=virtio"
	--os-variant "$vm_os_variant"
	--graphics none
	--noautoconsole
	--wait 0
)

log "creating native Devuan System V domain $domain_name"
virt-install "${virt_install_args[@]}"
wait_for_ssh "$domain_uuid" "$vm_boot_timeout" "Devuan System V guest"

ssh_guest "umask 077; mkdir -p ~/.ssh; printf '%s\\n' '$run_public_key' > ~/.ssh/authorized_keys"
set_ssh_identity "$run_key"
ssh_guest true >/dev/null

{
	printf '%s\n' '--- operating system ---'
	ssh_guest cat /etc/os-release
	printf '%s\n' '--- PID 1 ---'
	ssh_guest ps -p 1 -o pid=,comm=,args=
	printf '%s\n' '--- runlevel ---'
	ssh_guest runlevel
	printf '%s\n' '--- init package ---'
	ssh_guest "dpkg-query -W -f='\${Package} \${Version}\\n' sysvinit-core sysv-rc initscripts"
} >"$artifact_dir/systemv-environment.txt"

[[ "$(ssh_guest cat /proc/1/comm)" == init ]] || fail "Devuan guest is not running SysV init as PID 1"
ssh_guest grep -qi devuan /etc/os-release || fail "guest does not identify as Devuan"
if ssh_guest test -d /run/systemd/system; then
	fail "systemd is active in the native Devuan guest"
fi

log "copying integration payload"
scp "${ssh_options[@]}" \
	"$build_dir/daemon" \
	"$build_dir/test-app" \
	"$build_dir/relative-path-test.txt" \
	"$build_dir/guest-test.sh" \
	"$build_dir/interpreted-app-test.sh" \
	"$ssh_user@$ip_address:/tmp/"
ssh_guest sudo install -d -m 0755 /opt/daemon-itest
ssh_guest sudo install -m 0755 /tmp/daemon /opt/daemon-itest/daemon
ssh_guest sudo install -m 0755 /tmp/test-app /opt/daemon-itest/test-app
ssh_guest sudo install -m 0644 /tmp/relative-path-test.txt /opt/daemon-itest/relative-path-test.txt
ssh_guest sudo install -m 0755 /tmp/guest-test.sh /opt/daemon-itest/guest-test.sh
ssh_guest sudo install -m 0755 /tmp/interpreted-app-test.sh /opt/daemon-itest/interpreted-app-test.sh

log "running pre-reboot lifecycle checks"
ssh_guest sudo /opt/daemon-itest/guest-test.sh pre-reboot "$service_name" "$port"
previous_boot_id=$(ssh_guest cat /proc/sys/kernel/random/boot_id)
log "rebooting Devuan guest to verify service persistence"
ssh_guest sudo shutdown -r now >/dev/null 2>&1 || true
wait_for_new_boot "$previous_boot_id"
remote_ready=1

log "running post-reboot lifecycle checks"
ssh_guest sudo /opt/daemon-itest/guest-test.sh post-reboot "$service_name" "$port"
copy_guest_artifacts

log "System V VM integration test passed"
