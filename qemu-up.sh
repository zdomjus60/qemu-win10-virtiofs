#!/bin/bash
#
# Configura la rete per la VM QEMU/KVM:
#   bridge br0 + interfaccia tap0 + NAT verso l'uplink + DHCP (dnsmasq dedicato)
#
# Da eseguire come utente normale: lo script chiede la password sudo dove serve.
# Da rifare a ogni riavvio della macchina (la rete non sopravvive al reboot).
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# --- configurazione ---
BRIDGE_IF="br0"
TAP_IF="tap0"
VM_GATEWAY="192.168.100.1"
VM_DHCP_RANGE="192.168.100.10,192.168.100.200,255.255.255.0,12h"
VM_DNS="8.8.8.8,8.8.4.4"
DNSMASQ_PID="/run/qemu-dnsmasq.pid"
LEGACY_HOST_IF="enp3s0" # vecchio valore usato in passato, lo rimuoviamo

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  -> $*"; }

# --- interfaccia di uplink: la ricavo dalla route default ---
HOST_IF=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$HOST_IF" ] || err "no default route found: check the internet connection"
echo "Uplink interface: $HOST_IF"

# --- pulizia delle configurazioni precedenti (idempotente) ---
echo "Cleaning up previous configuration..."
if [ -f "$DNSMASQ_PID" ]; then
	sudo kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
	rm -f "$DNSMASQ_PID" 2>/dev/null || sudo rm -f "$DNSMASQ_PID"
fi
sudo systemctl stop dnsmasq 2>/dev/null || true

# regole iptables vecchie (uplink attuale e quello legacy)
for IF in "$HOST_IF" "$LEGACY_HOST_IF"; do
	sudo iptables -t nat -D POSTROUTING -o "$IF" -j MASQUERADE 2>/dev/null || true
	sudo iptables -D FORWARD -i "$BRIDGE_IF" -o "$IF" -j ACCEPT 2>/dev/null || true
	sudo iptables -D FORWARD -i "$IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
done
sudo iptables -D FORWARD -m physdev --physdev-is-bridged -j ACCEPT 2>/dev/null || true

sudo ip link set "$TAP_IF" down 2>/dev/null || true
sudo ip link set "$BRIDGE_IF" down 2>/dev/null || true
sudo ip link del "$TAP_IF" 2>/dev/null || true
sudo ip link del "$BRIDGE_IF" 2>/dev/null || true

# --- instradamento (NAT) della VM verso l'esterno ---
echo "Enabling packet forwarding (net.ipv4.ip_forward=1)..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- bridge ---
echo "Creating bridge $BRIDGE_IF with address $VM_GATEWAY/24..."
sudo ip link add name "$BRIDGE_IF" type bridge
sudo ip addr add "$VM_GATEWAY/24" dev "$BRIDGE_IF"
sudo ip link set "$BRIDGE_IF" up

# --- interfaccia tap per QEMU ---
OWNER="${SUDO_USER:-$(id -un)}"
echo "Creating interface $TAP_IF (owner: $OWNER)..."
sudo ip tuntap add dev "$TAP_IF" mode tap user "$OWNER"
sudo ip link set "$TAP_IF" up
sudo ip link set "$TAP_IF" master "$BRIDGE_IF"

# --- regole NAT/FORWARD ---
echo "Configuring iptables (NAT on $HOST_IF)..."
sudo iptables -t nat -A POSTROUTING -o "$HOST_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$BRIDGE_IF" -o "$HOST_IF" -j ACCEPT
sudo iptables -A FORWARD -i "$HOST_IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

# --- DHCP dedicato per la VM ---
echo "Starting dnsmasq (DHCP only, external DNS 8.8.8.8)..."
sudo dnsmasq \
	--conf-file= \
	--port=0 \
	--interface="$BRIDGE_IF" \
	--bind-interfaces \
	--dhcp-range="$VM_DHCP_RANGE" \
	--dhcp-option=option:router,"$VM_GATEWAY" \
	--dhcp-option=option:dns-server,"$VM_DNS" \
	--dhcp-authoritative \
	--pid-file="$DNSMASQ_PID"

sleep 0.5
[ -f "$DNSMASQ_PID" ] || err "dnsmasq did not start"

echo
info "bridge   : $BRIDGE_IF ($VM_GATEWAY/24) UP"
info "tap      : $TAP_IF  ->  $BRIDGE_IF (owner $OWNER)"
info "NAT      : via $HOST_IF (ip_forward active)"
info "DHCP     : $VM_DHCP_RANGE, gateway $VM_GATEWAY"
echo
echo "Now you can start the VM:  ./launch.sh"
