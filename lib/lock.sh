#!/usr/bin/env bash
#
# sing-box deployment project - lock management
# Unified lock implementation (no trap string injection)

# Lock fd cleanup stack (function refs, no string concatenation)
declare -a _LOCK_CLEANUP_PID_FILES=()
declare -a _LOCK_CLEANUP_FDS=()

_lock_cleanup_handler() {
	local i
	for i in "${!_LOCK_CLEANUP_PID_FILES[@]}"; do
		rm -f "${_LOCK_CLEANUP_PID_FILES[$i]}" 2>/dev/null || true
	done
	for i in "${!_LOCK_CLEANUP_FDS[@]}"; do
		eval "exec ${_LOCK_CLEANUP_FDS[$i]}>&-" 2>/dev/null || true
	done
	_LOCK_CLEANUP_PID_FILES=()
	_LOCK_CLEANUP_FDS=()
}

# Unified lock acquisition
# Usage: acquire_lock <lock_file> [timeout_seconds]
# Returns: 0=success 1=timeout or failure
# Auto-registers EXIT/INT/TERM trap for cleanup
acquire_lock() {
	local lock_file="$1"
	local timeout="${2:-300}"
	local lock_fd
	local pid_file="${lock_file}.pid"

	# Ensure lock directory exists
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

	# Atomically open lock file (safe syntax, no eval)
	exec {lock_fd}>"$lock_file"

	local start
	start=$(date +%s)

	while ! flock -n "$lock_fd"; do
		local elapsed=$(($(date +%s) - start))

		# Stale lock detection: PID file exists but process is dead
		if [ -f "$pid_file" ]; then
			local lock_pid
			lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")

			if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
				echo "[INFO] Stale lock detected (PID $lock_pid), auto-cleaning..." >&2
				rm -f "$pid_file" 2>/dev/null || true
				# Retry immediately after stale lock cleanup
				continue
			fi
		fi

		if [ "$elapsed" -ge "$timeout" ]; then
			echo "[ERROR] Lock acquisition timed out (${timeout}s)" >&2
			echo "[INFO] Lock file: $lock_file" >&2
			[ -f "$pid_file" ] && echo "[INFO] Held by PID: $(cat "$pid_file" 2>/dev/null || echo "unknown")" >&2
			# Close fd to free resources
			eval "exec ${lock_fd}>&-" 2>/dev/null || true
			return 1
		fi

		sleep 2
	done

	# Write PID
	echo $$ > "$pid_file" 2>/dev/null || true

	# Register cleanup (array+function refs, no trap string injection)
	_LOCK_CLEANUP_PID_FILES+=("$pid_file")
	_LOCK_CLEANUP_FDS+=("$lock_fd")

	# 只在第一次注册 trap（后续调用只是往数组追加）
	# 使用命名函数引用而非字符串拼接，避免 trap -p | sed 解析含单引号内容时失效
	if [ "${#_LOCK_CLEANUP_PID_FILES[@]}" -eq 1 ]; then
		# 将锁清理注册到全局 hook 数组；统一由 _lock_dispatch_cleanup 调用，
		# 从而无需解析已有 trap 字符串。
		if ! declare -p _GLOBAL_EXIT_HOOKS &>/dev/null 2>&1; then
			declare -ga _GLOBAL_EXIT_HOOKS=()
		fi
		# 避免重复注册
		if [[ ! " ${_GLOBAL_EXIT_HOOKS[*]:-} " =~ " _lock_cleanup_handler " ]]; then
			_GLOBAL_EXIT_HOOKS+=("_lock_cleanup_handler")
		fi

		# _lock_dispatch_cleanup 遍历所有已注册的 hook，并保留幂等性
		_lock_dispatch_cleanup() {
			local _hook
			for _hook in "${_GLOBAL_EXIT_HOOKS[@]:-}"; do
				"$_hook" 2>/dev/null || true
			done
		}

		# 链接：若已有 EXIT trap 包含其他函数，则追加调用；否则直接注册
		# 使用 bash 内置 BASH_COMMAND 无关的方式：检测 trap -p 是否已含 _lock_dispatch_cleanup
		local _current_exit
		_current_exit=$(trap -p EXIT 2>/dev/null || true)
		if [[ "$_current_exit" == *"_lock_dispatch_cleanup"* ]]; then
			: # already chained, nothing to do
		elif [ -n "$_current_exit" ]; then
			# Prepend our dispatcher before the existing handler (safe: function call, no string eval)
			# Extract existing command via printf/eval-safe method
			local _existing_fn
			_existing_fn=$(trap -p EXIT | awk -F"'" 'NF>=2{print $2}' 2>/dev/null || true)
			if [ -n "$_existing_fn" ] && [[ "$_existing_fn" != *"_lock_dispatch_cleanup"* ]]; then
				# Register existing handler into hook array too, then set single dispatcher
				if [[ " ${_GLOBAL_EXIT_HOOKS[*]:-} " != *" $_existing_fn "* ]]; then
					_GLOBAL_EXIT_HOOKS+=("$_existing_fn")
				fi
			fi
			trap '_lock_dispatch_cleanup' EXIT
		else
			trap '_lock_dispatch_cleanup' EXIT
		fi

		# INT/TERM: same dispatcher
		local _current_int
		_current_int=$(trap -p INT 2>/dev/null || true)
		if [[ "$_current_int" != *"_lock_dispatch_cleanup"* ]]; then
			local _existing_int_fn
			_existing_int_fn=$(trap -p INT | awk -F"'" 'NF>=2{print $2}' 2>/dev/null || true)
			if [ -n "$_existing_int_fn" ] && [[ "$_existing_int_fn" != *"_lock_dispatch_cleanup"* ]]; then
				if [[ " ${_GLOBAL_EXIT_HOOKS[*]:-} " != *" $_existing_int_fn "* ]]; then
					_GLOBAL_EXIT_HOOKS+=("$_existing_int_fn")
				fi
			fi
			trap '_lock_dispatch_cleanup' INT TERM
		fi
	fi

	return 0
}

# 向后兼容别名
acquire_deploy_lock() {
	local lock_file="$1"
	# $2 = pid_file (旧 API，忽略，统一用 .pid 后缀)
	local timeout="${3:-300}"
	acquire_lock "$lock_file" "$timeout"
}

acquire_script_lock() {
	acquire_lock "$1" "${2:-300}"
}

cleanup_deploy_lock() {
	local lock_file="$1"
	# 旧 API 兼容：仅清理 PID 文件
	rm -f "${lock_file}.pid" 2>/dev/null || true
	# 如果传了第二个参数 (旧 pid_file 路径)，也清理
	[ -n "${2:-}" ] && rm -f "$2" 2>/dev/null || true
}
