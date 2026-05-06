#!/bin/bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
IFACE=${IFACE:-enp6s0}
TABLE="${TABLE:-ru_routes}"
TABLE_ID="${TABLE_ID:-200}"
PRIORITY="${PRIORITY:-500}"
GATEWAY="${GATEWAY:-192.168.1.1}"
SOURCE_URL="${SOURCE_URL:-https://antifilter.download/list/subnet.lst}"
BASE_DIR="${BASE_DIR:-$HOME/.local/ru-routes}"
CACHE_DIR="${CACHE_DIR:-$BASE_DIR/cache}"
LOCK_FILE="/tmp/ru-routes.lock"
QUIET=0
USE_CACHE=1

mkdir -p $BASE_DIR

# ── Config file loading ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/ru-routes.conf"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=ru-routes.conf
    source "$CONF_FILE"
fi

# ── Logging ───────────────────────────────────────────────────────────
log() {
    (( QUIET )) || echo "$*" >&2
}
err() {
    echo "ERROR: $*" >&2
}

# ── Locking ──────────────────────────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid lock_age
        lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
        lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if (( lock_age > 600 )); then
            log "Removing stale lock (PID $lock_pid, ${lock_age}s old)"
            rm -f "$LOCK_FILE"
        elif kill -0 "$lock_pid" 2>/dev/null; then
            err "Another instance is running (PID $lock_pid). Aborting."
            exit 1
        else
            log "Removing stale lock (PID $lock_pid no longer exists)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ── Config persistence ───────────────────────────────────────────────
save_config() {
    mkdir -p "$CACHE_DIR"
    cat > "$CACHE_DIR/config" <<CONF
IFACE="${IFACE:-}"
TABLE="${TABLE}"
TABLE_ID="${TABLE_ID}"
PRIORITY="${PRIORITY}"
GATEWAY="${GATEWAY:-}"
SOURCE_URL="${SOURCE_URL}"
CACHE_DIR="${CACHE_DIR}"
CONF
    log "Config saved to $CACHE_DIR/config"
}

load_config() {
    local cfg="$CACHE_DIR/config"
    if [[ ! -f "$cfg" ]]; then
        err "No saved config found at $cfg. Run 'install' first."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$cfg"
    # Re-apply env overrides (env vars take precedence over config file)
    TABLE="${TABLE_ENV_OVERRIDE:-$TABLE}"
    TABLE_ID="${TABLE_ID_ENV_OVERRIDE:-$TABLE_ID}"
    PRIORITY="${PRIORITY_ENV_OVERRIDE:-$PRIORITY}"
    GATEWAY="${GATEWAY_ENV_OVERRIDE:-$GATEWAY}"
    SOURCE_URL="${SOURCE_URL_ENV_OVERRIDE:-$SOURCE_URL}"
    CACHE_DIR="${CACHE_DIR_ENV_OVERRIDE:-$CACHE_DIR}"
}

# Save current env values before load_config overwrites them
# (called when user explicitly sets vars on the command line)
save_env_overrides() {
    # Only save if the var was explicitly set in the environment
    [[ -n "${IFACE:+x}" ]]        && IFACE_ENV_OVERRIDE="$IFACE"         || true
    [[ -n "${TABLE:+x}" ]]        && TABLE_ENV_OVERRIDE="$TABLE"         || true
    [[ -n "${TABLE_ID:+x}" ]]     && TABLE_ID_ENV_OVERRIDE="$TABLE_ID"   || true
    [[ -n "${PRIORITY:+x}" ]]     && PRIORITY_ENV_OVERRIDE="$PRIORITY"   || true
    [[ -n "${GATEWAY:+x}" ]]      && GATEWAY_ENV_OVERRIDE="$GATEWAY"     || true
    [[ -n "${SOURCE_URL:+x}" ]]   && SOURCE_URL_ENV_OVERRIDE="$SOURCE_URL" || true
    [[ -n "${CACHE_DIR:+x}" ]]    && CACHE_DIR_ENV_OVERRIDE="$CACHE_DIR" || true
}

# ── Interface check ──────────────────────────────────────────────────
check_interface() {
    if [[ -z "${IFACE:-}" ]]; then
        err "IFACE is required. Set it via environment variable or ru-routes.conf."
        exit 1
    fi
    if ! ip link show "$IFACE" &>/dev/null; then
        err "Interface '$IFACE' does not exist."
        exit 2
    fi
    log "Interface: $IFACE"
}

