#!/usr/bin/env bash
# Shared helpers for tetron-relay. Sourced by bin/tetron-relay and lib/relay.sh
# -- never executed directly. Same shape as tetron-testsuite's lib/common.sh
# (host inventory + run_on) since both tools reach a target machine the
# identical way; tetron-relay's targets are real, already-provisioned
# servers though, not disposable VMs, so there is no topology/vagrant layer
# here at all.

set -uo pipefail

log_info()  { printf '[info]  %s\n' "$*" >&2; }
log_warn()  { printf '[warn]  %s\n' "$*" >&2; }
log_error() { printf '[error] %s\n' "$*" >&2; }
log_pass()  { printf '[pass]  %s\n' "$*" >&2; }
log_fail()  { printf '[fail]  %s\n' "$*" >&2; }

fatal() {
	log_error "$*"
	exit 1
}

require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || fatal "required command not found on this controller: $cmd"
	done
}

declare -gA RELAY_HOSTS=()

# Populates RELAY_HOSTS[name]=target from a hosts.conf-formatted file.
# target is "local" or "ssh:<user@host>", matching hosts.conf.example.
load_hosts_conf() {
	local conf_path="$1"
	[[ -f "$conf_path" ]] || fatal "hosts file not found: $conf_path (copy hosts.conf.example to hosts.conf and edit it)"

	RELAY_HOSTS=()
	local line name target
	while IFS= read -r line; do
		line="${line%%#*}"
		line="$(echo "$line" | xargs)" || true
		[[ -z "$line" ]] && continue
		name="$(echo "$line" | cut -d' ' -f1)"
		target="$(echo "$line" | cut -d' ' -f2-)"
		target="$(echo "$target" | xargs)" || true
		[[ -z "$name" || -z "$target" ]] && fatal "malformed hosts.conf line: $line"
		RELAY_HOSTS["$name"]="$target"
	done <"$conf_path"

	[[ ${#RELAY_HOSTS[@]} -gt 0 ]] || fatal "hosts file declares no hosts: $conf_path"
}

# run_on <host-name> <command...>
# Runs a command on the named host (local shell, or ssh for a "ssh:" target)
# and streams its stdout/stderr through. Returns the command's exit code.
# Mutating commands on the target are expected to need root there (systemd
# units, /etc/iroh-relay, /usr/local/bin) -- this wrapper does not add sudo
# itself; hosts.conf's SSH user must already have passwordless sudo, or you
# run as root directly, same assumption tetron's own install docs make.
run_on() {
	local host_name="$1"
	shift
	local target="${RELAY_HOSTS[$host_name]:-}"
	[[ -n "$target" ]] || fatal "unknown host in hosts.conf: $host_name"

	if [[ "$target" == "local" ]]; then
		bash -c "$*"
	elif [[ "$target" == ssh:* ]]; then
		ssh -o BatchMode=yes "${target#ssh:}" "$@"
	else
		fatal "unrecognized hosts.conf target for '$host_name': $target (expected 'local' or 'ssh:user@host')"
	fi
}

# upload_to <host-name> <local-path> <remote-path>
# Copies a local file to the named host (cp for local, scp for ssh).
upload_to() {
	local host_name="$1" local_path="$2" remote_path="$3"
	local target="${RELAY_HOSTS[$host_name]:-}"
	[[ -n "$target" ]] || fatal "unknown host in hosts.conf: $host_name"

	if [[ "$target" == "local" ]]; then
		cp "$local_path" "$remote_path"
	elif [[ "$target" == ssh:* ]]; then
		scp -o BatchMode=yes -q "$local_path" "${target#ssh:}:$remote_path"
	else
		fatal "unrecognized hosts.conf target for '$host_name': $target"
	fi
}
