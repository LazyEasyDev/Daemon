#!/usr/bin/env bash

set -Eeuo pipefail

phase=${1:-}
service_name=${2:-}
port=${3:-18080}
install_dir=${DAEMON_ITEST_INSTALL_DIR:-/opt/daemon-itest}
daemon_bin="$install_dir/daemon"
app_bin="$install_dir/test-app"
unit_name="lz_lz_${service_name}.service"
unit_path="/etc/systemd/system/$unit_name"
metadata_path="/var/lib/daemon-util/services/lz_lz_${service_name}.json"
state_dir="/var/tmp/daemon-itest-$service_name"
artifact_dir="$state_dir/artifacts"
fixture_path="$install_dir/relative-path-test.txt"
current_scenario=initialization
expect_selinux=${DAEMON_ITEST_EXPECT_SELINUX:-0}
temporary_app=${DAEMON_ITEST_TEMP_APP:-/tmp/test-app}
warning_service_name="${service_name}warning"
warning_unit_path="/etc/systemd/system/lz_lz_${warning_service_name}.service"
warning_metadata_path="/var/lib/daemon-util/services/lz_lz_${warning_service_name}.json"
long_service_name=$(printf 'n%0239d' 0)

log() {
	printf '[systemd-itest] %s\n' "$*"
}

fail() {
	printf '[systemd-itest] ERROR: %s\n' "$*" >&2
	return 1
}

assert_contains() {
	local value=$1
	local expected=$2
	local description=$3
	if [[ "$value" != *"$expected"* ]]; then
		fail "$description: expected output to contain '$expected', got '$value'"
	fi
}

assert_file_contains() {
	local path=$1
	local expected=$2
	if ! grep -Fq -- "$expected" "$path"; then
		fail "$path does not contain '$expected'"
	fi
}

process_is_test_app() {
	local pid=$1 executable
	[[ -e "/proc/$pid/exe" ]] || return 1
	executable=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
	[[ "$executable" == "$app_bin" || "$executable" == "$app_bin (deleted)" ]]
}

wait_process_gone() {
	local pid=$1
	local deadline=$((SECONDS + 15))
	while process_is_test_app "$pid"; do
		if (( SECONDS >= deadline )); then
			fail "test application process $pid is still running"
		fi
		sleep 0.2
	done
}

assert_no_test_app_processes() {
	local process executable
	for process in /proc/[0-9]*; do
		executable=$(readlink "$process/exe" 2>/dev/null || true)
		if [[ "$executable" == "$app_bin" || "$executable" == "$app_bin (deleted)" ]]; then
			fail "test application process ${process##*/} leaked after cleanup"
		fi
	done
}

assert_selinux_enforcing() {
	[[ "$expect_selinux" == 1 ]] || return 0
	command -v getenforce >/dev/null || fail "getenforce is required for the SELinux lane"
	[[ -r /sys/fs/selinux/enforce ]] || fail "SELinux enforce state is unavailable"
	[[ "$(tr -d '[:space:]' </sys/fs/selinux/enforce)" == 1 ]] || fail "SELinux kernel enforcement is disabled"
	[[ "$(getenforce)" == Enforcing ]] || fail "SELinux is not enforcing"
}

verify_selinux_warning() {
	[[ "$expect_selinux" == 1 ]] || return 0
	local output status
	[[ -x "$temporary_app" ]] || fail "missing temporary test application at $temporary_app"
	rm -f "$warning_unit_path" "$warning_metadata_path"
	set +e
	output=$("$daemon_bin" install "$warning_service_name" "$temporary_app" 2>&1)
	status=$?
	set -e
	printf '%s\n' "$output" >"$artifact_dir/selinux-warning.txt"
	(( status != 0 )) || fail "SELinux-risky temporary executable installed without confirmation"
	assert_contains "$output" "Warning: SELinux may prevent this system service from starting" "SELinux warning"
	assert_contains "$output" "$temporary_app" "SELinux warning executable"
	assert_contains "$output" "requires a terminal" "noninteractive warning refusal"
	assert_contains "$output" "--ignore-warnings" "warning bypass guidance"
	[[ ! -e "$warning_unit_path" ]] || fail "warning-only install created a systemd unit"
	[[ ! -e "$warning_metadata_path" ]] || fail "warning-only install created metadata"
}

