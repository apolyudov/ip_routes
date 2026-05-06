#!/usr/bin/env bash
# mv-routes.sh — Move routes from main table to another table based on criteria
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: mv-routes.sh --table TABLE_ID [--iface INTERFACE] [--proto PROTOCOL] [--dry-run]

Move routes from the main routing table to TABLE_ID if they match either the
specified interface or protocol (OR logic). At least one filter required.

Options:
  --table TABLE_ID   Target routing table (number or name from /etc/iproute2/rt_tables)
  --iface INTERFACE  Match routes via this interface
  --proto PROTOCOL   Match routes with this protocol (kernel, dhcp, static, etc.)
  --dry-run          Show commands without executing
  -h, --help         Show this help

Requires root/sudo.
EOF
    exit "${1:-0}"
}

TABLE=""
IFACE=""
PROTO=""
DRY_RUN=0
INVERSE_PROTO=0
INVERSE_IFACE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --table)   TABLE="$2"; shift 2 ;;
        --iface)   IFACE="$2"; shift 2 ;;
        --no-iface)   IFACE="$2"; INVERSE_IFACE=1; shift 2 ;;
        --proto)   PROTO="$2"; shift 2 ;;
        --no-proto)   PROTO="$2"; INVERSE_PROTO=1; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$TABLE" ]] && { echo "Error: --table is required" >&2; exit 1; }
[[ -z "$IFACE" && -z "$PROTO" ]] && { echo "Error: specify at least --[no-]iface or --[no-]proto" >&2; exit 1; }
[[ "$(id -u)" -ne 0 ]] && { echo "Error: root required" >&2; exit 1; }


# Collect matching routes (AND logic between criteria)
routes=""

proto_inv_match=""
[ $INVERSE_PROTO -eq 1 ] && proto_inv_match="-v"
iface_inv_match=""
[ $INVERSE_IFACE -eq 1 ] && iface_inv_match="-v"
LOOKUP_PROTO=$PROTO
[ $PROTO == "any" ] && LOOKUP_PROTO=""

if [[ -n "$IFACE" ]]; then
    if [[ -n "$PROTO" ]]; then
        routes+=$(ip route show table main | grep $proto_inv_match "proto $LOOKUP_PROTO" | grep $iface_inv_match "dev $IFACE" | grep -v "default")
        routes+=$'\n'
    else
        routes+=$(ip route show table main | grep $iface_inv_match "dev $IFACE" | grep -v "default")
        routes+=$'\n'
    fi
else
    routes+=$(ip route show table main | grep $proto_inv_match "proto $LOOKUP_PROTO" | grep -v "default")
    routes+=$'\n'
fi

UNIQ_ROUTES=$(echo "$routes" | sed '/^$/d' | sort -u)

if [[ -z "$UNIQ_ROUTES" ]]; then
    echo "No matching routes."
    exit 0
fi

echo "Moving to table $TABLE:"
echo "$UNIQ_ROUTES" | sed 's/^/  /'

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  $*"
    else
        "$@"
    fi
}

# Phase 1: copy to target table — only delete what succeeds
SUCCEEDED=()
while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    # shellcheck disable=SC2086
    if run ip route add $r table "$TABLE"; then
        SUCCEEDED+=("$r")
    else
        echo "  WARNING: failed to add: $r" >&2
    fi
done <<< "$UNIQ_ROUTES"

# Phase 2: remove from main table
for r in "${SUCCEEDED[@]}"; do
    # shellcheck disable=SC2086
    run ip route del $r
done

echo "Done. Moved ${#SUCCEEDED[@]} route(s) to table $TABLE."
