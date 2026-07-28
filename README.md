# tetron-relay

A bringup tool that turns a plain Linux server into a running, self-hosted [iroh relay](https://github.com/n0-computer/iroh/tree/main/iroh-relay) for a [tetron](https://github.com/ErikAllanKincaid/tetron) fleet, and hands back the exact `tetron config set relay <url>` command to point your nodes at it.

**Optional and separate from tetron on purpose**, same relationship tetron-webui/tetron-systray/tetron-testsuite have to core: a genuinely separate, opt-in addon. Nothing about tetron's own behavior changes whether this exists or not. tetron already supports pointing at any relay you like (`tetron config set relay https://...`) -- this tool exists purely to stand one up, not to change tetron itself.

## Why run your own relay

tetron defaults to n0's own public relay for NAT-traversal fallback or the bundled `rayfish` preset. Both work fine, but neither is infrastructure you control: you don't know their retention/logging policy, their uptime is someone else's responsibility. Running your own relay means your fleet's fallback path is a server you own, with access restricted to just your own nodes.

## Design

- **Bash-driven, like tetron-testsuite** -- no Cargo/Rust toolchain needed. iroh publishes prebuilt `iroh-relay` binaries on every GitHub release (`iroh-relay-v<version>-<arch>-unknown-linux-gnu.tar.gz`), so this tool downloads and installs one directly rather than building iroh from source.
- **Version-pinned to your tetron build.** Defaults to the exact iroh version your tetron binary was compiled against (read from a sibling `../tetron` checkout's `Cargo.lock` if present, else a hardcoded fallback verified at write time) so the relay's protocol version matches your fleet exactly. Override with `RELAY_IROH_VERSION=<version>` if you need a different one.
- **Private by default, via EndpointId allowlist -- not a shared token.** iroh's relay-client API (`Endpoint::builder().relay_mode(...)`, `RelayUrl`) has no field for carrying an auth token, and tetron's own `relay` config key is a bare URL list with nothing token-shaped either -- so a shared-token access mode would need an unconfirmed assumption about whether a `?token=` query string riding along in the URL actually reaches the relay's HTTP dial. Skipped entirely: iroh-relay's `access.allowlist` takes EndpointIds directly, and every tetron node already has a stable one (`tetron status --json`'s `endpoint_id` field). Zero tetron-side changes, zero URL-encoding guesswork -- this tool just manages that allowlist for you.
- **Never mutates your firewall.** `up` reports what ports need to be open (tcp/80, tcp/443, udp/7842) and prints the exact command, but never runs it -- a scripted firewall change against a remote box you're SSH'd into is exactly the kind of mistake that locks you out of your own server.
- **No auto DNS.** You point your domain's A/AAAA record at the server yourself before running `up` against it; this tool only checks the record already resolves correctly (best-effort, not fatal if it can't tell).

## Prerequisites

1. A Linux server (x86_64 or aarch64) reachable over SSH, with passwordless sudo for the SSH user (or run as root directly).
2. **For production (`cert_mode = LetsEncrypt`):** a domain name with its A/AAAA record already pointed at the server's public IP, and ports tcp/80 + tcp/443 + udp/7842 open to the internet on that server. Port 80 is used for Let's Encrypt's ACME HTTP-01 challenge as well as ordinary relay traffic; there is no way around exposing it.
3. **For `--dev` (lab/testing only):** none of the above -- no domain, no public IP, no open ports beyond whatever your lab network already allows. Generates a self-signed cert instead of requesting one from Let's Encrypt. See the important caveat below before relying on this for anything but infrastructure smoke-testing.

```bash
cp hosts.conf.example hosts.conf   # edit for your server(s)
```

## Usage

```bash
# Production: real domain, real Let's Encrypt cert, private to your fleet.
./bin/tetron-relay up --host relay-1 --domain relay.example.com --contact you@example.com \
    --allow <endpoint-id-1> --allow <endpoint-id-2>

# -> prints: tetron config set relay https://relay.example.com --replace
# Run that on each fleet node, then `sudo tetron restart`.

# Manage the allowlist (add, list, remove):
./bin/tetron-relay allow add --host relay-1 --endpoint-id <endpoint-id-3>
./bin/tetron-relay allow list --host relay-1
./bin/tetron-relay allow remove --host relay-1 --endpoint-id <endpoint-id-3>

./bin/tetron-relay status --host relay-1
./bin/tetron-relay down --host relay-1              # stop, keep config/binary
./bin/tetron-relay down --host relay-1 --purge       # stop and remove everything
```

Get a node's EndpointId from `tetron status --json`'s `endpoint_id` field on that node.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `RELAY_IROH_VERSION` | auto (from `../tetron/Cargo.lock`, or `1.0.3`) | iroh-relay release version to install. Only needed if you cloned tetron-relay without the full tetron repo, or need a specific version different from what tetron was compiled against. |

## Important: self-signed (`--dev`) certs do not work with a real tetron client

Verified live during this tool's development (2026-07-27), not assumed: `--dev` generates a well-formed, properly-profiled self-signed certificate (correct `basicConstraints=CA:FALSE`, `keyUsage`, `extendedKeyUsage` -- without these, iroh's client rejects it even earlier, with `CaUsedAsEndEntity`, before trust is even evaluated). Even with a fully correct leaf certificate, a real tetron daemon pointed at a `--dev` relay still fails with:

```
invalid peer certificate: UnknownIssuer
```

iroh's relay HTTPS client verifies against a standard public-CA trust store and has no override to trust a private/self-signed root. **`--dev` is only useful for verifying the relay server's own mechanics** (binary installs, systemd runs, config renders, TLS serves, allowlist updates correctly) -- it does not prove a tetron fleet can actually use the relay for real traffic. That requires a real trusted certificate, which means the production Let's Encrypt path (a real domain + public server). This round of work verified `--dev` end-to-end against a lab VM; the production path is documented above but was not live-run against a real domain as part of this work -- run it yourself when you have one ready.

## Layout

```
hosts.conf.example                -- copy to hosts.conf (gitignored) and edit
bin/tetron-relay                   -- CLI: up | allow | status | down
lib/common.sh                      -- host inventory + run_on/upload_to (same shape as tetron-testsuite's)
lib/relay.sh                       -- bringup logic
templates/relay-config.toml.tmpl   -- rendered into /etc/iroh-relay/config.toml
templates/iroh-relay.service.tmpl  -- installed as-is to /etc/systemd/system/
```

## What `up` actually does on the target

1. Preflight: arch check, best-effort DNS check (skipped under `--dev`), reports (never applies) required firewall rules.
2. Downloads and installs the matching `iroh-relay` release binary to `/usr/local/bin/iroh-relay`.
3. Creates a dedicated `iroh-relay` system user/group, `/etc/iroh-relay` (config) and `/var/lib/iroh-relay` (ACME cache / dev certs).
4. `--dev`: generates a self-signed cert there. Otherwise: configures `cert_mode = "LetsEncrypt"` with your `--domain`/`--contact`.
5. Renders `/etc/iroh-relay/config.toml` and installs the systemd unit (binds :80/:443 via `AmbientCapabilities=CAP_NET_BIND_SERVICE`, not root).
6. Enables and (always) restarts the service, then polls its own HTTPS endpoint until it actually answers -- never declares success without observing the service respond (ACME issuance in particular can fail silently from a script's point of view; `systemctl` shows "active" even mid-retry-loop against Let's Encrypt).

## v1 scope / backlog

- Relay only. iroh also publishes a self-hostable `iroh-dns-server` (the discovery/pkarr side, matching tetron's `discovery-dns` config key) -- same shape, natural follow-on, out of scope here.
- No DNS-provider API integration (Cloudflare/Route53/etc.) -- you create the A/AAAA record yourself.
- No automatic firewall rule application, by design (see Design above).
- No cert rotation tooling needed: `LetsEncrypt` cert_mode renews itself at runtime; `--dev` self-signed certs are for smoke-testing only.

## License

MPL-2.0. See `LICENSE`.
