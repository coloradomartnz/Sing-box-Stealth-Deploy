#!/usr/bin/env bash
#
# Step 01: Preparation - Install sing-box, Pinning, and User Creation
#

deploy_step_01() {
	log_step "========== [1/7] 安装 sing-box 与基础配置 =========="

	if [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		log_info "[升级模式] 检查并更新 sing-box 核心..."
		_run apt-get update
		_run apt-get install --only-upgrade -y sing-box
	else
		# 1.1 必需工具检查与安装
		install_missing_tools || exit 1

		# 1.2 安装 sing-box
		if command -v sing-box &>/dev/null; then
			CURRENT_VERSION=$(sing-box version 2>&1 | head -n1)
			log_warn "sing-box 已安装：$CURRENT_VERSION"
			# 如果是自动模式或 dry-run，跳过确认
			if [ "${AUTO_YES:-0}" -eq 0 ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
				read -p "是否重新安装？[y/N]: " -n 1 -r REINSTALL
				echo
				if [[ $REINSTALL =~ ^[Yy]$ ]]; then
					_run apt-get remove -y sing-box || true
				fi
			fi
		fi

		if ! command -v sing-box &>/dev/null; then
			log_info "配置官方 APT 源..."
			_run mkdir -p /etc/apt/keyrings
			curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
			_run chmod a+r /etc/apt/keyrings/sagernet.asc

			cat >/etc/apt/sources.list.d/sagernet.sources <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

			log_info "安装 sing-box..."
			_run apt-get update
			_run apt-get install -y sing-box

			if [ "${DRY_RUN:-0}" -eq 0 ] && ! command -v sing-box &>/dev/null; then
				log_error "sing-box 安装失败"
				exit 1
			fi
		fi
	fi

	# 1.3 专用用户创建
	log_info "正在配置 sing-box 专用用户..."
	if ! id -u sing-box >/dev/null 2>&1; then
		_run useradd -r -s /usr/sbin/nologin sing-box
		log_info "已创建用户 sing-box"
	fi

	# 1.4 配置版本冻结 (Pinning)
	log_info "配置版本冻结策略..."
	local current_v
	current_v=$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null | cut -d'-' -f1)
	if [ -n "$current_v" ]; then
		local major_minor
		major_minor=$(echo "$current_v" | cut -d'.' -f1-2)
		cat >/etc/apt/preferences.d/sing-box <<EOF
Package: sing-box
Pin: version ${major_minor}.*
Pin-Priority: 1001
EOF
		log_info "已配置 APT Pin 到 ${major_minor}.* 版本线"

		# Ubuntu 24.04+ 专项
		if [[ "$OS_ID" == "Ubuntu" && "${OS_VERSION%%.*}" -ge 24 ]]; then
			cat >/etc/apt/apt.conf.d/51sing-box-no-auto-upgrade <<'EOF'
Unattended-Upgrade::Package-Blacklist {
    "sing-box";
};
EOF
			log_info "已禁用 sing-box 的 unattended-upgrades 自动更新"
		fi
	fi

	echo ""
}
