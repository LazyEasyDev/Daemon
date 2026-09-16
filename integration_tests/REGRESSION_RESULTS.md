# Regression results — 2026-09-16

## Environment

- Linux ARM64 host, Go 1.26.0, four host CPUs.
- QEMU TCG software emulation; no KVM device.
- Cached official images and existing Buildroot baseline/debug/release outputs.
- VMs ran sequentially and were removed after each run.
- macOS and Windows integration tests were intentionally excluded.

## Final results

All 14 checks below passed after the fixes and targeted reruns. Thirteen are
real, two-boot application-level VM suites; the ownership check uses real
libvirt definitions without booting its diskless fixtures.

| Check | Final result | Coverage |
| --- | --- | --- |
| Libvirt ownership | PASS | All 11 entry points reject an existing domain name; existing workspace stays intact; owned partial definitions are removed |
| Ubuntu 24.04 / systemd | PASS | Full lifecycle, native maximum-name boundary, metadata, reboot, cleanup |
| openSUSE Tumbleweed | PASS | AppArmor module assertion and full systemd lifecycle |
| Rocky Linux 9.8 | PASS | SELinux Enforcing and full systemd lifecycle |
| Fedora 44 | PASS | SELinux Enforcing and full systemd lifecycle; four vCPUs, 3 GiB RAM |
| Alpine / OpenRC | PASS | Full native application lifecycle and reboot persistence |
| Void Linux / runit | PASS | Full lifecycle plus stop during a real pending respawn and subsequent reboot autostart |
| Ubuntu 14.04 / Upstart | PASS | Full native application lifecycle and reboot persistence |
| OpenWrt / procd | PASS | Full native application lifecycle and reboot persistence |
| Yocto / System V | PASS | Full native application lifecycle and reboot persistence |
| Buildroot baseline | PASS | Full native application lifecycle and reboot persistence |
| Buildroot debug | PASS | Full native application lifecycle and reboot persistence |
| Buildroot release | PASS | Full native application lifecycle and reboot persistence |
| FreeBSD 14.4 | PASS | Full rc.d application lifecycle and reboot persistence |

## Findings resolved during real testing

1. Short temporary names fix the filesystem write failure at the general
   241-character boundary, but a resulting 255-byte systemd unit name triggers
   journald's `Control protocol line not properly terminated` error. New
   systemd installs now reject more than 240 user-name characters. Existing
   names can still be managed or removed, and the general name limit remains
   241. Real tests exercise the 240-character lifecycle and rejection at 241.
2. Native runit `sv` can return while an already-down supervisor has not yet
   consumed the stop command. The regression waits for acknowledgment without
   allowing any additional application startup, then verifies autostart after
   reboot and absence of a persistent `down` marker.
3. Fedora's first attempt hit an early device-discovery deadline with two
   vCPUs/2 GiB under TCG, before the application ran. The retry passed with four
   vCPUs/3 GiB; these are now the Fedora runner defaults, with overrides kept.

## Evidence retained locally

Artifacts are ignored by Git but remain in this workspace. Initial failures
are retained rather than overwritten; the targeted reports supply the final
results for the retried lanes.

- Initial complete matrix: [artifacts/regression-20260916T062423Z-33739/results.tsv](artifacts/regression-20260916T062423Z-33739/results.tsv)
- Runit, Ubuntu, openSUSE, Rocky reruns: [artifacts/regression-20260916T073556Z-101380/results.tsv](artifacts/regression-20260916T073556Z-101380/results.tsv)
- Fedora resource-adjusted rerun: [artifacts/regression-20260916T080634Z-121101/results.tsv](artifacts/regression-20260916T080634Z-121101/results.tsv)

Each report directory contains lane logs, native service diagnostics, HTTP
responses, lifecycle events, and guest result markers where applicable.
