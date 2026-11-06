#!/usr/bin/env bash
# Bringup logic for tetron-relay. Sourced by bin/tetron-relay -- never
# executed directly. Depends on lib/common.sh already being sourced
# (run_on, upload_to, RELAY_HOSTS, log_*, fatal).

set -uo pipefail

readonly RELAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pin to tetron's own compiled-in iroh version by default so the relay's
# protocol version matches every fleet node exactly. Reads a sibling
# ../tetron checkout's Cargo.lock if present (same convention
# tetron-testsuite uses for its own tetron binary path); falls back to the
# version verified against at write time.
relay_default_iroh_version() {
	local lockfile="$RELAY_ROOT/../tetron/Cargo.lock"
	if [[ -f "$lockfile" ]]; then
		local v
		v="$(awk '/^name = "iroh"$/{f=1;next} f&&/^version = /{print $3;exit}' "$lockfile" | tr -d '"')"
		[[ -n "$v" ]] && { echo "$v"; return; }
	fi
	echo "1.0.3"
}

readonly RELAY_CONFIG_DIR="/etc/iroh-relay"
readonly RELAY_STATE_DIR="/var/lib/iroh-relay"
readonly RELAY_ALLOWLIST_FILE="$RELAY_CONFIG_DIR/allowlist.txt"
readonly RELAY_STATE_FILE="$RELAY_CONFIG_DIR/bringup-state.env"
readonly RELAY_BIN_PATH="/usr/local/bin/iroh-relay"
readonly RELAY_UNIT_PATH="/etc/systemd/system/iroh-relay.service"
readonly RELAY_GH_REPO="n0-computer/iroh"

# relay_arch_asset <host>
# Maps `uname -m` on the target to the arch token used in iroh's GitHub
# release asset names (x86_64/aarch64 for the -unknown-linux-gnu builds).
relay_arch_asset() {
	local host="$1"
	local m
	m="$(run_on "$host" "uname -m")" || fatal "relay_arch_asset: could not run uname on '$host'"
	case "$m" in
	x86_64) echo "x86_64" ;;
	aarch64 | arm64) echo "aarch64" ;;
	*) fatal "relay_arch_asset: unsupported architecture '$m' on '$host' -- iroh only publishes x86_64/aarch64 linux-gnu relay binaries" ;;
	esac
}

