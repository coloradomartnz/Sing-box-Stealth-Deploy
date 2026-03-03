#!/usr/bin/env bash
set -euo pipefail

# This script is specifically executed by the docker-smoke job using a container launched with
# --privileged --cap-add NET_ADMIN --device /dev/net/tun

echo "============================================="
echo "  Docker TUN Smoke Test Validation"
echo "============================================="

# 1. Verify existence of TUN device node
if [ ! -c /dev/net/tun ]; then
    echo "[ERROR] /dev/net/tun not found! Privileged wrapper failed."
    exit 1
fi

# 2. Try creating a TUN device programmatically
ip tuntap add dev test_tun mode tun
ip addr add 198.18.0.2/15 dev test_tun
ip link set test_tun up

# 3. Verify it is up
# TUN interfaces without an open fd show as UNKNOWN (not UP) — both are valid
LINK_STATE=$(ip link show test_tun)
if ! echo "$LINK_STATE" | grep -qE 'state (UP|UNKNOWN)'; then
    echo "[ERROR] Failed to bring test_tun interface UP"
    echo "Link state output: $LINK_STATE"
    exit 1
fi

echo "  \u2713 TUN kernel capabilities successfully validated."

# 4. Routing Table injection test
ip route add 8.8.4.4/32 dev test_tun table 205
if ! ip route show table 205 | grep -q "8.8.4.4"; then
    echo "[ERROR] Advanced customized routing table injection failed."
    exit 1
fi
echo "  \u2713 PBR specific routing tables validated."

# 5. Cleanup
ip link delete test_tun
echo "---------------------------------------------"
echo "  \u2705 ALL Privileged TUN Smoke Tests PASSED."
exit 0
