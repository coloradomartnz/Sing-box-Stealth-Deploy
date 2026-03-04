#!/usr/bin/env bash
#
# Step 02: Directories and Scripts
#

deploy_step_02() {
	log_step "========== [第 ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] 创建目录与部署脚本 =========="

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
		"templates/sing-box-config-gen.sh:/usr/local/libexec/sing-box-config-gen.sh"
		"lib/globals.sh:/usr/local/etc/sing-box/lib/globals.sh"
		"lib/utils.sh:/usr/local/etc/sing-box/lib/utils.sh"
		"lib/checks.sh:/usr/local/etc/sing-box/lib/checks.sh"
		"lib/lock.sh:/usr/local/etc/sing-box/lib/lock.sh"
		"lib/ruleset.sh:/usr/local/etc/sing-box/lib/ruleset.sh"
		"lib/service.sh:/usr/local/etc/sing-box/lib/service.sh"
	)

	# 创建安全凭据目录
	local cred_dir="/usr/local/etc/sing-box/.credentials"
	_run mkdir -p "$cred_dir"
	_run chown root:root "$cred_dir"
	_run chmod 700 "$cred_dir"

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

	# 2.2.5 Deploy Go Watchdog sidecar
	_deploy_watchdog_binary "$PROJECT_DIR"

	# 2.3 初始化自定义分流规则列表
	log_info "初始化自定义分流列表..."
	_run touch /usr/local/etc/sing-box/direct_list.txt
	_run touch /usr/local/etc/sing-box/proxy_list.txt
	_run chmod 644 /usr/local/etc/sing-box/direct_list.txt /usr/local/etc/sing-box/proxy_list.txt

	echo ""
}

# ---------------------------------------------------------------------------
# _deploy_watchdog_binary <project_root>
# 优先从 GitHub Release 下载预编译的 amd64 二进制，若失败且本地有 Go 则尝试动态编译
# ---------------------------------------------------------------------------
_deploy_watchdog_binary() {
	local project_root="$1"
	local target="/usr/local/bin/singbox-watchdog"
	local watchdog_src="$project_root/cmd/watchdog"

	log_info "部署 singbox-watchdog (Go Sidecar)..."

	# 1. 尝试从 GitHub Release 下载 (推荐，无环境依赖)
	if download_release_asset "singbox-watchdog" "$target"; then
		chmod +x "$target"
		log_info "  ✓ 已成功下载并部署预编译 Watchdog"
		return 0
	fi
	log_warn "  预编译二进制下载失败，尝试本地编译..."

	# 2. 回退到本地编译 (仅当有 Go 环境时)
	if command -v go &>/dev/null && [ -d "$watchdog_src" ]; then
		log_info "  本地 Go 环境就绪，正在尝试编译..."
		# GOTOOLCHAIN=local 防止 Go 尝试下载新版本工具链（可能导致 sudo 环境挂起）
		if _run bash -c "export GOTOOLCHAIN=local && cd $watchdog_src && go build -ldflags \"-s -w\" -o $target ."; then
			chmod +x "$target"
			log_info "  ✓ 已通过本地编译部署 Go Watchdog"
			return 0
		else
			log_warn "  本地编译失败。"
		fi
	else
		[ ! -d "$watchdog_src" ] && log_warn "  ⚠ 未找到 cmd/watchdog 源代码。"
		! command -v go &>/dev/null && log_warn "  ⚠ 未检测到 Go 环境。"
	fi

	# 3. 如果都失败了，视情况决定是否报错（目前 Watchdog 是非核心组件）
	log_warn "  ⚠ 无法获取 Watchdog 二进制。将在缺少 Watchdog 模式下运行。"
	return 0
}

