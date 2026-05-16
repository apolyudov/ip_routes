# ip_routes

Linux policy-based routing toolkit for managing split tunneling and VPN routing.

## What it does

- Downloads a list of Russian and Chinese IP subnets and routes them through a specified network interface and gateway
- Manages SberCloud VPN routing by organizing routes into dedicated routing tables
- Provides diagnostics and WHOIS lookup tools for inspecting the routing table

## Requirements

- Linux with `iproute2`
- Root/sudo
- Python 3.10+ (for radb-tools, ip_whois.py, VPN tools)
- git (radb-tools is a submodule)
- Optional VPN stack: `openconnect`, `pass`, `pass-otp` ([pass-extension-otp](https://github.com/tadfisher/pass-otp)), `oathtool` — see [docs/secrets-setup.md](docs/secrets-setup.md)

## Quick start

```bash
git clone --recurse-submodules <repo-url>
cd ip_routes

# Route Russian and Chinese IPs through a specific interface/gateway
IFACE=eth0 GATEWAY=10.0.0.1 ./ru-routes.sh install
```

## Commands

### ru-routes.sh — Main routing manager

```bash
./ru-routes.sh install        # Download subnets, create table, add routes and rule
./ru-routes.sh update         # Re-download and apply incremental diffs (both phases)
./ru-routes.sh update_db      # Phase 1: re-download subnet list and refresh cache
./ru-routes.sh update_tables  # Phase 2: sync routes from cache; restore ip rule if missing
./ru-routes.sh remove         # Flush routes, remove rule, clean up
./ru-routes.sh status         # Show current routing state

# Options
./ru-routes.sh --quiet install         # Suppress progress output
./ru-routes.sh --no-use-cache update   # Don't fall back to cached subnet list
./ru-routes.sh update_tables           # After reboot: restore ip rule and sync routes
```

#### SberCloud VPN management

```bash
./ru-routes.sh install_sber   # Split main table into sber_cloud_pub (50) and sber_cloud_tun (100)
./ru-routes.sh remove_sber    # Remove SberCloud tables
./ru-routes.sh update_sber    # Rebuild SberCloud tables (use after VPN reconnect)
```

### vpn.sh

Connect multiple VPNs in order (openconnect with LDAP+TOTP, shell CLIs such as AdGuard), then run routing hooks (`ru-routes.sh update_sber`, custom `ip route` / `ip rule`).

**Setup:** [docs/secrets-setup.md](docs/secrets-setup.md) (GPG, pass, pass-otp) · copy `vpn-profiles.yaml.example` → `vpn-profiles.yaml` · [docs/sudoers-openconnect.example](docs/sudoers-openconnect.example) for passwordless `sudo openconnect`.

```bash
cp vpn-profiles.json.example vpn-profiles.json   # edit servers, pass: paths
# optional: cp vpn-profiles.yaml.example vpn-profiles.yaml (needs pip install pyyaml)

./vpn.sh up              # all profiles in order
./vpn.sh up sber_vpn     # one profile
./vpn.sh down
./vpn.sh status
```

#### Daemon mode (auto-restart on session expiry)

Openconnect sessions expire (e.g. 12h). Daemon mode monitors the connection and automatically reconnects with fresh credentials (new TOTP) when it drops.

```bash
./vpn.sh daemon              # fork to background, auto-restart all profiles
./vpn.sh daemon sber_vpn     # specific profile only
./vpn.sh log                 # tail daemon log (Ctrl-C to stop watching)
./vpn.sh stop                # disconnect profiles and stop daemon
```

The daemon forks to background — logs go to `~/.local/ru-routes/vpn/daemon.log`. It survives closing the terminal. Post-connect/disconnect hooks run on every reconnect cycle.

**TOTP from Google Authenticator export QR:**

```bash
pip install pyzbar Pillow   # optional; apt install libzbar0
./ga_qr_decode.py export.png
pass otp insert vpn/your-totp
```

Plans and design: [docs/plans/multi-vpn-automation.md](docs/plans/multi-vpn-automation.md).

### Other scripts

| Script | Description |
|---|---|
| `mv-routes.sh` | Move routes matching interface or protocol criteria between routing tables |
| `collect.sh` | Dump full network state (interfaces, addresses, routes, rules, DNS) |
| `vpn.sh` | Ordered multi-VPN connect/disconnect with pass-backed secrets |
| `ga_qr_decode.py` | Decode GA export QR → base32 TOTP secret for `pass otp insert` |
| `ip_whois.py` | WHOIS lookup for all IPs in the routing table, outputs CSV |
| `test-sites` | Verify that sites are routed through the correct routing tables |
| `test-ga_qr_decode` | Unit tests for `ga_qr_decode.py` |
| `test-vpn` | Smoke tests for VPN profile loading and CLI |

### mv-routes.sh

```bash
sudo ./mv-routes.sh --table TABLE_ID [--iface INTERFACE] [--proto PROTOCOL] [--dry-run]
```

Supports inverse matching with `--no-iface` and `--no-proto`. Use `--dry-run` to preview.

### test-sites

```bash
./test-sites
```

Verifies routing correctness by resolving sites and checking which routing table their IPs land in. Runs four checks:

- Russian sites go through `ru_routes`
- Non-Russian sites do **not** go through `ru_routes`
- Sber sites go through `sber_cloud_tun`
- Non-Russian sites do **not** go through `sber_cloud_tun`

### User include/exclude lists

Manage custom network overrides that are applied on every `install` and `update`:

```bash
./ru-routes.sh add include 10.0.0.0/8        # Force-include a network
./ru-routes.sh del include 10.0.0.0/8        # Remove from include list
./ru-routes.sh list                           # Show all override lists
./ru-routes.sh list include                   # Show include list only
./ru-routes.sh clear                          # Clear all overrides
./ru-routes.sh clear include                  # Clear include list only

./ru-routes.sh add exclude 192.168.0.0/16    # Force-exclude a network
./ru-routes.sh del 10.0.0.0/8                # Remove from whichever list has it
```

Lists are stored in `~/.local/ru-routes/user-include.lst` and `~/.local/ru-routes/user-exclude.lst` (one CIDR per line). During `install`, `update`, and `update_tables`, excluded networks are removed from the subnet list first, then included networks are appended. The result replaces what goes into the routing table.

`del` without a kind specifier searches both lists: removes from whichever matches, removes from both with a warning if found in both, or errors if not found.

## Configuration

Set via environment variables or `ru-routes.conf` (placed next to the script):

| Variable | Default | Description |
|---|---|---|
| `IFACE` | _(required)_ | Target network interface |
| `GATEWAY` | _(none)_ | Optional gateway address |
| `TABLE` | `ru_routes` | Routing table name |
| `TABLE_ID` | `200` | Routing table numeric ID |
| `PRIORITY` | `500` | ip rule priority |
| `CACHE_DIR` | `~/.local/ru-routes/cache` | Cache directory |

Configuration is saved to `$CACHE_DIR/config` on `install`. Subsequent `update`, `update_db`, `update_tables`, `remove`, and `status` commands read it back automatically.

## How it works

### Russian and Chinese routes (install)

1. Downloads RIPE ASN database and MRT RIB dump via `radb-tools`
2. Generates aggregated IP prefix lists for Russia (`ip_RU.lst`) and China (`ip_CN.lst`)
3. Merges both into `ip_allow.lst` via `dbctl merge_ip`
4. Registers a routing table in `/etc/iproute2/rt_tables`
5. Adds a route for each subnet through the configured interface
6. Creates an `ip rule` entry to direct traffic through the table

### Updates

`update` runs two phases in order:

1. **`update_db`** — re-downloads the subnet list (via `radb-tools`), validates it, applies user overrides, and writes `$CACHE_DIR/subnet.lst`.
2. **`update_tables`** — reads the cached list, computes diffs against the current routing table, adds/removes routes incrementally, registers the routing table in `/etc/iproute2/rt_tables` if needed, and ensures the `ip rule` exists with the configured priority.

Either phase can be run alone. After a reboot (when `ip rule` entries are lost but routes may still be present), run `update_tables` to restore the rule and reconcile routes against the cache.

Downloaded subnet lists are validated (checked for non-empty, CIDR format) before any routes are modified. If validation or download fails during `update_db` / `update`, a previously cached list is used as fallback (`--no-use-cache` to disable).

### SberCloud routing

Separates the main routing table into two dedicated tables:

- **sber_cloud_pub** (ID 50) — all routes except those through `tun0`
- **sber_cloud_tun** (ID 100) — routes through `tun0` (VPN tunnel)

Each table gets its own `ip rule` entry so traffic is matched by priority.

## radb-tools

The `radb-tools/` directory is a git submodule ([apolyudov/radb-tools](https://github.com/apolyudov/radb-tools)) that handles ASN/IP data processing:

```bash
cd radb-tools
./dbctl install     # Create venv, install Python dependencies
./dbctl pull_db     # Download RIPE ASN database and MRT RIB dump
./dbctl update_ip   # Generate country-specific IP and ASN lists
./dbctl clean       # Remove generated and backup files
```

## License

Apache License 2.0
