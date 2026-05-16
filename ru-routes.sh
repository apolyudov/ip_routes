#!/bin/bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
IFACE="${IFACE:-}"
TABLE="${TABLE:-ru_routes}"
TABLE_ID="${TABLE_ID:-200}"
PRIORITY="${PRIORITY:-500}"
GATEWAY="${GATEWAY:-}"
SOURCE_URL="${SOURCE_URL:-https://antifilter.download/list/subnet.lst}"
BASE_DIR="${BASE_DIR:-$HOME/.local/ru-routes}"
CACHE_DIR="${CACHE_DIR:-$BASE_DIR/cache}"
LOCK_FILE="/tmp/ru-routes.lock"
QUIET=0
USE_CACHE=1

cd $(dirname "$(readlink -f "$0" || echo "$0")")

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

# ── Sudoers setup ────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/ru-routes"

setup_sudoers() {
    local user="${SUDO_USER:-}"
    if [[ -z "$user" ]]; then
        err "Cannot determine user — run install under sudo."
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<EOF
# Managed by ru-routes install/remove
${user} ALL=(root) NOPASSWD: /usr/sbin/ip
${user} ALL=(root) NOPASSWD: /usr/bin/tee -a /etc/iproute2/rt_tables
${user} ALL=(root) NOPASSWD: /usr/bin/kill
${user} ALL=(root) NOPASSWD: /home/linuxbrew/.linuxbrew/bin/openconnect
EOF

    if ! visudo -c -f "$tmpfile" >/dev/null 2>&1; then
        rm -f "$tmpfile"
        err "Sudoers syntax check failed — not installing."
        return 1
    fi

    mv "$tmpfile" "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    log "Sudoers configured for $user ($SUDOERS_FILE)."
}

remove_sudoers() {
    if [[ -f "$SUDOERS_FILE" ]]; then
        rm -f "$SUDOERS_FILE"
        log "Removed $SUDOERS_FILE."
    fi
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
    local tmpfile="$1"
    (
        cd radb-tools
        ./dbctl pull_db
        ./dbctl update_ip RU
        ./dbctl update_ip CN
        ./dbctl merge_ip ip_RU.lst ip_CN.lst
        cp ip_allow.lst "$tmpfile"
        ./dbctl clean
    )
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

# ── User override lists ──────────────────────────────────────────────
list_file() {
    local kind=$1
    echo "$BASE_DIR/user-${kind}.lst"
}

validate_cidr() {
    local net=$1
    if ! [[ "$net" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        err "Invalid CIDR format: $net (expected a.b.c.d/prefix)"
        exit 1
    fi
}

list_add() {
    local kind=$1
    local net=$2
    validate_cidr "$net"
    local file
    file="$(list_file "$kind")"
    if [[ -f "$file" ]] && grep -qxF "$net" "$file"; then
        log "$net already in $kind list."
        return 0
    fi
    echo "$net" >> "$file"
    log "Added $net to $kind list."
}

list_remove() {
    local kind=$1
    local net=$2
    validate_cidr "$net"
    local file
    file="$(list_file "$kind")"
    if [[ ! -f "$file" ]]; then
        log "$kind list is empty."
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    grep -vxF "$net" "$file" > "$tmp" || true
    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp" "$file"
    fi
    log "Removed $net from $kind list."
}

list_list() {
    local kind=$1
    local file
    file="$(list_file "$kind")"
    if [[ -f "$file" ]] && [[ -s "$file" ]]; then
        cat "$file"
    else
        echo "(empty)"
    fi
}

list_clear() {
    local kind=$1
    local file
    file="$(list_file "$kind")"
    if [[ -f "$file" ]]; then
        rm -f "$file"
        log "Cleared $kind list."
    else
        log "$kind list already empty."
    fi
}

apply_user_overrides() {
    local subnet_file=$1
    local exc_file inc_file
    exc_file="$(list_file exclude)"
    inc_file="$(list_file include)"

    # Exclude: remove exact matches
    if [[ -f "$exc_file" ]]; then
        local tmp
        tmp="$(mktemp)"
        grep -vxFf "$exc_file" "$subnet_file" > "$tmp"
        mv "$tmp" "$subnet_file"
        local exc_count
        exc_count="$(wc -l < "$exc_file")"
        log "Applied exclude list: $exc_count entries."
    fi

    # Include: append entries not already present
    if [[ -f "$inc_file" ]]; then
        local added=0
        while IFS= read -r net; do
            if ! grep -qxF "$net" "$subnet_file"; then
                echo "$net" >> "$subnet_file"
                (( added++ )) || true
            fi
        done < "$inc_file"
        log "Applied include list: $added new entries added."
    fi
}

cmd_list() {
    local kind="${1:-}"
    case "$kind" in
        include)  list_list include ;;
        exclude)  list_list exclude ;;
        "")       echo "Include:"; list_list include; echo "Exclude:"; list_list exclude ;;
        *)        err "Unknown list kind: $kind (expected include or exclude)"; exit 1 ;;
    esac
}

