#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# sing-box deployment project - environmental checks and validation
#

detect_os() {
	# 临时开启 nocasematch 用于 case 标准化 ID
	local _nocasematch_was_off=1
	shopt -q nocasematch && _nocasematch_was_off=0
	shopt -s nocasematch 2>/dev/null || true

	_detect_os_cleanup() {
		# shellcheck disable=SC2015
		[ "$_nocasematch_was_off" -eq 1 ] && shopt -u nocasematch 2>/dev/null || true
	}

	# 优先使用 lsb_release
	if command -v lsb_release &>/dev/null; then
		OS_ID=$(lsb_release -is)
		OS_VERSION=$(lsb_release -rs)
		OS_CODENAME=$(lsb_release -cs)
		_detect_os_cleanup
		return 0
	fi

	# Fallback: 解析 /etc/os-release
	# O-A1 修复: 在子 shell 中 source 避免全局命名空间污染
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		OS_ID=$(. /etc/os-release && echo "${ID^}")
		# shellcheck disable=SC1091
		OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
		# shellcheck disable=SC1091
		OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")

		# 标准化 ID
		case "$OS_ID" in
		Debian | Ubuntu)
			_detect_os_cleanup
			return 0
			;;
		*)
			_detect_os_cleanup
			return 1
			;;
		esac
	fi

	_detect_os_cleanup
	return 1
}

check_network() {
	log_info "检查网络连接（访问 sing-box 仓库所需站点）..."
	local urls=(
		"https://sing-box.app/gpg.key"
		"https://deb.sagernet.org/"
	)

	for u in "${urls[@]}"; do
		if curl -fsSL --connect-timeout "${CONNECT_TIMEOUT:-5}" -m "${MAX_TIME:-10}" -o /dev/null "$u"; then
			log_info "网络检查通过: $u"
			return 0
		fi
	done

	log_warn "HTTPS 检查失败，尝试 ICMP ping 兜底..."
	if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
		log_warn "⚠️ ping 通但 HTTPS 不通：可能是透明代理/证书/防火墙拦截导致"
		return 0
	fi

	return 1
}

