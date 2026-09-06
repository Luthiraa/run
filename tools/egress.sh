#!/bin/sh
# Explicit host routing for one VM. Run grants still filter every outbound frame.
# Usage: sudo sh tools/egress.sh up|down VM_ID UPLINK
set -eu
case ${1-} in up) op=-A ;; down) op=-D ;; *) exit 2 ;; esac
case ${2-} in [0-7]) ;; *) exit 2 ;; esac
test "$#" = 3
test "$(id -u)" = 0
tap=run$2
guest=10.0.$2.2/32
uplink=$3
ip link show dev "$uplink" >/dev/null
rule() {
    table=$1; shift
    if iptables -w -t "$table" -C "$@" 2>/dev/null; then
        test "$op" = -A || iptables -w -t "$table" -D "$@"
    else
        test "$op" = -D || iptables -w -t "$table" -A "$@"
    fi
}
if test "$op" = -A; then
    ip link show dev "$tap" >/dev/null
    sysctl -w net.ipv4.ip_forward=1
fi
rule nat POSTROUTING -s "$guest" -o "$uplink" -m comment --comment "$tap" -j MASQUERADE
rule filter FORWARD -i "$tap" -o "$uplink" -s "$guest" -m comment --comment "$tap" -j ACCEPT
rule filter FORWARD -i "$uplink" -o "$tap" -d "$guest" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$tap" -j ACCEPT
# down removes only these exact rules; forwarding may serve other VMs, so stays on.
