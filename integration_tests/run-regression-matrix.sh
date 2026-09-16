#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
report_dir=${REGRESSION_ARTIFACT_DIR:-$script_dir/artifacts/regression-$(date -u +%Y%m%dT%H%M%SZ)-$$}
lanes=("$@")
if (( ${#lanes[@]} == 0 )); then
	lanes=(ownership systemd opensuse rocky fedora openrc runit upstart openwrt yocto buildroot-baseline buildroot-debug buildroot-release freebsd)
fi

for lane in "${lanes[@]}"; do
	case "$lane" in
		ownership|systemd|opensuse|rocky|fedora|openrc|runit|upstart|openwrt|yocto|buildroot-baseline|buildroot-debug|buildroot-release|freebsd) ;;
		*) printf 'Unknown regression lane: %s\n' "$lane" >&2; exit 2 ;;
	esac
done

mkdir -p "$report_dir"
printf 'lane\tstatus\texit_code\tduration_seconds\n' >"$report_dir/results.tsv"
printf 'Regression artifacts: %s\n' "$report_dir"

run_lane() {
	local lane=$1
	export INTEGRATION_ARTIFACT_DIR="$report_dir/$lane"
	case "$lane" in
		ownership) OWNERSHIP_ARTIFACT_DIR="$report_dir/ownership" bash "$script_dir/libvirt-ownership-test.sh" ;;
		runit|yocto) bash "$script_dir/$lane/run-qemu.sh" ;;
		buildroot-*) BUILDROOT_PROFILE=${lane#buildroot-} bash "$script_dir/buildroot/run-libvirt.sh" ;;
		*) bash "$script_dir/$lane/run-libvirt.sh" ;;
	esac
}

failed=0
for lane in "${lanes[@]}"; do
	printf '\n=== %s ===\n' "$lane"
	started=$SECONDS
	if run_lane "$lane" 2>&1 | tee "$report_dir/$lane.log"; then
		status=PASS
		code=0
	else
		codes=("${PIPESTATUS[@]}")
		code=${codes[0]}
		(( code != 0 )) || code=${codes[1]}
		status=FAIL
		failed=1
	fi
	printf '%s\t%s\t%s\t%s\n' "$lane" "$status" "$code" "$((SECONDS - started))" >>"$report_dir/results.tsv"
done

printf '\n=== Regression summary ===\n'
cat "$report_dir/results.tsv"
exit "$failed"
