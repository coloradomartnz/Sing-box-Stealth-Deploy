#!/usr/bin/env bash
#
# Step 02: Directories and Scripts
#

deploy_step_02() {
	log_step "========== [2/7] 创建目录与部署脚本 =========="

	# 2.1 创建目录结构
	_run mkdir -p /usr/local/etc/sing-box/backups/{daily,weekly,monthly}
	_run mkdir -p /usr/local/etc/sing-box/docs
	_run mkdir -p /var/lib/sing-box/ruleset
	_run chown -R sing-box:sing-box /var/lib/sing-box 2>/dev/null || true
	_run chmod 750 /var/lib/sing-box
	# ruleset 子目录需要可被 sing-box check (root) 和 sing-box service 共同访问
	_run chmod 755 /var/lib/sing-box/ruleset
	# 清理历次部署遗留的 .tmp 文件
	find /var/lib/sing-box/ruleset -name "*.tmp.*" -delete 2>/dev/null || true

	# 2.2 部署管理脚本 (从项目根目录复制)
	log_info "部署管理脚本..."
	local project_root
	project_root="$(dirname "$(readlink -f "$0")")"
	
	local target_scripts=(
		"scripts/singbox_dns_failover.sh:/usr/local/bin/singbox_dns_failover.sh"
		"scripts/singbox_ruleset_weekly_update.sh.tpl:/usr/local/bin/singbox_ruleset_weekly_update.sh"
		"scripts/add_docker_route.sh:/usr/local/bin/add_docker_route.sh"
		"scripts/singbox_build_region_groups.py:/usr/local/bin/singbox_build_region_groups.py"
		"scripts/update_and_restart.sh:/usr/local/etc/sing-box/update_and_restart.sh"
		"scripts/backup.sh:/usr/local/etc/sing-box/backup.sh"
		"lib/globals.sh:/usr/local/etc/sing-box/lib/globals.sh"
		"lib/utils.sh:/usr/local/etc/sing-box/lib/utils.sh"
		"lib/checks.sh:/usr/local/etc/sing-box/lib/checks.sh"
		"lib/lock.sh:/usr/local/etc/sing-box/lib/lock.sh"
		"lib/ruleset.sh:/usr/local/etc/sing-box/lib/ruleset.sh"
	)

	for pair in "${target_scripts[@]}"; do
		local src="${pair%%:*}"
		local dst="${pair##*:}"
		if [ -f "$project_root/$src" ]; then
			# 确保目标目录存在
			_run mkdir -p "$(dirname "$dst")"
			# 如果是 .tpl 脚本，需要进行简单的变量替换 (主要是 ruleset 链接)
			if [[ "$src" == *.tpl ]]; then
				sed -e "s|%%RULESET_GEOSITE_CN_URL%%|${RULESET_GEOSITE_CN_URL}|g" \
				    -e "s|%%RULESET_GEOSITE_GEOLOC_NONCN_URL%%|${RULESET_GEOSITE_GEOLOC_NONCN_URL}|g" \
				    -e "s|%%RULESET_GEOIP_CN_URL%%|${RULESET_GEOIP_CN_URL}|g" \
				    "$project_root/$src" > "$dst"
			else
				cp "$project_root/$src" "$dst"
			fi
			chmod +x "$dst"
			log_info "  ✓ 已部署: $dst"
		else
			log_warn "  ⚠ 源码缺失: $src (路径: $project_root/$src)"
		fi
	done

	# 2.2.5 Build and deploy Go Watchdog sidecar
	log_info "编译并部署 singbox-watchdog (Go Sidecar)..."
	if command -v go &>/dev/null && [ -d "$project_root/cmd/watchdog" ]; then
		_run bash -c "cd $project_root/cmd/watchdog && go build -o /usr/local/bin/singbox-watchdog ."
		log_info "  ✓ 已编译并部署 Go Watchdog"
	else
		log_warn "  ⚠ 未获取到 Go 环境或 cmd/watchdog 目录，跳过 Watchdog 构建 (如果在 CI 中已预构建则忽略此警告)"
	fi

	# 2.3 初始化自定义分流规则列表
	log_info "初始化自定义分流列表..."
	_run touch /usr/local/etc/sing-box/direct_list.txt
	_run touch /usr/local/etc/sing-box/proxy_list.txt
	_run chmod 644 /usr/local/etc/sing-box/direct_list.txt /usr/local/etc/sing-box/proxy_list.txt

	echo ""
}
