#!/usr/bin/env bash
#
# Step 05: Setup MetacubexD Dashboard UI
#

deploy_step_05() {
	log_step "========== [5/7] 安装 MetacubexD 面板 =========="

	if [ "${ENABLE_DASHBOARD:-0}" -ne 1 ]; then
		log_info "用户选择不开启面板，跳过安装"
		return 0
	fi

	local ui_dir="/usr/local/etc/sing-box/ui"
	
	# 判断面板是否已安装（目录存在且有内容）
	local ui_installed=0
	if [ -d "$ui_dir" ] && [ "$(find "$ui_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)" -gt 0 ]; then
		ui_installed=1
	fi
	
	if [ "$ui_installed" -eq 1 ] && [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		# 面板已安装，升级模式下只有用户明确要求时才重装
		if [ "${AUTO_YES:-0}" -eq 1 ]; then
			log_info "面板已存在，升级模式下跳过下载"
			return 0
		fi
		read -r -p "面板已存在，是否重新下载最新资源？[y/N]: " REINSTALL_UI
		if [[ ! "$REINSTALL_UI" =~ ^[Yy]$ ]]; then
			return 0
		fi
	elif [ "$ui_installed" -eq 0 ]; then
		# 面板不存在或为空目录 — 无论什么模式都安装
		log_info "面板尚未安装，自动下载..."
	fi

	log_info "正在从 GitHub 下载 MetacubexD 静态资源..."
	local tmp_file="/tmp/metacubexd.tgz"
	
	if ! curl -Lo "$tmp_file" "$METACUBEXD_URL"; then
		log_warn "下载 MetacubexD 失败，跳过面板安装 (代理核心功能不受影响)"
		return 0
	fi

	log_info "正在解压到 $ui_dir..."
	_run mkdir -p "$ui_dir"
	if ! _run tar -zxf "$tmp_file" -C "$ui_dir"; then
		log_warn "解压面板资源失败，跳过面板安装"
		rm -f "$tmp_file"
		return 0
	fi

	_run rm -f "$tmp_file"
	log_info "MetacubexD 面板安装完成 ✓"
}
