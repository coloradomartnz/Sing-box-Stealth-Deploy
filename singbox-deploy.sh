#!/usr/bin/env bash
#
# sing-box Deployment Project - Main Entrypoint
# Version: 3.0
#

set -euo pipefail
export LC_ALL=C
export ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
export ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true
export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true

# Resolve script directory
PROJECT_DIR="$(dirname "$(readlink -f "$0")")"
# Permissions are set per-file in step02 via install/cp

# Load core libraries
source "$PROJECT_DIR/lib/globals.sh"
source "$PROJECT_DIR/lib/utils.sh"
source "$PROJECT_DIR/lib/lock.sh"

_CLEANUP_DIRS=()
_CLEANUP_PIDS=()
_cleanup_all() {
	cleanup_deploy_lock "$DEPLOY_LOCK" "$DEPLOY_LOCK_PID"
	cleanup
	for pid in "${_CLEANUP_PIDS[@]}"; do
		kill -9 "$pid" 2>/dev/null || true
	done
	wait "${_CLEANUP_PIDS[@]}" 2>/dev/null || true
	for dir in "${_CLEANUP_DIRS[@]}"; do
		[ -d "$dir" ] && rm -rf "$dir" 2>/dev/null || true
	done
}
register_cleanup_dir() {
	_CLEANUP_DIRS+=("$1")
}
register_cleanup_pid() {
	_CLEANUP_PIDS+=("$1")
}
trap '_cleanup_all' EXIT INT TERM

source "$PROJECT_DIR/lib/checks.sh"
source "$PROJECT_DIR/lib/ruleset.sh"
source "$PROJECT_DIR/lib/service.sh"

# Load subcommands
source "$PROJECT_DIR/cmd/check.sh"
source "$PROJECT_DIR/cmd/uninstall.sh"
source "$PROJECT_DIR/cmd/rollback.sh"

# Load deployment steps and execution manifest
source "$PROJECT_DIR/lib/manifest.sh"
source "$PROJECT_DIR/steps/01-prepare.sh"
source "$PROJECT_DIR/steps/02-dirs-and-scripts.sh"
source "$PROJECT_DIR/steps/03-subscribe.sh"
source "$PROJECT_DIR/steps/04-rulesets.sh"
source "$PROJECT_DIR/steps/05-dashboard-ui.sh"
source "$PROJECT_DIR/steps/06-templates-and-config.sh"
source "$PROJECT_DIR/steps/07-finalize.sh"
source "$PROJECT_DIR/steps/08-stealth-plus.sh"
source "$PROJECT_DIR/steps/09-sub-store.sh"

# ============================================================================
# Argument parsing
# ============================================================================
SHOW_HELP=0
AUTO_YES=0
SUBSTORE_MODE=0
NEXTDNS_ID=""
ENABLE_DASHBOARD=1

usage() {
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  --check       Run health check on the deployment environment"
	echo "  --uninstall   Fully uninstall sing-box and all configuration"
	echo "  --rollback    Roll back to the previous configuration"
	echo "  --upgrade     Upgrade only (skip interactive configuration)"
	echo "  --substore    Deploy with Sub-Store subscription management"
	echo "  --dry-run     Show commands without executing them"
	echo "  --auto-yes    Non-interactive mode (no confirmation prompts)"
	echo "  --version     Show version information"
	echo "  --status      Show current service status"
	echo "  --help        Show this help message"
	echo ""
}

