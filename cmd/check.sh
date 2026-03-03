#!/usr/bin/env bash
#
# sing-box deployment project - check subcommand
#

do_check() {
	echo ""
	echo "========================================="
	echo "  sing-box 环境健康检查"
	echo "========================================="
	echo ""

	# 检测 root（但不强制要求）
	local is_root=0
	[ "$(id -u)" -eq 0 ] && is_root=1

	if [ $is_root -eq 0 ]; then
		log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		log_warn "当前以非 root 用户运行"
		log_warn "部分检查项可能无法执行，建议使用: sudo $0 --check"
		log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		echo ""
	fi

	local fail=0

	# 1. sing-box 安装与版本
	echo "[1/10] sing-box 安装检查..."
	if command -v sing-box &>/dev/null; then
		local sb_path sb_ver
		sb_path=$(command -v sing-box)
		sb_ver=$(sing-box version 2>&1 | head -n1)
		echo "  ✓ 已安装: $sb_path ($sb_ver)"
	else
		echo "  ✗ sing-box 未安装"
		fail=1
	fi

	# 2. 配置文件验证
	echo "[2/10] 配置文件检查..."
	local config="/usr/local/etc/sing-box/config.json"
	if [ -f "$config" ]; then
		echo "  ✓ 配置文件存在: $config"
		if jq empty "$config" >/dev/null 2>&1; then
			echo "  ✓ JSON 语法正确"
		else
			echo "  ✗ JSON 语法错误"
			fail=1
		fi
		if command -v sing-box &>/dev/null; then
			if validate_sing_box_config "$config" >/dev/null 2>&1; then
				echo "  ✓ sing-box check 通过"
			else
				echo "  ✗ sing-box check 失败"
				fail=1
			fi
		fi
	fi

	# 2.5 订阅配置验证
	echo "[3/10] 订阅配置 (providers.json) 检查..."
	local providers="/usr/local/etc/sing-box/providers.json"
	if [ -f "$providers" ]; then
		echo "  ✓ providers.json 存在"
		if jq empty "$providers" >/dev/null 2>&1; then
			echo "  ✓ JSON 语法正确"
		else
			echo "  ✗ JSON 语法错误"
			fail=1
		fi
	else
		echo "  ⚠ providers.json 不存在 (若不涉及订阅转换则忽略)"
	fi

	# 3. 规则集检查
	echo "[4/10] 规则集检查..."
	local ruleset_dir="/var/lib/sing-box"
	if [ -d "$ruleset_dir" ]; then
		local srs_count
		srs_count=$(find "$ruleset_dir" -name '*.srs' 2>/dev/null | wc -l)
		echo "  ✓ 规则集目录存在: $ruleset_dir ($srs_count 个 .srs 文件)"
		if [ "$srs_count" -eq 0 ]; then
			echo "  ⚠ 无 .srs 规则文件，需要运行更新"
		fi
	else
		echo "  ✗ 规则集目录不存在: $ruleset_dir"
		fail=1
	fi

	# 4. systemd 服务状态
	echo "[5/10] systemd 服务状态..."
	for svc in sing-box.service singbox-healthcheck.timer singbox-ruleset-weekly-update.timer singbox-backup.timer; do
		if systemctl is-active "$svc" &>/dev/null 2>&1; then
			echo "  ✓ $svc: active"
		elif systemctl is-enabled "$svc" &>/dev/null 2>&1; then
			echo "  ⚠ $svc: enabled 但未 active"
		elif systemctl list-unit-files "$svc" &>/dev/null 2>&1; then
			echo "  ✗ $svc: 未启用"
			fail=1
		else
			echo "  - $svc: 无法查询（需要 root 或单元不存在）"
		fi
	done

	# 5. TUN 接口
	echo "[6/10] TUN 接口检查..."
	if ip link show singbox_tun &>/dev/null 2>&1; then
		local tun_ip
		tun_ip=$(ip -4 -o addr show dev singbox_tun 2>/dev/null | awk '{print $4}' | head -n1)
		tun_ip=${tun_ip:-N/A}
		echo "  ✓ singbox_tun 接口存在 (IP: $tun_ip)"
	else
		if [ $is_root -eq 0 ] && [ ! -d /sys/class/net/singbox_tun ]; then
			echo "  - singbox_tun: 无法查询（接口不存在或需要 root）"
		else
			echo "  ✗ singbox_tun 接口不存在"
			fail=1
		fi
	fi

	# 6. 必要工具
	echo "[7/10] 必要工具检查..."
	for tool in curl jq python3 git; do
		if command -v "$tool" &>/dev/null; then
			echo "  ✓ $tool: $(command -v "$tool")"
		else
			echo "  ✗ $tool: 未安装"
			fail=1
		fi
	done

	# 7. 网络连通性
	echo "[8/10] 网络连通性检查..."
	if curl -fsSL -m 5 "http://223.5.5.5" >/dev/null 2>&1; then
		echo "  ✓ 直连 HTTP 正常"
	elif ping -c1 -W2 "223.5.5.5" >/dev/null 2>&1; then
		echo "  ⚠ HTTP 不通但 ICMP 正常（可能有端口限制）"
	else
		echo "  ✗ 网络不可达"
		fail=1
	fi

	if curl -fsSL -m 5 "https://www.google.com" >/dev/null 2>&1; then
		echo "  ✓ 代理出站正常 (Google)"
	else
		echo "  ⚠ Google 不可达（代理可能未生效）"
	fi

	# 8. 部署配置
	echo "[9/10] 部署配置检查..."
	local deploy_cfg="/usr/local/etc/sing-box/.deployment_config"
	if [ -f "$deploy_cfg" ]; then
		echo "  ✓ 部署配置存在: $deploy_cfg"
		local saved_region
		saved_region=$(grep '^DEFAULT_REGION=' "$deploy_cfg" 2>/dev/null | cut -d'=' -f2)
		echo "  ✓ DEFAULT_REGION: ${saved_region:-未设置}"
	else
		echo "  ⚠ 部署配置不存在 (非致命)"
	fi

	# 9. Dashboard 检查
	echo "[10/10] 面板 (Dashboard) 启动检查..."
	if [ -f "$deploy_cfg" ]; then
		# shellcheck disable=SC1090
		source "$deploy_cfg"
		if [ "${ENABLE_DASHBOARD:-0}" -eq 1 ]; then
			local ui_dir="/usr/local/etc/sing-box/ui"
			local d_port="${DASHBOARD_PORT:-9090}"
			
			if [ -d "$ui_dir" ] && [ "$(find "$ui_dir" -maxdepth 1 | wc -l)" -gt 1 ]; then
				echo "  ✓ 面板资源已就绪: $ui_dir"
			else
				echo "  ✗ 面板资源缺失或为空: $ui_dir"
				fail=1
			fi
			
			if command -v ss &>/dev/null; then
				if ss -tlnp | grep -q ":$d_port "; then
					echo "  ✓ 面板接口正在监听: $d_port"
				else
					echo "  ✗ 面板接口未监听: $d_port (请检查是否配置正确且服务已运行)"
					fail=1
				fi
			elif command -v netstat &>/dev/null; then
				if netstat -tlnp | grep -q ":$d_port "; then
					echo "  ✓ 面板接口正在监听: $d_port"
				else
					echo "  ✗ 面板接口未监听: $d_port"
					fail=1
				fi
			else
				echo "  - 无法检查端口状况 (缺少 ss/netstat)"
			fi
		else
			echo "  - 用户已选择关闭面板支持"
		fi
	else
		echo "  ⚠ 无法加载部署配置，跳过面板检查"
	fi

	echo ""
	if [ $fail -eq 0 ]; then
		echo -e "${GREEN}✅ 所有检查通过${NC}"
	else
		echo -e "${YELLOW}⚠️  存在异常项，请根据上方输出排查${NC}"
	fi

	if [ $is_root -eq 0 ]; then
		echo ""
		echo "提示：使用 'sudo $0 --check' 可获得完整检查报告"
	fi

	echo ""
	return $fail
}
