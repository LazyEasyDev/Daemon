#!/usr/bin/env bash

set -Eeuo pipefail

phase=${1:-}
service_name=${2:-}
port=${3:-18080}
install_dir=/opt/daemon-itest
daemon_bin="$install_dir/daemon"
app_bin="$install_dir/test-app"
registration_name="lz_lz_${service_name}"
service_dir="/etc/sv/$registration_name"
enabled_path="/var/service/$registration_name"
metadata_path="/var/lib/daemon-util/services/${registration_name}.json"
state_dir="/var/tmp/daemon-itest-$service_name"
artifact_dir="$state_dir/artifacts"
fixture_path="$install_dir/relative-path-test.txt"
interpreted_test="$install_dir/interpreted-app-test.sh"
current_scenario=initialization
respawn_name="${service_name}downrespawn"
respawn_dir="/etc/sv/lz_lz_${respawn_name}"
respawn_enabled="/var/service/lz_lz_${respawn_name}"
respawn_events="$install_dir/downrespawn-events.jsonl"
paused_runsv_pid=

log() {
	printf '[runit-itest] %s\n' "$*"
}

fail() {
	printf '[runit-itest] ERROR: %s\n' "$*" >&2
	return 1
}

. "$interpreted_test"

interpreted_definition_path() {
	printf '/etc/sv/lz_lz_%s/run\n' "$1"
}

interpreted_removed() {
	local auxiliary=$1 registration="lz_lz_$1"
	[[ ! -e "/etc/sv/$registration" ]] || fail "auxiliary runit service remains: $registration"
	[[ ! -L "/var/service/$registration" ]] || fail "auxiliary runit enablement remains: $registration"
	[[ ! -e "/var/lib/daemon-util/services/${registration}.json" ]] || fail "auxiliary metadata remains: $auxiliary"
}

assert_contains() {
	local value=$1 expected=$2 description=$3
	[[ "$value" == *"$expected"* ]] || fail "$description: expected output to contain '$expected', got '$value'"
}

assert_file_contains() {
	local path=$1 expected=$2
	grep -Fq -- "$expected" "$path" || fail "$path does not contain '$expected'"
}

process_is_test_app() {
	local pid=$1 executable
	[[ -e "/proc/$pid/exe" ]] || return 1
	executable=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
	[[ "$executable" == "$app_bin" || "$executable" == "$app_bin (deleted)" ]]
}

