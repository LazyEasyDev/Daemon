# Application-level integration tests

These tests boot disposable virtual machines and exercise daemon-util through a
real operating-system service manager. They complement `go test ./...`; they do
not replace the package-level tests.

Every verified backend lane includes an executable hot-replacement scenario.
Unix guests atomically rename a replacement over the running executable, verify
that the original PID and service status remain stable, stop the old image, and
confirm the next start uses a new PID. Windows Server verifies the corresponding
NTFS/SCM behavior with distinct binary hashes and a replacement-backed restart.

The verified Unix lanes also verify a native executable installed through a
symlink, a shell script passed as an argument to a native shell interpreter,
and rejection of a script passed directly as the executable. They run the same
argument-hosted test through Python when Python is installed in the guest. The
Windows lane performs the equivalent symlinked-PE, PowerShell-hosted,
direct-script-rejection, and optional-Python checks.

The shared Unix test preserves an explicit `sh` applet when `/bin/sh` resolves
to BusyBox or Toybox, and uses the running Python process's native executable on
Linux instead of an argv0-dependent Python dispatcher. This matches
daemon-util's documented behavior of resolving executable symlinks before
registration.

Cleanup assertions follow the selected backend rather than kernel capability.
In particular, a System V or Buildroot guest may expose cgroups, but those
backends are tested only for validated-main-process termination because
daemon-util does not create service cgroups for them.

### Cleanup assertions by backend

| Backend | What the integration tests assert |
| --- | --- |
| systemd | The main process and a spawned child are terminated as members of the unit control group |
| OpenRC | The generated service sets `stopgroup=true` and `rc_cgroup_cleanup=yes`; tests require supervised-main-process cleanup, not arbitrary descendant cleanup |
| runit | The main process and a spawned child are stopped through the dedicated process group |
| Windows SCM | The application and spawned child are terminated through the per-service Job Object |
| System V and Buildroot | Only the PID/start-time-validated main process is guaranteed to stop |
| Upstart, OpenWrt, and FreeBSD | Native manager or supervisor stop behavior is tested; arbitrary descendant cleanup is not claimed |

