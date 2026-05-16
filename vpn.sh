#!/bin/bash
# Connect/disconnect VPN profiles in order (openconnect, shell CLIs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${VPN_PROFILES:-}" ]]; then
    PROFILES_FILE="$VPN_PROFILES"
elif [[ -f "$SCRIPT_DIR/vpn-profiles.yaml" ]]; then
    PROFILES_FILE="$SCRIPT_DIR/vpn-profiles.yaml"
elif [[ -f "$SCRIPT_DIR/vpn-profiles.json" ]]; then
    PROFILES_FILE="$SCRIPT_DIR/vpn-profiles.json"
else
    PROFILES_FILE="$SCRIPT_DIR/vpn-profiles.json"
fi
STATE_DIR="${VPN_STATE_DIR:-$HOME/.local/ru-routes/vpn}"
LOCK_FILE="/tmp/vpn.lock"
SESSION_LDAP_FILE="$STATE_DIR/session-ldap"

cd "$SCRIPT_DIR"
source venv/bin/activate

log() { echo "$*" >&2; }
err() { echo "ERROR: $*" >&2; }

usage() {
    cat <<'EOF'
Usage: vpn.sh <command> [profile ...]

Commands:
  up [PROFILE ...]    Connect profiles in order (all from yaml if omitted)
  down [PROFILE ...]  Disconnect in reverse order
  daemon [PROFILE ..] Connect and auto-restart on disconnect (openconnect only)
  stop                Stop daemon and disconnect profiles
  log                 Tail daemon log
  status              Show profile / interface / pid state
  list                List profile names from vpn-profiles.yaml

Environment:
  VPN_PROFILES        Path to profiles file (default: vpn-profiles.json or .yaml)
  VPN_STATE_DIR       Pid/state directory (default: ~/.local/ru-routes/vpn)

Setup:
  cp vpn-profiles.json.example vpn-profiles.json
  See docs/secrets-setup.md and docs/sudoers-openconnect.example
EOF
}

require_profiles() {
    if [[ ! -f "$PROFILES_FILE" ]]; then
        err "Missing $PROFILES_FILE — copy vpn-profiles.json.example and edit."
        exit 1
    fi
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "$1 is not installed (required for $2)"
        exit 1
    fi
}

profile_list() {
    python3 "$SCRIPT_DIR/vpn_profiles_load.py" "$PROFILES_FILE" list
}

profile_json() {
    local name="$1"
    python3 "$SCRIPT_DIR/vpn_profiles_load.py" "$PROFILES_FILE" get "$name"
}

json_get() {
    local key="$1"
    python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('$key'); print('' if v is None else v)"
}

json_get_list() {
    python3 -c "
import json, sys
d = json.load(sys.stdin)
for x in d.get(sys.argv[1], []) or []:
    print(x)
" "$1"
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid lock_age
        lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
        lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if (( lock_age > 600 )); then
            rm -f "$LOCK_FILE"
        elif kill -0 "$lock_pid" 2>/dev/null; then
            err "Another instance is running (PID $lock_pid)."
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE"; }

pid_file() {
    echo "$STATE_DIR/$1.pid"
}

# Find openconnect PID by matching server URL from profile, write to pid file
recover_openconnect_pid() {
    local name="$1"
    local j server pid
    j="$(profile_json "$name")"
    server="$(echo "$j" | json_get server)"
    pid=$(pgrep -f "openconnect.*${server}" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        echo "$pid" | sudo tee "$(pid_file "$name")" >/dev/null
        echo "$pid"
    fi
}

pass_show() {
    local spec="$1"
    require_cmd pass "password retrieval"
    if [[ "$spec" != pass:* ]]; then
        err "secret must use pass:path form, got: $spec"
        return 1
    fi
    pass show "${spec#pass:}" | head -1
}

totp_code() {
    local spec="$1"
    require_cmd oathtool "TOTP generation"
    local path="${spec#pass:}"
    if pass otp "$path" &>/dev/null; then
        pass otp "$path" | tr -d '[:space:]'
        return 0
    fi
    local secret algo
    secret="$(pass show "$path" | head -1 | tr -d '[:space:]')"
    algo="SHA1"
    oathtool -b --totp="$algo" "$secret" | tr -d '[:space:]'
}

ldap_password() {
    local spec="$1" mode="$2" name="$3"
    case "$mode" in
        unattended)
            pass_show "$spec"
            ;;
        session)
            if [[ -f "$SESSION_LDAP_FILE" ]]; then
                cat "$SESSION_LDAP_FILE"
            else
                local pw
                read -r -s -p "LDAP password for $name: " pw </dev/tty
                echo >&2
                mkdir -p "$STATE_DIR"
                chmod 700 "$STATE_DIR"
                printf '%s' "$pw" > "$SESSION_LDAP_FILE"
                chmod 600 "$SESSION_LDAP_FILE"
                printf '%s' "$pw"
            fi
            ;;
        manual)
            err "manual mode: run openconnect interactively for profile $name"
            return 1
            ;;
        *)
            err "unknown mode: $mode"
            return 1
            ;;
    esac
}