wait_process_gone() {
	local pid=$1 deadline=$((SECONDS + 15))
	while process_is_test_app "$pid"; do
		(( SECONDS < deadline )) || fail "test application process $pid is still running"
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

http_body() {
	timeout 3 bash -c '
		exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
		printf "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3
		while IFS= read -r line <&3; do
			[ "$line" = "$(printf "\r")" ] && break
		done
		cat <&3
	' bash "$port"
}

wait_for_http() {
	local expect_child=${1:-false} deadline=$((SECONDS + 30)) output
	while (( SECONDS < deadline )); do
		if output=$(http_body 2>/dev/null) &&
			grep -Fq "\"executable\": \"$app_bin\"" <<<"$output" &&
			grep -Fq 'daemon-util relative path test passed' <<<"$output" &&
			grep -Fq '"enabled": true' <<<"$output" &&
			grep -Fq '"message": "hello runit"' <<<"$output" &&
			grep -Fq "\"port\": $port" <<<"$output"; then
			if [[ "$expect_child" == true ]]; then
				grep -Eq '"child_pid": [1-9][0-9]*' <<<"$output" || {
					sleep 0.2
					continue
				}
			fi
			printf '%s\n' "$output"
			return
		fi
		sleep 0.2
	done
	fail 'HTTP application did not become ready'
}

http_pid() {
	http_body | sed -n 's/^[[:space:]]*"pid":[[:space:]]*\([0-9][0-9]*\),*$/\1/p'
}

wait_for_new_http_pid() {
	local old_pid=$1 timeout_seconds=$2 new_pid
	local deadline=$((SECONDS + timeout_seconds))
	while (( SECONDS < deadline )); do
		new_pid=$(http_pid 2>/dev/null || true)
		if [[ -n "$new_pid" && "$new_pid" != "$old_pid" ]]; then
			printf '%s\n' "$new_pid"
			return
		fi
		sleep 0.2
	done
	fail "application did not restart from PID $old_pid"
}

event_count() {
	local path=$1 expected=$2
	grep -Fc "\"event\":\"$expected\"" "$path" 2>/dev/null || true
}

assert_event() {
	local path=$1 expected=$2
	grep -Fq "\"event\":\"$expected\"" "$path" || fail "event '$expected' not found in $path"
}

collect_artifacts() {
	local label=${1:-$current_scenario}
	mkdir -p "$artifact_dir"
	{
		printf 'phase=%s\nscenario=%s\nservice=%s\n' "$phase" "$current_scenario" "$service_name"
		printf '\nOS release:\n'
		cat /etc/os-release
		uname -a
		printf '\nPID 1:\n'
		readlink /proc/1/exe
		printf '\nPackages:\n'
		xbps-query -l | grep -E 'runit|runit-void' || true
	} >"$artifact_dir/${label}-environment.txt" 2>&1 || true
	sv status "$enabled_path" >"$artifact_dir/${label}-status.txt" 2>&1 || true
	"$daemon_bin" list >"$artifact_dir/${label}-list.txt" 2>&1 || true
	find /etc/sv /etc/runit/runsvdir/default /run/runit/runsvdir/current -maxdepth 2 -ls >"$artifact_dir/${label}-runit-tree.txt" 2>&1 || true
	ps -ef >"$artifact_dir/${label}-processes.txt" 2>&1 || true
	cp -f "$install_dir"/*-events.jsonl "$artifact_dir/" 2>/dev/null || true
	cp -f "$state_dir"/*.json "$state_dir"/*.pid "$artifact_dir/" 2>/dev/null || true
	chmod -R a+rX "$artifact_dir" 2>/dev/null || true
}

cleanup_service() {
	if [[ -n "$paused_runsv_pid" ]]; then
		kill -CONT "$paused_runsv_pid" 2>/dev/null || true
		paused_runsv_pid=
	fi
	if [[ -e "$respawn_dir" || -L "$respawn_enabled" ]]; then
		"$daemon_bin" remove "$respawn_name" >/dev/null 2>&1 || {
			sv force-shutdown "$respawn_dir" >/dev/null 2>&1 || true
			rm -f "$respawn_enabled"
			rm -rf "$respawn_dir"
		}
	fi
	if [[ -e "$service_dir" || -L "$enabled_path" ]]; then
		"$daemon_bin" remove "$service_name" >/dev/null 2>&1 || {
			sv force-shutdown "$service_dir" >/dev/null 2>&1 || true
			rm -f "$enabled_path"
			rm -rf "$service_dir"
		}
	fi
	rm -f "$metadata_path"
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
	local packages pid1
	[[ $(id -u) -eq 0 ]] || fail 'guest test must run as root'
	[[ -x "$daemon_bin" ]] || fail "missing daemon binary at $daemon_bin"
	[[ -x "$app_bin" ]] || fail "missing test application at $app_bin"
	[[ -r "$interpreted_test" ]] || fail "missing interpreted application test at $interpreted_test"
	[[ -f "$fixture_path" ]] || fail "missing relative-path fixture at $fixture_path"
	grep -Fq 'ID="void"' /etc/os-release || fail 'guest is not Void Linux'
	pid1=$(readlink /proc/1/exe)
	[[ "$pid1" == /usr/bin/runit || "$pid1" == /usr/bin/runit-init ]] || fail 'runit is not PID 1'
	[[ ! -d /run/systemd/system ]] || fail 'systemd unexpectedly detected in runit guest'
	[[ -d /etc/sv ]] || fail '/etc/sv is missing'
	[[ -d /var/service ]] || fail '/var/service does not resolve to the active runsvdir'
	[[ -d /run/runit/runsvdir/current ]] || fail '/run/runit/runsvdir/current is missing'
	for command in bash chpst ps readlink runsv runsvdir sv timeout xbps-query; do
		command -v "$command" >/dev/null || fail "$command is required in the guest"
	done
	packages=$(xbps-query -l)
	grep -Eq '^ii runit-[0-9]' <<<"$packages" || fail 'runit package is not installed'
	grep -Eq '^ii runit-void-[0-9]' <<<"$packages" || fail 'runit-void package is not installed'
	mkdir -p "$state_dir" "$artifact_dir"
}

install_scenario() {
	local stop_timeout=$1 events=$2
	shift 2
	rm -f "$events" "$install_dir/child.pid"
	"$daemon_bin" install --stop-timeout "$stop_timeout" --ignore-warnings \
		"$service_name" "$app_bin" \
		--enabled=true \
		--message 'hello runit' \
		--count 7 \
		--port "$port" \
		--file-path relative-path-test.txt \
		--event-path "$events" \
		"$@"
}

verify_definition() {
	[[ -d "$service_dir" ]] || fail 'runit service directory was not created'
	[[ -x "$service_dir/run" ]] || fail 'runit run script was not created as executable'
	[[ -L "$enabled_path" ]] || fail 'runit enablement symlink was not created'
	[[ $(readlink "$enabled_path") == "$service_dir" ]] || fail 'runit enablement symlink has the wrong target'
	[[ $(cat "$service_dir/daemon-util-stop-timeout") == 5 ]] || fail 'runit stop timeout was not persisted'
	[[ ! -e "$service_dir/down" ]] || fail 'temporary runit down marker remains after installation'
	assert_file_contains "$service_dir/run" "cd '$install_dir' || exit 111"
	assert_file_contains "$service_dir/run" "exec chpst -P '$app_bin'"
	[[ -x "$service_dir/control/t" ]] || fail 'runit TERM control hook was not created'
	[[ -x "$service_dir/control/k" ]] || fail 'runit KILL control hook was not created'
	assert_file_contains "$service_dir/control/t" 'kill -TERM "-$pid"'
	assert_file_contains "$service_dir/control/k" 'kill -KILL "-$pid"'
	assert_contains "$(sv status "$enabled_path")" 'down:' 'runit status after installation'
}

verify_management_commands() {
	local output
	output=$("$daemon_bin" status "$service_name")
	assert_contains "$output" 'running' 'status command'
	output=$("$daemon_bin" list)
	assert_contains "$output" "$service_name" 'list command'
	assert_contains "$output" "$app_bin" 'list command application path'
	output=$("$daemon_bin" list -l)
	assert_contains "$output" 'hello runit' 'long list arguments'
	assert_contains "$(sv status "$enabled_path")" 'run:' 'native runit status'
}

verify_stop_during_respawn() {
	local native_sv supervisor_pid= process status count deadline shim_dir="$state_dir/sv-gate"
	local auxiliary_port=$((port == 65535 ? 65534 : port + 1))
	native_sv=$(command -v sv)
	rm -f "$respawn_events"
	"$daemon_bin" install --ignore-warnings --stop-timeout 5s "$respawn_name" "$app_bin" \
		--port "$auxiliary_port" --stop-after 200ms --event-path "$respawn_events"
	for process in /proc/[0-9]*; do
		if [[ "$(readlink "$process/cwd" 2>/dev/null || true)" == "$respawn_dir" &&
			"$(cat "$process/comm" 2>/dev/null || true)" == runsv ]]; then
			supervisor_pid=${process##*/}
			break
		fi
	done
	[[ -n "$supervisor_pid" ]] || fail 'could not locate auxiliary runsv supervisor'
	sv up "$respawn_enabled"
	deadline=$((SECONDS + 30))
	while (( SECONDS < deadline )); do
		status=$(sv status "$respawn_enabled")
		if [[ "$status" == down:* && "$status" == *'want up'* ]] &&
			grep -Fq '"event":"failure"' "$respawn_events" 2>/dev/null; then
			paused_runsv_pid=$supervisor_pid
			kill -STOP "$supervisor_pid"
			status=$(sv status "$respawn_enabled")
			if [[ "$status" == down:* && "$status" == *'want up'* ]]; then
				break
			fi
			kill -CONT "$supervisor_pid"
			paused_runsv_pid=
		fi
		sleep 0.05
	done
	[[ -n "$paused_runsv_pid" ]] || fail 'did not observe a real down/want-up respawn interval'
	printf '%s\n' "$status" >"$artifact_dir/downrespawn-before-stop.txt"

	# Freeze the real supervisor only to hold the short respawn window open.
	# All status/control calls still reach native sv; resume on force-stop so
	# the old early-return bug cannot accidentally pass after a timing race.
	mkdir -p "$shim_dir"
	cat >"$shim_dir/sv" <<'EOF'
#!/bin/sh
for argument do
	if [ "$argument" = force-stop ]; then
		kill -CONT "$DAEMON_ITEST_RUNSV_PID" || exit 1
	fi
done
exec "$DAEMON_ITEST_NATIVE_SV" "$@"
EOF
	chmod 0755 "$shim_dir/sv"
	PATH="$shim_dir:$PATH" DAEMON_ITEST_NATIVE_SV="$native_sv" DAEMON_ITEST_RUNSV_PID="$supervisor_pid" \
		"$daemon_bin" stop "$respawn_name"
	kill -CONT "$supervisor_pid" 2>/dev/null || true
	paused_runsv_pid=
	count=$(event_count "$respawn_events" started)
	# Native sv may observe an already-down process before runsv consumes the
	# queued stop byte. Wait for acknowledgment, but never allow another start.
	deadline=$((SECONDS + 5))
	while :; do
		status=$(sv status "$respawn_enabled")
		[[ "$(event_count "$respawn_events" started)" == "$count" ]] || fail 'application restarted after stop'
		[[ "$status" == down:* && "$status" != *'want up'* ]] && break
		(( SECONDS < deadline )) || fail 'supervisor did not acknowledge the stop command'
		sleep 0.05
	done
	for _ in {1..15}; do
		status=$(sv status "$respawn_enabled")
		[[ "$status" == down:* && "$status" != *'want up'* ]] || fail 'stopped service still wants to respawn'
		[[ "$(event_count "$respawn_events" started)" == "$count" ]] || fail 'application restarted after stop'
		sleep 0.2
	done
	[[ ! -e "$respawn_dir/down" && -L "$respawn_enabled" ]] || fail 'stop changed boot enablement'
	printf '%s\n' "$count" >"$state_dir/downrespawn-starts"
	printf '%s\n' 'PASS: stop cancelled a real pending respawn without disabling boot' >"$artifact_dir/downrespawn-stop-result.txt"
}

