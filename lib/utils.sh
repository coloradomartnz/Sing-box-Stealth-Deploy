#!/usr/bin/env bash
#
# sing-box deployment project - utility functions
#

# ============================================================================
# 颜色输出
# ============================================================================
# O-A3 修复: 仅在 TTY 环境下输出颜色码，避免 journalctl/cron 乱码
if [[ -t 1 ]]; then
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[1;33m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ============================================================================
# 标准退出码定义 (Standard Exit Codes)
# ============================================================================
export E_GENERAL=1
export E_NETWORK=10
export E_CONFIG=11
export E_LOCK=12
export E_PERMISSION=13
export E_DEPENDENCY=14

_redact() {
	# 增强脱敏：URL、IP、token、密钥
	sed -E \
		-e 's#https?://[^[:space:]]+#<REDACTED_URL>#g' \
		-e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<REDACTED_IP>/g' \
		-e 's/(token|key|secret|password|uuid|private_key|pre_shared_key|auth_str|username|peer)=[^&[:space:]]+/\1=<REDACTED>/gi' \
		-e 's/"(token|key|secret|password|uuid|private_key|pre_shared_key|auth_str|username|peer)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":""/gi'
}

_on_err() {
	local rc="$1" line="$2" cmd="$3" file="${4:-$0}"
	local cmd_safe
	cmd_safe="$(printf '%s' "$cmd" | _redact)"

	echo -e "${RED}[ERROR]${NC} 文件: ${file}"
	echo -e "${RED}[ERROR]${NC} 步骤: ${CURRENT_STEP:-init}"
	echo -e "${RED}[ERROR]${NC} 行号: ${line}, 退出码: ${rc}"
	echo -e "${RED}[ERROR]${NC} 命令: ${cmd_safe}"

	# Trouble-shooting advice based on standardized exit codes
	case "$rc" in
		"$E_NETWORK")    echo -e "${YELLOW}[排障指引] 检测到网络连接失败。请检查系统 DNS 或所在地区是否阻断了相关域名。${NC}" ;;
		"$E_CONFIG")     echo -e "${YELLOW}[排障指引] 配置文件格式、参数或依赖缺失。请检查 jq 输出及输入载荷是否符合规范。${NC}" ;;
		"$E_LOCK")       echo -e "${YELLOW}[排障指引] 获取文件锁失败或超时。如果有僵死进程，请尝试手动清理锁文件。${NC}" ;;
		"$E_PERMISSION") echo -e "${YELLOW}[排障指引] 权限不足。部署脚本及其调用的命令需要 root 权限，请确保以 sudo 运行，并检查文件读写权限。${NC}" ;;
		"$E_DEPENDENCY") echo -e "${YELLOW}[排障指引] 缺少关键系统依赖 (如 curl, jq, iptables 等)。请检查前置环境准备是否成功执行。${NC}" ;;
		*)               echo -e "${YELLOW}[排障指引] 发生了未知错误。请结合上面的命令和如下的系统日志进行排查。${NC}" ;;
	esac

	# 如果 sing-box 已经装了/有 unit，顺手吐一点日志帮助定位
	if command -v systemctl >/dev/null 2>&1; then
		if systemctl status sing-box --no-pager -n 30 >/dev/null 2>&1; then
			journalctl -u sing-box -n 120 --no-pager 2>/dev/null || true
		fi
	fi

	exit "$rc"
}

# ============================================================================
# 陷阱栈管理
# ============================================================================
declare -a TRAP_STACK=()

push_trap() {
	local name="$1"
	local cmd="$2"
	# 保存当前 ERR trap（解析出实际命令）
	local current_trap
	current_trap=$(trap -p ERR)

	# 提取 trap 命令（去掉 "trap -- 'xxx' ERR" 的包装）
	if [ -n "$current_trap" ]; then
		# 从 "trap -- 'command' ERR" 中提取 command
		current_trap=$(echo "$current_trap" | sed -E "s/^trap -- '(.*)' ERR$/\1/")
	else
		current_trap="__EMPTY__"
	fi

	# 审计修复(R-05): 带名称标签压栈，便于 pop 时校验匹配
	TRAP_STACK+=("${name}::${current_trap}")

	# 链式调用：新 trap 执行后调用旧 trap
	if [ "$current_trap" != "__EMPTY__" ]; then
		# shellcheck disable=SC2064
		trap "$cmd; $current_trap" ERR
	else
		# shellcheck disable=SC2064
		trap "$cmd" ERR
	fi
}