wait_iface() {
    local iface="$1" timeout="${2:-60}"
    local i=0
    while (( i < timeout )); do
        if ip link show "$iface" &>/dev/null; then
            if ip link show "$iface" 2>/dev/null | grep -q 'state UP\|state UNKNOWN'; then
                return 0
            fi
        fi
        sleep 1
        (( i++ )) || true
    done
    err "timeout waiting for interface $iface"
    return 1
}

run_hooks() {
    local hook
    while IFS= read -r hook; do
        [[ -z "$hook" ]] && continue
        log "  hook: $hook"
        (cd "$SCRIPT_DIR" && eval "$hook")
    done
}

connect_openconnect() {
    local name="$1"
    local j mode server user pass_spec totp_spec iface timeout
    j="$(profile_json "$name")"
    mode="$(echo "$j" | json_get mode)"
    mode="${mode:-unattended}"
    server="$(echo "$j" | json_get server)"
    user="$(echo "$j" | json_get user)"
    pass_spec="$(echo "$j" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('secrets')or{}).get('password',''))")"
    totp_spec="$(echo "$j" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('secrets')or{}).get('totp',''))")"
    iface="$(echo "$j" | json_get wait_iface)"
    timeout="$(echo "$j" | json_get wait_timeout)"
    timeout="${timeout:-90}"

    if [[ -z "$server" || -z "$user" ]]; then
        err "profile $name: server and user required"
        return 1
    fi

    local pf
    pf="$(pid_file "$name")"
    mkdir -p "$STATE_DIR"
    if [[ -f "$pf" ]] && ps -p "$(cat "$pf")" -o pid= >/dev/null 2>&1; then
        log "profile $name: already running (pid $(cat "$pf"))"
        return 0
    fi
    local recovered
    recovered=$(recover_openconnect_pid "$name")
    if [[ -n "$recovered" ]]; then
        log "profile $name: recovered stale pid file (pid $recovered)"
        return 0
    fi

    if [[ "$mode" == "manual" ]]; then
        require_cmd openconnect "$name"
        log "profile $name: starting openconnect (manual — enter password and OTP yourself)"
        sudo openconnect --user="$user" --pid-file="$pf" "$server"
    else
        require_cmd openconnect "$name"
        OPENCONNECT=$(which openconnect)
        local ldap otp
        ldap="$(ldap_password "$pass_spec" "$mode" "$name")"
        otp="$(totp_code "$totp_spec")"
        log "profile $name: connecting to $server as $user"
        local -a oc_args=()
        while IFS= read -r arg; do
            [[ -z "$arg" ]] && continue
            arg="$(echo "$arg" | envsubst)"
            oc_args+=("$arg")
        done < <(echo "$j" | json_get_list openconnect_args)

        printf '%s\n%s\n' "$ldap" "$otp" | sudo -n "$OPENCONNECT" \
            --user="$user" \
            --passwd-on-stdin \
            --background \
            --pid-file="$pf" \
            "${oc_args[@]}" \
            "$server"
    fi

    if [[ -n "$iface" ]]; then
        wait_iface "$iface" "$timeout"
    fi
}

