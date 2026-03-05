#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# sing-box deployment project - environmental checks and validation
#

detect_os() {
	# Enable nocasematch for case-insensitive ID matching
	local _nocasematch_was_off=1
	shopt -q nocasematch && _nocasematch_was_off=0
	shopt -s nocasematch 2>/dev/null || true

	_detect_os_cleanup() {
		# shellcheck disable=SC2015
		[ "$_nocasematch_was_off" -eq 1 ] && shopt -u nocasematch 2>/dev/null || true
	}

	# Prefer lsb_release
	if command -v lsb_release &>/dev/null; then
		OS_ID=$(lsb_release -is)
		OS_VERSION=$(lsb_release -rs)
		OS_CODENAME=$(lsb_release -cs)
		_detect_os_cleanup
		return 0
	fi

	# Fallback: parse /etc/os-release
	# Source in subshell to avoid namespace pollution
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		OS_ID=$(. /etc/os-release && echo "${ID^}")
		# shellcheck disable=SC1091
		OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
		# shellcheck disable=SC1091
		OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")

		# Normalize distro ID
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
	log_info "Checking network connectivity (sing-box repository sites)..."
	local urls=(
		"https://sing-box.app/gpg.key"
		"https://deb.sagernet.org/"
	)

	for u in "${urls[@]}"; do
		if curl -fsSL --connect-timeout "${CONNECT_TIMEOUT:-5}" -m "${MAX_TIME:-10}" -o /dev/null "$u"; then
			log_info "Network check passed: $u"
			return 0
		fi
	done

	log_warn "HTTPS check failed, trying ICMP ping fallback..."
	if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
		log_warn "Ping OK but HTTPS failed: possible transparent proxy, cert, or firewall issue"
		return 0
	fi

	return 1
}

install_missing_tools() {
	log_info "Checking required tools..."
	local tools=(curl git python3 python3-venv jq)
	local missing=()
	for cmd in "${tools[@]}"; do
		if [[ "$cmd" == "python3-venv" ]]; then
			if ! python3 -m ensurepip --version &>/dev/null; then
				missing+=("$cmd")
			fi
		elif ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		log_warn "Missing tools: ${missing[*]}"
		log_info "Installing missing tools..."
		_run apt-get update -qq
		
		# Handle python3-venv: Ubuntu may require version-specific pkg (e.g. python3.12-venv)
		local apt_packages=()
		for m in "${missing[@]}"; do
			if [[ "$m" == "python3-venv" ]]; then
				local py_ver
				py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")
				if [ -n "$py_ver" ]; then
					apt_packages+=("python${py_ver}-venv")
				fi
				apt_packages+=("python3-venv") # Also keep generic package
			else
				apt_packages+=("$m")
			fi
		done

		_run apt-get install -y "${apt_packages[@]}"

		# Verify each tool was actually installed
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
			log_error "Failed to install required tools: ${still_missing[*]}"
			log_error "Please install manually and retry"
			return 1
		fi
	fi
	return 0
}

detect_interface_type() {
	local iface="$1"
	# Check if interface is virtual
	if [ -L "/sys/class/net/$iface/device" ]; then
		# Physical NIC: only flag PPPoE if default route goes through ppp*
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
		# Only flag ipv6 if the interface has a global-scope IPv6 address
		if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6"; then
			echo "ipv6"
		else
			echo "standard"
		fi
	fi
}

probe_pmtu() {
	local target="$1"  # Probe target IP
	local max_mtu="$2" # Starting MTU

	# Verify probe target reachability, try domestic target on failure
	if ! timeout 2 ping -c 1 -W 1 -- "$target" >/dev/null 2>&1; then
		if timeout 2 ping -c 1 -W 1 -- "223.5.5.5" >/dev/null 2>&1; then
			target="223.5.5.5"
		fi
	fi

	# Binary search probe (start from max_mtu)
	local low=1280
	local high=$max_mtu
	local result=$low

	while [ "$low" -le "$high" ]; do
		local mid=$(((low + high) / 2))
		local payload=$((mid - 28)) # Subtract IP(20) + ICMP(8) headers

		# Use ping -M do to disable fragmentation
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

	# Try ipcalc if available (more precise)
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

	# Fallback: parse ip addr output with bit arithmetic
	addr_with_mask=$(ip -o -f inet addr show "$iface" | awk '{print $4}' | head -n1)
	if [ -n "$addr_with_mask" ]; then
		local ip="${addr_with_mask%/*}"
		local mask="${addr_with_mask##*/}"
		
		# Correctly compute network address with bit arithmetic
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
	# Match X.X.X.X/N format (N = 0-32)
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
