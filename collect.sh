#!/bin/bash -u

function cmd() {
    local cmd_line="$@"
    echo "########################################"
    echo "# $cmd_line"
    echo "########################################"
    "$@"
    echo
    echo "# Result: $?"
    echo
}

cmd hostname -I
cmd cat /etc/resolv.conf
cmd resolvectl status

for dev in $(netstat -i | cut -d" " -f1 | sed '1d;2d'); do
    cmd ip address show dev $dev
done

cmd ip rule show

for table in $(ip rule show | grep -o "lookup [^ ]\+$" | cut -d" " -f2 | sort -u); do
    cmd ip route list table $table 2> /dev/null
done

echo "=== DONE ==="
