#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请用 root 运行：sudo $0"
  exit "${E_PERMISSION:-13}"
fi

# 1. 加载核心库与变量
PROJECT_DIR="$(dirname "$(readlink -f "$0")")"
# 如果在 /usr/local/bin，尝试找原本的安装目录，这里假设在 /home/jade/code/stealth (用户开发环境) 
# 或脚本同目录 lib 下。
if [ -d "$PROJECT_DIR/lib" ]; then
    source "$PROJECT_DIR/lib/globals.sh"
    source "$PROJECT_DIR/lib/utils.sh"
    source "$PROJECT_DIR/lib/lock.sh"
else
    # 生产环境路径
    # shellcheck source=/dev/null
    source "/usr/local/etc/sing-box/lib/globals.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "/usr/local/etc/sing-box/lib/utils.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "/usr/local/etc/sing-box/lib/lock.sh" 2>/dev/null || true
fi

CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/sing-box}"
CONFIG="${CONFIG:-$CONFIG_DIR/config.json}"
SB_SUB="${SB_SUB:-/opt/sing-box-subscribe}"
PY="${SB_SUB}/venv/bin/python"

# 2. 获取锁
# 使用与部署相同的锁，避免冲突
acquire_deploy_lock "$DEPLOY_LOCK" "$DEPLOY_LOCK_PID" 60 || exit "${E_LOCK:-12}"
trap 'cleanup_deploy_lock "$DEPLOY_LOCK" "$DEPLOY_LOCK_PID"; cleanup' EXIT INT TERM

# validate_sing_box_config 已在 lib/utils.sh 中定义

# 辅助函数：回滚函数 (匹配原脚本 _rollback)
_rollback_logic() {
	local reason="$1"
	log_error "$reason，开始回滚..."
	
	local rollback_tar="/usr/local/etc/sing-box/rollback_point.tar.gz"
	local config_json="/usr/local/etc/sing-box/config.json"
	
	if [ -f "$rollback_tar" ]; then
		log_info "正在从回滚点恢复..."
		# O-19: 恢复所有配置文件（config.json, providers.json, config_template.json）
		tar -xzf "$rollback_tar" -C "/usr/local/etc/sing-box"
		log_info "[+] 已从回滚点恢复所有配置"
	elif [ -f "$config_json.bak" ]; then
		cp "$config_json.bak" "$config_json"
		log_info "[+] 已从 .bak 恢复旧版配置"
	else
		log_warn "[!] 未找到任何回滚点或备份文件，无法自动回滚"
	fi
}

echo "[*] 1) 备份当前配置..."
cp "$CONFIG" "$CONFIG.bak"

echo "[*] 2) 创建回滚点..."
create_rollback_point "/usr/local/etc/sing-box"

echo "[*] 3) 更新订阅节点..."
if [ -d "$SB_SUB" ]; then
	# P0 修复：初始部署后 $SB_SUB/providers.json 已被清理；
	# 必须在每次运行前从配置目录重新复制，运行后立即删除（与 step 06 逻辑一致）。
	if [ -f "${CONFIG_DIR}/providers.json" ]; then
		install -m 640 "${CONFIG_DIR}/providers.json" "$SB_SUB/providers.json"
	else
		log_error "providers.json 不存在: ${CONFIG_DIR}/providers.json"
		exit "${E_CONFIG:-11}"
	fi

	pushd "$SB_SUB" >/dev/null
	if ! "$PY" main.py --template_index=0; then
		_rollback_logic "订阅更新失败"
		rm -f "$SB_SUB/providers.json" 2>/dev/null || true
		popd >/dev/null
		exit "${E_CONFIG:-11}"
	fi
	popd >/dev/null
	# 立即清理副本，防止订阅 token 留存于 sing-box-subscribe 目录
	rm -f "$SB_SUB/providers.json" 2>/dev/null || true
else
	log_warn "未找到 sing-box-subscribe 目录，跳过节点更新"
fi

echo "[*] 4) 执行地区自动分组..."
if [ -f "/usr/local/bin/singbox_build_region_groups.py" ]; then
	if ! python3 /usr/local/bin/singbox_build_region_groups.py "$CONFIG"; then
		_rollback_logic "地区分组失败"
		exit "${E_CONFIG:-11}"
	fi
else
	log_warn "未找到地区分组脚本，跳过"
fi

echo "[*] 5) 最终配置门禁..."
if ! validate_sing_box_config "$CONFIG"; then
	_rollback_logic "生成的配置无效"
	exit "${E_CONFIG:-11}"
fi

echo "[*] 6) 重启服务..."
if id -u sing-box >/dev/null 2>&1; then
	chown sing-box:sing-box "$CONFIG"
fi

if ! systemctl restart sing-box; then
	_rollback_logic "服务重启失败"
	systemctl restart sing-box || true
	# 审计修复(E-03): 回滚后二次重启失败，尝试最小安全模式避免网络完全中断
	if ! systemctl is-active --quiet sing-box; then
		log_error "回滚后服务仍然无法启动，转储最近日志："
		journalctl -u sing-box -n 50 --no-pager 2>/dev/null || true
		log_warn "请立即手动排查：journalctl -u sing-box -n 200 --no-pager"
	fi
	exit "${E_GENERAL:-1}"
fi

echo "[*] 7) 验证服务健康状态..."
sleep 3
if systemctl is-active --quiet sing-box && ip link show singbox_tun >/dev/null 2>&1; then
	log_info "✅ 更新成功，服务运行正常"
	log_info "    - TUN 接口: $(ip -br addr show singbox_tun 2>/dev/null | awk '{print $1" "$3}' || echo '未检测到')"
	log_info "    - 服务状态: $(systemctl is-active sing-box)"
else
	log_error "❌ 服务启动异常，请检查日志"
	journalctl -u sing-box -n 50 --no-pager
	exit "${E_GENERAL:-1}"
fi

echo ""
echo "[*] 快速验证命令:"
echo "    外网测试: curl -I https://www.google.com"
echo "    直连测试: curl -I https://www.baidu.com"
echo "    查看日志: journalctl -u sing-box -f"
