#!/usr/bin/env bash
#
# sing-box deployment project - service management utilities
# 审计修复(R-06): 提取公共的校验→重载→健康检查模式为统一函数
#

# 安全重载 sing-box 服务
# 用法: safe_reload_sing_box <config_path> [rollback_callback]
# 功能: 校验配置 → 重载/重启服务 → 验证健康状态
# 返回: 0=成功 非0=失败
safe_reload_sing_box() {
	local config="${1:-/usr/local/etc/sing-box/config.json}"
	local rollback_fn="${2:-}"
	local sb_bin="${SING_BOX_BIN:-/usr/bin/sing-box}"

	# 1. JSON 语法校验
	if ! jq empty "$config" >/dev/null 2>&1; then
		log_error "配置文件 JSON 语法错误: $config"
		[ -n "$rollback_fn" ] && "$rollback_fn" "JSON 语法错误"
		return 1
	fi

	# 2. sing-box 语义校验
	log_info "校验配置文件合法性..."
	if ! "$sb_bin" check -c "$config" >/dev/null 2>&1; then
		log_error "sing-box 配置校验未通过: $config"
		"$sb_bin" check -c "$config" 2>&1 | head -20 >&2
		[ -n "$rollback_fn" ] && "$rollback_fn" "配置校验失败"
		return 1
	fi

	# 3. 修复权限
	if id -u sing-box >/dev/null 2>&1; then
		chown root:sing-box "$config" 2>/dev/null || true
		chmod 640 "$config" 2>/dev/null || true
	fi

	# 4. 尝试热重载 (reload)，降级为重启 (restart)
	log_info "重载 sing-box 服务..."
	if ! systemctl reload sing-box 2>/dev/null; then
		log_warn "热重载失败，尝试完整重启..."
		if ! systemctl restart sing-box; then
			log_error "sing-box 服务重启失败"
			[ -n "$rollback_fn" ] && "$rollback_fn" "服务重启失败"
			return 1
		fi
	fi

	# 5. 健康检查
	sleep 3
	if systemctl is-active --quiet sing-box; then
		log_info "✅ sing-box 服务运行正常"
		# 检查 TUN 接口
		if ip link show singbox_tun >/dev/null 2>&1; then
			log_info "  ✓ TUN 接口已就绪"
		else
			log_warn "  ⚠ TUN 接口未检测到（可能仍在初始化）"
		fi
		return 0
	else
		log_error "❌ sing-box 服务启动后异常，请检查日志"
		journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
		[ -n "$rollback_fn" ] && "$rollback_fn" "服务启动后异常"
		return 1
	fi
}
