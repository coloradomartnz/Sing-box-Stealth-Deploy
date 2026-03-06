#!/usr/bin/env bash
#
# Step 01: Preparation - Install sing-box, Pinning, and User Creation
#

deploy_step_01() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Install sing-box and base config =========="

	if [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		log_info "[Upgrade mode] Checking and updating sing-box core..."
		_run apt-get update
		_run apt-get install --only-upgrade -y sing-box
	else
		# Check and install required tools
		install_missing_tools || exit "${E_DEPENDENCY:-14}"
		download_bpf_object

		# Install sing-box
		if command -v sing-box &>/dev/null; then
			local CURRENT_VERSION REINSTALL
			CURRENT_VERSION=$(sing-box version 2>&1 | head -n1)
			log_warn "sing-box already installed: $CURRENT_VERSION"
			# Skip confirmation in auto or dry-run mode
			if [ "${AUTO_YES:-0}" -eq 0 ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
				read -p "Reinstall? [y/N]: " -n 1 -r REINSTALL
				echo
				if [[ $REINSTALL =~ ^[Yy]$ ]]; then
					_run apt-get remove -y sing-box || true
				fi
			fi
		fi

		if ! command -v sing-box &>/dev/null; then
			log_info "Configuring official APT source..."
			_run mkdir -p /etc/apt/keyrings
			curl -fsSL --connect-timeout 5 -m 30 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
			_run chmod a+r /etc/apt/keyrings/sagernet.asc

			cat >/etc/apt/sources.list.d/sagernet.sources <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

			log_info "Installing sing-box..."
			_run apt-get update
			_run apt-get install -y sing-box

			if [ "${DRY_RUN:-0}" -eq 0 ] && ! command -v sing-box &>/dev/null; then
				log_error "sing-box installation failed"
				exit "${E_DEPENDENCY:-14}"
			fi
		fi
	fi

	# Create dedicated system user
	log_info "Configuring sing-box system user..."
	if ! id -u sing-box >/dev/null 2>&1; then
		_run useradd -r -s /usr/sbin/nologin sing-box
		log_info "Created user sing-box"
	fi

	# Configure version pinning
	log_info "Configuring version pinning..."
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
		log_info "APT pinned to ${major_minor}.* 版本线"

		# Ubuntu 24.04+ specific
		if [[ "$OS_ID" == "Ubuntu" && "${OS_VERSION%%.*}" -ge 24 ]]; then
			cat >/etc/apt/apt.conf.d/51sing-box-no-auto-upgrade <<'EOF'
Unattended-Upgrade::Package-Blacklist {
    "sing-box";
};
EOF
			log_info "Disabled unattended-upgrades for sing-box"
		fi
	fi

	echo ""
}

download_bpf_object() {
	local bpf_dest="/usr/local/share/sing-box/tproxy_tc.bpf.o"
	local kernel_major kernel_minor
	kernel_major=$(uname -r | cut -d. -f1)
	kernel_minor=$(uname -r | cut -d. -f2)

	# Remove old entry before appending (prevent duplicates)
	_set_ebpf_mode() {
		sed -i '/^EBPF_TC_MODE=/d' "$DEPLOYMENT_CONFIG" 2>/dev/null || true
		echo "EBPF_TC_MODE=$1" >> "$DEPLOYMENT_CONFIG"
	}

	# Kernel version gate: CO-RE requires BTF (>= 5.10 for stable TC redirect)
	if [ "$kernel_major" -lt 5 ] || { [ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -lt 10 ]; }; then
		log_warn "Kernel $(uname -r) < 5.10, skipping eBPF TC mode, falling back to ip rule fwmark"
		_set_ebpf_mode 0
		return 0
	fi

	# Check for BTF support (/sys/kernel/btf/vmlinux)
	if [ ! -f /sys/kernel/btf/vmlinux ]; then
		log_warn "Kernel lacks BTF (CONFIG_DEBUG_INFO_BTF not enabled), falling back"
		_set_ebpf_mode 0
		return 0
	fi

	mkdir -p "$(dirname "$bpf_dest")"

	if ! download_release_asset "tproxy_tc.bpf.o" "$bpf_dest"; then
		log_warn "Cannot fetch BPF release asset (API rate limit, timeout, or no binary published), falling back to ip rule mode"
		_set_ebpf_mode 0
		return 0
	fi

	# Validate ELF magic and BTF section
	if ! file "$bpf_dest" | grep -q "ELF.*BPF"; then
		log_error "Downloaded .bpf.o has invalid format"
		rm -f "$bpf_dest"
		_set_ebpf_mode 0
		return 1
	fi

	log_info "OK BPF CO-RE object ready: $bpf_dest"
	_set_ebpf_mode 1

	# Target only needs libbpf (runtime) + bpftool (map ops), not clang/llvm
	# Ubuntu 24.04+ ships bpftool as virtual pkg and libbpf1 instead of libbpf0
	local bpf_pkgs=("bpftool" "libbpf0")
	if [[ "$OS_ID" == "Ubuntu" ]]; then
		bpf_pkgs=("linux-tools-common")
		if [[ "${OS_VERSION%%.*}" -ge 24 ]]; then
			bpf_pkgs+=("libbpf1")
		else
			bpf_pkgs+=("libbpf0")
		fi
	fi

	log_info "Installing eBPF runtime dependencies: ${bpf_pkgs[*]}..."
	# P1 修复：改用 _run 以支持 DRY_RUN 模式并保留 dpkg 锁重试逻辑；去掉 2>/dev/null 使错误可见
	_run apt-get install -y --no-install-recommends "${bpf_pkgs[@]}" || \
		log_warn "eBPF dependency install failed, TC redirect may not work"
}
