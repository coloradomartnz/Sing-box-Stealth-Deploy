#!/usr/bin/env bash
#
# Stealth+ Residential Proxy Module Verification Test (Structural)
#

set -e
set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$PROJECT_ROOT/templates/config_template.json.tpl"
TMP_DIR="$PROJECT_ROOT/tests/tmp"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# Mock values
TUN_ADDRESS='"172.18.0.1/30"'
DNS_STRATEGY='"strategy": "prefer_ipv4",'
BOOTSTRAP_DNS="8.8.8.8"
DASHBOARD_PORT=9090
DASHBOARD_SECRET="test-secret"
MTU=1400
LAN="192.168.1.0/24"

verify_config() {
    local has_res="$1"
    local res_host="$2"
    local res_port="$3"
    
    echo "--- Testing scenario: Residential Proxy ($has_res) ---"
    
    local tmp_json="$TMP_DIR/config.json"
    local tmp_base="$TMP_DIR/base.json"
    
    # 1. 模拟 Step 06 sed 替换阶段
    sed -e "s|\${TUN_ADDRESS}|$TUN_ADDRESS|g" \
        -e "s|\${DNS_STRATEGY}|$DNS_STRATEGY|g" \
        -e "s|\${BOOTSTRAP_DNS_IPV4}|$BOOTSTRAP_DNS|g" \
        -e "s|\${LOCAL_DOH_HOST}|dns.alidns.com|g" \
        -e "s|\${LOCAL_DOH_PATH}|/dns-query|g" \
        -e "s|\${REMOTE_CF_HOST}|cloudflare-dns.com|g" \
        -e "s|\${REMOTE_CF_PATH}|/dns-query|g" \
        -e "s|\${REMOTE_MAIN_TAG}|remote_cf|g" \
        -e "s|\${DASHBOARD_PORT}|$DASHBOARD_PORT|g" \
        -e "s|\${DASHBOARD_SECRET}|$DASHBOARD_SECRET|g" \
        -e "s|\${RECOMMENDED_TUN_MTU}|$MTU|g" \
        -e "s|\${LAN_SUBNET}|$LAN|g" \
        -e "s|\${RES_HOST}|$res_host|g" \
        -e "s|\${RES_PORT_INT}|${res_port:-0}|g" \
        -e "s|\${RES_USER}|user|g" \
        -e "s|\${RES_PASS}|pass|g" \
        "$TEMPLATE" > "$tmp_base"

    # 2. 模拟 Step 06 jq 处理阶段
    jq --argjson cr "[]" \
       --argjson cd "[]" \
       --argjson nd "null" \
       --arg has_res "$has_res" \
       '
       .route.rules = (.route.rules[:2] + $cr + .route.rules[2:]) |
       .dns.rules = ($cd + .dns.rules) |
       (if $nd != null then .dns.servers = (.dns.servers[:3] + [$nd] + .dns.servers[3:]) else . end) |
       (if $has_res == "" then
         del(.outbounds[] | select(.tag == "🏠 住宅代理-中转出口")) |
         (.outbounds[] |= if .tag == "🤖 AI专用-精准分流" then .outbounds = ["🚀 节点选择", "direct"] | .default = "🚀 节点选择" else . end)
       else . end)
       ' "$tmp_base" > "$tmp_json"

    # 3. 结构化验证
    if [[ "$has_res" == "1" ]]; then
        # 必须存在住宅出站
        jq -e '.outbounds[] | select(.tag == "🏠 住宅代理-中转出口")' "$tmp_json" >/dev/null
        # AI 组默认必须指向住宅代理
        local default_out
        default_out=$(jq -r '.outbounds[] | select(.tag == "🤖 AI专用-精准分流") | .default' "$tmp_json")
        if [[ "$default_out" != "🏠 住宅代理-中转出口" ]]; then
            echo "FAILED: AI group default incorrect ($default_out)"
            exit 1
        fi
        echo "  [✓] Residential outbound present and prioritized"
    else
        # 必须删除住宅出站
        if jq -e '.outbounds[] | select(.tag == "🏠 住宅代理-中转出口")' "$tmp_json" >/dev/null; then
            echo "FAILED: Residential outbound still present"
            exit 1
        fi
        # AI 组必须降级到普通节点
        local default_out
        default_out=$(jq -r '.outbounds[] | select(.tag == "🤖 AI专用-精准分流") | .default' "$tmp_json")
        if [[ "$default_out" != "🚀 节点选择" ]]; then
            echo "FAILED: AI group default not downgraded ($default_out)"
            exit 1
        fi
        echo "  [✓] Residential outbound removed and AI group downgraded"
    fi
    
    # 4. JSON 语法基本验证
    jq empty "$tmp_json"
    echo "  [✓] JSON structure valid"
    
    echo "SUCCESS: Scenario passed"
}

# Run tests
verify_config "1" "1.2.3.4" "1080"
verify_config "" "" ""

echo ""
echo "All Stealth+ structural tests passed!"