# Show quick service status
do_status() {
	local sb_active tun_status uptime_str
	sb_active=$(systemctl is-active sing-box 2>/dev/null || echo "inactive")
	if ip link show singbox_tun &>/dev/null; then
		tun_status="UP"
	else
		tun_status="DOWN"
	fi
	uptime_str=$(systemctl show sing-box --property=ActiveEnterTimestamp --value 2>/dev/null || echo "N/A")
	echo "sing-box v${SCRIPT_VERSION} | service: ${sb_active} | TUN: ${tun_status} | since: ${uptime_str}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--check) do_check; exit $? ;;
	--uninstall)
		# shellcheck disable=SC2317
		do_uninstall
		# shellcheck disable=SC2317
		exit 0
		;;
	--rollback) do_rollback; exit 0 ;;
	--version) echo "sing-box-stealth-deploy v${SCRIPT_VERSION}"; exit 0 ;;
	--status) do_status; exit $? ;;
	--substore) SUBSTORE_MODE=1; shift ;;
	--upgrade) UPGRADE_MODE=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	--auto-yes) AUTO_YES=1; shift ;;
	--help) SHOW_HELP=1; shift ;;
	*) echo "Unknown option: $1"; usage; exit 1 ;;
	esac
done

if [ "$SHOW_HELP" -eq 1 ]; then
	usage
	exit 0
fi

# ============================================================================
# Main execution flow
# ============================================================================

# Verify root privileges
if [ "$(id -u)" -ne 0 ]; then
	log_error "Root privileges required: sudo $0"
	exit "${E_PERMISSION:-13}"
fi

detect_os || { log_error "Unsupported operating system"; exit "${E_GENERAL:-1}"; }
check_network || { log_error "Network connectivity check failed"; exit "${E_NETWORK:-10}"; }
install_missing_tools || { log_error "Required tool installation failed"; exit "${E_DEPENDENCY:-14}"; }

# Acquire deployment lock
acquire_deploy_lock "$DEPLOY_LOCK" "$DEPLOY_LOCK_PID" 300 || exit "${E_LOCK:-12}"

# Collect subscription info (skip in upgrade mode)

# Initialize global arrays
AIRPORT_URLS=()
AIRPORT_TAGS=()

