# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Linux routing management toolkit for policy-based routing. Two main use cases:
1. Route Russian IP subnets through a specific interface/gateway (for VPN-like split tunneling)
2. Manage SberCloud VPN routing by moving routes between routing tables

All scripts require root/sudo. Designed for Linux with `iproute2`.

## Commands

### Main script — `ru-routes.sh`

```bash
sudo ./ru-routes.sh install        # Download subnet list, register routing table, add routes and ip rule
sudo ./ru-routes.sh update         # Re-download and apply diffs (update_db + update_tables)
sudo ./ru-routes.sh update_db      # Re-download subnet list and refresh cache only
sudo ./ru-routes.sh update_tables  # Sync routes from cache; restore ip rule if missing
sudo ./ru-routes.sh remove         # Flush routes, remove ip rule, clean radb-tools data
sudo ./ru-routes.sh status         # Show routing state (table, rule, route count, last update)
sudo ./ru-routes.sh list [include|exclude]               # Show override list(s) (both if omitted)
sudo ./ru-routes.sh add <include|exclude> <CIDR>         # Add network to override list
sudo ./ru-routes.sh del [include|exclude] <CIDR>         # Remove network (searches both if kind omitted)
sudo ./ru-routes.sh clear [include|exclude]              # Clear override list(s) (both if omitted)

sudo ./ru-routes.sh install_sber   # Set up sber_cloud_pub (50) and sber_cloud_tun (100) tables
sudo ./ru-routes.sh remove_sber    # Flush and remove sber_cloud tables
sudo ./ru-routes.sh update_sber    # remove_sber + install_sber (use after VPN reconnect)
```

Configuration via environment variables or `ru-routes.conf` (sourced from same directory):
- `IFACE` — target network interface (required for install)
- `GATEWAY` — optional gateway address
- `TABLE` — routing table name (default: `ru_routes`)
- `TABLE_ID` — numeric table ID (default: `200`)
- `PRIORITY` — ip rule priority (default: `500`)
- `SOURCE_URL` — subnet list URL
- `CACHE_DIR` — cache directory (default: `~/.local/ru-routes/cache`)

Config is persisted to `$CACHE_DIR/config` on install; subsequent update/remove/status load it back.

### Helper scripts

- `mv-routes.sh` — Moves routes matching `--iface`/`--proto` criteria from main table to a target table. Supports `--no-iface`/`--no-proto` for inverse matching. Two-phase: add to target first, then delete from main only on success.
- `collect.sh` — Diagnostic script that dumps network state (interfaces, addresses, routes, rules, DNS).
- `combo.sh` — Quick AdGuardVPN connect/disconnect with route setup (`enable`/`disable`).

### `ip_whois.py`

Fetches WHOIS data for all IPs in the routing table via reg.ru, outputs `ip_whois.csv` (public) and `ip_whois_private.csv` (private). Uses `reg_cache.txt` as a local cache of inetnum ranges to avoid redundant lookups.

Dependencies: `beautifulsoup4` (install separately).

### radb-tools submodule

See `radb-tools/README.md`. Key commands via `dbctl`:
```bash
cd radb-tools && ./dbctl install    # Create venv, install Python deps
./dbctl pull_db                     # Download RIPE ASN database and MRT RIB dump
./dbctl update_ip                   # Generate ip_RU.lst and asn_RU.lst from the database
./dbctl clean                       # Remove generated/backup files
```

## Architecture

```
ru-routes.sh          Main orchestrator (install/update/remove/status for Russian routes)
├── mv-routes.sh      Low-level route mover between tables
├── radb-tools/       Git submodule (github.com:apolyudov/radb-tools)
│   ├── dbctl         Shell driver: pull_db, update_ip, install, clean
│   ├── ip-country.py         Generates ip_<CC>.lst (CIDR prefixes per country from MRT RIB data)
│   ├── asn-country.py        Generates asn_<CC>.lst (ASN list per country)
│   ├── ip-country-ripe.py    Alternative: uses RIPE Stat API instead of MRT data
│   └── requirements.txt      aggregate_prefixes, pyasn, requests
collect.sh            Network diagnostics dumper
combo.sh              AdGuardVPN quick-connect wrapper
ip_whois.py           WHOIS lookup tool for routes
```

### Data flow (install)

1. `radb-tools/dbctl pull_db` + `update_ip RU` + `update_ip CN` + `merge_ip` produces `ip_allow.lst` (RU + CN aggregated prefixes)
2. Subnet list is validated (non-empty, CIDR format check)
3. User overrides applied: `apply_user_overrides()` removes excluded CIDRs, then appends included CIDRs
4. Previous routes in the table are flushed, new routes are added
5. An `ip rule` entry directs traffic through this table at the configured priority

### Data flow (update)

`update` = `update_db` + `update_tables`.

**update_db**

1. Re-downloads and validates the subnet list
2. User overrides applied (same as install step 3)
3. Writes `$CACHE_DIR/subnet.lst` and updates `last-update`

**update_tables**

1. Loads cached subnet list; re-applies user overrides (picks up list changes without re-download)
2. Registers routing table if missing (`register_table`)
3. Ensures `ip rule` exists with configured priority (`ensure_rule` — recovers after reboot)
4. `calc_diffs()` computes add/del diffs against the current routing table
5. Only adds new routes and removes stale ones

### Routing table structure

- **Table 50** (`sber_cloud_pub`): non-tun0, non-trivial-protocol routes (SberCloud public)
- **Table 100** (`sber_cloud_tun`): tun0 routes (SberCloud VPN tunnel)
- **Table 200** (`ru_routes`): Russian IP subnets routed through specified interface

Tables are registered in `/etc/iproute2/rt_tables` by `register_table()`.

## Testing

After modifying `ru-routes.sh` (or any routing logic), run `test-sites` to verify routing correctness:

```bash
./test-sites
```

It resolves a set of known sites and checks that their IPs land in the expected routing tables:
- Russian/Chinese sites go through `ru_routes`
- Non-Russian sites do **not** go through `ru_routes`
- Sber sites go through `sber_cloud_tun`
- Non-Russian sites do **not** go through `sber_cloud_tun`

Each check prints PASSED/FAILED. All four must pass before considering changes to routing logic complete.

## Key conventions

- Shell scripts use `set -euo pipefail` (or `set -eu`)
- File locking via `/tmp/ru-routes.lock` with stale-lock detection (PID check + 10min timeout)
- All route operations are idempotent where possible
- `ru-routes.sh` uses two-phase route moves (add first, delete only on success) to avoid route loss
- radb-tools venv is at `radb-tools/venv/` (Python 3.14)
- Every new feature must be documented in `README.md` before the task is considered complete
- Commit structure: small features → single commit (docs + tests + code). Larger features → sequence: docs → tests/interfaces → implementation. See `feature_commit` skill.