# ── Routing table registration ───────────────────────────────────────
register_table() {
    local table=$1
    local table_id=$2
    local rt_tables="/etc/iproute2/rt_tables"
    # Check if name already registered
    if grep -qP "^\s*${table_id}\s+${table}(\s|$)" "$rt_tables" 2>/dev/null; then
        log "Table $table ($table_id) already registered."
        return 0
    fi
    # Check for name conflict (same name, different ID)
    local existing_id
    existing_id="$(grep -oP "^\s*\K\d+(?=\s+${TABLE}(\s|$))" "$rt_tables" 2>/dev/null || true)"
    if [[ -n "$existing_id" && "$existing_id" != "$table_id" ]]; then
        err "Table name '$table' already registered with ID $existing_id (expected $table_id)."
        exit 1
    fi
    # Check for ID conflict (same ID, different name)
    local existing_name
    existing_name="$(grep -oP "^\s*${table_id}\s+\K\S+" "$rt_tables" 2>/dev/null || true)"
    if [[ -n "$existing_name" && "$existing_name" != "$table" ]]; then
        err "Table ID $table_id already registered with name '$existing_name' (expected '$table')."
        exit 1
    fi
    # Add the entry
    local record="${table_id}    ${table}"
    echo "About to add line '$record' to $rt_tables"
    echo $record | sudo tee -a "$rt_tables"
    log "Registered table $table ($table_id) in $rt_tables"
}

download_subnets() {
    tmpfile="$1"
    (
        cd radb-tools
        ./dbctl pull_db
        ./dbctl update_ip RU
        ./dbctl update_ip CN
        ./dbctl merge_ip ip_RU.lst ip_CN.lst
        cp ip_allow.lst $tmpfile
        ./dbctl clean
    )
    return 0
}