assert_selinux_path_labeled() {
	local path=$1 context
	[[ "$expect_selinux" == 1 ]] || return 0
	context=$(ls -Zd -- "$path" 2>&1) || fail "could not read SELinux context for $path"
	[[ "$context" != *unlabeled_t* && "$context" != "? "* ]] || fail "invalid SELinux context for $path: $context"
	matchpathcon -V "$path" >/dev/null || fail "SELinux context does not match policy for $path"
}

verify_selinux_file_contexts() {
	[[ "$expect_selinux" == 1 ]] || return 0
	assert_selinux_path_labeled "$daemon_bin"
	assert_selinux_path_labeled "$app_bin"
	assert_selinux_path_labeled "$unit_path"
	assert_selinux_path_labeled "$metadata_path"
}

verify_selinux_runtime_context() {
	[[ "$expect_selinux" == 1 ]] || return 0
	local pid context
	pid=$(http_pid)
	context=$(tr -d '\000' <"/proc/$pid/attr/current" 2>/dev/null || true)
	[[ -n "$context" ]] || fail "test application PID $pid has no SELinux runtime context"
	[[ "$context" != *unlabeled_t* ]] || fail "test application PID $pid is unlabeled: $context"
}

assert_no_relevant_avc_denials() {
	[[ "$expect_selinux" == 1 ]] || return 0
	local patterns="test-app|daemon-itest|lz_lz_${service_name}" journal_denials audit_denials denials
	journal_denials=$(journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'avc:.*denied' | grep -Ei "$patterns" || true)
	audit_denials=
	if command -v ausearch >/dev/null; then
		audit_denials=$(timeout --kill-after=2s 5s ausearch -m AVC,USER_AVC -ts boot 2>/dev/null | grep -Ei "$patterns" || true)
	fi
	denials="${journal_denials}${audit_denials}"
	[[ -z "$denials" ]] || fail "service-specific SELinux AVC denial detected: $denials"
}

wait_for_http() {
	local expect_child=${1:-false}
	local deadline=$((SECONDS + 30)) response
	while (( SECONDS < deadline )); do
		if response=$(http_response 2>/dev/null); then
			assert_contains "$response" "\"executable\": \"$app_bin\"" "HTTP executable"
			assert_contains "$response" '"file_content": "daemon-util relative path test passed\n"' "HTTP fixture"
			assert_contains "$response" '"enabled": true' "HTTP boolean argument"
			assert_contains "$response" '"message": "hello systemd"' "HTTP string argument"
			assert_contains "$response" '"count": 7' "HTTP integer argument"
			assert_contains "$response" "\"port\": $port" "HTTP port argument"
			assert_contains "$response" '"hello systemd"' "HTTP argument vector"
			assert_contains "$response" '"relative-path-test.txt"' "HTTP relative-path argument"
			if [[ "$expect_child" == true ]]; then
				grep -Eq '^[[:space:]]*"child_pid":[[:space:]]*[1-9][0-9]*,*$' <<<"$response" || fail "HTTP child PID is missing: $response"
			fi
			printf '%s\n' "$response"
			return
		fi
		sleep 0.2
	done
	fail "HTTP application did not become ready"
}

http_response() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsS --max-time 2 "http://127.0.0.1:$port/"
	else
		wget -qO- -T 2 "http://127.0.0.1:$port/"
	fi
}

http_pid() {
	http_response 2>/dev/null | sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\),*$/\1/p'
}

wait_for_new_http_pid() {
	local old_pid=$1
	local timeout_seconds=$2
	local deadline=$((SECONDS + timeout_seconds)) new_pid
	while (( SECONDS < deadline )); do
		new_pid=$(http_pid || true)
		if [[ -n "$new_pid" && "$new_pid" != "$old_pid" ]]; then
			printf '%s\n' "$new_pid"
			return
		fi
		sleep 0.2
	done
	fail "application did not restart from PID $old_pid"
}

