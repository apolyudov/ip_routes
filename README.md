# ip_routes

Linux policy-based routing toolkit for managing split tunneling and VPN routing.

## What it does

- Downloads a list of Russian IP subnets and routes them through a specified network interface and gateway
- Manages SberCloud VPN routing by organizing routes into dedicated routing tables
- Provides diagnostics and WHOIS lookup tools for inspecting the routing table

## Requirements

- Linux with `iproute2`
- Root/sudo
- Python 3.10+ (for radb-tools and ip_whois.py)
- git (radb-tools is a submodule)

## Quick start

```bash
git clone --recurse-submodules <repo-url>
cd ip_routes

# Route Russian IPs through enp6s0 via 192.168.1.1
IFACE=enp6s0 GATEWAY=192.168.1.1 ./ru-routes.sh install
```

## Commands

### ru-routes.sh — Main routing manager

```bash
./ru-routes.sh install        # Download subnets, create table, add routes and rule
./ru-routes.sh update         # Re-download and apply incremental diffs
./ru-routes.sh remove         # Flush routes, remove rule, clean up
./ru-routes.sh status         # Show current routing state
```

#### SberCloud VPN management

```bash
./ru-routes.sh install_sber   # Split main table into sber_cloud_pub (50) and sber_cloud_tun (100)
./ru-routes.sh remove_sber    # Remove SberCloud tables
./ru-routes.sh update_sber    # Rebuild SberCloud tables (use after VPN reconnect)
```

### Other scripts

| Script | Description |
|---|---|
| `mv-routes.sh` | Move routes matching interface or protocol criteria between routing tables |
| `collect.sh` | Dump full network state (interfaces, addresses, routes, rules, DNS) |
| `combo.sh` | Quick AdGuardVPN connect/disconnect with route setup |
| `ip_whois.py` | WHOIS lookup for all IPs in the routing table, outputs CSV |

### mv-routes.sh

```bash
sudo ./mv-routes.sh --table TABLE_ID [--iface INTERFACE] [--proto PROTOCOL] [--dry-run]
```

Supports inverse matching with `--no-iface` and `--no-proto`. Use `--dry-run` to preview.

## Configuration

Set via environment variables or `ru-routes.conf` (placed next to the script):

| Variable | Default | Description |
|---|---|---|
| `IFACE` | — | Target network interface (required for install) |
| `GATEWAY` | — | Gateway address (optional) |
| `TABLE` | `ru_routes` | Routing table name |
| `TABLE_ID` | `200` | Routing table numeric ID |
| `PRIORITY` | `500` | ip rule priority |
| `SOURCE_URL` | antiffilter.download | Subnet list URL |
| `CACHE_DIR` | `~/.local/ru-routes/cache` | Cache directory |

Configuration is saved to `$CACHE_DIR/config` on `install`. Subsequent `update`, `remove`, and `status` commands read it back automatically.

## How it works

### Russian routes (install)

1. Downloads RIPE ASN database and MRT RIB dump via `radb-tools`
2. Generates a list of Russian IP prefixes (`ip_RU.lst`) aggregated with `aggregate_prefixes`
3. Merges with manual additions from `ip_extra.txt` into `ip_allow.lst`
4. Registers a routing table in `/etc/iproute2/rt_tables`
5. Adds a route for each subnet through the configured interface
6. Creates an `ip rule` entry to direct traffic through the table

### Updates

On `update`, the tool re-downloads the subnet list and computes diffs against the current routing table. Only new routes are added and stale ones removed — the ip rule stays in place.

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