collect_subscription_urls() {
	AIRPORT_URLS=()
	AIRPORT_TAGS=()
	if [ "$AUTO_YES" -eq 0 ]; then
		# Disable shell history to prevent subscription URLs from leaking
		set +o history 2>/dev/null || true
		log_warn "Enter subscription URLs (leave blank to finish):"
		log_warn "(Input is hidden; paste and press Enter to confirm)"
		while true; do
			read -rs -p "Subscription URL [$(( ${#AIRPORT_URLS[@]} + 1 ))]: " url
			echo  # -s suppresses newline
			[ -z "$url" ] && break
			AIRPORT_URLS+=("$url")
			# Extract tag from URL name parameter using bash native regex (no fork)
			# Pattern stored in variable to avoid bash parsing issues with & inside [[ =~ ]]
			tag=""
			_tag_re='[?&]name=([^&]+)'
			if [[ "$url" =~ $_tag_re ]]; then
				tag="${BASH_REMATCH[1]}"
			fi
			AIRPORT_TAGS+=("${tag:-sub_$(( ${#AIRPORT_URLS[@]} ))}")
			log_info "  OK added subscription #${#AIRPORT_URLS[@]}"
		done
		set -o history 2>/dev/null || true
		if [ ${#AIRPORT_URLS[@]} -eq 0 ]; then
			log_error "At least one subscription URL is required"
			exit "${E_CONFIG:-11}"
		fi
		
		# NextDNS
		read -r -p "NextDNS config ID (optional): " NEXTDNS_ID
	else
		# Read from environment variable in auto mode
		if [ -z "${AIRPORT_URLS_STR:-}" ] && [ ${#AIRPORT_URLS[@]} -eq 0 ]; then
			log_error "AIRPORT_URLS_STR environment variable required in auto mode"
			exit "${E_CONFIG:-11}"
		fi
		# Parse space-separated string into array
		if [ -n "${AIRPORT_URLS_STR:-}" ]; then
			read -r -a AIRPORT_URLS <<< "$AIRPORT_URLS_STR"
			for url in "${AIRPORT_URLS[@]}"; do
				tag=""
				_tag_re='[?&]name=([^&]+)'
				if [[ "$url" =~ $_tag_re ]]; then
					tag="${BASH_REMATCH[1]}"
				fi
				AIRPORT_TAGS+=("${tag:-sub_$(( ${#AIRPORT_TAGS[@]} + 1 ))}")
			done
		fi
	fi
}

# Collect environment information
if [ "$UPGRADE_MODE" -eq 0 ]; then
	log_step "========== Environment Discovery =========="
	
	# Detect default network interface
	DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
	if [ "$AUTO_YES" -eq 1 ]; then
		MAIN_IFACE=${MAIN_IFACE:-$DEFAULT_IFACE}
	else
		read -r -p "Primary egress interface [default: $DEFAULT_IFACE]: " MAIN_IFACE_INPUT
		MAIN_IFACE=${MAIN_IFACE_INPUT:-$DEFAULT_IFACE}
	fi
	
	# Auto-detect MTU and LAN subnet
	PHYSICAL_MTU=$(ip -o link show dev "$MAIN_IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}' | head -n1)
	PHYSICAL_MTU=${PHYSICAL_MTU:-1500}
	# shellcheck disable=SC2034
	NETWORK_TYPE=$(detect_interface_type "$MAIN_IFACE")
	PROBED_MTU=$(probe_pmtu "8.8.8.8" "$PHYSICAL_MTU")
	RECOMMENDED_TUN_MTU=$((PROBED_MTU - 80))
	[ "$RECOMMENDED_TUN_MTU" -lt 1280 ] && RECOMMENDED_TUN_MTU=1280
	
	LAN_SUBNET=$(detect_lan_subnet "$MAIN_IFACE" || echo "192.168.0.0/16")

	# Detect IPv6 dual-stack support
	if ip -6 addr show dev "$MAIN_IFACE" scope global 2>/dev/null | grep -q "inet6"; then
		HAS_IPV6=1
		log_info "IPv6 global address detected, enabling dual-stack"
	else
		HAS_IPV6=0
	fi

	# Detect desktop environment
	detect_desktop

	# Sub-Store configuration (Move to here, before subscription collection)
	if [ "$AUTO_YES" -eq 0 ]; then
		read -r -p "Enable Sub-Store subscription management? [y/N]: " SUBSTORE_YN_INPUT
		if [[ "$SUBSTORE_YN_INPUT" =~ ^[Yy]$ ]]; then
			SUBSTORE_MODE=1
			read -r -p "  Sub-Store collection name [default: MySubs]: " SUBSTORE_COLL_INPUT
			SUBSTORE_COLLECTION_NAME=${SUBSTORE_COLL_INPUT:-MySubs}
		fi
	fi
	
	# Collect subscription URLs (Required for both modes now)
	collect_subscription_urls
	
	# Dashboard configuration
	if [ "$AUTO_YES" -eq 1 ]; then
		DASHBOARD_PORT=${DASHBOARD_PORT:-9090}
		# Generate random secret in auto mode to avoid weak defaults
		DASHBOARD_SECRET=${DASHBOARD_SECRET:-$(openssl rand -hex 8 2>/dev/null || echo "sing-box")}
		ENABLE_DASHBOARD=${ENABLE_DASHBOARD:-1}
	else
		read -r -p "Enable dashboard (port 9090)? [Y/n]: " DASHBOARD_YN_INPUT
		if [[ ! "$DASHBOARD_YN_INPUT" =~ ^[Nn]$ ]]; then
			ENABLE_DASHBOARD=1
			read -r -p "  Dashboard listen port [default: 9090]: " DASHBOARD_PORT_INPUT
			DASHBOARD_PORT=${DASHBOARD_PORT_INPUT:-9090}
			# Generate random secret in interactive mode too
			_DEFAULT_SECRET=$(openssl rand -hex 8 2>/dev/null || echo "sing-box")
			read -r -p "  Dashboard access secret [default: $_DEFAULT_SECRET]: " DASHBOARD_SECRET_INPUT
			DASHBOARD_SECRET=${DASHBOARD_SECRET_INPUT:-$_DEFAULT_SECRET}
		else
			ENABLE_DASHBOARD=0
			DASHBOARD_PORT=9090
			DASHBOARD_SECRET="sing-box"
		fi
	fi

	# Persist deployment config（敏感 token 写入 .credentials 目录，不留存于此文件）
	mkdir -p /usr/local/etc/sing-box
	cat >"$DEPLOYMENT_CONFIG" <<EOF
MAIN_IFACE="$MAIN_IFACE"
LAN_SUBNET="$LAN_SUBNET"
PHYSICAL_MTU="$PHYSICAL_MTU"
RECOMMENDED_TUN_MTU="$RECOMMENDED_TUN_MTU"
HAS_IPV6="$HAS_IPV6"
DEFAULT_REGION="$DEFAULT_REGION"
AIRPORT_TAGS="${AIRPORT_TAGS[*]}"
NEXTDNS_ID="$NEXTDNS_ID"
DASHBOARD_PORT="$DASHBOARD_PORT"
ENABLE_DASHBOARD="$ENABLE_DASHBOARD"
IS_DESKTOP="$IS_DESKTOP"
SUBSTORE_MODE="$SUBSTORE_MODE"
SUBSTORE_COLLECTION_NAME="${SUBSTORE_COLLECTION_NAME:-MySubs}"
EOF

	# Restrict config file permissions
	chmod 600 "$DEPLOYMENT_CONFIG"

	# P1 修复：首次安装时同步将订阅 URL（含 token）迁移至 credentials 目录，
	#          与 upgrade 模式的迁移逻辑保持一致，避免 token 明文留存于 deployment_config。
	_cred_dir_init="/usr/local/etc/sing-box/.credentials"
	mkdir -p "$_cred_dir_init"
	chmod 700 "$_cred_dir_init"
	if [ ${#AIRPORT_URLS[@]} -gt 0 ]; then
		printf '%s' "${AIRPORT_URLS[*]}" > "$_cred_dir_init/airport_urls"
		chmod 600 "$_cred_dir_init/airport_urls"
	fi
	
	# Collect optional residential proxy info
	if [ "$AUTO_YES" -eq 0 ]; then
		read -r -p "Record residential proxy info for Stealth+ integration? [y/N]: " ENABLE_RES_INPUT
		if [[ "$ENABLE_RES_INPUT" =~ ^[Yy]$ ]]; then
			read -r -p "  Residential proxy host: " RES_HOST
			read -r -p "  Residential proxy port: " RES_PORT
			read -r -p "  Proxy username: " RES_USER
			read -rs -p "  Proxy password: " RES_PASS; echo
			
			{
				echo "RES_HOST=\"$RES_HOST\""
				echo "RES_PORT=\"$RES_PORT\""
			} >> "$DEPLOYMENT_CONFIG"
		fi
	fi
else
	log_info "[Upgrade mode] Loading existing configuration..."
	if [ -f "$DEPLOYMENT_CONFIG" ]; then
		_safe_source_deployment_config "$DEPLOYMENT_CONFIG"

		# Migrate secrets from legacy config to credentials directory
		cred_dir="/usr/local/etc/sing-box/.credentials"
		_run mkdir -p "$cred_dir"
		_run chmod 700 "$cred_dir"
		do_scrub=0
		if [ -n "${DASHBOARD_SECRET:-}" ]; then
			echo -n "$DASHBOARD_SECRET" > "$cred_dir/dash_secret"
			do_scrub=1
		elif [ -f "$cred_dir/dash_secret" ]; then
			DASHBOARD_SECRET=$(cat "$cred_dir/dash_secret")
		fi
		
		if [ -n "${RES_PASS:-}" ] || grep -q "RES_PASS" "$DEPLOYMENT_CONFIG"; then
			echo -n "${RES_PASS:-}" > "$cred_dir/res_pass"
			echo -n "${RES_USER:-}" > "$cred_dir/res_user"
			do_scrub=1
		else
			[ -f "$cred_dir/res_pass" ] && RES_PASS=$(cat "$cred_dir/res_pass")
			[ -f "$cred_dir/res_user" ] && RES_USER=$(cat "$cred_dir/res_user")
		fi

		# Migrate subscription URLs (containing tokens) to secure credentials directory
		if [ -n "${AIRPORT_URLS_STR:-}" ] || grep -q "AIRPORT_URLS_STR" "$DEPLOYMENT_CONFIG"; then
			echo -n "${AIRPORT_URLS_STR:-}" > "$cred_dir/airport_urls"
			do_scrub=1
		else
			[ -f "$cred_dir/airport_urls" ] && AIRPORT_URLS_STR=$(cat "$cred_dir/airport_urls")
		fi
		_run chmod 600 "$cred_dir"/* 2>/dev/null || true

		if [ $do_scrub -eq 1 ]; then
			log_info "Scrubbing legacy secrets from deployment config..."
			# Remove sensitive keys from plaintext config
			sed -i '/DASHBOARD_SECRET=/d; /RES_PASS=/d; /RES_USER=/d; /AIRPORT_URLS_STR=/d' "$DEPLOYMENT_CONFIG"
		fi

		# Apply backward-compatible defaults
		_ensure_compat_defaults
	else
		log_error "Deployment config not found; run a full install first"
		exit "${E_CONFIG:-11}"
	fi

	# Auto-recovery: re-collect subscriptions if providers.json is empty
	providers_json="/usr/local/etc/sing-box/providers.json"
	if [ ! -f "$providers_json" ] || grep -q '"subscribes": \[\]' "$providers_json"; then
		log_warn "Subscription config missing or empty, prompting for URLs"
		collect_subscription_urls
	fi
fi

# Execute deployment steps via manifest scheduler
execute_all_steps

# Deployment complete
log_info "Deployment complete!"
log_info "Run '$0 --check' for detailed status"

if [ "${ENABLE_DASHBOARD:-0}" -eq 1 ]; then
	echo ""
	log_info "========================================================"
	log_info "Dashboard URL: http://127.0.0.1:${DASHBOARD_PORT:-9090}/ui/"
	_masked_secret="****"
	if [ -n "${DASHBOARD_SECRET:-}" ] && [ "${#DASHBOARD_SECRET}" -gt 4 ]; then
		_masked_secret="${DASHBOARD_SECRET:0:4}****"
	fi
	log_info "Dashboard secret: ${_masked_secret}"
	log_info "========================================================"
	echo ""
fi

if [ "${SUBSTORE_MODE:-0}" -eq 1 ]; then
	echo ""
	log_info "========================================================"
	log_info "🚀 Sub-Store 部署与自动化配置完成！"
	log_info "--------------------------------------------------------"
	log_info "正在执行首次节点同步..."
	if [ -f "/usr/local/bin/substore-update.sh" ]; then
		/usr/bin/bash /usr/local/bin/substore-update.sh || log_warn "首次同步遇到问题，请检查网络后尝试: sudo substore-update.sh"
	fi
	log_info "--------------------------------------------------------"
	if [ -f "/opt/sub-store/substore.env" ]; then
		_ss_path=$(grep SUB_STORE_FRONTEND_BACKEND_PATH "/opt/sub-store/substore.env" | cut -d'=' -f2)
		log_info "管理面板入口: http://127.0.0.1:${SUBSTORE_PORT:-2999}${_ss_path:-\"\"}"
		log_info "✅ 订阅注入状态: 已自动注入 ${#AIRPORT_URLS[@]} 个订阅源"
		log_info "✅ 安全保护状态: 已通过 16 位随机 Token 隐藏后端路径"
		log_info "🎬 接下来操作: 您可以直接启动代理，或进入面板添加更多订阅"
	fi
	log_info "========================================================"
	echo ""
fi