disconnect_openconnect() {
    local name="$1"
    local pf
    pf="$(pid_file "$name")"
    if [[ -f "$pf" ]]; then
        local pid
        pid="$(cat "$pf")"
        if kill -0 "$pid" 2>/dev/null; then
            log "profile $name: stopping openconnect (pid $pid)"
            sudo kill -TERM "$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            local i=0
            while kill -0 "$pid" 2>/dev/null && (( i < 30 )); do
                sleep 1
                (( i++ )) || true
            done
        fi
        rm -f "$pf"
    fi
}

connect_shell() {
    local name="$1"
    local j up iface timeout
    j="$(profile_json "$name")"
    up="$(echo "$j" | json_get up)"
    iface="$(echo "$j" | json_get wait_iface)"
    timeout="$(echo "$j" | json_get wait_timeout)"
    timeout="${timeout:-60}"

    if [[ -z "$up" ]]; then
        err "profile $name: 'up' command required for shell connector"
        return 1
    fi

    log "profile $name: $up"
    eval "$up"

    if [[ -n "$iface" ]]; then
        wait_iface "$iface" "$timeout"
    fi
}

disconnect_shell() {
    local name="$1"
    local j down
    j="$(profile_json "$name")"
    down="$(echo "$j" | json_get down)"
    if [[ -z "$down" ]]; then
        log "profile $name: no down command"
        return 0
    fi
    log "profile $name: $down"
    eval "$down" || true
}

run_post_connect() {
    local name="$1"
    local j
    j="$(profile_json "$name")"
    log "profile $name: post_connect"
    echo "$j" | json_get_list post_connect | run_hooks
}

run_post_disconnect() {
    local name="$1"
    local j
    j="$(profile_json "$name")"
    log "profile $name: post_disconnect"
    echo "$j" | json_get_list post_disconnect | run_hooks
}

connect_profile() {
    local name="$1"
    local connector
    connector="$(profile_json "$name" | json_get connector)"
    log "=== up: $name ($connector) ==="
    case "$connector" in
        openconnect) connect_openconnect "$name" ;;
        shell) connect_shell "$name" ;;
        *)
            err "unknown connector: $connector"
            return 1
            ;;
    esac
    run_post_connect "$name"
}

disconnect_profile() {
    local name="$1"
    local connector
    connector="$(profile_json "$name" | json_get connector)"
    log "=== down: $name ($connector) ==="
    run_post_disconnect "$name"
    case "$connector" in
        openconnect) disconnect_openconnect "$name" ;;
        shell) disconnect_shell "$name" ;;
        *)
            err "unknown connector: $connector"
            return 1
            ;;
    esac
}