pop_trap() {
	local expected_name="${1:-}"
	if [ ${#TRAP_STACK[@]} -eq 0 ]; then
		return 0
	fi

	local last_entry="${TRAP_STACK[-1]}"
	unset 'TRAP_STACK[-1]'

	# 审计修复(R-05): 校验标签名称匹配
	local tag="${last_entry%%::*}"
	local last_trap="${last_entry#*::}"
	if [ -n "$expected_name" ] && [ "$tag" != "$expected_name" ]; then
		log_warn "Trap 栈不匹配: 期望弹出 '$expected_name', 实际弹出 '$tag'"
	fi

	if [ "$last_trap" == "__EMPTY__" ]; then
		trap - ERR
	else
		# shellcheck disable=SC2064
		trap "$last_trap" ERR
	fi
}

_on_err_trap() {
	local rc="$1" line="$2" cmd="$3" file="$4"
	_on_err "$rc" "$line" "$cmd" "$file"
}

cleanup() {
	# O-3 修复: 显式 unset 已知敏感变量，避免 compgen 性能问题
	unset AIRPORT_URLS AIRPORT_URLS_STR AIRPORT_TAGS NEXTDNS_ID REMOTE_MAIN_TAG 2>/dev/null || true
	unset SUBSCRIBE_COMMIT AIRPORT_URLS_STR 2>/dev/null || true

	# 临时文件清理
	rm -f /usr/local/etc/sing-box/*.tmp 2>/dev/null || true
	rm -f /var/lib/sing-box/ruleset/*.tmp 2>/dev/null || true
	rm -f /tmp/singbox-* 2>/dev/null || true
}

_array_contains() {
	local needle="$1"
	shift
	local x
	for x in "$@"; do
		[[ "$x" == "$needle" ]] && return 0
	done
	return 1
}

log_info() { echo -e "${GREEN}[INFO]${NC} [$(date +'%H:%M:%S')] $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} [$(date +'%H:%M:%S')] $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date +'%H:%M:%S')] $*"; }
log_step() {
	CURRENT_STEP="$*"
	echo -e "${BLUE}[STEP]${NC} [$(date +'%H:%M:%S')] $*"
}

_run() {
	# mkdir 始终执行——后续步骤依赖目录存在
	if [[ "$1" == "mkdir" ]]; then
		if [ "${DRY_RUN:-0}" -eq 1 ]; then
			echo -e "${YELLOW}[DRY-RUN]${NC} $* (实际创建以避免后续失败)"
		fi
		"$@"
		return $?
	fi

	if [ "${DRY_RUN:-0}" -eq 1 ]; then
		echo -e "${YELLOW}[DRY-RUN]${NC} $*"
		return 0
	fi

	# APT 锁处理：遇到 unattended-upgrades/dpkg 锁占用时等待并重试
	if [[ "$1" == "apt-get" ]]; then
		local wait_s="${APT_LOCK_WAIT_S:-300}"
		local interval_s="${APT_LOCK_POLL_S:-3}"
		local start_ts
		start_ts=$(date +%s)
		# O-A2 修复: 将 local 声明移出循环，兼容 Bash 4.3 以下版本
		local tmp rc elapsed

		while true; do
			tmp=$(mktemp /tmp/apt-get.stderr.XXXXXX)

			"$@" 2>"$tmp"
			rc=$?
			if [ $rc -eq 0 ]; then
				rm -f "$tmp"
				return 0
			fi

			# 保留 apt-get 的原始错误输出
			cat "$tmp" >&2

			if [ $rc -eq 100 ] && grep -qE "Could not get lock (/var/lib/dpkg/lock-frontend|/var/lib/dpkg/lock)|dpkg frontend lock|Unable to acquire the dpkg frontend lock" "$tmp"; then
				rm -f "$tmp"
				elapsed=$(($(date +%s) - start_ts))

				if [ "$elapsed" -ge "$wait_s" ]; then
					log_error "apt-get 被 dpkg 锁占用超过 ${wait_s}s，请稍后重试"
					return $rc
				fi

				log_warn "apt-get 被 dpkg 锁占用，等待释放后重试... (${elapsed}/${wait_s}s)"
				sleep "$interval_s"
				continue
			fi

			rm -f "$tmp"
			return $rc
		done
	fi

	"$@"
}

_sed_escape_replacement() {
	# 转义 sed replacement 语义字符：& / \ |
	printf '%s' "$1" | sed -e 's/[&\/|]/\\&/g'
}

_safe_source_deployment_config() {
	local cfg="$1"
	[ -f "$cfg" ] || { log_error "配置文件不存在: $cfg"; return 1; }
	# 收紧正则，禁止反引号、$()、${} 等 shell 扩展
	if grep -qvE '^[A-Za-z_][A-Za-z0-9_]*="[A-Za-z0-9_./:, @*=%+\[\]-]*"$|^[[:space:]]*$|^#' "$cfg"; then
		log_error "配置文件格式异常，包含禁止的 shell 元字符: $cfg"
		return 1
	fi
	# shellcheck source=/dev/null
	source "$cfg"
}

_atomic_write() {
	local target="$1"
	local content
	if [ $# -gt 1 ]; then
		content="$2"
	else
		content=$(cat)
	fi
	
	local target_dir
	target_dir="$(dirname "$target")"
	
	# 检查目标磁盘是否有充足可用空间 (预留至少 1MB)
	if ! df -P "$target_dir" >/dev/null 2>&1 || [ "$(df -P "$target_dir" | awk 'NR==2 {print $4}')" -lt 1024 ]; then
		log_error "目标路径 $target_dir 磁盘空间耗尽或无法访问，退出原子写入。"
		return 1
	fi

	local tmp
	tmp=$(mktemp "$target_dir/$(basename "$target").tmp.XXXXXX") || {
		log_error "在 $target_dir 创建临时文件失败，可能是权限或配置所致。"
		return 1
	}
	
	# C-3 修复: 继承目标文件的权限（如果存在）
	if [ -f "$target" ]; then
		chmod --reference="$target" "$tmp" 2>/dev/null || true
	fi
	
	# H-5 修复: 使用 %s 不带 \n，避免对 JSON 等内容添加多余尾部换行
	if printf '%s' "$content" > "$tmp"; then
		# C-3 修复: 确保数据落盘后再原子替换
		# 审计修复(C-03): 消除 python3 -c 路径注入风险，使用原生 sync 命令
		sync "$tmp" 2>/dev/null || sync
		if ! mv "$tmp" "$target"; then
			rm -f "$tmp"
			log_error "原子替换写入失败: $target"
			return 1
		fi
		return 0
	else
		rm -f "$tmp"
		log_error "临时文件写入失败: $tmp"
		return 1
	fi
}

# ============================================================================
# 维护与恢复
# ============================================================================
validate_sing_box_config() {
	local config="$1"
	local sb_bin="${SING_BOX_BIN:-/usr/bin/sing-box}"
	log_info "验证配置文件: $config"

	if [ ! -f "$config" ]; then
		log_error "文件不存在: $config"
		return 1
	fi

	if ! jq empty "$config" >/dev/null 2>&1; then
		log_error "JSON 语法错误"
		return 1
	fi

	local check_log
	check_log=$(mktemp /tmp/singbox_check.XXXXXX)
	# shellcheck disable=SC2024
	if ! sudo -u sing-box "$sb_bin" check -c "$config" >"$check_log" 2>&1; then
		log_error "sing-box 语义检查失败:"
		cat "$check_log" >&2
		rm -f "$check_log"
		return 1
	fi
	rm -f "$check_log"

	return 0
}

create_rollback_point() {
	local config_dir="${1:-/usr/local/etc/sing-box}"
	local rollback_tar="$config_dir/rollback_point.tar.gz"
	
	log_info "创建配置回滚点..."
	# 收集存在的配置文件
	local files_to_back=()
	for f in config.json providers.json config_template.json; do
		[ -f "$config_dir/$f" ] && files_to_back+=("$f")
	done

	if [ ${#files_to_back[@]} -gt 0 ]; then
		tar -czf "$rollback_tar" -C "$config_dir" "${files_to_back[@]}"
		sha256sum "$rollback_tar" > "${rollback_tar}.sha256"
		log_info "  ✓ 已保存回滚快照: $rollback_tar (${files_to_back[*]})"
	else
		log_warn "  ⚠ 未找到任何配置文件，跳过回滚点创建"
	fi
}

# O-16: 集中管理参数的向下兼容默认值（升级模式用）
# 审计注解(R-04): 此处有意不使用 local，这些变量需要全局可见以供后续步骤使用
_ensure_compat_defaults() {
	ENABLE_DASHBOARD=${ENABLE_DASHBOARD:-1}
	DASHBOARD_PORT=${DASHBOARD_PORT:-9090}
	DASHBOARD_SECRET=${DASHBOARD_SECRET:-sing-box}
	IS_DESKTOP=${IS_DESKTOP:-0}
	HAS_IPV6=${HAS_IPV6:-0}
	DEFAULT_REGION=${DEFAULT_REGION:-auto}
	PHYSICAL_MTU=${PHYSICAL_MTU:-1500}
	RECOMMENDED_TUN_MTU=${RECOMMENDED_TUN_MTU:-1400}
	LAN_SUBNET=${LAN_SUBNET:-192.168.0.0/16}
}
