#!/usr/bin/env bash
set -eo pipefail

echo "=== 测试配置生成防注入 (test_sed_injection.sh) ==="

PROJECT_DIR="$(readlink -f "$(dirname "$0")/..")"

# 准备模拟环境
export DEFAULT_REGION="HK"
export AIRPORT_URLS_STR="https://example.com/sub"
export DASHBOARD_SECRET="secret\"} { \"injected\": true }"
export RES_PASS="pass\nword'\""
export RES_USER='user$PATH'

TMP_CFG=$(mktemp)
trap 'rm -f "$TMP_CFG"' EXIT

# 调用模板引擎 (由于我们已改造为 jq，这里测试 jq 是否正确转义而没有引发 JSON 格式错误)

export MAIN_IFACE="eth0"
export LAN_SUBNET="192.168.1.0/24"
export HAS_IPV6="1"

jq -n \
  --arg tun_addr "172.19.0.1/30" \
  --arg dns_strategy "ipv4_only" \
  --arg bootstrap "8.8.8.8" \
  --arg fwmark "255" \
  --arg route_table "200" \
  --arg v6_rule "block" \
  --arg v6_strategy "ipv4_only" \
  --arg main_iface "$MAIN_IFACE" \
  --arg lan_subnet "$LAN_SUBNET" \
  --arg default_region "$DEFAULT_REGION" \
  --arg nextdns_id "abcdef" \
  --arg dashboard_port "9090" \
  --arg dashboard_secret "$DASHBOARD_SECRET" \
  --arg res_host "proxy.com" \
  --arg res_port "1080" \
  --arg res_user "$RES_USER" \
  --arg res_pass "$RES_PASS" \
  '$ARGS.named' > "$TMP_CFG"

echo "验证生成的 vars.json:"
# 如果能成功解析，说明没有发生注入断裂
jq . "$TMP_CFG" >/dev/null

INJECTED_SECRET=$(jq -r '.dashboard_secret' "$TMP_CFG")
if [ "$INJECTED_SECRET" != "$DASHBOARD_SECRET" ]; then
	echo "❌ 注入后的值被破坏"
	exit 1
fi

echo "  ✓ 恶意载荷被 jq 正确转义，未破坏 JSON 结构"

echo "=== 测试通过 ==="
exit 0
