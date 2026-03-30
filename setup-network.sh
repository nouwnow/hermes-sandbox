#!/bin/bash
# Gebruik: sudo ./setup-network.sh
# Maakt de tap-interface en NAT aan voor de hermes MicroVM.
# Subnetten: nanoclaw=vmtap0/10.0.0.x, openclaw=vmtap1/10.0.1.x, hermes=vmtap2/10.0.2.x
# Moet opnieuw uitgevoerd worden na een reboot (tenzij systemd-networkd gebruikt wordt).

USER_NAME="${SUDO_USER:-$(whoami)}"  # automatisch de aanroepende gebruiker
TAP_DEV="vmtap2"
HOST_IP="10.0.2.1"

# 1. Interface
ip tuntap add dev $TAP_DEV mode tap user $USER_NAME multi_queue
ip addr add $HOST_IP/24 dev $TAP_DEV
ip link set $TAP_DEV up

# 2. Routing
sysctl net.ipv4.ip_forward=1

# 3. NAT/Firewall
INT_IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $INT_IFACE -j MASQUERADE
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $TAP_DEV -o $INT_IFACE -j ACCEPT

echo "Netwerk voor Hermes MicroVM is klaar op $TAP_DEV ($HOST_IP)"