assert_event() {
	local path=$1
	local expected=$2
	grep -Fq "\"event\":\"$expected\"" "$path" || fail "event '$expected' not found in $path"
}

event_count() {
	local path=$1
	local expected=$2
	grep -Fc "\"event\":\"$expected\"" "$path" || true
}

collect_artifacts() {
	local label=${1:-$current_scenario}
	mkdir -p "$artifact_dir"
	{
		printf 'phase=%s\nscenario=%s\nservice=%s\n' "$phase" "$current_scenario" "$service_name"
		uname -a
		printf '\nOperating system:\n'
		cat /etc/os-release 2>/dev/null || true
		if [[ -f /etc/armbian-release ]]; then
			printf '\nArmbian release:\n'
			cat /etc/armbian-release
		fi
		if [[ -f /etc/daemon-itest-image-source ]]; then
			printf '\nImage source:\n'
			cat /etc/daemon-itest-image-source
		fi
		printf '\nPID 1:\n'
		ps -p 1 -o pid=,comm=,args=
		printf '\nsystemd:\n'
		systemctl --version
	} >"$artifact_dir/${label}-environment.txt" 2>&1 || true
	systemctl status "$unit_name" --no-pager >"$artifact_dir/${label}-status.txt" 2>&1 || true
	systemctl show "$unit_name" --no-pager >"$artifact_dir/${label}-show.txt" 2>&1 || true
	systemctl cat "$unit_name" --no-pager >"$artifact_dir/${label}-unit.txt" 2>&1 || true
	journalctl -u "$unit_name" --no-pager >"$artifact_dir/${label}-journal.txt" 2>&1 || true
	if [[ -f "/etc/systemd/system/lz_lz_${long_service_name}.service" ]]; then
		systemctl status "lz_lz_${long_service_name}.service" --no-pager -l >"$artifact_dir/${label}-maximum-name-status.txt" 2>&1 || true
		systemctl cat "lz_lz_${long_service_name}.service" --no-pager >"$artifact_dir/${label}-maximum-name-unit.txt" 2>&1 || true
		journalctl -u "lz_lz_${long_service_name}.service" --no-pager >"$artifact_dir/${label}-maximum-name-journal.txt" 2>&1 || true
	fi
	ps -ef >"$artifact_dir/${label}-processes.txt" 2>&1 || true
	if [[ "$expect_selinux" == 1 ]]; then
		{
			getenforce
			sestatus
			printf '\nFile contexts:\n'
			ls -lZd "$install_dir" "$daemon_bin" "$app_bin" "$unit_path" "$metadata_path" 2>&1 || true
			printf '\nExpected contexts:\n'
			matchpathcon -V "$daemon_bin" "$app_bin" "$unit_path" "$metadata_path" 2>&1 || true
		} >"$artifact_dir/${label}-selinux.txt" 2>&1 || true
		ps -eZ >"$artifact_dir/${label}-selinux-processes.txt" 2>&1 || true
		journalctl -k -b --no-pager | grep -Ei 'avc:|selinux' >"$artifact_dir/${label}-selinux-kernel.txt" 2>&1 || true
		timeout --kill-after=2s 5s ausearch -m AVC,USER_AVC -ts boot >"$artifact_dir/${label}-selinux-audit.txt" 2>&1 || true
	fi
	cp -f "$install_dir"/*-events.jsonl "$artifact_dir/" 2>/dev/null || true
	cp -f "$state_dir"/*.json "$state_dir"/*.pid "$artifact_dir/" 2>/dev/null || true
	chmod -R a+rX "$artifact_dir" 2>/dev/null || true
}

cleanup_service() {
	if [[ -f "/etc/systemd/system/lz_lz_${long_service_name}.service" ]]; then
		"$daemon_bin" remove "$long_service_name" >/dev/null 2>&1 || true
	fi
	if [[ -f "$unit_path" ]]; then
		"$daemon_bin" remove "$service_name" >/dev/null 2>&1 || {
			systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
			rm -f "$unit_path"
			systemctl daemon-reload >/dev/null 2>&1 || true
		}
	fi
	rm -f "$metadata_path"
	if [[ "$expect_selinux" == 1 ]]; then
		systemctl disable --now "lz_lz_${warning_service_name}.service" >/dev/null 2>&1 || true
		rm -f "$warning_unit_path" "$warning_metadata_path"
		systemctl daemon-reload >/dev/null 2>&1 || true
	fi
}

on_exit() {
	local status=$?
	trap - EXIT
	if (( status != 0 )); then
		collect_artifacts failure
		cleanup_service
	fi
	exit "$status"
}
trap on_exit EXIT

require_environment() {
	[[ $(id -u) -eq 0 ]] || fail "guest test must run as root"
	[[ -x "$daemon_bin" ]] || fail "missing daemon binary at $daemon_bin"
	[[ -x "$app_bin" ]] || fail "missing test application at $app_bin"
	[[ -f "$fixture_path" ]] || fail "missing relative-path fixture at $fixture_path"
	[[ "$(ps -p 1 -o comm= | tr -d '[:space:]')" == systemd ]] || fail "systemd is not PID 1"
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "curl or wget is required in the guest"
	if [[ "$expect_selinux" == 1 ]]; then
		command -v matchpathcon >/dev/null || fail "matchpathcon is required for the SELinux lane"
		command -v timeout >/dev/null || fail "timeout is required for the SELinux lane"
		assert_selinux_enforcing
	fi
	mkdir -p "$state_dir" "$artifact_dir"
}

install_scenario() {
	local timeout=$1
	local events=$2
	local install_flags=(--ignore-warnings)
	shift 2
	if [[ "$expect_selinux" == 1 ]]; then
		install_flags=()
	fi
	rm -f "$events" "$install_dir/child.pid"
	"$daemon_bin" install --stop-timeout "$timeout" "${install_flags[@]}" \
		"$service_name" "$app_bin" \
		--enabled=true \
		--message "hello systemd" \
		--count 7 \
		--port "$port" \
		--file-path relative-path-test.txt \
		--event-path "$events" \
		"$@"
}

verify_definition() {
	[[ -f "$unit_path" ]] || fail "systemd unit was not created"
	assert_file_contains "$unit_path" 'Type=exec'
	assert_file_contains "$unit_path" "ExecStart=\"$app_bin\""
	assert_file_contains "$unit_path" "WorkingDirectory=$install_dir"
	assert_file_contains "$unit_path" 'Restart=on-failure'
	assert_file_contains "$unit_path" 'RestartPreventExitStatus=203'
	assert_file_contains "$unit_path" 'RestartSec=20s'
	assert_file_contains "$unit_path" 'KillMode=control-group'
	[[ "$(systemctl is-enabled "$unit_name")" == enabled ]] || fail "systemd unit is not enabled"
	verify_selinux_file_contexts
}

verify_management_commands() {
	local output
	output=$("$daemon_bin" status "$service_name")
	assert_contains "$output" 'running' 'status command'
	output=$("$daemon_bin" list)
	assert_contains "$output" "$service_name" 'list command'
	assert_contains "$output" "$app_bin" 'list command application path'
	output=$("$daemon_bin" list -l)
	assert_contains "$output" 'hello systemd' 'long list arguments'
}

wait_for_managed_pid() {
	local pid_file=$1
	local deadline=$((SECONDS + 20)) pid
	while (( SECONDS < deadline )); do
		pid=$(cat "$pid_file" 2>/dev/null || true)
		if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
			printf '%s\n' "$pid"
			return
		fi
		sleep 0.2
	done
	fail "interpreted application did not write a live PID to $pid_file"
}

wait_for_managed_pid_gone() {
	local pid=$1
	local deadline=$((SECONDS + 20))
	while kill -0 "$pid" 2>/dev/null; do
		if (( SECONDS >= deadline )); then
			fail "interpreted application PID $pid is still running"
		fi
		sleep 0.2
	done
}

verify_maximum_service_name() {
	local long_unit="lz_lz_${long_service_name}.service"
	local long_unit_path="/etc/systemd/system/$long_unit"
	local long_metadata="/var/lib/daemon-util/services/lz_lz_${long_service_name}.json"
	local pid output

	[[ ${#long_service_name} == 240 && ${#long_unit} == 254 ]] || fail 'maximum-name test has the wrong boundary'
	if output=$("$daemon_bin" install --ignore-warnings "${long_service_name}a" "$app_bin" 2>&1); then
		fail 'systemd accepted a 255-byte unit name that journald cannot handle'
	fi
	assert_contains "$output" 'systemd service names must not exceed 240 characters' 'systemd native name-limit error'
	[[ ! -e "/etc/systemd/system/lz_lz_${long_service_name}a.service" ]] || fail 'rejected name created a unit'
	[[ ! -e "/var/lib/daemon-util/services/lz_lz_${long_service_name}a.json" ]] || fail 'rejected name created metadata'
	printf '%s\n' "$output" >"$artifact_dir/maximum-name-rejection.txt"
	"$daemon_bin" install --ignore-warnings --stop-timeout 5s "$long_service_name" "$app_bin" \
		--enabled=true --message 'hello systemd' --count 7 --port "$port" \
		--file-path relative-path-test.txt
	[[ -f "$long_unit_path" ]] || fail 'maximum-length unit was not written'
	assert_file_contains "$long_metadata" "\"application_path\":\"$app_bin\""
	assert_file_contains "$long_metadata" '"arguments":"--enabled=true --message hello systemd --count 7'
	assert_file_contains "$long_metadata" '"stop_timeout_seconds":5'
	[[ "$(systemctl is-enabled "$long_unit")" == enabled ]] || fail 'maximum-length unit is not enabled'
	"$daemon_bin" start "$long_service_name"
	wait_for_http false >"$artifact_dir/maximum-name-http.json"
	pid=$(http_pid)
	[[ "$(systemctl is-active "$long_unit")" == active ]] || fail 'maximum-length unit is not active'
	output=$("$daemon_bin" status "$long_service_name")
	assert_contains "$output" running 'maximum-length service status'
	output=$("$daemon_bin" list -l)
	printf '%s\n' "$output" >"$artifact_dir/maximum-name-list.txt"
	assert_contains "$output" "$long_service_name" 'maximum-length service listing'
	assert_contains "$output" "$app_bin" 'maximum-length metadata application'
	assert_contains "$output" 'hello systemd' 'maximum-length metadata arguments'
	"$daemon_bin" stop "$long_service_name"
	wait_process_gone "$pid"
	"$daemon_bin" remove "$long_service_name"
	[[ ! -e "$long_unit_path" && ! -e "$long_metadata" ]] || fail 'maximum-length service files remain'
	[[ ! -L "/etc/systemd/system/multi-user.target.wants/$long_unit" ]] || fail 'maximum-length enablement remains'
	printf '%s\n' 'PASS: 240-character systemd lifecycle and safe rejection at 241' >"$artifact_dir/maximum-name-result.txt"
}

verify_native_symlink_application() {
	local auxiliary_name="${service_name}symlinkapp"
	local auxiliary_unit="/etc/systemd/system/lz_lz_${auxiliary_name}.service"
	local auxiliary_metadata="/var/lib/daemon-util/services/lz_lz_${auxiliary_name}.json"
	local application_link="$install_dir/test-app-symlink"
	local events="$artifact_dir/symlink-application.events.jsonl"
	local pid output

	ln -sfn "$app_bin" "$application_link"
	rm -f "$events"
	"$daemon_bin" install --ignore-warnings "$auxiliary_name" "$application_link" \
		--enabled=true --message 'hello systemd' --count 7 --port "$port" \
		--file-path relative-path-test.txt --event-path "$events"
	[[ -f "$auxiliary_unit" ]] || fail "symlink application unit was not created"
	assert_file_contains "$auxiliary_unit" "ExecStart=\"$app_bin\""
	"$daemon_bin" start "$auxiliary_name"
	wait_for_http false >"$artifact_dir/symlink-application-http.json"
	pid=$(http_pid)
	output=$("$daemon_bin" status "$auxiliary_name")
	assert_contains "$output" running 'symlink application status'
	output=$("$daemon_bin" list)
	assert_contains "$output" "$app_bin" 'symlink application resolved path listing'
	"$daemon_bin" stop "$auxiliary_name"
	wait_process_gone "$pid"
	"$daemon_bin" remove "$auxiliary_name"
	[[ ! -e "$auxiliary_unit" ]] || fail "symlink application unit remains after removal"
	[[ ! -e "$auxiliary_metadata" ]] || fail "symlink application metadata remains after removal"
	rm -f "$application_link"
}

verify_interpreted_application() {
	local label=$1 interpreter=$2 script=$3
	local auxiliary_name="${service_name}${label}"
	local auxiliary_unit="/etc/systemd/system/lz_lz_${auxiliary_name}.service"
	local auxiliary_metadata="/var/lib/daemon-util/services/lz_lz_${auxiliary_name}.json"
	local interpreter_link="$install_dir/${label}-interpreter"
	local state_prefix="$artifact_dir/${label}-application"
	local resolved_interpreter pid output

	resolved_interpreter=$(readlink -f "$interpreter")
	ln -sfn "$resolved_interpreter" "$interpreter_link"
	rm -f "$state_prefix.pid" "$state_prefix.events"
	"$daemon_bin" install --ignore-warnings "$auxiliary_name" "$interpreter_link" "$script" "$state_prefix"
	[[ -f "$auxiliary_unit" ]] || fail "$label application unit was not created"
	assert_file_contains "$auxiliary_unit" "ExecStart=\"$resolved_interpreter\""
	assert_file_contains "$auxiliary_unit" "$script"
	"$daemon_bin" start "$auxiliary_name"
	pid=$(wait_for_managed_pid "$state_prefix.pid")
	output=$("$daemon_bin" status "$auxiliary_name")
	assert_contains "$output" running "$label application status"
	output=$("$daemon_bin" list -l)
	assert_contains "$output" "$script" "$label application argument listing"
	"$daemon_bin" stop "$auxiliary_name"
	wait_for_managed_pid_gone "$pid"
	assert_file_contains "$state_prefix.events" stopped
	"$daemon_bin" remove "$auxiliary_name"
	[[ ! -e "$auxiliary_unit" ]] || fail "$label application unit remains after removal"
	[[ ! -e "$auxiliary_metadata" ]] || fail "$label application metadata remains after removal"
	rm -f "$interpreter_link"
}

verify_script_applications() {
	local shell_script="$install_dir/shell-application.sh"
	local python_script="$install_dir/python-application.py"
	local rejected_name="${service_name}directscript"
	local rejected_unit="/etc/systemd/system/lz_lz_${rejected_name}.service"
	local rejected_metadata="/var/lib/daemon-util/services/lz_lz_${rejected_name}.json"
	local output status

	printf '%s\n' \
		'#!/bin/sh' \
		'state=$1' \
		'printf "%s\\n" "$$" >"$state.pid"' \
		'printf "%s\\n" started >>"$state.events"' \
		'trap '\''printf "%s\\n" stopped >>"$state.events"; exit 0'\'' TERM INT' \
		'while :; do sleep 1; done' >"$shell_script"
	chmod 0755 "$shell_script"

	set +e
	output=$("$daemon_bin" install --ignore-warnings "$rejected_name" "$shell_script" 2>&1)
	status=$?
	set -e
	(( status != 0 )) || fail "direct shell script was accepted as a native executable"
	printf '%s\n' "$output" >"$artifact_dir/direct-script-rejection.txt"
	[[ ! -e "$rejected_unit" ]] || fail "rejected direct script created a systemd unit"
	[[ ! -e "$rejected_metadata" ]] || fail "rejected direct script created metadata"

	verify_native_symlink_application
	verify_interpreted_application shell /bin/sh "$shell_script"

	if command -v python3 >/dev/null 2>&1; then
		printf '%s\n' \
			'import os' \
			'import signal' \
			'import sys' \
			'import time' \
			'state = sys.argv[1]' \
			'open(state + ".pid", "w").write(str(os.getpid()))' \
			'open(state + ".events", "a").write("started\\n")' \
			'def stop(_signal, _frame):' \
			'    open(state + ".events", "a").write("stopped\\n")' \
			'    raise SystemExit(0)' \
			'signal.signal(signal.SIGTERM, stop)' \
			'signal.signal(signal.SIGINT, stop)' \
			'while True:' \
			'    time.sleep(1)' >"$python_script"
		chmod 0644 "$python_script"
		verify_interpreted_application python "$(command -v python3)" "$python_script"
	else
		printf '%s\n' 'SKIP: python3 is not installed in this guest' >"$artifact_dir/python-application-skip.txt"
	fi
}

pre_reboot() {
	local events="$install_dir/boot-events.jsonl"
	local child_pid
	current_scenario=pre-reboot
	log "installing boot-persistence scenario"
	cleanup_service
	verify_selinux_warning
	install_scenario 5s "$events" \
		--stop_delay 1s \
		--spawn-child=true \
		--child-pid-path child.pid
	verify_definition
	assert_file_contains "$unit_path" 'TimeoutStopSec=5s'
	"$daemon_bin" start "$service_name"
	wait_for_http true >"$state_dir/pre-reboot-http.json"
	verify_selinux_runtime_context
	verify_management_commands
	child_pid=$(cat "$install_dir/child.pid")
	process_is_test_app "$child_pid" || fail "child process $child_pid is not running"
	http_pid >"$state_dir/pre-reboot-parent.pid"
	collect_artifacts pre-reboot
	log "pre-reboot checks passed"
}

post_reboot() {
	local boot_events="$install_dir/boot-events.jsonl"
	local restart_parent restart_child new_parent hard_crash_parent
	local hot_parent hot_child hot_new_parent replacement
	local graceful_started graceful_elapsed
	local auto_events="$install_dir/restart-events.jsonl"
	local forced_events="$install_dir/forced-events.jsonl"
	local forced_child forced_started forced_elapsed

	current_scenario=post-reboot
	log "verifying boot persistence"
	[[ "$(systemctl is-enabled "$unit_name")" == enabled ]] || fail "service lost enablement after reboot"
	wait_for_http true >"$state_dir/post-reboot-http.json"
	verify_selinux_runtime_context
	(( $(event_count "$boot_events" started) >= 2 )) || fail "service did not record a second startup after reboot"
	verify_management_commands

	current_scenario=explicit-restart
	restart_parent=$(http_pid)
	restart_child=$(cat "$install_dir/child.pid")
	"$daemon_bin" restart "$service_name"
	new_parent=$(wait_for_new_http_pid "$restart_parent" 20)
	[[ "$new_parent" != "$restart_parent" ]] || fail "restart reused parent PID $restart_parent"
	wait_for_http true >"$state_dir/restart-http.json"
	wait_process_gone "$restart_parent"
	wait_process_gone "$restart_child"
	assert_event "$boot_events" signal
	assert_event "$boot_events" stopped

	current_scenario=hot-replacement
	log "verifying status, list, and stop after atomic executable replacement"
	hot_parent=$(http_pid)
	hot_child=$(cat "$install_dir/child.pid")
	replacement="$install_dir/.test-app.replacement.$$"
	cp -p "$app_bin" "$replacement"
	mv -f "$replacement" "$app_bin"
	[[ "$(readlink "/proc/$hot_parent/exe" 2>/dev/null || true)" == "$app_bin (deleted)" ]] || fail "running executable was not atomically replaced"
	sleep 2
	[[ "$(http_pid)" == "$hot_parent" ]] || fail "systemd restarted the application after hot replacement"
	verify_management_commands
	[[ "$(systemctl is-active "$unit_name")" == active ]] || fail "systemd unit is not active after hot replacement"
	"$daemon_bin" stop "$service_name"
	wait_process_gone "$hot_parent"
	wait_process_gone "$hot_child"
	[[ "$(systemctl is-active "$unit_name" 2>/dev/null || true)" == inactive ]] || fail "systemd unit is not inactive after hot-replacement stop"
	"$daemon_bin" start "$service_name"
	wait_for_http true >"$state_dir/hot-replacement-http.json"
	hot_new_parent=$(http_pid)
	[[ "$hot_new_parent" != "$hot_parent" ]] || fail "hot-replacement restart reused PID $hot_parent"
	verify_management_commands

	current_scenario=graceful-stop
	graceful_started=$(date +%s)
	"$daemon_bin" stop "$service_name"
	graceful_elapsed=$(($(date +%s) - graceful_started))
	(( graceful_elapsed >= 1 )) || fail "graceful stop returned before the configured one-second delay"
	(( graceful_elapsed < 10 )) || fail "graceful stop took ${graceful_elapsed}s"
	assert_event "$boot_events" stopped
	[[ "$(systemctl is-active "$unit_name" 2>/dev/null || true)" == inactive ]] || fail "service is not inactive after graceful stop"
	"$daemon_bin" remove "$service_name"
	[[ ! -e "$unit_path" ]] || fail "unit remains after graceful scenario removal"

	current_scenario=automatic-restart
	log "verifying restart after application failure"
	install_scenario 5s "$auto_events" --stop-after 5s
	"$daemon_bin" start "$service_name"
	wait_for_http false >"$state_dir/automatic-restart-first-http.json"
	restart_parent=$(http_pid)
	new_parent=$(wait_for_new_http_pid "$restart_parent" 300)
	[[ "$new_parent" != "$restart_parent" ]] || fail "automatic restart reused parent PID $restart_parent"
	(( $(event_count "$auto_events" started) >= 2 )) || fail "automatic restart did not record a second startup"
	assert_event "$auto_events" failure
	kill -KILL "$new_parent"
	hard_crash_parent=$(wait_for_new_http_pid "$new_parent" 300)
	wait_process_gone "$new_parent"
	[[ "$hard_crash_parent" != "$new_parent" ]] || fail "hard-crash restart reused parent PID $new_parent"
	(( $(event_count "$auto_events" started) >= 3 )) || fail "hard crash did not record a third startup"
	verify_management_commands
	verify_selinux_runtime_context
	"$daemon_bin" stop "$service_name"
	"$daemon_bin" remove "$service_name"

	current_scenario=forced-stop
	log "verifying timeout escalation and cgroup cleanup"
	install_scenario 2s "$forced_events" \
		--stop_delay 30s \
		--spawn-child=true \
		--child-pid-path child.pid
	assert_file_contains "$unit_path" 'TimeoutStopSec=2s'
	"$daemon_bin" start "$service_name"
	wait_for_http true >"$state_dir/forced-stop-http.json"
	verify_selinux_runtime_context
	forced_child=$(cat "$install_dir/child.pid")
	forced_started=$(date +%s)
	"$daemon_bin" stop "$service_name"
	forced_elapsed=$(($(date +%s) - forced_started))
	(( forced_elapsed >= 2 )) || fail "forced stop returned before the configured timeout"
	(( forced_elapsed < 15 )) || fail "forced stop took ${forced_elapsed}s"
	assert_event "$forced_events" signal
	if grep -Fq '"event":"stopped"' "$forced_events"; then
		fail "application reported graceful completion despite forced termination"
	fi
	wait_process_gone "$forced_child"
	assert_no_test_app_processes
	"$daemon_bin" remove "$service_name"

	current_scenario=maximum-service-name
	log 'verifying the systemd service-name and metadata boundary'
	verify_maximum_service_name

	current_scenario=script-applications
	log "verifying symlinked, shell, Python, and rejected direct-script applications"
	verify_script_applications

	current_scenario=cleanup
	collect_artifacts success
	[[ ! -e "$unit_path" ]] || fail "unit remains after final removal"
	[[ ! -e "$metadata_path" ]] || fail "metadata remains after final removal"
	if find /etc/systemd/system -type l -lname "$unit_path" -print -quit | grep -q .; then
		fail "systemd enablement link remains after final removal"
	fi
	assert_no_test_app_processes
	assert_no_relevant_avc_denials
	log "all systemd application-level tests passed"
}

require_environment
case "$phase" in
	pre-reboot)
		[[ -n "$service_name" ]] || fail "service name is required"
		pre_reboot
		;;
	post-reboot)
		[[ -n "$service_name" ]] || fail "service name is required"
		post_reboot
		;;
	cleanup)
		cleanup_service
		;;
	*)
		fail "usage: $0 {pre-reboot|post-reboot|cleanup} SERVICE_NAME [PORT]"
		;;
esac