verify_stopped_service_boot_start() {
	local before count deadline=$((SECONDS + 30))
	before=$(cat "$state_dir/downrespawn-starts")
	while (( SECONDS < deadline )); do
		count=$(event_count "$respawn_events" started)
		if (( count > before )); then
			"$daemon_bin" stop "$respawn_name"
			"$daemon_bin" remove "$respawn_name"
			interpreted_removed "$respawn_name"
			printf '%s\n' 'PASS: manually stopped service autostarted after reboot' >"$artifact_dir/downrespawn-reboot-result.txt"
			return
		fi
		sleep 0.2
	done
	fail 'manually stopped service did not autostart after reboot'
}

pre_reboot() {
	local events="$install_dir/boot-events.jsonl" child_pid
	current_scenario=pre-reboot
	log 'installing boot-persistence scenario'
	cleanup_service
	install_scenario 5s "$events" --stop_delay 1s --spawn-child=true --child-pid-path child.pid
	verify_definition
	"$daemon_bin" start "$service_name"
	wait_for_http true >"$state_dir/pre-reboot-http.json"
	verify_management_commands
	child_pid=$(cat "$install_dir/child.pid")
	process_is_test_app "$child_pid" || fail "child process $child_pid is not running"
	http_pid >"$state_dir/pre-reboot-parent.pid"
	current_scenario=stop-during-respawn
	log 'verifying stop during the native down/want-up respawn interval'
	verify_stop_during_respawn
	collect_artifacts pre-reboot
	log 'pre-reboot checks passed'
}