install_missing_tools() {
	log_info "检查必需工具..."
	local tools=(curl git python3 python3-venv jq)
	local missing=()
	for cmd in "${tools[@]}"; do
		if [[ "$cmd" == "python3-venv" ]]; then
			if ! python3 -m venv --help &>/dev/null; then
				missing+=("$cmd")
			fi
		elif ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		log_warn "以下工具未安装：${missing[*]}"
		log_info "正在安装..."
		_run apt-get update -qq
		_run apt-get install -y "${missing[@]}"

		# 目的验证：确认每个工具确实安装成功
		local still_missing=()
		for cmd in "${missing[@]}"; do
			if [[ "$cmd" == "python3-venv" ]]; then
				if ! python3 -m venv --help &>/dev/null; then
					still_missing+=("$cmd")
				fi
			elif ! command -v "$cmd" &>/dev/null; then
				still_missing+=("$cmd")
			fi
		done
		if [ ${#still_missing[@]} -gt 0 ]; then
			log_error "以下必需工具安装失败：${still_missing[*]}"
			log_error "请手动安装后重试"
			return 1
		fi
	fi
	return 0
}

detect_interface_type() {
	local iface="$1"
	# 检查是否为虚拟接口
	if [ -L "/sys/class/net/$iface/device" ]; then
		# 物理网卡：只有当默认路由实际走 ppp* 时，才认为是 PPPoE 嵌套
		if ip route show default 2>/dev/null | grep -qE '\bdev ppp[0-9]+'; then
			echo "pppoe_nested"
			return
		fi
		echo "physical"
	elif [[ "$iface" =~ ^ppp[0-9]+$ ]]; then
		echo "pppoe"
	elif [[ "$iface" =~ ^(tun|tap)[0-9]*$ ]]; then
		echo "vpn"
	else
		# 仅当该接口确实存在全局 IPv6 地址时，才标记 ipv6
		if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6"; then
			echo "ipv6"
		else
			echo "standard"
		fi
	fi
}

probe_pmtu() {
	local target="$1"  # 探测目标 IP
	local max_mtu="$2" # 起始 MTU

	# 二分法探测（从 max_mtu 开始递减）
	local low=1280
	local high=$max_mtu
	local result=$low

	while [ "$low" -le "$high" ]; do
		local mid=$(((low + high) / 2))
		local payload=$((mid - 28)) # 减去 IP(20) + ICMP(8) 头

		# 使用 ping -M do 禁止分片，-s 设置 payload 大小
		if timeout 2 ping -M "do" -s "$payload" -c 1 -W 1 -- "$target" >/dev/null 2>&1; then
			result=$mid
			low=$((mid + 1))
		else
			high=$((mid - 1))
		fi
	done

	echo "$result"
}

detect_lan_subnet() {
	local iface="$1"
	local addr_with_mask

	# 尝试使用 ipcalc（更精确）
	if command -v ipcalc &>/dev/null; then
		addr_with_mask=$(ip -4 addr show "$iface" | grep 'inet ' | awk '{print $2}' | head -n1)
		if [ -n "$addr_with_mask" ]; then
			local network
			network=$(ipcalc -n "$addr_with_mask" 2>/dev/null | sed -nE 's/^Network:[[:space:]]+([0-9./]+).*/\1/p' | head -n1)
			if [ -n "$network" ]; then
				echo "$network"
				return 0
			fi
		fi
	fi

	# Fallback：使用 ip addr 解析 + 位运算通用方案
	addr_with_mask=$(ip -o -f inet addr show "$iface" | awk '{print $4}' | head -n1)
	if [ -n "$addr_with_mask" ]; then
		local ip="${addr_with_mask%/*}"
		local mask="${addr_with_mask##*/}"
		
		# O-2 修复: 位运算正确计算任意掩码长度的网络地址
		local -a octets
		IFS='.' read -ra octets <<< "$ip"
		local ip_int=$(( (octets[0]<<24) + (octets[1]<<16) + (octets[2]<<8) + octets[3] ))
		local mask_int=$(( 0xFFFFFFFF << (32-mask) & 0xFFFFFFFF ))
		local net_int=$(( ip_int & mask_int ))
		printf "%d.%d.%d.%d/%d" \
			$(( (net_int>>24) & 0xFF )) $(( (net_int>>16) & 0xFF )) \
			$(( (net_int>>8) & 0xFF )) $(( net_int & 0xFF )) "$mask"
		echo  # trailing newline
		return 0
	fi

	return 1
}

_validate_cidr() {
	local cidr="$1"
	# 匹配 X.X.X.X/N 格式 (N = 0-32)
	if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
		return 1
	fi

	local ip="${cidr%/*}"
	local mask="${cidr##*/}"

	if ! [[ "$mask" =~ ^[0-9]+$ ]] || [ "$mask" -lt 0 ] || [ "$mask" -gt 32 ]; then
		return 1
	fi

	local -a octets
	IFS='.' read -ra octets <<< "$ip"
	if [ "${#octets[@]}" -ne 4 ]; then return 1; fi

	for o in "${octets[@]}"; do
		if ! [[ "$o" =~ ^[0-9]+$ ]] || [ "$o" -lt 0 ] || [ "$o" -gt 255 ]; then
			return 1
		fi
	done

	return 0
}

detect_desktop() {
	IS_DESKTOP=0
	if [ -n "${XDG_CURRENT_DESKTOP:-}" ] || [ -n "${GNOME_SETUP_DISPLAY:-}" ] || [ -n "${KDE_FULL_SESSION:-}" ]; then
		IS_DESKTOP=1
	elif command -v systemctl >/dev/null 2>&1; then
		if systemctl is-active --quiet graphical.target; then
			IS_DESKTOP=1
		fi
	fi
	return 0
}
