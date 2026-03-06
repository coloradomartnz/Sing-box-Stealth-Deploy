#!/usr/bin/env bash
# O-Secure 5.3: Generate in-memory sing-box config using Systemd Credentials
# This is executed by ExecStartPre in sing-box.service
# 审计修复(C-06): 增加 set -u 防止未绑定变量静默失败
set -eu

# Credentials injected by Systemd LoadCredential
# 审计修复(C-06): 当 CREDENTIALS_DIRECTORY 未设置时给出明确错误
if [ -z "${CREDENTIALS_DIRECTORY:-}" ]; then
    echo "[ERROR] CREDENTIALS_DIRECTORY 未设置。该脚本应由 Systemd ExecStartPre 调用，不应手动执行。" >&2
    exit 1
fi

DASH_SEC=$(cat "$CREDENTIALS_DIRECTORY/dash_secret" 2>/dev/null || echo "sing-box")
RES_PASS=$(cat "$CREDENTIALS_DIRECTORY/res_pass" 2>/dev/null || echo "")
RES_USER=$(cat "$CREDENTIALS_DIRECTORY/res_user" 2>/dev/null || echo "")

mkdir -p /run/sing-box

# 审计修复(C-06): 使用原子写入，防止 jq 中途 OOM kill 导致半截 JSON
# Note: config_template.json is generated statically by singbox-deploy.sh and contains ALL settings EXCEPT the sensitive ones.
jq --arg sec "$DASH_SEC" \
   --arg pass "$RES_PASS" \
   --arg user "$RES_USER" '
  .experimental.clash_api.secret = $sec |
  (if $pass != "" then
    (.outbounds[] | select(.tag == "🏠 住宅代理-中转出口") | .password) = $pass |
    (.outbounds[] | select(.tag == "🏠 住宅代理-中转出口") | .username) = $user
  else . end)
' /usr/local/etc/sing-box/config.json > /run/sing-box/config.json.tmp \
  && mv /run/sing-box/config.json.tmp /run/sing-box/config.json
