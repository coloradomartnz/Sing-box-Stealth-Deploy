#!/usr/bin/env bash
#
# sing-box Stealth+ Residential Proxy Watchdog
#

# 凭据配置（由 Systemd LoadCredential 安全注入）
RES_HOST="${RES_HOST}"
RES_PORT="${RES_PORT}"
RES_USER=$(cat "$CREDENTIALS_DIRECTORY/res_user" 2>/dev/null || echo "")
RES_PASS=$(cat "$CREDENTIALS_DIRECTORY/res_pass" 2>/dev/null || echo "")

CLASH_API="http://127.0.0.1:${DASHBOARD_PORT}"
CLASH_SECRET=$(cat "$CREDENTIALS_DIRECTORY/dash_secret" 2>/dev/null || echo "sing-box")
SELECTOR_TAG="🤖 AI专用-精准分流"
RES_OUTBOUND="🏠 住宅代理-中转出口"
FALLBACK_OUTBOUND="🚀 节点选择"

# 检查住宅代理可用性
_check_res() {
    # 通过住宅代理隧道测试 OpenAI API
    # 200/401/403 均视为“网络通畅”（401=免Key测试, 403=Cloudflare拦截但IP没死）
    curl -s --max-time 10 \
         --proxy "socks5h://${RES_USER}:${RES_PASS}@${RES_HOST}:${RES_PORT}" \
         "https://api.openai.com/v1/models" \
         -o /dev/null -w "%{http_code}" 2>/dev/null
}

# 切换出站组
_switch_to() {
    local target="$1"
    curl -s -X PUT "${CLASH_API}/proxies/${SELECTOR_TAG}" \
         -H "Authorization: Bearer ${CLASH_SECRET}" \
         -H "Content-Type: application/json" \
         -d "{\"name\": \"${target}\"}" >/dev/null
}

CURRENT_STATE="unknown"

# 初始检测
echo "[*] sing-box Watchdog 启动..."

while true; do
    HTTP_CODE=$(_check_res)
    
    if [[ "$HTTP_CODE" =~ ^(200|401|403)$ ]]; then
        if [[ "$CURRENT_STATE" != "residential" ]]; then
            echo "[+] 住宅代理可用 (HTTP $HTTP_CODE)，切换至住宅出口"
            _switch_to "$RES_OUTBOUND"
            CURRENT_STATE="residential"
        fi
    else
        if [[ "$CURRENT_STATE" != "fallback" ]]; then
            echo "[!] 住宅代理异常 (HTTP $HTTP_CODE)，降级切换至机场节点"
            _switch_to "$FALLBACK_OUTBOUND"
            CURRENT_STATE="fallback"
        fi
    fi
    
    sleep 60
done
