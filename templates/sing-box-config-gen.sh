#!/usr/bin/env bash
# O-Secure 5.3: Generate in-memory sing-box config using Systemd Credentials
# This is executed by ExecStartPre in sing-box.service
set -e

# Credentials injected by Systemd LoadCredential
DASH_SEC=$(cat "$CREDENTIALS_DIRECTORY/dash_secret" 2>/dev/null || echo "sing-box")
RES_PASS=$(cat "$CREDENTIALS_DIRECTORY/res_pass" 2>/dev/null || echo "")
RES_USER=$(cat "$CREDENTIALS_DIRECTORY/res_user" 2>/dev/null || echo "")

mkdir -p /run/sing-box

# Note: config_template.json is generated statically by singbox-deploy.sh and contains ALL settings EXCEPT the sensitive ones.
jq --arg sec "$DASH_SEC" \
   --arg pass "$RES_PASS" \
   --arg user "$RES_USER" '
  .experimental.clash_api.secret = $sec |
  (if $pass != "" then
    (.outbounds[] | select(.tag == "🏠 住宅代理-中转出口") | .password) = $pass |
    (.outbounds[] | select(.tag == "🏠 住宅代理-中转出口") | .username) = $user
  else . end)
' /usr/local/etc/sing-box/config_template.json > /run/sing-box/config.json