# relay_install_binary <host> <version>
# Downloads and installs the matching iroh-relay release tarball directly
# on the target (the target needs outbound internet either way, for ACME
# in production -- fetching there avoids shipping a tarball through the
# controller at all).
relay_install_binary() {
	local host="$1" version="$2"
	local arch
	arch="$(relay_arch_asset "$host")"
	local asset="iroh-relay-v${version}-${arch}-unknown-linux-gnu.tar.gz"
	local url="https://github.com/${RELAY_GH_REPO}/releases/download/v${version}/${asset}"

	log_info "installing iroh-relay v${version} ($arch) on '$host' from $url"
	run_on "$host" "
		set -e
		tmpdir=\$(mktemp -d)
		curl -fsSL '$url' -o \"\$tmpdir/relay.tar.gz\"
		tar -xzf \"\$tmpdir/relay.tar.gz\" -C \"\$tmpdir\"
		bin=\$(find \"\$tmpdir\" -type f -name iroh-relay | head -n1)
		[ -n \"\$bin\" ] || { echo 'iroh-relay binary not found in release tarball' >&2; exit 1; }
		sudo install -m 0755 \"\$bin\" '$RELAY_BIN_PATH'
		rm -rf \"\$tmpdir\"
	" || fatal "relay_install_binary: failed on '$host' (bad version/arch, or no release for v${version}?)"

	# Verify the binary was actually placed. If the tarball's internal
	# structure changes between iroh versions (different layout, renamed
	# binary), the find+install above could silently do nothing.
	run_on "$host" "test -x '$RELAY_BIN_PATH'" || fatal "relay_install_binary: '$RELAY_BIN_PATH' not found or not executable on '$host' after install"
}

# relay_create_user <host>
# Idempotent: a second `up` run against an already-provisioned host must
# not fail just because the user/dirs already exist.
relay_create_user() {
	local host="$1"
	run_on "$host" "sudo id iroh-relay >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin iroh-relay" \
		|| fatal "relay_create_user: could not create system user 'iroh-relay' on '$host'"
	run_on "$host" "sudo install -d -o root -g iroh-relay -m 0750 '$RELAY_CONFIG_DIR' && sudo install -d -o iroh-relay -g iroh-relay -m 0750 '$RELAY_STATE_DIR'" \
		|| fatal "relay_create_user: could not create $RELAY_CONFIG_DIR/$RELAY_STATE_DIR on '$host'"
}

# relay_generate_dev_cert <host> <subject>
# ECDSA P-256, not Ed25519: rustls/TLS1.3 support for the ring crypto
# provider (what iroh-relay's main.rs installs) is unambiguous for
# ECDSA/RSA server certs; Ed25519 server-cert support is a less certain
# corner of that stack and this is only for --dev/self-signed testing, so
# there is no reason to risk it. `subject` is the domain or bare IP the
# relay is reached at.
#
# Explicit basicConstraints/keyUsage/extendedKeyUsage: found live that a
# plain `openssl req -x509` without these defaults to marking the cert as
# its own CA (CA:TRUE) in some OpenSSL config profiles, which iroh's
# rustls-webpki client rejects outright during leaf-cert parsing --
# `invalid peer certificate: Other(OtherError(CaUsedAsEndEntity))` -- before
# it even gets to evaluating trust. A real end-entity server cert needs
# CA:FALSE regardless of the trust-anchor question this dev cert is meant
# to probe.
relay_generate_dev_cert() {
	local host="$1" subject="$2"
	# subjectAltName's IP: entry needs a literal, parseable IP address --
	# openssl's a2i_GENERAL_NAME rejects anything else outright ("bad ip
	# address"), found live 2026-08-12 passing a hostname (e.g.
	# "test-relay.local") as --domain, the normal case for --dev testing.
	# Only add IP:$subject when $subject actually looks like an IPv4/IPv6
	# literal; otherwise DNS:$subject alone is correct.
	local san="DNS:$subject"
	if [[ "$subject" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$subject" =~ : ]]; then
		san="DNS:$subject,IP:$subject"
	fi
	run_on "$host" "sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-days 365 -nodes -subj '/CN=$subject' \
		-addext 'subjectAltName=$san' \
		-addext 'basicConstraints=critical,CA:FALSE' \
		-addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
		-addext 'extendedKeyUsage=serverAuth' \
		-keyout '$RELAY_STATE_DIR/dev-cert.key.pem' -out '$RELAY_STATE_DIR/dev-cert.pem' 2>/dev/null && \
		sudo chown iroh-relay:iroh-relay '$RELAY_STATE_DIR/dev-cert.key.pem' '$RELAY_STATE_DIR/dev-cert.pem'" \
		|| fatal "relay_generate_dev_cert: openssl failed on '$host'"
}

# relay_render_config <cert_mode> <hostname_or_subject> <contact> <allow_ids_csv>
# Renders templates/relay-config.toml.tmpl to a local temp file, returns
# its path on stdout. `allow_ids_csv` is comma-separated EndpointIds
# (empty means "access everyone" -- only meant for --dev smoke-testing
# before you have real fleet EndpointIds to allowlist).
relay_render_config() {
	local cert_mode="$1" subject="$2" contact="$3" allow_ids_csv="$4"
	local out
	out="$(mktemp)"

	local access_block
	if [[ -z "$allow_ids_csv" ]]; then
		access_block='access = "everyone"'
	else
		local ids_toml
		ids_toml="$(echo "$allow_ids_csv" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/  "&",/')"
		access_block="access.allowlist = [
${ids_toml}
]"
	fi

	local tls_extra
	if [[ "$cert_mode" == "LetsEncrypt" ]]; then
		tls_extra="hostname = \"$subject\"
contact = \"$contact\"
prod_tls = true"
	else
		tls_extra="manual_cert_path = \"$RELAY_STATE_DIR/dev-cert.pem\"
manual_key_path = \"$RELAY_STATE_DIR/dev-cert.key.pem\""
	fi

	# Substitute the two multi-line blocks first (sed -e with a delimiter
	# other than / since the values contain slashes/quotes), then the
	# simple scalar.
	python3 - "$RELAY_ROOT/templates/relay-config.toml.tmpl" "$out" "$access_block" "$cert_mode" "$tls_extra" "$RELAY_STATE_DIR" <<'PYEOF'
import sys
tmpl_path, out_path, access_block, cert_mode, tls_extra, cert_dir = sys.argv[1:7]
text = open(tmpl_path).read()
text = text.replace("__ACCESS_BLOCK__", access_block)
text = text.replace("__CERT_MODE__", cert_mode)
text = text.replace("__TLS_EXTRA__", tls_extra)
text = text.replace("__CERT_DIR__", cert_dir)
open(out_path, "w").write(text)
PYEOF

	echo "$out"
}

# relay_write_state <host> <cert_mode> <subject> <contact>
# Persists the bringup parameters on the target itself so `allow` can
# re-render the config later without the caller re-passing
# --domain/--contact every time.
relay_write_state() {
	local host="$1" cert_mode="$2" subject="$3" contact="$4"
	local tmp
	tmp="$(mktemp)"
	{
		echo "CERT_MODE=$cert_mode"
		echo "SUBJECT=$subject"
		echo "CONTACT=$contact"
	} >"$tmp"
	upload_to "$host" "$tmp" "/tmp/tetron-relay-state.env"
	run_on "$host" "sudo install -m 0640 -o root -g iroh-relay /tmp/tetron-relay-state.env '$RELAY_STATE_FILE' && rm -f /tmp/tetron-relay-state.env"
	rm -f "$tmp"
}

# relay_read_state <host>
# Prints CERT_MODE/SUBJECT/CONTACT as shell-sourceable KEY=value lines.
relay_read_state() {
	local host="$1"
	run_on "$host" "sudo cat '$RELAY_STATE_FILE'" || fatal "relay_read_state: no bringup state found on '$host' -- run 'tetron-relay up' first"
}

# relay_current_allowlist <host>
# Prints the current allowlist, one EndpointId per line (empty if the file
# doesn't exist yet or access is "everyone").
relay_current_allowlist() {
	local host="$1"
	run_on "$host" "sudo test -f '$RELAY_ALLOWLIST_FILE' && sudo cat '$RELAY_ALLOWLIST_FILE' || true"
}

# relay_deploy_config <host> <local_config_path>
relay_deploy_config() {
	local host="$1" local_path="$2"
	upload_to "$host" "$local_path" "/tmp/tetron-relay-config.toml"
	run_on "$host" "sudo install -m 0640 -o root -g iroh-relay /tmp/tetron-relay-config.toml '$RELAY_CONFIG_DIR/config.toml' && rm -f /tmp/tetron-relay-config.toml" \
		|| fatal "relay_deploy_config: could not install config.toml on '$host'"
}

relay_deploy_unit() {
	local host="$1"
	upload_to "$host" "$RELAY_ROOT/templates/iroh-relay.service.tmpl" "/tmp/tetron-relay.service"
	run_on "$host" "sudo install -m 0644 -o root -g root /tmp/tetron-relay.service '$RELAY_UNIT_PATH' && rm -f /tmp/tetron-relay.service && sudo systemctl daemon-reload" \
		|| fatal "relay_deploy_unit: could not install systemd unit on '$host'"
}

# relay_public_ip <host>
# Tries several public-IP detection services in order until one succeeds.
# Returns the detected IP (empty string if all fail).
relay_public_ip() {
	local host="$1"
	local ip services
	services="https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://checkip.amazonaws.com"
	for url in $services; do
		ip="$(run_on "$host" "curl -fsS --max-time 5 '$url'" 2>/dev/null)" || continue
		[[ -n "$ip" ]] && { echo "$ip"; return 0; }
	done
	return 1
}

# relay_wait_https <host> <subject> [<insecure>=false] [<timeout_s>=60]
# Polls the relay's own HTTPS port until it answers. Never declare
# bringup successful without actually observing the service respond --
# ACME issuance in particular can fail silently from this script's point
# of view (systemd shows "active" even mid-retry-loop against Let's
# Encrypt).
relay_wait_https() {
	local host="$1" subject="$2" insecure="${3:-false}" timeout_s="${4:-60}"
	local curl_flags="-fsS --max-time 5"
	[[ "$insecure" == "true" ]] && curl_flags="$curl_flags -k"
	local waited=0
	while ((waited < timeout_s)); do
		if run_on "$host" "curl $curl_flags 'https://$subject/' -o /dev/null" >/dev/null 2>&1; then
			return 0
		fi
		sleep 3
		waited=$((waited + 3))
	done
	return 1
}

# relay_up <host> <domain> <contact> <allow_ids_csv> <dev>
relay_up() {
	local host="$1" domain="$2" contact="$3" allow_ids_csv="$4" dev="$5"
	local version="${RELAY_IROH_VERSION:-$(relay_default_iroh_version)}"

	if [[ "$dev" != "true" ]]; then
		local pub_ip resolved
		pub_ip="$(relay_public_ip "$host")" || log_warn "could not determine '$host''s own public IP (no internet, or blocked outbound) -- skipping DNS preflight"
		if [[ -n "$pub_ip" ]]; then
			resolved="$(run_on "$host" "getent hosts '$domain' 2>/dev/null | awk '{print \$1; exit}'")"
			if [[ -n "$resolved" && "$resolved" != "$pub_ip" ]]; then
				log_warn "DNS preflight: '$domain' resolves to $resolved but '$host' reports its own public IP as $pub_ip -- Let's Encrypt's HTTP-01 challenge will fail if these don't actually match. Continuing anyway (not fatal: NAT/load-balancer setups can legitimately differ)."
			fi
		fi
		log_warn "preflight: this tool does not open firewall ports automatically. Ensure tcp/80, tcp/443, and udp/7842 are reachable from the internet on '$host' (e.g. \`sudo ufw allow 80,443/tcp\` and \`sudo ufw allow 7842/udp\`) before continuing."
	fi

	relay_install_binary "$host" "$version"
	relay_create_user "$host"

	# Preflight: --dev needs openssl on the target for self-signed cert
	# generation. Check before any work that depends on it so the error
	# message is clear, not a confusing "openssl failed" deep in the
	# cert-generation function.
	if [[ "$dev" == "true" ]]; then
		run_on "$host" "command -v openssl" || fatal "relay_up: --dev requires openssl on '$host' (needed to generate a self-signed certificate)"
	fi

	local subject cert_mode
	if [[ "$dev" == "true" ]]; then
		cert_mode="Manual"
		subject="$domain"
		relay_generate_dev_cert "$host" "$subject"
	else
		cert_mode="LetsEncrypt"
		subject="$domain"
	fi

	# Always rewrite (or remove) the allowlist file to exactly match what
	# was passed this run -- `up` must be fully idempotent regardless of
	# what an earlier run (or a since-corrected typo) left behind. Leaving
	# a stale entry in place until the next unrelated `allow` call bit
	# this exact scenario live during verification.
	if [[ -n "$allow_ids_csv" ]]; then
		run_on "$host" "printf '%s\n' \"$(echo "$allow_ids_csv" | tr ',' '\n' | sed '/^$/d')\" | sudo tee '$RELAY_ALLOWLIST_FILE' >/dev/null && sudo chown root:iroh-relay '$RELAY_ALLOWLIST_FILE' && sudo chmod 0640 '$RELAY_ALLOWLIST_FILE'"
	else
		run_on "$host" "sudo rm -f '$RELAY_ALLOWLIST_FILE'"
	fi

	local cfg
	cfg="$(relay_render_config "$cert_mode" "$subject" "$contact" "$allow_ids_csv")"
	relay_deploy_config "$host" "$cfg"
	rm -f "$cfg"
	relay_deploy_unit "$host"
	relay_write_state "$host" "$cert_mode" "$subject" "$contact"

	# enable --now only starts the unit if it wasn't already running --
	# a re-run of `up` against an already-provisioned host would then
	# leave a stale in-memory cert/config loaded (Manual cert_mode reads
	# the cert file once at process start, no hot-reload) even though the
	# files on disk were just rewritten correctly. Found live: the served
	# cert kept showing an old, since-fixed CA:TRUE cert after a re-run
	# that had regenerated a correct CA:FALSE one on disk. `up` must
	# always restart to guarantee the running process matches what was
	# just rendered.
	run_on "$host" "sudo systemctl enable iroh-relay && sudo systemctl restart iroh-relay" || fatal "relay_up: systemctl enable/restart failed on '$host'"

	log_info "waiting for the relay to answer HTTPS on '$host'..."
	if relay_wait_https "$host" "$subject" "$dev"; then
		log_pass "relay is up: https://$subject/"
	else
		run_on "$host" "sudo systemctl status iroh-relay --no-pager -l | tail -30" || true
		fatal "relay_up: relay did not answer HTTPS within the timeout on '$host' -- see the status/log output above (a LetsEncrypt cert_mode failure here usually means the ACME HTTP-01 challenge on port 80 could not be reached from the internet)"
	fi

	echo
	log_info "point your fleet at this relay:"
	echo "    tetron config set relay https://$subject --replace"
	echo "(then \`sudo tetron restart\` on each node)"
}

# relay_allow <host> <endpoint_id>
relay_allow() {
	local host="$1" endpoint_id="$2"
	local state
	state="$(relay_read_state "$host")"
	local CERT_MODE SUBJECT CONTACT
	eval "$state"
	local cert_mode="$CERT_MODE" subject="$SUBJECT" contact="$CONTACT"

	local existing
	existing="$(relay_current_allowlist "$host")"
	if echo "$existing" | grep -qxF "$endpoint_id"; then
		log_warn "relay_allow: '$endpoint_id' is already allowlisted on '$host'"
		return 0
	fi
	local updated
	updated="$(printf '%s\n%s\n' "$existing" "$endpoint_id" | sed '/^$/d')"
	run_on "$host" "printf '%s\n' \"$updated\" | sudo tee '$RELAY_ALLOWLIST_FILE' >/dev/null && sudo chown root:iroh-relay '$RELAY_ALLOWLIST_FILE' && sudo chmod 0640 '$RELAY_ALLOWLIST_FILE'"

	local ids_csv
	ids_csv="$(echo "$updated" | paste -sd,)"
	local cfg
	cfg="$(relay_render_config "$cert_mode" "$subject" "$contact" "$ids_csv")"
	relay_deploy_config "$host" "$cfg"
	rm -f "$cfg"

	run_on "$host" "sudo systemctl restart iroh-relay" || fatal "relay_allow: restart failed on '$host'"
	log_pass "relay_allow: '$endpoint_id' added on '$host', service restarted"
}

# relay_allow_list <host>
# Prints the current allowlist, one EndpointId per line.
relay_allow_list() {
	local host="$1"
	local list
	list="$(relay_current_allowlist "$host")"
	if [[ -z "$list" ]]; then
		log_info "allowlist on '$host' is empty (access is open to everyone)"
	else
		echo "$list"
	fi
}

# relay_allow_remove <host> <endpoint_id>
# Removes an EndpointId from the allowlist, re-renders the config, and
# restarts the relay service.
relay_allow_remove() {
	local host="$1" endpoint_id="$2"
	local state
	state="$(relay_read_state "$host")"
	local CERT_MODE SUBJECT CONTACT
	eval "$state"
	local cert_mode="$CERT_MODE" subject="$SUBJECT" contact="$CONTACT"

	local existing
	existing="$(relay_current_allowlist "$host")"
	if ! echo "$existing" | grep -qxF "$endpoint_id"; then
		log_warn "relay_allow_remove: '$endpoint_id' is not in the allowlist on '$host'"
		return 0
	fi

	# Remove the matching line and any resulting blank line.
	local updated
	updated="$(echo "$existing" | grep -vxF "$endpoint_id" | sed '/^$/d')"
	if [[ -z "$updated" ]]; then
		# Last entry removed: remove the allowlist file entirely, matching
		# relay_up's behavior when no --allow is passed (open access).
		run_on "$host" "sudo rm -f '$RELAY_ALLOWLIST_FILE'"
	else
		run_on "$host" "printf '%s\n' \"$updated\" | sudo tee '$RELAY_ALLOWLIST_FILE' >/dev/null && sudo chown root:iroh-relay '$RELAY_ALLOWLIST_FILE' && sudo chmod 0640 '$RELAY_ALLOWLIST_FILE'"
	fi

	local ids_csv
	ids_csv="$(echo "$updated" | paste -sd,)"
	local cfg
	cfg="$(relay_render_config "$cert_mode" "$subject" "$contact" "$ids_csv")"
	relay_deploy_config "$host" "$cfg"
	rm -f "$cfg"

	run_on "$host" "sudo systemctl restart iroh-relay" || fatal "relay_allow_remove: restart failed on '$host'"
	log_pass "relay_allow_remove: '$endpoint_id' removed on '$host', service restarted"
}

# relay_status <host>
relay_status() {
	local host="$1"
	run_on "$host" "sudo systemctl status iroh-relay --no-pager" || true
	echo

	local state
	state="$(relay_read_state "$host" 2>/dev/null)" || { log_warn "no bringup state on '$host' -- was 'tetron-relay up' run here?"; return 1; }
	local CERT_MODE SUBJECT CONTACT
	eval "$state"

	local insecure="false"
	[[ "$CERT_MODE" == "Manual" ]] && insecure="true"
	if relay_wait_https "$host" "$SUBJECT" "$insecure" 5; then
		log_pass "https://$SUBJECT/ is responding"
	else
		log_fail "https://$SUBJECT/ is not responding"
	fi
}

# relay_down <host> <purge>
relay_down() {
	local host="$1" purge="$2"
	run_on "$host" "sudo systemctl disable --now iroh-relay" || log_warn "relay_down: service was not running/enabled on '$host'"
	if [[ "$purge" == "true" ]]; then
		run_on "$host" "sudo rm -f '$RELAY_UNIT_PATH' '$RELAY_BIN_PATH' && sudo rm -rf '$RELAY_CONFIG_DIR' '$RELAY_STATE_DIR' && sudo systemctl daemon-reload && sudo userdel iroh-relay 2>/dev/null || true"
		log_pass "relay_down: purged binary/config/user on '$host'"
	else
		log_pass "relay_down: stopped and disabled on '$host' (config/binary left in place -- use --purge to remove)"
	fi
}
