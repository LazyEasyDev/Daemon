#!/usr/bin/env bash

# Source this before creating test files. Names are user-selectable; UUIDs are
# generated for this invocation and used for every domain lifecycle operation.
virsh_command() {
	LC_ALL=C virsh --connect "$libvirt_uri" "$@"
}

new_domain_uuid() {
	local name=$1 names uuids uuid entry
	if ! names=$(virsh_command list --all --name); then
		printf '[libvirt] cannot verify domain ownership; refusing to continue\n' >&2
		return 1
	fi
	while IFS= read -r entry; do
		if [[ "$entry" == "$name" ]]; then
			printf '[libvirt] domain already exists: %s; refusing to reuse it\n' "$name" >&2
			return 1
		fi
	done <<<"$names"

	uuid=$(uuidgen) || return 1
	if [[ ! "$uuid" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
		printf '[libvirt] could not generate a valid domain UUID\n' >&2
		return 1
	fi
	if ! uuids=$(virsh_command list --all --uuid); then
		printf '[libvirt] cannot verify UUID ownership; refusing to continue\n' >&2
		return 1
	fi
	while IFS= read -r entry; do
		if [[ "${entry,,}" == "${uuid,,}" ]]; then
			printf '[libvirt] generated UUID already exists; refusing to reuse it\n' >&2
			return 1
		fi
	done <<<"$uuids"
	printf '%s\n' "$uuid"
}

remove_owned_domain() {
	local uuid=${1:-}
	# Never fall back to a name, including when creation failed partway through.
	if [[ ! "$uuid" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
		printf '[libvirt] refusing cleanup without an owned domain UUID\n' >&2
		return 1
	fi
	virsh_command destroy "$uuid" >/dev/null 2>&1 || true
	virsh_command undefine "$uuid" --nvram >/dev/null 2>&1 ||
		virsh_command undefine "$uuid" >/dev/null 2>&1 || true
}