cmd_add() {
    local kind="${1:-}"
    case "$kind" in
        include|exclude) ;;
        *)  err "Usage: $0 add <include|exclude> <cidr>"; exit 1 ;;
    esac
    shift || true
    [[ $# -lt 1 ]] && { err "Usage: $0 add <include|exclude> <cidr>"; exit 1; }
    list_add "$kind" "$1"
}

cmd_del() {
    local kind=""
    if [[ "${1:-}" == "include" || "${1:-}" == "exclude" ]]; then
        kind="$1"; shift || true
    fi
    [[ $# -lt 1 ]] && { err "Usage: $0 del [include|exclude] <cidr>"; exit 1; }
    local net="$1"
    validate_cidr "$net"

    if [[ -n "$kind" ]]; then
        list_remove "$kind" "$net"
        return
    fi

    local found=0
    local file
    for k in include exclude; do
        file="$(list_file "$k")"
        if [[ -f "$file" ]] && grep -qxF "$net" "$file"; then
            list_remove "$k" "$net"
            (( found++ )) || true
        fi
    done
    if (( found == 0 )); then
        err "$net not found in any list."
        exit 1
    elif (( found > 1 )); then
        log "Warning: $net was found in both lists."
    fi
}

cmd_clear() {
    local kind="${1:-}"
    case "$kind" in
        include)  list_clear include ;;
        exclude)  list_clear exclude ;;
        "")       list_clear include; list_clear exclude ;;
        *)        err "Unknown list kind: $kind (expected include or exclude)"; exit 1 ;;
    esac
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
ensure_rule() {
    # Ensure ip rule exists with the configured priority (recover after reboot).
    local table=$1
    local pri=$2
    local rule_line existing_prio
    rule_line="$(ip rule show 2>/dev/null | grep "lookup $table" || true)"
    if [[ -n "$rule_line" ]]; then
        existing_prio="$(echo "$rule_line" | grep -oP '^\d+' | head -1)"
        if [[ "$existing_prio" == "$pri" ]]; then
            log "Rule for table $table already present (priority $pri)."
            return 0
        fi
        log "Rule for table $table has priority $existing_prio (expected $pri). Recreating."
        sudo ip rule del lookup "$table"
    else
        log "Rule for table $table is missing. Adding."
    fi
    sudo ip rule add from all table "$table" priority "$pri"
    log "Ensured ip rule: table $table priority $pri"
}

add_rule() {
    ensure_rule "$@"
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
  update         Re-download routes and apply diffs (update_db + update_tables)
  update_db      Re-download subnet list and refresh cache only
  update_tables  Apply route diffs from cache; ensure routing table and ip rule
  update_sber    apply in order: remove_sber, then install_sber
                 useful after SberCloud VPN connection is re-established.
  status         Show current routing state
  list [include|exclude]               Show override list(s)
  add <include|exclude> <CIDR>         Add network to override list
  del [include|exclude] <CIDR>         Remove network (searches both if kind omitted)
  clear [include|exclude]              Clear override list(s)

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
  update/remove/status read it back so env vars need not be repeated.

  update_db writes \$CACHE_DIR/subnet.lst; update_tables reads it.
  Run update_tables alone after reboot to restore ip rules and sync routes."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)   QUIET=1; shift ;;
        --use-cache) USE_CACHE=1; shift ;;
        --no-use-cache) USE_CACHE=0; shift ;;
        --help)    echo "$USAGE"; exit 0 ;;
        list|add|del|clear)
            COMMAND="$1"; shift
            KIND="${1:-}"; shift || true
            break
            ;;
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

    TMPFILE="$(mktemp --tmpdir=$BASE_DIR)"
    cleanup_install() { rm -f "$TMPFILE"; release_lock; }
    trap cleanup_install EXIT
    local tmpfile=$TMPFILE

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

    if ! validate_subnets "$tmpfile"; then
        err "Subnet validation failed. Aborting."
        exit 1
    fi

    apply_user_overrides "$tmpfile"

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

    # Clear the trap since we succeeded — cleanup function will run on EXIT
    tmpfile=""
    setup_sudoers
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

    remove_sudoers
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

