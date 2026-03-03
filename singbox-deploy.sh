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

# 获取脚本所在目录
PROJECT_DIR="$(dirname "$(readlink -f "$0")")"
# O-1: 不再无差别 chmod，由 install/cp 在 step02 控制权限

# 1. 加载核心库
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

# 2. 加载子命令 (按需加载可选，这里统一加载)
source "$PROJECT_DIR/cmd/check.sh"
source "$PROJECT_DIR/cmd/uninstall.sh"
source "$PROJECT_DIR/cmd/rollback.sh"

# 3. 加载部署步骤
source "$PROJECT_DIR/steps/01-prepare.sh"
source "$PROJECT_DIR/steps/02-dirs-and-scripts.sh"
source "$PROJECT_DIR/steps/03-subscribe.sh"
source "$PROJECT_DIR/steps/04-rulesets.sh"
source "$PROJECT_DIR/steps/05-dashboard-ui.sh"
source "$PROJECT_DIR/steps/06-templates-and-config.sh"
source "$PROJECT_DIR/steps/07-finalize.sh"
source "$PROJECT_DIR/steps/08-stealth-plus.sh"

# ============================================================================
# 参数解析
# ============================================================================
SHOW_HELP=0
AUTO_YES=0
NEXTDNS_ID=""
ENABLE_DASHBOARD=1

usage() {
	echo "用法 (Usage): $0 [选项]"
	echo ""
	echo "选项 (Options):"
	echo "  --check       检查运行环境健康状态 (health check)"
	echo "  --uninstall   完整卸载 sing-box 及配置 (full uninstall)"
	echo "  --rollback    回滚到之前的配置文件 (rollback config)"
	echo "  --upgrade     仅执行升级（不重新询问配置）(upgrade only)"
	echo "  --dry-run     仅显示将要执行的命令 (dry run)"
	echo "  --auto-yes    自动执行，无需交互确认 (non-interactive)"
	echo "  --version     显示版本信息 (show version)"
	echo "  --status      显示当前服务状态 (quick status)"
	echo "  --help        显示此帮助信息 (show help)"
	echo ""
}

# A-1: --status 子命令
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
	--check) do_check; exit 0 ;;
	--uninstall)
		# shellcheck disable=SC2317
		do_uninstall
		# shellcheck disable=SC2317
		exit 0
		;;
	--rollback) do_rollback; exit 0 ;;
	--version) echo "sing-box-stealth-deploy v${SCRIPT_VERSION}"; exit 0 ;;
	--status) do_status; exit 0 ;;
	--upgrade) UPGRADE_MODE=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	--auto-yes) AUTO_YES=1; shift ;;
	--help) SHOW_HELP=1; shift ;;
	*) echo "未知选项 (Unknown option): $1"; usage; exit 1 ;;
	esac
done

if [ "$SHOW_HELP" -eq 1 ]; then
	usage
	exit 0
fi

# ============================================================================
# 主执行流程
# ============================================================================

# 1. 基础环境校验 (P0)
if [ "$(id -u)" -ne 0 ]; then
	log_error "请使用 root 权限运行: sudo $0"
	exit 1
fi

detect_os || { log_error "不支持的操作系统"; exit 1; }
check_network || { log_error "网络连通性检查失败"; exit 1; }
install_missing_tools || { log_error "必需工具安装失败"; exit 1; }

# 2. 获取部署锁
acquire_deploy_lock "$DEPLOY_LOCK" "$DEPLOY_LOCK_PID" 300 || exit 1

# 3. 信息收集 (仅在非升级模式)

# 全局变量初始化
AIRPORT_URLS=()
AIRPORT_TAGS=()

