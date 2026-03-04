#!/usr/bin/env bash
#
# Step 08: Stealth+ Extension (Residential Proxy & Watchdog)
#

deploy_step_08() {
	log_step "========== [第 ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Stealth+ 住宅 IP 增强 (可选) =========="

	# 1. 检测是否需要配置
	local enable_res="n"
	if [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		# 升级模式下，检查是否已有配置
		if [ -f "$DEPLOYMENT_CONFIG" ]; then
			_safe_source_deployment_config "$DEPLOYMENT_CONFIG"
			if [ -n "${RES_HOST:-}" ]; then
				enable_res="y"
				log_info "检测到既有住宅代理配置，将自动维护监控服务"
			fi
		fi
	fi

	if [ "$UPGRADE_MODE" -eq 0 ] && [ "$AUTO_YES" -eq 0 ]; then
		read -r -p "是否集成住宅 IP 代理链与自动回滚监控？[y/N]: " enable_res_input
		enable_res=${enable_res_input:-n}
	fi

	if [[ ! "$enable_res" =~ ^[Yy]$ ]]; then
		log_info "跳过 Stealth+ 增强模块"
		return 0
	fi

	# 2. 已由 singbox-deploy.sh 收集，此处仅降级验证
	if [ -z "${RES_HOST:-}" ]; then
		log_info "未配置住宅代理 Host，跳过 Watchdog 部署"
		return 0
	fi

	# 3. 部署监控脚本
	log_info "部署住宅代理监控脚本 (Watchdog)..."
	local watchdog_tpl watchdog_dest
	watchdog_tpl="$(dirname "$(readlink -f "$0")")/templates/residential-watchdog.sh.tpl"
	watchdog_dest="/usr/local/bin/singbox-residential-watchdog.sh"

	if [ -f "$watchdog_tpl" ]; then
		# 审计修复(C-07): 转义用户输入防止 sed 分隔符注入
		local safe_res_host safe_res_port safe_dash_port
		safe_res_host=$(_sed_escape_replacement "$RES_HOST")
		safe_res_port=$(_sed_escape_replacement "$RES_PORT")
		safe_dash_port=$(_sed_escape_replacement "${DASHBOARD_PORT:-9090}")
		sed -e "s|\${RES_HOST}|$safe_res_host|g" \
		    -e "s|\${RES_PORT}|$safe_res_port|g" \
		    -e "s|\${DASHBOARD_PORT}|$safe_dash_port|g" \
		    "$watchdog_tpl" > "$watchdog_dest"
		chmod +x "$watchdog_dest"
		log_info "  ✓ 监控脚本已就绪: $watchdog_dest"
	else
		log_error "监控脚本模板不存在: $watchdog_tpl"
		return 1
	fi

	# 4. 部署 Systemd 服务
	log_info "配置监控服务..."
	local service_tpl service_dest
	service_tpl="$(dirname "$(readlink -f "$0")")/templates/watchdog.service.tpl"
	service_dest="/etc/systemd/system/singbox-residential-watchdog.service"

	if [ -f "$service_tpl" ]; then
		cp "$service_tpl" "$service_dest"
		systemctl daemon-reload
		systemctl enable singbox-residential-watchdog.service
		systemctl restart singbox-residential-watchdog.service
		log_info "  ✓ 监控服务已启动"
	else
		log_error "服务模板不存在: $service_tpl"
		return 1
	fi

	log_info "Stealth+ 模块部署成功！"
	log_info "AI/Streaming 流量将优先通过住宅 IP 运行，若不可用将自动切回机场节点。"
	echo ""
}
