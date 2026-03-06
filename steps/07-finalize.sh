#!/usr/bin/env bash
#
# Step 07: Finalization - Systemd, AppArmor, TUN, Docker, Verify
#

deploy_step_07() {
	log_step "========== [第 ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] 系统集成与启动验证 =========="

	# shellcheck disable=SC2034
	local config_dir="/usr/local/etc/sing-box"
	local template_src_dir
	template_src_dir="$(dirname "$(readlink -f "$0")")/templates"

	# 5.1 Systemd-resolved 配置 (如果存在)
	if systemctl is-active --quiet systemd-resolved; then
		log_info "配置 systemd-resolved 忽略 TUN 接口..."
		_run mkdir -p /etc/systemd/resolved.conf.d
		_atomic_write /etc/systemd/resolved.conf.d/sing-box.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
	fi

	# 5.2 TUN 设备持久化
	log_info "配置 TUN 设备持久化..."
	if [ -f "$template_src_dir/tun.conf" ]; then
		cp "$template_src_dir/tun.conf" /etc/tmpfiles.d/tun.conf
		_run systemd-tmpfiles --create /etc/tmpfiles.d/tun.conf 2>/dev/null || true
	fi

	# 5.3 安装 Systemd 服务与 Timer
	log_info "部署 systemd 单元文件..."
	local systemd_units=(
		"sing-box.service"
		"singbox-watchdog.service"
		"singbox-healthcheck.service" "singbox-healthcheck.timer"
		"singbox-dns-failover.service" "singbox-dns-failover.timer"
		"singbox-ruleset-weekly-update.service" "singbox-ruleset-weekly-update.timer"
		"singbox-backup.service" "singbox-backup.timer"
	)
	for unit in "${systemd_units[@]}"; do
		if [ -f "$template_src_dir/$unit" ]; then
			cp "$template_src_dir/$unit" "/etc/systemd/system/$unit"
		fi
	done

	# 部署 Override 和 Journald 配置
	_run mkdir -p /etc/systemd/system/sing-box.service.d
	[ -f "$template_src_dir/sing-box.override.conf" ] && cp "$template_src_dir/sing-box.override.conf" /etc/systemd/system/sing-box.service.d/override.conf
	
	_run mkdir -p /etc/systemd/journald.conf.d
	if [ -f "$template_src_dir/sing-box.journald.conf" ]; then
		# 这里使用 atomic_write 并不太合适，直接 cp 即可（因为是新目录新文件）
		cp "$template_src_dir/sing-box.journald.conf" /etc/systemd/journald.conf.d/sing-box.conf
	fi

	_run systemctl daemon-reload
	_run systemctl enable sing-box singbox-watchdog.service singbox-healthcheck.timer singbox-ruleset-weekly-update.timer singbox-dns-failover.timer singbox-backup.timer

	# 5.4 AppArmor 安全策略
	if command -v apparmor_parser &>/dev/null && [ -f "$template_src_dir/usr.bin.sing-box.apparmor" ]; then
		log_info "配置 AppArmor 安全策略..."
		cp "$template_src_dir/usr.bin.sing-box.apparmor" /etc/apparmor.d/usr.bin.sing-box
		_run apparmor_parser -r /etc/apparmor.d/usr.bin.sing-box || true
	fi

	# 5.4.1 IPv6 安全加固 (Stealth Hardening)
	if [ "${HAS_IPV6:-0}" -eq 0 ]; then
		log_info "IPv4-Only 模式：执行 IPv6 侧漏防护 (Stealth Hardening)..."
		# A. 持久化 sysctl 禁用 IPv6 (除 lo 外)
		if [ -f "$template_src_dir/sing-box-stealth-ipv6-disable.conf" ]; then
			cp "$template_src_dir/sing-box-stealth-ipv6-disable.conf" /etc/sysctl.d/99-sing-box-stealth.conf
			_run sysctl -p /etc/sysctl.d/99-sing-box-stealth.conf || true
		fi
		# B. 注入全局黑洞路由，确保 WebRTC 无法通过旁路探测
		_run ip -6 route add blackhole default || true
	fi

	# 5.5 Docker 路由 (如果安装了 Docker)
	if command -v docker &>/dev/null; then
		log_info "检测到 Docker，执行初始路由注入..."
		# 自动执行
		/usr/local/bin/add_docker_route.sh --auto-yes || true
	fi

	# 5.6 桌面环境专项
	if [ "${IS_DESKTOP:-0}" -eq 1 ]; then
		log_info "配置桌面环境专项优化..."
		# NetworkManager
		if systemctl is-active --quiet NetworkManager; then
			log_info "配置 NetworkManager 排除 TUN 接口 (conf.d)..."
			_run mkdir -p /etc/NetworkManager/conf.d
			_atomic_write /etc/NetworkManager/conf.d/sing-box.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:singbox_tun
EOF
			_run systemctl restart NetworkManager || true
		fi
		# Resume hook
		[ -f "$template_src_dir/sing-box-resume" ] && cp "$template_src_dir/sing-box-resume" /usr/lib/systemd/system-sleep/sing-box-resume && chmod +x /usr/lib/systemd/system-sleep/sing-box-resume
	fi

	# 5.7 权限修复与启动
	# 精确修复已知文件/目录权限，避免 chown -R 递归扫描整棵目录树
	log_info "修复运行目录权限并启动服务..."
	_run chown sing-box:sing-box /var/lib/sing-box
	_run chown sing-box:sing-box /var/lib/sing-box/ruleset
	for _f in /var/lib/sing-box/ruleset/*.srs; do
		[ -f "$_f" ] && chown sing-box:sing-box "$_f" 2>/dev/null || true
	done
	_run chown root:sing-box /usr/local/etc/sing-box
	_run chmod 750 /usr/local/etc/sing-box
	for _f in config.json config_template.json providers.json; do
		[ -f "/usr/local/etc/sing-box/$_f" ] && \
			chown root:sing-box "/usr/local/etc/sing-box/$_f" && \
			chmod 640 "/usr/local/etc/sing-box/$_f" || true
	done
	
	if [ "${DRY_RUN:-0}" -eq 0 ]; then
		_run systemctl restart sing-box
		sleep 3
		if systemctl is-active --quiet sing-box; then
			log_info "✅ sing-box 服务已启动并通过初步验证"
			# H-2: IPv6 双栈环境下验证路由是否正确接管 (采用更稳健的内核查表模拟)
			if [ "${HAS_IPV6:-0}" -eq 1 ]; then
				local tun_if="singbox_tun"
				local test_v6="2606:4700:4700::1111"
				local ipv6_ok=0
				
				# 1. 基础检查：接口是否存在
				if ip link show "$tun_if" &>/dev/null; then
					# 2. 模拟内核查表 (ip route get 会穿透策略路由表)
					if ip -6 route get "$test_v6" 2>/dev/null | grep -q " dev $tun_if "; then
						ipv6_ok=1
					else
						# 3. 兼容性检查：如果是基于 fwmark 的策略路由，尝试带 mark 查表
						# 提取所有指向自定义表的 mark (例如 sing-box 默认的 table 2022)
						local custom_marks
						custom_marks=$(ip -6 rule show | awk '/lookup [0-9]+/ {for(i=1;i<=NF;i++) if($i=="fwmark") print $(i+1)}' | sort -u)
						for m in $custom_marks; do
							# 去掉掩码部分
							local m_val="${m%%/*}"
							if ip -6 route get "$test_v6" mark "$m_val" 2>/dev/null | grep -q " dev $tun_if "; then
								ipv6_ok=1
								break
							fi
						done
					fi
				fi

				if [ "$ipv6_ok" -eq 1 ]; then
					log_info "  ✓ IPv6 路由验证成功 (已通过内核查表确认接管)"
				else
					log_warn "  ⚠ IPv6 路由检测失败：流量可能未进入 $tun_if"
					log_warn "  建议检查: ip -6 rule show; ip -6 route show table all"
				fi
			fi
		else
			log_error "sing-box service failed to start, check logs"
		fi
	fi

	echo ""
}
