#!/usr/bin/env bash
# e2e_vm_test.sh – lightweight end-to-end network validation
# Run inside a virtme VM (or any privileged environment) to verify that
# the host kernel supports the capabilities required by sing-box stealth mode.
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "============================================="
echo "  e2e VM Network Capability Test"
echo "============================================="

# ── 1. TUN/TAP ────────────────────────────────────────────────────────────────
echo "--- TUN/TAP ---"
if [ -c /dev/net/tun ]; then
  ok "/dev/net/tun device node exists"
else
  fail "/dev/net/tun not found"
fi

if ip tuntap add dev e2e_tun mode tun 2>/dev/null; then
  ip addr add 198.18.1.1/15 dev e2e_tun
  ip link set e2e_tun up
  ip link delete e2e_tun
  ok "TUN interface create/up/delete cycle"
else
  fail "Could not create TUN interface"
fi

# ── 2. Policy-Based Routing ────────────────────────────────────────────────────
echo "--- Policy-Based Routing ---"
if ip rule add fwmark 1 table 100 2>/dev/null; then
  ip rule del fwmark 1 table 100
  ok "ip rule fwmark"
else
  fail "ip rule fwmark not supported"
fi

# ── 3. nftables / iptables ────────────────────────────────────────────────────
echo "--- Netfilter ---"
if command -v nft >/dev/null 2>&1; then
  if nft list ruleset >/dev/null 2>&1; then
    ok "nftables available"
  else
    fail "nftables list failed"
  fi
else
  echo "  [SKIP] nft not installed"
fi

# ── 4. /sys/kernel/btf/vmlinux (CO-RE requirement) ───────────────────────────
echo "--- BTF / CO-RE ---"
if [ -f /sys/kernel/btf/vmlinux ]; then
  ok "/sys/kernel/btf/vmlinux exists (CO-RE supported)"
else
  fail "/sys/kernel/btf/vmlinux missing – kernel lacks BTF"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "---------------------------------------------"
echo "  Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ ALL e2e VM tests PASSED."
  exit 0
else
  echo "  ❌ Some tests FAILED."
  exit 1
fi