cmd_up() {
    require_profiles
    acquire_lock
    trap release_lock EXIT
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    local -a names=("$@")
    if [[ ${#names[@]} -eq 0 ]]; then
        mapfile -t names < <(profile_list)
    fi

    local n
    for n in "${names[@]}"; do
        connect_profile "$n" || exit 1
    done
    log "All profiles connected."
}

cmd_down() {
    require_profiles
    acquire_lock
    trap release_lock EXIT

    local -a names=("$@")
    if [[ ${#names[@]} -eq 0 ]]; then
        mapfile -t names < <(profile_list)
    fi

    local -a rev=()
    local i
    for (( i = ${#names[@]} - 1; i >= 0; i-- )); do
        rev+=("${names[$i]}")
    done

    local n
    for n in "${rev[@]}"; do
        disconnect_profile "$n" || true
    done
    rm -f "$SESSION_LDAP_FILE"
    log "Disconnect complete."
}

cmd_status() {
    require_profiles
    local n j connector iface pf
    while IFS= read -r n; do
        j="$(profile_json "$n")"
        connector="$(echo "$j" | json_get connector)"
        iface="$(echo "$j" | json_get wait_iface)"
        printf '%-16s %-12s' "$n" "$connector"
        if [[ "$connector" == "openconnect" ]]; then
            pf="$(pid_file "$n")"
            if [[ -f "$pf" ]] && ps -p "$(cat "$pf")" -o pid= >/dev/null 2>&1; then
                printf ' pid=%s' "$(cat "$pf")"
            else
                local recovered
                recovered=$(recover_openconnect_pid "$n")
                if [[ -n "$recovered" ]]; then
                    printf ' pid=%s (recovered)' "$recovered"
                else
                    printf ' stopped'
                fi
            fi
        fi
        if [[ -n "$iface" ]]; then
            if ip link show "$iface" &>/dev/null; then
                printf ' %s=up' "$iface"
            else
                printf ' %s=missing' "$iface"
            fi
        fi
        echo
    done < <(profile_list)
}

cmd_list() {
    require_profiles
    profile_list
}

cmd_daemon() {
    require_profiles

    local -a names=("$@")
    if [[ ${#names[@]} -eq 0 ]]; then
        mapfile -t names < <(profile_list)
    fi

    local n
    for n in "${names[@]}"; do
        local connector
        connector="$(profile_json "$n" | json_get connector)"
        if [[ "$connector" != "openconnect" ]]; then
            err "daemon mode only supports openconnect profiles, got: $connector ($n)"
            exit 1
        fi
    done

    local DAEMON_LOG="$STATE_DIR/daemon.log"
    mkdir -p "$STATE_DIR"

    # Fork to background, redirect stdout+stderr to log file
    if [[ -z "${VPN_DAEMON_CHILD:-}" ]]; then
        VPN_DAEMON_CHILD=1 nohup "$0" daemon "$@" >> "$DAEMON_LOG" 2>&1 &
        local daemon_pid=$!
        echo "$daemon_pid" > "$STATE_DIR/daemon.pid"
        log "daemon: started (pid $daemon_pid, log $DAEMON_LOG)"
        return 0
    fi

    local RESTART_DELAY=10
    log "daemon: monitoring ${names[*]} (auto-restart on disconnect)"

    # Initial connection for all profiles
    for n in "${names[@]}"; do
        connect_profile "$n" || true
    done

    # Monitor loop: watch primary profile pid, reconnect all when it dies
    local primary="${names[0]}"
    while true; do
        local pf pid
        pf="$(pid_file "$primary")"
        if [[ -f "$pf" ]]; then
            pid="$(cat "$pf")"
            if ps -p "$pid" -o pid= >/dev/null 2>&1; then
                sleep 30
                continue
            fi
        fi

        log "daemon: $primary disconnected, reconnecting in ${RESTART_DELAY}s..."
        local i
        for (( i = ${#names[@]} - 1; i >= 0; i-- )); do
            disconnect_profile "${names[$i]}" || true
        done
        sleep "$RESTART_DELAY"
        for n in "${names[@]}"; do
            connect_profile "$n" || { log "daemon: failed to connect $n, retrying in 60s..."; sleep 60; }
        done
    done
}

cmd_log() {
    local DAEMON_LOG="$STATE_DIR/daemon.log"
    if [[ ! -f "$DAEMON_LOG" ]]; then
        echo "No daemon log found at $DAEMON_LOG"
        return 0
    fi
    tail -n 50 -f "$DAEMON_LOG"
}

cmd_stop() {
    local daemon_pid_file="$STATE_DIR/daemon.pid"
    if [[ ! -f "$daemon_pid_file" ]]; then
        err "daemon not running (no $daemon_pid_file)"
        return 1
    fi
    local dpid
    dpid=$(cat "$daemon_pid_file")
    if ! ps -p "$dpid" -o pid= >/dev/null 2>&1; then
        rm -f "$daemon_pid_file"
        err "daemon pid $dpid not running (cleaned up pid file)"
        return 1
    fi
    log "stopping daemon (pid $dpid)..."
    # Disconnect all profiles first, then kill the daemon
    cmd_down "$@" || true
    kill -TERM "$dpid" 2>/dev/null || true
    rm -f "$daemon_pid_file"
    log "daemon stopped."
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        up) cmd_up "$@" ;;
        down) cmd_down "$@" ;;
        daemon) cmd_daemon "$@" ;;
        stop) cmd_stop "$@" ;;
        log) cmd_log ;;
        status) cmd_status ;;
        list) cmd_list ;;
        -h|--help|help|"") usage ;;
        *) err "unknown command: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