validate_subnets() {
    local file="$1"
    local line_count
    line_count="$(wc -l < "$file")"
    if (( line_count == 0 )); then
        err "Downloaded file is empty."
        return 1
    fi
    # Validate first 10 lines are CIDR
    local bad=0
    local checked=0
    while IFS= read -r line && (( checked < 10 )); do
        (( checked++ )) || true
        if ! [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            (( bad++ )) || true
        fi
    done < "$file"
    if (( bad > 0 )); then
        err "Invalid CIDR format detected in downloaded list ($bad bad out of first $checked lines)."
        return 1
    fi
    log "Validated: $line_count subnets."
}

# ── Route management ─────────────────────────────────────────────────
add_routes() {
    local subnet_file="$1"
    local table=$2
    local iface=$3
    local gateway=$4

    local added=0
    local failed=0
    local gw_arg=""
    if [[ -n "$gateway" ]]; then
        gw_arg="via $gateway"
    fi
    (( step = 100 )) || true
    while IFS= read -r subnet; do
        if sudo ip route add "$subnet" dev "$iface" $gw_arg table "$table" 2>/dev/null; then
            (( added++ )) || true
        else
            (( failed++ )) || true
        fi
        if (( added + failed == step )) ; then
          log "routes added: $added, skipped/failed: $failed"
          (( step += 100 )) || true
        fi
    done < "$subnet_file"
    log "Total routes added: $added, skipped/failed: $failed"
}

del_routes() {
    local subnet_file="$1"
    local table=$2

    local removed=0
    local failed=0
    (( step = 100 )) || true
    while IFS= read -r subnet; do
        if sudo ip route del "$subnet" table "$table" 2>/dev/null; then
            (( removed++ )) || true
        else
            (( failed++ )) || true
        fi
        if (( removed + failed == step )) ; then
          log "routes removed: $removed, skipped/failed: $failed"
          (( step += 100 )) || true
        fi
    done < "$subnet_file"
    log "Total routes removed: $removed, skipped/failed: $failed"
}

ipv4_sort() {
  awk -F'[./]' '{printf "%03d.%03d.%03d.%03d/%02d %s\n", $1, $2, $3, $4, $5, $0}' \
    | sort -u \
    | sed 's/^[^ ]* //'
}

flush_routes() {
    local table=$1
    local count
    set +e
    count="$(ip route list table "$table" 2>/dev/null | wc -l)"
    set -e
    if (( count > 0 )); then
        sudo ip route flush table "$table"
        log "Flushed $count routes from table $table."
    else
        log "Table $table is already empty."
    fi
}

# ── Rule management ──────────────────────────────────────────────────
add_rule() {
    # Idempotent: skip if rule already exists
    local table=$1
    local pri=$2
    if ip rule show | grep -q "table $table"; then
        log "Rule for table $table already exists."
        return 0
    fi
    sudo ip rule add from all table "$table" priority "$pri"
    log "Added ip rule: table $table priority $pri"
}

remove_rule() {
    local table=$1
    if ip rule show | grep -q "lookup $table"; then
        sudo ip rule del lookup "$table"
        log "Removed ip rule for table $table."
    else
        log "No rule found for table $table."
    fi
}

# ── Flags ─────────────────────────────────────────────────────────────
USAGE="Usage: $0 [OPTIONS] COMMAND

Commands:
  install        Download subnet list, add routes and ip rule
  install_sber   Move sber_cloud rules from main to its own tables
  remove         Flush routes from table, remove ip rule
  remove_sber    Delete sber_cloud tables
  update         Re-download routes and apply diffs (keep rule)
  update_sber    apply in order: remove_sber, then install_sber
                 useful after SberCloud VPN connection is re-established.
  status         Show current routing state

Options:
  --quiet       Suppress progress output (errors only)
  --[no-]use-cache   On download failure, [do not] use cached subnet list
  --help        Show this help

Configuration (environment variables or ru-routes.conf):
  IFACE       Target network interface (required for install)
  GATEWAY     Optional gateway via interface
  TABLE       Routing table name (default: ru_routes)
  TABLE_ID    Routing table numeric ID (default: 200)
  PRIORITY    ip rule priority (default: 500)
  SOURCE_URL  Subnet list URL (default: antifilter.download)
  CACHE_DIR   Cache directory (default: ~/.local/ru-routes/cache)

Config persistence: 'install' saves config to \$CACHE_DIR/config.
  update/remove/status read it back so env vars need not be repeated."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)   QUIET=1; shift ;;
        --use-cache) USE_CACHE=1; shift ;;
        --no-use-cache) USE_CACHE=0; shift ;;
        --help)    echo "$USAGE"; exit 0 ;;
        install*|remove*|update*|status) COMMAND="$1"; shift ;;
        *)         err "Unknown argument: $1"; echo "$USAGE" >&2; exit 1 ;;
    esac
done

if [[ -z "${COMMAND:-}" ]]; then
    err "No command specified."
    echo "$USAGE" >&2
    exit 1
fi

cmd_install_sber() {
    echo "Adding configuration for sber_cloud"
    register_table sber_cloud_pub 50
    register_table sber_cloud_tun 100

    echo "Populating tables (moving records from main)"
    sudo ./mv-routes.sh --table sber_cloud_pub --no-iface tun0 --no-proto any
    sudo ./mv-routes.sh --table sber_cloud_tun --iface tun0

    add_rule       sber_cloud_pub 50
    add_rule       sber_cloud_tun 100
}

cmd_install() {
    check_interface
    acquire_lock
    trap release_lock EXIT

    local tmpfile
    tmpfile="$(mktemp --tmpdir=$BASE_DIR)"
    trap 'rm -f "$tmpfile"' EXIT

    (
        cd radb-tools
        ./dbctl install
    )

    if ! download_subnets "$tmpfile"; then
        if (( USE_CACHE )) && [[ -f "$CACHE_DIR/subnet.lst" ]]; then
            log "Using cached subnet list."
            cp "$CACHE_DIR/subnet.lst" "$tmpfile"
        else
            err "Cannot proceed without subnet list."
            exit 1
        fi
    fi

    # table for russian routes
    echo "Adding configuration for ru_routes"
    register_table $TABLE $TABLE_ID
    echo "Clean-up of prevoius routes"
    flush_routes   $TABLE
    echo "Adding new routes"
    add_routes     "$tmpfile" $TABLE $IFACE $GATEWAY
    echo "Adding enabler rule"
    add_rule       $TABLE $PRIORITY

    mkdir -p "$CACHE_DIR"
    cp "$tmpfile" "$CACHE_DIR/subnet.lst"
    date '+%Y-%m-%d %H:%M:%S' > "$CACHE_DIR/last-update"
    save_config

    rm -f "$tmpfile"
    trap - EXIT
    release_lock

    log "Install complete."
}