collect_subscription_urls() {
	AIRPORT_URLS=()
	AIRPORT_TAGS=()
	if [ "$AUTO_YES" -eq 0 ]; then
		# C-1 安全加固: 禁用历史记录，防止订阅 URL (含 token) 被记录
		set +o history 2>/dev/null || true
		log_warn "请输入机场订阅链接（留空结束）:"
		log_warn "（输入内容不会回显，粘贴后按回车确认）"
		while true; do
			read -rs -p "订阅链接 [$(( ${#AIRPORT_URLS[@]} + 1 ))]: " url
			echo  # -s 不会换行，手动补一个
			[ -z "$url" ] && break
			AIRPORT_URLS+=("$url")
			# 提取 tag
			tag=$(echo "$url" | sed -E 's/.*[?&]name=([^&]+).*/\1/' | head -n1)
			AIRPORT_TAGS+=("${tag:-sub_$(( ${#AIRPORT_URLS[@]} ))}")
			log_info "  ✓ 已添加第 ${#AIRPORT_URLS[@]} 个订阅"
		done
		set -o history 2>/dev/null || true
		if [ ${#AIRPORT_URLS[@]} -eq 0 ]; then
			log_error "必须提供至少一个订阅链接"
			exit 1
		fi
		
		# NextDNS
		read -r -p "NextDNS 配置 ID (可选): " NEXTDNS_ID
	else
		# 自动模式下尝试从环境变量读取
		if [ -z "${AIRPORT_URLS_STR:-}" ] && [ ${#AIRPORT_URLS[@]} -eq 0 ]; then
			log_error "自动模式下必须预设 AIRPORT_URLS_STR 环境变量"
			exit 1
		fi
		# 如果提供了字符串形式，解析成数组
		if [ -n "${AIRPORT_URLS_STR:-}" ]; then
			read -r -a AIRPORT_URLS <<< "$AIRPORT_URLS_STR"
			for url in "${AIRPORT_URLS[@]}"; do
				tag=$(echo "$url" | sed -E 's/.*[\?&]name=([^&]+).*/\1/' | head -n1)
				AIRPORT_TAGS+=("${tag:-sub_$(( ${#AIRPORT_TAGS[@]} + 1 ))}")
			done
		fi
	fi
}

# 3. 信息收集
if [ "$UPGRADE_MODE" -eq 0 ]; then
	log_step "========== 环境信息收集 =========="
	
	# 检测主网卡
	DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
	if [ "$AUTO_YES" -eq 1 ]; then
		MAIN_IFACE=${MAIN_IFACE:-$DEFAULT_IFACE}
	else
		read -r -p "主出网接口 [默认: $DEFAULT_IFACE]: " MAIN_IFACE_INPUT
		MAIN_IFACE=${MAIN_IFACE_INPUT:-$DEFAULT_IFACE}
	fi
	
	# MTU/LAN 自动检测
	PHYSICAL_MTU=$(ip -o link show dev "$MAIN_IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}' | head -n1)
	PHYSICAL_MTU=${PHYSICAL_MTU:-1500}
	# shellcheck disable=SC2034
	NETWORK_TYPE=$(detect_interface_type "$MAIN_IFACE")
	PROBED_MTU=$(probe_pmtu "8.8.8.8" "$PHYSICAL_MTU")
	RECOMMENDED_TUN_MTU=$((PROBED_MTU - 80))
	[ "$RECOMMENDED_TUN_MTU" -lt 1280 ] && RECOMMENDED_TUN_MTU=1280
	
	LAN_SUBNET=$(detect_lan_subnet "$MAIN_IFACE" || echo "192.168.0.0/16")

	# H-2 修复: IPv6 双栈检测
	if ip -6 addr show dev "$MAIN_IFACE" scope global 2>/dev/null | grep -q "inet6"; then
		HAS_IPV6=1
		log_info "检测到 IPv6 全局地址，启用双栈支持"
	else
		HAS_IPV6=0
	fi

	detect_desktop
	
	# 收集机场 URL
	collect_subscription_urls
	
	# 面板配置
	if [ "$AUTO_YES" -eq 1 ]; then
		DASHBOARD_PORT=${DASHBOARD_PORT:-9090}
		# O-13: 自动模式下生成随机 secret，避免使用弱默认值
		DASHBOARD_SECRET=${DASHBOARD_SECRET:-$(openssl rand -hex 8 2>/dev/null || echo "sing-box")}
		ENABLE_DASHBOARD=${ENABLE_DASHBOARD:-1}
	else
		read -r -p "是否开启面板管理支持 (端口 9090, 秘钥 'sing-box')? [Y/n]: " DASHBOARD_YN_INPUT
		if [[ ! "$DASHBOARD_YN_INPUT" =~ ^[Nn]$ ]]; then
			ENABLE_DASHBOARD=1
			read -r -p "  面板监听端口 [默认: 9090]: " DASHBOARD_PORT_INPUT
			DASHBOARD_PORT=${DASHBOARD_PORT_INPUT:-9090}
			# O-13: 交互模式下也默认生成随机 secret
			_DEFAULT_SECRET=$(openssl rand -hex 8 2>/dev/null || echo "sing-box")
			read -r -p "  面板访问秘钥 [默认: $_DEFAULT_SECRET]: " DASHBOARD_SECRET_INPUT
			DASHBOARD_SECRET=${DASHBOARD_SECRET_INPUT:-$_DEFAULT_SECRET}
		else
			ENABLE_DASHBOARD=0
			DASHBOARD_PORT=9090
			DASHBOARD_SECRET="sing-box"
		fi
	fi
	
	# 持久化配置
	mkdir -p /usr/local/etc/sing-box
	cat >"$DEPLOYMENT_CONFIG" <<EOF
MAIN_IFACE="$MAIN_IFACE"
LAN_SUBNET="$LAN_SUBNET"
PHYSICAL_MTU="$PHYSICAL_MTU"
RECOMMENDED_TUN_MTU="$RECOMMENDED_TUN_MTU"
HAS_IPV6="$HAS_IPV6"
DEFAULT_REGION="$DEFAULT_REGION"
AIRPORT_TAGS="${AIRPORT_TAGS[*]}"
AIRPORT_URLS_STR="${AIRPORT_URLS[*]}"
NEXTDNS_ID="$NEXTDNS_ID"
DASHBOARD_PORT="$DASHBOARD_PORT"
DASHBOARD_SECRET="$DASHBOARD_SECRET"
ENABLE_DASHBOARD="$ENABLE_DASHBOARD"
IS_DESKTOP="$IS_DESKTOP"
EOF
	
	# Stealth+ 住宅 IP 信息收集 (可选)
	if [ "$AUTO_YES" -eq 0 ]; then
		read -r -p "是否记录住宅 IP 代理信息以供后续集成？[y/N]: " ENABLE_RES_INPUT
		if [[ "$ENABLE_RES_INPUT" =~ ^[Yy]$ ]]; then
			read -r -p "  住宅代理 Host: " RES_HOST
			read -r -p "  住宅代理 Port: " RES_PORT
			read -r -p "  Proxy 用户名: " RES_USER
			read -rs -p "  Proxy 密码: " RES_PASS; echo
			
			{
				echo "RES_HOST=\"$RES_HOST\""
				echo "RES_PORT=\"$RES_PORT\""
				echo "RES_USER=\"$RES_USER\""
				echo "RES_PASS=\"$RES_PASS\""
			} >> "$DEPLOYMENT_CONFIG"
		fi
	fi
else
	log_info "[升级模式] 加载现有配置..."
	if [ -f "$DEPLOYMENT_CONFIG" ]; then
		# H-4 安全加固: 验证配置文件格式，防止代码注入
		# C-3 安全修复: 收紧正则，禁止反引号、$()、${}等 shell 扩展字符
		if grep -qvE '^[A-Za-z_][A-Za-z0-9_]*="[A-Za-z0-9_./:, @*=%+\[\]-]*"$|^[[:space:]]*$|^#' "$DEPLOYMENT_CONFIG"; then
			log_error "部署配置文件格式异常（包含非法行），可能被篡改: $DEPLOYMENT_CONFIG"
			log_error "仅允许 KEY=\"VALUE\" 格式。请检查并修复后重试"
			exit 1
		fi
		# shellcheck source=/dev/null
		source "$DEPLOYMENT_CONFIG"
		# O-16: 使用 lib/utils.sh 中的集中管理函数
		_ensure_compat_defaults
	else
		log_error "未找到部署配置，请先执行完整安装"
		exit 1
	fi

	# [自动容错恢复] 升级模式下，如果检测到 providers.json 为空，主动要求输入订阅
	providers_json="/usr/local/etc/sing-box/providers.json"
	if [ ! -f "$providers_json" ] || grep -q '"subscribes": \[\]' "$providers_json"; then
		log_warn "检测到订阅配置缺失或为空，请重新输入订阅链接以恢复配置"
		collect_subscription_urls
	fi
fi

# 4. 执行部署步骤 (在子 Shell 中运行，隔离作用域)
( deploy_step_01 )
( deploy_step_02 )
( deploy_step_03 )
( deploy_step_04 )
( deploy_step_05 )
( deploy_step_06 )
( deploy_step_07 )
( deploy_step_08 )

# C-4 修复: 移除错误缩进
log_info "🎉 部署完成！"
log_info "详细状态请运行: $0 --check"

if [ "${ENABLE_DASHBOARD:-0}" -eq 1 ]; then
	echo ""
	log_info "========================================================"
	log_info "💻 面板访问地址: http://127.0.0.1:${DASHBOARD_PORT:-9090}/ui/"
	_masked_secret="****"
	if [ -n "${DASHBOARD_SECRET:-}" ] && [ "${#DASHBOARD_SECRET}" -gt 4 ]; then
		_masked_secret="${DASHBOARD_SECRET:0:4}****"
	fi
	log_info "🔑 面板访问密钥: ${_masked_secret}"
	log_info "========================================================"
	echo ""
fi