post_reboot() {
	local boot_events="$install_dir/boot-events.jsonl"
	local restart_parent restart_child new_parent hard_parent
	local hot_parent hot_child hot_new_parent replacement
	local graceful_started graceful_elapsed
	local auto_events="$install_dir/restart-events.jsonl"
	local forced_events="$install_dir/forced-events.jsonl"
	local forced_child forced_started forced_elapsed

	current_scenario=post-reboot
	log 'verifying boot persistence'
	[[ -L "$enabled_path" ]] || fail 'service lost runit enablement after reboot'
	wait_for_http true >"$state_dir/post-reboot-http.json"
	(( $(event_count "$boot_events" started) >= 2 )) || fail 'service did not start after reboot'
	verify_management_commands
	verify_stopped_service_boot_start

	current_scenario=explicit-restart
	restart_parent=$(http_pid)
	restart_child=$(cat "$install_dir/child.pid")
	"$daemon_bin" restart "$service_name"
	new_parent=$(wait_for_new_http_pid "$restart_parent" 20)
	wait_for_http true >"$state_dir/restart-http.json"
	wait_process_gone "$restart_parent"
	wait_process_gone "$restart_child"
	assert_event "$boot_events" signal
	assert_event "$boot_events" stopped
	[[ "$new_parent" != "$restart_parent" ]] || fail "restart reused parent PID $restart_parent"

	current_scenario=hot-replacement
	log 'verifying status, list, and stop after atomic executable replacement'
	hot_parent=$(http_pid)
	hot_child=$(cat "$install_dir/child.pid")
	replacement="$install_dir/.test-app.replacement.$$"
	cp -p "$app_bin" "$replacement"
	mv -f "$replacement" "$app_bin"
	[[ "$(readlink "/proc/$hot_parent/exe" 2>/dev/null || true)" == "$app_bin (deleted)" ]] || fail 'running executable was not atomically replaced'
	sleep 2
	[[ "$(http_pid)" == "$hot_parent" ]] || fail 'runit restarted the application after hot replacement'
	verify_management_commands
	"$daemon_bin" stop "$service_name"
	wait_process_gone "$hot_parent"
	wait_process_gone "$hot_child"
	assert_contains "$(sv status "$enabled_path")" 'down:' 'runit status after hot-replacement stop'
	"$daemon_bin" start "$service_name"
	wait_for_http true >"$state_dir/hot-replacement-http.json"
	hot_new_parent=$(http_pid)
	[[ "$hot_new_parent" != "$hot_parent" ]] || fail "hot-replacement restart reused PID $hot_parent"
	verify_management_commands

	current_scenario=graceful-stop
	graceful_started=$(date +%s)
	"$daemon_bin" stop "$service_name"
	graceful_elapsed=$(($(date +%s) - graceful_started))
	(( graceful_elapsed >= 1 )) || fail 'graceful stop returned before the configured delay'
	(( graceful_elapsed < 10 )) || fail "graceful stop took ${graceful_elapsed}s"
	wait_process_gone "$(cat "$install_dir/child.pid")"
	assert_contains "$(sv status "$enabled_path")" 'down:' 'runit status after graceful stop'
	"$daemon_bin" remove "$service_name"
	[[ ! -e "$service_dir" ]] || fail 'runit service directory remains after removal'
	[[ ! -L "$enabled_path" ]] || fail 'runit enablement link remains after removal'

	current_scenario=automatic-restart
	log 'verifying configured failure and hard-crash recovery'
	install_scenario 5s "$auto_events" --stop-after 5s
	"$daemon_bin" start "$service_name"
	wait_for_http false >"$state_dir/automatic-restart-first-http.json"
	restart_parent=$(http_pid)
	new_parent=$(wait_for_new_http_pid "$restart_parent" 20)
	(( $(event_count "$auto_events" started) >= 2 )) || fail 'configured failure did not restart the app'
	assert_event "$auto_events" failure
	kill -KILL "$new_parent"
	hard_parent=$(wait_for_new_http_pid "$new_parent" 20)
	(( $(event_count "$auto_events" started) >= 3 )) || fail 'hard crash did not record a third startup'
	[[ "$hard_parent" != "$new_parent" ]] || fail 'hard-crash recovery reused the parent PID'
	verify_management_commands
	"$daemon_bin" stop "$service_name"
	"$daemon_bin" remove "$service_name"

	current_scenario=forced-stop
	log 'verifying timeout escalation and process cleanup'
	install_scenario 2s "$forced_events" --stop_delay 30s --spawn-child=true --child-pid-path child.pid
	"$daemon_bin" start "$service_name"
	wait_for_http true >"$state_dir/forced-stop-http.json"
	forced_child=$(cat "$install_dir/child.pid")
	forced_started=$(date +%s)
	"$daemon_bin" stop "$service_name"
	forced_elapsed=$(($(date +%s) - forced_started))
	(( forced_elapsed >= 2 )) || fail 'forced stop returned before the configured timeout'
	(( forced_elapsed < 12 )) || fail "forced stop took ${forced_elapsed}s"
	assert_event "$forced_events" signal
	if grep -Fq '"event":"stopped"' "$forced_events"; then
		fail 'application reported graceful completion despite forced termination'
	fi
	wait_process_gone "$forced_child"
	assert_no_test_app_processes
	"$daemon_bin" remove "$service_name"

	current_scenario=interpreted-applications
	log 'verifying symlinked native, shell, optional Python, and rejected direct-script applications'
	verify_interpreted_applications

	current_scenario=cleanup
	collect_artifacts success
	[[ ! -e "$service_dir" ]] || fail 'runit service directory remains after final removal'
	[[ ! -L "$enabled_path" ]] || fail 'runit enablement link remains after final removal'
	[[ ! -e "$metadata_path" ]] || fail 'metadata remains after final removal'
	assert_no_test_app_processes
	log 'all runit application-level tests passed'
}

require_environment
case "$phase" in
	pre-reboot)
		[[ -n "$service_name" ]] || fail 'service name is required'
	pre_reboot
		;;
	post-reboot)
		[[ -n "$service_name" ]] || fail 'service name is required'
		post_reboot
		;;
	cleanup)
		cleanup_service
		;;
	*)
		fail "usage: $0 {pre-reboot|post-reboot|cleanup} SERVICE_NAME [PORT]"
		;;
esac