#!/usr/bin/env bash
# ============================================================================
# Sub-Store Config Updater & Hot Reload for Stealth / sing-box
# ============================================================================

set -euo pipefail

DEPLOYMENT_CONFIG="/usr/local/etc/sing-box/.deployment_config"

# C-02 修复: 使用正确的生产部署路径
SHARED_LIB_DIR="/usr/local/etc/sing-box/lib"

# 加载公共库（优先开发环境，其次生产路径）
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -d "$SCRIPT_DIR/../lib" ]; then
    SHARED_LIB_DIR="$SCRIPT_DIR/../lib"
fi

for _lib in globals.sh utils.sh lock.sh service.sh; do
    if [ -f "$SHARED_LIB_DIR/$_lib" ]; then
        # shellcheck source=/dev/null
        source "$SHARED_LIB_DIR/$_lib"
    else
        echo "[Error] 找不到代码依赖库: $SHARED_LIB_DIR/$_lib" >&2
        exit 1
    fi
done

# C-01 修复: 使用安全的白名单 source 替代裸 source
if [ -f "$DEPLOYMENT_CONFIG" ]; then
    _safe_source_deployment_config "$DEPLOYMENT_CONFIG"
else
    log_error "未找到部署配置文件: $DEPLOYMENT_CONFIG"
    exit 1
fi

if [ "${SUBSTORE_MODE:-0}" -ne 1 ]; then
    log_error "Sub-Store 模式未启用 (SUBSTORE_MODE!=1)。该更新器仅限 Sub-Store 模式下使用。"
    exit 1
fi

# 1. 解析面板挂载的鉴权路径
ss_path=""
if [ -f "/opt/sub-store/substore.env" ]; then
    ss_path=$(grep SUB_STORE_FRONTEND_BACKEND_PATH "/opt/sub-store/substore.env" | cut -d'=' -f2 || true)
fi

# E-05 修复: 等待 Sub-Store 服务就绪，避免冷启动竞态
log_info "等待 Sub-Store 服务就绪..."
_substore_ready=0
for _i in $(seq 1 15); do
    if curl -sf "http://127.0.0.1:${SUBSTORE_PORT:-2999}${ss_path}/api/utils/env" >/dev/null 2>&1; then
        _substore_ready=1
        break
    fi
    sleep 2
done
if [ "$_substore_ready" -eq 0 ]; then
    log_error "Sub-Store 服务未就绪 (http://127.0.0.1:${SUBSTORE_PORT:-2999})，请检查服务状态: systemctl status sub-store"
    exit 1
fi

# 2. 构建下载目标地址
COLLECTION_NAME="${SUBSTORE_COLLECTION_NAME:-MySubs}"
DOWNLOAD_URL="http://127.0.0.1:${SUBSTORE_PORT:-2999}${ss_path}/download/${COLLECTION_NAME}?target=sing-box"

log_info "从 Sub-Store 拉取节点组合 [${COLLECTION_NAME}]..."
log_info "🔗 接口地址: $DOWNLOAD_URL"

# 3. 生成一次性 providers.json
# 由于 Sub-Store 内部已经进行过去重和合并，这里强制把它当成一个单点 Airport
WORK_DIR="/usr/local/etc/sing-box"
TMP_PROVIDERS="$(mktemp /tmp/substore_providers_XXXXXX.json)"

cat > "$TMP_PROVIDERS" <<EOF
{
  "subscribes": [
    {
      "url": "$DOWNLOAD_URL",
      "tag": "SubStore",
      "enabled": true
    }
  ],
  "auto_set_outbounds_dns": {
    "proxy": "",
    "direct": ""
  },
  "save_config_path": "$WORK_DIR/config.json",
  "auto_backup": false,
  "exclude_protocol": "ssr",
  "config_template": "",
  "generate_info": true
}
EOF

# 4. 执行基于 sing-box-subscribe 的转换合并
log_info "执行节点转换与模板映射..."
if [ ! -d "/opt/sing-box-subscribe" ]; then
    log_error "未检测到核心转换组件 /opt/sing-box-subscribe"
    rm -f "$TMP_PROVIDERS"
    exit 1
fi

cp "$TMP_PROVIDERS" "/opt/sing-box-subscribe/providers.json"
rm -f "$TMP_PROVIDERS"

py_bin="/opt/sing-box-subscribe/venv/bin/python"
if ! (cd "/opt/sing-box-subscribe" && "$py_bin" main.py --template_index=0); then
    log_error "转换模板执行失败。请进入面板检查 Sub-Store 集合内是否正确包含了节点或是否有解析错误！"
    # 删除临时凭证，避免暴露
    rm -f "/opt/sing-box-subscribe/providers.json"
    exit 1
fi
rm -f "/opt/sing-box-subscribe/providers.json"

# 5. 生成按地区分组配置 (如果存在构建器)
if [ -f "/usr/local/bin/singbox_build_region_groups.py" ]; then
    log_info "生成地区节点流控组..."
    DEFAULT_REGION="${DEFAULT_REGION:-HK}" python3 /usr/local/bin/singbox_build_region_groups.py "$WORK_DIR/config.json"
fi

# 5.5 P2 修复：语义门禁——确保生成的配置含有效代理节点（与 step 06 E-01 一致）
_ss_outbound_count=$(jq '[.outbounds[] | select(
    .type != "direct" and .type != "block" and .type != "dns" and
    .type != "selector" and .type != "urltest"
)] | length' "$WORK_DIR/config.json" 2>/dev/null || echo "0")
if [ "$_ss_outbound_count" -eq 0 ]; then
    log_error "Sub-Store 更新后配置不含任何有效代理节点，中止热更新（请检查集合内订阅是否有效）"
    exit "${E_CONFIG:-11}"
fi
log_info "  ✓ 检测到 $_ss_outbound_count 个有效代理节点"

# 6. 配置预检与热更新 (使用 lib/service.sh 提供的安全重载函数)
if type safe_reload_sing_box &>/dev/null; then
    safe_reload_sing_box "$WORK_DIR/config.json"
else
    # 降级：直接校验并重载
    log_info "校验更新后的 sing-box 配置文件合法性..."
    if ! /usr/bin/sing-box check -c "$WORK_DIR/config.json"; then
        log_error "新配置校验未通过，请勿应用！"
        exit 1
    fi
    log_info "配置校验通过，重载网络连接守护..."
    systemctl reload sing-box
fi

log_info "🎉 Sub-Store 配置更新并生效成功！"