daemon-util does not infer service containment from `CONFIG_CGROUPS`, a
`cgroup2` filesystem, or `/sys/fs/cgroup`. systemd owns its unit cgroups, while
OpenRC may provide cgroup cleanup when its own cgroup support is active. The raw
System V and Buildroot backends intentionally remain main-process-only even on
a kernel with cgroup support. The public guarantee is summarized in the
[process-cleanup table](../readme.md#process-cleanup).

## Current coverage

The systemd lane verifies:

- backend detection with systemd running as PID 1;
- installation, native unit rendering, and boot enablement;
- application argument and working-directory preservation;
- `start`, `status`, `list`, `list -l`, `restart`, `stop`, and `remove`;
- service startup after a guest reboot;
- automatic restart after a nonzero application exit or direct `SIGKILL`;
- atomic executable replacement with unchanged running PID and replacement-backed restart;
- graceful shutdown within the configured timeout;
- forced termination after the configured timeout;
- systemd control-group cleanup of a child process; and
- removal of the unit, enablement links, metadata, and application processes.

The Raspberry Pi OS lane runs that systemd lifecycle against both the official
32-bit ARMHF and 64-bit ARM64 Raspberry Pi OS Lite images. It additionally
asserts the guest bitness, mounts the image's real Pi firmware partition, and
verifies service recovery after a direct `SIGKILL`.

The Armbian lane runs the systemd lifecycle against the official minimal ARM64
Orange Pi 5 image. It boots the image's real root filesystem under QEMU `virt`,
verifies its published SHA-256, preserves Armbian userspace and configuration,
and covers reboot persistence, recovery, atomic replacement, timeout escalation,
and cgroup cleanup without requiring physical RK3588 hardware.

The DietPi lane applies the same two-boot test to the official Orange Pi 5
DietPi ARMv8 image. Python coverage is skipped when Python is absent, and the
guest test requires no online package installation, so it also runs on minimal
vendor images.

The Radxa and Orange Pi vendor lanes run the official ROCK 5B Debian CLI and
Orange Pi 5 Ubuntu Server userspaces, respectively. Their board-only kernels do
not represent a QEMU `virt` machine, so the lanes use the checksum-verified
Yocto `qemuarm64` kernel while preserving and testing each vendor root
filesystem. This validates userspace, systemd, daemon lifecycle, persistence,
and atomic executable replacement; it does not validate RK3588 hardware,
firmware, boot loaders, device trees, or peripherals.

The Arch Linux ARM lane builds a writable filesystem from the official,
GPG-verified generic AArch64 rootfs and boots its native kernel and initramfs.
That generic rootfs is the Arch userspace supplied for PINE64 and Rockchip board
installations. The Manjaro ARM lane similarly tests the official bootable
minimal generic ARM64 image using a checksum-verified generic QEMU kernel.

The FriendlyCore lane runs the systemd lifecycle against the official NanoPi
R5S ARM64 FriendlyCore image. Like the Radxa, Orange Pi, and Manjaro lanes, it
preserves the vendor root filesystem while using a checksum-verified generic
QEMU kernel; board firmware and peripherals remain outside this test scope.

The Rocky Linux lane runs the systemd lifecycle on an official Rocky Linux 9
GenericCloud image with SELinux Enforcing. It verifies the real risky-path
warning and noninteractive refusal, safe installation from `/opt` without a
warning bypass, persistent file labels, runtime process context, and absence of
service-specific AVC denials.

The Fedora lane runs the same SELinux-enforcing lifecycle against Fedora Cloud
Base ARM64. The openSUSE Tumbleweed lane uses its official minimal ARM64 cloud
image, verifies AppArmor kernel availability, and runs the complete systemd
lifecycle. The pinned image uses XFS; the assertion also permits Btrfs.

The OpenRC lane performs the same core application-level lifecycle checks and
also verifies its generated `openrc-run` script, `supervise-daemon` configuration,
default-runlevel registration, respawn behavior, native stop escalation, and
atomic executable replacement. It requests native `stopgroup` and optional
cgroup cleanup, but does not promise cleanup of descendants that outlive or
escape the supervised main process.

The Gentoo lane runs those OpenRC checks against an official ARM64 Gentoo
OpenRC stage3. It uses serial-only direct QEMU boot, verifies the published
stage3 and boot-kernel checksums, and performs the complete lifecycle without
cloud-init, SSH, or online package installation.

The Upstart lane boots Ubuntu 14.04 LTS with Upstart as PID 1 and verifies the
generated job definition, boot auto-start, explicit restart, graceful stop,
configured-failure respawn, hard-crash respawn, atomic executable replacement,
and complete removal.

The Windows lane installs Windows Server 2019 or 2025 Evaluation Server Core and
verifies SCM registration, automatic startup, recovery actions, external HTTP
behavior, configured-failure and hard-crash recovery, reboot persistence,
running-image replacement with hash verification, graceful and forced stop
behavior, Job Object descendant cleanup, metadata cleanup, and service removal.
It additionally verifies a symlinked PE application, a PowerShell script passed
to the native PowerShell executable, direct PowerShell-script rejection, and a
Python-hosted application when Python is present.

The FreeBSD lane verifies the rc.d backend, `/usr/sbin/daemon` supervision,
supervisor and application PID files, boot enablement, restart behavior,
atomic executable replacement, native-executable symlink resolution,
interpreter-hosted scripts, direct-script rejection, graceful and forced
shutdown, and removal.

The OpenWrt lane verifies procd backend detection, generated `rc.common`
scripts, boot enablement, respawn behavior, atomic executable replacement, stop
timeout handling, and removal.

The OpenWrt MIPS lane runs that lifecycle on official Malta big-endian and
little-endian images with matching static Go binaries and soft-float settings.
The ImmortalWrt lane runs it on the official ARM64 EFI image and preserves test
state across two separately controlled QEMU boots.

The FriendlyWrt lane runs that procd lifecycle against the official NanoPi
R5S/R5C FriendlyWrt 25.12 ARM64 root filesystem. It verifies the vendor archive
checksum and Rockchip target metadata, converts the vendor's Android-sparse ext4
container, and uses a dedicated state disk to verify persistence across two
QEMU boots.

The Yocto lane boots the official Poky 5.0.19 Scarthgap LTS `qemuarm64`
`core-image-minimal` image with SysVinit. It verifies runlevel registration,
reboot persistence, explicit restart, configured-failure and direct `SIGKILL`
watchdog recovery, graceful and forced validated-main-process cleanup, and
removal. System V does not promise cleanup of arbitrary descendants.

The Buildroot lane builds baseline, debug, and release variants from source and
boots them with a dedicated libvirt guest runner. It verifies watchdog recovery,
reboot persistence, atomic executable replacement, direct and CLI restart,
status, stop, removal, native-executable symlink resolution,
interpreter-hosted shell execution, optional Python, and direct-script
rejection. Its cleanup contract covers the validated main process, not
arbitrary descendants.

The runit lane boots the official Void Linux ARM64 root filesystem with native
runit as PID 1. It verifies backend precedence, service supervision, reboot
persistence, explicit restart, configured-failure and hard-crash recovery,
atomic executable replacement, graceful and forced process-group cleanup, and
removal.

The runit lane also holds a real `down ... want up` respawn interval open while
the CLI queries status, then resumes the native supervisor when the CLI sends
`force-stop`. It asserts that no further application startup occurs before
reboot, that no persistent `down` marker was created, and that the stopped
service still autostarts after reboot. The shared systemd lane separately
exercises a 240-character service name through install, metadata readback,
start, status/list, stop, and removal, and rejects 241 characters before any
service files are written. Real VM testing exposed journald's native
255-byte-unit-name protocol boundary; the general service-name limit and the
atomic-writer unit-test boundary remain 241 characters.

The tests use cached upstream images, archives, generated Buildroot filesystems,
and disposable overlays or copies. Cached source artifacts are not modified by
normal test runs.

## Runner index

Run commands from the repository root. The generic System V constructors are
retained for diagnostics but are not part of the verified matrix; the Yocto
lane is the canonical System V regression.

To run the ownership safety check and one app-level lane per relevant backend,
including the Rocky/Fedora/openSUSE security variants and all three Buildroot
profiles, use the sequential regression matrix. Cached images and prebuilt
Buildroot outputs are recommended. macOS and Windows are not included:

```sh
bash integration_tests/run-regression-matrix.sh
# Or select lanes:
bash integration_tests/run-regression-matrix.sh ownership systemd opensuse runit
```

Each lane keeps its log and artifacts; the matrix writes a `results.tsv` report,
continues after a failed lane, and returns nonzero if any lane failed.

| Lane | Service backend | Command | Host requirement |
| --- | --- | --- | --- |
| Ubuntu | systemd | `./integration_tests/systemd/run-libvirt.sh` | x86-64 or ARM64 |
| Rocky Linux | systemd | `./integration_tests/rocky/run-libvirt.sh` | x86-64 or ARM64 |
| Fedora | systemd | `./integration_tests/fedora/run-libvirt.sh` | QEMU capable of ARM64 |
| openSUSE | systemd | `./integration_tests/opensuse/run-libvirt.sh` | QEMU capable of ARM64 |
| Raspberry Pi OS | systemd | `./integration_tests/raspios/run-qemu.sh` | QEMU with ARM and ARM64 system emulation |
| Armbian | systemd | `./integration_tests/armbian/run-qemu.sh` | QEMU capable of ARM64 |
| DietPi | systemd | `./integration_tests/dietpi/run-qemu.sh` | QEMU capable of ARM64 |
| Radxa OS | systemd | `./integration_tests/radxa/run-qemu.sh` | QEMU capable of ARM64 |
| Orange Pi Ubuntu | systemd | `./integration_tests/orangepi/run-qemu.sh` | QEMU capable of ARM64 |
| FriendlyCore | systemd | `./integration_tests/friendlycore/run-qemu.sh` | QEMU capable of ARM64 |
| Arch Linux ARM | systemd | `./integration_tests/archlinux/run-qemu.sh` | QEMU capable of ARM64 |
| Manjaro ARM | systemd | `./integration_tests/manjaro/run-qemu.sh` | QEMU capable of ARM64 |
| Alpine | OpenRC | `./integration_tests/openrc/run-libvirt.sh` | ARM64 host |
| Gentoo | OpenRC | `./integration_tests/gentoo/run-qemu.sh` | QEMU capable of ARM64 |
| Void Linux | runit | `./integration_tests/runit/run-qemu.sh` | QEMU capable of ARM64 |
| Ubuntu 14.04 | Upstart | `./integration_tests/upstart/run-libvirt.sh` | ARM64 host |
| Yocto/Poky | System V | `./integration_tests/yocto/run-qemu.sh` | QEMU capable of ARM64 |
| Buildroot | Buildroot init | `./integration_tests/buildroot/run-libvirt.sh` | ARM64 host |
| FreeBSD | rc.d | `./integration_tests/freebsd/run-libvirt.sh` | ARM64 host |
| OpenWrt | procd | `./integration_tests/openwrt/run-libvirt.sh` | ARM64 host |
| OpenWrt MIPS | procd | `./integration_tests/openwrt-mips/run-qemu.sh` | Debian/Ubuntu host with `apt-get` |
| FriendlyWrt | procd | `./integration_tests/friendlywrt/run-qemu.sh` | ARM64 Debian/Ubuntu host |
| ImmortalWrt | procd | `./integration_tests/immortalwrt/run-qemu.sh` | QEMU capable of ARM64 |
| Windows Server | Windows SCM | `./integration_tests/windows/run-qemu.sh` | x86-64 QEMU; ARM64 uses TCG |
| Experimental Devuan constructor | System V | `./integration_tests/systemv/run-libvirt.sh` | x86-64 or ARM64 |
| Experimental Debian conversion | System V | `./integration_tests/systemv/run-libvirt-fallback.sh` | x86-64 or ARM64 |

## Ubuntu host prerequisites

Install the packages appropriate for the host architecture:

```sh
sudo apt update
sudo apt install libvirt-daemon-system libvirt-clients virtinst \
  cloud-image-utils qemu-utils qemu-system-x86 qemu-system-arm uuid-runtime \
  qemu-efi-aarch64 genisoimage e2fsprogs util-linux wget openssh-client \
  cpio fakeroot kmod mtools xz-utils python3 dpkg-dev iproute2 \
  build-essential bc bison flex git libssl-dev libelf-dev openssl rsync \
  file gnupg
sudo usermod -aG libvirt,kvm "$USER"
```

Log out and back in after changing group membership. A readable `/dev/kvm`
provides hardware acceleration. Without it, the runner selects QEMU software
emulation, which is substantially slower. On ARM hosts, software emulation uses
the non-Secure-Boot AAVMF firmware and a Cortex-A72 CPU model for compatibility
with nested virtualized environments such as Parallels.

The repository's required Go version must also be available on `PATH`. The
module version is defined in [../go.mod](../go.mod).

Some direct-QEMU lanes extract optional host tools from Ubuntu packages without
root privileges. Their scripts check every required command before changing
guest state and report any missing dependency.

Verify access before running the test:

```sh
virsh --connect qemu:///system list
virsh --connect qemu:///system net-info default
```

The default libvirt network must exist. The runner starts it when it exists but
is inactive.

## Run the systemd lane

From the repository root:

```sh
./integration_tests/systemd/run-libvirt.sh
```

The default guest architecture follows the host: AMD64 on x86-64 and ARM64 on
AArch64. The runner downloads the matching Ubuntu 24.04 cloud image, verifies it
against the release checksum, caches it under `/var/tmp`, builds matching static
Go binaries, and creates a disposable guest.

No application port is exposed to the host. HTTP assertions execute inside the
guest against the test application's loopback listener.

Systemd Ubuntu-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `UBUNTU_RELEASE` | `24.04` | Ubuntu cloud-image release |
| `BASE_IMAGE` | Cached release image | Existing qcow2 cloud image |
| `BASE_IMAGE_URL` | Ubuntu release URL | Download source |
| `BASE_IMAGE_SHA256` | Published checksum | Optional pinned image checksum |

## Run the Rocky Linux lane

The Rocky Linux lane targets the official Rocky Linux 9.8 GenericCloud Base
image and keeps SELinux in Enforcing mode:

```sh
./integration_tests/rocky/run-libvirt.sh
```

The default guest architecture follows the host: x86-64 on x86-64 and ARM64 on
AArch64. The image is verified against Rocky's per-image published SHA-256 and
used through a disposable qcow2 overlay. The guest test does not install
packages or weaken SELinux policy.

In addition to the shared systemd lifecycle, the lane verifies:

- SELinux is enabled and enforcing before and after reboot;
- installing the temporary `/tmp/test-app` without `--ignore-warnings` prints
  the SELinux warning, refuses the noninteractive install, and creates no unit
  or metadata;
- the root-owned `/opt/daemon-itest/test-app` installs without bypassing
  warnings and runs successfully;
- application, executable, unit, and metadata labels match policy and are not
  `unlabeled_t`;
- the live application process has a valid SELinux execution context; and
- kernel and bounded audit-log checks contain no service-specific AVC denial.

Rocky-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `ROCKY_RELEASE` | `9.8` | Rocky Linux release embedded in the image filename |
| `ROCKY_BUILD` | `20260525.0` | Version-pinned GenericCloud build |
| `ROCKY_BASE_IMAGE` | Cached official image | Existing Rocky qcow2 image |
| `ROCKY_BASE_IMAGE_SHA256` | Published checksum | Optional pinned image checksum |
| `ROCKY_IMAGE_URL` | Official versioned image | Download source |
| `ROCKY_IMAGE_CHECKSUM_URL` | Image URL plus `.CHECKSUM` | Published checksum source |
| `VM_OS_VARIANT` | `rocky9` | libosinfo identifier |

The shared `VM_ARCH`, `VM_MEMORY_MIB`, `VM_VCPUS`, `VM_DISK_GIB`,
`VM_BOOT_TIMEOUT`, `VM_VIRT_TYPE`, `VM_NETWORK`, `LIBVIRT_URI`,
`ARM_UEFI_CODE`, `ARM_UEFI_VARS`, `INTEGRATION_CACHE_DIR`,
`INTEGRATION_ARTIFACT_DIR`, and `KEEP_VM` settings also apply. The default boot
timeout is 900 seconds because SELinux initialization and reboot are slower
under QEMU TCG.

## Run the Fedora and openSUSE lanes

Both lanes reuse the Rocky/systemd runner with distribution-specific image and
security assertions. Their defaults are pinned ARM64 images:

```sh
./integration_tests/fedora/run-libvirt.sh
./integration_tests/opensuse/run-libvirt.sh
```

Fedora defaults to Cloud Base 44 and requires SELinux Enforcing. openSUSE
defaults to the Tumbleweed minimal ARM64 snapshot dated 2026-08-30, requires
the AppArmor kernel module, and accepts the image's Btrfs or XFS root
filesystem. Both default to a 1,200-second boot timeout under emulation.
Fedora defaults to four vCPUs and 3 GiB RAM; its early device discovery can
exceed native boot deadlines with fewer resources under TCG. Override these
with `VM_VCPUS` and `VM_MEMORY_MIB` when appropriate for the host.

Use `DISTRO_IMAGE_FILENAME`, `DISTRO_IMAGE_URL`,
`DISTRO_IMAGE_SHA256`, and `VM_ARCH` together when substituting another image
or architecture; overriding `VM_ARCH` alone does not select a matching image.

## Run the Raspberry Pi OS lane

The Raspberry Pi OS lane defaults to both supported Pi userspace architectures:

```sh
./integration_tests/raspios/run-qemu.sh
```

It downloads the official Raspberry Pi OS Lite ARMHF and ARM64 images, verifies
each image against Raspberry Pi's published SHA-256, and builds `GOARM=6` and
ARM64 binaries respectively. For each image, it provisions a disposable raw
copy, boots it, runs the full systemd application lifecycle, reboots it, and
then tests configured-failure recovery, direct `SIGKILL` recovery, forced-stop
cleanup, metadata cleanup, and removal.

QEMU's Raspberry Pi machine models do not provide sufficiently complete and
stable networking/reset behavior for this automated suite. The runner therefore
uses an architecture-matched Debian Trixie kernel on QEMU `virt` hardware while
retaining the official Raspberry Pi OS root filesystem, systemd services,
libraries, configuration, cloud-init, and mounted `/boot/firmware` partition.
The Debian kernel, initrd, and matching module packages are also checksum
verified. Pi-specific peripherals and firmware behavior still require physical
Raspberry Pi hardware.

Run one architecture when needed:

```sh
RASPIOS_VARIANTS=armhf ./integration_tests/raspios/run-qemu.sh
RASPIOS_VARIANTS=arm64 ./integration_tests/raspios/run-qemu.sh
```

Raspberry Pi OS-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `RASPIOS_VARIANTS` | `armhf,arm64` | Comma-separated architectures to test |
| `RASPIOS_RELEASE` | `2026-06-18` | Raspberry Pi OS image filename date |
| `RASPIOS_IMAGE_RELEASE` | `2026-06-19` | Raspberry Pi download-directory date |
| `RASPIOS_ARMHF_IMAGE` | Cached official image | Existing compressed ARMHF image |
| `RASPIOS_ARMHF_IMAGE_URL` | Official Raspberry Pi URL | ARMHF download source |
| `RASPIOS_ARMHF_IMAGE_SHA256` | Published checksum | Optional pinned ARMHF checksum |
| `RASPIOS_ARM64_IMAGE` | Cached official image | Existing compressed ARM64 image |
| `RASPIOS_ARM64_IMAGE_URL` | Official Raspberry Pi URL | ARM64 download source |
| `RASPIOS_ARM64_IMAGE_SHA256` | Published checksum | Optional pinned ARM64 checksum |
| `DEBIAN_RELEASE` | `trixie` | Generic boot-kernel and module release |
| `RASPIOS_SSH_PORT` | `55222` | First host SSH forwarding port |
| `QEMU_ACCEL` | `tcg` | QEMU accelerator |

The shared `VM_MEMORY_MIB`, `VM_VCPUS`, `VM_BOOT_TIMEOUT`, `TEST_APP_PORT`,
`INTEGRATION_CACHE_DIR`, `INTEGRATION_ARTIFACT_DIR`, `VM_WORK_DIR`, and
`KEEP_VM` settings also apply. The variants run sequentially and need about
8 GiB of free disk for downloads, one expanded image, and working files.

## Run the Armbian Orange Pi lane

The Armbian lane defaults to the official Orange Pi 5 ARM64 minimal image:

```sh
./integration_tests/armbian/run-qemu.sh
```

The runner verifies Armbian's published SHA-256, extracts and enlarges the real
ext4 root partition, and boots it using the image's native Rockchip64 kernel and
initramfs on generic QEMU `virt` hardware. The guest runs the complete systemd
application lifecycle and hot-replacement scenario without SSH or cloud-init.
This validates Armbian userspace and service behavior; the RK3588 bootloader,
device tree, and peripherals still require physical Orange Pi or Rock 5 hardware.

Armbian-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `ARMBIAN_RELEASE` | `26.8.1` | Versioned Armbian release |
| `ARMBIAN_BOARD` | `Orangepi5` | Board image userspace |
| `ARMBIAN_CODENAME` | `trixie` | Debian userspace codename |
| `ARMBIAN_KERNEL_VERSION` | `6.18.43` | Native image kernel version |
| `ARMBIAN_IMAGE` | Cached official image | Existing compressed board image |
| `ARMBIAN_IMAGE_URL` | Official versioned image URL | Image download source |
| `ARMBIAN_IMAGE_SHA256` | Published checksum | Optional pinned checksum override |
| `ARMBIAN_ROOTFS_SIZE_MIB` | `3072` | Expanded disposable root filesystem size |

## Run the additional systemd vendor lanes

These runners reuse either the Armbian direct-QEMU harness or the shared
systemd guest test:

```sh
./integration_tests/dietpi/run-qemu.sh
./integration_tests/radxa/run-qemu.sh
./integration_tests/orangepi/run-qemu.sh
./integration_tests/friendlycore/run-qemu.sh
./integration_tests/archlinux/run-qemu.sh
./integration_tests/manjaro/run-qemu.sh
```

| Lane | Default source | Boot kernel |
| --- | --- | --- |
| DietPi | Orange Pi 5 ARMv8 Trixie image | Native image kernel |
| Radxa OS | ROCK 5B Debian Bullseye CLI `b42` | Verified Poky 5.0.19 QEMU ARM64 kernel |
| Orange Pi | Orange Pi 5 Ubuntu Jammy Server 1.2.4 | Verified Poky 5.0.19 QEMU ARM64 kernel |
| FriendlyCore | NanoPi R5S Focal image dated 2026-07-21 | Verified Poky 5.0.19 QEMU ARM64 kernel |
| Arch Linux ARM | Signed generic AArch64 rootfs | Kernel and initramfs from the rootfs |
| Manjaro ARM | Minimal generic ARM64 23.02 image | Verified Poky 5.0.19 QEMU ARM64 kernel |

The vendor-image lanes validate their userspace, init system, and service
behavior on QEMU `virt`; they do not validate board boot firmware, device
trees, storage controllers, networking hardware, or peripherals. Each wrapper
accepts lane-prefixed image, checksum, rootfs-size, and boot-timeout overrides
defined at the top of its `run-qemu.sh` file.

## Run the Yocto/Poky lane

The Yocto lane targets the official Poky 5.0.19 Scarthgap LTS ARM64 minimal
image:

```sh
./integration_tests/yocto/run-qemu.sh
```

The runner verifies the official kernel and root filesystem against their
published SHA-256 sidecars, copies and enlarges the 22 MiB ext4 image, and
injects static ARM64 test binaries without mounting the filesystem. The stock
minimal image has no SSH server, so a guest-side runlevel script performs the
two-boot lifecycle, records a durable PASS or FAIL result, and powers off. The
host extracts the result, serial log, and artifact archive directly from the
stopped ext4 image.

This lane uses Poky's native SysVinit environment without installing packages
or adding compatibility wrappers. It validates the presence and behavior of
the image's real `service`, BusyBox `wget`, runlevel scripts, and watchdog
process. It validates PID/start-time identity before TERM/KILL escalation and
does not implement a custom process-tree or process-group supervisor.

Yocto-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `YOCTO_RELEASE` | `5.0.19` | Scarthgap LTS release |
| `YOCTO_IMAGE_BASE_URL` | Official qemuarm64 directory | Artifact source |
| `YOCTO_KERNEL` | Cached official kernel | Existing kernel image |
| `YOCTO_KERNEL_URL` | Official `Image-qemuarm64.bin` | Kernel source |
| `YOCTO_KERNEL_SHA256` | Published checksum | Optional pinned kernel checksum |
| `YOCTO_ROOTFS` | Cached official ext4 | Existing minimal rootfs |
| `YOCTO_ROOTFS_URL` | Official minimal ext4 | Rootfs source |
| `YOCTO_ROOTFS_SHA256` | Published checksum | Optional pinned rootfs checksum |
| `YOCTO_ROOTFS_SIZE_MIB` | `256` | Expanded disposable ext4 size |
| `QEMU_ACCEL` | Automatic | `kvm` on compatible ARM64 hosts, otherwise `tcg` |

The shared `VM_MEMORY_MIB`, `VM_VCPUS`, `VM_BOOT_TIMEOUT`, `TEST_APP_PORT`,
`INTEGRATION_CACHE_DIR`, `INTEGRATION_ARTIFACT_DIR`, `VM_WORK_DIR`, and
`KEEP_VM` settings also apply. No libvirt network, cloud-init, SSH key, or UEFI
firmware is required.

## Experimental generic System V constructors

The verified System V regression is the Yocto lane above. Two additional
libvirt constructors are retained for diagnostics:

```sh
./integration_tests/systemv/run-libvirt.sh
./integration_tests/systemv/run-libvirt-fallback.sh
```

The first performs a native Devuan Excalibur installation; the second attempts
to convert a Debian 12 cloud image to SysVinit. These image-construction paths
are not part of the passing matrix and may fail before daemon-util reaches its
guest application tests. Such failures are constructor or image-compatibility
failures, not evidence of a daemon-util runtime failure. When a guest does
reach the tests, the backend validates and signals only the recorded main PID;
it does not provide arbitrary descendant cleanup even if the kernel exposes
cgroups.

## Run the OpenRC lane

The OpenRC lane currently targets the official Alpine ARM64 UEFI cloud image:

```sh
./integration_tests/openrc/run-libvirt.sh
```

This libvirt runner currently requires an ARM64 host.

The runner downloads Alpine 3.24.1, verifies the published SHA-512 checksum,
installs Bash through cloud-init for the guest test driver, connects through the
default `alpine` account and its passwordless `doas` policy, and confirms OpenRC
is the active backend before changing service state. Metadata is delivered with
NoCloud-Net over the libvirt bridge because Alpine cloud-init images do not
guarantee that the packages needed to mount a CIDATA ISO are present. The runner
also enables Alpine's PAM-backed SSH server because non-PAM SSH rejects key
authentication for the locked default cloud account.

OpenRC-specific image settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `ALPINE_VERSION` | `3.24.1` | Alpine cloud-image release |
| `ALPINE_BRANCH` | Version major/minor | Alpine repository branch |
| `ALPINE_BASE_IMAGE` | Cached official image | Existing Alpine qcow2 image |
| `ALPINE_BASE_IMAGE_URL` | Official generic image | Download source |
| `ALPINE_BASE_IMAGE_SHA512` | Published checksum | Optional pinned image checksum |
| `VM_METADATA_HOST` | `192.168.122.1` | Host address on the libvirt bridge |
| `VM_OS_VARIANT` | `alpinelinux3.21` | Closest available libosinfo identifier |

The shared `VM_MEMORY_MIB`, `VM_VCPUS`, `VM_DISK_GIB`, `VM_BOOT_TIMEOUT`,
`VM_VIRT_TYPE`, `VM_NETWORK`, `LIBVIRT_URI`, `ARM_UEFI_CODE`, `ARM_UEFI_VARS`,
`INTEGRATION_CACHE_DIR`, `INTEGRATION_ARTIFACT_DIR`, and `KEEP_VM` settings also
apply. The OpenRC defaults are 1 GiB memory and a 4 GiB overlay.

## Run the Gentoo OpenRC lane

The Gentoo lane targets the official ARM64 OpenRC stage3:

```sh
./integration_tests/gentoo/run-qemu.sh
```

A stage3 contains Gentoo's root userspace but no kernel or bootloader. The
runner therefore creates a disposable ext4 image from the stage3 and boots it
with the checksum-verified generic ARM64 QEMU kernel from Yocto 5.0.19. Gentoo's
`init` remains PID 1, and Gentoo's OpenRC manages the complete test lifecycle.
The external kernel is used only as a QEMU boot harness.

The test runs from an OpenRC `local.d` hook after all default-runlevel services.
It performs pre-reboot and post-reboot phases, records durable PASS or FAIL
state, emits progress through the serial console, powers off the guest, and
extracts its artifacts from the stopped ext4 image. It does not require guest
networking or modify the cached stage3.

Gentoo-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `GENTOO_STAGE3_BUILD` | `20260830T234553Z` | Pinned official stage3 build |
| `GENTOO_STAGE3_NAME` | Build-derived ARM64 OpenRC archive | Stage3 filename |
| `GENTOO_STAGE3` | Cached official archive | Existing stage3 archive |
| `GENTOO_STAGE3_URL` | Official dated stage3 URL | Download source |
| `GENTOO_STAGE3_SHA256` | Published checksum | Optional pinned stage3 checksum |
| `GENTOO_BOOT_KERNEL_RELEASE` | `5.0.19` | Yocto release supplying the QEMU boot kernel |
| `GENTOO_BOOT_KERNEL` | Cached official kernel | Existing ARM64 QEMU kernel |
| `GENTOO_BOOT_KERNEL_URL` | Official Yocto kernel URL | Boot-kernel download source |
| `GENTOO_BOOT_KERNEL_SHA256` | Published checksum | Optional pinned boot-kernel checksum |
| `GENTOO_ROOTFS_SIZE_MIB` | `2048` | Disposable ext4 image size |

The shared `VM_MEMORY_MIB`, `VM_VCPUS`, `VM_BOOT_TIMEOUT`, `TEST_APP_PORT`,
`INTEGRATION_CACHE_DIR`, `INTEGRATION_ARTIFACT_DIR`, `VM_WORK_DIR`, `QEMU_ACCEL`,
and `KEEP_VM` settings also apply.

## Run the Void Linux runit lane

The runit lane targets the official Void Linux ARM64 root filesystem:

```sh
./integration_tests/runit/run-qemu.sh
```

The runner verifies the pinned rootfs checksum against Void's published
manifest, creates a disposable ext4 image, and boots it with the same verified
generic ARM64 QEMU kernel used by the Gentoo lane. Void's runit remains PID 1.
The guest test runs as a supervised service without SSH or online package
installation and stores its two-boot result and diagnostics in the rootfs for
offline extraction.

Void-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `VOID_RELEASE` | `20250202` | Pinned official Void image release |
| `VOID_ROOTFS_NAME` | Release-derived ARM64 rootfs archive | Rootfs filename |
| `VOID_ROOTFS` | Cached official archive | Existing rootfs archive |
| `VOID_ROOTFS_URL` | Official Void rootfs URL | Download source |
| `VOID_ROOTFS_SHA256` | Pinned published checksum | Rootfs checksum |
| `VOID_BOOT_KERNEL_RELEASE` | `5.0.19` | Yocto release supplying the QEMU boot kernel |
| `VOID_BOOT_KERNEL` | Cached official kernel | Existing ARM64 QEMU kernel |
| `VOID_BOOT_KERNEL_URL` | Official Yocto kernel URL | Boot-kernel download source |
| `VOID_BOOT_KERNEL_SHA256` | Published checksum | Optional pinned boot-kernel checksum |
| `VOID_ROOTFS_SIZE_MIB` | `1024` | Disposable ext4 image size |

The shared `VM_MEMORY_MIB`, `VM_VCPUS`, `VM_BOOT_TIMEOUT`, `TEST_APP_PORT`,
`INTEGRATION_CACHE_DIR`, `INTEGRATION_ARTIFACT_DIR`, `VM_WORK_DIR`, `QEMU_ACCEL`,
and `KEEP_VM` settings also apply.

## Run the Upstart lane

The Upstart lane targets the official Ubuntu 14.04.5 LTS ARM64 UEFI cloud image:

```sh
./integration_tests/upstart/run-libvirt.sh
```

This historical direct-boot runner currently requires an ARM64 host.

Because modern AArch64 firmware may not boot this historical image reliably,
the runner defaults to direct boot with the image's Ubuntu 4.4 kernel and
initrd. It verifies the official image SHA-256 before creating a disposable
overlay. Ubuntu 14.04 is end-of-life; the lane does not install guest packages
or depend on archived package repositories.

Upstart-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `UPSTART_BOOT_MODE` | `direct` | Use `direct` kernel boot or optional `uefi` boot |
| `UPSTART_BASE_IMAGE` | Cached official Trusty image | Existing qcow2 image |
| `UPSTART_BASE_IMAGE_SHA256` | Published checksum | Optional pinned image checksum |
| `UPSTART_IMAGE_URL` | Official Trusty release URL | Image download source |
| `UPSTART_KERNEL_VERSION` | `4.4.0-148-generic` | Kernel and initrd version extracted for direct boot |
| `UPSTART_KERNEL_IMAGE` | Cached extracted kernel | Existing direct-boot kernel |
| `UPSTART_INITRD_IMAGE` | Cached extracted initrd | Existing direct-boot initrd |

The shared VM, cache, artifact, and `KEEP_VM` settings also apply.

## Run the Windows Server lane

The Windows lane defaults to the official Windows Server 2019 Evaluation ISO and
runs without requiring a prebuilt Windows image. Select Server 2025 explicitly:

```sh
./integration_tests/windows/run-qemu.sh
WINDOWS_SERVER_VERSION=2025 ./integration_tests/windows/run-qemu.sh
```

The first run downloads the selected Microsoft ISO (4.9 GiB for Server 2019 or
7.6 GiB for Server 2025), verifies its pinned SHA-256, and performs one
unattended Server Core installation. Later runs use a disposable qcow2 overlay
backed by the cached clean base disk and do not download or verify the installer
ISO unless the base is missing or `WINDOWS_RESET_BASE=1`. The test communicates
with the guest through WinRM and forwards the application's HTTP endpoint to
the host for external assertions.

The runner builds a second application binary with a distinct PE hash and uses
same-volume `File.Replace` while the original process is running. It accepts and
records either valid Windows result: a successful live replacement or an
expected sharing violation with an unchanged target. It then stops the service,
ensures the replacement hash is installed, starts the service, and verifies a
new application PID plus healthy SCM/status/list behavior. Windows Server 2019
and Server 2025 both permit live replacement in the tested configurations.

These Windows Server images are x86-64-only. On an ARM64 host the runner extracts Ubuntu's
`qemu-system-x86` and WinRM client packages into `/var/tmp` without sudo, then
uses QEMU TCG cross-architecture emulation. Initial installation can take
several hours; at least 12 GiB for Server 2019 or 18 GiB for Server 2025 of free
disk space is required. The evaluation image remains subject to Microsoft's
licensing terms.

Windows-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `WINDOWS_SERVER_VERSION` | `2019` | Evaluation release: `2019` or `2025` |
| `WINDOWS_ISO` | Cached official ISO for the selected release | Existing installation ISO |
| `WINDOWS_ISO_URL` | Official Microsoft evaluation URL | ISO download source |
| `WINDOWS_ISO_SHA256` | Pinned official-image checksum | Override checksum for a supplied ISO |
| `WINDOWS_BASE_IMAGE` | Cached Server Core qcow2 | Existing prepared base image |
| `WINDOWS_RESET_BASE` | `0` | Set to `1` to discard and reinstall the selected cached base image |
| `WINDOWS_ADMIN_USER` | `Administrator` | Disposable guest administrator |
| `WINDOWS_ADMIN_PASSWORD` | `DaemonTest!2026` | Disposable guest password |
| `WINDOWS_WINRM_OPERATION_TIMEOUT` | `180` | Timeout for an individual WinRM operation in seconds |
| `WINDOWS_WINRM_PORT` | `55985` | Host port forwarded to guest WinRM |
| `WINDOWS_APP_HOST_PORT` | `58080` | Host port forwarded to the test application |
| `WINDOWS_PAYLOAD_PORT` | `58081` | Temporary host payload server port |
| `WINDOWS_VNC_DISPLAY` | `7` | Local-only VNC display used for diagnostics |
| `VM_INSTALL_TIMEOUT` | `14400` (2019), `21600` (2025) | First installation timeout in seconds |

The shared cache, artifact, memory, CPU, disk, boot-timeout, and `KEEP_VM`
settings also apply. The defaults are 2.5 GiB memory, two vCPUs, and a sparse
40 GiB virtual disk.

## Run the FreeBSD lane

The FreeBSD lane uses the official ARM64 BASIC-CLOUDINIT UFS image:

```sh
./integration_tests/freebsd/run-libvirt.sh
```

This libvirt runner currently requires an ARM64 host.

The default is FreeBSD 14.4-RELEASE. The compressed image is verified against
the release SHA-256 manifest before it is decompressed and cached. No packages
are installed in the guest; the test driver uses FreeBSD base-system tools. The
image's automatic first-boot base and package updates are disabled through
nuageinit's early config-2 file provisioning, before networking and the update
services. The same provisioning configures temporary key-only root SSH for the
disposable guest.

FreeBSD-specific image settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `FREEBSD_RELEASE` | `14.4-RELEASE` | FreeBSD VM-image release |
| `FREEBSD_BASE_IMAGE` | Cached decompressed image | Existing FreeBSD qcow2 image |
| `FREEBSD_BASE_IMAGE_SHA256` | None | Optional checksum for a supplied base image |
| `FREEBSD_COMPRESSED_IMAGE` | Cached official archive | Existing compressed image |
| `FREEBSD_IMAGE_URL` | Official release URL | Compressed-image download source |
| `FREEBSD_IMAGE_SHA256` | Release manifest value | Optional pinned archive checksum |
| `VM_OS_VARIANT` | `freebsd14.2` | Closest available libosinfo identifier |

The shared VM and artifact settings also apply. The FreeBSD
defaults are 2 GiB memory and an 8 GiB overlay.

## Run the OpenWrt lane

The OpenWrt lane uses the official ARM64 ext4 combined EFI image:

```sh
./integration_tests/openwrt/run-libvirt.sh
```

This libvirt runner currently requires an ARM64 host.

The default is OpenWrt 25.12.5. The runner verifies the published SHA-256,
copies the raw image for each run, and injects an ephemeral Dropbear key and a
first-boot UCI script with unprivileged ext4 tools. The UCI script changes the
LAN interface to DHCP and disables its DHCP server so the guest can safely join
the existing libvirt network.

OpenWrt-specific image settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `OPENWRT_VERSION` | `25.12.5` | OpenWrt image release |
| `OPENWRT_BASE_IMAGE` | Cached decompressed image | Existing raw OpenWrt image |
| `OPENWRT_BASE_IMAGE_SHA256` | None | Optional checksum for a supplied base image |
| `OPENWRT_COMPRESSED_IMAGE` | Cached official archive | Existing compressed image |
| `OPENWRT_IMAGE_URL` | Official release URL | Compressed-image download source |
| `OPENWRT_IMAGE_SHA256` | Published checksum | Optional pinned archive checksum |
| `VM_OS_VARIANT` | `linux2024` | Generic Linux libosinfo identifier |

The shared VM and artifact settings also apply. The OpenWrt default is 512 MiB
of memory. OpenWrt mounts `/var` as volatile storage, so informational `APP` and
`ARGS` list metadata is expected to disappear after reboot; the persistent
procd service definition remains authoritative.

## Run the additional procd lanes

The MIPS lane tests both official Malta endian variants with soft-float Go
binaries. The ImmortalWrt lane tests the official ARM64 EFI image:

```sh
./integration_tests/openwrt-mips/run-qemu.sh
./integration_tests/immortalwrt/run-qemu.sh
```

`OPENWRT_MIPS_VERSION=25.12.0` and `OPENWRT_MIPS_VARIANTS=le,be` select the
default MIPS images. The MIPS runner extracts QEMU's MIPS binaries from host
packages into `/var/tmp` and therefore requires a Debian/Ubuntu host with
`apt-get` and `dpkg-deb`. ImmortalWrt defaults to release 23.05.7 for target
`armsr/armv8` and uses a separate 128 MiB state image to preserve two-boot test
state.

## Run the NanoPi FriendlyWrt lane

The FriendlyWrt lane uses the official NanoPi R5S/R5C FriendlyWrt 25.12 archive:

```sh
./integration_tests/friendlywrt/run-qemu.sh
```

The archive contains a Linux/OpenWrt ext4 root filesystem stored in Android
sparse-image format. The runner uses `simg2img` only as a host-side format
converter, verifies that the result identifies OpenWrt `rockchip/armv8` with
procd as PID 1, and boots the real FriendlyWrt userspace with a generic ARM64
QEMU kernel. A separate ext4 state disk retains phase and artifact data despite
FriendlyWrt's writable overlay, allowing the host to validate both boot phases.
Board-specific RK3568 firmware and network hardware require a physical NanoPi.

FriendlyWrt-specific settings are:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `FRIENDLYWRT_RELEASE` | `2026-08-07` | Official release tag date |
| `FRIENDLYWRT_ARCHIVE` | Cached official archive | Existing NanoPi image archive |
| `FRIENDLYWRT_ARCHIVE_URL` | Official GitHub release URL | Archive download source |
| `FRIENDLYWRT_ARCHIVE_SHA256` | Pinned release checksum | Archive integrity check |
| `FRIENDLYWRT_QEMU_KERNEL` | Cached Poky qemuarm64 kernel | Generic test boot kernel |
| `FRIENDLYWRT_STATE_SIZE_MIB` | `128` | Persistent test-state disk size |

## Common runner configuration

Defaults vary by lane; the values below describe the general libvirt baseline.
Direct-QEMU and vendor wrappers override them where their sections or scripts
say otherwise.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `VM_ARCH` | Host architecture | `amd64` or `arm64` guest |
| `VM_MEMORY_MIB` | Runner-specific | Guest memory |
| `VM_VCPUS` | `2` | Guest virtual CPUs |
| `VM_DISK_GIB` | Runner-specific | Overlay disk capacity where applicable |
| `VM_BOOT_TIMEOUT` | Runner-specific | Boot, SSH, and reboot timeout in seconds |
| `VM_VIRT_TYPE` | Automatic | Force `kvm` or `qemu` |
| `QEMU_ACCEL` | Automatic | Force `kvm` or `tcg` in direct-QEMU lanes |
| `VM_NETWORK` | `default` | Existing libvirt NAT network |
| `LIBVIRT_URI` | `qemu:///system` | Libvirt connection URI |
| `ARM_UEFI_CODE` | AAVMF non-Secure-Boot code | ARM firmware code image |
| `ARM_UEFI_VARS` | AAVMF variables template | ARM firmware variables image |
| `INTEGRATION_CACHE_DIR` | `/var/tmp/daemon-util-integration-cache-<uid>` | Base-image cache |
| `INTEGRATION_ARTIFACT_DIR` | `integration_tests/artifacts` | Diagnostic output |
| `VM_WORK_DIR` | Timestamped path under `/var/tmp` | Temporary per-run workspace |
| `TEST_APP_PORT` | `18080` | Guest loopback application port |
| `KEEP_VM` | `0` | Keep the domain and temporary disks when set to `1` |

For reproducible Ubuntu systemd CI, provide a controlled `BASE_IMAGE` and pin
its `BASE_IMAGE_SHA256`.

Examples:

```sh
VM_ARCH=arm64 ./integration_tests/systemd/run-libvirt.sh

BASE_IMAGE=/srv/vm-images/ubuntu-systemd.qcow2 \
BASE_IMAGE_SHA256='<pinned-sha256>' \
./integration_tests/systemd/run-libvirt.sh

KEEP_VM=1 ./integration_tests/systemd/run-libvirt.sh
```

## Failure artifacts

Each run creates a timestamped artifact directory. Libvirt lanes retain domain
XML and network diagnostics; direct-QEMU lanes retain serial logs, source and
checksum records, and available guest diagnostics. Depending on the lane,
guest diagnostics include:

- generated systemd unit, OpenRC service script, FreeBSD rc.d script, or
  OpenWrt procd script;
- SELinux enforcement state, file/process contexts, warning output, and scoped
  audit/kernel AVC diagnostics for Rocky Linux;
- native service-manager status and registration output;
- journal entries where available;
- process list;
- HTTP response snapshots; and
- JSON Lines lifecycle records from the test application.

Offline-image lanes such as Yocto, Gentoo, runit, and several vendor runners
also retain a durable guest result, guest test log, and artifacts extracted
from the stopped filesystem.

The libvirt domain or direct-QEMU process and disposable work files are removed
even when a test fails unless `KEEP_VM=1` is set. Libvirt runners first reject
existing domain names before creating test files and allocate a fresh UUID for
each test domain (including the experimental System V installer domain).
Creation, lookup, and cleanup use that UUID, so failed or partial creation
cannot cause cleanup to stop or unregister a different VM with the same name.

The host-side ownership and openSUSE assertion regressions run with the normal
Go tests using mocked commands; they do not access libvirt or boot a VM. To
exercise collision handling against a real libvirt daemon, run the diskless
definition test (it never boots its two temporary domains):

```sh
bash integration_tests/libvirt-ownership-test.sh
```

That test requires the runner prerequisites above and verifies every libvirt
entry point refuses a name collision without changing the existing domain or
work directory. It also verifies cleanup of a partially created owned domain.

Most software-emulated runners print periodic boot, DHCP, SSH, or reboot
progress. These waits are expected to take longer than they do with KVM.

## Build multiple Buildroot variants

To simulate different real-world Buildroot configurations, build a profile
matrix from source:

```sh
./integration_tests/buildroot/build-matrix.sh
```

Default profiles are `baseline,debug,release` using
`qemu_aarch64_virt_defconfig` plus profile fragments in
`integration_tests/buildroot/fragments`.

The matrix can be built on a normal Linux development host, but the current
libvirt runner for the generated ARM64 images requires an ARM64 host.

Useful overrides:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `BUILDROOT_REF` | `2026.02.3` | Buildroot git tag/branch to clone |
| `BUILDROOT_DIR` | `.cache/buildroot-<ref>` | Existing Buildroot source tree |
| `BUILDROOT_OUTPUT_ROOT` | `/var/tmp/daemon-buildroot-matrix` | Per-profile output root |
| `BUILDROOT_PROFILES` | `baseline,debug,release` | Comma-separated profile list |
| `JOBS` | Host CPU count | Parallel build jobs |
| `BUILDROOT_KEEP_BUILD_TREES` | `0` | Set to `1` to retain large per-profile compiler and target trees |
| `BUILDROOT_RESUME` | `0` | Set to `1` to resume profiles with an existing output configuration |
| `BUILDROOT_PROFILE` | `baseline` | Profile selected by `run-libvirt.sh` |
| `BUILDROOT_IMAGE_DIR` | `<output-root>/<profile>/images` | Directory containing generated boot images |
| `BUILDROOT_KERNEL` | `<image-dir>/Image` | Kernel passed to libvirt |
| `BUILDROOT_ROOTFS` | `<image-dir>/rootfs.ext2` | Root filesystem copied for the guest |

Example building two profiles only:

```sh
BUILDROOT_PROFILES=baseline,release JOBS=8 ./integration_tests/buildroot/build-matrix.sh
```

The builder writes a manifest at:

- `BUILDROOT_OUTPUT_ROOT/manifest.tsv`

Each row contains the generated kernel and rootfs image paths for one profile.
Run the application regression against each generated profile with:

```sh
for profile in baseline debug release; do
  BUILDROOT_PROFILE="$profile" ./integration_tests/buildroot/run-libvirt.sh
done
```

## Safety

The guest test installs a root service and deliberately triggers forced process
termination. Run it only in a disposable VM. The script refuses to execute the
guest phase unless the expected service manager is active and the caller is
root.