_do_update_db() {
    local tmpfile=$1

    if ! download_subnets "$tmpfile"; then
        if (( USE_CACHE )) && [[ -f "$CACHE_DIR/subnet.lst" ]]; then
            log "Using cached subnet list."
            cp "$CACHE_DIR/subnet.lst" "$tmpfile"
        else
            err "Download failed and no cache available."
            return 1
        fi
    fi

    if ! validate_subnets "$tmpfile"; then
        err "Subnet validation failed."
        return 1
    fi

    apply_user_overrides "$tmpfile"

    mkdir -p "$CACHE_DIR"
    cp "$tmpfile" "$CACHE_DIR/subnet.lst"
    date '+%Y-%m-%d %H:%M:%S' > "$CACHE_DIR/last-update"
    save_config
    return 0
}

_do_update_tables() {
    local subnet_file=$1
    local name_add="$BASE_DIR/ip_allow-$TABLE-add.lst"
    local name_del="$BASE_DIR/ip_allow-$TABLE-del.lst"

    register_table "$TABLE" "$TABLE_ID"
    ensure_rule "$TABLE" "$PRIORITY"

    calc_diffs "$TABLE" "$subnet_file" "$name_del" "$name_add"
    del_routes "$name_del" "$TABLE"
    add_routes "$name_add" "$TABLE" "$IFACE" "$GATEWAY"
}

require_iface_config() {
    if [[ -z "${IFACE:-}" ]]; then
        err "IFACE not found in saved config. Run 'install' first."
        exit 1
    fi
}

require_subnet_cache() {
    if [[ ! -f "$CACHE_DIR/subnet.lst" ]]; then
        err "No cached subnet list at $CACHE_DIR/subnet.lst. Run 'update_db' or 'install' first."
        exit 1
    fi
}

cmd_update_db() {
    save_env_overrides
    load_config
    acquire_lock

    TMPFILE="$(mktemp --tmpdir=$BASE_DIR)"
    cleanup_update_db() { rm -f "$TMPFILE"; release_lock; }
    trap cleanup_update_db EXIT

    _do_update_db "$TMPFILE"
    TMPFILE=""
    log "update_db complete."
}

cmd_update_tables() {
    save_env_overrides
    load_config
    require_iface_config
    require_subnet_cache
    acquire_lock

    TMPFILE="$(mktemp --tmpdir=$BASE_DIR)"
    cleanup_update_tables() { rm -f "$TMPFILE"; release_lock; }
    trap cleanup_update_tables EXIT

    cp "$CACHE_DIR/subnet.lst" "$TMPFILE"
    apply_user_overrides "$TMPFILE"

    _do_update_tables "$TMPFILE"
    TMPFILE=""
    log "update_tables complete."
}

cmd_update() {
    save_env_overrides
    load_config
    require_iface_config
    acquire_lock

    TMPFILE="$(mktemp --tmpdir=$BASE_DIR)"
    cleanup_update() { rm -f "$TMPFILE"; release_lock; }
    trap cleanup_update EXIT

    if ! _do_update_db "$TMPFILE"; then
        err "update_db phase failed. Routes unchanged."
        exit 1
    fi

    _do_update_tables "$TMPFILE"
    TMPFILE=""
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
    rule_line="$(ip rule show 2>/dev/null | grep "lookup $TABLE" || true)"
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

    local inc_count="none"
    local exc_count="none"
    local inc_file exc_file
    inc_file="$(list_file include)"
    exc_file="$(list_file exclude)"
    [[ -f "$inc_file" ]] && [[ -s "$inc_file" ]] && inc_count="$(wc -l < "$inc_file") entries"
    [[ -f "$exc_file" ]] && [[ -s "$exc_file" ]] && exc_count="$(wc -l < "$exc_file") entries"

    echo "Include overrides: ${inc_count}"
    echo "Exclude overrides: ${exc_count}"
}

if [[ "$COMMAND" == "list" || "$COMMAND" == "add" || "$COMMAND" == "del" || "$COMMAND" == "clear" ]]; then
    "cmd_$COMMAND" "$KIND" "$@"
else
    "cmd_$COMMAND"
fi