cmd_remove() {
    save_env_overrides
    load_config
    acquire_lock
    trap release_lock EXIT

    flush_routes $TABLE
    remove_rule  $TABLE
    (
        cd radb-tools
        git clean -xdf
    )

    release_lock
    log "Remove complete."
}

cmd_remove_sber() {
    save_env_overrides
    load_config
    acquire_lock
    trap release_lock EXIT

    flush_routes sber_cloud_pub
    flush_routes sber_cloud_tun
    remove_rule  sber_cloud_pub
    remove_rule  sber_cloud_tun

    release_lock
    log "Remove sber_cloud routing complete."
}

calc_diffs() {
  local table=$1
  local name_input="$2"
  local name_del="$3"
  local name_add="$4"

  local tbl_file="$BASE_DIR/$table.txt"

  name_base="$name_input.sorted"

  cat "$name_input" | ipv4_sort > "$name_base"

  ip route show table $table | cut -d" " -f1 | ipv4_sort > "$tbl_file"
  diff -ura "$tbl_file" "$name_base" | grep "^+" | sed '1d' | cut -c2- > "$name_add" || true
  diff -ura "$tbl_file" "$name_base" | grep "^-" | sed '1d' | cut -c2- > "$name_del" || true
  rm -f "$tbl_file" "$name_base"
  add_cnt=$(cat "$name_add" | wc -l)
  del_cnt=$(cat "$name_del" | wc -l)
  echo "Total $add_cnt insertions and $del_cnt removals for \"$table\" required"
}

cmd_update() {
    save_env_overrides
    load_config

    if [[ -z "${IFACE:-}" ]]; then
        err "IFACE not found in saved config. Run 'install' first."
        exit 1
    fi

    acquire_lock
    trap release_lock EXIT

    local tmpfile
    tmpfile="$(mktemp --tmpdir=$BASE_DIR)"
    trap 'rm -f "$tmpfile"' EXIT

    if ! download_subnets "$tmpfile"; then
        if (( USE_CACHE )) && [[ -f "$CACHE_DIR/subnet.lst" ]]; then
            log "Using cached subnet list."
            cp "$CACHE_DIR/subnet.lst" "$tmpfile"
        else
            err "Download failed and no cache available. Routes unchanged."
            exit 1
        fi
    fi

    local name_base="$tmpfile"
    local name_add="$BASE_DIR/ip_allow-$TABLE-add.lst"
    local name_del="$BASE_DIR/ip_allow-$TABLE-del.lst"

    calc_diffs $TABLE $name_base $name_del $name_add
    del_routes "$name_del" $TABLE
    add_routes "$name_add" $TABLE $IFACE $GATEWAY
    # Rule stays in place — no need to touch it

    mkdir -p "$CACHE_DIR"
    cp "$tmpfile" "$CACHE_DIR/subnet.lst"
    date '+%Y-%m-%d %H:%M:%S' > "$CACHE_DIR/last-update"
    save_config

    rm -f "$tmpfile"
    trap - EXIT
    release_lock

    log "Update complete."
}

cmd_update_sber() {
    cmd_remove_sber
    cmd_install_sber
}

cmd_status() {
    save_env_overrides
    load_config

    local route_count=0
    route_count="$(ip route list table "$TABLE" 2>/dev/null | wc -l)"

    local rule_status="not installed"
    local rule_prio=""
    local rule_line
    rule_line="$(ip rule show 2>/dev/null | grep "table $TABLE" || true)"
    if [[ -n "$rule_line" ]]; then
        rule_prio="$(echo "$rule_line" | grep -oP '^\d+' | head -1)"
        rule_status="installed (priority ${rule_prio})"
    fi

    local last_update="N/A"
    if [[ -f "$CACHE_DIR/last-update" ]]; then
        last_update="$(cat "$CACHE_DIR/last-update")"
    fi

    echo "Table: ${TABLE} (${TABLE_ID})"
    echo "Interface: ${IFACE:-N/A}"
    echo "Gateway: ${GATEWAY:-none}"
    echo "Routes: ${route_count}"
    echo "Rule: ${rule_status}"
    echo "Last updated: ${last_update}"
}

"cmd_$COMMAND"
