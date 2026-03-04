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
		install_missing_tools || exit "${E_DEPENDENCY:-14}"
		download_bpf_object

		# 1.2 安装 sing-box
		if command -v sing-box &>/dev/null; then
			local CURRENT_VERSION REINSTALL
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
				exit "${E_DEPENDENCY:-14}"
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

download_bpf_object() {
	local bpf_dest="/usr/local/share/sing-box/tproxy_tc.bpf.o"
	local kernel_ver
	kernel_ver=$(uname -r | cut -d. -f1-2 | tr -d '.')

	# 审计修复(C-08): 辅助函数，先清除旧行再追加，防止重复
	_set_ebpf_mode() {
		sed -i '/^EBPF_TC_MODE=/d' "$DEPLOYMENT_CONFIG" 2>/dev/null || true
		echo "EBPF_TC_MODE=$1" >> "$DEPLOYMENT_CONFIG"
	}

	# 内核版本门槛：CO-RE 需要 BTF 支持 (>= 5.4 有 BTF，>= 5.10 TC redirect 稳定)
	if [ "$kernel_ver" -lt 510 ]; then
		log_warn "内核 $(uname -r) < 5.10，跳过 eBPF TC 模式，保留 ip rule fwmark 回退"
		_set_ebpf_mode 0
		return 0
	fi

	# 检查是否已有可用 BTF (/sys/kernel/btf/vmlinux)
	if [ ! -f /sys/kernel/btf/vmlinux ]; then
		log_warn "内核缺少 BTF（CONFIG_DEBUG_INFO_BTF 未开启），回退"
		_set_ebpf_mode 0
		return 0
	fi

	mkdir -p "$(dirname "$bpf_dest")"

	# 从 GitHub Release 下载预编译对象，零编译依赖
	local release_url
	release_url=$(curl -sf "https://api.github.com/repos/coloradomartnz/Sing-box-Stealth-Deploy/releases/latest" | jq -r '.assets[] | select(.name == "tproxy_tc.bpf.o") | .browser_download_url')

	if [ -z "$release_url" ]; then
		log_warn "无法获取 BPF release 资产，回退到 ip rule 模式"
		_set_ebpf_mode 0
		return 0
	fi

	_run curl -fsSL -o "$bpf_dest" "$release_url"

	# 验证 ELF magic + BTF section（无需 clang，只需 file 命令）
	if ! file "$bpf_dest" | grep -q "ELF.*BPF"; then
		log_error "下载的 .bpf.o 格式无效"
		rm -f "$bpf_dest"
		_set_ebpf_mode 0
		return 1
	fi

	log_info "✓ BPF CO-RE 对象已就绪: $bpf_dest"
	_set_ebpf_mode 1

	# 目标机器只需 libbpf0（运行时）+ bpftool（map 操作），不需要 clang/llvm
	apt-get install -y --no-install-recommends libbpf0 bpftool 2>/dev/null || \
		log_warn "libbpf0 安装失败，TC redirect 可能降级"
}
