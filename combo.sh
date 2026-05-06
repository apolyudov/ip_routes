#!/bin/bash -eux

enable() {
  adguardvpn-cli connect
  sudo ip route add default via 172.16.219.2 dev tun1
  sudo ip rule add pref 100 table main
}

disable() {
  sudo ip rule del pref 100 table main || true
  adguardvpn-cli disconnect
}

$1
