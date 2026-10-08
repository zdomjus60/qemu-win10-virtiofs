#!/bin/bash
#
# Rimuove la rete creata da qemu-up.sh:
# dnsmasq (DHCP), regole iptables, bridge br0 e interfaccia tap0.
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

BRIDGE_IF="br0"
TAP_IF="tap0"
DNSMASQ_PID="/run/qemu-dnsmasq.pid"
LEGACY_HOST_IF="enp3s0"

info() { echo "  -> $*"; }

# --- uplink corrente e legacy, per rimuovere le regole giuste ---
HOST_IF=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

# --- fermo il nostro dnsmasq (DHCP) ---
echo "Stopping dnsmasq (VM DHCP)..."
if [ -f "$DNSMASQ_PID" ]; then
	sudo kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
	sudo rm -f "$DNSMASQ_PID" 2>/dev/null || true
fi
sudo systemctl stop dnsmasq 2>/dev/null || true

# --- rimuovo le regole iptables che ho creato ---
echo "Removing iptables rules..."
IFACES="$HOST_IF"
[ -n "$HOST_IF" ] && [ "$HOST_IF" != "$LEGACY_HOST_IF" ] && IFACES="$HOST_IF $LEGACY_HOST_IF"
for IF in $IFACES; do
	sudo iptables -t nat -D POSTROUTING -o "$IF" -j MASQUERADE 2>/dev/null || true
	sudo iptables -D FORWARD -i "$BRIDGE_IF" -o "$IF" -j ACCEPT 2>/dev/null || true
	sudo iptables -D FORWARD -i "$IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
done
sudo iptables -D FORWARD -m physdev --physdev-is-bridged -j ACCEPT 2>/dev/null || true

# --- abbasso bridge e tap ---
echo "Removing $TAP_IF and $BRIDGE_IF..."
sudo ip link set "$TAP_IF" down 2>/dev/null || true
sudo ip link set "$BRIDGE_IF" down 2>/dev/null || true
sudo ip link del "$TAP_IF" 2>/dev/null || true
sudo ip link del "$BRIDGE_IF" 2>/dev/null || true

# nota: net.ipv4.ip_forward resta com'e' (lo usa anche Docker, se presente)

info "network configuration removed"
