#!/bin/sh

set -eu
umask 022

usage() {
	printf '%s\n' \
		'Usage: sh ./cloud_hook/aws_start.sh' \
		'Builds and installs daemon and the AWS hook on Linux/systemd or Windows/Git Bash.' \
		'Install your applications separately using daemon install and daemon start.' \
		'Requires an existing ASG termination hook.'
}

if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
	usage
	exit 0
fi
if [ "$#" -ne 0 ]; then
	usage >&2
	exit 1
fi

fail() {
	printf 'aws_start: %s\n' "$*" >&2
	exit 1
}

case "$(uname -s)" in
	Linux) target_os=linux; extension= ;;
	MINGW*|MSYS*) target_os=windows; extension=.exe ;;
	*) fail 'Linux/systemd or Windows with Git Bash is required.' ;;
esac
cpu=$(uname -m)
if [ "$target_os" = windows ]; then
	case "$cpu" in
		x86_64|amd64|AMD64|aarch64|arm64|ARM64) ;;
		*) fail 'Use 64-bit Git Bash on Windows.' ;;
	esac
	cpu=${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-$cpu}}
fi
case "$cpu" in
	x86_64|AMD64|amd64) arch=amd64 ;;
	aarch64|arm64|ARM64) arch=arm64 ;;
	*) fail 'Only AMD64 and ARM64 are supported by this quick start.' ;;
esac
if [ "$target_os" = linux ]; then
	tools='go systemctl ln readlink chmod'
else
	tools='go cygpath powershell.exe readlink'
fi
for tool in $tools; do
	command -v "$tool" >/dev/null 2>&1 || fail "Required command not found: $tool"
done

run_root() {
	if [ "$target_os" = windows ] || [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo -- "$@"
	fi
}

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
unit_dir=/etc/systemd/system
daemon_link=/usr/bin/daemon
daemon_target="$repo_dir/build/daemon-$target_os-$arch$extension"
hook_target="$repo_dir/cloud_hook/build/aws_hook-$target_os-$arch$extension"

if [ "$target_os" = linux ]; then
	systemctl show --property=Version --value >/dev/null ||
		fail 'A running, accessible systemd service manager is required.'
	if [ "$(id -u)" -ne 0 ]; then
		command -v sudo >/dev/null 2>&1 || fail 'sudo is required when not running as root.'
		sudo -v
	fi
	if [ -e "$unit_dir/lz_lz_awsHook.service" ] || [ -L "$unit_dir/lz_lz_awsHook.service" ]; then
		fail 'awsHook is already installed. Use daemon to manage it; this script is for initial setup.'
	fi
else
	daemon_link="$(cygpath -u "${WINDIR:-C:/Windows}")/System32/daemon.exe"
	DAEMON_HOOK_SERVICE=lz_lz_awsHook MSYS2_ARG_CONV_EXCL='*' \
		powershell.exe -NoProfile -NonInteractive -Command '
			$ErrorActionPreference = "Stop"
			$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
			if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
				throw "Open Git Bash as Administrator and run setup again."
			}
			if (Get-Service -ErrorAction Stop | Where-Object { $_.Name -eq $env:DAEMON_HOOK_SERVICE }) {
				throw "$env:DAEMON_HOOK_SERVICE is already installed. Use daemon to manage it; this script is for initial setup."
			}
		' || fail 'Windows service setup prerequisites failed.'
fi

if [ -e "$daemon_link" ] || [ -L "$daemon_link" ]; then
	[ -L "$daemon_link" ] || fail "Refusing to replace existing $daemon_link."
	link_target=$(readlink "$daemon_link")
	if [ "$target_os" = windows ]; then
		link_target=$(cygpath -u "$link_target")
	fi
	[ "$link_target" = "$daemon_target" ] ||
		fail "Refusing to replace existing $daemon_link."
fi

printf 'Detected %s/%s; building daemon and cloud hooks...\n' "$target_os" "$arch"
sh "$repo_dir/build.sh"
sh "$repo_dir/cloud_hook/build.sh"

if [ "$target_os" = linux ]; then
	run_root chmod u=rwx,go=rx,a-s,a-t \
		"$repo_dir/build" "$repo_dir/cloud_hook/build" "$daemon_target" "$hook_target"
	if [ ! -L "$daemon_link" ]; then
		run_root ln -s "$daemon_target" "$daemon_link"
	fi
	resolved_daemon=$(run_root sh -c 'command -v daemon') ||
		fail 'daemon is not available on the privileged command path.'
	[ "$resolved_daemon" = "$daemon_link" ] ||
		fail "daemon resolves to $resolved_daemon instead of $daemon_link; check the privileged PATH."
else
	DAEMON_LINK_PATH="$(cygpath -w "$daemon_link")" \
	DAEMON_TARGET_PATH="$(cygpath -w "$daemon_target")" MSYS2_ARG_CONV_EXCL='*' \
		powershell.exe -NoProfile -NonInteractive -Command '
			$ErrorActionPreference = "Stop"
			if (-not (Test-Path -LiteralPath $env:DAEMON_LINK_PATH)) {
				New-Item -ItemType SymbolicLink -Path $env:DAEMON_LINK_PATH -Target $env:DAEMON_TARGET_PATH | Out-Null
			}
			$command = Get-Command daemon -CommandType Application -ErrorAction Stop
			if ($command.Source -ine $env:DAEMON_LINK_PATH) {
				throw "daemon resolves to $($command.Source) instead of $env:DAEMON_LINK_PATH; check PATH."
			}
		' || fail 'Cannot create or resolve the global Windows daemon command.'
	hook_target=$(cygpath -w "$hook_target")
fi

run_root "$daemon_link" install awsHook "$hook_target"
run_root "$daemon_link" start awsHook

printf '%s\n' \
	"Installed daemon shortcut: $daemon_link" \
	'ASG prerequisite: EC2_INSTANCE_TERMINATING lifecycle hook, default result CONTINUE.' \
	'This script does not create that AWS hook. Its timeout must cover detection and cleanup.'
if [ "$target_os" = linux ]; then
	printf '%s\n' \
		'Use sudo daemon install <service-name> <application> and sudo daemon start <service-name>.' \
		'Verify metadata monitoring: sudo journalctl -u lz_lz_awsHook.service -n 50 --no-pager'
else
	printf '%s\n' \
		'In an administrator terminal, use daemon install <service-name> <application> and daemon start <service-name>.' \
		"Hook logs: $hook_target.1.log and $hook_target.2.log"
fi
